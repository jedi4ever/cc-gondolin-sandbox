---
name: gondolin-sandbox
description: Documents the persistent gondolin microVM Bash sandbox configured at the project level. The actual hook bindings live in .claude/settings.json so they apply to subagents and the main orchestrator alike. Read when investigating sandbox behavior or extending the routing logic.
---

# Gondolin Sandbox (persistent VM)

While this skill is active, every `Bash` tool call runs inside a
**single long-running** gondolin microVM scoped to the current Claude
session. The host project directory is bind-mounted at `/workspace`
inside the guest. State persists across calls — env vars, installed
packages, background processes, and files anywhere in the guest
rootfs all survive between commands until SessionEnd.

## How it works

1. The first Bash call lazy-boots a Node helper (`helper.mjs`) in
   daemon mode. The daemon uses gondolin's SDK (`VM.create`) to boot a
   microVM with `/workspace` bind-mounted, then listens on a Unix
   socket at `~/.cache/gondolin-skill/<session-id>/vm.sock`.
2. The PreToolUse hook (`route.sh`) catches each Bash invocation,
   base64-encodes the command, and returns
   `permissionDecision: "allow"` with `updatedInput.command` rewritten
   to `node helper.mjs exec --sock <socket> <BASE64>`.
3. Claude Code's host Bash tool runs that wrapped command natively.
   `helper.mjs exec` connects to the daemon, sends the command, and
   streams stdout/stderr back to its own stdout/stderr as bytes
   arrive — so output appears in real time in the agent's view.
4. The SessionEnd hook (`cleanup.sh`) sends a `shutdown` request to
   the daemon, which calls `vm.close()` to tear the VM down cleanly.

## State semantics

- **Persists** for the entire Claude session: env vars, installed
  packages (`apk add ...`), files anywhere in the guest, background
  processes, working directory between calls.
- **Synced with host** via `/workspace`: the bind-mount means file
  changes the agent makes there are visible on the host immediately,
  and host edits are visible in the guest.
- **Lost at SessionEnd**: the VM is destroyed and a fresh one boots
  for the next session.

## First-run setup

The first time the skill is used, `route.sh` populates a runtime
cache at `~/.cache/gondolin-skill/runtime/` by running:
```
npm install --silent --no-fund --no-audit @earendil-works/gondolin@latest
```
into that directory. After this one-time install, subsequent sessions
just spawn the helper out of the cache.

VM cold-boot (~few seconds + first-ever ~200MB image download) is paid
**once per session**, not per call. Subsequent calls just round-trip
over the socket.

## Caveats

- **No TTY**: interactive tools (vim, less, prompts) won't work — the
  guest is fed commands one at a time via the protocol, not via a
  pseudo-terminal.
- **No host-shell features in commands**: each command is wrapped in
  `/bin/sh -lc <cmd>` inside the guest. zsh-isms won't work.
- **Single VM per Claude session**: parallel Bash invocations from the
  same session will queue on the daemon (the helper handles one
  command per connection at a time).
- **Requires** Node ≥ 23.6 and QEMU on the host
  (`brew install qemu` on macOS).
- **Project-scoped** via `.claude/settings.json` — hooks fire for every
  agent in this project (main orchestrator and any subagents),
  regardless of whether this skill is loaded in context.

## Debug bypass

Prefix a Bash command with `__HOST__ ` (note the trailing space) to
make `route.sh` rewrite to the unwrapped host command — useful for
inspecting VM state, killing leaked QEMU processes, or running git on
the host. Probe `__REWRITE_TEST__` verifies that PreToolUse hooks
honor `updatedInput` on the `allow` branch.

## Files

- `route.sh` — `PreToolUse` Bash router (lazy-boot + rewrite)
- `helper.mjs` — Node SDK helper (daemon, exec client, shutdown)
- `cleanup.sh` — `SessionEnd` graceful daemon shutdown
- `~/.cache/gondolin-skill/<session-id>/` — per-session VM state
  (socket, daemon log, daemon pid)
- `~/.cache/gondolin-skill/runtime/` — shared SDK install
- `~/.cache/gondolin-skill/logs/rewrite.log` — per-call audit log
