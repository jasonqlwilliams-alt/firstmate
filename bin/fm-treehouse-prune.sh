#!/usr/bin/env bash
# fm-treehouse-prune.sh - remove idle, available Treehouse pool slots on a
# schedule, never a slot anything still holds.
#
# Usage:
#   fm-treehouse-prune.sh run [--dry-run]   sweep now and print each decision
#   fm-treehouse-prune.sh check             watcher entry (see the header)
#   fm-treehouse-prune.sh arm               write and register state/treehouse-prune.check.sh
#   fm-treehouse-prune.sh disarm            retire the check and its records
#   fm-treehouse-prune.sh status            print whether it is armed and the last sweep
#   fm-treehouse-prune.sh --help
#
# Off by default: nothing is swept until a home runs `arm` (or `run` by hand).
#
# Pools swept are the pools of this home's own repository and of every clone
# under its projects/ directory, at whatever root Treehouse resolves for them
# (TREEHOUSE_ROOT, then Treehouse's own configuration). Each slot is read from
# `treehouse status --json`, and one is removed only when every test passes:
#
#   - Treehouse reports it `available`, with no lease and no running process;
#   - it is not listed in config/treehouse-prune-protected;
#   - it carries no Firstmate slot-owner claim (.fm-slot-owner), readable or not;
#   - no task record in any local home this machine can see (this home's root,
#     and every locally registered secondmate home beneath it) names it as a
#     worktree= or home=, per fm_treehouse_slot_foreign_records in
#     bin/fm-wake-lib.sh; a home scan that cannot be trusted stops the sweep;
#   - it is not itself a Firstmate home.
#
# A slot that passes is removed one at a time with `treehouse destroy <path>
# --yes` and no --include-* flag, so Treehouse re-checks it at removal time and
# skips anything dirty, unmerged, in use, or leased by then. A skipped slot is
# kept and reported, never forced. Nothing outside a pool slot is touched; pool
# folders themselves are left in place.
#
# config/treehouse-prune-protected (local, gitignored, not inherited) lists
# protected slots: one absolute path per line, blank lines and `#` comments
# ignored. A listed path protects the slot whose worktree, or whose slot
# directory, is that path or lies beneath it. A relative or otherwise unusable
# line stops the sweep rather than being skipped, so a typo cannot unprotect a
# slot. docs/configuration.md owns the operator contract.
#
# `check` is what the watcher runs. It prints one line only when the last
# sweep failed and that failure has not been reported yet, and nothing
# otherwise. When FM_TREEHOUSE_PRUNE_INTERVAL seconds (default 86400, valid
# 3600..2592000) have passed since the last sweep started and none is running,
# it starts a sweep detached from the watcher, because removing gigabytes of
# worktrees can outlast the watcher's per-check bound. The sweep's last output
# is kept in state/.treehouse-prune.log and its result in state/.treehouse-prune.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS_DIR="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
PROTECTED_FILE="$CONFIG_DIR/treehouse-prune-protected"
CHECK_ID=treehouse-prune
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
RECORD="$STATE/.treehouse-prune"
LOG="$STATE/.treehouse-prune.log"
LOCK="$STATE/.treehouse-prune.lock"
STATUS_SECS=60
DESTROY_SECS=900

usage() {
  sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die_usage() {
  printf 'fm-treehouse-prune: %s\n' "$1" >&2
  usage >&2
  exit 2
}

INTERVAL=

# Only the actions that schedule read the interval, so a bad value never stops
# a manual sweep or a disarm.
load_interval() {
  INTERVAL=${FM_TREEHOUSE_PRUNE_INTERVAL:-86400}
  case "$INTERVAL" in
    ''|*[!0-9]*) INTERVAL=-1 ;;
  esac
  if [ "$INTERVAL" -lt 3600 ] || [ "$INTERVAL" -gt 2592000 ]; then
    printf 'fm-treehouse-prune: FM_TREEHOUSE_PRUNE_INTERVAL must be a whole number from 3600 to 2592000\n' >&2
    exit 2
  fi
}

now_epoch() {
  case "${FM_TREEHOUSE_PRUNE_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_TREEHOUSE_PRUNE_NOW" ;;
  esac
}

canonical_dir() {  # <path>
  [ -n "$1" ] && [ -d "$1" ] || return 1
  CDPATH='' cd -P -- "$1" 2>/dev/null && pwd -P
}

# --- record -----------------------------------------------------------------

record_get() {  # <key>
  local line value=''
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$1="*) value=${line#*=} ;;
    esac
  done < "$RECORD"
  printf '%s' "$value"
}

# Rewrite the record with <key>=<value> pairs replacing their old values.
record_set() {  # <key>=<value>...
  local tmp pair key line keep
  mkdir -p "$STATE" || return 1
  tmp=$(umask 077; mktemp "$STATE/.treehouse-prune.XXXXXX") || return 1
  if [ -f "$RECORD" ] && [ ! -L "$RECORD" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      keep=1
      for pair in "$@"; do
        key=${pair%%=*}
        case "$line" in "$key="*) keep=0 ;; esac
      done
      [ "$keep" = 0 ] || printf '%s\n' "$line"
    done < "$RECORD" > "$tmp"
  fi
  for pair in "$@"; do
    printf '%s\n' "${pair//$'\n'/ }" >> "$tmp"
  done
  mv -f -- "$tmp" "$RECORD" || { rm -f -- "$tmp"; return 1; }
}

# --- protected slots ----------------------------------------------------------

PROTECTED=()

load_protected() {
  local line n=0 path
  PROTECTED=()
  [ -e "$PROTECTED_FILE" ] || [ -L "$PROTECTED_FILE" ] || return 0
  [ -f "$PROTECTED_FILE" ] && [ -r "$PROTECTED_FILE" ] || {
    printf 'cannot read protected-slot list %s\n' "$PROTECTED_FILE"
    return 1
  }
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    case "$line" in
      /*) ;;
      *)
        printf 'protected-slot list %s line %s is not an absolute path: %s\n' "$PROTECTED_FILE" "$n" "$line"
        return 1
        ;;
    esac
    path=${line%/}
    [ -n "$path" ] || path=/
    PROTECTED+=("$path")
    # A listed path that exists is matched by its physical path as well.
    if path=$(canonical_dir "$line"); then
      PROTECTED+=("$path")
    fi
  done < "$PROTECTED_FILE"
}

under() {  # <path> <prefix>
  [ "$2" = / ] && return 0
  case "$1" in
    "$2"|"$2"/*) return 0 ;;
  esac
  return 1
}

protected_slot() {  # <worktree> <physical-worktree>
  local p
  for p in "${PROTECTED[@]+"${PROTECTED[@]}"}"; do
    under "$1" "$p" && return 0
    under "$2" "$p" && return 0
    under "${1%/*}" "$p" && return 0
    under "${2%/*}" "$p" && return 0
  done
  return 1
}

# --- sweep --------------------------------------------------------------------

sweep_repos() {
  local d
  canonical_dir "$FM_HOME" >/dev/null && git -C "$FM_HOME" rev-parse --git-dir >/dev/null 2>&1 \
    && canonical_dir "$FM_HOME"
  for d in "$PROJECTS_DIR"/*/; do
    [ -d "$d" ] || continue
    git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || continue
    canonical_dir "$d"
  done
}

# A slot that holds a Firstmate home must never go, even unclaimed.
slot_is_home() {  # <physical-worktree>
  local s home
  for s in "${FM_TREEHOUSE_OWNER_STATES[@]+"${FM_TREEHOUSE_OWNER_STATES[@]}"}"; do
    home=$(canonical_dir "${s%/state}") || continue
    [ "$home" = "$1" ] && return 0
  done
  [ -f "$1/bin/fm-session-start.sh" ] && { [ -d "$1/state" ] || [ -d "$1/data" ]; }
}

# Prints decisions; returns 0 when the sweep completed, 1 when it stopped.
sweep() {  # <dry-run 0|1>
  local dry=$1 repo json rows name path status lease procs phys reason rc out
  local removed=0 kept=0 seen='|' none_meta
  command -v treehouse >/dev/null 2>&1 || { echo 'stopped: treehouse is not installed'; return 1; }
  command -v jq >/dev/null 2>&1 || { echo 'stopped: jq is not installed'; return 1; }
  load_protected || { echo 'stopped: protected-slot list is unusable'; return 1; }
  # Every local home's records are read before anything is removed.
  none_meta="$STATE/.treehouse-prune.none.meta"
  fm_treehouse_collect_owner_states "$STATE" 2>&1 || { echo 'stopped: cannot read every local home'"'"'s task records'; return 1; }
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    json=$(cd "$repo" && fm_run_timed "$STATUS_SECS" treehouse status --json 2>/dev/null) || {
      echo "stopped: treehouse status failed for $repo"
      return 1
    }
    # Every field is non-empty, because read collapses adjacent tab separators.
    rows=$(printf '%s' "$json" | jq -r '
      if type == "array" then .[] else error("not an array") end
      | [(.name // "-"), .path, (.status // "-"),
         (if (.lease_id // "") == "" then "-" else "leased" end),
         ((.processes // []) | length)]
      | map(tostring) | @tsv') || { echo "stopped: unreadable treehouse status for $repo"; return 1; }
    while IFS=$'\t' read -r name path status lease procs; do
      [ -n "$path" ] || continue
      case "$seen" in *"|$path|"*) continue ;; esac
      seen="$seen$path|"
      reason=
      phys=$(canonical_dir "$path") || phys=$path
      if [ "$status" != available ]; then
        reason="treehouse reports it $status"
      elif [ "$lease" != - ]; then
        reason='leased'
      elif [ "$procs" != 0 ]; then
        reason='in use'
      elif [ ! -d "$path" ]; then
        reason='missing on disk'
      elif protected_slot "$path" "$phys"; then
        reason='protected'
      elif [ -e "${phys%/*}/.fm-slot-owner" ] || [ -L "${phys%/*}/.fm-slot-owner" ]; then
        reason='carries a Firstmate slot-owner claim'
      elif slot_is_home "$phys"; then
        reason='is a Firstmate home'
      else
        rc=0
        out=$(fm_treehouse_slot_foreign_records "$phys" "$none_meta" 2>&1) || rc=$?
        case "$rc" in
          0) reason="named by task record $(printf '%s' "$out" | head -1 | cut -f1)" ;;
          1) ;;
          *) echo "stopped: cannot read every local home's task records: $out"; return 1 ;;
        esac
      fi
      if [ -n "$reason" ]; then
        printf 'kept %s: %s\n' "$path" "$reason"
        kept=$((kept + 1))
        continue
      fi
      if [ "$dry" = 1 ]; then
        printf 'would remove %s\n' "$path"
        removed=$((removed + 1))
        continue
      fi
      rc=0
      out=$(cd "$repo" && fm_run_timed "$DESTROY_SECS" treehouse destroy "$path" --yes 2>&1) || rc=$?
      if [ "$rc" = 0 ] && [ ! -e "$path" ]; then
        printf 'removed %s\n' "$path"
        removed=$((removed + 1))
      else
        printf 'kept %s: treehouse declined: %s\n' "$path" \
          "$(printf '%s\n' "$out" | grep -E 'did not destroy|error' | tail -1)"
        kept=$((kept + 1))
      fi
    done <<< "$rows"
    : "$name"
  done < <(sweep_repos)
  if [ "$dry" = 1 ]; then
    printf 'summary: would remove %s, keep %s\n' "$removed" "$kept"
  else
    printf 'summary: removed %s, kept %s\n' "$removed" "$kept"
  fi
}

action_run() {
  local dry=0 rc=0 start out summary
  case "${1:-}" in
    '') ;;
    --dry-run) dry=1 ;;
    *) die_usage "unknown run option: $1" ;;
  esac
  mkdir -p "$STATE" || return 1
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$SCRIPT_DIR/fm-timeout-lib.sh" || return 1
  # shellcheck disable=SC2034 # read by bin/fm-wake-lib.sh at load
  FM_WAKE_NO_MKDIR=1
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh" || return 1
  if ! fm_lock_try_acquire "$LOCK"; then
    echo 'fm-treehouse-prune: a sweep is already running' >&2
    return 1
  fi
  start=$(now_epoch)
  [ "$dry" = 1 ] || record_set "last_start=$start"
  out=$(sweep "$dry") || rc=$?
  printf '%s\n' "$out"
  summary=$(printf '%s\n' "$out" | grep -E '^(summary|stopped):' | tail -1)
  if [ "$dry" = 0 ]; then
    if [ "$rc" = 0 ]; then
      record_set "last_end=$(now_epoch)" "last_result=ok" "last_summary=$summary"
    else
      record_set "last_end=$(now_epoch)" "last_result=failed" "last_summary=$summary" "reported=0"
    fi
  fi
  fm_lock_release "$LOCK"
  return "$rc"
}

action_check() {
  local last now result reported summary
  load_interval
  result=$(record_get last_result)
  reported=$(record_get reported)
  if [ "$result" = failed ] && [ "$reported" != 1 ]; then
    summary=$(record_get last_summary)
    record_set "reported=1" || true
    printf 'treehouse pool prune failed: %s (see state/.treehouse-prune.log)\n' "${summary:-no detail}" | cut -c1-500
  fi
  last=$(record_get last_start)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  now=$(now_epoch)
  [ $((now - last)) -ge "$INTERVAL" ] || return 0
  # Recording the start here keeps the next poll from launching a second sweep
  # before this one takes its lock; the sweep's own lock covers the rest.
  record_set "last_start=$now" || return 0
  # Detach the sweep from the watcher: new session, no inherited descriptors.
  if command -v setsid >/dev/null 2>&1; then
    setsid "$SCRIPT_DIR/fm-treehouse-prune.sh" run </dev/null >"$LOG" 2>&1 &
  else
    nohup "$SCRIPT_DIR/fm-treehouse-prune.sh" run </dev/null >"$LOG" 2>&1 &
  fi
  return 0
}

shim_content() {  # <home>
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-treehouse-prune.sh - scheduled Treehouse pool prune shim.' \
    '# The watcher validates these bytes, then dispatches the trusted script.' \
    "export FM_HOME=$(printf '%q' "$1")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-treehouse-prune.sh") check"
}

action_arm() {
  local home tmp
  home=$(canonical_dir "$FM_HOME") || { echo "fm-treehouse-prune: cannot resolve FM_HOME $FM_HOME" >&2; return 1; }
  mkdir -p "$STATE" || return 1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo 'fm-treehouse-prune: state directory is unavailable' >&2; return 1; }
  if [ -L "$CHECK_SHIM" ] || { [ -e "$CHECK_SHIM" ] && [ ! -f "$CHECK_SHIM" ]; }; then
    echo "fm-treehouse-prune: refusing to replace $CHECK_SHIM" >&2
    return 1
  fi
  tmp=$(umask 077; mktemp "$STATE/.treehouse-prune-check.XXXXXX") || return 1
  if ! shim_content "$home" > "$tmp" || ! chmod 0700 "$tmp" || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    echo "fm-treehouse-prune: could not write $CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null; then
    rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
    echo "fm-treehouse-prune: could not register $CHECK_SHIM" >&2
    return 1
  fi
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

action_disarm() {
  if [ -e "$CHECK_SHIM" ] || [ -e "$CHECK_TRUST" ] || [ -L "$CHECK_SHIM" ] || [ -L "$CHECK_TRUST" ]; then
    "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" >/dev/null || return 1
  fi
  rm -f -- "$RECORD" "$LOG"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

action_status() {
  load_interval
  if [ -f "$CHECK_SHIM" ] && [ -f "$CHECK_TRUST" ]; then
    echo 'armed: yes'
  else
    echo 'armed: no'
  fi
  printf 'interval: %ss\n' "$INTERVAL"
  printf 'last start: %s\n' "$(record_get last_start)"
  printf 'last result: %s\n' "$(record_get last_result)"
  printf 'last summary: %s\n' "$(record_get last_summary)"
}

case "${1:-}" in
  run) shift; [ "$#" -le 1 ] || die_usage 'too many arguments'; action_run "$@" ;;
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  status) action_status ;;
  -h|--help) usage ;;
  '') die_usage 'missing action' ;;
  *) die_usage "unknown action: $1" ;;
esac
