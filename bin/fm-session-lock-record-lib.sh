#!/usr/bin/env bash
# shellcheck disable=SC2034

# ---------------------------------------------------------------------------
# Session-lock owner record.
#
# state/.lock contains a single harness PID, so in-process Pi, omp, and
# OpenCode readers can keep using it across a live update.
# When a start token is available, the writer publishes state/.lock.start
# first, with that same PID on line 1 and start=<token> on line 2.
# It then commits the PID line in state/.lock by atomic rename.
# A missing sidecar or one naming a different PID leaves the lock in PID-only
# mode. A sidecar naming the owner must provide a matching process start time.

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
  [ -n "$2" ] || return 1
  printf '%s\nstart=%s\n' "$1" "$2"
}

# Read the owner PID and its associated start token into the two output globals.
FM_SESSION_LOCK_PID=''
FM_SESSION_LOCK_START=''
fm_session_lock_read() {  # <lock-file>
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
