# shellcheck shell=bash disable=SC2034
# fm-secondmate-restart-lib.sh - the shared contract for restarting a second
# mate onto the current instruction surface and launch-time wiring. Source only.
#
# Two consumers, one owner:
#   - bin/fm-update.sh decides WHICH live mates belong in the restart set, so it
#     needs the capability test before it prints its action lines.
#   - bin/fm-secondmate-restart.sh performs the pass, so it needs the same test
#     again on its own argv rather than trusting a caller's list.
#
# The capability test is the pre-stop half of the control plane's own refusals
# (bin/fm-control-lib.sh owns those tables): a mate whose recorded backend has
# no recovery-grade agent-state classifier, or whose harness has no verified
# control mechanics, can never have "the old agent stopped and the replacement
# came up" proven for it. Asking here keeps that verdict on the side of the
# transaction where nothing has been touched yet, so an incapable mate is routed
# to the ordinary re-read nudge instead of being stopped for a launch that must
# be refused.
#
# Placement is resolved from the same remote_host= signal bin/fm-send.sh routes
# on, and it changes only the transport: the restart itself is bin/fm-control.sh
# <id> relaunch either way, run here for a local mate and run on the host over
# bin/fm-on.sh for a remote one.

_FM_SECONDMATE_RESTART_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-backend.sh disable=SC1091
. "$_FM_SECONDMATE_RESTART_LIB_DIR/fm-backend.sh"
# shellcheck source=bin/fm-control-lib.sh disable=SC1091
. "$_FM_SECONDMATE_RESTART_LIB_DIR/fm-control-lib.sh"

# The persist request uses only the open-record part of /stow. Bundling a
# memory curation pass would make every instruction update cost far more than
# the reload it is paying for.
# The mate answers through its parent channel, which is what resolves the
# parent-owned reply expectation fm-send arms for a marked request; that
# correlated answer, never the wall clock, is what releases the restart, and
# only when fm_secondmate_persist_outcome reads it as saved.
_FM_SECONDMATE_SAVED_RECEIPT='Saved all open work.'
fm_secondmate_persist_request() {  # <running-harness>
  printf '%s' 'Firstmate was updated and I am about to restart your agent so it comes up on the current instructions and launch-time settings, which drops your conversation but keeps every durable record. Before that, persist the open work you are holding only in this conversation, following the /stow skill'"'"'s "Open-record persistence" section and nothing else from that skill: file a task for each open record that exists only in this conversation, including any captain call you had formed but never registered, and correct any task whose status no longer reflects what you now know. Do NOT run the memory, learnings, or captain-preference sweeps.'
  if [ "$1" = claude ]; then
    printf '%s' ' Also stop every background shell task you started, such as timers or sleep loops, because a running one makes the exit stop at a confirmation that the restart will not answer.'
  fi
  printf ' If all required open work is written down, reply on your parent channel with done [corr=<request id>]: %s Use the correlation ID from this request and keep the receipt text exact. If any required write failed or was skipped, reply with blocked [corr=<request id>]: <reason> and explain what was left unwritten. Only the exact save receipt lets the restart go ahead.' "$_FM_SECONDMATE_SAVED_RECEIPT"
}

# Read the persist answers on <corr_id>'s parent channel. Publishes:
#   FM_SECONDMATE_PERSIST_OUTCOME  saved|not-saved|unclear
#   FM_SECONDMATE_PERSIST_NOTE     the negative or unclear answer's note, if any
# Only a done with the requested save receipt is saved, and any contrary reply
# already on the channel vetoes it.
# blocked, failed, and needs-decision are the status vocabulary's negative
# verbs. Other replies are unclear and also stop the restart.
# The answer is the same correlated parent-channel line for a local and a remote
# mate, so placement plays no part here.
FM_SECONDMATE_PERSIST_OUTCOME=""
FM_SECONDMATE_PERSIST_NOTE=""
fm_secondmate_persist_outcome() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 rec status_file line reply_header
  local decision_tag='\[key=[A-Za-z0-9._-]+\]'
  reply_header="^[[:blank:]]*[A-Za-z][A-Za-z0-9_-]*[[:blank:]]+($decision_tag[[:blank:]]+)?(\[corr=$corr\]|corr=$corr)([[:blank:]]+$decision_tag)?[[:blank:]]*:"
  FM_SECONDMATE_PERSIST_OUTCOME=""
  FM_SECONDMATE_PERSIST_NOTE=""
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  status_file=$(fm_pending_reply_get "$rec" parent_status)
  [ -f "$status_file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ $reply_header ]] || continue
    case "$line" in
      "done [corr=$corr]: $_FM_SECONDMATE_SAVED_RECEIPT"|"done [corr=$corr]: $_FM_SECONDMATE_SAVED_RECEIPT (via-helper)")
        FM_SECONDMATE_PERSIST_OUTCOME=saved
        continue
        ;;
    esac
    FM_SECONDMATE_PERSIST_NOTE=$(status_line_note "$line" | tr -s '[:space:]' ' ')
    case "$(status_line_verb "$line")" in
      blocked|failed|needs-decision) FM_SECONDMATE_PERSIST_OUTCOME=not-saved ;;
      *) FM_SECONDMATE_PERSIST_OUTCOME=unclear ;;
    esac
    return 0
  done < <(grep -F -e "corr=$corr" "$status_file")
  [ "$FM_SECONDMATE_PERSIST_OUTCOME" = saved ]
}

# Resolve one mate's restart capability from its durable record alone.
# Publishes, on success:
#   FM_SECONDMATE_RESTART_PLACEMENT  local|remote
#   FM_SECONDMATE_RESTART_BACKEND    the backend whose classifier must prove the stop
#   FM_SECONDMATE_RESTART_HARNESS    the verified control adapter it runs on
#   FM_SECONDMATE_RESTART_HOST       the configured host (remote placement only)
# and on failure sets FM_SECONDMATE_RESTART_REASON to one operator-readable line.
FM_SECONDMATE_RESTART_PLACEMENT=""
FM_SECONDMATE_RESTART_BACKEND=""
FM_SECONDMATE_RESTART_HARNESS=""
FM_SECONDMATE_RESTART_HOST=""
FM_SECONDMATE_RESTART_REASON=""
fm_secondmate_restart_capable() {  # <meta-file>
  local meta=$1 kind window remote_host backend harness family
  FM_SECONDMATE_RESTART_PLACEMENT=""
  FM_SECONDMATE_RESTART_BACKEND=""
  FM_SECONDMATE_RESTART_HARNESS=""
  FM_SECONDMATE_RESTART_HOST=""
  FM_SECONDMATE_RESTART_REASON=""

  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    FM_SECONDMATE_RESTART_REASON="no durable record for this second mate in this home"
    return 1
  fi
  kind=$(fm_meta_get "$meta" kind)
  if [ "$kind" != secondmate ]; then
    FM_SECONDMATE_RESTART_REASON="the durable record is not a second mate's"
    return 1
  fi
  window=$(fm_meta_get "$meta" window)
  if [ -z "$window" ]; then
    FM_SECONDMATE_RESTART_REASON="the durable record names no endpoint, so there is no agent to replace"
    return 1
  fi
  harness=$(fm_meta_get "$meta" harness)
  remote_host=$(fm_meta_get "$meta" remote_host)
  if [ -n "$remote_host" ]; then
    FM_SECONDMATE_RESTART_PLACEMENT=remote
    FM_SECONDMATE_RESTART_HOST=$remote_host
    # A remote mate's endpoint record lives on its host; the parent's own record
    # names the backend that launch established there, and the remote route
    # accepts nothing but herdr.
    backend=$(fm_meta_get "$meta" remote_backend)
    [ -n "$backend" ] || backend=herdr
  else
    FM_SECONDMATE_RESTART_PLACEMENT=local
    backend=$(fm_backend_of_meta "$meta")
  fi
  FM_SECONDMATE_RESTART_BACKEND=$backend
  if ! fm_control_backend_state_verified "$backend"; then
    FM_SECONDMATE_RESTART_REASON="its runtime cannot prove an agent stopped and came back (backend $backend)"
    return 1
  fi
  if ! family=$(fm_control_harness_family "$harness") \
    || ! fm_control_harness_supported "$family" \
    || ! fm_control_harness_supports_kind "$family" secondmate; then
    FM_SECONDMATE_RESTART_REASON="its worker runtime '${harness:-none}' has no verified restart mechanics for a second mate"
    return 1
  fi
  FM_SECONDMATE_RESTART_HARNESS=$family
  return 0
}
