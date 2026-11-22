#!/usr/bin/env bash
# fm-bearings-helper.sh - prepare and send one advisory helper request.
#
# Usage:
#   fm-bearings-helper.sh roster
#   fm-bearings-helper.sh task <owner> <task-id>
#   fm-bearings-helper.sh prepare <source-id> <sequence> <position> [verified-prerequisite]
#   fm-bearings-helper.sh send --confirmed '<exact prepare JSON>'
#
# roster prints a JSON array of roles from the configured delivery registry.
# task prints the authoritative tasks-axi record as JSON.
# prepare prints one read-only plan for a 1-based assignment position. An
# optional prerequisite is for a prose condition the supervisor verified from
# the task record. Structured blockers and holds are included automatically.
# send accepts the plan only after trusted-chat approval. It re-reads the
# captured choice, task and delivery route, requires the exact approved plan,
# and publishes one advisory note. Keep the board wake pending until the
# separate runner acknowledgment succeeds.
set -eu
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
export FM_HOME
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

fail() {
  printf 'fm-bearings-helper: %s\n' "$*" >&2
  exit 1
}

delivery_inbox() {
  local path
  path=$(awk '{sub(/#.*/, ""); sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); if (length) {print; exit}}' \
    "$CONFIG/packet-router-inbox") || return 1
  case "$path" in /*) ;; *) return 1 ;; esac
  path=$(CDPATH='' cd -- "$path" && pwd -P) || return 1
  case "$path" in */inbox/new) printf '%s\n' "$path" ;; *) return 1 ;; esac
}

roster() {
  # Honor an explicit status column when present. Other seat tables identify
  # routes by a role and its bound hand. Never publish the hand to the board.
  awk -F '|' '
    /^[[:space:]]*\|/ {
      for (i = 2; i < NF; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
      }
      if (tolower($2) == "role") {
        hand = 0; status = 0
        for (i = 3; i < NF; i++) {
          if (tolower($i) == "hand" || tolower($i) == "current hand") hand = i
          if (tolower($i) == "state" || tolower($i) == "status") status = i
        }
        next
      }
      if ($2 !~ /^[A-Za-z0-9._-]+$/ || $2 ~ /^-+$/ || length($2) > 128) next
      if (!hand) next
      count[$2]++
      if ($(hand) != "" && $(hand) != "-" &&
          (!status || tolower($(status)) == "active")) active[$2] = 1
    }
    END {for (role in active) if (count[role] == 1) print role}
  ' "${1%/inbox/new}/registry/SEATS.md" | jq -Rsc 'split("\n") | map(select(length > 0)) | sort'
}

task_record() {
  local owner=$1 task=$2 data=$DATA
  [[ "$task" =~ ^[A-Za-z0-9._-]{1,128}$ && "$task" != -* ]] || return 1
  if [ "$owner" != '(main)' ]; then
    secondmate_registry_line_for_id "$DATA/secondmates.md" "$owner" || return 1
    if [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ]; then
      "$SCRIPT_DIR/fm-on.sh" "$owner" fm-bearings-helper.sh task '(main)' "$task" |
        jq -ce --arg host "$SECONDMATE_REGISTRY_HOST" '. + {route_host:$host}'
      return
    fi
    case "$SECONDMATE_REGISTRY_HOME" in /*) ;; *) return 1 ;; esac
    data="$SECONDMATE_REGISTRY_HOME/data"
  fi
  data=$(fm_backlog_data_absolute "$data") || return 1
  fm_backlog_row_show "$data" "$task" --full | jq -Rces --arg id "$task" --arg data "$data" '
    def scalar: if startswith("\"") then fromjson else . end;
    split("\n") | map(capture("^  (?<key>[a-z_]+): (?<value>.*)$")? | .value |= scalar)
    | from_entries | select(.id == $id and (.state | type == "string")) | . + {backlog_data:$data}
  '
}

check_request_key() {
  local board board_id
  board=$("$SCRIPT_DIR/fm-bearings-board.sh" path) || return 1
  board_id=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$board") || return 1
  [ "$1" = "$board_id" ] && [[ "$2" =~ ^(0|[1-9][0-9]{0,15})$ && "$3" =~ ^[1-9][0-9]{0,5}$ ]]
}

receipt_path() {
  printf '%s/%s.%s.helper-%s.sent\n' "$(fm_procevent_inbox_dir "$STATE")" "$1" "$2" "$3"
}

prepare() {
  local source=$1 seq=$2 position=$3 condition=${4:-} result receipt assignments choice
  local owner task role inbox roles fields
  check_request_key "$source" "$seq" "$position" || fail "invalid Bearings request key"
  result="$(fm_procevent_inbox_dir "$STATE")/$source.$seq.result"
  [ "$(fm_procevent_result_adapter "$result")" = lavish ] || fail "no captured Bearings result"
  ! fm_procevent_is_handled "$STATE" "$source" "$seq" || fail "wake already acknowledged"
  receipt=$(receipt_path "$source" "$seq" "$position")
  if [ -e "$receipt" ] || [ -L "$receipt" ]; then
    fail "a delivery receipt already exists for this request"
  fi
  assignments=$("$SCRIPT_DIR/fm-procevent-lavish.sh" assignments "$result") || fail "cannot read helper requests"
  choice=$(jq -cse --argjson pos "$position" '.[$pos - 1]' <<< "$assignments") || fail "no helper at this position"
  owner=$(jq -r .owner <<< "$choice")
  task=$(jq -r .question <<< "$choice")
  role=$(jq -r .agent <<< "$choice")
  fields=$(task_record "$owner" "$task") || fail "cannot verify $task in $owner's current backlog"
  jq -e --arg task "$task" '.id == $task and .state == "queued"' <<< "$fields" >/dev/null ||
    fail "$task is no longer queued"
  jq -e --arg condition "$condition" '
    if $condition != "" then (.body | contains($condition))
    else .blocked == "yes" or (.held == "yes" and (.hold_reason | length > 0) and .hold_reason != "-")
    end
  ' <<< "$fields" >/dev/null || fail "no verified unmet start condition for $task"
  inbox=$(delivery_inbox) || fail "cannot verify the configured Packet Router inbox"
  roles=$(roster "$inbox") || fail "cannot read the delivery registry"
  jq -e --arg role "$role" 'index($role) != null' <<< "$roles" >/dev/null ||
    fail "$role is not an eligible role at the configured inbox"
  jq -cS --arg source "$source" --arg seq "$seq" --arg pos "$position" \
    --arg inbox "$inbox" --arg condition "$condition" --argjson task "$fields" '
      . + {source:$source, sequence:$seq, position:$pos, inbox:$inbox,
           backlog_data:$task.backlog_data, route_host:($task.route_host // null),
           title:$task.title, prerequisite:$condition,
           blockers:(if $task.blocked == "yes" then $task.blocked_by else "" end),
           hold:(if $task.held == "yes" then $task.hold_reason else "" end),
           until:(if $task.held == "yes" and $task.hold_until != "-" then $task.hold_until else "" end)}
    ' <<< "$choice"
}

send_confirmed() {
  local approved source seq position condition current dest packet id receipt created
  approved=$(jq -cSe 'select(type == "object")' <<< "$1") || fail "an exact prepared plan is required"
  source=$(jq -r .source <<< "$approved")
  seq=$(jq -r .sequence <<< "$approved")
  position=$(jq -r .position <<< "$approved")
  condition=$(jq -r .prerequisite <<< "$approved")
  check_request_key "$source" "$seq" "$position" || fail "invalid Bearings request key"
  STATE=$(fm_procevent_state_root_resolve "$STATE") || fail "cannot verify process-event state"
  fm_procevent_private_directory_valid "$(fm_procevent_inbox_dir "$STATE")" 1 ||
    fail "cannot verify process-event inbox"
  fm_procevent_source_lock_acquire "$source" || fail "cannot lock the Bearings source"
  SEND_SOURCE=$source
  RECEIPT_TMP=''
  INBOX_TMP=''
  trap 'if [ -n "$INBOX_TMP" ]; then rm -f -- "$INBOX_TMP"; fi
        if [ -n "$RECEIPT_TMP" ]; then rm -f -- "$RECEIPT_TMP"; fi
        fm_procevent_source_lock_release "$SEND_SOURCE"' EXIT
  id="fm-helper-$source-$seq-$position"
  receipt=$(receipt_path "$source" "$seq" "$position")
  if [ -f "$receipt" ] && [ ! -L "$receipt" ] && [ "$(cat "$receipt")" = "$approved" ]; then
    printf 'already-sent: %s\n' "$id"
    return
  fi
  current=$(prepare "$source" "$seq" "$position" "$condition") || exit 1
  [ "$current" = "$approved" ] || fail "request changed since confirmation; prepare a new plan"
  dest="$(jq -r .inbox <<< "$current")/$id.md"
  created=$(TZ=America/Los_Angeles date '+%Y-%m-%dT%H:%M:%S')
  packet=$(jq -r --arg id "$id" --arg created "$created" '
    ["---", "type: continuum-packet", "schema: packet-router/v1", "kind: note",
     "id: \($id)", "from: firstmate", "role_target: \(.agent | @json)", "ask_of: \(.agent | @json)",
     "created_at_pt: \($created | @json)", "ttl_hours: 2", "priority: normal",
     "status: new", "read_only: true", "dedupe_key: \($id | @json)", "---", "",
     "Please send Firstmate evidence or recommendations to help meet these start conditions.",
     "", "Task: \(.title) (\(.question), owner \(.owner))",
     (if .blockers != "" then "Open blockers: \(.blockers)" else empty end),
     (if .hold != "" then "Hold: \(.hold)" else empty end),
     (if .until != "" then "Hold until: \(.until)" else empty end),
     (if .prerequisite != "" then "Prerequisite: \(.prerequisite)" else empty end),
     "", "Bearings request: \(.source) sequence \(.sequence) assignment \(.position)"] | .[]
  ' <<< "$current")
  RECEIPT_TMP=$(umask 077; mktemp "${receipt%/*}/.fm-helper.XXXXXX") || fail "cannot stage delivery receipt"
  printf '%s\n' "$current" > "$RECEIPT_TMP" || fail "cannot stage delivery receipt"
  current=$(prepare "$source" "$seq" "$position" "$condition") || exit 1
  [ "$current" = "$approved" ] || fail "request changed since confirmation; prepare a new plan"
  # Stage on the destination filesystem only after the final eligibility check.
  INBOX_TMP=$(umask 077; mktemp "${dest%/*}/.fm-helper.XXXXXX") || fail "cannot stage advisory note in the inbox"
  printf '%s\n' "$packet" > "$INBOX_TMP" || fail "cannot write advisory note"
  perl -e 'link($ARGV[0], $ARGV[1]) or exit 1' -- "$INBOX_TMP" "$dest" ||
    fail "cannot publish advisory note"
  perl -e 'link($ARGV[0], $ARGV[1]) or exit 1' -- "$RECEIPT_TMP" "$receipt" ||
    fail "note entered the inbox, but its local delivery receipt could not be saved"
  printf 'sent: %s\n' "$dest"
}

case "${1:-}" in
  roster)
    if inbox=$(delivery_inbox 2>/dev/null) && roles=$(roster "$inbox" 2>/dev/null); then
      printf '%s\n' "$roles"
    else
      printf '[]\n'
    fi ;;
  task) [ "$#" -eq 3 ] || fail "expected owner and task id"; task_record "$2" "$3" ;;
  prepare) shift; [ "$#" -eq 3 ] || [ "$#" -eq 4 ] || fail "expected source, sequence and assignment position"; prepare "$@" ;;
  send) [ "$#" -eq 3 ] && [ "$2" = --confirmed ] || fail "trusted-chat confirmation and the exact prepared plan are required"
    send_confirmed "$3" ;;
  -h|--help|help) awk 'NR == 1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0" ;;
  *) fail "use --help for command usage" ;;
esac
