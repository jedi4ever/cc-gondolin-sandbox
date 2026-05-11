#!/usr/bin/env bash
# PreToolUse hook for the Bash tool.
#
# Persistent-VM mode: the first Bash call in a Claude session lazy-boots
# a long-running gondolin daemon (vm.js in daemon mode) that owns
# one microVM with /workspace bind-mounted to the host project dir.
# Subsequent Bash calls are rewritten via permissionDecision=allow +
# updatedInput to talk to that same daemon over a Unix socket, so cwd /
# env vars / installed packages / background processes persist between
# calls. Output streams natively because the host Bash tool runs the
# rewritten exec-client command.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
. "$SKILL_DIR/_lib.sh"

INPUT="$(cat)"
TOOL_NAME=$(jq -r '.tool_name // empty' <<<"$INPUT")
SESSION_ID=$(jq -r '.session_id // empty' <<<"$INPUT")
COMMAND=$(jq -r '.tool_input.command // empty' <<<"$INPUT")

# Defensive passthrough.
if [ "$TOOL_NAME" != "Bash" ] || [ -z "$COMMAND" ] || [ -z "$SESSION_ID" ]; then
  exit 0
fi

# --- Probes (kept for diagnostics) -----------------------------------

if [ "$COMMAND" = "__REWRITE_TEST__" ]; then
  emit_allow_rewrite 'echo REWRITE_WORKED:$(date +%s)'
  exit 0
fi

if [[ "$COMMAND" == "__HOST__ "* ]]; then
  emit_allow_rewrite "${COMMAND#__HOST__ }"
  exit 0
fi

# Cooperative scope prefix:
#   __SCOPE=<name>__ <cmd>
# Routes <cmd> to a VM whose state is namespaced by <name>. Each
# distinct scope name gets its own daemon and microVM. The default
# scope ("main") is shared by the orchestrator and any subagents that
# don't opt into a different scope.
SCOPE="main"
if [[ "$COMMAND" =~ ^__SCOPE=([A-Za-z0-9_-]+)__\ (.*)$ ]]; then
  SCOPE="${BASH_REMATCH[1]}"
  COMMAND="${BASH_REMATCH[2]}"
fi

# --- Daemon bootstrap (shared with file-op hooks) --------------------

gondolin_paths "$SESSION_ID" "$SCOPE"
if ! gondolin_ensure_daemon; then
  emit_deny "gondolin-helper: failed to bring up VM daemon (see $GONDOLIN_LOG_DIR)"
  exit 0
fi

# --- Wrap the command to run inside the VM ---------------------------

ENCODED=$(printf '%s' "$COMMAND" | base64 | tr -d '\n')
WRAPPED="node '$GONDOLIN_RUNTIME_DIR/vm.js' exec --sock '$SOCK' '$ENCODED'"

{
  echo "=== $(date -Iseconds) session=$SESSION_ID scope=$SCOPE ==="
  echo "ORIGINAL: $COMMAND"
  echo "WRAPPED:  $WRAPPED"
} >>"$GONDOLIN_LOG_DIR/rewrite.log" 2>/dev/null || true

emit_allow_rewrite "$WRAPPED"
