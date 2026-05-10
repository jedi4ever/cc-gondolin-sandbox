#!/usr/bin/env bash
# PreToolUse hook for the Bash tool.
#
# Rewrites every Bash invocation into a `gondolin exec` call that runs
# the command inside a one-shot Alpine microVM with the project dir
# bind-mounted at /workspace. The rewrite is delivered via
# `permissionDecision: "allow"` + `updatedInput`, so Claude Code's host
# Bash tool runs the wrapped command natively — full streaming, no
# truncation, stdin works.
#
# To handle arbitrary command content (quotes, $vars, backticks, etc.)
# we base64-encode the command on the host and `eval` the decoded form
# inside the guest. The outer shell only ever sees safe alphanumeric
# base64 characters in single quotes.

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
LOG_DIR="${GONDOLIN_SKILL_LOG_DIR:-$HOME/.cache/gondolin-skill/logs}"
mkdir -p "$LOG_DIR"

INPUT="$(cat)"
TOOL_NAME=$(jq -r '.tool_name // empty' <<<"$INPUT")
COMMAND=$(jq -r '.tool_input.command // empty' <<<"$INPUT")

# Defensive passthrough.
if [ "$TOOL_NAME" != "Bash" ] || [ -z "$COMMAND" ]; then
  exit 0
fi

emit_allow_rewrite() {
  jq -nc --arg cmd "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      updatedInput: { command: $cmd }
    }
  }'
}

emit_deny() {
  jq -nc --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
}

# --- Probes (kept for diagnostics; remove once you trust the skill) ----

# Tests whether updatedInput is honored on the allow branch.
if [ "$COMMAND" = "__REWRITE_TEST__" ]; then
  emit_allow_rewrite 'echo REWRITE_WORKED:$(date +%s)'
  exit 0
fi

# Same probe via permissionDecision=ask.
if [ "$COMMAND" = "__REWRITE_TEST_ASK__" ]; then
  jq -nc '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: "rewrite-bug probe (ask path)",
      updatedInput: { command: "echo REWRITE_WORKED_ASK:$(date +%s)" }
    }
  }'
  exit 0
fi

# Long-running probe inside the VM.
if [ "$COMMAND" = "__LONG_TEST__" ]; then
  GUEST_SCRIPT='START=$(date +%s); for i in $(seq 1 10); do echo "tick $i at $(date +%s) (elapsed $(( $(date +%s) - START ))s)"; sleep 1; done; echo done'
  emit_allow_rewrite "npx --yes @earendil-works/gondolin exec --mount-hostfs '$PROJECT_DIR:/workspace' --cwd /workspace -- /bin/sh -lc '$GUEST_SCRIPT'"
  exit 0
fi

# Host bypass for debugging the skill itself.
if [[ "$COMMAND" == "__HOST__ "* ]]; then
  HOST_CMD="${COMMAND#__HOST__ }"
  emit_allow_rewrite "$HOST_CMD"
  exit 0
fi

# --- Main path: wrap the command into a gondolin exec call. ------------

ENCODED=$(printf '%s' "$COMMAND" | base64 | tr -d '\n')

# The outer host shell sees only single-quoted base64 plus the static
# decode shim. The guest's /bin/sh -lc decodes via base64 -d and evals
# the original command in a login shell so $PATH / profile are loaded.
WRAPPED="npx --yes @earendil-works/gondolin exec --mount-hostfs '$PROJECT_DIR:/workspace' --cwd /workspace -- /bin/sh -lc 'eval \"\$(printf %s $ENCODED | base64 -d)\"'"

# Light per-call audit log. We don't capture command output — the host
# Bash tool now owns that — but we record the rewrite for debugging.
{
  echo "=== $(date -Iseconds) ==="
  echo "ORIGINAL: $COMMAND"
  echo "WRAPPED: $WRAPPED"
} >>"$LOG_DIR/rewrite.log" 2>/dev/null || true

emit_allow_rewrite "$WRAPPED"
