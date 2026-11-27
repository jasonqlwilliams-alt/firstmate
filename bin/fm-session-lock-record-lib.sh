#!/usr/bin/env bash
# shellcheck disable=SC2034

# ---------------------------------------------------------------------------
# Session-lock owner record.
#
# state/.lock is one PID line and the commit pointer. In launch-v1, its
# .lock.owner.<pid> proof binds that PID to its start token, kind, canonical
# home and launch fingerprint. A persistent .lock.owner-format seal forbids
# interpreting missing proof as legacy. The publisher stages separate proofs
# under .lock.acquire and replaces the PID line atomically.
#
# Before activation a legacy .lock.start may hold the matching PID and
# start=<token>. The legacy reader accepts a missing or differently keyed
# sidecar as PID-only. The launch-v1 writer preserves that proof while sealing
# the first transition.

fm_proc_start_ticks() {
  local path=$1 stat_line ticks
  local -a stat_fields
  stat_line=$(cat "$path" 2>/dev/null) || return 1
  # After the final comm delimiter, array index 19 is proc stat field 22.
  read -r -a stat_fields <<< "${stat_line##*)}"
  [ "${#stat_fields[@]}" -ge 20 ] || return 1
  ticks=${stat_fields[19]}
  case "$ticks" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$ticks"
}

fm_pid_start_time() {
  local pid=$1 proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc} value
  case "$pid" in ''|0|1|*[!0-9]*) return 1 ;; esac
  if [ -r "$proc_root/$pid/stat" ]; then
    value=$(fm_proc_start_ticks "$proc_root/$pid/stat") || return 1
    printf 'proc:%s\n' "$value"
    return 0
  fi
  value=$(LC_ALL=C TZ=UTC0 ps -p "$pid" -o lstart= 2>/dev/null) || return 1
  value=$(printf '%s' "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  case "$value" in ''|*$'\n'*|*$'\r'*) return 1 ;; esac
  printf 'lstart:%s\n' "$value"
}

fm_session_lock_start_matches() {
  local pid=$1 recorded=$2 current
  case "$pid" in ''|0|1|*[!0-9]*) return 1 ;; esac
  [ -n "$recorded" ] || return 0
  case "$recorded" in linux:*|darwin:*) fm_session_owner_liveness "$pid" "$recorded"; return ;; esac
  current=$(fm_pid_start_time "$pid") || return 1
  [ "$current" = "$recorded" ]
}

fm_session_lock_print_record() {
  [ -n "$2" ] || return 1
  printf '%s\nstart=%s\n' "$1" "$2"
}

# Read the owner PID and its associated start token into the two output globals.
FM_SESSION_LOCK_PID=''
FM_SESSION_LOCK_START=''
fm_session_lock_read_legacy() {  # <lock-file>
  local content line2 pid sidecar="$1.start"
  FM_SESSION_LOCK_PID='' FM_SESSION_LOCK_START=''
  pid=$(cat "$1" 2>/dev/null) || return 1
  case "$pid" in ''|0|1|*[!0-9]*) return 0 ;; esac
  if [ -e "$sidecar" ] || [ -L "$sidecar" ]; then
    [ -f "$sidecar" ] && [ ! -L "$sidecar" ] || return 1
    content=$(cat "$sidecar" 2>/dev/null && printf '.') || return 1
    content=${content%.}
    content=${content%$'\n'}
    if [ "${content%%$'\n'*}" = "$pid" ]; then
      line2=${content#*$'\n'}
      case "$line2" in
        *$'\n'*) FM_SESSION_LOCK_START=invalid ;;
        start=?*) FM_SESSION_LOCK_START=${line2#start=} ;;
        *) FM_SESSION_LOCK_START=invalid ;;
      esac
    fi
  fi
  FM_SESSION_LOCK_PID=$pid
}

# Gate publication per home, independently of runtime overrides. The format
# seal persists after first publication so missing proof can never mean legacy.
fm_session_owner_enabled() {
  [ -n "${FM_HOME:-}" ] || return 1
  local gate="$FM_HOME/config/session-lock-owner"
  [ -f "$gate" ] && [ ! -L "$gate" ] && [ "$(cat "$gate" 2>/dev/null)" = launch-v1 ]
}

fm_session_owner_mode_active() { # <state-dir>
  fm_session_owner_enabled || [ -e "$1/.lock.owner-format" ] || [ -L "$1/.lock.owner-format" ]
}

fm_session_owner_home() {
  local home
  home=$(cd -- "${FM_HOME:?}" 2>/dev/null && pwd -P) || return 1
  case "$home" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  printf '%s\n' "$home"
}

fm_session_owner_hash() {
  local digest
  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum) || return 1
  else
    digest=$(shasum -a 256) || return 1
  fi
  printf '%s\n' "${digest%% *}"
}

fm_session_owner_pid_valid() {
  [[ "$1" =~ ^[1-9][0-9]{0,9}$ ]] && [ "$1" -gt 1 ] && [ "$1" -le 2147483647 ]
}

fm_session_owner_token_valid() {
  [[ "$1" =~ ^linux:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:[0-9]+$ ]] \
    || [[ "$1" =~ ^darwin:[0-9]+:[0-9]{1,6}$ ]]
}

fm_session_owner_token() { # <pid>; 1 unavailable, 2 exited
  local pid=$1 root=${FM_PROC_ROOT_OVERRIDE:-/proc} stat_line boot reason
  local LC_ALL=C
  local -a fields
  export LC_ALL
  fm_session_owner_pid_valid "$pid" || return 1
  if ! reason=$(kill -0 "$pid" 2>&1); then
    case "$reason" in *'No such process'*) return 2 ;; *) return 1 ;; esac
  fi
  if [ -d "$root/sys/kernel" ] || [ "$(uname -s)" = Linux ]; then
    boot=$(cat "$root/sys/kernel/random/boot_id" 2>/dev/null) || return 1
    [[ "$boot" =~ ^[0-9a-f-]{36}$ ]] || return 1
    stat_line=$(cat "$root/$pid/stat" 2>/dev/null) || return 1
    read -r -a fields <<< "${stat_line##*)}"
    [ "${#fields[@]}" -ge 20 ] || return 1
    case "${fields[0]}" in Z|X|x) return 2 ;; esac
    [[ "${fields[19]}" =~ ^[0-9]+$ ]] || return 1
    printf 'linux:%s:%s\n' "$boot" "${fields[19]}"
  elif [ "$(uname -s)" = Darwin ]; then
    # libproc exposes the kernel's microsecond creation time, independent of
    # command name and with finer resolution than ps lstart.
    python3 "${BASH_SOURCE[0]%/*}/fm-session-owner-darwin.py" "$pid"
  else
    return 1
  fi
}

fm_session_owner_liveness() { # <pid> <start>; 0 live, 1 uncertain, 2 stale
  local pid=$1 start=$2 current reason
  local LC_ALL=C
  export LC_ALL
  fm_session_owner_pid_valid "$pid" || return 1
  case "$start" in
    invalid) return 1 ;;
    linux:*|darwin:*)
      fm_session_owner_token_valid "$start" || return 1
      current=$(fm_session_owner_token "$pid") || return $?
      [ "${current%%:*}" = "${start%%:*}" ] || return 1
      ;;
    *)
      if ! reason=$(kill -0 "$pid" 2>&1); then
        case "$reason" in *'No such process'*) return 2 ;; *) return 1 ;; esac
      fi
      [ -n "$start" ] || return 0
      current=$(fm_pid_start_time "$pid") || return 1
      [ "${current%%:*}" = "${start%%:*}" ] || return 1
      ;;
  esac
  [ "$current" = "$start" ] && return 0
  return 2
}

fm_session_owner_read() { # <lock> <pid> <seal>
  local lock=$1 pid=$2 seal=$3 proof content version owner_pid start kind home fingerprint extra
  proof="$lock.owner.$pid"
  if [ ! -e "$proof" ] && [ ! -L "$proof" ]; then
    [ -z "$seal" ] || return 1
    fm_session_lock_read_legacy "$lock" || return 1
    [ "$FM_SESSION_LOCK_PID" = "$pid" ]
    return
  fi
  [ -f "$proof" ] && [ ! -L "$proof" ] || return 1
  content=$(cat "$proof" 2>/dev/null) || return 1
  IFS=$'\t' read -r version owner_pid start kind home fingerprint extra <<< "$content"
  [ "$version" = v1 ] && [ "$owner_pid" = "$pid" ] && [ -n "$start" ] \
    && [ "$home" = "$(fm_session_owner_home)" ] && [ -z "$extra" ] || return 1
  case "$kind:$fingerprint" in
    launch:*|startup:*|native:*) [[ "$fingerprint" =~ ^[0-9a-f]{64}$ ]] || return 1 ;;
    legacy:-) [ "$start" != invalid ] || return 1 ;;
    *) return 1 ;;
  esac
  if [ "$kind" != legacy ]; then
    fm_session_owner_token_valid "$start" || return 1
  fi
  [ "$content" = "$(fm_session_owner_format "$pid" "$start" "$kind" "$home" "$fingerprint")" ] || return 1
  FM_SESSION_LOCK_PID=$pid FM_SESSION_LOCK_START=$start
  [ "$start" != pid-only ] || FM_SESSION_LOCK_START=''
  FM_SESSION_LOCK_KIND=$kind FM_SESSION_LOCK_FINGERPRINT=$fingerprint
  FM_SESSION_LOCK_GENERATION=$(printf '%s' "$content" | fm_session_owner_hash)
}

fm_session_owner_format() {
  printf 'v1\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"
}

# Snapshot uses the PID line as its commit pointer. A same-PID replacement
# commits at the proof rename. Callers granting authority also verify liveness.
fm_session_lock_read() {
  local lock=$1 pid seal='' after=''
  FM_SESSION_LOCK_PID='' FM_SESSION_LOCK_START='' FM_SESSION_LOCK_KIND=''
  FM_SESSION_LOCK_FINGERPRINT='' FM_SESSION_LOCK_GENERATION=''
  [ -f "$lock" ] && [ ! -L "$lock" ] || return 1
  pid=$(cat "$lock" 2>/dev/null) || return 1
  if ! fm_session_owner_pid_valid "$pid"; then
    ! fm_session_owner_enabled && [ ! -e "$lock.owner-format" ] && [ ! -L "$lock.owner-format" ]
    return
  fi
  if [ -e "$lock.owner-format" ] || [ -L "$lock.owner-format" ]; then
    [ -f "$lock.owner-format" ] && [ ! -L "$lock.owner-format" ] || return 1
    seal=$(cat "$lock.owner-format" 2>/dev/null) && [ "$seal" = v1 ] || return 1
  fi
  fm_session_owner_read "$lock" "$pid" "$seal" || return 1
  [ "$(cat "$lock" 2>/dev/null)" = "$pid" ] || return 1
  if [ -e "$lock.owner-format" ] || [ -L "$lock.owner-format" ]; then
    after=$(cat "$lock.owner-format" 2>/dev/null) || return 1
  fi
  [ "$seal" = "$after" ]
}

# Exec the publisher in the process that took .lock.acquire. In particular,
# no orphaned child can rename a record after that mutex becomes reclaimable.
fm_session_owner_publish() { # <lock> <claim-owner-dir>
  local lock=$1 claim_owner=$2 legacy='' next
  if [ -n "${FM_SESSION_LOCK_PID:-}" ] && [ -z "${FM_SESSION_LOCK_GENERATION:-}" ]; then
    legacy=$(fm_session_owner_format "$FM_SESSION_LOCK_PID" "${FM_SESSION_LOCK_START:-pid-only}" legacy "$FM_SESSION_OWNER_HOME" -) || return 1
  fi
  next=$(fm_session_owner_format "$FM_SESSION_OWNER_PID" "$FM_SESSION_OWNER_START" \
    "$FM_SESSION_OWNER_KIND" "$FM_SESSION_OWNER_HOME" "$FM_SESSION_OWNER_FINGERPRINT") || return 1
  exec node "${BASH_SOURCE[0]%/*}/fm-session-owner-publish.mjs" "$lock" "$claim_owner" \
    "${FM_SESSION_LOCK_PID:-}" "$FM_SESSION_OWNER_PID" "$legacy" "$next"
}
