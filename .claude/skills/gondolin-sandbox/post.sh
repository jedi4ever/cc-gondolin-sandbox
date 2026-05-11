#!/usr/bin/env bash
# PostToolUse hook for Write/Edit.
#
# If the host tool just modified a shadow file under $SHADOW_ROOT,
# push the new bytes back into the VM at the corresponding VM path.
# Bind-mounted paths (under the host project dir) need no sync — the
# bind mount already takes care of it.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
. "$SKILL_DIR/_lib.sh"

INPUT="$(cat)"
TOOL_NAME=$(jq -r '.tool_name // empty' <<<"$INPUT")
SESSION_ID=$(jq -r '.session_id // empty' <<<"$INPUT")
HOST_TARGET=$(jq -r '.tool_input.file_path // empty' <<<"$INPUT")

case "$TOOL_NAME" in
  Write|Edit) ;;
  *) exit 0 ;;
esac

[ -z "$HOST_TARGET" ] || [ -z "$SESSION_ID" ] && exit 0

gondolin_paths "$SESSION_ID"

VM_PATH=$(gondolin_unshadow "$HOST_TARGET")
[ -z "$VM_PATH" ] && exit 0  # not a shadow → bind mount, nothing to do

if ! gondolin_ensure_daemon; then
  echo "gondolin-post: daemon unavailable, cannot sync $HOST_TARGET back to VM $VM_PATH" >&2
  exit 0
fi

if [ ! -f "$HOST_TARGET" ]; then
  echo "gondolin-post: shadow $HOST_TARGET missing after $TOOL_NAME — nothing to sync" >&2
  exit 0
fi

B64=$(base64 < "$HOST_TARGET" | tr -d '\n')
QP=$(printf '%q' "$VM_PATH")
SCRIPT="mkdir -p -- \"\$(dirname -- $QP)\" && printf '%s' '$B64' | base64 -d > $QP"

if ! vm_exec_capture "$SCRIPT"; then
  echo "gondolin-post: failed to sync $HOST_TARGET → VM $VM_PATH: ${VM_OUT:-(no output)}" >&2
fi
