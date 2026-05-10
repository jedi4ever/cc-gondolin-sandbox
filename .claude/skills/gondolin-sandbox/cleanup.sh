#!/usr/bin/env bash
# SessionEnd hook: gracefully shut down the per-Claude-session gondolin
# daemon and tear down its microVM.
set -uo pipefail

RUNTIME_DIR="${GONDOLIN_SKILL_RUNTIME_DIR:-$HOME/.cache/gondolin-skill/runtime}"

INPUT="$(cat 2>/dev/null || true)"
SESSION_ID=$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null || true)
[ -z "$SESSION_ID" ] && exit 0

SESSION_DIR="$HOME/.cache/gondolin-skill/$SESSION_ID"
SOCK="$SESSION_DIR/vm.sock"
PID_FILE="$SESSION_DIR/daemon.pid"

# Polite shutdown over the socket: the daemon will await vm.close() and
# unlink the socket itself.
if [ -S "$SOCK" ] && [ -f "$RUNTIME_DIR/helper.mjs" ]; then
  node "$RUNTIME_DIR/helper.mjs" shutdown --sock "$SOCK" 2>/dev/null || true
fi

# Backstop: if a PID file exists and the process is still alive after a
# short grace period, kill it.
if [ -f "$PID_FILE" ]; then
  PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
  if [ -n "$PID" ]; then
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$PID" 2>/dev/null || break
      sleep 0.5
    done
    kill -0 "$PID" 2>/dev/null && kill -KILL "$PID" 2>/dev/null || true
  fi
fi

rm -rf "$SESSION_DIR"
