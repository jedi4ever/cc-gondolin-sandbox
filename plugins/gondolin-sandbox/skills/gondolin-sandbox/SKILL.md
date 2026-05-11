---
name: gondolin-sandbox
description: Documents the persistent gondolin microVM sandbox configured at the project level. Bash runs inside the VM, and Read/Write/Edit are bridged into the VM via shadow files. Hook bindings live in .claude/settings.json so they apply to subagents and the main orchestrator alike. Read when investigating sandbox behavior or extending the routing logic.
---

# Gondolin Sandbox (persistent VM)

While this skill is active, every `Bash`, `Read`, `Write`, and `Edit`
tool call is bridged into a **single long-running** gondolin microVM
scoped to the current Claude session. The host project directory is
bind-mounted at `/workspace` inside the guest. State persists across
calls — env vars, installed packages, background processes, and files
anywhere in the guest rootfs survive between commands until SessionEnd.

## Architecture

```
┌────────────── Claude Code (host) ──────────────┐      ┌── microVM ──┐
│  Bash ──► bash.sh ─┐                           │      │             │
│  Read ──► read.sh ─┤                           │      │  /workspace │
│  Write ─► write.sh ─┤ (PreToolUse hooks)       │      │  ◄──bind──► │
│  Edit ──► edit.sh ─┤   emit allow + rewrite    │      │             │
│                    ▼                           │      │             │
│           updatedInput.command|file_path       │      │             │
│                    │                           │      │             │
│        host runs the rewritten tool ──┐        │      │             │
│                                       ▼        │      │             │
│   PostToolUse: post.sh (shadow → VM) ──────────┼──► daemon (vm.js)  │
│                                                │   over Unix sock   │
│   SessionEnd: cleanup.sh ──────────────────────┼──► shutdown        │
└────────────────────────────────────────────────┘      └─────────────┘
```

## How each tool is bridged

### Bash → `bash.sh`

1. The first Bash call lazy-boots `node vm.js daemon`, which uses the
   gondolin SDK (`VM.create`) to start a microVM with `/workspace`
   bind-mounted to the project dir and listens on a Unix socket at
   `~/.cache/gondolin-skill/<session>/<scope>/vm.sock`.
2. `bash.sh` base64-encodes the command and emits
   `permissionDecision: "allow"` with `updatedInput.command` rewritten
   to `node vm.js exec --sock <sock> <BASE64>`.
3. Claude Code's host Bash tool runs the wrapped command natively.
   `vm.js exec` connects to the daemon, sends the command, and
   streams stdout/stderr back as bytes arrive — so output appears in
   real time, not buffered to the end.

### Read → `read.sh`

1. Resolves the agent-supplied path into `VM_PATH` (where it lives in
   the guest) and `HOST_PATH` (where the host Read tool will actually
   run).
2. For bind-mounted paths (under the project dir or `/workspace/*`):
   `HOST_PATH` is just the host equivalent — same bytes either way.
3. For VM-only paths (`/tmp/foo`, `/etc/os-release`, …): `cat`s the
   file from inside the VM into a **shadow** file under
   `~/.cache/gondolin-skill/<session>/<scope>/shadow/<path>` on the
   host, then redirects Read there.
4. Emits `permissionDecision: "allow"` with `updatedInput.file_path`
   set to `HOST_PATH`. Claude Code's host Read tool returns content
   exactly as it normally would.

### Write → `write.sh` (+ `post.sh`)

1. Same path resolution as Read. Pre-creates `dirname HOST_PATH` for
   shadow targets so the host Write tool finds a writable directory.
2. Emits `allow + updatedInput.file_path` (preserving `content` via
   a JSON merge in `emit_allow_file_path`).
3. Host Write writes either the bind-mounted host file (no sync
   needed) or a shadow file.
4. `post.sh` (PostToolUse) inspects the final file_path; if it's
   under `$SHADOW_ROOT`, it pushes the bytes back into the VM at the
   corresponding VM path via `vm_exec`.

### Edit → `edit.sh` (+ `post.sh`)

Same shape as Write — rewrite to shadow path, then sync back in
PostToolUse. The host Edit tool does the actual exact-string
replacement; we just give it the right file to mutate.

### SessionEnd → `cleanup.sh`

Iterates every per-scope subdir under
`~/.cache/gondolin-skill/<session>/`, sends `vm.js shutdown` to each
daemon's socket (graceful `vm.close()`), and removes the session dir.

## Path resolution rules (`gondolin_resolve_path`)

| Agent supplies                        | VM_PATH                         | HOST_PATH                                | Shadow? |
|---------------------------------------|---------------------------------|------------------------------------------|---------|
| `/Users/.../microvm/foo`              | `/workspace/foo`                | `/Users/.../microvm/foo`                 | no      |
| `/workspace/foo`                      | `/workspace/foo`                | `/Users/.../microvm/foo`                 | no      |
| `/tmp/foo` (or any other absolute)    | `/tmp/foo`                      | `$SHADOW_ROOT/tmp/foo`                   | yes     |
| `foo` (relative)                      | `foo`                           | `foo`                                    | no      |

`$SHADOW_ROOT = ~/.cache/gondolin-skill/<session>/<scope>/shadow`.

## State semantics

- **Persists** for the whole Claude session: env vars, installed
  packages (`apk add ...`), files anywhere in the guest, background
  processes, working directory between calls.
- **Synced via bind mount** for paths under the project dir / `/workspace`:
  changes are immediately visible on both sides.
- **Synced via shadow** for VM-only paths: Read fetches VM → shadow;
  Write/Edit mutate shadow then PostToolUse pushes shadow → VM.
- **Lost at SessionEnd**: the VM is destroyed and a fresh one boots
  for the next session.

## First-run setup

The first hook call in a session populates a runtime cache at
`~/.cache/gondolin-skill/runtime/` by running:

```
npm install --silent --no-fund --no-audit @earendil-works/gondolin@latest
```

into that directory, then copies `vm.js` next to it so Node resolves
`@earendil-works/gondolin` via the sibling `node_modules`. Subsequent
sessions just spawn the daemon out of the cache.

`vm.js` is re-synced to the runtime cache on every hook call (it's a
cheap `cp`), so edits or renames in the skill dir pick up on the next
call without manual cleanup.

VM cold-boot (~few seconds + a first-ever ~200MB image download) is
paid **once per session**, not per call. Subsequent calls just
round-trip over the socket.

## Caveats and limits

- **Edit preflight**: Claude Code's `Edit` tool checks "file exists on
  host" *before* PreToolUse hooks fire. That means Edit on `/workspace/*`
  or VM-only paths (`/tmp/foo`) fails with `File does not exist` —
  the hook never gets to redirect. Use the **host-equivalent path**
  (`/Users/.../microvm/...`) when editing bind-mounted files, and
  `Bash` (`sed`, `awk`, `cat >`) for VM-only files outside the bind
  mount.
- **No TTY**: interactive tools (`vim`, `less`, prompts) won't work —
  the guest is fed commands one at a time via the protocol, not via
  a pseudo-terminal.
- **No host-shell features**: each command runs as `/bin/sh -lc <cmd>`
  inside the guest. zsh-isms don't work.
- **Single VM per session+scope**: parallel Bash invocations to the
  same scope queue on the daemon (one command per connection at a
  time). Use `__SCOPE=<name>__ <cmd>` to spin up an isolated VM for a
  subagent.
- **Requires** Node ≥ 23.6 and QEMU on the host (`brew install qemu`
  on macOS).
- **Project-scoped** via `.claude/settings.json` — hooks fire for
  every agent in this project (orchestrator + subagents), regardless
  of whether this skill is loaded in context.

## Debug bypasses

| Bash command prefix             | Effect                                                                                  |
|---------------------------------|-----------------------------------------------------------------------------------------|
| `__HOST__ <cmd>`                | `bash.sh` rewrites to the unwrapped host command — inspect VM state, kill leaked QEMU.  |
| `__SCOPE=<name>__ <cmd>`        | Routes to a per-scope VM (separate daemon, separate `/workspace` mount).                |
| `__REWRITE_TEST__`              | Probe that PreToolUse `allow + updatedInput` actually rewrites the command.             |

## Files

- `_lib.sh` — shared helpers: daemon bootstrap, `vm_exec_*`,
  `gondolin_resolve_path` / `gondolin_unshadow`, JSON emitters.
- `bash.sh` — `PreToolUse` for `Bash` (lazy-boot + rewrite-to-exec-client).
- `read.sh` — `PreToolUse` for `Read` (populate shadow + redirect).
- `write.sh` — `PreToolUse` for `Write` (redirect to shadow).
- `edit.sh` — `PreToolUse` for `Edit` (redirect to shadow).
- `post.sh` — `PostToolUse` for `Write|Edit` (sync shadow → VM).
- `cleanup.sh` — `SessionEnd` (per-scope graceful daemon shutdown).
- `vm.js` — Node program: `daemon` mode owns the VM and listens on
  the socket; `exec` mode is the thin streaming client; `shutdown`
  mode triggers `vm.close()`.
- `~/.cache/gondolin-skill/<session>/<scope>/` — per-session, per-scope
  VM state (socket, daemon log, pid, shadow tree).
- `~/.cache/gondolin-skill/runtime/` — shared SDK install + copy of
  `vm.js`.
- `~/.cache/gondolin-skill/logs/rewrite.log` — per-call Bash audit log.
