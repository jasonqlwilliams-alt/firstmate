#!/usr/bin/env bash
# Shared durable, supervisor-facing publication for a confirmed PR outcome.
#
# This home publishes its own merges and the merge poll publishes merges and
# closures through this operation, independently of the agent.
# This operation publishes the poll's local actionable row; the watcher
# immediately delivers that row as observation handling, not a second outcome
# path.
#
# The destination is the home's role, never the caller's choice:
#   - a secondmate home reports upward on its parent channel, resolved and
#     appended through bin/fm-parent-channel-lib.sh in the same
#     "<state> [key=<slug>]: <note>" shape the charter contract defines;
#   - a main home reports to the captain through the durable wake queue.
# A poll observed in a secondmate home also receives a local durable wake after
# the upward write, so the mate can handle its own poll observation.
# No new state file and no new transport are involved.
#
# Normal operation deduplicates the task's latest canonical PR identity through
# the outcome marker owned by bin/fm-pr-lib.sh. Main-home wake keys
# also include that PR identity so distinct PRs for a reused task remain
# distinct in queue presentation. The outcome is published before the marker
# is committed, so a failed commit stays eligible for at-least-once retry and
# may rarely duplicate rather than leave an outcome silent.
#
# Sourced by bin/fm-pr-merge.sh, bin/fm-watch.sh, and tests. No side effects on
# source beyond its sourced libraries.

_FM_MERGE_OUTCOME_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$_FM_MERGE_OUTCOME_LIB_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$_FM_MERGE_OUTCOME_LIB_DIR/fm-parent-channel-lib.sh"

# shellcheck disable=SC2034 # Public result consumed by sourcing callers.
FM_MERGE_OUTCOME_ALREADY_RECORDED=false

# fm_merge_outcome_report <home> <state> <task-id> <pr-url> <origin> [authority] [outcome]
#
# <origin> says who observed the outcome, because that decides whether the
# existing poll path also needs a local wake:
#   self - this home performed the merge.
#   poll - this home's merge poll detected the outcome, so it
#          also wakes this home after any upward hop needed by a secondmate.
# Optional <authority> is yolo or away-grant when the merge ran while the
# away-posture record existed; it is appended to the ledger line. Known audit
# gap: queued merges and a poll that wins direct-merge deduplication publish an
# untagged row because the poll path does not persist merge authority.
# <outcome> defaults to merged. Only the poll can report closed-unmerged.
#
# Returns 0 when the outcome is recorded (or already was), 2 on an invalid
# request, 3 when this home's role or parent binding cannot be read well enough
# to route the outcome, 4 when the captured registration does not match a
# closure, and 1 on any other recording failure.
fm_merge_outcome_report() {
  local home=$1 state=$2 id=$3 url=$4 origin=$5
  local authority=${6-} suffix=
  local outcome=${7:-merged} expected wake_note
  local self_rc=0 destination='' line lock status=0
  local provider host path number
  # shellcheck disable=SC2034 # Sourced wake helpers consume these scoped globals.
  local STATE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
  FM_MERGE_OUTCOME_ALREADY_RECORDED=false
  case "$origin" in self|poll) ;; *) return 2 ;; esac
  case "$authority" in
    yolo|away-grant) suffix=" $authority" ;;
    '') ;;
    *) return 2 ;;
  esac
  fm_pr_task_id_valid "$id" || return 2
  fm_pr_url_parse "$url" || return 2
  provider=$FM_PR_PROVIDER
  host=$FM_PR_HOST
  path=$FM_PR_PATH
  number=$FM_PR_NUMBER
  [ -d "$state" ] && [ ! -L "$state" ] || return 1

  case "$outcome" in
    merged)
      expected=merged
      line="done [key=merged-$id]: merged $id $FM_PR_URL$suffix"
      wake_note="merge landed: $id $FM_PR_URL$suffix"
      ;;
    closed-unmerged)
      [ "$origin" = poll ] && [ -z "$authority" ] || return 2
      # A stale closure observation must not supersede a confirmed merge.
      expected=any
      line="done [key=closed-unmerged-$id]: PR closed without merge: $id $FM_PR_URL"
      wake_note="PR closed without merge: $id $FM_PR_URL"
      ;;
    *) return 2 ;;
  esac

  destination=$(fm_parent_channel_destination "$home" "$state") || self_rc=$?
  case "$self_rc" in
    0) ;;
    1) destination='' ;;
    *) return 3 ;;
  esac

  STATE=$state
  # shellcheck source=bin/fm-wake-lib.sh
  . "$_FM_MERGE_OUTCOME_LIB_DIR/fm-wake-lib.sh"
  lock="$state/$id.pr-poll-merge-notified.lock"
  fm_lock_acquire_wait "$lock" || return 1
  if [ "$outcome" = closed-unmerged ] \
    && { [ "$url" != "$FM_PR_POLL_SNAPSHOT_URL" ] \
      || ! fm_pr_poll_snapshot_matches "$state" "$id" "$_FM_MERGE_OUTCOME_LIB_DIR/fm-pr-poll.sh"; }; then
    fm_lock_release "$lock"
    return 4
  fi
  if fm_pr_poll_outcome_recorded "$state" "$id" \
    "$provider" "$host" "$path" "$number" "$expected"; then
    # shellcheck disable=SC2034 # Public result consumed by sourcing callers.
    FM_MERGE_OUTCOME_ALREADY_RECORDED=true
    fm_lock_release "$lock"
    return 0
  fi

  if [ -n "$destination" ]; then
    fm_parent_channel_append_once "$destination" "$line" || status=1
  fi
  if [ "$status" -eq 0 ] && { [ "$origin" = poll ] || [ -z "$destination" ]; }; then
    fm_wake_append check "$outcome-$id-$FM_PR_URL" "check: $wake_note" || status=1
  fi
  if [ "$status" -eq 0 ]; then
    fm_pr_poll_outcome_record "$state" "$id" \
      "$provider" "$host" "$path" "$number" "$outcome" || status=1
  fi
  fm_lock_release "$lock"
  return "$status"
}
