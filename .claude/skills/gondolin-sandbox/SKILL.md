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

# Gondolin Sandbox (one-shot exec, rewrite path)

While this skill is active, every `Bash` tool call runs inside a fresh
gondolin microVM. The host project directory is bind-mounted at
`/workspace` inside the guest — file changes the agent makes via Bash
are visible on the host and vice-versa.

## How it works

1. PreToolUse hook (`route.sh`) catches each Bash invocation, reads the
   command from the JSON payload, base64-encodes it, and returns
   `permissionDecision: "allow"` with `updatedInput.command` rewritten
   to:
   ```
   npx @earendil-works/gondolin exec \
     --mount-hostfs '$PROJECT_DIR:/workspace' \
     --cwd /workspace \
     -- /bin/sh -lc 'eval "$(printf %s <BASE64> | base64 -d)"'
   ```
2. Claude Code's host Bash tool runs that wrapped command natively —
   stdout / stderr stream live, no truncation, stdin works.
3. The VM tears down when `gondolin exec` exits, so each call is
   self-contained and cannot leak state to other calls.

The base64 trick avoids a tarpit of shell quoting: the outer host shell
only sees alphanumeric base64 characters in single quotes, and the
original command is reconstructed and `eval`'d inside the guest's login
shell where `$PATH` and profile are loaded.

This relies on PreToolUse hooks honoring `updatedInput` on the `allow`
branch — historically buggy (anthropics/claude-code#15897) but verified
working as of this skill's last test.

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
