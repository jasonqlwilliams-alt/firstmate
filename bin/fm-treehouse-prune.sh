#!/usr/bin/env bash
# fm-treehouse-prune.sh - schedule a daily Treehouse pool prune.
#
# Usage:
#   fm-treehouse-prune.sh arm       register the daily prune with this home's watcher
#   fm-treehouse-prune.sh disarm    retire the registration and its records
#   fm-treehouse-prune.sh --help
#
# The registered check runs the sweep in a separate session. See
# docs/configuration.md for pool scope, protection, and sweep records.
set -u
export LC_ALL=C
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS_DIR="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
PROTECTED_FILE="$CONFIG_DIR/treehouse-prune-protected"
RECORD="$STATE/.treehouse-prune"
LOG="$STATE/.treehouse-prune.log"
LOCK="$STATE/.treehouse-prune.lock"

usage() {
  sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

fail() {
  printf 'fm-treehouse-prune: %s\n' "$1" >&2
  return 1
}

# shellcheck disable=SC2034 # read by bin/fm-wake-lib.sh at load
FM_WAKE_NO_MKDIR=1
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-treehouse-scratch.sh
. "$SCRIPT_DIR/fm-treehouse-scratch.sh"

CHECK_ID="$FM_TREEHOUSE_PRUNE_CHECK_ID"
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"

record_get() {
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 0
  sed -n "s/^$1=//p" "$RECORD"
}

record_set() {
  local tmp
  [ ! -d "$RECORD" ] || return 1
  tmp=$(mktemp "$STATE/.treehouse-prune.XXXXXX") || return 1
  if ! printf '%s\n' "last_start=$1" "last_result=$2" "reported=$3" > "$tmp" ||
    ! mv -f -- "$tmp" "$RECORD"; then
    rm -f -- "$tmp"
    return 1
  fi
}

sweep_due() {
  local last
  last=$(record_get last_start)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ "$(($1 - 10#$last))" -ge 86400 ]
}

check_protected() {
  local line list physical entry leased missing=0
  [ -e "$PROTECTED_FILE" ] || [ -L "$PROTECTED_FILE" ] || return 0
  [ -f "$PROTECTED_FILE" ] && list=$(cat -- "$PROTECTED_FILE") || {
    printf 'Cannot read protected-slot list %s\n' "$PROTECTED_FILE"
    return 1
  }
  while IFS= read -r line; do
    case "${line#"${line%%[![:space:]]*}"}" in ''|\#*) continue ;; esac
    [[ "$line" = /* ]] || { printf 'Expected an absolute protected-slot path: %s\n' "$line"; return 1; }
    physical=$(fm_treehouse_canonical_dir "$line") || physical=
    leased=0
    for entry in "$@"; do
      [ "$physical" = "${entry:1}" ] || continue
      leased=${entry:0:1}
      [ "$leased" = 1 ] || break
    done
    [ "$leased" = 0 ] || continue
    printf 'Protected slot needs a Treehouse lease: %s\n' "$line"
    missing=1
  done <<< "$list"
  return "$missing"
}

sweep() {
  local dir repo json rows row leased name physical parent out rc=0
  local -a repos=() slots=() unleased=()
  fm_treehouse_require_compatible || return 1
  for dir in "$FM_HOME" "$PROJECTS_DIR"/*/; do
    repo=$(fm_treehouse_canonical_dir "$dir") || continue
    [ "$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" = "$repo" ] || continue
    repos+=("$repo")
    json=$(cd "$repo" && fm_run_timed 60 treehouse status --json) || return 1
    rows=$(jq -r '
      if type == "array" then .[] else error("expected Treehouse status array") end
      | select(.path | contains("\n") | not)
      | [(if (.lease_id | type == "string" and length > 0) then "1" else "0" end), .name, .path]
      | join("\t")
    ' <<< "$json") || return 1
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      leased=${row%%$'\t'*}
      row=${row#*$'\t'}
      name=${row%%$'\t'*}
      physical=$(fm_treehouse_canonical_dir "${row#*$'\t'}") || continue
      slots+=("$leased$physical")
      parent=${physical%/*}
      if [ "${parent##*/}" = "$name" ]; then
        slots+=("$leased$parent")
      fi
      [ "$leased" = 1 ] || unleased+=("$physical")
    done <<< "$rows"
  done
  check_protected "${slots[@]+"${slots[@]}"}" || return 1
  fm_treehouse_require_recorded_leases "$STATE" prune "${unleased[@]+"${unleased[@]}"}" || return 1
  for repo in "${repos[@]+"${repos[@]}"}"; do
    printf 'Pruning pool for %s\n' "$repo"
    out=$(cd "$repo" && fm_run_timed 900 treehouse prune --yes 2>&1) || {
      printf 'Treehouse prune exited %s\n' "$?"
      rc=1
    }
    printf '%s\n' "$out"
    if grep -Eq '^  (cleanup failed|remove failed):$' <<< "$out"; then
      rc=1
    fi
  done
  return "$rc"
}

shim_content() {
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    "export FM_HOME=$(printf '%q' "$1")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-treehouse-prune.sh") check"
}

prune_registered() {
  fm_custom_check_registered "$STATE" "$CHECK_ID" &&
    cmp -s "$CHECK_SHIM" <(shim_content "$1")
}

check_present() {
  [ -e "$CHECK_SHIM" ] || [ -L "$CHECK_SHIM" ] ||
    [ -e "$CHECK_TRUST" ] || [ -L "$CHECK_TRUST" ]
}

action_sweep() {
  local now tmp result=ok
  prune_registered "$FM_HOME" || return 0
  now=$(date +%s) && sweep_due "$now" || return 0
  [ ! -d "$LOG" ] || return 1
  tmp=$(mktemp "$STATE/.treehouse-prune-log.XXXXXX") || return 1
  if ! mv -f -- "$tmp" "$LOG"; then
    rm -f -- "$tmp"
    return 1
  fi
  record_set "$now" running 0 || return 1
  sweep > "$LOG" 2>&1 || result=failed
  record_set "$now" "$result" 0
}

action_check() {
  local now last result
  prune_registered "$FM_HOME" || return 0
  result=$(record_get last_result)
  if [ "$result" = running ] ||
    { [ "$result" = failed ] && [ "$(record_get reported)" != 1 ]; }; then
    last=$(record_get last_start)
    record_set "$last" failed 1 || return 1
    printf 'Treehouse pool prune failed. See state/.treehouse-prune.log.\n'
  fi
  now=$(date +%s) && sweep_due "$now" || return 0
  fm_lock_release "$LOCK" || return 1
  if ! command -v setsid >/dev/null 2>&1 ||
    ! setsid "$BASH" -c "$(printf '%q _sweep &' "$SCRIPT_DIR/fm-treehouse-prune.sh")" </dev/null >/dev/null 2>&1; then
    printf 'Treehouse pool prune could not start a separate session with setsid.\n'
    return 1
  fi
}

action_arm() {
  local tmp
  if check_present; then
    prune_registered "$FM_HOME" || { fail "refusing to replace $CHECK_SHIM or its trust binding"; return 1; }
  else
    tmp=$(mktemp "$STATE/.treehouse-prune-check.XXXXXX") || return 1
    if ! shim_content "$FM_HOME" > "$tmp" || ! chmod 0700 "$tmp" ||
      ! ln -- "$tmp" "$CHECK_SHIM"; then
      rm -f -- "$tmp"
      return 1
    fi
    rm -f -- "$tmp"
    if ! "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null; then
      rm -f -- "$CHECK_SHIM"
      return 1
    fi
  fi
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

action_disarm() {
  if check_present; then
    prune_registered "$FM_HOME" || { fail "refusing to retire $CHECK_SHIM or its trust binding"; return 1; }
    "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" >/dev/null || return 1
  fi
  rm -f -- "$RECORD" "$LOG" || return 1
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

[ "$#" -eq 1 ] || { usage >&2; exit 2; }
case "$1" in
  -h|--help) usage; exit ;;
  arm)
    command -v setsid >/dev/null 2>&1 || { fail 'setsid is required to arm the scheduled prune'; exit 1; }
    fm_treehouse_require_compatible && mkdir -p "$STATE" || exit 1
    ;;
  disarm) [ -e "$STATE" ] || [ -L "$STATE" ] || exit 0 ;;
  check|_sweep) ;;
  *) usage >&2; exit 2 ;;
esac
[ -d "$STATE" ] && [ ! -L "$STATE" ] || { fail 'state directory is unavailable'; exit 1; }
FM_HOME=$(fm_treehouse_canonical_dir "$FM_HOME") || exit 1
export FM_HOME
if ! fm_lock_try_acquire "$LOCK"; then
  case "$1" in check|_sweep) exit 0 ;; esac
  fail 'the scheduled prune is busy'
  exit 1
fi
trap 'fm_lock_release "$LOCK"' EXIT
case "$1" in
  arm) action_arm ;;
  disarm) action_disarm ;;
  check) action_check ;;
  _sweep) action_sweep ;;
esac
