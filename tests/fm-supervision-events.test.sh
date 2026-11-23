#!/usr/bin/env bash
# tests/fm-supervision-events.test.sh - unit tests for the watcher's native
# event-wait splice (event_wait_or_sleep in bin/fm-watch.sh and
# handle_push_transition in bin/fm-push-transition-lib.sh). The watcher's source
# guard lets this file source it to load
# the functions WITHOUT acquiring the singleton lock or entering the blocking
# loop; wake/sleep and the backend dispatchers are overridden so the exemptions,
# capability memo, and fail-closed disable are asserted without launching Herdr.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-supervision-events)
STATE_DIR="$TMP/state"
mkdir -p "$STATE_DIR"

# Source the watcher with an isolated state/home. The guard returns before the
# lock/loop, so only the functions load.
export FM_STATE_OVERRIDE="$STATE_DIR"
export FM_ROOT_OVERRIDE="$ROOT"
# Production modules are independently linted canonical roots. Keep this test's
# ShellCheck context local while preserving its unchanged runtime source path.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-watch.sh"

# Overrides: capture wake reasons and neutralize real sleeps (POLL is 15s).
WAKE_LOG="$TMP/wakes"
SLEEP_LOG="$TMP/sleeps"
wake() { printf '%s\n' "$1" >> "$WAKE_LOG"; return 0; }
sleep() { printf 'SLEEP\n' >> "$SLEEP_LOG"; }
# shellcheck disable=SC2329 # Runtime override called by the isolated watcher.
watcher_publish_beat() { return 0; }

fm_backend_source herdr || fail "could not load the Herdr adapter"
fm_backend_herdr_cli() {
  [ "$2 $3" = "pane get" ] || return 1
  printf '{"result":{"pane":{"pane_id":"%s","terminal_id":"%s"}}}\n' "$4" "${live_terminal:-term-worker}"
}

reset_state() {
  rm -f "$STATE_DIR"/*.meta "$STATE_DIR"/*.status "$STATE_DIR"/.wake-queue \
    "$STATE_DIR"/.wake-queue.seq "$STATE_DIR"/.watch-triage.log \
    "$STATE_DIR"/.herdr-escalated-* "$TMP"/panes "$TMP"/wtcalls "$TMP"/wtcalled 2>/dev/null || true
  : > "$WAKE_LOG"
  : > "$SLEEP_LOG"
  _event_cap_key=""
  _event_cap_ok=0
  _event_cap_fails=0
}

mkrec() {  # <pane_id> <status>
  fm_transition_record "$1" "wG" "" "$2" claude
}

# --- handle_push_transition: enqueue + wake for a non-paused blocked crew -----

reset_state
fm_write_meta "$STATE_DIR/tk1.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship" "herdr_terminal_id=term-worker"
handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
[ -e "$STATE_DIR/.wake-queue" ] || fail "handle_push_transition should enqueue a wake for a blocked crew"
grep -q 'stale' "$STATE_DIR/.wake-queue" || fail "the enqueued wake must be a stale record: $(cat "$STATE_DIR/.wake-queue")"
grep -q 'default:wG:pQ' "$STATE_DIR/.wake-queue" || fail "the stale record must name the crew's window"
grep -q 'herdr: agent blocked' "$STATE_DIR/.wake-queue" || fail "the stale payload must name the herdr-blocked cause"
[ -s "$WAKE_LOG" ] || fail "handle_push_transition must wake the supervisor for a blocked crew"
[ -e "$STATE_DIR/.herdr-escalated-default_wG_pQ" ] || fail "handle_push_transition must commit dedupe only after enqueue"
pass "handle_push_transition: a blocked crew enqueues a stale wake naming its window and wakes the supervisor"

reset_state
fm_write_meta "$STATE_DIR/tk1.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship" "herdr_terminal_id=term-worker"
live_terminal=term-foreign handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
[ ! -e "$STATE_DIR/.wake-queue" ] && [ ! -s "$WAKE_LOG" ] \
  && [ ! -e "$STATE_DIR/.herdr-escalated-default_wG_pQ" ] || fail "a recycled pane woke the supervisor or advanced dedupe"
pass "handle_push_transition: a blocked foreign terminal cannot wake the supervisor or advance dedupe"

reset_state
fm_write_meta "$STATE_DIR/tk1.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship" "herdr_terminal_id=term-worker"
(
  # shellcheck disable=SC2329 # Runtime override called by the isolated production owner.
  fm_wake_append() { return 1; }
  handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
) >/dev/null 2>&1 || true
[ ! -e "$STATE_DIR/.herdr-escalated-default_wG_pQ" ] || fail "a failed durable enqueue must leave the blocked edge eligible for reconnect reconciliation"
pass "handle_push_transition: enqueue failure cannot commit the Herdr dedupe marker"

# --- handle_push_transition: absorb (no wake, no enqueue) for a declared pause -

reset_state
fm_write_meta "$STATE_DIR/tk2.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship" "herdr_terminal_id=term-worker"
printf 'paused: waiting on the upstream release\n' > "$STATE_DIR/tk2.status"
handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
if [ -e "$STATE_DIR/.wake-queue" ] && grep -q 'stale' "$STATE_DIR/.wake-queue"; then
  fail "a declared-pause crew must NOT be fast-escalated: $(cat "$STATE_DIR/.wake-queue")"
fi
[ ! -s "$WAKE_LOG" ] || fail "a declared-pause crew must not wake the supervisor from the event fast-path"
grep -q 'absorbed push' "$STATE_DIR/.watch-triage.log" 2>/dev/null || fail "the paused absorb should be logged to the triage log"
pass "handle_push_transition: a declared-pause crew is absorbed (no fast wake), left to the poll loop's long cadence"

# --- handle_push_transition: absorb for a verified captain-held transfer -------

reset_state
fm_write_meta "$STATE_DIR/tk2h.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship" "herdr_terminal_id=term-worker"
printf 'captain-held [key=route]: tracked by task-decision-route\n' > "$STATE_DIR/tk2h.status"
handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
if [ -e "$STATE_DIR/.wake-queue" ] && grep -q 'stale' "$STATE_DIR/.wake-queue"; then
  fail "a captain-held crew must NOT be fast-escalated: $(cat "$STATE_DIR/.wake-queue")"
fi
[ ! -s "$WAKE_LOG" ] || fail "a captain-held crew must not wake the supervisor from the event fast-path"
grep -q 'absorbed push' "$STATE_DIR/.watch-triage.log" 2>/dev/null || fail "the captain-held absorb should be logged to the triage log"
pass "handle_push_transition: a captain-held crew is absorbed (no fast wake), left to the poll loop's long cadence"

reset_state
fm_write_meta "$STATE_DIR/tk1.meta" "window=default:wG:pQ" "backend=herdr" "herdr_terminal_id=term-worker"
record=$(fm_task_inbox_write "$STATE_DIR" tk1 'fixture steer') || fail "could not create a steer"
terminal_calls="$TMP/terminal-calls"
(
  fm_task_inbox_due_action() { printf 'ring %s' "$record"; }
  fm_backend_herdr_pane_agent_state() { printf 'live'; }
  fm_backend_herdr_cli() {
    case "$2 $3" in
      'pane get')
        fm_write_meta "$STATE_DIR/tk1.meta" "window=default:wG:pR" "backend=herdr" "herdr_terminal_id=term-replacement"
        printf '{"result":{"pane":{"pane_id":"%s","terminal_id":"term-worker"}}}\n' "$4"
        ;;
      'status --json')
        printf '{"server":{"running":true}}\n'
        ;;
      *)
        printf '%s\n' "$*" >> "$terminal_calls"
        ;;
    esac
  }
  inbox_steer_check default:wG:pQ tk1 herdr
)
[ "$(fm_meta_get "$STATE_DIR/tk1.meta" window)" = default:wG:pR ] || fail "relaunch did not move the binding"
[ -f "$record" ] && [ ! -s "$terminal_calls" ] || fail "the watcher accessed a terminal after its task moved"
pass "inbox_steer_check: a relaunch after liveness leaves the steer queued and forbids capture or input at its old pane"

reset_state
fm_write_meta "$STATE_DIR/a-old.meta" "window=default:wG:pQ" "backend=herdr" "herdr_terminal_id=term-old"
fm_write_meta "$STATE_DIR/z-new.meta" "window=default:wG:pQ" "backend=herdr" "herdr_terminal_id=term-worker"
printf 'paused: waiting on the upstream release\n' > "$STATE_DIR/a-old.status"
handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
[ -s "$WAKE_LOG" ] || fail "the old task's pause suppressed the live worker's blocked event"
pass "handle_push_transition: a stale record sharing the slot cannot displace the bound worker"

test_native_wait_keeps_subscription() (
  local mode=$1 dir="$TMP/native-$1" server i path watch_pid=''
  mkdir -p "$dir"
  reset_state
  export FM_GUARD_GRACE=4 TMPDIR="$dir"
  WATCHER_WAIT_LIMIT=2
  POLL=15
  fm_write_meta "$STATE_DIR/tk3.meta" 'window=default:wG:pQ' 'backend=herdr' 'kind=ship' 'herdr_terminal_id=term-worker'
  fm_backend_herdr_commit_transition "$STATE_DIR" default "$(mkrec wG:pQ blocked)" \
    || fail "could not record the previous blocked edge"
  fm_backend_events_capable() { return 0; }
  fm_backend_herdr_socket_path() { printf '%s\n' "$dir/socket"; }
  fm_backend_herdr_agent_status_raw() {
    if [ "$mode" = cancel ]; then
      : > "$dir/level-started"
      command sleep 4
    fi
    printf '%s\n' blocked
  }
  fm_backend_herdr_event_reader_cmd() { printf '%s\n' python3 "$ROOT/bin/backends/herdr-eventwait.py"; }
  watcher_publish_beat() { printf '%s\n' beat >> "$dir/beats"; }

  python3 - "$dir" "$mode" "$FM_GUARD_GRACE" <<'PYTHON' &
import json
from pathlib import Path
import select
import socket
import sys
import time

directory, mode, grace = Path(sys.argv[1]), sys.argv[2], float(sys.argv[3])
beats = directory / "beats"
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
    server.bind(str(directory / "socket"))
    server.listen()
    server.settimeout(10)
    connection, _ = server.accept()
    with connection, connection.makefile("r") as requests:
        connection.settimeout(10)
        assert json.loads(requests.readline())["method"] == "events.subscribe"

        def reject_reconnect(delay):
            ready, _, _ = select.select([server], [], [], delay)
            if ready:
                server.accept()[0].close()
                raise AssertionError("watcher opened another subscription")

        def await_beat(count, started, release_after):
            seen = None
            while time.monotonic() - started < grace:
                reject_reconnect(0.02)
                now = time.monotonic()
                if seen is None and beats.exists() and len(beats.read_text().splitlines()) >= count:
                    seen = now
                if seen is not None and now >= release_after:
                    return seen
            raise AssertionError("watcher did not publish a beacon within grace")

        started = time.monotonic()
        if mode == "progress":
            first_beat = await_beat(1, started, started + 3)
        connection.sendall(b'{"result":{"type":"subscription_started"}}\n')
        if mode == "cancel":
            connection.settimeout(2)
            assert connection.recv(1) == b"", "subscriber outlived cancellation"
        else:
            await_beat(2, first_beat, time.monotonic() + 1.5)
            for status in ("working", "blocked"):
                event = {
                    "event": "pane.agent_status_changed",
                    "data": {"pane_id": "wG:pQ", "workspace_id": "wG", "agent_status": status, "agent": "claude"},
                }
                connection.sendall((json.dumps(event) + "\n").encode())
            reject_reconnect(0.1)
PYTHON
  server=$!
  trap 'if [ -n "$watch_pid" ]; then kill "$watch_pid" 2>/dev/null || true; fi
    kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true' EXIT
  for ((i=0; i<100; i++)); do
    [ ! -S "$dir/socket" ] || break
    command sleep 0.02
  done
  [ -S "$dir/socket" ] || fail "fixture subscription socket did not open"

  if [ "$mode" = cancel ]; then
    ( trap watcher_cleanup_capture EXIT; event_wait_or_sleep ) &
    watch_pid=$!
    for ((i=0; i<100; i++)); do
      [ ! -e "$dir/level-started" ] || break
      command sleep 0.02
    done
    [ -e "$dir/level-started" ] || fail "native level read did not start"
    kill -TERM "$watch_pid" || fail "could not stop the native wait"
    wait "$server" || fail "native subscription did not close while the level read was pending"
    for ((i=0; i<100; i++)); do
      kill -0 "$watch_pid" 2>/dev/null || break
      command sleep 0.02
    done
    ! kill -0 "$watch_pid" 2>/dev/null || fail "native wait did not shut down"
    wait "$watch_pid" 2>/dev/null || true
    watch_pid=
    for path in "$dir"/fm-watch-events.* "$dir"/fm-herdr-eventwait.*; do
      [ ! -e "$path" ] || fail "native wait leaked its FIFO directory"
    done
    pass "event_wait_or_sleep: cancelling a slow level read closes the subscription and removes its FIFOs"
  else
    event_wait_or_sleep
    wait "$server" || fail "fixture server did not see timely progress on a single subscription"
    [ ! -s "$SLEEP_LOG" ] || fail "the delayed acknowledgement caused a fallback to polling"
    assert_grep 'herdr: agent blocked' "$WAKE_LOG" "the working edge must rearm delivery of the second blocked edge"
    pass "event_wait_or_sleep: beacons, delayed acknowledgement, and blocked-again delivery share one subscription"
  fi
  trap - EXIT
)

test_native_wait_keeps_subscription progress || exit $?
test_native_wait_keeps_subscription cancel || exit $?

test_optional_capture_failures() (
  reset_state
  fm_write_meta "$STATE_DIR/tk3.meta" 'window=default:wG:pQ' 'backend=herdr' 'kind=ship' 'herdr_terminal_id=term-worker'
  fm_backend_events_capable() { return 0; }
  fm_backend_herdr_socket_path() { printf '%s\n' "$TMP/unused.sock"; }
  mkfifo() { return 1; }
  event_wait_or_sleep
  [ -s "$SLEEP_LOG" ] || fail "native FIFO failure must fall back to polling"

  mktemp() { return 1; }
  FM_PENDING_REPLY_OBSERVATION=idle
  watcher_remote_observe printf busy || fail "remote capture failure must not stop supervision"
  [ "$FM_PENDING_REPLY_OBSERVATION" = unknown ] || fail "remote capture failure must leave observation unknown"
  pass "watcher: optional capture setup failures degrade to polling or unknown"
)

test_optional_capture_failures || exit $?

test_remote_wait_uses_elapsed_budget() (
  local tick=$SECONDS i
  WATCHER_WAIT_LIMIT=1
  for ((i=0; i<100; i++)); do
    [ "$SECONDS" -eq "$tick" ] || break
    command sleep 0.02
  done
  command sleep 0.65
  watcher_remote_observe bash -c 'sleep 0.55; printf busy' || fail "remote observation could not run"
  [ "$FM_PENDING_REPLY_OBSERVATION" = busy ] || fail "a subsecond reply was discarded within a one-second budget"
  pass "watcher: a remote observation gets its full elapsed budget across a clock tick"
)

test_remote_wait_uses_elapsed_budget || exit $?

# --- event_wait_or_sleep: secondmate windows are excluded from the pane list --

reset_state
fm_write_meta "$STATE_DIR/a-old.meta" "window=default:wG:pQ" "backend=herdr" "herdr_terminal_id=term-old"
fm_write_meta "$STATE_DIR/tk3.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship" "herdr_terminal_id=term-worker"
fm_write_meta "$STATE_DIR/sm1.meta" "window=default:wA:pS" "backend=herdr" "kind=secondmate"
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_events_capable() { return 0; }
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_wait_transition() { shift 4; printf '%s\n' "$*" > "$TMP/panes"; return 1; }
event_wait_or_sleep
PANES=$(cat "$TMP/panes" 2>/dev/null || true)
case "$PANES" in *"default:wG:pQ"*) : ;; *) fail "the ship window must be in the event pane list, got '$PANES'" ;; esac
case "$PANES" in *"default:wA:pS"*) fail "a kind=secondmate window must be EXCLUDED from the event pane list, got '$PANES'" ;; *) : ;; esac
pass "event_wait_or_sleep: herdr windows go on the event pane list, but kind=secondmate endpoints are excluded"

reset_state
fm_write_meta "$STATE_DIR/tk3.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship" "herdr_terminal_id=term-worker"
CAP_CALLS=0
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_events_capable() { CAP_CALLS=$((CAP_CALLS + 1)); return 0; }
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_wait_transition() {
  [ "${FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED:-0}" = 1 ] || fail "cached capability verdict was not passed to the wait"
  return 1
}
event_wait_or_sleep
event_wait_or_sleep
[ "$CAP_CALLS" = 1 ] || fail "capability probe must be memoized across waits, got $CAP_CALLS calls"
pass "event_wait_or_sleep: one cached capability probe owns validation across bounded waits"

# --- event_wait_or_sleep: a tmux-only home never runs the event path ----------

reset_state
fm_write_meta "$STATE_DIR/tk4.meta" "window=fmses:fm-tk4" "kind=ship"   # no backend= -> tmux
# shellcheck disable=SC2329 # Runtime override called by the isolated watcher.
fm_backend_wait_transition() { printf 'CALLED\n' > "$TMP/wtcalled"; return 1; }
event_wait_or_sleep
[ ! -e "$TMP/wtcalled" ] || fail "a tmux-only home must never invoke the event wait path"
grep -q 'SLEEP' "$SLEEP_LOG" || fail "a tmux-only home must sleep POLL exactly as before"
pass "event_wait_or_sleep: a home with no push-capable window is inert (sleeps POLL, never touches the event path)"

# --- event_wait_or_sleep: runtime failures disable the event path (fail-closed)

reset_state
fm_write_meta "$STATE_DIR/tk5.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship" "herdr_terminal_id=term-worker"
export EVENT_CAP_FAIL_MAX=2
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_events_capable() { return 0; }
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_wait_transition() { printf 'WT\n' >> "$TMP/wtcalls"; return 2; }
: > "$TMP/wtcalls"
event_wait_or_sleep   # fails=1
event_wait_or_sleep   # fails=2 -> disable
event_wait_or_sleep   # disabled: sleeps without calling wait_transition
WTN=$(wc -l < "$TMP/wtcalls" | tr -d '[:space:]')
[ "$WTN" = 2 ] || fail "after EVENT_CAP_FAIL_MAX connect failures the event path must be disabled for the process (expected 2 wait_transition calls, got $WTN)"
pass "event_wait_or_sleep: consecutive event-path failures disable the fast-path and revert to pure polling (fail-closed)"

echo "# fm-supervision-events.test.sh: all assertions passed"
