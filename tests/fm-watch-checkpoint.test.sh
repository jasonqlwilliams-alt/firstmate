#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
# Each test that exports runs in its own subshell, so its exports stay deliberately local.
# shellcheck disable=SC2030,SC2031
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)

if [ "${FM_CHECKPOINT_TEST_HARNESS:-0}" != 1 ]; then
  ln -s /bin/bash "$TMP_ROOT/codex" || exit 1
  unset CLAUDECODE CURSOR_AGENT CURSOR_INVOKED_AS GEMINI_CLI PI_CODING_AGENT GROK_AGENT FM_OMP_HARNESS ANTIGRAVITY_AGENT
  unset ATLASSIAN_AGENT_TYPE ROVODEV_CLI FM_SUPERVISION_MODEL
  # shellcheck disable=SC2016
  FM_CHECKPOINT_TEST_HARNESS=1 "$TMP_ROOT/codex" -c '"$@"; status=$?; exit "$status"' _ "$0" "$@"
  exit $?
fi

export FM_GUARD_GRACE=300

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
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 3 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit ($(cat "$err"))"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 3s" "quiet checkpoint line missing"
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
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 12 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "signal checkpoint exit ($(cat "$out" "$err"))"
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
  FM_HOME="$home" "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

test_foreground_wake_acknowledgement_and_owned_successor() (
  local home child='' attempts out guard_output drained seq generation status=0 cat_bin close_gate deadline
  home=$(make_home owned-successor)
  export FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home"
  export FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
  export FM_SUPERVISION_MODEL=persistent
  "$ROOT/bin/fm-lock.sh" >/dev/null || fail "fixture could not acquire the fleet lock"
  # Read the production health interface against watcher-written state only.
  # shellcheck source=bin/fm-wake-lib.sh
  . "$ROOT/bin/fm-wake-lib.sh"
  printf 'kind=ship\n' > "$home/state/demo.meta"
  # Both children have bounded lifetimes and are waited even on assertion failure.
  close_gate="$home/close-gate"
  mkdir "$close_gate" "$home/bin" || fail "could not create checkpoint close gate"
  trap ': > "$close_gate/release"; [ -z "$child" ] || wait "$child" 2>/dev/null || true' EXIT

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
  assert_contains "$guard_output" 'between foreground checkpoints' "normal signal return did not explain the gap"
  assert_not_contains "$guard_output" 'WATCHER DOWN' "normal signal return alarmed"

  drained=$("$ROOT/bin/fm-wake-drain.sh" 2>&1)
  assert_contains "$drained" 'known foreground wake' "drain did not present the durable event"
  seq=$(printf '%s\n' "$drained" | sed -n 's/.*--ack-through \([0-9]*\) --recovery-generation .*/\1/p')
  generation=$(printf '%s\n' "$drained" | sed -n 's/.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p')
  [ -n "$seq" ] && [ -n "$generation" ] || fail "drain omitted its generation-bound acknowledgement"

  # Deliberately retain the pending handling generation while the caller starts
  # its successor: an unacknowledged episode alone must not report watcher down.
  cat_bin=$(command -v cat) || fail "could not locate cat for the close fixture"
  cat > "$home/bin/cat" <<'SH'
#!/usr/bin/env bash
if [ "$#" -eq 1 ] && [ "$1" = "${FM_WATCH_CHECKPOINT_CLOSE:-}" ] \
  && IFS= read -r close < "$1" && [ "$close" = quiet ]; then
  : > "$FM_TEST_CLOSE_GATE/ready" || exit 1
  deadline=$((SECONDS + FM_TEST_STUB_MAX_BLOCK_SECONDS))
  until [ -f "$FM_TEST_CLOSE_GATE/release" ]; do
    [ "$SECONDS" -lt "$deadline" ] || exit 1
    sleep 0.1
  done
  "$FM_TEST_REAL_CAT" "$@" || exit $?
  : > "$FM_TEST_CLOSE_GATE/forwarded"
else
  exec "$FM_TEST_REAL_CAT" "$@"
fi
SH
  chmod +x "$home/bin/cat"
  PATH="$home/bin:$PATH" FM_TEST_REAL_CAT="$cat_bin" FM_TEST_CLOSE_GATE="$close_gate" \
    "$CHECKPOINT" --seconds 8 > "$home/successor.out" 2>&1 &
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
  deadline=$((SECONDS + 20))
  until [ -f "$close_gate/ready" ]; do
    [ "$SECONDS" -lt "$deadline" ] && kill -0 "$child" 2>/dev/null \
      || fail "older checkpoint never reached a quiet close ($(cat "$home/successor.out"))"
    sleep 0.1
  done
  status=0
  TMPDIR="$home/missing" "$CHECKPOINT" --seconds 2 >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "overlapping attempt failed during setup"
  : > "$close_gate/release" || fail "could not release the older checkpoint"
  status=0
  wait "$child" || status=$?
  child=''
  expect_code 124 "$status" "quiet caller-owned successor exit"
  assert_present "$close_gate/forwarded" "older checkpoint did not receive its quiet close after release"
  assert_absent "$home/state/.watch.lock/pid" "quiet successor left a polling process behind"
  guard_output=$("$ROOT/bin/fm-guard.sh" 2>&1)
  assert_contains "$guard_output" 'WATCHER DOWN' "older checkpoint return superseded a newer failed attempt"
  pass "foreground wake is durable, caller owns its successor, and pending recovery does not falsify live health"
)

# A normal return (quiet deadline here) followed by the protocol's drain is the
# expected interval between foreground checkpoints, not a supervision lapse: it
# must not print the watcher-down alarm or leave a repeating "still down"
# reminder across cycles. A missing or failed cycle must still alarm.
test_normal_checkpoint_return_is_not_a_watcher_down_alarm() (
  local home out cycle seq gen guard_output record status
  home=$(make_home checkpoint-return-gap)
  export FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home"
  export FM_POLL=15 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
  export FM_SUPERVISION_MODEL=persistent
  record="$home/state/.last-checkpoint-return"
  "$ROOT/bin/fm-lock.sh" >/dev/null || fail "fixture could not acquire the fleet lock"
  printf 'kind=ship\n' > "$home/state/demo.meta"
  for cycle in 1 2 3; do
    status=0
    "$CHECKPOINT" --seconds 5 >"$home/checkpoint.log" 2>&1 || status=$?
    expect_code 124 "$status" "cycle $cycle quiet deadline ($(cat "$home/checkpoint.log"))"
    out=$("$ROOT/bin/fm-wake-drain.sh" 2>&1)
    assert_not_contains "$out" 'WATCHER DOWN' "cycle $cycle: a normal checkpoint return printed the watcher-down alarm"
    assert_not_contains "$out" 'watcher still down' "cycle $cycle: a fresh beat after a normal return printed 'watcher still down'"
    assert_contains "$out" 'between foreground checkpoints' "cycle $cycle: the post-return gap was not named"
    seq=$(printf '%s\n' "$out" | sed -n 's/.*--ack-through \([0-9]*\) --recovery-generation .*/\1/p')
    gen=$(printf '%s\n' "$out" | sed -n 's/.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p')
    [ -z "$seq" ] || "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
  done
  assert_absent "$home/state/.guard-watcher-stale-banner" "a normal return claimed a watcher-down episode"

  status=0
  TMPDIR="$home/missing" "$CHECKPOINT" --seconds 2 >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "successor could not create its output directory"
  guard_output=$("$ROOT/bin/fm-guard.sh" 2>&1)
  assert_contains "$guard_output" 'WATCHER DOWN' "a missing watcher with no clean return was not alarmed"
  assert_contains "$guard_output" 'no live watcher process' "the alarm lost its missing-watcher cause"
  guard_output=$("$ROOT/bin/fm-guard.sh" 2>&1)
  assert_contains "$guard_output" 'watcher still down' "the announced episode lost its reminder"

  status=0
  "$CHECKPOINT" --seconds 5 >/dev/null 2>&1 || status=$?
  expect_code 124 "$status" "quiet successor after a failed start"
  guard_output=$("$ROOT/bin/fm-guard.sh" 2>&1)
  assert_not_contains "$guard_output" 'watcher still down' "a clean return did not end the announced episode"
  assert_contains "$guard_output" 'between foreground checkpoints' "quiet successor did not explain the gap"

  mkdir "$home/state/.watch.lock"
  printf 'invalid pid\n' > "$home/state/.watch.lock/pid"
  guard_output=$("$ROOT/bin/fm-guard.sh" 2>&1)
  assert_contains "$guard_output" 'WATCHER DOWN' "a retained invalid lock inherited the expected gap"
  rm -r "$home/state/.watch.lock"
  guard_output=$("$ROOT/bin/fm-guard.sh" 2>&1)
  assert_contains "$guard_output" 'between foreground checkpoints' "released lock did not restore the expected gap"

  guard_output=$(FM_SUPERVISION_MODEL=autoarm "$ROOT/bin/fm-guard.sh" 2>&1)
  assert_not_contains "$guard_output" 'WATCHER DOWN' "auto-arm model alarmed a mid-turn gap"
  assert_not_contains "$guard_output" 'between foreground checkpoints' "auto-arm model printed the foreground-checkpoint note"

  guard_output=$(FM_GUARD_READ_ONLY=1 "$ROOT/bin/fm-guard.sh" 2>&1)
  assert_contains "$guard_output" 'WATCHER DOWN' "read-only guard inherited the attended exception"
  assert_not_contains "$guard_output" 'between foreground checkpoints' "read-only guard printed the owning session's checkpoint notice"

  fm_touch_epoch "$(( $(date +%s) - 400 ))" "$record"
  guard_output=$("$ROOT/bin/fm-guard.sh" 2>&1)
  assert_contains "$guard_output" 'WATCHER DOWN' "an overdue next checkpoint was not alarmed"
  assert_not_contains "$guard_output" 'between foreground checkpoints' "an overdue return still read as the expected gap"

  status=0
  "$CHECKPOINT" --seconds 5 4<"$home/checkpoint.log" >&4 2>/dev/null || status=$?
  expect_code 1 "$status" "quiet line could not be forwarded"
  [ ! -s "$record" ] || fail "an undelivered quiet line recorded a clean return"

  pass "a normal foreground checkpoint return is not reported as supervision off, while a missing or overdue cycle still alarms"
)

test_timed_out_startup_is_a_failed_checkpoint() (
  local home status=0 output
  home=$(make_home blocked-startup)
  export FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home"
  export FM_POLL=15 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999
  "$ROOT/bin/fm-lock.sh" >/dev/null || fail "fixture could not acquire the fleet lock"
  printf 'kind=ship\n' > "$home/state/demo.meta"
  "$CHECKPOINT" --seconds 5 >/dev/null 2>&1 || status=$?
  expect_code 124 "$status" "initial quiet checkpoint"
  output=$("$ROOT/bin/fm-guard.sh" 2>&1)
  assert_contains "$output" 'between foreground checkpoints' "fixture never established an initial clean return"
  mkdir "$home/state/.wake-queue.lock" || fail "fixture could not hold the wake-queue lock"
  printf '%s\n' "$$" > "$home/state/.wake-queue.lock/pid"
  status=0
  output=$("$CHECKPOINT" --seconds 2 2>&1) || status=$?
  expect_code 124 "$status" "startup timeout keeps the checkpoint deadline exit ($output)"
  assert_present "$home/state/.watch.lock/pid" "watcher did not reach the blocked recovery startup"
  [ ! -s "$home/state/.last-checkpoint-return" ] || fail "startup timeout recorded a clean return"
  output=$("$ROOT/bin/fm-guard.sh" 2>&1)
  assert_contains "$output" 'WATCHER DOWN' "startup timeout suppressed the guard alarm"
  pass "a deadline during recovery startup leaves the guard alarm active"
)

test_timeout_after_first_beacon() (
  local blocked_lock=$1 home status=0 output mv_bin
  home=$(make_home "blocked-$blocked_lock")
  export FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home"
  export FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999
  "$ROOT/bin/fm-lock.sh" >/dev/null || fail "fixture could not acquire the fleet lock"
  printf 'kind=ship\n' > "$home/state/demo.meta"
  mv_bin=$(command -v mv) || fail "could not locate mv for the beacon fixture"
  mkdir "$home/bin"
  cat > "$home/bin/mv" <<'SH'
#!/usr/bin/env bash
"$FM_TEST_REAL_MV" "$@" || exit $?
if [ "${!#}" = "$FM_STATE_OVERRIDE/.last-watcher-beat" ]; then
  mkdir "$FM_TEST_BLOCKED_LOCK" || exit 1
  printf '%s\n' "$FM_TEST_LOCK_OWNER" > "$FM_TEST_BLOCKED_LOCK/pid"
fi
SH
  chmod +x "$home/bin/mv"
  output=$(PATH="$home/bin:$PATH" FM_TEST_REAL_MV="$mv_bin" FM_TEST_LOCK_OWNER="$$" \
    FM_TEST_BLOCKED_LOCK="$home/state/$blocked_lock" \
    "$CHECKPOINT" --seconds 3 2>&1) || status=$?
  expect_code 124 "$status" "blocked checkpoint keeps the deadline exit ($output)"
  assert_contains "$output" 'checkpoint: no actionable wake within 3s' "blocked checkpoint lost its deadline line"
  assert_present "$home/state/.last-watcher-beat" "watcher never published its first beacon"
  assert_present "$home/state/$blocked_lock/pid" "publisher never blocked the first scan"
  if [ "$blocked_lock" = .watcher-down.lock ]; then
    assert_present "$home/state/.watch.lock/pid" "force-killed watcher did not retain its lock"
  else
    assert_absent "$home/state/.watch.lock" "watcher did not release its lock"
  fi
  [ ! -s "$home/state/.last-checkpoint-return" ] || fail "blocked checkpoint recorded a clean return"
  output=$("$ROOT/bin/fm-guard.sh" 2>&1)
  assert_contains "$output" 'WATCHER DOWN' "a beacon without a completed scan hid a failed cycle"
  assert_not_contains "$output" 'between foreground checkpoints' "a beacon alone certified the first scan"
  pass "a checkpoint blocked by $blocked_lock still reports the deadline and alarms"
)

test_actionable_close_before_first_beacon() (
  local home status=0 output rm_bin mktemp_bin
  home=$(make_home early-wake)
  export FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home"
  "$ROOT/bin/fm-lock.sh" >/dev/null || fail "fixture could not acquire the fleet lock"
  printf 'kind=ship\n' > "$home/state/demo.meta"
  printf 'invalid retirement receipt\n' > "$home/state/demo.pr-poll-retirement"
  output=$("$CHECKPOINT" --seconds 8 2>&1) || status=$?
  expect_code 0 "$status" "startup wake ($output)"
  assert_contains "$output" 'rejected unauthenticated PR poll retirement receipts' "watcher did not deliver the startup wake"
  assert_absent "$home/state/.last-watcher-beat" "startup wake unexpectedly published a beacon"
  output=$("$ROOT/bin/fm-wake-drain.sh" 2>&1)
  assert_contains "$output" 'between foreground checkpoints' "verified startup wake did not explain the missing watcher"
  assert_not_contains "$output" 'WATCHER DOWN' "verified startup wake alarmed without a beacon"
  assert_not_contains "$output" 'start the next checkpoint' "guard notice instructs the reader to re-arm"

  status=0
  "$CHECKPOINT" --seconds 8 4<"$home/state/demo.meta" >&4 2>/dev/null || status=$?
  expect_code 1 "$status" "actionable wake could not be forwarded"
  [ ! -s "$home/state/.last-checkpoint-return" ] || fail "an undelivered wake recorded a clean return"

  mktemp_bin=$(command -v mktemp)
  mkdir "$home/bin"
  cat > "$home/bin/mktemp" <<'SH'
#!/usr/bin/env bash
case "$1" in */.last-checkpoint-return.*) exit 1 ;; esac
exec "$FM_TEST_REAL_MKTEMP" "$@"
SH
  chmod +x "$home/bin/mktemp"
  status=0
  output=$(PATH="$home/bin:$PATH" FM_TEST_REAL_MKTEMP="$mktemp_bin" "$CHECKPOINT" --seconds 8 2>&1) || status=$?
  expect_code 0 "$status" "optional record setup failure keeps the wake exit ($output)"
  assert_contains "$output" 'rejected unauthenticated PR poll retirement receipts' "record setup failure swallowed the wake"
  assert_absent "$home/state/.last-checkpoint-return" "failed record setup left proof of a clean return"
  rm "$home/bin/mktemp"

  rm_bin=$(command -v rm)
  cat > "$home/bin/rm" <<'SH'
#!/usr/bin/env bash
[ "${2:-}" != "$FM_STATE_OVERRIDE/.watch.lock" ] || exit 1
exec "$FM_TEST_REAL_RM" "$@"
SH
  chmod +x "$home/bin/rm"
  status=0
  output=$(PATH="$home/bin:$PATH" FM_TEST_REAL_RM="$rm_bin" "$CHECKPOINT" --seconds 8 2>&1) || status=$?
  expect_code 0 "$status" "startup wake with failed lock cleanup keeps the wake exit ($output)"
  [ ! -s "$home/state/.last-checkpoint-return" ] || fail "wake with failed lock cleanup recorded a clean return"
  assert_contains "$output" 'rejected unauthenticated PR poll retirement receipts' "cleanup failure test never delivered the wake"
  assert_present "$home/state/.watch.lock/pid" "cleanup failure did not retain a lock"
  output=$("$ROOT/bin/fm-guard.sh" 2>&1)
  assert_contains "$output" 'WATCHER DOWN' "wake with a retained lock suppressed the guard alarm"
  pass "an early wake explains a beacon-less gap only after successful lock release"
)

test_replaced_receipt_cannot_borrow_successor_mtime() (
  [ "$(uname -s)" = Linux ] || return 0
  local home output record stat_bin
  home=$(make_home replaced-receipt)
  export FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home"
  "$ROOT/bin/fm-lock.sh" >/dev/null || fail "fixture could not acquire the fleet lock"
  printf 'kind=ship\n' > "$home/state/demo.meta"
  printf 'invalid retirement receipt\n' > "$home/state/demo.pr-poll-retirement"
  "$CHECKPOINT" --seconds 8 >/dev/null 2>&1 || fail "fixture could not deliver an early wake"
  record="$home/state/.last-checkpoint-return"
  output=$("$ROOT/bin/fm-guard.sh" 2>&1)
  assert_contains "$output" 'between foreground checkpoints' "fixture never established a valid wake receipt"
  fm_touch_epoch "$(( $(date +%s) - 400 ))" "$record"
  : > "$record.successor"
  stat_bin=$(command -v stat) || fail "could not locate stat for the receipt fixture"
  mkdir "$home/bin"
  cat > "$home/bin/stat" <<'SH'
#!/usr/bin/env bash
if [ "${!#}" = "$FM_TEST_RECORD" ] && [ -f "$FM_TEST_RECORD.successor" ]; then
  mv -f -- "$FM_TEST_RECORD.successor" "$FM_TEST_RECORD" || exit 1
fi
exec "$FM_TEST_REAL_STAT" "$@"
SH
  chmod +x "$home/bin/stat"
  output=$(PATH="$home/bin:$PATH" FM_TEST_REAL_STAT="$stat_bin" FM_TEST_RECORD="$record" \
    "$ROOT/bin/fm-guard.sh" 2>&1)
  assert_absent "$record.successor" "the receipt replacement did not interleave with the guard"
  [ -f "$record" ] && [ ! -s "$record" ] || fail "fixture did not install an empty successor receipt"
  assert_contains "$output" 'WATCHER DOWN' "the expired wake borrowed the failed successor's fresh mtime"
  assert_not_contains "$output" 'between foreground checkpoints' "a replaced wake receipt explained the gap"
  pass "a guard reading an expired receipt alarms after it is replaced by an empty successor"
)

test_replacement_and_away_handoff_cannot_reuse_return() (
  local home status=0 output contract result owner fingerprint
  home=$(make_home checkpoint-session)
  export FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home"
  export FM_POLL=15 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999
  printf 'kind=ship\n' > "$home/state/demo.meta"
  ln -s /bin/bash "$home/codex"
  # shellcheck disable=SC2016
  output=$("$home/codex" -c '
    "$1" >/dev/null || exit 1
    "$2" --seconds 5
    status=$?
    "$3"
    exit "$status"
  ' _ "$ROOT/bin/fm-lock.sh" "$CHECKPOINT" "$ROOT/bin/fm-guard.sh" 2>&1) || status=$?
  expect_code 124 "$status" "predecessor checkpoint ($output)"
  assert_contains "$output" 'between foreground checkpoints' "predecessor did not complete a valid quiet checkpoint"
  assert_not_contains "$output" 'WATCHER DOWN' "predecessor alarmed after its own checkpoint"
  read -r result owner fingerprint < "$home/state/.last-checkpoint-return" || fail "predecessor receipt missing"
  [ "$result" = quiet ] && [ "$owner" = "$(cat "$home/state/.lock")" ] \
    && [[ "$fingerprint" =~ ^[[:xdigit:]]{64}$ ]] || fail "quiet receipt must contain only the session PID and SHA-256 fingerprint"
  "$ROOT/bin/fm-lock.sh" >/dev/null || fail "replacement could not acquire the fleet lock"
  output=$("$ROOT/bin/fm-guard.sh" 2>&1)
  assert_contains "$output" 'WATCHER DOWN' "replacement Codex session inherited the predecessor's checkpoint"
  status=0
  output=$("$CHECKPOINT" --seconds 4 2>&1) || status=$?
  expect_code 0 "$status" "replacement recovery checkpoint ($output)"
  assert_contains "$output" 'check: rearm-resurface' "replacement did not deliver the unacknowledged recovery episode"
  output=$("$ROOT/bin/fm-guard.sh" 2>&1)
  assert_contains "$output" 'between foreground checkpoints' "replacement's own checkpoint did not explain the gap"
  output=$(GROK_AGENT=1 "$ROOT/bin/fm-guard.sh" 2>&1)
  assert_contains "$output" 'WATCHER DOWN' "Grok supervision inherited a Codex checkpoint"
  output=$("$ROOT/bin/fm-guard.sh" 2>&1)
  assert_contains "$output" 'between foreground checkpoints' "Codex lost its valid return after another protocol checked the guard"

  contract="$ROOT/bin/fm-afk-contract.sh"
  "$contract" propose >/dev/null || fail "could not propose away posture"
  "$contract" confirm >/dev/null || fail "could not confirm away posture"
  status=0
  FM_SUPERVISOR_TARGET=fixture FM_SUPERVISOR_BACKEND=unsupported \
    "$ROOT/bin/fm-afk-launch.sh" start >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "failed daemon launch"
  assert_absent "$home/state/.afk" "failed daemon launch left an active daemon flag"
  output=$("$ROOT/bin/fm-guard.sh" 2>&1)
  assert_contains "$output" 'WATCHER DOWN' "failed away-daemon launch inherited a Codex checkpoint"
  "$contract" archive >/dev/null || fail "could not close away posture"
  output=$("$ROOT/bin/fm-guard.sh" 2>&1)
  assert_contains "$output" 'watcher still down' "return from away reused the pre-away checkpoint"
  pass "replacement sessions and away supervision require their own monitoring cycle"
)

test_receipt_removal_is_optional() (
  local home output archived record contract
  home=$(make_home obstructed-receipt)
  export FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home"
  "$ROOT/bin/fm-lock.sh" >/dev/null || fail "fixture could not acquire the fleet lock"
  printf 'kind=ship\n' > "$home/state/demo.meta"
  printf 'invalid retirement receipt\n' > "$home/state/demo.pr-poll-retirement"
  record="$home/state/.last-checkpoint-return"
  mkdir "$record" || fail "fixture could not obstruct receipt removal"

  output=$("$CHECKPOINT" --seconds 8 2>&1) || fail "receipt removal blocked the checkpoint ($output)"
  assert_contains "$output" 'rejected unauthenticated PR poll retirement receipts' "receipt removal swallowed the wake"
  output=$("$ROOT/bin/fm-guard.sh" 2>&1)
  assert_contains "$output" 'WATCHER DOWN' "an obstructed receipt suppressed the guard alarm"

  contract="$ROOT/bin/fm-afk-contract.sh"
  "$contract" propose >/dev/null || fail "could not propose away posture"
  "$contract" confirm >/dev/null || fail "could not confirm away posture"
  archived=$("$contract" archive) || fail "receipt removal blocked away-posture archival"
  assert_present "$archived" "away posture was not archived"
  assert_absent "$home/state/.afk-contract" "away posture remained active"
  rmdir "$record" || fail "checkpoint wrote into the obstructing directory"
  pass "an obstructed receipt path leaves wake delivery and away return available"
)

test_quiet_checkpoint_exits_124_cleanly
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
test_foreground_wake_acknowledgement_and_owned_successor || exit 1
test_normal_checkpoint_return_is_not_a_watcher_down_alarm || exit 1
test_timed_out_startup_is_a_failed_checkpoint || exit 1
test_timeout_after_first_beacon .wake-queue.lock || exit 1
test_timeout_after_first_beacon .watcher-down.lock || exit 1
test_actionable_close_before_first_beacon || exit 1
test_replaced_receipt_cannot_borrow_successor_mtime || exit 1
test_replacement_and_away_handoff_cannot_reuse_return || exit 1
test_receipt_removal_is_optional || exit 1
