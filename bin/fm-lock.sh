#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
# The sidecar records that process's start time, so a pid the kernel later
# reuses for an unrelated process no longer counts as the live owner; its format
# and start-time matching are owned by bin/fm-session-lock-record-lib.sh.
# Usage: fm-lock.sh           acquire; exit 1 unless ownership is verified
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
mkdir -p "$STATE" 2>/dev/null || {
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit 1
}

# Harness identity (FM_HARNESS_RE, ancestry walk, holder liveness) is owned by
# the shared session-lock lib so the Claude Stop auto-arm applies the exact
# same identity contract.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  fm_session_lock_read "$LOCK" || {
    echo "lock: unreadable"
    exit 0
  }
  old=$FM_SESSION_LOCK_PID
  if fm_session_lock_owner_alive "$old" "$FM_SESSION_LOCK_START"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead, reused, or not a harness)"; fi
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

me_start=$(fm_pid_start_time "$me") || me_start=''
legacy_self=0
if [ -f "$LOCK" ] && [ ! -L "$LOCK" ] && fm_session_lock_read "$LOCK"; then
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
    echo "lock acquired: harness pid $me"
    exit 0
  fi
  sweep_pid=$(sed -n 's/^pid=//p' "$STATE/.startup-network.status" 2>/dev/null | tail -1)
  if [ -n "${FM_LOCK_HELD_PID:-}" ] && [ "$FM_LOCK_HELD_PID" = "$sweep_pid" ]; then
    echo "error: the prior session's bounded startup sweep is finishing; operate read-only until it releases the fleet lock" >&2
    exit 1
  fi
  fm_lock_acquire_wait "$CLAIM_LOCK"
fi
CLAIM_LOCK_HELD=1

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
  old=$FM_SESSION_LOCK_PID
  if [ "$old" != "$me" ] && fm_session_lock_owner_alive "$old" "$FM_SESSION_LOCK_START"; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi
if [ "$old" = "$me" ]; then
  fm_session_lock_write_start "$LOCK" "$me" "$me_start"
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
