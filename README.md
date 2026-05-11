# gondolin-sandbox

A [Claude Code](https://claude.com/claude-code) plugin that sandboxes
every `Bash`, `Read`, `Write`, and `Edit` tool call inside a persistent
[gondolin](https://www.npmjs.com/package/@earendil-works/gondolin) microVM,
scoped to a single Claude session.

- **`Bash`** runs inside the VM. Output streams back in real time.
- **`Read`**, **`Write`**, **`Edit`** act on the same filesystem the
  VM sees — either directly via a bind mount, or through host-side
  *shadow files* synced into the VM after each write.
- State (env vars, installed packages, background processes, files
  anywhere in the guest rootfs) persists across calls. The VM is
  destroyed at `SessionEnd`.

## Why

Running `apt install …` (or `apk add …`) shouldn't pollute your dev
machine. Letting an agent edit `/etc/...` shouldn't actually edit your
host's `/etc/...`. With this plugin, the agent's "filesystem" is the
VM's filesystem — your host stays clean.

## How it works

The plugin ships PreToolUse hooks for `Bash`/`Read`/`Write`/`Edit`,
a PostToolUse hook for `Write`/`Edit`, and a SessionEnd cleanup
hook. All hooks share a single shell library and a Node helper:

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

The first hook in a session lazy-boots `node vm.js daemon`, which
uses the gondolin SDK to start a microVM with the project dir
bind-mounted at `/workspace`. Subsequent hook calls reuse the same
daemon over a Unix socket.

Full architecture and edge cases:
[`plugins/gondolin-sandbox/skills/gondolin-sandbox/SKILL.md`](plugins/gondolin-sandbox/skills/gondolin-sandbox/SKILL.md).

## Requirements

- macOS (Apple Silicon tested) or Linux
- **Node ≥ 23.6**
- **QEMU** — `brew install qemu` on macOS
- **Claude Code** with hooks support

## Layout

```
.claude-plugin/
└── marketplace.json                   # exposes this repo as a plugin marketplace
plugins/gondolin-sandbox/
├── .claude-plugin/plugin.json         # plugin manifest
├── hooks/hooks.json                   # hook bindings (used when installed as a plugin)
└── skills/gondolin-sandbox/
    ├── SKILL.md                       # in-depth architecture doc
    ├── _lib.sh                        # shared bootstrap, vm_exec, path resolution, JSON emitters
    ├── bash.sh                        # PreToolUse Bash
    ├── read.sh                        # PreToolUse Read
    ├── write.sh                       # PreToolUse Write
    ├── edit.sh                        # PreToolUse Edit
    ├── post.sh                        # PostToolUse Write|Edit (shadow → VM sync)
    ├── cleanup.sh                     # SessionEnd (graceful per-scope shutdown)
    └── vm.js                          # Node program (daemon | exec client | shutdown)

.claude/
└── settings.json                      # this repo dogfoods the plugin by pointing
                                       # hooks at the plugin scripts directly.
```

## Install

Inside Claude Code, in any project where you want the sandbox:

```text
/plugin marketplace add jedi4ever/cc-gondolin-sandbox
/plugin install gondolin-sandbox@gondolin
```

Or, from a shell:

```sh
claude plugin marketplace add jedi4ever/cc-gondolin-sandbox
claude plugin install gondolin-sandbox@gondolin --scope project   # or --user
```

Pass `--project` to install into the current project only
(`.claude/settings.json`), or `--user` to install for your user
globally (`~/.claude/settings.json`).

The first command registers this repo as a plugin marketplace (named
`gondolin` from `.claude-plugin/marketplace.json`); the second
installs the `gondolin-sandbox` plugin from it. Reload the session
and every `Bash`/`Read`/`Write`/`Edit` tool call routes through the
microVM.

To install from a local clone instead of GitHub:

```text
/plugin marketplace add /path/to/microvm
/plugin install gondolin-sandbox@gondolin --project   # or --user
```

### Using it in this repo

`.claude/settings.json` already wires the hooks to the plugin
scripts via `${CLAUDE_PROJECT_DIR}`, so opening this repo with Claude
Code activates the sandbox automatically — no `/plugin install` needed.

## Path semantics (Read/Write/Edit)

| Agent supplies                        | Where it goes                                | Notes                              |
|---------------------------------------|----------------------------------------------|------------------------------------|
| `/path/to/project/foo`                | host bind-mount (= `/workspace/foo` in VM)   | direct, no shadow                  |
| `/workspace/foo`                      | same as above                                | translated to host equivalent      |
| `/tmp/foo`, `/etc/os-release`, …      | shadow file on host, synced into VM          | works for `Read`/`Write`           |
| same as above, but `Edit`             | **doesn't work** — see below                 | use `Bash` (`sed`, `echo >>`)      |

### Known limitation — `Edit` preflight

Claude Code's `Edit` tool checks "does the file exist on the host?"
*before* PreToolUse hooks fire. So `Edit` on `/workspace/...` or
VM-only paths fails with `File does not exist` — the hook never gets
to redirect. For bind-mounted files, **use the host-equivalent path**
(`/path/to/project/foo`). For VM-only files, use `Bash` (`sed -i`,
`echo >>`).

## Bash escapes

| Prefix the Bash command with   | Effect                                                              |
|--------------------------------|---------------------------------------------------------------------|
| `__HOST__ <cmd>`               | Runs `<cmd>` on the host, not in the VM (debug / inspect).          |
| `__SCOPE=<name>__ <cmd>`       | Routes `<cmd>` to a separate per-scope VM (separate `/workspace`).  |
| `__REWRITE_TEST__`             | Diagnostic probe — verifies that `allow + updatedInput` works.      |

## Caveats

- **No TTY** — interactive tools (`vim`, `less`, prompts) won't work.
- **Single VM per session+scope** — parallel Bash calls in the same
  scope queue on the daemon.
- VM cold-boot (~few seconds + a first-ever ~200MB image download)
  is paid **once per session**, not per call.
- All hooks fire for every agent in this project (orchestrator +
  subagents). Use `__SCOPE=...` to isolate.

## License

MIT
