#!/usr/bin/env bash
# PreToolUse hook for the Write tool.
#
# Symmetric with bash.sh: allow + rewrite file_path so the host Write
# tool runs natively. For VM-only paths the host writes into a shadow
# file under $SHADOW_ROOT; post.sh then syncs the shadow into the VM.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
. "$SKILL_DIR/_lib.sh"

INPUT="$(cat)"
TOOL_NAME=$(jq -r '.tool_name // empty' <<<"$INPUT")
SESSION_ID=$(jq -r '.session_id // empty' <<<"$INPUT")
FILE_PATH=$(jq -r '.tool_input.file_path // empty' <<<"$INPUT")


if [ "$TOOL_NAME" != "Write" ] || [ -z "$FILE_PATH" ] || [ -z "$SESSION_ID" ]; then
  exit 0
fi

gondolin_paths "$SESSION_ID"
gondolin_resolve_path "$FILE_PATH"


mkdir -p "$(dirname -- "$HOST_PATH")"

emit_allow_file_path "$HOST_PATH" "$INPUT"
