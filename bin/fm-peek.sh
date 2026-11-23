#!/usr/bin/env bash
# Print the tail of a crewmate endpoint (bounded, for cheap diagnosis).
# Usage: fm-peek.sh <target> [lines=40]
#   <target> may be an exact task id, a legacy fm-<id> task label resolved
#   through this home's state/<id>.meta, or an explicit backend target.
# A recorded Herdr pane must pass fm-backend.sh's live identity check.
# Select a remote secondmate by task id or label. Its recorded remote_host=
# routes the read over fm-on.sh to fm-remote-secondmate-control.sh, clamped to
# that command's 100-line cap. An unreachable host or unreadable endpoint
# fails loudly naming the host.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

RAW_TARGET=$1
N=${2:-40}

fm_backend_resolve_selector "$RAW_TARGET" "$STATE" >/dev/null
TARGET_META=$FM_BACKEND_RESOLVED_META
if [ -n "$FM_BACKEND_RESOLVED_LABEL" ] && [ -n "$(fm_meta_get "$TARGET_META" remote_host)" ]; then
  REMOTE_ID=${TARGET_META##*/}
  REMOTE_ID=${REMOTE_ID%.meta}
  REMOTE_HOST=$(fm_meta_get "$TARGET_META" remote_host)
  case "$N" in ''|*[!0-9]*|0) N=40 ;; esac
  [ "$N" -le 100 ] || N=100
  if ! FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-on.sh" "$REMOTE_ID" \
    fm-remote-secondmate-control.sh capture "$REMOTE_ID" "$N" < /dev/null; then
    echo "error: could not read the remote pane of $REMOTE_ID on $REMOTE_HOST (host unreachable or endpoint unreadable; the mate is not thereby dead)" >&2
    exit 1
  fi
  exit 0
fi

BACKEND=tmux
TARGET_MODE=
if [ -n "$TARGET_META" ]; then
  BACKEND=$(fm_backend_of_meta "$TARGET_META")
elif [[ "$RAW_TARGET" == *:* ]]; then
  TARGET_MODE=explicit
fi
FM_BACKEND_HERDR_ENDPOINT_META="$TARGET_META" \
  fm_backend_capture "$BACKEND" "$FM_BACKEND_RESOLVED_TARGET" "$N" "$FM_BACKEND_RESOLVED_LABEL" "$TARGET_MODE"
