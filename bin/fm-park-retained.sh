#!/usr/bin/env bash
# fm-park-retained.sh - mark a task as parked with its isolated copy retained,
# so the watcher's recorded-endpoint loss report stays silent for it.
#
# Usage:
#   fm-park-retained.sh <task-id> mark     record the mark for a confirmed missing endpoint
#   fm-park-retained.sh <task-id> clear    remove the mark
#
# Operator workflow: docs/watcher-continuity.md#parking-a-task-with-its-copy-retained.
# Park marks apply only to local ordinary tasks. Existing secondmate reporting
# rules still apply. Both actions require an existing task record and a state
# directory that physically resolves within FM_HOME, including when
# FM_STATE_OVERRIDE is set. The state directory, task record, and any existing
# park mark must be non-symlinks. Both actions honor the Pi supervision lease.
# Both actions operate on supervision state, and mark also checks the runtime
# endpoint. The task's copy, branch, and work stay unread and untouched.
#
# <state>/<id>.parked-retained stores backend:target, a tab, and the spawn
# generation. fm_backend_endpoint_park_identity treats a legacy teardown
# stamp like an absent generation, so the mark still applies if teardown
# leaves the stamped record in place. Watcher loss reporting consults the mark
# for that identity.
# Relaunch, cleanup authorization, landed-work checks, backlog holds, and
# decision records keep their own authority. Teardown and interrupted-close
# replay remove the mark when the task record is retired.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
FM_WAKE_NO_MKDIR=1 . "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"

usage() {
  sed -n '/^# Usage:$/,/^#$/ { /^#$/d; s/^# //; p; }' "$0" >&2
  exit 2
}

[ "$#" -eq 2 ] || usage
ID=$1 ACTION=$2
case "$ID" in ''|.*|*[!A-Za-z0-9._-]*) echo "error: invalid task id: $ID" >&2; exit 2 ;; esac
case "$ACTION" in mark|clear) ;; *) usage ;; esac

refuse_path() {
  echo "error: park $ACTION refused: $1" >&2
  exit 1
}

HOME_ROUTE=$FM_HOME
STATE_ROUTE=$STATE
FM_HOME=$(CDPATH='' cd -P -- "$HOME_ROUTE" 2>/dev/null && pwd -P) \
  || refuse_path "cannot resolve the selected home at $HOME_ROUTE"
fm_backlog_directory_present "$STATE_ROUTE" "state directory" || refuse_path "$FM_BACKLOG_TRANSITION_ERROR"
STATE=$(CDPATH='' cd -P -- "$STATE_ROUTE" 2>/dev/null && pwd -P) \
  || refuse_path "cannot resolve state directory at $STATE_ROUTE"
case "$STATE" in
  "$FM_HOME"|"${FM_HOME%/}"/*) ;;
  *) refuse_path "state directory resolves outside this home at $STATE_ROUTE" ;;
esac
FM_STATE_OVERRIDE=$STATE

META="$STATE/$ID.meta"
MARK="$STATE/$ID.parked-retained"
LOCK=$(fm_meta_lock_path "$META") || { echo "error: could not resolve the task record lock" >&2; exit 1; }
CONTROL_LOCK="$STATE/.control-$ID.lock"
TMP=
refuse_busy() {
  echo "error: another lifecycle action is already running for task $ID" >&2
  exit 1
}
require_task_record() {
  [ "$(CDPATH='' cd -P -- "$HOME_ROUTE" 2>/dev/null && pwd -P)" = "$FM_HOME" ] \
    || refuse_path "home directory changed at $HOME_ROUTE"
  fm_backlog_directory_present "$STATE_ROUTE" "state directory" || refuse_path "$FM_BACKLOG_TRANSITION_ERROR"
  [ "$(CDPATH='' cd -P -- "$STATE_ROUTE" 2>/dev/null && pwd -P)" = "$STATE" ] \
    || refuse_path "state directory changed at $STATE_ROUTE"
  fm_backlog_record_present "$META" "task record" "$STATE" || refuse_path "$FM_BACKLOG_TRANSITION_ERROR"
}
cleanup() {
  [ -z "$TMP" ] || rm -f -- "$TMP" || true
  fm_lock_release "$LOCK" || true
  fm_lock_release "$CONTROL_LOCK" || true
  fm_lease_guard_release || true
}
require_task_record
trap cleanup EXIT
fm_lock_try_acquire "$CONTROL_LOCK" same-owner || refuse_busy
require_task_record
INCARNATION=$(fm_backend_endpoint_park_identity "$META") || INCARNATION=
fm_lock_release "$CONTROL_LOCK"
require_task_record
fm_lease_guard "$ID" "park $ACTION (fm-park-retained)" existing-parent || exit 1
fm_lock_try_acquire "$CONTROL_LOCK" same-owner || refuse_busy
fm_lock_acquire_wait "$LOCK" existing-parent || exit 1

require_task_record
if [ "$INCARNATION" != "$(fm_backend_endpoint_park_identity "$META")" ]; then
  echo "error: task $ID's recorded endpoint changed while waiting for its lock" >&2
  exit 1
fi

[ -z "$(fm_meta_get "$META" remote_host)" ] \
  || { echo "error: $ID is placed on a remote host; its endpoint loss is not reported here" >&2; exit 1; }
[ "$(fm_meta_get "$META" kind)" != secondmate ] \
  || { echo "error: $ID is a secondmate; park marks apply to ordinary tasks only" >&2; exit 1; }
if { [ -e "$MARK" ] || [ -L "$MARK" ]; } && ! fm_backlog_record_present "$MARK" "park mark" "$STATE"; then
  refuse_path "$FM_BACKLOG_TRANSITION_ERROR"
fi

if [ "$ACTION" = clear ]; then
  rm -f "$MARK"
  echo "parked-retained: no"
  exit 0
fi

[ -n "$INCARNATION" ] \
  || { echo "error: task $ID records no endpoint to park" >&2; exit 1; }
BACKEND=$(fm_backend_of_meta "$META")
TARGET=$(fm_backend_target_of_meta "$META")
if ! ENDPOINT_STATE=$(FM_BACKEND_HERDR_ENDPOINT_META="$META" \
    fm_backend_agent_state "$BACKEND" "$TARGET" 2>/dev/null) || [ "$ENDPOINT_STATE" != missing ]; then
  echo "error: task $ID's recorded endpoint could not be confirmed missing (${ENDPOINT_STATE:-unreadable})" >&2
  exit 1
fi
TMP=$(mktemp "$STATE/.fm-parked-retained.XXXXXX")
printf '%s\n' "$INCARNATION" > "$TMP"
chmod 0600 "$TMP"
mv -f -- "$TMP" "$MARK"
TMP=
echo "parked-retained: yes"
