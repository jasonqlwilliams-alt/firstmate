#!/usr/bin/env bash
# fm-urgent-alert.sh - write one URGENT-ALERT v1 packet into this home's
# Packet Router inbox, when one is configured.
#
# Firstmate drops this packet so Spur can ping the captain when captain-held
# work actually stops progress. Merge-ready work and routine holds are not
# that class; this helper does not decide the class. Callers opt in.
#
# Usage:
#   fm-urgent-alert.sh --task-id <id> --why <text> --blocked <text> --ask <text>
#
# Configuration:
#   config/packet-router-inbox  first non-comment, non-blank line is the
#                               absolute Packet Router inbox/new directory
#                               for this home. LOCAL, gitignored, not
#                               inherited. bin/fm-urgent-alert.sh's header
#                               owns the read and no-op contract.
#
# If that file is absent, empty, or does not name an absolute path, this
# command silently no-ops with exit 0 so an unconfigured home is unaffected.
# When an absolute inbox is configured but the packet is not written (missing
# directory, temp-file, write, or rename failure), it prints one `actionable:`
# line on stderr and still exits 0 so a captain-hold still succeeds.
#
# Environment:
#   FM_HOME                 operational home whose config/ is read.
#   FM_CONFIG_OVERRIDE      alternate config dir, mainly for tests.
#   FM_URGENT_ALERT_NOW     optional created_at_pt override (Pacific clock
#                           string). Absent: America/Los_Angeles now, or
#                           empty when that clock cannot be read.
#
# Output: the written packet path on stdout after a successful write.
# Nothing is printed on an unconfigured no-op. Exit 2 is usage only.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

CONFIG_FILE="packet-router-inbox"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail_usage() {
  printf 'fm-urgent-alert: %s\n' "$*" >&2
  exit 2
}

# First non-comment, non-blank line, or nothing.
read_inbox_setting() {
  local path="$CONFIG/$CONFIG_FILE" line
  [ -r "$path" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    printf '%s' "$line"
    return 0
  done < "$path"
}

yaml_double_quote() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}

validate_slug() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) fail_usage "task-id must be a non-empty privacy-safe slug" ;;
  esac
}

validate_one_line() {
  local label=$1 value=$2
  [ -n "$value" ] || fail_usage "$label must not be empty"
  case "$value" in
    *$'\n'*|*$'\r'*) fail_usage "$label must be one line" ;;
  esac
}

pacific_now() {
  if [ -n "${FM_URGENT_ALERT_NOW:-}" ]; then
    printf '%s' "$FM_URGENT_ALERT_NOW"
    return 0
  fi
  TZ=America/Los_Angeles date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || true
}

report_unwritten() {  # <cause>
  printf 'actionable: URGENT-ALERT for task %s was not written to Packet Router inbox %s (%s)\n' \
    "$task_id" "$inbox" "$1" >&2
}

write_packet() {
  local dest=$1 packet=$2 tmp
  [ -d "$inbox" ] || { report_unwritten "inbox directory is missing"; return 0; }
  tmp=$(umask 077; mktemp "$inbox/.fm-urgent-alert.XXXXXX" 2>/dev/null) \
    || { report_unwritten "could not create a temp file"; return 0; }
  if ! printf '%s\n' "$packet" > "$tmp" 2>/dev/null; then
    rm -f -- "$tmp"
    report_unwritten "could not write the packet"
    return 0
  fi
  if ! mv -f -- "$tmp" "$dest" 2>/dev/null; then
    rm -f -- "$tmp"
    report_unwritten "could not move the packet into place"
    return 0
  fi
  printf '%s\n' "$dest"
}

task_id=''
why=''
blocked=''
ask=''

while [ "$#" -gt 0 ]; do
  case "$1" in
    --task-id) shift; task_id=${1:-} ;;
    --why) shift; why=${1:-} ;;
    --blocked) shift; blocked=${1:-} ;;
    --ask) shift; ask=${1:-} ;;
    -h|--help) usage; exit 0 ;;
    *) fail_usage "unknown argument: $1" ;;
  esac
  shift
done

validate_slug "$task_id"
validate_one_line why "$why"
validate_one_line blocked "$blocked"
validate_one_line ask "$ask"

inbox=$(read_inbox_setting)
case "$inbox" in
  /*) : ;;
  *) exit 0 ;;
esac

packet_id="pkt-urgent-$task_id"
dedupe_key="fm:$task_id"
created_at_pt=$(pacific_now)
dest="$inbox/${packet_id}.md"

packet=$(printf '%s\n' \
  '---' \
  'type: continuum-packet' \
  'schema: packet-router/v1' \
  'kind: urgent-alert' \
  "id: $packet_id" \
  'from: firstmate' \
  'role_target: spur' \
  'priority: high' \
  'ask_of: spur' \
  "created_at_pt: $(yaml_double_quote "$created_at_pt")" \
  'ttl_hours: 6' \
  "dedupe_key: $(yaml_double_quote "$dedupe_key")" \
  'source_class: H' \
  '---' \
  '' \
  'URGENT-ALERT v1' \
  "dedupe_key: $dedupe_key" \
  "source: firstmate / $task_id" \
  'class: H' \
  "why: $why" \
  "blocked: $blocked" \
  "ask: $ask" \
  'action_hint: Answer the captain hold' \
  'link:')

write_packet "$dest" "$packet" || true
exit 0
