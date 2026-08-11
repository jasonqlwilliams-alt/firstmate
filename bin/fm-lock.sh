#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
# Usage: fm-lock.sh           acquire; exit 1 unless ownership is verified
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
LOCK_IDENTITY="$STATE/.lock.pid-identity"
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
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "lock: unreadable"
    exit 0
  }
  if fm_harness_pid_alive "$old"; then
    echo "lock: held by live harness pid $old"
  else
    holder_state=$?
    case "$holder_state" in
      1) echo "lock: stale (pid $old dead, terminal, or not a harness)" ;;
      3) echo "lock: stopped (pid $old requires fenced recovery)" ;;
      *) echo "lock: unknown (cannot classify harness pid $old)" ;;
    esac
  fi
  exit 0
fi

me=$(fm_harness_ancestry_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
if [ -f "$LOCK" ] && [ ! -L "$LOCK" ]; then
  existing_owner=$(cat "$LOCK" 2>/dev/null || true)
  if fm_session_lock_pid_owned_by_self "$STATE" "$existing_owner"; then
    me=$existing_owner
  fi
fi
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
me_identity=$(fm_pid_identity "$me" 2>/dev/null) || {
  echo "error: cannot establish session lock owner identity; operate read-only until resolved" >&2
  exit 1
}
probe=$(mktemp "$STATE/.lock-write.XXXXXX" 2>/dev/null) || {
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
}
rm -f "$probe" 2>/dev/null || {
  echo "error: cannot clean session-lock publication probe; operate read-only until resolved" >&2
  exit 1
}
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

if [ -f "$LOCK" ] && [ ! -L "$LOCK" ]; then
  old=$(cat "$LOCK" 2>/dev/null || true)
  if [ "$old" = "$me" ]; then
    recorded_identity=$(fm_session_lock_recorded_identity "$STATE" "$old" 2>/dev/null || true)
    if [ "$recorded_identity" = "$me_identity" ]; then
      echo "lock acquired: harness pid $me"
      exit 0
    fi
  fi
  if [ "$old" != "$me" ]; then
    if fm_harness_pid_alive "$old"; then
      echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
      exit 1
    else
      holder_state=$?
      if [ "$holder_state" -ne 1 ] && [ "$holder_state" -ne 3 ]; then
        echo "error: cannot classify session lock owner process (pid $old); operate read-only until resolved" >&2
        exit 1
      fi
    fi
  fi
fi

if ! fm_lock_try_acquire "$CLAIM_LOCK"; then
  sweep_pid=$(sed -n 's/^pid=//p' "$STATE/.startup-network.status" 2>/dev/null | tail -1)
  if [ -n "${FM_LOCK_HELD_PID:-}" ] && [ "$FM_LOCK_HELD_PID" = "$sweep_pid" ]; then
    echo "error: the prior session's bounded startup sweep is finishing; operate read-only until it releases the fleet lock" >&2
    exit 1
  fi
  fm_lock_acquire_wait "$CLAIM_LOCK"
fi
CLAIM_LOCK_HELD=1

if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
  if [ ! -f "$LOCK" ] || [ -L "$LOCK" ]; then
    echo "error: session lock is not a regular file; operate read-only until resolved" >&2
    exit 1
  fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "error: session lock is unreadable; operate read-only until resolved" >&2
    exit 1
  }
  if [ "$old" != "$me" ]; then
    if fm_harness_pid_alive "$old"; then
      echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
      exit 1
    else
      holder_state=$?
      case "$holder_state" in
        1)
          if ! fm_harness_pid_fence_stopped "$old"; then
            echo "error: prior session execution could not be safely excluded (pid $old); operate read-only until resolved" >&2
            exit 1
          fi
          ;;
        3)
          recorded_identity=$(fm_session_lock_recorded_identity "$STATE" "$old" 2>/dev/null || true)
          if ! fm_harness_pid_fence_stopped "$old" "$recorded_identity"; then
            echo "error: stopped session lock owner could not be safely fenced (pid $old); operate read-only until resolved" >&2
            exit 1
          fi
          ;;
        *)
          echo "error: cannot classify session lock owner process (pid $old); operate read-only until resolved" >&2
          exit 1
          ;;
      esac
    fi
  fi
fi
identity_tmp=$(mktemp "$STATE/.lock-pid-identity.XXXXXX" 2>/dev/null) || {
  echo "error: cannot write session lock owner identity; operate read-only until resolved" >&2
  exit 1
}
if ! printf '%s\n%s\n' "$me" "$me_identity" > "$identity_tmp" 2>/dev/null \
  || ! chmod 0600 "$identity_tmp" 2>/dev/null \
  || ! mv -f "$identity_tmp" "$LOCK_IDENTITY" 2>/dev/null; then
  rm -f "$identity_tmp" 2>/dev/null || true
  echo "error: cannot write session lock owner identity; operate read-only until resolved" >&2
  exit 1
fi
if ! { printf '%s\n' "$me" > "$LOCK"; } 2>/dev/null; then
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
fi
written=$(cat "$LOCK" 2>/dev/null) || {
  echo "error: cannot verify session lock ownership; operate read-only until resolved" >&2
  exit 1
}
written_identity=$(fm_session_lock_recorded_identity "$STATE" "$me" 2>/dev/null || true)
if [ ! -f "$LOCK" ] || [ -L "$LOCK" ] || [ "$written" != "$me" ] \
  || [ "$written_identity" != "$me_identity" ]; then
  echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
  exit 1
fi
release_claim_lock
echo "lock acquired: harness pid $me"
