#!/usr/bin/env bash
# PreToolUse hook for the Read tool.
#
# Symmetric with bash.sh: instead of denying, we `allow` and rewrite
# file_path so the host Read tool runs natively — but on a host file
# that reflects the VM's contents.
#
#   - bind-mounted paths (/workspace/* or under the host project
#     dir) just translate to the host equivalent. Same bytes either
#     way; host Read runs directly.
#   - VM-only paths (/tmp/foo, /etc/os-release, ...) get a shadow
#     file populated by `cat`ting the VM file. Host Read reads the
#     shadow.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
. "$SKILL_DIR/_lib.sh"

INPUT="$(cat)"
TOOL_NAME=$(jq -r '.tool_name // empty' <<<"$INPUT")
SESSION_ID=$(jq -r '.session_id // empty' <<<"$INPUT")
FILE_PATH=$(jq -r '.tool_input.file_path // empty' <<<"$INPUT")

# Trace for debugging — comment out once stable.

if [ "$TOOL_NAME" != "Read" ] || [ -z "$FILE_PATH" ] || [ -z "$SESSION_ID" ]; then
  exit 0
fi

gondolin_paths "$SESSION_ID"
gondolin_resolve_path "$FILE_PATH"


if [ "$NEEDS_SYNC" = "yes" ]; then
  if ! gondolin_ensure_daemon; then
    emit_deny "gondolin-read: VM daemon unavailable for $FILE_PATH"
    exit 0
  fi
  mkdir -p "$(dirname -- "$HOST_PATH")"
  QP=$(printf '%q' "$VM_PATH")
  if ! vm_exec_to_file "cat -- $QP" "$HOST_PATH" 2> "$HOST_PATH.err"; then
    err=$(cat "$HOST_PATH.err" 2>/dev/null)
    rm -f "$HOST_PATH" "$HOST_PATH.err"
    emit_deny "gondolin-read: cannot read $VM_PATH in VM: ${err:-(no error)}"
    exit 0
  fi
  rm -f "$HOST_PATH.err"
fi

emit_allow_file_path "$HOST_PATH" "$INPUT"
