# Shared helpers for the gondolin-sandbox file-op hooks (read.sh,
# write.sh, edit.sh, post.sh). Sourced — not executed directly.
#
# Mirrors the daemon bootstrap that bash.sh does for Bash, so any of
# these hooks can be the first one to wake the VM in a session.

set -uo pipefail

GONDOLIN_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
GONDOLIN_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GONDOLIN_RUNTIME_DIR="${GONDOLIN_SKILL_RUNTIME_DIR:-$HOME/.cache/gondolin-skill/runtime}"
GONDOLIN_LOG_DIR="${GONDOLIN_SKILL_LOG_DIR:-$HOME/.cache/gondolin-skill/logs}"
mkdir -p "$GONDOLIN_LOG_DIR"

# Populate SESSION_DIR / SOCK / DAEMON_LOG / DAEMON_PID_FILE / SHADOW_ROOT
# for the given session id (and optional scope, defaulting to "main").
gondolin_paths() {
  local session_id="$1" scope="${2:-main}"
  SESSION_DIR="$HOME/.cache/gondolin-skill/$session_id/$scope"
  SOCK="$SESSION_DIR/vm.sock"
  DAEMON_LOG="$SESSION_DIR/daemon.log"
  DAEMON_PID_FILE="$SESSION_DIR/daemon.pid"
  SHADOW_ROOT="$SESSION_DIR/shadow"
  mkdir -p "$SESSION_DIR" "$SHADOW_ROOT"
}

_gondolin_ensure_runtime() {
  if [ -d "$GONDOLIN_RUNTIME_DIR/node_modules/@earendil-works/gondolin" ]; then
    return 0
  fi
  mkdir -p "$GONDOLIN_RUNTIME_DIR"
  (
    cd "$GONDOLIN_RUNTIME_DIR" \
      && ([ -f package.json ] || echo '{"private":true,"type":"module"}' >package.json) \
      && npm install --silent --no-fund --no-audit @earendil-works/gondolin@latest
  ) >"$GONDOLIN_LOG_DIR/runtime-install.log" 2>&1 || return 1
  return 0
}

_gondolin_sync_helper() {
  cp -f "$GONDOLIN_SKILL_DIR/vm.js" "$GONDOLIN_RUNTIME_DIR/vm.js"
}

_gondolin_daemon_alive() {
  [ -S "$SOCK" ] || return 1
  [ -f "$DAEMON_PID_FILE" ] || return 1
  local pid
  pid=$(cat "$DAEMON_PID_FILE" 2>/dev/null)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

_gondolin_boot_daemon() {
  rm -f "$SOCK"
  nohup node "$GONDOLIN_RUNTIME_DIR/vm.js" daemon \
    --sock "$SOCK" \
    --workspace "$GONDOLIN_PROJECT_DIR" \
    >"$DAEMON_LOG" 2>&1 </dev/null &
  local pid=$!
  echo "$pid" >"$DAEMON_PID_FILE"
  disown "$pid" 2>/dev/null || true

  local deadline=$(( $(date +%s) + 60 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ -S "$SOCK" ] && return 0
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.5
  done
  return 1
}

# Ensure the VM daemon for the current session/scope is alive. On
# failure prints a diagnostic to stderr and returns non-zero.
#
# Always re-syncs vm.js from the skill dir into the runtime cache so
# edits / renames pick up on the next hook invocation without manual
# cleanup. The daemon itself keeps its in-memory copy; only the exec
# client (spawned per call) needs the on-disk file up to date.
gondolin_ensure_daemon() {
  if ! _gondolin_ensure_runtime; then
    echo "gondolin-helper: runtime install failed (see $GONDOLIN_LOG_DIR/runtime-install.log)" >&2
    return 1
  fi
  _gondolin_sync_helper
  _gondolin_daemon_alive && return 0
  if ! _gondolin_boot_daemon; then
    local tail
    tail=$(tail -n 40 "$DAEMON_LOG" 2>/dev/null || echo "(no log)")
    echo "gondolin-helper: daemon failed to start. --- daemon.log (tail) ---" >&2
    echo "$tail" >&2
    return 1
  fi
  return 0
}

# Run a bash command in the VM. Captures combined stdout+stderr to
# VM_OUT and returns the VM's exit code.
vm_exec_capture() {
  local b64
  b64=$(printf '%s' "$1" | base64 | tr -d '\n')
  VM_OUT=$(node "$GONDOLIN_RUNTIME_DIR/vm.js" exec --sock "$SOCK" "$b64" 2>&1)
  return $?
}

# Run a bash command in the VM, sending stdout to a host file.
vm_exec_to_file() {
  local cmd="$1" out_path="$2"
  local b64
  b64=$(printf '%s' "$cmd" | base64 | tr -d '\n')
  node "$GONDOLIN_RUNTIME_DIR/vm.js" exec --sock "$SOCK" "$b64" > "$out_path"
}

# Resolve an agent-supplied file path into three pieces:
#   VM_PATH    — where the file lives inside the VM
#   HOST_PATH  — the path the host tool should actually operate on
#   NEEDS_SYNC — "yes" if HOST_PATH is a shadow that needs to be
#                synced back to VM_PATH after a Write/Edit
#
# Rules:
#   - paths under the host project dir (e.g. /Users/.../microvm/x)
#     are bind-mounted to /workspace/x in the VM. Host tool acts on
#     the host path; no shadow, no sync.
#   - /workspace/x is the VM view of the same bind mount. Translate
#     to the host project equivalent; no shadow, no sync.
#   - any other absolute path (/tmp/foo, /etc/os-release, ...) is
#     VM-only. Use a shadow file under $SHADOW_ROOT mirroring the
#     VM path. Host tool acts on the shadow; PostToolUse syncs back.
gondolin_resolve_path() {
  local agent_path="$1"
  local host="${GONDOLIN_PROJECT_DIR%/}"
  case "$agent_path" in
    "$host")
      VM_PATH="/workspace"; HOST_PATH="$host"; NEEDS_SYNC="no" ;;
    "$host"/*)
      VM_PATH="/workspace/${agent_path#$host/}"; HOST_PATH="$agent_path"; NEEDS_SYNC="no" ;;
    /workspace)
      VM_PATH="/workspace"; HOST_PATH="$host"; NEEDS_SYNC="no" ;;
    /workspace/*)
      VM_PATH="$agent_path"; HOST_PATH="$host/${agent_path#/workspace/}"; NEEDS_SYNC="no" ;;
    /*)
      VM_PATH="$agent_path"; HOST_PATH="$SHADOW_ROOT$agent_path"; NEEDS_SYNC="yes" ;;
    *)
      VM_PATH="$agent_path"; HOST_PATH="$agent_path"; NEEDS_SYNC="no" ;;
  esac
}

# Recover the VM path from a host shadow path. Echoes empty string
# if the host path isn't actually under SHADOW_ROOT.
gondolin_unshadow() {
  local host_path="$1"
  case "$host_path" in
    "$SHADOW_ROOT"/*) echo "/${host_path#$SHADOW_ROOT/}" ;;
    *)                echo "" ;;
  esac
}

# JSON helpers — emit Claude Code PreToolUse hook responses.

# Allow the Bash tool to run a rewritten command (used by bash.sh
# to wrap each Bash invocation in `node vm.js exec ...`).
emit_allow_rewrite() {
  jq -nc --arg cmd "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      updatedInput: { command: $cmd }
    }
  }'
}

# Build an allow + updatedInput that preserves every other field
# from the original tool_input (Edit needs old_string/new_string,
# Write needs content, etc.). Pass INPUT as the second arg.
emit_allow_file_path() {
  local fp="$1" input_json="$2"
  jq -nc --arg fp "$fp" --argjson orig "$(jq -c '.tool_input' <<<"$input_json")" '
    {
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "allow",
        updatedInput: ($orig + { file_path: $fp })
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
