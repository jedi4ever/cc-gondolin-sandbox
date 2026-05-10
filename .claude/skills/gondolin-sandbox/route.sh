#!/usr/bin/env bash
# PreToolUse hook for the Bash tool.
#
# Runs each command in a fresh one-shot gondolin microVM with the
# project directory bind-mounted at /workspace. State persists across
# calls via the bind-mount (any file changes the agent makes are visible
# on the host and vice-versa). Each call pays a few-second VM cold-boot;
# in-VM state (env vars, installed packages) does NOT persist.
#
# We use the "deny + reason carrying the output" pattern because
# `updatedInput` is currently ignored on PreToolUse hooks
# (anthropics/claude-code#15897). The reason text is framed so the model
# reads it as the actual command result.

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

emit_deny() {
  jq -nc --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
}

# Debug bypass: a command starting with `__HOST__ ` (note the SPACE) runs
# on the host instead of the microVM. Lets us introspect/clean up VM
# state from outside the sandbox while the skill is active.
if [[ "$COMMAND" == "__HOST__ "* ]]; then
  HOST_CMD="${COMMAND#__HOST__ }"
  TMP_OUT=$(mktemp); TMP_ERR=$(mktemp)
  bash -c "$HOST_CMD" >"$TMP_OUT" 2>"$TMP_ERR"
  HX=$?
  REASON=$(printf '[host-bypass] exit %d\n--- stdout ---\n%s\n--- stderr ---\n%s' \
    "$HX" "$(cat "$TMP_OUT")" "$(cat "$TMP_ERR")")
  rm -f "$TMP_OUT" "$TMP_ERR"
  emit_deny "$REASON"
  exit 0
fi

# Run the command in a one-shot VM. `gondolin exec` in in-process VM
# mode boots a microVM, runs the command, and tears the VM down on
# exit — no orphaned QEMUs.
TMP_OUT=$(mktemp); TMP_ERR=$(mktemp)
trap 'rm -f "$TMP_OUT" "$TMP_ERR"' EXIT

LOG_FILE="$LOG_DIR/$(date +%Y%m%dT%H%M%S)-$$.log"
{
  echo "=== gondolin-sandbox $(date -Iseconds) ==="
  echo "PROJECT_DIR=$PROJECT_DIR"
  echo "COMMAND=$COMMAND"
} >"$LOG_FILE"

npx --yes @earendil-works/gondolin exec \
  --mount-hostfs "$PROJECT_DIR:/workspace" \
  --cwd /workspace \
  -- /bin/sh -lc "$COMMAND" \
  >"$TMP_OUT" 2>"$TMP_ERR"
EXIT=$?

{
  echo "EXIT=$EXIT"
  echo "--- stdout ---"; cat "$TMP_OUT"
  echo "--- stderr ---"; cat "$TMP_ERR"
} >>"$LOG_FILE"

OUT=$(cat "$TMP_OUT")
ERR=$(cat "$TMP_ERR")

# Phrasing: this is what the model sees. Frame as the command's actual
# result so it doesn't react to "deny" by retrying or apologizing.
REASON=$(printf 'Command executed inside gondolin microVM (one-shot). Treat the following as the actual command result.\nExit code: %d\n\n--- stdout ---\n%s\n\n--- stderr ---\n%s\n\nNote: Each call boots a fresh VM. State persists via /workspace (bind-mounted from %s on the host). Env vars and installed packages do NOT persist between calls.' \
  "$EXIT" "$OUT" "$ERR" "$PROJECT_DIR")

emit_deny "$REASON"
