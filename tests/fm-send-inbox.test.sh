#!/usr/bin/env bash
# tests/fm-send-inbox.test.sh - fm-send's inbox data plane.
#
# An ordinary text steer to a task recorded in this home no longer types its
# payload: fm-send appends a durable sequenced record to state/<id>.inbox/ and
# rings one constant self-describing doorbell line, best-effort. These tests
# drive the real fm-send executable over a stubbed tmux and pin:
#   1. The payload is durably recorded and never typed; only the doorbell
#      crosses the terminal, and the send exits 0 at enqueue.
#   2. Multi-line steers are legal and round-trip byte-exact.
#   3. A re-send enqueues a NEW sequence and still never retypes a payload,
#      so the terminal can never truncate, garble, or duplicate a steer.
#   4. Visibly pending composer text refuses the ring with a notice, and the
#      steer is still durably sent (exit 0) for the watcher to retry and then
#      escalate.
#   5. A failed doorbell is still a sent steer (exit 0, record durable): the
#      watcher's re-ring ladder owns delivery from the record on.
#   6. Carve-outs keep the typed plane: a leading "/" (any harness), a leading
#      "$" to codex, an explicit backend target, and the --key path.
#   7. A marked secondmate steer carries its marker + corr token in the record
#      body, and the pending-reply expectation is marked delivered at enqueue.
#   8. Pending-reply bookkeeping failure after enqueue never reports a
#      retryable send failure that could duplicate the durable instruction.
#   9. An unwritable inbox is a real local failure: nonzero exit, nothing
#      typed, and a just-created pending-reply expectation is discarded.
# Every case below that passes a literal `$...` message quotes it on purpose
# (the point is sending an unexpanded `$` line), so SC2016 is disabled.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-marker-lib.sh"

SEND="$ROOT/bin/fm-send.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-inbox)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# Stub tmux: logs literal typed text to FM_SEND_LOG and lets the submit and
# composer paths reach clean verdicts. FM_FAKE_TMUX_COMPOSER=pending renders a
# composer visibly holding text; FM_FAKE_TMUX_SEND_FAIL=1 fails send-keys.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    [ "${FM_FAKE_TMUX_SEND_FAIL:-0}" = 1 ] && exit 1
    if [ -n "${FM_FAKE_CLAUDE_LOCK:-}" ]; then
      owner=$(cat "$FM_FAKE_CLAUDE_LOCK/pid" 2>/dev/null) && kill -0 "$owner" 2>/dev/null \
        || { printf 'unlocked write\n' >> "$FM_SEND_LOG.keys"; exit 1; }
    fi
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s\n' "${1:-}" >> "$FM_SEND_LOG"
      printf '%s' "${1:-}" > "$FM_SEND_LOG.pending"
    else
      printf '%s\n' "${1:-}" >> "$FM_SEND_LOG.keys"
      [ "${1:-}" != Enter ] || rm -f -- "$FM_SEND_LOG.pending"
    fi
    exit 0 ;;
  display-message)
    case "${*: -1}" in
      '#{cursor_y}')
        case "${FM_FAKE_CLAUDE_CAPTURE:-}" in
          before) printf '8\n'; exit 0 ;;
          after-typing) if [ -s "$FM_SEND_LOG.pending" ]; then printf '8\n'; exit 0; fi ;;
        esac
        printf '1\n'; exit 0 ;;
      '#{pane_current_command}') printf 'claude\n'; exit 0 ;;
      '#{pane_id}') printf '%%%s\n' "${4#@}"; exit 0 ;;
    esac
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    case "${FM_FAKE_CLAUDE_CAPTURE:-}" in
      unreadable) exit 1 ;;
      multiline-draft)
        printf '────────────────────────\n❯ \n  ||\n────────────────────────\n'
        exit 0 ;;
      wrong-text)
        if [ -s "$FM_SEND_LOG.pending" ]; then
          printf '────────────────────────\n❯ unrelated text\n────────────────────────\n'
          exit 0
        fi ;;
      shell) printf 'Claude has exited.\n❯ %s\n' "$(cat "$FM_SEND_LOG.pending" 2>/dev/null)"; exit 0 ;;
      shell-after-typing)
        if [ -s "$FM_SEND_LOG.pending" ]; then
          printf 'Claude has exited.\n❯ %s\n' "$(cat "$FM_SEND_LOG.pending")"
          exit 0
        fi ;;
      before) cat "$FM_FAKE_CLAUDE_SCREEN"; exit ;;
      after-typing)
        if [ -s "$FM_SEND_LOG.pending" ]; then cat "$FM_FAKE_CLAUDE_SCREEN"; exit; fi ;;
      unreadable-after-typing)
        if [ -s "$FM_SEND_LOG.pending" ]; then exit 1; fi ;;
      after-enter)
        if [ -s "$FM_SEND_LOG.keys" ]; then cat "$FM_FAKE_CLAUDE_SCREEN"; exit; fi ;;
    esac
    if [ -s "$FM_SEND_LOG.pending" ]; then
      printf '────────────────────────\n❯ %s\n────────────────────────\n' "$(cat "$FM_SEND_LOG.pending")"
    elif [ "${FM_FAKE_TMUX_COMPOSER:-}" = pending ]; then
      printf '╭──────────────╮\n│ leftover txt │\n╰──────────────╯\n'
    else
      printf '────────────────────────\n❯ \n────────────────────────\n'
    fi
    exit 0 ;;
  list-windows)
    case "$*" in
      *window_id*) printf '@1 sess:fm-t1\n@2 sess:win\n' | fm_fake_tmux_window_ids "$@" ;;
      *) printf 'fm-t1\n' ;;
    esac
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  0.3|0.4|1.2) exit 0 ;;
  *) exec /bin/sleep "$@" ;;
esac
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

setup_case() {  # <name> [harness] -> echoes case dir with home/state + t1 meta
  local name=$1 harness=${2:-claude} dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state"
  make_stubs "$dir" >/dev/null
  fm_write_meta "$dir/home/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=$harness"
  printf '%s\n' "$dir"
}

run_send() {  # <case-dir> <err-file> [env...] -- <fm-send args...>
  local dir=$1 err=$2
  shift 2
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  shift
  : > "$dir/send.log"
  rm -f -- "$dir/send.log.pending" "$dir/send.log.keys"
  env PATH="$dir/fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$dir/home" FM_HOME="$dir/home" FM_SEND_LOG="$dir/send.log" \
    FM_SEND_SETTLE=0 ${envs[@]+"${envs[@]}"} \
    FM_STATE_OVERRIDE="$dir/home/state" "$SEND" "$@" >/dev/null 2>"$err"
}

record_body() {  # <record>
  bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$2"
}

test_text_steer_rides_inbox() {
  local dir err rc rec body typed
  dir=$(setup_case rides); err="$dir/send.err"
  run_send "$dir" "$err" -- t1 "please rebase onto main"; rc=$?
  expect_code 0 "$rc" "an inbox-plane steer should exit 0 at enqueue"
  rec="$dir/home/state/t1.inbox/001.msg"
  [ -f "$rec" ] || fail "the steer was not durably recorded at $rec"
  body=$(record_body _ "$rec")
  [ "$body" = "please rebase onto main" ] || fail "the recorded body differs: $body"
  typed=$(cat "$dir/send.log")
  assert_contains "$typed" "Firstmate instruction waiting: list '$dir/home/state/t1.inbox'/*.msg" \
    "the doorbell should direct the worker to drain the inbox"
  case "$typed" in
    *"please rebase onto main"*) fail "the payload must never be typed:"$'\n'"$typed" ;;
  esac
  pass "fm-send inbox: the payload is recorded durably and only the doorbell is typed"
}

test_multiline_steer_is_legal() {
  local dir err rc body
  dir=$(setup_case multiline); err="$dir/send.err"
  run_send "$dir" "$err" -- t1 $'first line\nsecond line\nthird: with punctuation'; rc=$?
  expect_code 0 "$rc" "a multi-line steer should succeed"
  body=$(record_body _ "$dir/home/state/t1.inbox/001.msg")
  [ "$body" = $'first line\nsecond line\nthird: with punctuation' ] \
    || fail "the multi-line body did not round-trip:"$'\n'"$body"
  case "$(cat "$dir/send.log")" in
    *"second line"*) fail "a payload line leaked onto the typed channel" ;;
  esac
  pass "fm-send inbox: newlines are legal and the terminal can no longer truncate a steer"
}

test_resend_enqueues_new_sequence() {
  local dir err doorbells typed
  dir=$(setup_case resend); err="$dir/send.err"
  run_send "$dir" "$err" -- t1 "check the CI result" || fail "first send failed"
  run_send "$dir" "$err" -- t1 "check the CI result" || fail "second send failed"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] && [ -f "$dir/home/state/t1.inbox/002.msg" ] \
    || fail "a re-send should enqueue a new sequence:"$'\n'"$(ls "$dir/home/state/t1.inbox")"
  doorbells=$(grep -cF 'Firstmate instruction waiting' "$dir/send.log" || true)
  [ "$doorbells" = 1 ] || fail "each send rings once (the log is truncated per send), got $doorbells"
  typed=$(cat "$dir/send.log")
  assert_contains "$typed" "numeric order" \
    "a newer record's doorbell should preserve inbox sequence ordering"
  case "$typed" in
    *"check the CI result"*) fail "a re-send typed the payload" ;;
  esac
  pass "fm-send inbox: a re-send is a new durable record, never a retyped payload"
}

test_pending_composer_skips_ring_advisorily() {
  local dir err rc
  dir=$(setup_case pendingskip grok); err="$dir/send.err"
  run_send "$dir" "$err" FM_FAKE_TMUX_COMPOSER=pending -- t1 "steer past a stuck composer"; rc=$?
  expect_code 0 "$rc" "a skipped ring is still a sent steer"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the steer was not recorded"
  [ ! -s "$dir/send.log" ] || fail "a visibly pending composer should skip the ring:"$'\n'"$(cat "$dir/send.log")"
  assert_contains "$(cat "$err")" "blocked the doorbell" "fm-send should explain the pending-draft refusal"
  assert_contains "$(cat "$err")" "watcher will retry, then escalate" \
    "the refusal notice should point at the retry and escalation"
  pass "fm-send inbox: a visibly pending composer skips the ring, and the steer stays durably sent"
}

test_failed_ring_is_still_sent() {
  local dir err rc
  dir=$(setup_case ringfail); err="$dir/send.err"
  run_send "$dir" "$err" FM_FAKE_TMUX_SEND_FAIL=1 -- t1 "steer into a dead pane"; rc=$?
  expect_code 0 "$rc" "a failed doorbell must not fail the send"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the steer was not recorded"
  assert_contains "$(cat "$err")" "watcher will re-ring" \
    "the failed-ring notice should point at the re-ring"
  pass "fm-send inbox: a failed doorbell is still a durably sent steer"
}

test_harness_invocations_stay_typed() {
  local dir err typed
  # A slash command must reach the harness's own parser, on any harness.
  dir=$(setup_case slash); err="$dir/send.err"
  run_send "$dir" "$err" -- t1 "/no-mistakes" || fail "a slash send should succeed"
  typed=$(cat "$dir/send.log")
  assert_contains "$typed" "/no-mistakes" "the slash command should be typed literally"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "a slash command must not be routed to the inbox"
  # A codex `$<skill>` invocation likewise stays typed.
  dir=$(setup_case codexskill codex); err="$dir/send.err"
  run_send "$dir" "$err" -- t1 '$no-mistakes' || fail "a codex \$skill send should succeed"
  assert_contains "$(cat "$dir/send.log")" '$no-mistakes' "the codex \$skill should be typed literally"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "a codex \$skill must not be routed to the inbox"
  # The same `$` message to a non-codex harness is plain text: inbox plane.
  dir=$(setup_case dollartext claude); err="$dir/send.err"
  run_send "$dir" "$err" -- t1 '$5/month is cheap' || fail "a claude \$-text send should succeed"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "a non-codex \$-message should ride the inbox"
  case "$(cat "$dir/send.log")" in
    *'$5/month'*) fail "a non-codex \$-message payload was typed" ;;
  esac
  pass "fm-send planes: slash and codex \$skill invocations stay typed; plain \$-text rides the inbox"
}

test_claude_automatic_input_refuses_unproven_composers() {
  local dir err log meta exact near mode screen rc out lock text
  dir=$(setup_case claude-guard claude-latest); err="$dir/send.err"; log="$dir/send.log"
  local -x FM_STATE_OVERRIDE="$dir/home/state"
  meta="$dir/home/state/t1.meta"
  exact="$ROOT/tests/fixtures/claude-exit/claude-2.1.330.screen"
  near="$dir/choice-two.screen"
  sed -e 's/❯ 1\. Exit/  1. Exit/' -e 's/    2\. Move/  ❯ 2. Move/' "$exact" > "$near"
  assert_contains "$(cat "$near")" '❯ 2. Move to background and exit' 'the near miss must render choice 2 as selected'

  run_send "$dir" "$err" FM_FAKE_CLAUDE_CAPTURE=multiline-draft -- t1 'queue with a draft' \
    || fail 'a multiline draft should preserve durable delivery'
  assert_contains "$(cat "$err")" 'blocked the doorbell' 'a blank cursor row hid a draft inside the Claude frame'
  [ ! -s "$log" ] && [ ! -s "$log.keys" ] || fail 'a multiline draft received terminal input'

  for mode in before unreadable shell; do
    for screen in "$exact" "$near"; do
      run_send "$dir" "$err" FM_FAKE_CLAUDE_CAPTURE="$mode" FM_FAKE_CLAUDE_SCREEN="$screen" -- t1 'queue this' \
        || fail 'an input refusal should preserve durable delivery'
      assert_contains "$(cat "$err")" 'blocked the doorbell' 'the send did not report a refusal before typing'
      [ ! -s "$log" ] && [ ! -s "$log.keys" ] || fail 'an unproven screen received a doorbell'
      rc=0
      run_send "$dir" "$err" FM_FAKE_CLAUDE_CAPTURE="$mode" FM_FAKE_CLAUDE_SCREEN="$screen" -- t1 /help || rc=$?
      expect_code 1 "$rc" 'native Claude commands require a proven-empty composer'
      assert_contains "$(cat "$err")" 'text not typed' 'the native command did not report a refusal before typing'
      [ ! -s "$log" ] && [ ! -s "$log.keys" ] || fail 'an unproven screen received a native command'
    done
  done

  for mode in after-typing unreadable-after-typing wrong-text shell-after-typing; do
    run_send "$dir" "$err" FM_FAKE_CLAUDE_CAPTURE="$mode" FM_FAKE_CLAUDE_SCREEN="$near" -- t1 'queue this too' \
      || fail 'withholding Enter should preserve durable delivery'
    assert_contains "$(cat "$log")" 'Firstmate instruction waiting' 'the initial composer must permit the literal write'
    assert_contains "$(cat "$err")" 'Enter was withheld' 'the doorbell did not report withholding Enter'
    [ ! -s "$log.keys" ] || fail 'the doorbell pressed Enter without proof it held the line'
    rc=0
    run_send "$dir" "$err" FM_FAKE_CLAUDE_CAPTURE="$mode" FM_FAKE_CLAUDE_SCREEN="$near" -- t1 /help || rc=$?
    expect_code 1 "$rc" 'a native command must withhold Enter without a matching line'
    [ "$(cat "$log")" = /help ] && [ ! -s "$log.keys" ] || fail 'native command did not stop after its literal write'
  done
  rc=0
  run_send "$dir" "$err" FM_SEND_RETRIES=3 FM_FAKE_CLAUDE_CAPTURE=after-enter FM_FAKE_CLAUDE_SCREEN="$exact" -- t1 /help || rc=$?
  expect_code 3 "$rc" 'a dialog after a delivered Enter must stop native submit retries and leave submission unconfirmed'
  [ "$(cat "$log.keys")" = Enter ] || fail 'native send retried Enter into the dialog'

  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    lock="$dir/home/state/.control-t1.lock"
    fm_lock_try_acquire "$lock" || fail 'could not hold the actual lifecycle lock'
    trap 'fm_lock_release "$lock"' EXIT
    run_send "$dir" "$err" -- t1 'queue while lifecycle control is running' || fail 'a lock refusal lost the durable record'
    assert_contains "$(cat "$err")" 'lifecycle lock' 'the busy lifecycle lock did not produce a refusal'
    [ ! -s "$log" ] && [ ! -s "$log.keys" ] || fail 'a held lifecycle lock allowed doorbell writes'
    rc=0
    run_send "$dir" "$err" -- t1 /help || rc=$?
    expect_code 1 "$rc" 'a held lifecycle lock must block the native send'
    [ ! -s "$log" ] && [ ! -s "$log.keys" ] || fail 'a held lifecycle lock allowed native-command writes'
  ) || fail 'lifecycle-lock contention regression failed'
  for text in 'queue with lifecycle idle' /help; do
    run_send "$dir" "$err" FM_FAKE_CLAUDE_LOCK="$dir/home/state/.control-t1.lock" -- t1 "$text" \
      || fail 'proven composer did not accept the send'
    [ -s "$log" ] && [ "$(cat "$log.keys")" = Enter ] || fail 'a proven composer did not receive both writes under the lifecycle lock'
    assert_absent "$dir/home/state/.control-t1.lock" 'successful delivery left its lifecycle lock held'
  done

  mkdir "$dir/worktree" "$dir/project"
  printf 'worktree=%s\nproject=%s\n' "$dir/worktree" "$dir/project" >> "$meta"
  for mode in before unreadable shell; do
    : > "$log.keys"
    rc=0
    out=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_SEND_LOG="$log" \
      FM_FAKE_CLAUDE_CAPTURE="$mode" FM_FAKE_CLAUDE_SCREEN="$exact" "$ROOT/bin/fm-control.sh" t1 interrupt 2>&1) || rc=$?
    expect_code 1 "$rc" 'a standalone interrupt must refuse an unproven Claude composer'
    assert_contains "$out" 'interrupt-refused' 'the recovery interrupt did not identify its refusal'
    [ ! -s "$log.keys" ] || fail 'the recovery interrupt sent Escape to an unproven composer'
  done
  out=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_SEND_LOG="$log" \
    FM_FAKE_CLAUDE_LOCK="$dir/home/state/.control-t1.lock" "$ROOT/bin/fm-control.sh" t1 interrupt 2>&1) \
    || fail "a proven composer did not admit the recovery interrupt: $out"
  [ "$(cat "$log.keys")" = Escape ] || fail 'the recovery interrupt did not send Escape under the lifecycle lock'
  run_send "$dir" "$err" FM_FAKE_CLAUDE_CAPTURE=before FM_FAKE_CLAUDE_SCREEN="$exact" -- t1 --key Enter \
    || fail 'the explicit operator key was blocked'
  [ "$(cat "$log.keys")" = Enter ] || fail 'the explicit operator key did not reach the dialog'
  pass 'Claude automatic input requires proof at both writes and holds the lifecycle lock, while explicit keys reach the dialog'
}

test_claude_watcher_rering_respects_lifecycle_lock() (
  local dir state rec lock pid='' i
  dir=$(setup_case claude-watcher); state="$dir/home/state"
  # The watcher needs a real poll delay. Only terminal operations are fake.
  rm -f -- "$dir/fakebin/sleep"
  run_send "$dir" "$dir/send.err" FM_FAKE_CLAUDE_CAPTURE=unreadable -- t1 'retry this steer' \
    || fail 'could not queue a steer for the watcher'
  rec="$state/t1.inbox/001.msg"
  touch -t 202001010000 "$rec"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-wake-lib.sh"
  lock="$state/.control-t1.lock"
  fm_lock_try_acquire "$lock" || fail 'could not hold the actual lifecycle lock'
  trap '[ -z "$pid" ] || { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }; fm_lock_release "$lock"' EXIT
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CREW_STATE_BIN=/bin/false FM_POLL=1 FM_TASK_INBOX_GRACE_SECS=1 FM_TASK_INBOX_RING_MAX=30 \
    FM_SEND_LOG="$dir/send.log" FM_FAKE_CLAUDE_LOCK="$lock" \
    "$ROOT/bin/fm-watch.sh" >"$dir/watch.out" 2>&1 &
  pid=$!
  for ((i=0; i<100; i++)); do
    [ ! -s "$state/t1.inbox/.ring-state" ] || break
    kill -0 "$pid" 2>/dev/null || fail "watcher exited early: $(cat "$dir/watch.out")"
    sleep 0.1
  done
  assert_present "$state/t1.inbox/.ring-state" 'the watcher never recorded its refused attempt'
  [ ! -s "$dir/send.log" ] && [ ! -s "$dir/send.log.keys" ] || fail 'the watcher wrote into a lifecycle-locked pane'
  assert_present "$rec" 'the lifecycle lock made the watcher lose the queued record'
  fm_lock_release "$lock"
  for ((i=0; i<100; i++)); do
    [ ! -s "$dir/send.log.keys" ] || break
    kill -0 "$pid" 2>/dev/null || fail "watcher exited before the second attempt: $(cat "$dir/watch.out")"
    sleep 0.1
  done
  assert_contains "$(cat "$dir/send.log")" 'Firstmate instruction waiting' 'the watcher never typed after lifecycle control released the lock'
  [ "$(cat "$dir/send.log.keys")" = Enter ] || fail 'the watcher did not submit its proven doorbell'
  pass 'Claude watcher re-rings count a lifecycle refusal and retry the durable steer'
)

test_explicit_target_stays_typed() {
  local dir err
  dir=$(setup_case explicit); err="$dir/send.err"
  run_send "$dir" "$err" -- sess:win "hello there" || fail "an explicit-target send should succeed"
  assert_contains "$(cat "$dir/send.log")" "hello there" \
    "an explicit backend target should receive the literal text"
  [ -z "$(find "$dir/home/state" -maxdepth 1 -name '*.inbox' -print 2>/dev/null)" ] \
    || fail "an explicit target has no task record here and must not grow an inbox"
  pass "fm-send planes: an explicit backend target keeps the typed plane"
}

test_key_path_never_touches_inbox() {
  local dir err
  dir=$(setup_case keypath); err="$dir/send.err"
  run_send "$dir" "$err" -- t1 --key Enter || fail "a --key send should succeed"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "the --key path must never write an inbox record"
  pass "fm-send planes: the --key lifecycle path never touches the inbox"
}

test_secondmate_marker_and_enqueue_delivery() {
  local dir err body corr pr_rec delivered
  dir=$(setup_case secondmate); err="$dir/send.err"
  fm_write_secondmate_meta "$dir/home/state/domain.meta" "$dir/home" "sess:fm-domain"
  run_send "$dir" "$err" -- fm-domain "please summarize fleet health" \
    || fail "a secondmate steer should succeed"
  body=$(record_body _ "$dir/home/state/domain.inbox/001.msg")
  case "$body" in
    "$FM_FROMFIRST_MARK"corr=*) : ;;
    *) fail "the recorded body lost the from-firstmate marker/corr framing:"$'\n'"$body" ;;
  esac
  corr=$(printf '%s' "$body" | grep -oE 'corr=[a-f0-9]{16}' | head -1 | cut -d= -f2)
  [ -n "$corr" ] || fail "no corr token in the recorded body"
  pr_rec="$dir/home/state/pending-replies/$corr"
  [ -f "$pr_rec" ] || fail "no pending-reply expectation was recorded at $pr_rec"
  delivered=$(grep '^delivered_epoch=' "$pr_rec" | cut -d= -f2)
  [ -n "$delivered" ] || fail "enqueue IS delivery: delivered_epoch should be set at enqueue time:"$'\n'"$(cat "$pr_rec")"
  case "$(cat "$dir/send.log")" in
    *"summarize fleet health"*) fail "the marked payload was typed" ;;
  esac
  pass "fm-send inbox: a secondmate steer records marker+corr in the body and is delivered at enqueue"
}

test_post_enqueue_bookkeeping_failure_is_not_retryable() {
  local dir err rc rec body
  dir=$(setup_case bookkeeping-failure); err="$dir/send.err"
  fm_write_secondmate_meta "$dir/home/state/domain.meta" "$dir/home" "sess:fm-domain"
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
source_arg=${@: -2:1}
target_arg=${@: -1}
if [ "${FM_FAIL_DELIVERY_CONFIRM:-0}" = 1 ] \
  && grep -q '^confirmed=' "$source_arg" 2>/dev/null; then
  # Simulate losing both the delivery commit and its prepared recovery marker.
  rm -f "$target_arg"
  exit 1
fi
exec /bin/mv "$@"
SH
  chmod +x "$dir/fakebin/mv"

  run_send "$dir" "$err" FM_FAIL_DELIVERY_CONFIRM=1 -- domain "durable once"; rc=$?
  # The durable record IS the delivery: even with the commit AND its recovery
  # marker both lost, the steer was delivered, so fm-send must not signal a
  # status that invites a resend (a nonzero would make automated callers
  # enqueue the same instruction again under a new sequence). The degradation
  # surfaces as its own distinct do-not-resend condition instead.
  expect_code 0 "$rc" "a delivered steer must not report a resend-inviting failure over lost bookkeeping"
  rec="$dir/home/state/domain.inbox/001.msg"
  [ -f "$rec" ] || fail "bookkeeping failure test did not durably enqueue the steer"
  [ "$(find "$dir/home/state/domain.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" = 1 ] \
    || fail "the delivered steer was duplicated:"$'\n'"$(ls "$dir/home/state/domain.inbox")"
  body=$(record_body _ "$rec")
  case "$body" in
    "$FM_FROMFIRST_MARK"corr=*) : ;;
    *) fail "bookkeeping failure test lost the secondmate marker: $body" ;;
  esac
  assert_contains "$(cat "$err")" "reply-tracking-degraded" \
    "lost bookkeeping should surface as its own distinct degraded condition"
  assert_contains "$(cat "$err")" "do not resend" \
    "the degraded condition should give explicit do-not-resend guidance"
  assert_contains "$(cat "$err")" "durably recorded at" \
    "the degraded condition should name the already-delivered record"
  pass "fm-send inbox: lost reply bookkeeping never invites a resend, and the delivered steer is never duplicated"
}

test_meta_lock_contention_fails_bounded() {
  local dir err rc holder marker lock i
  dir=$(setup_case meta-lock); err="$dir/send.err"
  marker="$dir/meta-lock-held"
  lock="$dir/home/state/.meta-t1.lock"
  bash -c '
    . "$1"
    fm_lock_acquire_wait "$2"
    touch "$3"
    sleep 30
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$lock" "$marker" &
  holder=$!
  i=0
  while [ ! -e "$marker" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$marker" ] || { kill "$holder" 2>/dev/null; fail "the metadata lock holder did not start"; }
  run_send "$dir" "$err" FM_TASK_INBOX_LOCK_WAIT_SECS=0 -- t1 "must not hang"; rc=$?
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  [ "$rc" -ne 0 ] || fail "metadata lock contention should fail after the bounded wait"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "a lock refusal must not enqueue a record"
  assert_contains "$(cat "$err")" "metadata could not be locked" \
    "the bounded metadata lock refusal should be explicit"
  pass "fm-send inbox: metadata lock contention fails bounded without enqueue"
}

test_unwritable_inbox_fails_loudly() {
  local dir err rc
  dir=$(setup_case unwritable); err="$dir/send.err"
  fm_write_secondmate_meta "$dir/home/state/domain.meta" "$dir/home" "sess:fm-domain"
  : > "$dir/home/state/domain.inbox"   # a FILE where the inbox dir must go
  run_send "$dir" "$err" -- fm-domain "this cannot be recorded"; rc=$?
  [ "$rc" -ne 0 ] || fail "an unwritable inbox must fail the send"
  assert_contains "$(cat "$err")" "inbox record could not be written" \
    "the failure should name the unwritable inbox"
  [ ! -s "$dir/send.log" ] || fail "a failed enqueue still typed something:"$'\n'"$(cat "$dir/send.log")"
  [ -z "$(find "$dir/home/state/pending-replies" -type f -not -name '.*' 2>/dev/null)" ] \
    || fail "a failed enqueue should discard the just-created pending-reply expectation"
  pass "fm-send inbox: an unwritable record is a loud local failure that leaves no false expectation"
}

test_text_steer_rides_inbox
test_multiline_steer_is_legal
test_resend_enqueues_new_sequence
test_pending_composer_skips_ring_advisorily
test_failed_ring_is_still_sent
test_harness_invocations_stay_typed
test_claude_automatic_input_refuses_unproven_composers
test_claude_watcher_rering_respects_lifecycle_lock
test_explicit_target_stays_typed
test_key_path_never_touches_inbox
test_secondmate_marker_and_enqueue_delivery
test_post_enqueue_bookkeeping_failure_is_not_retryable
test_meta_lock_contention_fails_bounded
test_unwritable_inbox_fails_loudly
