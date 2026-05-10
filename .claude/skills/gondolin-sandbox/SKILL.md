---
name: gondolin-sandbox
description: Routes every Bash command through a gondolin microVM (Alpine Linux on QEMU) one call at a time. Use when shell commands should execute in an isolated sandbox while still being able to read and write the host project directory. Activate for tasks involving untrusted code, agent-generated scripts, network-restricted execution, or microVM sandboxing.
hooks:
  PreToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "${CLAUDE_PROJECT_DIR}/.claude/skills/gondolin-sandbox/route.sh"
  SessionEnd:
    - matcher: "*"
      hooks:
        - type: command
          command: "${CLAUDE_PROJECT_DIR}/.claude/skills/gondolin-sandbox/cleanup.sh"
---

# Gondolin Sandbox (one-shot exec)

While this skill is active, every `Bash` tool call runs inside a fresh
gondolin microVM. The host project directory is bind-mounted at
`/workspace` inside the guest — file changes the agent makes via Bash
are visible on the host and vice-versa.

## How it works

1. PreToolUse hook (`route.sh`) catches each Bash invocation, reads the
   command from the JSON payload, and runs:
   ```
   npx @earendil-works/gondolin exec \
     --mount-hostfs "$PROJECT_DIR:/workspace" \
     --cwd /workspace \
     -- /bin/sh -lc "$COMMAND"
   ```
2. stdout / stderr / exit code are captured and returned to the model
   via `permissionDecision: "deny"` with the output framed as the
   command's actual result. This is the documented workaround for the
   open `updatedInput` bug on PreToolUse hooks
   (anthropics/claude-code#15897).
3. The VM tears down when `gondolin exec` exits, so each call is
   self-contained and cannot leak state to other calls.

## State semantics

- **Persists across calls**: anything written under `/workspace` (i.e.
  the host project dir).
- **Does NOT persist**: env vars, installed packages, background
  processes, anything written outside `/workspace`. Each call gets a
  fresh Alpine rootfs.

To get a long-running persistent VM (so installed packages and env
survive across calls), the next iteration would need a small Node helper
that uses gondolin's `VM.create()` SDK and exposes a control socket —
the bare CLI doesn't register a session in non-TTY background spawns,
which made the persistent-VM-via-`gondolin bash` approach unreliable.

## Caveats

- **No streaming**: output is buffered until the command finishes.
- **No TTY**: interactive tools (vim, less, prompts) won't work.
- **VM cold-start per call**: ~few seconds overhead on every Bash call.
  First call ever also downloads ~200MB of guest assets into
  `~/.cache/gondolin/images/`.
- **Requires** Node ≥ 23.6 and QEMU on the host
  (`brew install qemu` on macOS).
- **Skill-scoped**, not session-scoped — the hooks only fire while the
  skill is loaded into context. To make routing always-on for a project,
  copy the same `hooks:` block into `.claude/settings.json`.

## Debug bypass

While iterating on the skill itself, you can prefix a Bash command with
`__HOST__ ` (note the trailing space) to make `route.sh` execute the
command on the host instead of the microVM. Useful for inspecting VM
state, killing leaked QEMU processes, etc. The bypass is implemented in
`route.sh` lines 38–48; remove that block before treating the skill as
production-ready.

## Files

- `route.sh` — `PreToolUse` Bash router
- `cleanup.sh` — `SessionEnd` (no-op by default; set
  `GONDOLIN_KILL_ALL_QEMU=1` to opt into blanket QEMU cleanup)
- `~/.cache/gondolin-skill/logs/` — per-call command logs (timestamped)
