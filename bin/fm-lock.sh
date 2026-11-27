#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# A launch-v1 home admits the private launch binding, or holds startup-only
# authority around a standalone startup. The default format uses the legacy
# harness ancestry. fm-session-lock-record-lib.sh owns both record formats.
# Usage: fm-lock.sh           acquire; exit 1 unless ownership is verified
#        fm-lock.sh status    print holder and liveness; always exits 0
#        fm-lock.sh verify [engine-pid]  verify current ownership; print generation
#        fm-lock.sh verify-hook         verify a continuing session; print generation
#        fm-lock.sh bind-engine <pid>  issue a binding to the directly calling adapter
# For a recorded owner in launch-v1 mode, status distinguishes a live owner,
# positive evidence of exit or PID reuse, and uncertainty about the record or
# process. Legacy status uses the harness identity and optional start token.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"

# Share the launch-binding and legacy harness checks with the Stop hooks.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

if [ "${1:-}" = bind-engine ]; then
  fm_session_owner_enabled && [ "$#" -eq 2 ] && [ "$2" = "$PPID" ] || exit 1
  # The engine must request a binding for itself. A nested engine gets a fresh
  # binding, independent of any binding it inherited from its parent.
  fm_session_owner_bind "$2" native || exit 1
  printf '%s\n' "$FM_SESSION_OWNER_HOME" "$FM_SESSION_OWNER_PID" "$FM_SESSION_OWNER_START" \
    "$FM_SESSION_OWNER_ID" "$FM_SESSION_OWNER_KIND"
  exit 0
fi

if [ "${1:-}" = verify ] || [ "${1:-}" = verify-hook ]; then
  fm_session_lock_owned_by_self "$STATE" || exit 1
  if [ "$1" = verify-hook ]; then [ "$FM_SESSION_LOCK_KIND" != startup ] || exit 1; fi
  if [ "$#" -gt 1 ]; then
    [ "$FM_SESSION_LOCK_PID" = "$2" ] || exit 1
    [ "$FM_SESSION_LOCK_KIND" != startup ] || exit 1
  fi
  printf '%s\n' "${FM_SESSION_LOCK_GENERATION:-legacy}"
  exit 0
fi

if [ "${1:-}" = "status" ]; then
  if [ ! -e "$LOCK" ] && [ ! -L "$LOCK" ]; then echo "lock: free"; exit 0; fi
  fm_session_lock_read "$LOCK" || {
    if fm_session_owner_mode_active "$STATE"; then
      echo "lock: uncertain (unreadable owner record)"
    else
      echo "lock: unreadable"
    fi
    exit 0
  }
  old=$FM_SESSION_LOCK_PID
  if fm_session_owner_enabled || [ -n "$FM_SESSION_LOCK_GENERATION" ]; then
    fm_session_owner_liveness "$old" "$FM_SESSION_LOCK_START"
    case $? in
      0) echo "lock: held by live ${FM_SESSION_LOCK_KIND:-legacy} pid $old" ;;
      2) echo "lock: stale (pid $old exited or was reused)" ;;
      *) echo "lock: uncertain (cannot inspect pid $old)" ;;
    esac
  elif fm_session_lock_owner_alive "$old" "$FM_SESSION_LOCK_START"; then
    echo "lock: held by live harness pid $old"
  else
    echo "lock: stale (pid $old dead, reused, or not a harness)"
  fi
  exit 0
fi

mkdir -p "$STATE" 2>/dev/null || {
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit 1
}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
CLAIM_LOCK="$STATE/.lock.acquire"
CLAIM_LOCK_HELD=0
release_claim_lock() {
  if [ "$CLAIM_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=0
  fi
}
trap release_claim_lock EXIT
trap 'exit 1' HUP INT TERM

if [ "$#" -ne 0 ]; then
  echo 'usage: fm-lock.sh [status|verify]' >&2
  exit 2
fi
if fm_session_owner_mode_active "$STATE" || fm_session_owner_context_present; then
  fm_session_owner_context || {
    echo 'error: no valid session launch binding; enter through fm-session-launch.sh or run fm-session-start.sh' >&2
    exit 1
  }
  launch_candidate_may_replace() {
    fm_session_owner_liveness "$FM_SESSION_LOCK_PID" "$FM_SESSION_LOCK_START"
    case $? in
      0)
        echo "error: another live firstmate session holds the lock (pid $FM_SESSION_LOCK_PID)" >&2
        return 1
        ;;
      2) return 0 ;;
      *) echo "error: cannot verify liveness of recorded session owner pid $FM_SESSION_LOCK_PID" >&2; return 1 ;;
    esac
  }
  # Exact renewal can proceed while its own bounded startup worker holds the
  # publication mutex. Live and uncertain foreign owners can be refused
  # immediately; any verdict that permits publication is checked again below.
  if fm_session_lock_read "$LOCK"; then
    if fm_session_owner_matches_context; then
      printf 'lock acquired: %s pid %s\n' "$FM_SESSION_LOCK_KIND" "$FM_SESSION_LOCK_PID"
      exit 0
    fi
    launch_candidate_may_replace || exit 1
  fi
  claim_launch_owner() (
    fm_lock_acquire_wait "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=1
    trap release_claim_lock EXIT
    trap 'exit 1' HUP INT TERM
    fm_session_owner_context || { echo 'error: session owner lifetime ended during lock acquisition' >&2; exit 1; }
    if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
      fm_session_lock_read "$LOCK" || { echo 'error: session owner record is unreadable' >&2; exit 1; }
      fm_session_owner_matches_context && exit 0
      launch_candidate_may_replace || exit 1
    fi
    fm_session_owner_publish "$LOCK" "$FM_LOCK_OWNER_DIR"
  )
  claim_launch_owner || exit 1
  fm_session_owner_context || exit 1
  if ! fm_session_lock_read "$LOCK" || ! fm_session_owner_matches_context; then
    echo 'error: cannot verify committed session owner generation' >&2
    exit 1
  fi
  printf 'lock acquired: %s pid %s\n' "$FM_SESSION_LOCK_KIND" "$FM_SESSION_LOCK_PID"
  exit 0
fi

me=$(fm_harness_ancestry_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
probe=$(mktemp "$STATE/.lock-write.XXXXXX" 2>/dev/null) || {
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
}
rm -f "$probe" 2>/dev/null || {
  echo "error: cannot clean session-lock publication probe; operate read-only until resolved" >&2
  exit 1
}
me_start=$(fm_pid_start_time "$me") || me_start=''
legacy_self=0
require_legacy_mode() {
  if fm_session_owner_mode_active "$STATE" || [ -n "${FM_SESSION_LOCK_GENERATION:-}" ]; then
    echo 'error: launch ownership is active; use a valid session binding' >&2
    return 1
  fi
}
if [ -f "$LOCK" ] && [ ! -L "$LOCK" ] && fm_session_lock_read "$LOCK"; then
  require_legacy_mode || exit 1
  old=$FM_SESSION_LOCK_PID
  if [ "$old" = "$me" ]; then
    if [ "$FM_SESSION_LOCK_START" = "$me_start" ]; then
      echo "lock acquired: harness pid $me"
      exit 0
    fi
    [ -n "$FM_SESSION_LOCK_START" ] || legacy_self=1
  elif fm_session_lock_owner_alive "$old" "$FM_SESSION_LOCK_START"; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi

if ! fm_lock_try_acquire "$CLAIM_LOCK"; then
  if [ "$legacy_self" -eq 1 ]; then
    require_legacy_mode || exit 1
    echo "lock acquired: harness pid $me"
    exit 0
  fi
  sweep_pid=$(sed -n 's/^pid=//p' "$STATE/.startup-network.status" 2>/dev/null | tail -1)
  if [ "$(fm_lock_role "$CLAIM_LOCK" 2>/dev/null)" = startup-network ] \
    || { [ -n "${FM_LOCK_HELD_PID:-}" ] && [ "$FM_LOCK_HELD_PID" = "$sweep_pid" ]; }; then
    echo "error: the prior session's bounded startup sweep is finishing; operate read-only until it releases the fleet lock" >&2
    exit 1
  fi
  fm_lock_acquire_wait "$CLAIM_LOCK"
fi
CLAIM_LOCK_HELD=1
require_legacy_mode || exit 1

old=''
if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
  if [ ! -f "$LOCK" ] || [ -L "$LOCK" ]; then
    echo "error: session lock is not a regular file; operate read-only until resolved" >&2
    exit 1
  fi
  fm_session_lock_read "$LOCK" || {
    echo "error: session lock is unreadable; operate read-only until resolved" >&2
    exit 1
  }
  require_legacy_mode || exit 1
  old=$FM_SESSION_LOCK_PID
  if [ "$old" != "$me" ] && fm_session_lock_owner_alive "$old" "$FM_SESSION_LOCK_START"; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi
if [ "$old" = "$me" ]; then
  if [ "$FM_SESSION_LOCK_START" != "$me_start" ]; then
    if [ -z "$me_start" ]; then
      echo "error: cannot verify session lock owner's start time; operate read-only until resolved" >&2
      exit 1
    fi
    fm_session_lock_write_start "$LOCK" "$me" "$me_start"
  fi
else
  fm_session_lock_write "$LOCK" "$me" "$me_start"
fi || {
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
}
fm_session_lock_read "$LOCK" || {
  echo "error: cannot verify session lock ownership; operate read-only until resolved" >&2
  exit 1
}
if [ ! -f "$LOCK" ] || [ -L "$LOCK" ] || [ "$FM_SESSION_LOCK_PID" != "$me" ] \
  || [ "$FM_SESSION_LOCK_START" != "$me_start" ]; then
  echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
  exit 1
fi
release_claim_lock
echo "lock acquired: harness pid $me"
