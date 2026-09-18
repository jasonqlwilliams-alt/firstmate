#!/usr/bin/env bash
# fm-system-state-card.sh - generate the live SYSTEM_STATE card from probes.
#
# Builds a versioned markdown overlay of what is live now (revisions, runtime
# flags, copied routing text, active holds, SoT map, recent 7d changes) with
# TTL 60m and no model tokens. Agents read this card instead of browsing Atlas
# or C:\continuum-system for those facts. Vault remains SOPs; Northstar remains
# outcomes.
#
# Usage:
#   fm-system-state-card.sh [--stdout] [--no-write] [--no-inherit]
#                           [--no-packet] [--rakazo-pointer]
#   fm-system-state-card.sh --pointer
#   fm-system-state-card.sh --help
#
# --pointer   Print one session-start line for the existing card. No probes,
#             no writes, no network.
# --stdout    Also print the generated card to stdout.
# --no-write  Do not write data/system-state.md (still prints when --stdout).
# --no-inherit
#             Do not copy the card into local secondmate homes listed in
#             data/secondmates.md.
# --no-packet Do not drop an Eleusis named-C: publish packet even when
#             config/packet-router-inbox is configured.
# --rakazo-pointer
#             Include the one-line Atlas and Eleusis bots.instructions pointer
#             on the Eleusis packet (locked patch path). No-op without an inbox.
#
# Writes:
#   $FM_HOME/data/system-state.md   home-local, gitignored, regenerated in place
#   local secondmate data/system-state.md copies unless --no-inherit
#   Packet Router inbox packet to role_target eleusis, naming Evidence/SYSTEM_STATE.md
#     (and DISCOVERY.md) as the named C: target, when the inbox is configured
#
# Probe list and section order are owned here (freshness scout section 3).
# Missing probes print unavailable; they never fail the generate.
# Target size is at most 80 lines.
#
# Environment (tests and specialized homes):
#   FM_HOME FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE
#   FM_SYSTEM_STATE_NOW            RFC3339 UTC generated_at override
#   FM_SYSTEM_STATE_TTL_SECS       TTL in seconds (default 3600)
#   FM_SYSTEM_STATE_HOST           generator host override
#   FM_SYSTEM_STATE_CONTINUUM_HEALTH_URL
#   FM_SYSTEM_STATE_TENT_URL
#   FM_SYSTEM_STATE_RAKAZO_HEALTH_URL
#   FM_SYSTEM_STATE_RAKAZO_UI_URL
#   FM_SYSTEM_STATE_S_ROOT
#   FM_SYSTEM_STATE_VAULT_ROOT
#   FM_SYSTEM_STATE_PACKET_ROUTER_ROOT
#   FM_SYSTEM_STATE_RAKAZO_GIT
#   FM_SYSTEM_STATE_CONTINUUM_MAIN_GIT
#   FM_SYSTEM_STATE_CONTINUUM_UI_GIT
#   FM_SYSTEM_STATE_NORTHSTAR_PATH
#   FM_SYSTEM_STATE_CURL_MAX_TIME  curl --max-time seconds (default 3)
#
# Output: the written card path on stdout after a successful write, unless
# --stdout (card body) or --pointer (one status line) or --no-write without
# --stdout (nothing). Exit 2 is usage only.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CARD_REL="data/system-state.md"
CARD_PATH="$DATA/system-state.md"
TTL_SECS="${FM_SYSTEM_STATE_TTL_SECS:-3600}"
CURL_MAX="${FM_SYSTEM_STATE_CURL_MAX_TIME:-3}"
CARD_LINE_CAP=80
POINTER_HINT='(load system-state-card; do not browse Atlas for live rev/hold/routing)'

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail_usage() {
  printf 'fm-system-state-card: %s\n' "$*" >&2
  exit 2
}

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    printf 'unavailable'
  fi
}

utc_now() {
  if [ -n "${FM_SYSTEM_STATE_NOW:-}" ]; then
    printf '%s' "$FM_SYSTEM_STATE_NOW"
    return 0
  fi
  date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf 'unavailable'
}

host_name() {
  if [ -n "${FM_SYSTEM_STATE_HOST:-}" ]; then
    printf '%s' "$FM_SYSTEM_STATE_HOST"
    return 0
  fi
  uname -n 2>/dev/null || printf 'unknown'
}

unavailable() { printf 'unavailable'; }

# First non-comment, non-blank line, or nothing.
read_inbox_setting() {
  local path="$CONFIG/packet-router-inbox" line
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

file_excerpt() {  # <path> <max-lines>
  local path=$1 max=$2
  if [ ! -f "$path" ]; then
    printf 'unavailable (absent)\n'
    return 0
  fi
  if [ ! -s "$path" ]; then
    printf '(present, empty)\n'
    return 0
  fi
  awk -v max="$max" '
    NR <= max { print; next }
    { extra++ }
    END {
      if (extra > 0) printf "... truncated %s more lines; see the source file\n", extra
    }
  ' "$path"
}

section_excerpt() {  # <path> <heading-regex> <max-lines>
  local path=$1 heading=$2 max=$3
  if [ ! -f "$path" ]; then
    printf 'unavailable (absent)\n'
    return 0
  fi
  awk -v heading="$heading" -v max="$max" '
    BEGIN { want = 0; n = 0 }
    $0 ~ heading { want = 1 }
    want && n > 0 && /^## / && $0 !~ heading { exit }
    want {
      print
      n++
      if (n >= max) {
        printf "... truncated; see the source file\n"
        exit
      }
    }
    END { if (n == 0) print "unavailable (section absent)" }
  ' "$path"
}

git_one() {  # <repo> [format]
  local repo=$1 fmt=${2:-%H %ci %s}
  if [ -z "$repo" ] || [ ! -d "$repo" ]; then
    unavailable
    return 0
  fi
  git -C "$repo" log -1 --format="$fmt" 2>/dev/null || unavailable
}

git_recent() {  # <repo> <label>
  local repo=$1 label=$2 out
  if [ -z "$repo" ] || [ ! -d "$repo" ]; then
    printf '%s: unavailable\n' "$label"
    return 0
  fi
  out=$(git -C "$repo" log --since='7 days ago' --format='%h %s' -5 2>/dev/null || true)
  if [ -z "$out" ]; then
    printf '%s: none in 7d\n' "$label"
    return 0
  fi
  printf '%s:\n' "$label"
  printf '%s\n' "$out" | awk '{printf "  %s\n", $0}'
}

curl_body() {  # <url>
  local url=$1 body
  [ -n "$url" ] || { unavailable; return 0; }
  body=$(curl -sS --connect-timeout "$CURL_MAX" --max-time "$CURL_MAX" "$url" 2>/dev/null || true)
  if [ -z "$body" ]; then
    unavailable
    return 0
  fi
  printf '%s' "$body"
}

curl_code() {  # <url>
  local url=$1 code
  [ -n "$url" ] || { printf 'unavailable'; return 0; }
  code=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout "$CURL_MAX" --max-time "$CURL_MAX" "$url" 2>/dev/null || true)
  if [ -z "$code" ]; then
    printf 'unavailable'
    return 0
  fi
  printf '%s' "$code"
}

parse_health() {  # stdin JSON -> six lines: revision status env hold jobs urgent
  if ! command -v python3 >/dev/null 2>&1; then
    printf 'unavailable\nunavailable\nunavailable\nunavailable\nunavailable\nunavailable\n'
    return 0
  fi
  python3 -c '
import json, sys
try:
    raw = sys.stdin.read()
    o = json.loads(raw) if raw.strip() else {}
except Exception:
    o = {}
def g(*keys):
    cur = o
    for k in keys:
        if isinstance(cur, dict) and k in cur:
            cur = cur[k]
        else:
            return "unavailable"
    if cur is True:
        return "true"
    if cur is False:
        return "false"
    if cur is None:
        return "unavailable"
    return str(cur)
rev = g("revision")
status = g("status")
env = g("environment")
hold = g("backgroundJobs", "globalHold")
if hold == "unavailable":
    hold = g("globalHold")
jobs = g("jobs_count")
if jobs == "unavailable":
    jobs = g("backgroundJobs", "count")
urgent = g("URGENT_CAPTAIN_ALERTS_ENABLED")
if urgent == "unavailable":
    urgent = g("urgentCaptainAlertsEnabled")
print(rev)
print(status)
print(env)
print(hold)
print(jobs)
print(urgent)
'
}

ui_bundles() {
  local root=$1 match
  if [ -z "$root" ] || [ ! -d "$root/ui-dist/assets" ]; then
    unavailable
    return 0
  fi
  match=$(find "$root/ui-dist/assets" -maxdepth 1 -name 'index-*.js' 2>/dev/null | while IFS= read -r f; do
    basename "$f"
  done | LC_ALL=C sort | paste -sd, -)
  if [ -z "$match" ]; then
    unavailable
    return 0
  fi
  printf '%s' "$match"
}

exists_flag() {
  if [ -e "$1" ]; then
    printf 'exists'
  else
    printf 'absent'
  fi
}

secondmate_summary() {
  local path="$DATA/secondmates.md" ids count=0
  if [ ! -f "$path" ]; then
    printf 'count=0 ids=absent'
    return 0
  fi
  ids=$(awk '
    /^[-] [A-Za-z0-9._-]+ - / {
      id = $2
      printf "%s ", id
      n++
    }
    END { }
  ' "$path")
  ids=${ids%% }
  count=$(printf '%s\n' "$ids" | awk '{print NF}')
  printf 'count=%s ids=%s' "$count" "${ids:-none}"
}

active_holds() {
  local file="$DATA/backlog.md"
  if [ ! -f "$file" ]; then
    printf 'unavailable (no backlog)\n'
    return 0
  fi
  awk '
    /^## / {
      heading = $0
      sub(/^##[[:space:]]+/, "", heading)
      in_done = (heading == "Done")
      next
    }
    in_done { next }
    /hold-kind:[[:space:]]*captain/ {
      line = $0
      sub(/^[-*][[:space:]]+\[[ xX]\][[:space:]]+/, "", line)
      print line
      n++
      if (n >= 8) {
        extra = 1
        exit
      }
    }
    END {
      if (n == 0) print "(none recorded in backlog)"
      else if (extra) print "... truncated; see data/backlog.md"
    }
  ' "$file"
}

seats_rows() {
  local path=$1 out
  if [ ! -f "$path" ]; then
    printf 'unavailable'
    return 0
  fi
  out=$(awk -F '|' '
    /^[|]/ && $2 ~ /[a-z]/ && $2 !~ /role/ {
      role = $2; hand = $3
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", role)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", hand)
      if (role != "" && role != "role") {
        printf "%s=%s\n", role, hand
        n++
        if (n >= 8) exit
      }
    }
  ' "$path")
  if [ -z "$out" ]; then
    printf 'unavailable'
    return 0
  fi
  printf '%s' "$out" | paste -sd, -
}

packet_router_recent() {
  local root=$1 line
  if [ ! -f "$root/wake-log.md" ]; then
    printf 'packet_router: unavailable\n'
    return 0
  fi
  line=$(grep -E 'lock|CAPTAIN-ANSWER|LOCKED|locked' "$root/wake-log.md" 2>/dev/null | tail -n 1 || true)
  if [ -z "$line" ]; then
    line=$(tail -n 1 "$root/wake-log.md" 2>/dev/null || true)
  fi
  if [ -z "$line" ]; then
    printf 'packet_router: unavailable\n'
    return 0
  fi
  printf 'packet_router: %s\n' "$line" | awk '{
    s = $0
    if (length(s) > 160) s = substr(s, 1, 157) "..."
    print s
  }'
}

cap_text() {  # <max-lines>  stdin -> stdout, never more than max lines
  local max=$1
  awk -v max="$max" '
    NR < max { print; next }
    NR == max { buf = $0; next }
    { extra++ }
    END {
      if (extra > 0) printf "... truncated %s more lines\n", extra + 1
      else if (buf != "") print buf
    }
  '
}

age_seconds() {  # <rfc3339>
  local ts=$1
  if ! command -v python3 >/dev/null 2>&1; then
    printf '-1'
    return 0
  fi
  python3 -c '
import sys, datetime
raw = sys.argv[1].strip()
if raw.endswith("Z"):
    raw = raw[:-1] + "+00:00"
try:
    then = datetime.datetime.fromisoformat(raw)
    if then.tzinfo is None:
        then = then.replace(tzinfo=datetime.timezone.utc)
    now = datetime.datetime.now(datetime.timezone.utc)
    secs = int((now - then).total_seconds())
    print(max(0, secs))
except Exception:
    print(-1)
' "$ts"
}

print_pointer() {
  local generated ttl_field sha status age_s age_m ttl_m
  if [ ! -f "$CARD_PATH" ]; then
    printf 'SYSTEM_STATE: %s status=absent (run bin/fm-system-state-card.sh; %s)\n' \
      "$CARD_REL" "$POINTER_HINT"
    return 0
  fi
  generated=$(awk -F': ' '/^generated_at:/{print $2; exit}' "$CARD_PATH")
  ttl_field=$(awk -F': ' '/^ttl:/{print $2; exit}' "$CARD_PATH")
  sha=$(awk -F': ' '/^sha256:/{print $2; exit}' "$CARD_PATH")
  if [ -z "$generated" ] || [ -z "$sha" ]; then
    printf 'SYSTEM_STATE: %s status=unreadable (%s)\n' "$CARD_REL" "$POINTER_HINT"
    return 0
  fi
  age_s=$(age_seconds "$generated")
  ttl_m=$((TTL_SECS / 60))
  case "$ttl_field" in
    *m) ttl_m=${ttl_field%m} ;;
  esac
  if [ "$age_s" -lt 0 ]; then
    status=unreadable
    age_m='?'
  else
    age_m=$((age_s / 60))
    if [ "$age_s" -gt "$TTL_SECS" ]; then
      status=stale
    else
      status=fresh
    fi
  fi
  printf 'SYSTEM_STATE: %s status=%s generated_at=%s age=%sm ttl=%sm sha256=%s %s\n' \
    "$CARD_REL" "$status" "$generated" "$age_m" "$ttl_m" "$sha" "$POINTER_HINT"
}

yaml_double_quote() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}

write_atomic() {  # <dest> <contents>
  local dest=$1 contents=$2 parent tmp
  parent=$(dirname "$dest")
  mkdir -p "$parent"
  tmp=$(umask 077; mktemp "$parent/.system-state.XXXXXX")
  if ! printf '%s\n' "$contents" > "$tmp"; then
    rm -f -- "$tmp"
    printf 'fm-system-state-card: could not write %s\n' "$dest" >&2
    return 1
  fi
  if ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    printf 'fm-system-state-card: could not move %s into place\n' "$dest" >&2
    return 1
  fi
}

inherit_local_secondmates() {  # <card-contents>
  local contents=$1 line dest
  [ -f "$DATA/secondmates.md" ] || return 0
  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  . "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    secondmate_registry_parse_line "$line" || continue
    [ "${SECONDMATE_REGISTRY_REMOTE:-0}" = 0 ] || continue
    dest="${SECONDMATE_REGISTRY_HOME:-}/data/system-state.md"
    case "$dest" in
      /data/system-state.md) continue ;;
    esac
    [ "$dest" = "$CARD_PATH" ] && continue
    [ -d "$(dirname "$dest")" ] || continue
    write_atomic "$dest" "$contents" || true
  done < "$DATA/secondmates.md"
}

write_eleusis_packet() {  # <card> <rakazo-pointer 0|1>
  local card=$1 rakazo=$2 inbox dest tmp packet_id created ask
  inbox=$(read_inbox_setting)
  case "$inbox" in
    /*) : ;;
    *) return 0 ;;
  esac
  [ -d "$inbox" ] || {
    printf 'actionable: SYSTEM_STATE packet was not written to Packet Router inbox %s (inbox directory is missing)\n' \
      "$inbox" >&2
    return 0
  }
  packet_id="pkt-system-state-$(utc_now | tr -d ':-')"
  packet_id=${packet_id%Z}
  created=$(TZ=America/Los_Angeles date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || utc_now)
  dest="$inbox/${packet_id}.md"
  if [ "$rakazo" -eq 1 ]; then
    ask=$(printf '%s\n' \
      '- Write the card body below to C:\\Continuum\\_PacketRouter\\Evidence\\SYSTEM_STATE.md (named C: target; overwrite).' \
      '- If DISCOVERY.md lacks a SYSTEM_STATE pointer, add one line pointing at Evidence/SYSTEM_STATE.md. Do not copy the card into DISCOVERY.md.' \
      '- Do not write vault 00_Indexes/SYSTEM_STATE.md (needs G2).' \
      '- Locked patch path (Eleusis -> Meridian -> FirstMate -> Rakazo sync): append one line to Atlas (continuum-system / rakazo-continuum) and Eleusis bots.instructions only:' \
      '  Live system state: Packet Router Evidence/SYSTEM_STATE.md (mirror: FirstMate data/system-state.md). TTL 60m. Do not browse C:\\continuum-system for live rev/hold/routing.' \
      '- Do not restore Flux/Thor hollow instructions in this pass.')
  else
    ask=$(printf '%s\n' \
      '- Write the card body below to C:\\Continuum\\_PacketRouter\\Evidence\\SYSTEM_STATE.md (named C: target; overwrite).' \
      '- If DISCOVERY.md lacks a SYSTEM_STATE pointer, add one line pointing at Evidence/SYSTEM_STATE.md. Do not copy the card into DISCOVERY.md.' \
      '- Do not write vault 00_Indexes/SYSTEM_STATE.md (needs G2).')
  fi
  tmp=$(umask 077; mktemp "$inbox/.fm-system-state.XXXXXX" 2>/dev/null) || {
    printf 'actionable: SYSTEM_STATE packet was not written to Packet Router inbox %s (could not create a temp file)\n' \
      "$inbox" >&2
    return 0
  }
  {
    printf '%s\n' \
      '---' \
      'type: continuum-packet' \
      'schema: packet-router/v1' \
      'kind: note' \
      "id: $packet_id" \
      'from: firstmate' \
      'role_target: eleusis' \
      'priority: normal' \
      "created_at_pt: $(yaml_double_quote "$created")" \
      'ttl_hours: 2' \
      'dedupe_key: "fm:system-state-card"' \
      'status: new' \
      'ask_of: eleusis' \
      'read_only: false' \
      'continuum_paths:' \
      '  - C:\Continuum\_PacketRouter\Evidence\SYSTEM_STATE.md' \
      '  - C:\Continuum\_PacketRouter\DISCOVERY.md' \
      'non_goals:' \
      '  - vault 00_Indexes/SYSTEM_STATE.md' \
      '  - Flux/Thor instruction restore' \
      '  - message to Jason' \
      '---' \
      '' \
      '# Intent' \
      '' \
      'Publish the generated SYSTEM_STATE live-facts card so Atlas, Eleusis, Grokbots, and Windows sessions read one file instead of browsing the stale vault.' \
      '' \
      '# Evidence / paths' \
      '' \
      '- Named C: target: C:\Continuum\_PacketRouter\Evidence\SYSTEM_STATE.md' \
      '- Pointer: C:\Continuum\_PacketRouter\DISCOVERY.md (one line, never a copy of the card)' \
      '- Mirror: FirstMate data/system-state.md' \
      '' \
      '# Ask' \
      '' \
      "$ask" \
      '' \
      '# Non-goals' \
      '' \
      '- vault 00_Indexes/SYSTEM_STATE.md' \
      '- Flux/Thor hollow-instruction restore' \
      '- rewriting G1-G4 or Northstar' \
      '' \
      '# Card body' \
      ''
    printf '%s\n' "$card"
  } > "$tmp" 2>/dev/null || {
    rm -f -- "$tmp"
    printf 'actionable: SYSTEM_STATE packet was not written to Packet Router inbox %s (could not write the packet)\n' \
      "$inbox" >&2
    return 0
  }
  if ! mv -f -- "$tmp" "$dest" 2>/dev/null; then
    rm -f -- "$tmp"
    printf 'actionable: SYSTEM_STATE packet was not written to Packet Router inbox %s (could not move the packet into place)\n' \
      "$inbox" >&2
    return 0
  fi
  printf '%s\n' "$dest" >&2
}

build_card() {
  local generated host ttl_m continuum_json rev status env hold jobs urgent
  local s_head vault_head fm_head rakazo_git rakazo_health rakazo_rev
  local tent_code rakazo_ui ui_js gh_main seats_file routing holds sot recent
  local body header digest sha card s_root vault_root pr_root rakazo_git_dir
  local continuum_main_git continuum_ui_git northstar health_url tent_url
  local rakazo_health_url rakazo_ui_url dnb core_max dnb core_max

  generated=$(utc_now)
  host=$(host_name)
  ttl_m=$((TTL_SECS / 60))
  health_url="${FM_SYSTEM_STATE_CONTINUUM_HEALTH_URL:-https://continuum.ngrok.app/health}"
  tent_url="${FM_SYSTEM_STATE_TENT_URL:-https://tent.ngrok.app/}"
  rakazo_health_url="${FM_SYSTEM_STATE_RAKAZO_HEALTH_URL:-http://127.0.0.1:3100/health}"
  rakazo_ui_url="${FM_SYSTEM_STATE_RAKAZO_UI_URL:-http://127.0.0.1:5173/}"
  s_root="${FM_SYSTEM_STATE_S_ROOT:-/mnt/s/continuum-main}"
  vault_root="${FM_SYSTEM_STATE_VAULT_ROOT:-/mnt/c/continuum-system}"
  pr_root="${FM_SYSTEM_STATE_PACKET_ROUTER_ROOT:-/mnt/c/Continuum/_PacketRouter}"
  rakazo_git_dir="${FM_SYSTEM_STATE_RAKAZO_GIT:-$FM_HOME/projects/rakazo}"
  continuum_main_git="${FM_SYSTEM_STATE_CONTINUUM_MAIN_GIT:-$FM_HOME/projects/continuum-main}"
  continuum_ui_git="${FM_SYSTEM_STATE_CONTINUUM_UI_GIT:-$FM_HOME/projects/continuum-ui}"
  northstar="${FM_SYSTEM_STATE_NORTHSTAR_PATH:-$vault_root/01_Charter/Northstar.md}"
  seats_file="$pr_root/registry/SEATS.md"

  continuum_json=$(curl_body "$health_url")
  if [ "$continuum_json" = unavailable ]; then
    rev=unavailable; status=unavailable; env=unavailable
    hold=unavailable; jobs=unavailable; urgent=unavailable
  else
    {
      read -r rev
      read -r status
      read -r env
      read -r hold
      read -r jobs
      read -r urgent
    } <<EOF
$(printf '%s' "$continuum_json" | parse_health)
EOF
  fi
  rakazo_health=$(curl_body "$rakazo_health_url")
  if [ "$rakazo_health" = unavailable ]; then
    rakazo_rev=unavailable
  else
    rakazo_rev=$(printf '%s' "$rakazo_health" | parse_health | awk 'NR==1{print; exit}')
  fi
  tent_code=$(curl_code "$tent_url")
  rakazo_ui=$(curl_code "$rakazo_ui_url")
  s_head=$(git_one "$s_root")
  vault_head=$(git_one "$vault_root" '%H %ci')
  fm_head=$(git_one "$FM_ROOT")
  rakazo_git=$(git_one "$rakazo_git_dir")
  gh_main=$(git_one "$continuum_main_git")
  ui_js=$(ui_bundles "$s_root")

  routing=$(printf '%s\n' \
    '### config/crew-dispatch.json' \
    "$(file_excerpt "$CONFIG/crew-dispatch.json" 10)" \
    '### config/secondmate-harness' \
    "$(file_excerpt "$CONFIG/secondmate-harness" 2)" \
    '### data/captain-shared.md Provider routing' \
    "$(section_excerpt "$DATA/captain-shared.md" '^## Provider routing' 12)")

  holds=$(printf '%s\n' \
    "$(active_holds)" \
    "secondmates: $(secondmate_summary)")

  sot=$(printf '%s\n' \
    "runtime_s: $s_root $(exists_flag "$s_root")" \
    "vault_c: $vault_root $(exists_flag "$vault_root")" \
    "packet_router: $pr_root $(exists_flag "$pr_root")" \
    "firstmate_data: $DATA exists" \
    'rakazo_instructions: bots.instructions (Postgres; pointer only)' \
    "northstar: $northstar $(exists_flag "$northstar")" \
    'secrets: 1Password' \
    "seats: $(seats_rows "$seats_file")")

  recent=$(printf '%s\n' \
    "$(git_recent "$continuum_main_git" continuum-main)" \
    "$(git_recent "$continuum_ui_git" continuum-ui)" \
    "$(git_recent "$rakazo_git_dir" rakazo)" \
    "$(git_recent "$FM_ROOT" firstmate)" \
    "$(packet_router_recent "$pr_root")")

  dnb=$(printf '%s\n' \
    '## Do-not-browse' \
    'For live rev/hold/routing facts, stop; do not walk C:\continuum-system.' \
    'Vault is SOPs. Northstar is outcomes. This card is the live overlay.')
  body=$(printf '%s\n' \
    '## Live revisions' \
    "continuum_health: revision=$rev status=$status env=$env" \
    "s_head: $s_head" \
    "continuum_main_git: $gh_main" \
    "ui_bundle: $ui_js" \
    "rakazo_health: revision=$rakazo_rev" \
    "rakazo_git: $rakazo_git" \
    "firstmate: $fm_head" \
    "vault_commit: $vault_head" \
    '' \
    '## Runtime flags' \
    "globalHold: $hold" \
    "jobs: $jobs" \
    "tent_http: $tent_code" \
    "rakazo_ui_http: $rakazo_ui" \
    "URGENT_CAPTAIN_ALERTS_ENABLED: $urgent" \
    '' \
    '## Routing and model rules' \
    "$routing" \
    '' \
    '## Active holds and freezes' \
    "$holds" \
    '' \
    '## Where each SoT lives' \
    "$sot" \
    '' \
    '## Recent changes (7d)' \
    "$recent")
  # Header is 6 lines plus one blank. Keep a blank and the 3-line do-not-browse trailer.
  core_max=$((CARD_LINE_CAP - 12))
  [ "$core_max" -gt 8 ] || core_max=8
  body=$(printf '%s\n' "$body" | cap_text "$core_max")
  body=$(printf '%s\n%s' "$body" "$dnb")
  digest=$(printf '%s\n' "$body")
  sha=$(sha256_text "$digest")
  header=$(printf '%s\n' \
    '# SYSTEM_STATE' \
    "version: $generated" \
    "generated_at: $generated" \
    "ttl: ${ttl_m}m" \
    "generator: bin/fm-system-state-card.sh host=$host" \
    "sha256: $sha")
  card=$(printf '%s\n\n%s\n' "$header" "$body")
  printf '%s' "$card"
  case "$card" in
    *$'\n') ;;
    *) printf '\n' ;;
  esac
}

DO_POINTER=0
DO_STDOUT=0
DO_WRITE=1
DO_INHERIT=1
DO_PACKET=1
DO_RAKAZO=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --pointer) DO_POINTER=1 ;;
    --stdout) DO_STDOUT=1 ;;
    --no-write) DO_WRITE=0 ;;
    --no-inherit) DO_INHERIT=0 ;;
    --no-packet) DO_PACKET=0 ;;
    --rakazo-pointer) DO_RAKAZO=1 ;;
    -h|--help) usage; exit 0 ;;
    *) fail_usage "unknown argument: $1" ;;
  esac
  shift
done

if [ "$DO_POINTER" -eq 1 ]; then
  if [ "$DO_STDOUT" -eq 1 ] || [ "$DO_WRITE" -eq 0 ] || [ "$DO_RAKAZO" -eq 1 ]; then
    fail_usage "--pointer cannot be combined with generate flags"
  fi
  print_pointer
  exit 0
fi

CARD=$(build_card)
CARD=${CARD%$'\n'}

if [ "$DO_WRITE" -eq 1 ]; then
  write_atomic "$CARD_PATH" "$CARD"
  if [ "$DO_INHERIT" -eq 1 ]; then
    inherit_local_secondmates "$CARD"
  fi
fi

if [ "$DO_PACKET" -eq 1 ] && [ "$DO_WRITE" -eq 1 ]; then
  write_eleusis_packet "$CARD" "$DO_RAKAZO"
fi

if [ "$DO_STDOUT" -eq 1 ]; then
  printf '%s\n' "$CARD"
elif [ "$DO_WRITE" -eq 1 ]; then
  printf '%s\n' "$CARD_PATH"
fi
