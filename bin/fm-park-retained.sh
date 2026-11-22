#!/usr/bin/env bash
# fm-park-retained.sh - mark a task as parked with its isolated copy retained,
# so the watcher's recorded-endpoint loss report stays silent for it.
#
# Usage:
#   fm-park-retained.sh <task-id> mark     record the mark for a confirmed missing endpoint
#   fm-park-retained.sh <task-id> clear    remove the mark
#
# Use it when a task's worker window was deliberately closed while its copy and
# unlanded work are kept for later. The mark is the file
# <state>/<id>.parked-retained holding the task record's endpoint incarnation
# (backend, target, and spawn generation; bin/fm-backend.sh's
# fm_backend_endpoint_park_identity). bin/fm-watch.sh skips the loss report only
# while that content equals the record's current incarnation, so a relaunch or
# resume, which records a new spawn generation, makes an old mark inert and the
# resumed worker's loss alerts again. `clear` restores normal reporting
# eligibility with the existing loss deduplication.
#
# The mark is advisory to loss reporting only. It never reads or changes the
# task's copy, branch, or work, and relaunch, cleanup, the landed-work checks,
# backlog holds, and decision records ignore it. bin/fm-teardown.sh removes it
# with the task record. A remote secondmate or secondmate record is refused:
# neither reaches the local loss report this mark governs.
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
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"

usage() { sed -n '4,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

[ "$#" -eq 2 ] || usage
ID=$1 ACTION=$2
case "$ID" in ''|.*|*[!A-Za-z0-9._-]*) echo "error: invalid task id: $ID" >&2; exit 2 ;; esac
case "$ACTION" in mark|clear) ;; *) usage ;; esac

META="$STATE/$ID.meta"
MARK="$STATE/$ID.parked-retained"
[ -f "$META" ] && [ ! -L "$META" ] || { echo "error: no task record for $ID" >&2; exit 1; }
INCARNATION=$(fm_backend_endpoint_park_identity "$META") || INCARNATION=

LOCK=$(fm_meta_lock_path "$META") || { echo "error: could not resolve the task record lock" >&2; exit 1; }
CONTROL_LOCK="$STATE/.control-$ID.lock"
TMP=
refuse_busy() {
  echo "error: another lifecycle action is already running for task $ID" >&2
  exit 1
}
cleanup() {
  [ -z "$TMP" ] || rm -f -- "$TMP" || true
  fm_lock_release "$LOCK" || true
  fm_lock_release "$CONTROL_LOCK" || true
  fm_lease_guard_release || true
}
if fm_pid_alive "$(cat "$CONTROL_LOCK/pid" 2>/dev/null || true)"; then
  refuse_busy
fi
trap cleanup EXIT
fm_lease_guard "$ID" "park $ACTION (fm-park-retained)"
fm_lock_try_acquire "$CONTROL_LOCK" || refuse_busy
fm_lock_acquire_wait "$LOCK"

if [ ! -f "$META" ] || [ -L "$META" ] \
   || [ "$INCARNATION" != "$(fm_backend_endpoint_park_identity "$META")" ]; then
  echo "error: task $ID's recorded endpoint changed while waiting for its lock" >&2
  exit 1
fi

if [ "$ACTION" = clear ]; then
  rm -f "$MARK"
  echo "parked-retained: no"
  exit 0
fi

[ -z "$(fm_meta_get "$META" remote_host)" ] \
  || { echo "error: $ID is placed on a remote host; its endpoint loss is not reported here" >&2; exit 1; }
[ "$(fm_meta_get "$META" kind)" != secondmate ] \
  || { echo "error: $ID is a secondmate; park marks apply to ordinary tasks only" >&2; exit 1; }
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
