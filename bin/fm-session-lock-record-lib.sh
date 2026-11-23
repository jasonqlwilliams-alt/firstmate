#!/usr/bin/env bash
# shellcheck disable=SC2034

# ---------------------------------------------------------------------------
# Session-lock owner record.
#
# state/.lock is the single owner record of this home's session lock:
#   line 1   the owning harness pid
#   line 2   start=<token>, that pid's process start time from fm_pid_start_time
# A record with no start line is the pre-start-time format: it keeps pid-only
# liveness until bin/fm-lock.sh rewrites it. bin/fm-lock.sh is the only writer,
# through fm_session_lock_write, which publishes the whole record by temporary
# file plus rename so no reader ever observes an empty or partial owner line.

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
  current=$(fm_pid_start_time "$pid") || return 1
  [ "$current" = "$recorded" ]
}

fm_session_lock_print_record() {
  printf '%s\n' "$1" || return 1
  [ -z "$2" ] || printf 'start=%s\n' "$2"
}

# Read lock file $1 once into FM_SESSION_LOCK_PID (line 1, unvalidated) and
# FM_SESSION_LOCK_START (line 2's start= token, empty for the legacy format).
# Malformed extra lines leave both outputs empty.
# Returns 1 only when the file cannot be read.
FM_SESSION_LOCK_PID=''
FM_SESSION_LOCK_START=''
fm_session_lock_read() {  # <lock-file>
  local content line2
  FM_SESSION_LOCK_PID='' FM_SESSION_LOCK_START=''
  content=$(cat "$1" 2>/dev/null && printf '.') || return 1
  content=${content%.}
  content=${content%$'\n'}
  if [[ "$content" == *$'\n'* ]]; then
    line2=${content#*$'\n'}
    case "$line2" in
      *$'\n'*) return 0 ;;
      start=?*) FM_SESSION_LOCK_START=${line2#start=} ;;
      *) return 0 ;;
    esac
  fi
  FM_SESSION_LOCK_PID=${content%%$'\n'*}
  return 0
}
