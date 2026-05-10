#!/usr/bin/env bash
# PreToolUse hook for the Bash tool.
#
# Persistent-VM mode: the first Bash call in a Claude session lazy-boots
# a long-running gondolin daemon (helper.mjs in daemon mode) that owns
# one microVM with /workspace bind-mounted to the host project dir.
# Subsequent Bash calls are rewritten via permissionDecision=allow +
# updatedInput to talk to that same daemon over a Unix socket, so cwd /
# env vars / installed packages / background processes persist between
# calls. Output streams natively because the host Bash tool runs the
# rewritten exec-client command.

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="${GONDOLIN_SKILL_RUNTIME_DIR:-$HOME/.cache/gondolin-skill/runtime}"
LOG_DIR="${GONDOLIN_SKILL_LOG_DIR:-$HOME/.cache/gondolin-skill/logs}"
mkdir -p "$LOG_DIR"

INPUT="$(cat)"
TOOL_NAME=$(jq -r '.tool_name // empty' <<<"$INPUT")
SESSION_ID=$(jq -r '.session_id // empty' <<<"$INPUT")
COMMAND=$(jq -r '.tool_input.command // empty' <<<"$INPUT")

# Defensive passthrough.
if [ "$TOOL_NAME" != "Bash" ] || [ -z "$COMMAND" ] || [ -z "$SESSION_ID" ]; then
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

# --- Per-Claude-session, per-scope VM state --------------------------

SESSION_DIR="$HOME/.cache/gondolin-skill/$SESSION_ID/$SCOPE"
SOCK="$SESSION_DIR/vm.sock"
DAEMON_LOG="$SESSION_DIR/daemon.log"
DAEMON_PID_FILE="$SESSION_DIR/daemon.pid"
mkdir -p "$SESSION_DIR"

# --- One-time SDK install in the runtime cache -----------------------

ensure_runtime() {
  if [ -d "$RUNTIME_DIR/node_modules/@earendil-works/gondolin" ]; then
    return 0
  fi
  mkdir -p "$RUNTIME_DIR"
  ( cd "$RUNTIME_DIR" \
    && [ -f package.json ] || echo '{"private":true,"type":"module"}' >package.json \
    && npm install --silent --no-fund --no-audit @earendil-works/gondolin@latest \
    ) >"$LOG_DIR/runtime-install.log" 2>&1 || return 1
  return 0
}

# Always copy the helper into the runtime dir so node resolves
# @earendil-works/gondolin via the sibling node_modules. Cheap; lets us
# edit helper.mjs and pick up changes on the next call.
sync_helper() {
  cp -f "$SKILL_DIR/helper.mjs" "$RUNTIME_DIR/helper.mjs"
}

daemon_alive() {
  [ -S "$SOCK" ] || return 1
  [ -f "$DAEMON_PID_FILE" ] || return 1
  local pid
  pid=$(cat "$DAEMON_PID_FILE" 2>/dev/null)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

boot_daemon() {
  rm -f "$SOCK"

  # Run the daemon detached so it survives this hook process. nohup +
  # disown is portable; setsid is Linux-only.
  nohup node "$RUNTIME_DIR/helper.mjs" daemon \
    --sock "$SOCK" \
    --workspace "$PROJECT_DIR" \
    >"$DAEMON_LOG" 2>&1 </dev/null &
  local pid=$!
  echo "$pid" >"$DAEMON_PID_FILE"
  disown "$pid" 2>/dev/null || true

  # Wait up to 60s for the socket to appear.
  local deadline=$(( $(date +%s) + 60 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ -S "$SOCK" ] && return 0
    if ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    sleep 0.5
  done
  return 1
}

# --- Main path -------------------------------------------------------

if ! daemon_alive; then
  if ! ensure_runtime; then
    emit_deny "gondolin-helper: failed to install runtime. See $LOG_DIR/runtime-install.log"
    exit 0
  fi
  sync_helper
  if ! boot_daemon; then
    LOG_TAIL=$(tail -n 40 "$DAEMON_LOG" 2>/dev/null || echo "(no log)")
    emit_deny "$(printf 'gondolin-helper: daemon failed to start.\n--- daemon.log (tail) ---\n%s' "$LOG_TAIL")"
    exit 0
  fi
fi

ENCODED=$(printf '%s' "$COMMAND" | base64 | tr -d '\n')
WRAPPED="node '$RUNTIME_DIR/helper.mjs' exec --sock '$SOCK' '$ENCODED'"

{
  echo "=== $(date -Iseconds) session=$SESSION_ID ==="
  echo "ORIGINAL: $COMMAND"
  echo "WRAPPED:  $WRAPPED"
} >>"$LOG_DIR/rewrite.log" 2>/dev/null || true

emit_allow_rewrite "$WRAPPED"
