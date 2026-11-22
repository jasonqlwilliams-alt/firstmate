#!/usr/bin/env bash
# Shared durable publication for confirmed PR outcomes.
#
# This home publishes its own merges and merges detected by its poll.
# This operation publishes the merged poll's local actionable row; the watcher
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
# distinct in queue presentation. The merge is published before the marker
# is committed, so a failed commit stays eligible for at-least-once retry and
# may rarely duplicate rather than leave a merge silent.
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

fm_merge_outcome_commit() {
  local state=$1 id=$2 url=$3 origin=$4 outcome=$5 gen=$6
  if [ "$origin" = poll ]; then
    [ "$id" = "$FM_PR_POLL_SNAPSHOT_ID" ] && [ "$url" = "$FM_PR_POLL_SNAPSHOT_URL" ] || return 4
    gen=$FM_PR_POLL_SNAPSHOT_SPAWN_GEN
  fi
  fm_pr_poll_artifacts_valid "$state" "$id" "$_FM_MERGE_OUTCOME_LIB_DIR/fm-pr-poll.sh" \
    && [ "$FM_PR_DATA_URL" = "$url" ] && [ "$FM_PR_META_SPAWN_GEN" = "$gen" ] || return 4
  if [ "$outcome" = closed-unmerged ] && fm_pr_poll_outcome_recorded "$state" "$id" \
    "$FM_PR_DATA_PROVIDER" "$FM_PR_DATA_HOST" "$FM_PR_DATA_PATH" "$FM_PR_DATA_NUMBER"; then
    return 0
  fi
  fm_pr_poll_outcome_record "$state" "$id" \
    "$FM_PR_DATA_PROVIDER" "$FM_PR_DATA_HOST" "$FM_PR_DATA_PATH" "$FM_PR_DATA_NUMBER" "$outcome"
}

# fm_merge_outcome_report <home> <state> <task-id> <pr-url> <origin> [authority] [outcome] [self-spawn-gen]
#
# <origin> says who observed the merge, because that decides whether the
# existing poll path also needs a local wake:
#   self - this home performed the merge.
#   poll - this home's merge poll detected the merge, so it
#          also wakes this home after any upward hop needed by a secondmate.
# Optional <authority> is yolo or away-grant when the merge ran while the
# away-posture record existed; it is appended to the ledger line. Known audit
# gap: queued merges and a poll that wins direct-merge deduplication publish an
# untagged row because the poll path does not persist merge authority.
# <outcome> defaults to merged. The poll records closed-unmerged locally.
#
# Returns 0 when the merge is reported or the closure is recorded, 2 on an invalid
# request, 3 when this home's role or parent binding cannot be read well enough
# to route a merge, 4 when closure registration no longer matches, and 1 on any
# other recording failure.
fm_merge_outcome_report() {
  local home=$1 state=$2 id=$3 url=$4 origin=$5
  local authority=${6-} suffix=
  local outcome=${7:-merged} gen=${8-}
  local self_rc=0 destination='' lock status=0
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
    merged) ;;
    closed-unmerged)
      [ "$origin" = poll ] && [ -z "$authority" ] || return 2
      ;;
    *) return 2 ;;
  esac

  STATE=$state
  # shellcheck source=bin/fm-wake-lib.sh
  . "$_FM_MERGE_OUTCOME_LIB_DIR/fm-wake-lib.sh"
  if [ "$outcome" = closed-unmerged ]; then
    fm_pr_poll_with_lock "$state" "$id" fm_merge_outcome_commit "$state" "$id" "$url" "$origin" "$outcome" "$gen"
    return $?
  fi
  destination=$(fm_parent_channel_destination "$home" "$state") || self_rc=$?
  case "$self_rc" in
    0) ;;
    1) destination='' ;;
    *) return 3 ;;
  esac
  lock="$state/$id.pr-poll-merge-notified.lock"
  fm_lock_acquire_wait "$lock" || return 1
  if fm_pr_poll_outcome_recorded "$state" "$id" \
    "$provider" "$host" "$path" "$number" merged; then
    # shellcheck disable=SC2034 # Public result consumed by sourcing callers.
    FM_MERGE_OUTCOME_ALREADY_RECORDED=true
    fm_lock_release "$lock"
    return 0
  fi

  if [ -n "$destination" ]; then
    fm_parent_channel_append_once "$destination" \
      "done [key=merged-$id]: merged $id $url$suffix" || status=1
  fi
  if [ "$status" -eq 0 ] && { [ "$origin" = poll ] || [ -z "$destination" ]; }; then
    fm_wake_append check "merged-$id-$url" "check: merge landed: $id $url$suffix" || status=1
  fi
  if [ "$status" -eq 0 ]; then
    fm_pr_poll_with_lock "$state" "$id" fm_merge_outcome_commit "$state" "$id" "$url" "$origin" "$outcome" "$gen" \
      || status=$?
    [ "$status" -ne 4 ] || status=0
  fi
  fm_lock_release "$lock"
  return "$status"
}
