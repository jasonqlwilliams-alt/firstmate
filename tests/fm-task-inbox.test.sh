#!/usr/bin/env bash
# tests/fm-task-inbox.test.sh - the per-task steering inbox
# (bin/fm-task-inbox-lib.sh) and the watcher's re-ring ladder.
#
# The inbox+doorbell design replaces typed steer payloads with durable
# sequenced records acknowledged by an atomic mv into handled/; the terminal
# carries only a constant doorbell line, and the watcher re-rings an
# unacknowledged message before escalating once as an ordinary stale wake.
# These tests pin the semantics with real processes:
#   1. A message is written durably and appears in the inbox, byte-exact
#      including newlines, with a doorbell naming the inbox glob, numeric order,
#      and handled/.
#   2. Sequencing dedups per worker lifetime: the handled mv retires a record,
#      re-acking it is a no-op, and an acknowledged sequence is never reissued.
#      The idempotent enqueue (the remote steer leg's primitive) additionally
#      dedups an exact-body re-run onto the existing record, handled or not.
#   3. Concurrent writers serialize on the sequence lock: no clobbered records.
#   4. The re-ring ladder: within grace is quiet, past grace rings, ring
#      spacing holds, a spent budget escalates exactly once, and an
#      acknowledgement resets the ladder for the next message.
#   5. A real fm-watch.sh subprocess re-rings the doorbell for an unhandled
#      aged message on an idle pane WITHOUT waking firstmate, waits on a busy
#      pane, stays silent on a healthy/empty inbox, surfaces unwritable ladder
#      bookkeeping only while its record remains unhandled, and emits exactly
#      one stale wake once the ring budget is spent.
#   6. Dead panes: the doorbell line is a shell no-op when executed by a bare
#      shell, the ring skips an agent the backend classifies dead, and the
#      watcher surfaces such a record exactly once instead of re-ringing.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-inbox)
# The doorbell line canonicalizes its paths, so keep the fixture root
# canonical too (a trailing-slash TMPDIR otherwise yields a double slash).
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# Run one library function against a state dir through a subshell that sources
# the production library, so the tests exercise the executable surface rather
# than re-implementing any format knowledge here.
inbox_lib() {  # <state> <function> [args...]
  local state=$1
  shift
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fn=$2
    shift 2
    "$fn" "$@"
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$@"
}

# A fake tmux for the watcher cases: capture-pane replays FM_FAKE_TMUX_CAPTURE,
# display-message yields a numeric cursor row (FM_FAKE_TMUX_CURSOR, default 1),
# every literal send-keys is logged to FM_SEND_LOG so a doorbell ring is
# observable, and every named key to FM_KEY_LOG. With FM_FAKE_TMUX_TYPED set,
# the pane behaves like a composer that renders what was typed: a literal send
# shows as a `›` row holding that text on the cursor row until Enter clears it. With
# FM_FAKE_TMUX_AGENT set, the inventory lists window fm-t1 and its
# #{pane_current_command} answers with that value, so `zsh` makes
# fm_backend_tmux_agent_state read the pane as a dead bare shell.
make_watch_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
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
      printf '%s\n' "${1:-}" >> "${FM_SEND_LOG:-/dev/null}"
      [ -z "${FM_FAKE_TMUX_TYPED:-}" ] || printf '%s' "${1:-}" > "$FM_FAKE_TMUX_TYPED"
      if [ -n "${FM_ACK_RECORD:-}" ] && [ -f "$FM_ACK_RECORD" ]; then
        mv "$FM_ACK_RECORD" "${FM_ACK_RECORD%/*}/handled/"
      fi
    else
      printf '%s\n' "${1:-}" >> "${FM_KEY_LOG:-/dev/null}"
      [ "${1:-}" != Enter ] || [ -z "${FM_FAKE_TMUX_TYPED:-}" ] || rm -f "$FM_FAKE_TMUX_TYPED"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '%s\n' "${FM_FAKE_TMUX_CURSOR:-1}"; exit 0 ;;
        *pane_current_command*) [ -z "${FM_FAKE_TMUX_AGENT:-}" ] || { printf '%s\n' "$FM_FAKE_TMUX_AGENT"; exit 0; } ;;
        *pane_tty*) [ -z "${FM_FAKE_TMUX_AGENT:-}" ] || { printf '\n'; exit 0; } ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    if [ -n "${FM_FAKE_TMUX_TYPED:-}" ] && [ -s "$FM_FAKE_TMUX_TYPED" ]; then
      printf 'fake agent\n› %s\n' "$(cat "$FM_FAKE_TMUX_TYPED")"
    elif [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] && [ -f "$FM_FAKE_TMUX_CAPTURE" ]; then
      cat "$FM_FAKE_TMUX_CAPTURE"
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
  list-windows) [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] || printf 'fm-t1\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  make_fake_crew_state "$fb" >/dev/null
  printf '%s\n' "$fb"
}

watch_bg() {  # <state> <fakebin> <out> [extra env assignments...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_TASK_INBOX_GRACE_SECS=1 FM_FAKE_TMUX_TYPED="${state%/*}/typed" \
    env "$@" "$WATCH" > "$out" 2>/dev/null &
}

wait_watcher_gone() {  # <pid> [limit-ticks]
  local pid=$1 limit=${2:-120} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

age_path() {  # <path>  (set mtime well past any grace under test)
  touch -t 202001010000 "$1"
}

test_write_is_durable_and_exact() {
  local state rec rec2 doorbell doorbell2 expected actual expected2 actual2 text
  state="$TMP_ROOT/write/state"; mkdir -p "$state"
  text=$'line one\nline two with  spaces\n/slash body\n\n'
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "$text") \
    || fail "inbox write failed"
  [ -f "$rec" ] || fail "inbox write printed a path that does not exist: $rec"
  case "$rec" in
    "$state/t1.inbox/001.msg") : ;;
    *) fail "first record should be 001.msg under the task inbox, got $rec" ;;
  esac
  expected="$state/expected.body"
  actual="$state/actual.body"
  printf '%s' "$text" > "$expected"
  inbox_lib "$state" fm_task_inbox_body "$rec" > "$actual" \
    || fail "record body could not be read"
  cmp -s "$expected" "$actual" \
    || fail "record body did not preserve trailing and blank-line bytes"
  rec2=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "no trailing newline") \
    || fail "second inbox write failed"
  expected2="$state/expected-no-newline.body"
  actual2="$state/actual-no-newline.body"
  printf '%s' "no trailing newline" > "$expected2"
  inbox_lib "$state" fm_task_inbox_body "$rec2" > "$actual2" \
    || fail "second record body could not be read"
  cmp -s "$expected2" "$actual2" \
    || fail "record body added a trailing newline"
  doorbell=$(inbox_lib "$state" fm_task_inbox_doorbell_line "$rec")
  doorbell2=$(inbox_lib "$state" fm_task_inbox_doorbell_line "$rec2")
  [ "$doorbell" = "$doorbell2" ] \
    || fail "every record in one inbox should ring the same drain-all doorbell"
  assert_contains "$doorbell" "'$state/t1.inbox'/*.msg" "doorbell should quote and name all unhandled records"
  assert_contains "$doorbell" "numeric order" "doorbell should require ordered processing"
  assert_contains "$doorbell" "'$state/t1.inbox'/handled/" "doorbell should quote and name the handled dir"
  assert_contains "$doorbell" "Firstmate instruction waiting" "doorbell should be self-describing"
  case "$doorbell" in
    *$'\n'*) fail "the doorbell must be a single line" ;;
  esac
  pass "inbox: a steer is written durably and round-trips byte-exact with a self-describing doorbell"
}

# The doorbell may land in a pane whose agent has exited, where it is a shell
# command line. Execute the real line in real shells and assert it is inert:
# exit 0, no output, and nothing in the inbox touched.
test_doorbell_is_a_shell_noop() {
  local state rec doorbell sh out before after marker
  state="$TMP_ROOT/noop/x; touch marker; #'s space/state"
  marker="$state/marker"
  mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  doorbell=$(inbox_lib "$state" fm_task_inbox_doorbell_line "$rec")
  case "$doorbell" in
    ': '*) ;;
    *) fail "the doorbell must start with the shell no-op prefix, got: $doorbell" ;;
  esac
  assert_contains "$doorbell" "'\\''s space/state/t1.inbox'" \
    "the doorbell should escape an embedded single quote in its quoted path"
  before=$(ls -R "$state/t1.inbox")
  for sh in sh bash zsh; do
    command -v "$sh" >/dev/null 2>&1 || continue
    out=$(cd "$state" && "$sh" -c "$doorbell" 2>&1) \
      || fail "$sh executed the hostile-path doorbell with a non-zero status: $out"
    [ -z "$out" ] || fail "$sh produced output while executing the hostile-path doorbell: $out"
    [ ! -e "$marker" ] || fail "$sh executed shell syntax embedded in the inbox path"
  done
  # An interactive-style zsh with the line fed on stdin, the closest portable
  # stand-in for a dead pane's login shell reading typed keystrokes.
  if command -v zsh >/dev/null 2>&1; then
    out=$(cd "$state" && printf '%s\n' "$doorbell" | zsh -s 2>&1) \
      || fail "zsh reading the hostile-path doorbell from stdin failed: $out"
    [ -z "$out" ] || fail "zsh printed while reading the hostile-path doorbell: $out"
    [ ! -e "$marker" ] || fail "zsh executed shell syntax from the stdin doorbell"
  fi
  after=$(ls -R "$state/t1.inbox")
  [ "$before" = "$after" ] || fail "executing the doorbell changed the inbox:"$'\n'"$after"
  [ -f "$rec" ] || fail "executing the doorbell removed the unhandled record"
  pass "inbox: a hostile-path doorbell executes as a no-op in bare shells"
}

test_doorbell_rejects_terminal_controls() {
  local dir state rec doorbell control label log marker rc
  dir="$TMP_ROOT/control-path"
  marker="$dir/marker"
  mkdir -p "$dir"
  make_watch_stubs "$dir" >/dev/null
  for label in etx esc; do
    case "$label" in
      etx) control=$'\003' ;;
      esc) control=$'\033' ;;
    esac
    state="$dir/${control}touch marker; # $label/state"
    mkdir -p "$state"
    rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
    doorbell=
    rc=0
    doorbell=$(inbox_lib "$state" fm_task_inbox_doorbell_line "$rec") || rc=$?
    [ "$rc" -ne 0 ] || fail "a $label path should make doorbell construction fail"
    [ -z "$doorbell" ] || fail "a rejected $label path emitted doorbell bytes"
    log="$dir/$label.send.log"; : > "$log"
    rc=0
    PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$log" \
      inbox_lib "$state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 || rc=$?
    [ "$rc" = 2 ] || fail "a rejected $label path should return send-failed status 2, got $rc"
    [ ! -s "$log" ] || fail "a $label path reached send-keys:"$'\n'"$(cat "$log")"
    [ ! -e "$marker" ] || fail "a $label path executed its crafted command"
    [ -f "$rec" ] || fail "rejecting a $label path removed the durable record"
  done
  pass "inbox: terminal-control paths are rejected without typing"
}

# fm_task_inbox_ring against a backend whose agent classifies dead or missing:
# nothing is typed and the distinct return code lets callers route to recovery.
# An unreadable endpoint still rings, so a blind classifier never starves a
# live worker.
test_ring_skips_dead_agent() {
  local dir state rec log rc
  dir="$TMP_ROOT/ring-dead"
  state="$dir/state"
  mkdir -p "$state"
  make_watch_stubs "$dir" >/dev/null
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  log="$dir/send.log"; : > "$log"
  rc=0
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$log" FM_FAKE_TMUX_AGENT=zsh \
    inbox_lib "$state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 || rc=$?
  [ "$rc" = 3 ] || fail "a dead agent should return 3 from the ring, got $rc"
  [ ! -s "$log" ] || fail "a dead pane was typed into:"$'\n'"$(cat "$log")"
  [ -f "$rec" ] || fail "skipping the ring must leave the durable record in place"
  rc=0
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$log" FM_FAKE_TMUX_MISSING=1 \
    inbox_lib "$state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 || rc=$?
  [ "$rc" = 3 ] || fail "a missing endpoint should return 3 from the ring, got $rc"
  [ ! -s "$log" ] || fail "a missing endpoint was typed into:"$'\n'"$(cat "$log")"
  [ -f "$rec" ] || fail "skipping a missing endpoint must leave the durable record in place"
  rc=0
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$log" FM_FAKE_TMUX_AGENT=claude \
    FM_FAKE_TMUX_TYPED="$dir/typed" \
    inbox_lib "$state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 || rc=$?
  [ "$rc" = 0 ] || fail "a live agent should still be rung, got $rc"
  grep -qF 'Firstmate instruction waiting' "$log" || fail "a live agent did not receive the doorbell"
  : > "$log"
  rc=0
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$log" FM_FAKE_TMUX_TYPED="$dir/typed" \
    inbox_lib "$state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 || rc=$?
  [ "$rc" = 0 ] || fail "an endpoint the classifier cannot see should still be rung, got $rc"
  grep -qF 'Firstmate instruction waiting' "$log" || fail "an unclassifiable endpoint did not receive the doorbell"
  pass "inbox: the ring skips dead or missing endpoints and still rings live or unclassifiable endpoints"
}

test_idempotent_write_dedups_exact_body() {
  local state r1 r2 r3 r4 count text
  state="$TMP_ROOT/idem/state"; mkdir -p "$state"
  text=$'re-runnable steer\nsecond line'
  r1=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 "$text") \
    || fail "idempotent write failed"
  [ "$r1" = "$state/t1.inbox/001.msg" ] || fail "first idempotent write should create 001.msg, got $r1"
  # Re-running the same enqueue (the safe recovery after an ambiguous remote
  # transport failure) lands on the SAME record, never a duplicate.
  r2=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 "$text") \
    || fail "idempotent re-run failed"
  [ "$r2" = "$r1" ] || fail "an identical re-run should return the existing record, got $r2"
  count=$(find "$state/t1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "an identical re-run must not enqueue a duplicate, found $count records"
  # A different body - two logical requests differ at least by their embedded
  # correlation token - still enqueues normally.
  r3=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 $'re-runnable steer\nsecond line changed') \
    || fail "idempotent write of a different body failed"
  [ "$r3" = "$state/t1.inbox/002.msg" ] || fail "a different body should enqueue a new record, got $r3"
  # A body the worker already acknowledged still dedups: the re-run reports
  # the handled record rather than re-delivering an instruction that was
  # already acted on.
  mv "$r1" "$state/t1.inbox/handled/"
  r4=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 "$text") \
    || fail "idempotent re-run after the ack failed"
  [ "$r4" = "$state/t1.inbox/handled/001.msg" ] \
    || fail "a re-run of an acknowledged steer should land on the handled record, got $r4"
  count=$(find "$state/t1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "a re-run of an acknowledged steer must not re-enqueue it, found $count unhandled records"
  pass "inbox: the idempotent enqueue dedups an exact re-run onto the same record, handled or not"
}

test_idempotent_write_follows_concurrent_ack() {
  local state rec result count text
  state="$TMP_ROOT/idem-ack-race/state"; mkdir -p "$state"
  text="acknowledge while dedup scans"
  rec=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 "$text") \
    || fail "race fixture write failed"
  result=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    eval "$(declare -f fm_task_inbox_body | sed "1s/fm_task_inbox_body/_original_fm_task_inbox_body/")"
    fm_task_inbox_body() {
      candidate=$1
      case "$candidate" in
        */handled/*) ;;
        *) mv "$candidate" "${candidate%/*}/handled/" || return 1
           candidate="${candidate%/*}/handled/${candidate##*/}" ;;
      esac
      _original_fm_task_inbox_body "$candidate"
    }
    fm_task_inbox_write_idempotent "$2" t1 "$3"
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$state" "$text") \
    || fail "idempotent enqueue failed while acknowledgement moved its candidate"
  [ "$result" = "$state/t1.inbox/handled/${rec##*/}" ] \
    || fail "dedup did not follow the concurrently acknowledged record: $result"
  count=$(find "$state/t1.inbox" -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "acknowledgement racing dedup created a duplicate record"
  pass "inbox: idempotent enqueue follows a record concurrently moved to handled"
}

test_handled_mv_dedups_by_sequence() {
  local state r1 r2 oldest r3
  state="$TMP_ROOT/dedup/state"; mkdir -p "$state"
  r1=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "first")
  r2=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "second")
  [ "$r2" = "$state/t1.inbox/002.msg" ] || fail "second record should be 002.msg, got $r2"
  oldest=$(inbox_lib "$state" fm_task_inbox_oldest_unhandled "$state" t1)
  [ "$oldest" = "$r1" ] || fail "oldest unhandled should be 001, got $oldest"
  mv "$r1" "$state/t1.inbox/handled/"
  oldest=$(inbox_lib "$state" fm_task_inbox_oldest_unhandled "$state" t1)
  [ "$oldest" = "$r2" ] || fail "after the ack mv the oldest should advance to 002, got $oldest"
  # Re-acking the same message is a no-op: the record is already retired and
  # nothing re-lists it as unhandled.
  mv "$state/t1.inbox/001.msg" "$state/t1.inbox/handled/" 2>/dev/null \
    && fail "a second mv of an acked record should find nothing to move"
  mv "$r2" "$state/t1.inbox/handled/"
  if inbox_lib "$state" fm_task_inbox_oldest_unhandled "$state" t1 >/dev/null; then
    fail "a fully handled inbox should report no unhandled record"
  fi
  # An acknowledged sequence is never reissued, so a message is processed at
  # most once per worker lifetime even if every doorbell is duplicated.
  r3=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "third")
  [ "$r3" = "$state/t1.inbox/003.msg" ] || fail "a handled sequence was reissued: $r3"
  pass "inbox: the handled mv is the idempotent ack and sequences are never reissued"
}

test_concurrent_writers_never_clobber() {
  local state i pids=() count
  state="$TMP_ROOT/race/state"; mkdir -p "$state"
  for i in 1 2 3 4 5 6; do
    inbox_lib "$state" fm_task_inbox_write "$state" t1 "steer number $i" >/dev/null &
    pids+=($!)
  done
  for i in "${pids[@]}"; do
    wait "$i" || fail "a concurrent inbox write failed"
  done
  count=$(find "$state/t1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 6 ] || fail "6 concurrent writes should yield 6 records, got $count:"$'\n'"$(ls "$state/t1.inbox")"
  for i in 1 2 3 4 5 6; do
    grep -rqF "steer number $i" "$state/t1.inbox" \
      || fail "steer number $i was lost in the concurrent write race"
  done
  pass "inbox: concurrent writers serialize on the sequence lock and lose nothing"
}

test_writer_retries_after_a_vanished_lock_collision() {
  local state fakebin marker rec real_ln
  state="$TMP_ROOT/vanished-lock-race/state"
  fakebin="$TMP_ROOT/vanished-lock-race/fakebin"
  marker="$TMP_ROOT/vanished-lock-race/first-ln-failed"
  mkdir -p "$state" "$fakebin"
  real_ln=$(command -v ln)
  cat > "$fakebin/ln" <<'SH'
#!/usr/bin/env bash
set -u
if [ ! -e "$FM_FAKE_LN_MARKER" ]; then
  : > "$FM_FAKE_LN_MARKER"
  exit 1
fi
exec "$FM_REAL_LN" "$@"
SH
  chmod +x "$fakebin/ln"

  rec=$(PATH="$fakebin:$PATH" FM_REAL_LN="$real_ln" FM_FAKE_LN_MARKER="$marker" \
    inbox_lib "$state" fm_task_inbox_write "$state" t1 "steer after collision") \
    || fail "a writer abandoned an acquisition whose competing lock had already vanished"
  [ -f "$rec" ] || fail "the retry after a vanished lock collision did not write its record"
  pass "inbox: a writer retries when a competing lock vanishes after its failed claim"
}

test_ladder_writes_ignore_vanished_inbox() {
  local state rec
  state="$TMP_ROOT/vanished/state"; mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "retired task")
  rm -rf "$state/t1.inbox"
  inbox_lib "$state" fm_task_inbox_record_ring "$state" t1 "$rec" \
    || fail "ring bookkeeping should ignore a concurrently removed inbox"
  inbox_lib "$state" fm_task_inbox_record_escalated "$state" t1 "$rec" \
    || fail "escalation bookkeeping should ignore a concurrently removed inbox"
  [ ! -e "$state/t1.inbox" ] || fail "bookkeeping recreated a retired task inbox"
  pass "inbox: ladder bookkeeping ignores a concurrently removed inbox"
}

test_fire_and_forget_records_never_enter_the_ladder() {
  local state fire tracked action
  state="$TMP_ROOT/fire-and-forget/state"; mkdir -p "$state"
  fire=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 "one-shot steer" fire-and-forget)
  age_path "$fire"
  action=$(FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_RING_MAX=0 \
    inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "a fire-and-forget record entered the re-ring ladder: $action"
  tracked=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "tracked steer")
  age_path "$tracked"
  action=$(FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_RING_MAX=0 \
    inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "escalate $tracked 0" ] \
    || fail "a fire-and-forget record hid the later tracked steer: $action"
  [ -f "$fire" ] || fail "excluding fire-and-forget from escalation removed its durable record"
  pass "inbox: fire-and-forget records stay durable and outside the ladder"
}

test_ring_ladder_policy() {
  local state rec action
  state="$TMP_ROOT/ladder/state"; mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "do the thing")
  # Within grace: quiet.
  action=$(FM_TASK_INBOX_GRACE_SECS=3600 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "a fresh unhandled message inside grace should be quiet, got: $action"
  # Past grace: one ring is due.
  age_path "$rec"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "ring $rec" ] || fail "an aged unhandled message should be due a ring, got: $action"
  # A just-recorded ring holds the spacing: quiet until another grace elapses.
  inbox_lib "$state" fm_task_inbox_record_ring "$state" t1 "$rec"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "a ring within the spacing window should be quiet, got: $action"
  # Backdate the ladder: the next ring becomes due, and at the budget the
  # action turns into a single escalation.
  printf '001.msg\t1\t100\n' > "$state/t1.inbox/.ring-state"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "ring $rec" ] || fail "an aged ladder should ring again, got: $action"
  printf '001.msg\t3\t100\n' > "$state/t1.inbox/.ring-state"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "escalate $rec 3" ] || fail "a spent ring budget should escalate, got: $action"
  # Escalation fires at most once per message.
  inbox_lib "$state" fm_task_inbox_record_escalated "$state" t1 "$rec"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "an escalated message should stay quiet for recovery, got: $action"
  # The acknowledgement resets the ladder: the next message starts fresh.
  mv "$rec" "$state/t1.inbox/handled/"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "a handled inbox should be quiet, got: $action"
  [ ! -e "$state/t1.inbox/.escalated" ] || fail "the ack should clear the escalation marker"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "next thing")
  age_path "$rec"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "ring $rec" ] || fail "the next message should start a fresh ladder, got: $action"
  pass "inbox: the re-ring ladder paces by grace, escalates once, and resets on ack"
}

setup_watch_case() {  # <name> -> echoes case dir; state in <dir>/state
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state"
  make_watch_stubs "$dir" >/dev/null
  fm_write_meta "$dir/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=grok"
  printf '%s\n' "$dir"
}

idle_capture() {  # <dir>
  printf '╭────╮\n│    │\n╰────╯\n' > "$1/idle.capture"
  printf '%s\n' "$1/idle.capture"
}

test_watcher_rerings_idle_pane_quietly() {
  local dir state out log pid rec
  dir=$(setup_watch_case rering)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=99
  pid=$!
  local i=0
  while [ "$i" -lt 100 ]; do
    grep -qF 'Firstmate instruction waiting' "$log" 2>/dev/null && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "Firstmate instruction waiting: list '$state/t1.inbox'/*.msg" "$log" \
    || { kill "$pid" 2>/dev/null; fail "the watcher never re-rang the doorbell:"$'\n'"$(cat "$log")"; }
  kill -0 "$pid" 2>/dev/null \
    || fail "a healthy re-ring must not wake firstmate (watcher exited):"$'\n'"$(cat "$out")"
  [ ! -s "$state/.wake-queue" ] \
    || { kill "$pid" 2>/dev/null; fail "a healthy re-ring queued a wake:"$'\n'"$(cat "$state/.wake-queue")"; }
  # The acknowledgement silences the ladder: no further doorbells after the mv.
  mv "$rec" "$state/t1.inbox/handled/"
  sleep 2.5
  : > "$log"
  sleep 2.5
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  [ ! -s "$log" ] || fail "the watcher kept ringing after the ack:"$'\n'"$(cat "$log")"
  pass "watcher: an unhandled aged message on an idle pane re-rings without waking firstmate, and the ack silences it"
}

test_watcher_waits_on_busy_pane() {
  local dir state out log pid rec
  dir=$(setup_watch_case busywait)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  printf 'some output\nBUSYTOKEN active\n' > "$dir/busy.capture"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$dir/busy.capture" \
    FM_BUSY_REGEX=BUSYTOKEN FM_TASK_INBOX_RING_MAX=99
  pid=$!
  sleep 4
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  [ ! -s "$log" ] || fail "a busy pane should wait, not ring:"$'\n'"$(cat "$log")"
  [ ! -s "$state/.wake-queue" ] || fail "a busy wait queued a wake:"$'\n'"$(cat "$state/.wake-queue")"
  pass "watcher: a busy pane just waits - the record is durable and no doorbell is typed"
}

test_watcher_quiet_on_healthy_inbox() {
  local dir state out log pid
  dir=$(setup_watch_case healthy)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  mkdir -p "$state/t1.inbox/handled"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=99
  pid=$!
  sleep 4
  kill -0 "$pid" 2>/dev/null || fail "the watcher exited on a healthy empty inbox:"$'\n'"$(cat "$out")"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  [ ! -s "$log" ] || fail "an empty inbox rang a doorbell:"$'\n'"$(cat "$log")"
  [ ! -s "$state/.wake-queue" ] || fail "an empty inbox queued a wake:"$'\n'"$(cat "$state/.wake-queue")"
  pass "watcher: a healthy or empty inbox stays completely silent"
}

test_watcher_ack_silences_unwritable_ladder() {
  local dir state out log pid rec rings i=0
  dir=$(setup_watch_case ack-unwritable-ladder)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  mkdir "$state/t1.inbox/.ring-state"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_ACK_RECORD="$rec" FM_TASK_INBOX_RING_MAX=99
  pid=$!
  while [ "$i" -lt 100 ]; do
    [ -f "$state/t1.inbox/handled/001.msg" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  [ -f "$state/t1.inbox/handled/001.msg" ] \
    || { kill "$pid" 2>/dev/null; fail "the doorbell stub did not acknowledge the record"; }
  sleep 2
  kill -0 "$pid" 2>/dev/null \
    || fail "the watcher escalated ladder failure after the record was acknowledged:"$'\n'"$(cat "$out")"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  rings=$(grep -cF 'Firstmate instruction waiting' "$log" || true)
  [ "$rings" = 1 ] || fail "acknowledgement should silence retries, got $rings doorbells:"$'\n'"$(cat "$log")"
  [ ! -s "$state/.wake-queue" ] \
    || fail "an acknowledged record queued a bookkeeping wake:"$'\n'"$(cat "$state/.wake-queue")"
  pass "watcher: acknowledgement silences an unwritable ladder without a stale wake"
}

test_watcher_surfaces_unwritable_ladder() {
  local dir state out log pid rec rings wakes
  dir=$(setup_watch_case unwritable-ladder)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  mkdir "$state/t1.inbox/.ring-state"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=99
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "the watcher silently retried with unwritable ladder bookkeeping"; }
  rings=$(grep -cF 'Firstmate instruction waiting' "$log" || true)
  [ "$rings" = 1 ] || fail "expected one doorbell before the bookkeeping wake, got $rings:"$'\n'"$(cat "$log")"
  wakes=$(grep -cF 'steering-inbox ladder bookkeeping unwritable' "$state/.wake-queue" || true)
  [ "$wakes" = 1 ] \
    || fail "expected exactly one bookkeeping-unwritable stale wake, got $wakes:"$'\n'"$(cat "$state/.wake-queue" 2>/dev/null)"
  grep -qF "$state/t1.inbox/.ring-state cannot be written" "$state/.wake-queue" \
    || fail "the stale wake did not identify the unwritable ladder:"$'\n'"$(cat "$state/.wake-queue")"
  [ -f "$rec" ] || fail "the unhandled record disappeared during bookkeeping failure"
  grep -qF 'stale:' "$out" \
    || fail "the watcher should exit through the ordinary stale wake:"$'\n'"$(cat "$out")"
  pass "watcher: unwritable ladder bookkeeping surfaces a stale wake after the doorbell"
}

test_watcher_escalates_once_after_budget() {
  local dir state out log pid rec rings
  dir=$(setup_watch_case escalate)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=1
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "the watcher never escalated a spent ring budget"; }
  rings=$(grep -cF 'Firstmate instruction waiting' "$log" || true)
  [ "$rings" = 1 ] || fail "expected exactly 1 doorbell before escalation, got $rings:"$'\n'"$(cat "$log")"
  grep -qF 'unread firstmate instruction' "$state/.wake-queue" \
    || fail "the escalation should queue a stale wake naming the unread instruction:"$'\n'"$(cat "$state/.wake-queue" 2>/dev/null)"
  grep -qF "$rec" "$state/.wake-queue" \
    || fail "the stale wake should name the record path:"$'\n'"$(cat "$state/.wake-queue")"
  [ "$(grep -cF 'unread firstmate instruction' "$state/.wake-queue")" = 1 ] \
    || fail "the escalation must fire exactly once:"$'\n'"$(cat "$state/.wake-queue")"
  grep -qF 'stale:' "$out" || fail "the watcher should exit through the ordinary stale wake:"$'\n'"$(cat "$out")"
  pass "watcher: a spent ring budget emits exactly one ordinary stale wake for recovery"
}

test_watcher_dead_pane_escalates_once_without_ringing() {
  local dir state out log pid rec
  dir=$(setup_watch_case dead-pane)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_FAKE_TMUX_AGENT=zsh FM_TASK_INBOX_RING_MAX=99
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "the watcher never surfaced a dead pane's unhandled instruction"; }
  [ ! -s "$log" ] || fail "a dead pane was typed into:"$'\n'"$(cat "$log")"
  [ "$(grep -cF 'unread firstmate instruction' "$state/.wake-queue" 2>/dev/null || true)" = 1 ] \
    || fail "a dead pane should surface exactly one stale wake:"$'\n'"$(cat "$state/.wake-queue" 2>/dev/null)"
  grep -qF "agent has exited" "$state/.wake-queue" \
    || fail "the stale wake should say the agent has exited:"$'\n'"$(cat "$state/.wake-queue")"
  grep -qF "$rec" "$state/.wake-queue" || fail "the stale wake should name the record path"
  [ -f "$rec" ] || fail "the durable record must survive for recovery"
  [ "$(cat "$state/t1.inbox/.escalated")" = "${rec##*/}" ] \
    || fail "the escalation marker should suppress further surfacing of this record"
  [ ! -e "$state/t1.inbox/.ring-state" ] || fail "a dead pane must not enter the re-ring ladder"
  # The ladder is capped: nothing further is due for this record, so no later
  # poll rings the dead pane or queues a second wake.
  [ "$(inbox_lib "$state" fm_task_inbox_due_action "$state" t1)" = quiet ] \
    || fail "a dead pane already surfaced must be quiet on later polls"
  pass "watcher: a positively dead pane is never typed into and surfaces exactly one stale wake"
}

test_watcher_dead_pane_ignores_stale_busy_state() {
  local dir state out log pid rec
  dir=$(setup_watch_case dead-pane-busy)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  printf 'some output\nBUSYTOKEN active\n' > "$dir/busy.capture"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$dir/busy.capture" \
    FM_FAKE_TMUX_AGENT=zsh FM_BUSY_REGEX=BUSYTOKEN FM_TASK_INBOX_RING_MAX=99
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "stale busy state hid a dead pane's unhandled instruction"; }
  [ ! -s "$log" ] || fail "a busy-marked dead pane was typed into:"$'\n'"$(cat "$log")"
  [ "$(grep -cF 'unread firstmate instruction' "$state/.wake-queue" 2>/dev/null || true)" = 1 ] \
    || fail "a busy-marked dead pane should surface exactly once:"$'\n'"$(cat "$state/.wake-queue" 2>/dev/null)"
  [ -f "$rec" ] || fail "the durable record must survive stale busy-state recovery"
  [ "$(cat "$state/t1.inbox/.escalated")" = "${rec##*/}" ] \
    || fail "stale busy-state recovery should suppress repeated surfacing"
  pass "watcher: dead-pane recovery overrides stale busy state"
}

# --- incident regressions: the ring against real screens ---------------------
#
# A doorbell Enter once confirmed Codex's global-update picker and broke the
# shared Codex install: the plain composer read that screen as unknown (cursor
# below the rows) or pending (cursor on the selection row), and the ring typed
# into both. These cases rebuild that screen, using the picker rows recorded in
# tests/fm-control.test.sh, in a REAL private tmux server (-L) and drive the real
# ring and the real fm-send through it. The ring's gate is per harness: the
# picker and pending text are refused on every harness, a Codex pane also needs
# a proven-empty composer, and any other harness still rings on an unknown
# screen. The screens are drawn by a bash stub launched through a `codex`- or
# `agy`-named symlink to bash, so the pane's foreground process reads as a live
# agent without any harness running. The stub logs
# every byte it receives (KEY), every Enter (ENTER), and every submitted line
# (SUBMIT), and on a submitted doorbell it acknowledges like a worker by moving
# the inbox records into handled/.
RING_TMUX=
RING_SOCKET="fm-inbox-ring-$$"
RING_LAB=

ring_lab_cleanup() {
  [ -z "$RING_TMUX" ] || "$RING_TMUX" -L "$RING_SOCKET" kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}

ring_lab_setup() {
  local bash_bin
  [ -z "$RING_LAB" ] || return 0
  RING_TMUX=$(command -v tmux) || fail "the ring regressions need tmux"
  bash_bin=$(command -v bash)
  trap ring_lab_cleanup EXIT
  RING_LAB="$TMP_ROOT/ring-lab"
  mkdir -p "$RING_LAB/shim" "$RING_LAB/bin"
  printf '#!/usr/bin/env bash\nexec "%s" -L "%s" "$@"\n' "$RING_TMUX" "$RING_SOCKET" > "$RING_LAB/shim/tmux"
  chmod +x "$RING_LAB/shim/tmux"
  ln -s "$bash_bin" "$RING_LAB/bin/codex"
  ln -s "$bash_bin" "$RING_LAB/bin/agy"
  cat > "$RING_LAB/screen-stub.sh" <<'STUB'
# Screen stub: <mode> <log>. Modes: empty, pending, unknown, picker-below,
# picker-row, picker-after-key (empty until the first key, then the picker),
# noecho (an empty composer that never renders what is typed), agy (agy's idle
# shape: a `>` row between two solid rules, which classifies unknown).
mode=$1 log=$2 buf=
cols=$(stty size 2>/dev/null | cut -d' ' -f2)
case "$cols" in ''|*[!0-9]*) cols=80 ;; esac
old=$(stty -g 2>/dev/null || true)
stty -echo -icanon min 1 time 0 2>/dev/null || true
trap '[ -z "$old" ] || stty "$old" 2>/dev/null' EXIT
[ "$mode" != pending ] || buf='half typed words'
picker() {
  printf '\033[2J\033[H'
  printf '%s\r\n' '  Update available · 0.162.1 → 0.999.0' \
    '  Release notes: https://github.com/openai/codex/releases/latest' '' \
    '› 1. Update now (runs `npm install -g @openai/codex`)' '  2. Skip' \
    '  3. Skip until next version' '' '  enter continue · esc skip'
  [ "$mode" != picker-row ] || printf '\033[4;1H'
}
composer() {
  local w=$((cols - 2)) i=0 row=3 len
  printf '\033[2J\033[H>_ Codex-shaped test stub\r\n\r\n'
  if [ -z "$buf" ]; then
    printf '› \033[2mAsk Codex to do anything\033[0m\r\n\r\n  \033[2m100%% context left\033[0m\033[3;3H'
    return
  fi
  printf '› %s' "${buf:0:w}"
  i=$w
  while [ "$i" -lt "${#buf}" ]; do
    printf '\r\n  %s' "${buf:i:w}"
    i=$((i + w))
    row=$((row + 1))
  done
  len=$(( ${#buf} - (row - 3) * w ))
  printf '\r\n\r\n  \033[2m100%% context left\033[0m\033[%d;%dH' "$row" "$((3 + len))"
}
agy() {
  local rule='────────────────────────────────────────'
  printf '\033[2J\033[HAntigravity test stub\r\n\r\n%s\r\n>\r\n%s\r\n  ? for shortcuts\033[4;2H' "$rule" "$rule"
}
draw() {
  case "$mode" in
    picker-below|picker-row) picker ;;
    unknown) printf '\033[2J\033[H  Loading your session\r\n\r\n' ;;
    agy) agy ;;
    *) composer ;;
  esac
}
draw
while IFS= read -r -n 1 ch; do
  if [ -z "$ch" ]; then
    printf 'ENTER\n' >> "$log"
    case "$mode" in
      empty|pending|agy)
        if [ -n "$buf" ]; then
          printf 'SUBMIT %s\n' "$buf" >> "$log"
          if [[ $buf =~ list\ \'([^\']+)\'/\*\.msg ]]; then
            for f in "${BASH_REMATCH[1]}"/*.msg; do
              [ -e "$f" ] && mv "$f" "${BASH_REMATCH[1]}/handled/"
            done
          fi
          buf=
        fi
        ;;
    esac
  else
    printf 'KEY %s\n' "$ch" >> "$log"
    case "$mode" in
      empty|pending|agy) buf="$buf$ch" ;;
      picker-after-key) mode=picker-below ;;
    esac
  fi
  draw
done
STUB
  "$RING_TMUX" -L "$RING_SOCKET" new-session -d -s ring -x 200 -y 40
}

# Start one stub window and wait until its screen is drawn. Echoes its target.
ring_stub_window() {  # <name> <mode> <log>
  local name=$1 mode=$2 log=$3 i=0 marker agent=codex
  : > "$log"
  [ "$mode" != agy ] || agent=agy
  "$RING_TMUX" -L "$RING_SOCKET" new-window -d -t ring: -n "$name" -- \
    "$RING_LAB/bin/$agent" "$RING_LAB/screen-stub.sh" "$mode" "$log"
  case "$mode" in
    picker-below|picker-row) marker='esc skip' ;;
    unknown) marker='Loading your session' ;;
    agy) marker='for shortcuts' ;;
    *) marker='context left' ;;
  esac
  while [ "$i" -lt 100 ]; do
    "$RING_TMUX" -L "$RING_SOCKET" capture-pane -p -t "ring:$name" 2>/dev/null | grep -qF "$marker" && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$i" -lt 100 ] || fail "the $mode stub never drew its screen"
  printf 'ring:%s\n' "$name"
}

# Ring one fresh record into a stub window through the real library, as the
# recorded harness. Prints the ring's return code.
ring_into() {  # <state> <task> <target> <harness>
  local state=$1 task=$2 target=$3 harness=$4 rec rc=0
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" "$task" "please continue")
  PATH="$RING_LAB/shim:$PATH" FM_TASK_INBOX_RING_POLLS=5 \
    inbox_lib "$state" fm_task_inbox_ring tmux "$target" "$rec" "" "$harness" || rc=$?
  printf '%s\n' "$rc"
}

test_ring_refuses_the_codex_update_picker() {
  local state target log rc mode harness
  ring_lab_setup
  state="$TMP_ROOT/ring-picker/state"
  mkdir -p "$state"
  for mode in picker-below picker-row; do
    for harness in codex agy; do
      log="$RING_LAB/$mode-$harness.log"
      target=$(ring_stub_window "$mode-$harness" "$mode" "$log")
      rc=$(ring_into "$state" "$mode-$harness" "$target" "$harness")
      sleep 0.3
      [ "$rc" = 4 ] || fail "the ring should refuse the update picker ($mode, $harness) with 4, got $rc"
      [ ! -s "$log" ] || fail "the ring typed into the update picker ($mode, $harness):"$'\n'"$(cat "$log")"
      [ -f "$state/$mode-$harness.inbox/001.msg" ] || fail "a refused ring must leave the durable record ($mode, $harness)"
    done
  done
  pass "inbox: the ring refuses Codex's update picker on every harness, cursor below the rows or on the selection row, with nothing typed and no Enter"
}

test_ring_refuses_a_picker_that_appears_while_typing() {
  local state target log rc harness
  ring_lab_setup
  state="$TMP_ROOT/ring-picker-late/state"
  mkdir -p "$state"
  for harness in codex claude; do
    log="$RING_LAB/picker-after-key-$harness.log"
    target=$(ring_stub_window "late-$harness" picker-after-key "$log")
    rc=$(ring_into "$state" "late-$harness" "$target" "$harness")
    sleep 0.3
    [ "$rc" = 4 ] || fail "a picker that appears after the empty-composer check should stop the ring with 4 ($harness), got $rc"
    grep -q '^KEY' "$log" || fail "the case is vacuous unless the doorbell was typed before the picker appeared ($harness)"
    ! grep -q '^ENTER' "$log" || fail "the ring pressed Enter into the picker ($harness):"$'\n'"$(cat "$log")"
  done
  pass "inbox: a picker that appears after the composer check stops the ring before its Enter on every harness"
}

test_ring_still_delivers_into_an_empty_composer() {
  local state target log rc
  ring_lab_setup
  state="$TMP_ROOT/ring-empty/state"
  mkdir -p "$state"
  log="$RING_LAB/empty.log"
  target=$(ring_stub_window empty empty "$log")
  rc=$(ring_into "$state" t1 "$target" codex)
  [ "$rc" = 0 ] || fail "the ring should deliver into a proven-empty composer, got $rc"
  local i=0
  while [ "$i" -lt 50 ] && [ -e "$state/t1.inbox/001.msg" ]; do sleep 0.1; i=$((i + 1)); done
  [ "$(grep -c '^ENTER' "$log")" = 1 ] || fail "the ring should press exactly one Enter:"$'\n'"$(cat "$log")"
  grep -qF "SUBMIT : Firstmate instruction waiting: list '$state/t1.inbox'/*.msg" "$log" \
    || fail "the stub never received the doorbell line:"$'\n'"$(cat "$log")"
  [ -f "$state/t1.inbox/handled/001.msg" ] || fail "the delivered doorbell was not acted on"
  pass "inbox: an ordinary empty composer still receives the doorbell and exactly one Enter"
}

test_ring_refuses_pending_and_unproven_codex_screens() {
  local state target log rc mode
  ring_lab_setup
  state="$TMP_ROOT/ring-unproven/state"
  mkdir -p "$state"
  for mode in pending unknown; do
    log="$RING_LAB/$mode.log"
    target=$(ring_stub_window "$mode" "$mode" "$log")
    rc=$(ring_into "$state" "$mode" "$target" codex)
    sleep 0.3
    [ "$rc" = 1 ] || fail "the ring should refuse a $mode Codex screen with 1, got $rc"
    [ ! -s "$log" ] || fail "the ring typed into a $mode Codex screen:"$'\n'"$(cat "$log")"
  done
  # Pending text is protected on every harness.
  log="$RING_LAB/pending-agy.log"
  target=$(ring_stub_window pending-agy pending "$log")
  rc=$(ring_into "$state" pending-agy "$target" agy)
  sleep 0.3
  [ "$rc" = 1 ] || fail "the ring should refuse pending composer text on any harness with 1, got $rc"
  [ ! -s "$log" ] || fail "the ring typed into pending composer text:"$'\n'"$(cat "$log")"
  log="$RING_LAB/noecho.log"
  target=$(ring_stub_window noecho noecho "$log")
  rc=$(ring_into "$state" noecho "$target" codex)
  sleep 0.3
  [ "$rc" = 5 ] || fail "a Codex composer that never shows the typed doorbell should withhold the Enter with 5, got $rc"
  grep -q '^KEY' "$log" || fail "the noecho case is vacuous unless the doorbell was typed"
  ! grep -q '^ENTER' "$log" || fail "the ring pressed Enter on an unproven Codex screen:"$'\n'"$(cat "$log")"
  pass "inbox: pending text gets no keystroke on any harness, and an unproven Codex screen gets no keystroke or no Enter"
}

# The other harnesses keep ringing on an unknown screen until their idle
# verdicts are proven: agy's real idle shape classifies unknown, and its
# doorbell must still be typed, submitted once, and acted on.
test_ring_still_rings_an_agy_shaped_unknown_screen() {
  local state target log rc verdict i=0
  ring_lab_setup
  state="$TMP_ROOT/ring-agy/state"
  mkdir -p "$state"
  log="$RING_LAB/agy.log"
  target=$(ring_stub_window agy agy "$log")
  verdict=$(PATH="$RING_LAB/shim:$PATH" bash -c '. "$1"; fm_backend_composer_state tmux "$2"' _ \
    "$ROOT/bin/fm-backend.sh" "$target")
  [ "$verdict" = unknown ] || fail "the case is vacuous unless agy's idle shape classifies unknown, got $verdict"
  rc=$(ring_into "$state" t1 "$target" agy)
  [ "$rc" = 0 ] || fail "an agy pane on an unknown idle screen should still be rung, got $rc"
  while [ "$i" -lt 50 ] && [ -e "$state/t1.inbox/001.msg" ]; do sleep 0.1; i=$((i + 1)); done
  [ "$(grep -c '^ENTER' "$log")" = 1 ] || fail "the agy ring should press exactly one Enter:"$'\n'"$(cat "$log")"
  grep -qF "SUBMIT : Firstmate instruction waiting: list '$state/t1.inbox'/*.msg" "$log" \
    || fail "the agy stub never received the doorbell line:"$'\n'"$(cat "$log")"
  [ -f "$state/t1.inbox/handled/001.msg" ] || fail "the agy doorbell was not acted on"
  pass "inbox: an agy-shaped unknown idle screen still receives the doorbell and one Enter"
}

# The incident path end to end: the real fm-send rings into the stub picker
# and types nothing, while the same send into an empty composer is delivered
# and acknowledged.
test_fm_send_ring_through_picker_and_composer() {
  local home target log err
  ring_lab_setup
  home="$TMP_ROOT/ring-send/home"
  mkdir -p "$home/state"
  log="$RING_LAB/send-picker.log"
  target=$(ring_stub_window send-picker picker-below "$log")
  fm_write_meta "$home/state/p1.meta" "window=$target" "backend=tmux" "kind=ship" "harness=codex"
  err="$TMP_ROOT/ring-send/picker.err"
  PATH="$RING_LAB/shim:$PATH" FM_HOME="$home" \
    "$ROOT/bin/fm-send.sh" p1 "please continue" >/dev/null 2>"$err" \
    || fail "a send refused at the picker is still a durably sent steer:"$'\n'"$(cat "$err")"
  sleep 0.3
  [ ! -s "$log" ] || fail "fm-send typed into the update picker:"$'\n'"$(cat "$log")"
  [ -f "$home/state/p1.inbox/001.msg" ] || fail "fm-send did not record the steer"
  assert_contains "$(cat "$err")" "Codex global-update picker" "fm-send should say why no Enter was sent"
  log="$RING_LAB/send-empty.log"
  target=$(ring_stub_window send-empty empty "$log")
  fm_write_meta "$home/state/e1.meta" "window=$target" "backend=tmux" "kind=ship" "harness=codex"
  PATH="$RING_LAB/shim:$PATH" FM_HOME="$home" \
    "$ROOT/bin/fm-send.sh" e1 "please continue" >/dev/null 2>"$err" \
    || fail "a send into an empty composer should succeed:"$'\n'"$(cat "$err")"
  local i=0
  while [ "$i" -lt 50 ] && [ -e "$home/state/e1.inbox/001.msg" ]; do sleep 0.1; i=$((i + 1)); done
  [ -f "$home/state/e1.inbox/handled/001.msg" ] \
    || fail "fm-send's doorbell into an empty composer was not acted on:"$'\n'"$(cat "$log")"
  [ "$(grep -c '^ENTER' "$log")" = 1 ] || fail "fm-send should press exactly one Enter:"$'\n'"$(cat "$log")"
  pass "fm-send: the incident's picker gets no keystroke, and an empty composer still gets the doorbell"
}

# The re-ring path through the real watcher: a picker on screen is never typed
# into, every refusal spends one attempt, and the spent budget escalates the
# unread record as a stuck steer that names the picker.
test_watcher_rering_refuses_picker_and_escalates() {
  local dir state out log keys pid rec cursor
  for cursor in 8 3; do
    dir=$(setup_watch_case "picker-rering-$cursor")
    state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; keys="$dir/keys.log"
    : > "$log"; : > "$keys"
    # The backticks are the vendor's literal row text, not an expansion.
    # shellcheck disable=SC2016
    printf '%s\n' '  Update available · 0.162.1 → 0.999.0' \
      '  Release notes: https://github.com/openai/codex/releases/latest' '' \
      '› 1. Update now (runs `npm install -g @openai/codex`)' '  2. Skip' \
      '  3. Skip until next version' '' '  enter continue · esc skip' '' > "$dir/picker.capture"
    rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
    age_path "$rec"
    watch_bg "$state" "$dir/fakebin" "$out" \
      FM_SEND_LOG="$log" FM_KEY_LOG="$keys" FM_FAKE_TMUX_CAPTURE="$dir/picker.capture" \
      FM_FAKE_TMUX_CURSOR="$cursor" FM_TASK_INBOX_RING_MAX=2
    pid=$!
    wait_watcher_gone "$pid" 200 \
      || { kill "$pid" 2>/dev/null; fail "the watcher never escalated refused picker rings (cursor row $cursor)"; }
    [ ! -s "$log" ] || fail "the watcher typed into the picker (cursor row $cursor):"$'\n'"$(cat "$log")"
    [ ! -s "$keys" ] || fail "the watcher sent a key into the picker (cursor row $cursor):"$'\n'"$(cat "$keys")"
    [ "$(cut -f2 "$state/t1.inbox/.ring-state")" = 2 ] \
      || fail "each refused ring should spend one attempt (cursor row $cursor): $(cat "$state/t1.inbox/.ring-state")"
    grep -qF 'unread firstmate instruction' "$state/.wake-queue" \
      || fail "refused rings must escalate as a stuck steer (cursor row $cursor):"$'\n'"$(cat "$state/.wake-queue" 2>/dev/null)"
    grep -qF 'Codex global-update picker' "$state/.wake-queue" \
      || fail "the escalation should name the picker (cursor row $cursor):"$'\n'"$(cat "$state/.wake-queue")"
    [ -f "$rec" ] || fail "the durable record must survive refused rings"
  done
  pass "watcher: re-rings never type into the update picker, and the spent budget escalates naming it"
}

test_write_is_durable_and_exact
test_doorbell_is_a_shell_noop
test_doorbell_rejects_terminal_controls
test_ring_skips_dead_agent
test_idempotent_write_dedups_exact_body
test_idempotent_write_follows_concurrent_ack
test_handled_mv_dedups_by_sequence
test_concurrent_writers_never_clobber
test_writer_retries_after_a_vanished_lock_collision
test_ladder_writes_ignore_vanished_inbox
test_fire_and_forget_records_never_enter_the_ladder
test_ring_ladder_policy
test_watcher_rerings_idle_pane_quietly
test_watcher_waits_on_busy_pane
test_watcher_quiet_on_healthy_inbox
test_watcher_ack_silences_unwritable_ladder
test_watcher_surfaces_unwritable_ladder
test_watcher_escalates_once_after_budget
test_watcher_dead_pane_escalates_once_without_ringing
test_watcher_dead_pane_ignores_stale_busy_state
test_ring_refuses_the_codex_update_picker
test_ring_refuses_a_picker_that_appears_while_typing
test_ring_still_delivers_into_an_empty_composer
test_ring_refuses_pending_and_unproven_codex_screens
test_ring_still_rings_an_agy_shaped_unknown_screen
test_fm_send_ring_through_picker_and_composer
test_watcher_rering_refuses_picker_and_escalates
