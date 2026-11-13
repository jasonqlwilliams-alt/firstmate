#!/usr/bin/env bash
# Build or apply the agent-composed model lineup. Never ranks or recommends.
# Usage: fm-lineup-board.sh build <payload.json> | apply <resolved.json> | path
#
# build input: schema=fm-lineup-board.v1, generated (string), quotas (array of
# {provider,headroom,reset,runway,spend_priority,attention}, all display strings),
# rows (array of {id,label,kind,current,suggested,reason,options}). Profile sets
# current/suggested are arrays; current may be empty for an unset role. options
# is a nonempty array of concrete {harness,model?,effort?} tuples, including all
# suggested tuples. kind is helm, backup_helm, secondmates, rule, or default.
# Include exactly one of each role and default, plus every dispatch rule/tier.
# Rule rows have rule_index (zero-based) and when (the exact rule condition).
# Row ids are unique routing identifiers; when lets the handler detect reordering.
# All offered and suggested tuples pass the same fences as apply. Current is
# display-only so a legacy invalid setting can still be shown and corrected.
# Benchmarks are loaded exclusively from config/model-benchmarks.json; input
# benchmarks are replaced. Cache shape: {entries:[{harness,model,task,benchmark,
# score,source,as_of}]}; score is a number, source an https URL, as_of YYYY-MM-DD.
# No cache or no matching entry displays "no public score". The agent researches
# and writes this private cache; this script never fetches or invents scores.
#
# apply input: schema=fm-lineup-apply.v1, dispatch (canonical crew-dispatch
# object), roles ({helm,backup_helm,secondmates}, one tuple each), instructions
# (string), and resolution (required nonempty agent explanation when instructions
# are nonblank). The agent resolves typed instructions before invoking apply.
# fallback_arrays and restart_secondmates are optional booleans, default false.
# Nonempty restart_ids is required only when restart_secondmates=true; firstmate
# resolves those ids from its live inventory, never from a board's editable text.
# Existing rule fields except use (including when/why) and dispatch-level fields
# except rules/default are preserved; new rules may be appended by the agent.
# Fallbacks require fallback_arrays=true. Role profiles never take arrays.
#
# apply validates every tuple and provenance before touching config. It stages
# all three files under a per-home lock, atomically renames each, and rolls back
# on publication failure. Readers of multiple files should hold .lineup-lock;
# ordinary readers always see complete individual files. No live helm switch is
# performed: a helm pick is printed as a handover instruction only. After commit,
# fm-config-push.sh owns propagation; failure is reported without claiming rollback.
# fm-secondmate-restart.sh is called only for an explicit true restart option.
#
# build uses the shipped template, safe JSON injection, and the shared Lavish
# session proof before arming fm-procevent-lavish.sh. No keyed-answer binding:
# the lineup skill handles and resolves the entire submission on its wake.
# FM_HOME and FM_CONFIG_OVERRIDE select private state, as in other home helpers.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
TEMPLATE="$SCRIPT_DIR/../.agents/skills/lineup/assets/board-template.html"
fail() { printf 'fm-lineup-board: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^set -eu/{ /^set -eu/d; s/^# \{0,1\}//; p; }' "$0"; }
board_path() { printf '%s/.lavish/model-lineup.html\n' "$FM_HOME"; }
# shellcheck source=bin/fm-agy-model-lib.sh
. "$SCRIPT_DIR/fm-agy-model-lib.sh"
# shellcheck source=bin/fm-cursor-lib.sh
. "$SCRIPT_DIR/fm-cursor-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"
# shellcheck source=bin/fm-lavish-board-lib.sh
. "$SCRIPT_DIR/fm-lavish-board-lib.sh"

validate() { # <board|apply|cache> <file>
  jq -e -s 'length == 1' "$2" >/dev/null || fail "expected one JSON document"
  jq -e --arg mode "$1" -f "$SCRIPT_DIR/fm-lineup-board.jq" "$2" >/dev/null \
    || fail "invalid $1 payload"
}
check_tuple() { # <kind> <tuple-json>
  local h m e patterns
  h=$(jq -r '.harness' <<< "$2")
  m=$(jq -r '.model // ""' <<< "$2")
  e=$(jq -r '.effort // ""' <<< "$2")
  case "$1" in
    helm|backup_helm|secondmates) "$SCRIPT_DIR/fm-harness.sh" primary-eligible "$h" || return 1 ;;
  esac
  "$SCRIPT_DIR/fm-harness.sh" validate-native-effort "$h" "$m" "$e" || return 1
  case "$h" in
    agy) fm_agy_model_allowed "$m" || return 1 ;;
    cursor)
      patterns=$(fm_cursor_model_allowlist_patterns "$CONFIG") || return 1
      printf '%s\n' "$patterns" | fm_cursor_model_allowlisted "$m" || {
        printf 'error: Cursor model %s is refused by config/cursor-model-allowlist\n' "$m" >&2
        return 1
      }
      ;;
  esac
}
check_profiles() { # <board|apply> <file>
  local row kind tuple
  while IFS= read -r row; do
    kind=$(jq -r '.kind' <<< "$row")
    tuple=$(jq -c '.profile' <<< "$row")
    check_tuple "$kind" "$tuple" || fail "refused $kind tuple: $tuple"
  done < <(jq -c --arg mode "$1" '
    def profiles: if type == "array" then .[] else . end;
    if $mode == "board" then .rows[] | .kind as $k | (.options[], .suggested[]) | {kind:$k,profile:.}
    else (.roles | to_entries[] | {kind:.key,profile:.value}),
      (.dispatch | (.rules[].use, .default) | profiles | {kind:"rule",profile:.}) end' "$2")
}
command_build() {
  local data=$1 board tmp json sid owner cache
  validate board "$data"
  check_profiles board "$data"
  cache="$CONFIG/model-benchmarks.json"
  if [ -e "$cache" ] || [ -L "$cache" ]; then
    [ -f "$cache" ] && [ -r "$cache" ] || fail "benchmark cache is unreadable"
    validate cache "$cache"
    json=$(jq -c --slurpfile cache "$cache" '.benchmarks = $cache[0].entries' "$data")
  else
    json=$(jq -c '.benchmarks = []' "$data")
  fi
  json=${json//</\\u003c}
  board=$(board_path)
  (umask 077; mkdir -p "${board%/*}")
  [ "$(grep -cxF '__FM_LINEUP_DATA__' "$TEMPLATE")" -eq 1 ] || fail "invalid board template"
  tmp=$(umask 077; mktemp "${board%/*}/.lineup.XXXXXX")
  BOARD_JSON="$json" perl -pe 's/^__FM_LINEUP_DATA__$/$ENV{BOARD_JSON}/' "$TEMPLATE" > "$tmp"
  if ! sed -n '/<script id="lineup-data" type="application\/json">/,/<\/script>/p' "$tmp" \
    | sed '1d;$d' | jq -e '.schema == "fm-lineup-board.v1"' >/dev/null; then
    rm -f -- "$tmp"
    fail "unreadable injected payload"
  fi
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$board"
  printf 'board: %s\n' "$board"
  sid=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$board")
  establish_board_session "$board"
  if [ "$BOARD_SESSION_REOPENED" = 1 ]; then
    "$SCRIPT_DIR/fm-procevent-lavish.sh" retire "$board" >/dev/null || fail "cannot retire pre-reopen source"
  fi
  lavish_session_listed_open "$(board_realpath "$board")" || fail "session ended before arm"
  owner=$(source_owner "$sid")
  if [ -n "$owner" ]; then
    printf 'already-armed: %s\n' "$sid"
  else
    "$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$board"
    owner=$(source_owner "$sid")
  fi
  if [ "$owner" != live ]; then
    "$SCRIPT_DIR/fm-procevent.sh" reconcile >/dev/null 2>&1 || true
    owner=$(await_source_owner "$sid")
    [ "$owner" = live ] || fail "source $sid is not listening (owner: ${owner:-none})"
  fi
  printf 'listening: live\n'
}

# The transaction holds original bytes until all file publications succeed.
# The lock is deliberately not auto-broken after an untrappable process death.
apply_cleanup() {
  local name rollback_failed=0
  if [ "${PUBLISHING:-0}" = 1 ]; then
    for name in crew-dispatch.json secondmate-harness backup-helm-successor; do
      if [ -f "$STAGE/old-$name" ]; then
        if ! mv -f -- "$STAGE/old-$name" "$CONFIG/$name"; then
          printf 'error: rollback failed for %s\n' "$name" >&2
          rollback_failed=1
        fi
      else
        rm -f -- "$CONFIG/$name" || rollback_failed=1
      fi
    done
  fi
  if [ "$rollback_failed" = 1 ]; then
    printf 'error: original bytes retained at %s; lineup lock retained for recovery\n' "$STAGE" >&2
    return 1
  fi
  [ -z "${STAGE:-}" ] || rm -rf -- "$STAGE"
  rmdir "$CONFIG/.lineup-lock" 2>/dev/null || true
}
command_apply() {
  local data=$1 name key ids id
  validate apply "$data"
  check_profiles apply "$data"
  # Refuse unsafe filesystem targets before creating staging or lock state.
  [ ! -L "$CONFIG" ] || fail "config directory is a symlink"
  for name in crew-dispatch.json secondmate-harness backup-helm-successor; do
    [ ! -L "$CONFIG/$name" ] || fail "config/$name is a symlink"
    if [ -e "$CONFIG/$name" ] && [ ! -f "$CONFIG/$name" ]; then fail "config/$name is not a regular file"; fi
  done
  (umask 077; mkdir -p "$CONFIG")
  mkdir "$CONFIG/.lineup-lock" 2>/dev/null || fail "another lineup apply holds the lock"
  STAGE=''
  PUBLISHING=0
  trap apply_cleanup EXIT
  trap 'exit 1' HUP INT TERM
  # Inspect provenance while holding the transaction lock. Nothing is written
  # if the live rules changed or their when/why/other fields were dropped.
  if [ -f "$CONFIG/crew-dispatch.json" ]; then
    jq -e -s 'length == 1 and (.[0] | type == "object")' "$CONFIG/crew-dispatch.json" >/dev/null \
      || fail "existing dispatch configuration is not one JSON object"
    jq -e --slurpfile old "$CONFIG/crew-dispatch.json" '
      .dispatch as $new | $old[0] as $old
      | (($old | del(.rules,.default)) == ($new | del(.rules,.default)))
      and (($old.rules // [] | length) <= ($new.rules | length))
      and ([range(0; ($old.rules // [] | length)) as $i
        | ($old.rules[$i] | del(.use)) == ($new.rules[$i] | del(.use))] | all)
    ' "$data" >/dev/null || fail "dispatch provenance changed; preserve existing rule fields and refresh stale input"
  fi
  STAGE=$(umask 077; mktemp -d "$CONFIG/.lineup.XXXXXX")
  jq '.fallback_arrays as $arrays | .dispatch
    | def representation: if $arrays == true then (if type == "array" then . else [.] end)
      else (if type == "array" then .[0] else . end) end;
    .rules |= map(.use |= representation) | .default |= representation' "$data" > "$STAGE/crew-dispatch.json"
  for key in secondmates backup_helm; do
    case "$key" in secondmates) name=secondmate-harness ;; backup_helm) name=backup-helm-successor ;; esac
    jq -r --arg key "$key" '.roles[$key] | .harness
      + (if has("model") or has("effort") then " " + (.model // "default") else "" end)
      + (if has("effort") then " " + .effort else "" end)' "$data" > "$STAGE/$name"
  done
  for name in crew-dispatch.json secondmate-harness backup-helm-successor; do
    chmod 0600 "$STAGE/$name"
    if [ -f "$CONFIG/$name" ]; then cp -p -- "$CONFIG/$name" "$STAGE/old-$name"; fi
  done
  PUBLISHING=1
  for name in crew-dispatch.json secondmate-harness backup-helm-successor; do
    if [ -f "$CONFIG/$name" ] && cmp -s "$STAGE/$name" "$CONFIG/$name"; then
      printf 'unchanged: config/%s\n' "$name"
    else
      mv -f -- "$STAGE/$name" "$CONFIG/$name" || fail "publication failed; rolling back"
      printf 'changed: config/%s\n' "$name"
    fi
  done
  PUBLISHING=0
  apply_cleanup
  trap - EXIT HUP INT TERM
  printf 'helm-handover: use the primary launch procedure with %s; live helm unchanged\n' "$(jq -c '.roles.helm' "$data")"
  "$SCRIPT_DIR/fm-config-push.sh" || fail "lineup saved, but secondmate propagation failed"
  if jq -e '.restart_secondmates == true' "$data" >/dev/null; then
    ids=$(jq -r '.restart_ids[]' "$data")
    # Validated ids contain no whitespace; array construction avoids globbing.
    local -a mates=()
    while IFS= read -r id; do mates+=("$id"); done <<< "$ids"
    "$SCRIPT_DIR/fm-secondmate-restart.sh" "${mates[@]}" || fail "lineup saved, but secondmate restart did not complete"
  else
    printf 'restart-secondmates: off\n'
  fi
}
case "${1:-}" in
  path) [ "$#" -eq 1 ] || fail "path takes no arguments"; board_path ;;
  build|apply)
    [ "$#" -eq 2 ] || fail "expected build|apply <file.json>"
    [ -f "$2" ] || fail "input file is missing"
    case "$1" in build) command_build "$2" ;; apply) command_apply "$2" ;; esac
    ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
