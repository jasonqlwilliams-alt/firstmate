#!/usr/bin/env bash
# fm-status-append.sh - append one worker status line.
#
# New ship and scout briefs (bin/fm-brief.sh) and bin/fm-secondmate-report.sh
# use this writer. An explicit key that starts with a prefix reserved by
# bin/fm-classify-lib.sh is refused before any byte is written: the error
# names that prefix and tells the worker to pick another key. The reserved
# prefix list stays in that library; this script only asks it.
# The status path must be nonempty and must not be a symlink. The status line
# must have no embedded newline.
#
# Usage: fm-status-append.sh <status-file> <line>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  --help) usage; exit 0 ;;
esac

[ "$#" -eq 2 ] || { usage >&2; exit 2; }
file=$1
line=$2
case "$line" in
  *$'\n'*) echo "error: status append requires one line without embedded newlines" >&2; exit 1 ;;
esac
[ -n "$file" ] || { echo "error: status file path is empty" >&2; exit 1; }
if [ -L "$file" ]; then
  echo "error: refusing to append through a symlink: $file" >&2
  exit 1
fi

if key=$(_fm_decision_key "$line" '') && [ -n "$key" ] && prefix=$(fm_classify_reserved_key_prefix "$key"); then
  echo "error: key '$key' starts with reserved prefix '$prefix' owned by bin/fm-classify-lib.sh; pick another key" >&2
  exit 1
fi

printf '%s\n' "$line" >> "$file"
