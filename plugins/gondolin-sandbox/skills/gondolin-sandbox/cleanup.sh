#!/usr/bin/env bash
# SessionEnd hook: gracefully shut down every gondolin daemon spawned
# by this Claude session — the default "main" VM and any per-scope
# isolated VMs created via the __SCOPE=<name>__ cooperative prefix.
set -uo pipefail

RUNTIME_DIR="${GONDOLIN_SKILL_RUNTIME_DIR:-$HOME/.cache/gondolin-skill/runtime}"

INPUT="$(cat 2>/dev/null || true)"
SESSION_ID=$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null || true)
[ -z "$SESSION_ID" ] && exit 0

SESSION_ROOT="$HOME/.cache/gondolin-skill/$SESSION_ID"
[ -d "$SESSION_ROOT" ] || exit 0

shutdown_one() {
  local scope_dir="$1"
  local sock="$scope_dir/vm.sock"
  local pid_file="$scope_dir/daemon.pid"

  if [ -S "$sock" ] && [ -f "$RUNTIME_DIR/vm.js" ]; then
    node "$RUNTIME_DIR/vm.js" shutdown --sock "$sock" 2>/dev/null || true
  fi

  if [ -f "$pid_file" ]; then
    local pid
    pid=$(cat "$pid_file" 2>/dev/null || echo "")
    if [ -n "$pid" ]; then
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
      done
      kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
}

for scope_dir in "$SESSION_ROOT"/*/; do
  [ -d "$scope_dir" ] || continue
  shutdown_one "$scope_dir"
done

rm -rf "$SESSION_ROOT"
