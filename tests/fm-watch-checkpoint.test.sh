#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived quiet checkpoint timeout"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  (
    sleep 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

test_registered_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod 0700 "$home/state/env-check.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" env-check >/dev/null \
    || fail "could not register checkpoint custom check"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for registered custom checks"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

test_foreground_wake_acknowledgement_and_owned_successor() (
  local home child='' attempts out guard_output drained seq generation status=0
  home=$(make_home owned-successor)
  export FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home"
  export FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
  export FM_SUPERVISION_MODEL=persistent
  # Read the production health interface against watcher-written state only.
  # shellcheck source=bin/fm-wake-lib.sh
  . "$ROOT/bin/fm-wake-lib.sh"
  printf 'kind=ship\n' > "$home/state/demo.meta"
  # Both children have bounded lifetimes and are waited even on assertion failure.
  trap '[ -z "$child" ] || wait "$child" 2>/dev/null || true' EXIT

  out="$home/first.out"
  "$CHECKPOINT" --seconds 12 > "$out" 2>&1 &
  child=$!
  attempts=0
  until fm_watcher_healthy "$home/state" "$ROOT/bin/fm-watch.sh" 300 "$home"; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 60 ] || fail "first checkpoint never published a live identity and fresh beacon"
    sleep 0.1
  done
  guard_output=$("$ROOT/bin/fm-guard.sh" 2>&1)
  assert_not_contains "$guard_output" 'WATCHER DOWN' "guard rejected a genuinely live checkpoint"
  printf 'done: known foreground wake\n' > "$home/state/demo.status"
  wait "$child" || status=$?
  child=''
  expect_code 0 "$status" "known wake checkpoint exit"
  assert_contains "$(cat "$out")" 'signal:' "known wake did not return to foreground caller"
  assert_absent "$home/state/.watch.lock/pid" "normal exit unexpectedly retained a watcher"
  guard_output=$("$ROOT/bin/fm-guard.sh" 2>&1)
  assert_contains "$guard_output" 'no live watcher process' "fresh leftover beacon hid the post-wake gap"

  drained=$("$ROOT/bin/fm-wake-drain.sh" 2>&1)
  assert_contains "$drained" 'known foreground wake' "drain did not present the durable event"
  seq=$(printf '%s\n' "$drained" | sed -n 's/.*--ack-through \([0-9]*\) --recovery-generation .*/\1/p')
  generation=$(printf '%s\n' "$drained" | sed -n 's/.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p')
  [ -n "$seq" ] && [ -n "$generation" ] || fail "drain omitted its generation-bound acknowledgement"

  # Deliberately retain the pending handling generation while the caller starts
  # its successor: an unacknowledged episode alone must not report watcher down.
  "$CHECKPOINT" --seconds 5 > "$home/successor.out" 2>&1 &
  child=$!
  attempts=0
  until fm_watcher_healthy "$home/state" "$ROOT/bin/fm-watch.sh" 300 "$home"; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 40 ] || fail "caller-owned successor never became healthy"
    sleep 0.1
  done
  guard_output=$("$ROOT/bin/fm-guard.sh" 2>&1)
  assert_not_contains "$guard_output" 'WATCHER DOWN' "unacknowledged episode caused a false full liveness alarm"
  assert_not_contains "$guard_output" 'watcher still down' "unacknowledged episode caused a false liveness reminder"
  assert_contains "$guard_output" 'queued wakes pending' "healthy successor hid the independent pending wake"
  "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$generation" \
    || fail "generation-bound acknowledgement failed"
  [ ! -s "$home/state/.wake-queue" ] || fail "acknowledged wake remains queued"
  status=0
  wait "$child" || status=$?
  child=''
  expect_code 124 "$status" "quiet caller-owned successor exit"
  assert_absent "$home/state/.watch.lock/pid" "quiet successor left a polling process behind"
  pass "foreground wake is durable, caller owns its successor, and pending recovery does not falsify live health"
)

test_quiet_checkpoint_exits_124_cleanly
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
test_foreground_wake_acknowledgement_and_owned_successor
