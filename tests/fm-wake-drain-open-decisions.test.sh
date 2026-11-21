#!/usr/bin/env bash
# tests/fm-wake-drain-open-decisions.test.sh - behavior tests for the OPEN
# DECISIONS section bin/fm-wake-drain.sh prints on every drain (including the
# empty-queue fast path). The section is pure wiring around
# fm-classify-lib.sh's status_open_decisions fold (the ONE authoritative
# open/resolved statement); these tests exercise the real drain script over
# crafted status logs and assert on its printed output, not on the fold's own
# source text.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-open-decisions-tests)

test_buried_decision_still_surfaces() {
  local dir state out
  dir=$(make_case buried)
  state="$dir/state"
  out="$dir/drain.out"
  # The needs-decision line sits under later routine and unrelated-key lines,
  # exactly the burial scenario the fix targets: last-line-only reads would
  # show "resolved [key=other]" and hide the still-open api-shape decision.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task1.status"
  printf 'working: continuing other work\n' >> "$state/task1.status"
  printf 'resolved [key=other]: unrelated decision closed\n' >> "$state/task1.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a buried decision"

  grep -F 'OPEN DECISIONS' "$out" >/dev/null || fail "buried decision produced no OPEN DECISIONS section"
  grep -F 'task1' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "buried needs-decision was not surfaced with its task, key, and note"
  grep -F "close one by answering it: bin/fm-send.sh <task> --resolve-key <key>" "$out" >/dev/null \
    || fail "open section is missing the answerer-closes hint"
  pass "a needs-decision buried under later routine/other-key lines still reports as open"
}

test_explicit_resolution_closes_it() {
  local dir state out
  dir=$(make_case resolved)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task2.status"
  printf 'resolved [key=api-shape]: went with REST\n' >> "$state/task2.status"
  printf 'done: shipped\n' >> "$state/task2.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after an explicit resolution"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "an explicitly resolved decision still printed as open: $(cat "$out")"
  fi
  pass "an explicit resolved [key=X] closes the keyed decision"
}

test_reserved_key_namespace_is_owned_by_its_library() {
  local dir state out
  dir=$(make_case reserved-key)
  state="$dir/state"
  out="$dir/drain.out"
  # `pending-reply-<id>` names a decision bin/fm-pending-reply-lib.sh raises and
  # is the only writer that closes it. Every writer reaches this same stream - a
  # local mate appends into it directly, and a remote mate's lines are mirrored
  # into it verbatim - so another writer must not be able to take that key over
  # or clear it just by naming it.
  printf 'blocked [key=pending-reply-abcdef0123456789]: pending-reply-missed: task=ios pending-reply-id=abcdef0123456789 request=ship it\n' > "$state/task9.status"
  printf 'blocked [key=pending-reply-abcdef0123456789]: shipping is blocked on infra\n' >> "$state/task9.status"
  printf 'resolved [key=pending-reply-abcdef0123456789]: all good now\n' >> "$state/task9.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on reserved-key lines"

  grep -F 'pending-reply-id=abcdef0123456789' "$out" >/dev/null \
    || fail "a foreign resolution cleared a reserved decision it does not own: $(cat "$out")"
  if grep -F 'shipping is blocked on infra' "$out" >/dev/null; then
    fail "a foreign line took over a reserved decision key: $(cat "$out")"
  fi

  # The owner's own resolution, which speaks that namespace's vocabulary, closes it.
  printf 'resolved [key=pending-reply-abcdef0123456789]: pending-reply-resolved: task=ios pending-reply-id=abcdef0123456789 via=status\n' >> "$state/task9.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after the owner closed its decision"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the owner's own resolution did not close its reserved decision: $(cat "$out")"
  fi
  pass "a reserved decision key can only be opened or closed by its owning library"
}

test_later_unrelated_terminal_line_does_not_close_it() {
  local dir state out
  dir=$(make_case unrelated-terminal)
  state="$dir/state"
  out="$dir/drain.out"
  # A later done: with no matching [key=...] token opens/closes only the
  # "default" key; it must never clear the still-open api-shape decision.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task3.status"
  printf 'done: unrelated later milestone\n' >> "$state/task3.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after an unrelated terminal line"

  grep -F 'task3' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "a later unrelated terminal line incorrectly cleared the open decision"
  pass "a later unrelated terminal line never clears an open decision"
}

test_no_open_decisions_prints_nothing() {
  local dir state out
  dir=$(make_case none-open)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'working: on it\n' > "$state/task4.status"
  printf 'resolved: shipped clean\n' > "$state/task5.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with no open decisions"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the empty case printed an OPEN DECISIONS section: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the empty case with no queued wakes was not silent: $(cat "$out")"
  pass "no open decisions across the fleet prints nothing"
}

test_open_decision_surfaces_even_with_an_unrelated_queued_wake() {
  local dir state out
  dir=$(make_case fleet-wide)
  state="$dir/state"
  out="$dir/drain.out"
  # task6 has a buried, still-open decision but generates NO new queue record
  # this turn; task7 is what actually wakes the drain. The fleet-wide scan
  # must still catch task6's decision alongside task7's own raw row.
  printf 'needs-decision [key=migration]: pick the rollout plan\n' > "$state/task6.status"
  printf 'working: continuing\n' >> "$state/task6.status"
  printf 'blocked: waiting on credentials\n' > "$state/task7.status"
  append_wake "$state" signal task7.status "blocked: waiting on credentials" \
    || fail "queueing the unrelated wake failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a mixed fleet"

  grep "$(printf '\tsignal\ttask7.status\t')" "$out" >/dev/null || fail "task7's own raw row is missing"
  grep -F 'task6' "$out" | grep -F '[key=migration]' >/dev/null \
    || fail "task6's buried decision was not surfaced even though only task7 queued a wake"
  pass "the open-decision section is fleet-wide, not scoped to this drain's own queued records"
}

test_buried_decision_surfaces_on_the_empty_queue_fast_path() {
  local dir state out
  dir=$(make_case empty-queue-fast-path)
  state="$dir/state"
  out="$dir/drain.out"
  # No wake is queued at all (the empty-queue exit), but the decision is still
  # open on disk - session-start relies on exactly this path.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task8.status"
  printf 'working: continuing\n' >> "$state/task8.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "empty-queue drain failed"

  grep -F 'task8' "$out" | grep -F '[key=api-shape]' >/dev/null \
    || fail "the empty-queue fast path did not surface a still-open decision"
  pass "a buried open decision surfaces even when the wake queue itself is empty"
}

test_status_symlink_is_not_followed() {
  local dir state out
  dir=$(make_case status-symlink)
  state="$dir/state"
  out="$dir/drain.out"
  mkdir -p "$dir/outside"
  printf 'needs-decision [key=local]: keep this visible\n' > "$state/local.status"
  printf 'needs-decision [key=foreign]: do not expose this\n' > "$dir/outside/foreign.status"
  ln -s ../outside/foreign.status "$state/linked.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a symlinked status file"

  grep -F 'local [key=local] needs-decision: keep this visible' "$out" >/dev/null \
    || fail "the valid local decision did not surface alongside a rejected status symlink"
  if grep -F 'do not expose this' "$out" >/dev/null; then
    fail "the fleet scan followed a status symlink outside the state directory"
  fi
  pass "the fleet-wide decision scan does not follow status symlinks"
}

# The per-item cut now comes from bin/fm-line-cap-lib.sh, shared with the
# session-start digest's status tails so one truncation marker means the same
# thing wherever an agent meets it. This pins the drain's own end of that
# contract: the lede survives, the marker appears, and the item still fits the
# section's per-item budget including the newline it is charged for.
test_over_long_decision_note_is_capped_with_a_marker() {
  local dir state out line longest
  dir=$(make_case long-note)
  state="$dir/state"
  out="$dir/drain.out"
  {
    printf 'needs-decision [key=api-shape]: pick REST or RPC'
    awk 'BEGIN { while (i++ < 200) printf " and-then-some" }'
    printf '\n'
  } > "$state/task-long.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on an over-long decision note"

  line=$(grep -F 'task-long' "$out")
  case "$line" in
    'task-long [key=api-shape] needs-decision: pick REST or RPC'*' [truncated]') : ;;
    *) fail "an over-long decision note was not capped with its lede intact: $line" ;;
  esac
  longest=${#line}
  [ "$longest" -le 219 ] || fail "a capped decision item ran $longest characters past its per-item budget"

  printf 'needs-decision [key=short]: brief enough to keep whole\n' > "$state/task-short.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a short decision note"
  grep -F 'task-short [key=short] needs-decision: brief enough to keep whole' "$out" >/dev/null \
    || fail "a decision note already under the cap was altered"
  if grep -F 'brief enough to keep whole [truncated]' "$out" >/dev/null; then
    fail "a decision note already under the cap was marked truncated"
  fi

  pass "an over-long open decision is cut to its per-item budget with the shared truncation marker"
}

test_folded_reserved_needs_decision_warns_once_per_line() {
  local dir state out warns
  dir=$(make_case folded-reserved)
  state="$dir/state"
  out="$dir/drain.out"
  {
    printf 'needs-decision [key=pending-reply-abc123]: which color should the button be\n'
    printf 'needs-decision: [key=pending-reply-colon] which shape\n'
    printf 'needs-decision [key=api-shape]: pick REST or RPC\n'
    printf 'needs-decision [key=pending-reply-owner1]: pending-reply-missed: task=t pending-reply-id=owner1 request=ok\n'
    printf 'blocked [key=pending-reply-foreign]: shipping is blocked on infra\n'
  } > "$state/task-fold.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a folded reserved needs-decision"

  warns=$(grep -cF 'folded reserved-prefix needs-decision' "$out" || true)
  [ "$warns" = 2 ] || fail "expected one warning per folded needs-decision, got $warns: $(cat "$out")"
  grep -F 'warning: task=task-fold key=pending-reply-abc123 folded reserved-prefix needs-decision' "$out" >/dev/null \
    || fail "the documented-position reserved needs-decision was not warned: $(cat "$out")"
  grep -F 'warning: task=task-fold key=pending-reply-colon folded reserved-prefix needs-decision' "$out" >/dev/null \
    || fail "the colon-first reserved needs-decision was not warned: $(cat "$out")"
  if grep -F 'which color should the button be' "$out" >/dev/null; then
    fail "a folded reserved needs-decision was listed: $(cat "$out")"
  fi
  if grep -F 'which shape' "$out" >/dev/null; then
    fail "a colon-first folded reserved needs-decision was listed: $(cat "$out")"
  fi
  grep -F 'task-fold [key=api-shape] needs-decision: pick REST or RPC' "$out" >/dev/null \
    || fail "an ordinary decision was dropped alongside the warning: $(cat "$out")"
  grep -F 'pending-reply-id=owner1' "$out" >/dev/null \
    || fail "the owner's own reserved-prefix decision was not listed: $(cat "$out")"
  if grep -F 'folded reserved-prefix' "$out" | grep -F 'pending-reply-owner1' >/dev/null; then
    fail "the owner's own reserved-prefix line was warned: $(cat "$out")"
  fi
  if grep -F 'folded reserved-prefix' "$out" | grep -F 'pending-reply-foreign' >/dev/null; then
    fail "a reserved-prefix blocked line was warned: $(cat "$out")"
  fi
  if grep -F 'folded reserved-prefix' "$out" | grep -F 'api-shape' >/dev/null; then
    fail "an ordinary decision was warned: $(cat "$out")"
  fi

  printf 'needs-decision [key=button-color]: which color should the button be\n' >> "$state/task-fold.status"
  printf 'note: unrelated delivery\n' > "$state/other.status"
  append_wake "$state" signal other.status 'note: unrelated delivery' || fail "could not queue the unrelated wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after the decision was reissued"
  if grep -F 'folded reserved-prefix needs-decision' "$out" >/dev/null; then
    fail "the unrelated drain replayed a presented warning: $(cat "$out")"
  fi
  grep -F 'task-fold [key=button-color] needs-decision: which color should the button be' "$out" >/dev/null \
    || fail "the reissued decision did not surface with its ordinary key: $(cat "$out")"
  pass "a folded reserved-prefix needs-decision is warned once per line and not listed"
}

test_drain_warning_follows_the_reserved_prefix_list() {
  local dir state out
  dir=$(make_case custom-prefix)
  state="$dir/state"
  out="$dir/drain.out"
  {
    printf 'needs-decision [key=secret-abc]: keep this quiet\n'
    printf 'needs-decision [key=pending-reply-abc123]: which color should the button be\n'
    printf 'needs-decision [key=secret-owned]: secret-held: owner vocabulary\n'
  } > "$state/task-custom.status"

  FM_CLASSIFY_RESERVED_KEY_PREFIXES='secret-' FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "drain failed under a custom reserved-prefix list"

  grep -F 'warning: task=task-custom key=secret-abc folded reserved-prefix needs-decision' "$out" >/dev/null \
    || fail "the configured reserved prefix was not warned: $(cat "$out")"
  if grep -F 'keep this quiet' "$out" >/dev/null; then
    fail "a needs-decision in the configured reserved namespace was listed: $(cat "$out")"
  fi
  grep -F 'task-custom [key=pending-reply-abc123] needs-decision: which color should the button be' "$out" >/dev/null \
    || fail "a prefix outside the configured list was folded: $(cat "$out")"
  if grep -F 'folded reserved-prefix' "$out" | grep -F 'pending-reply-abc123' >/dev/null; then
    fail "a prefix outside the configured list was warned: $(cat "$out")"
  fi
  grep -F 'secret-held: owner vocabulary' "$out" >/dev/null \
    || fail "the configured namespace owner's own line was not listed: $(cat "$out")"
  if grep -F 'folded reserved-prefix' "$out" | grep -F 'secret-owned' >/dev/null; then
    fail "the configured namespace owner's own line was warned: $(cat "$out")"
  fi
  pass "the drain warning uses the reserved-prefix list instead of a copied prefix"
}

test_branch_leaves_folded_decisions_unread_for_main() {
  local dir state branch_out main_out grant
  dir=$(make_case branch-warning)
  state="$dir/state"
  branch_out="$dir/branch.out"
  main_out="$dir/main.out"
  grant="$ROOT/bin/fm-wake-grant.sh"

  printf 'note: already read\n' > "$state/direct.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > /dev/null || fail "main could not present the earlier note"
  printf 'working: continuing branch work\n' >> "$state/direct.status"
  printf 'working: unrelated branch work\n' > "$state/routine.status"
  append_wake "$state" signal direct.status 'signal: direct' || fail "could not queue the direct branch row"
  append_wake "$state" signal routine.status 'signal: routine' || fail "could not queue the routine branch row"
  FM_STATE_OVERRIDE="$state" "$grant" activate "$$" reserved-warning || fail "could not activate branch owner"
  FM_STATE_OVERRIDE="$state" "$grant" publish reserved-warning 1 2 || fail "could not publish branch grant"

  printf 'needs-decision [key=pending-reply-direct]: choose a color\n' >> "$state/direct.status"
  printf 'needs-decision: [key=pending-reply-note] choose a shape\nnote: decision context\n' > "$state/fleet.status"
  append_wake "$state" signal direct.status 'signal: direct decision' || fail "could not queue the main direct row"
  append_wake "$state" signal fleet.status 'signal: fleet decision' || fail "could not queue the main fleet row"

  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" > "$branch_out" 2> "$dir/branch.err" \
    || fail "branch drain failed: $(cat "$dir/branch.err")"
  grep -Fq 'routine.status: working: unrelated branch work' "$branch_out" || fail "the routine branch annotation was suppressed"
  if grep -Eq 'folded reserved-prefix|choose a color|choose a shape|decision context' "$branch_out"; then
    fail "the branch presented status reserved for main: $(cat "$branch_out")"
  fi

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$main_out" 2> "$dir/main.err" \
    || fail "main drain failed: $(cat "$dir/main.err")"
  grep -Fq 'warning: task=direct key=pending-reply-direct folded reserved-prefix needs-decision' "$main_out" \
    || fail "branch direct receipt consumed the main warning: $(cat "$main_out")"
  grep -Fq 'warning: task=fleet key=pending-reply-note folded reserved-prefix needs-decision' "$main_out" \
    || fail "branch fleet receipt consumed the main warning: $(cat "$main_out")"
  grep -Fq 'direct.status: needs-decision [key=pending-reply-direct]: choose a color' "$main_out" \
    || fail "branch direct receipt consumed the main annotation: $(cat "$main_out")"
  if grep -Fq 'already read' "$main_out"; then
    fail "branch moved the presentation cursor backward: $(cat "$main_out")"
  fi
  pass "the branch preserves folded decisions and their annotations for main"
}

test_status_append_refuses_reserved_key_before_write() {
  local dir status err rc APPEND
  dir=$(make_case status-append)
  status="$dir/state/task.status"
  err="$dir/append.err"
  APPEND="$ROOT/bin/fm-status-append.sh"

  "$APPEND" --help >/dev/null || fail "the documented --help option did not succeed"
  if "$APPEND" -h >/dev/null 2>&1; then
    fail "the undocumented -h option still succeeds"
  fi
  if "$APPEND" "$status" $'working: reviewing\nneeds-decision [key=pending-reply-color]: choose blue' 2>"$err"; then
    fail "the status append helper accepted more than one physical line"
  fi
  assert_contains "$(cat "$err")" 'requires one line' "the multiline refusal should name the line contract"
  [ ! -e "$status" ] || fail "a refused multiline append still created the status file"

  "$APPEND" "$status" 'needs-decision [key=pending-reply-abc123]: which color should the button be' \
    >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a reserved-prefix key should be refused"
  assert_contains "$(cat "$err")" "reserved prefix 'pending-reply-'" "the refusal should name the reserved prefix"
  assert_contains "$(cat "$err")" "pick another key" "the refusal should tell the worker to pick another key"
  assert_contains "$(cat "$err")" "bin/fm-classify-lib.sh" "the refusal should point at the prefix owner"
  [ ! -e "$status" ] || fail "a refused append still created the status file: $(cat "$status")"

  printf 'working: already here\n' > "$status"
  "$APPEND" "$status" 'needs-decision: [key=pending-reply-colon] which shape' >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a colon-first reserved key should be refused"
  [ "$(cat "$status")" = "working: already here" ] || fail "a refused append changed the status file: $(cat "$status")"

  "$APPEND" "$status" 'working [key=pending-reply-phase]: still reserved' >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a reserved key on a non-decision verb should still be refused"
  [ "$(cat "$status")" = "working: already here" ] || fail "a refused working line changed the status file: $(cat "$status")"

  "$APPEND" "$status" 'needs-decision [key=pending-reply-abc123]: pending-reply-missed: copied vocabulary' \
    >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a worker line that copies the owner's vocabulary should still be refused"
  [ "$(cat "$status")" = "working: already here" ] || fail "a vocabulary copy was written: $(cat "$status")"

  "$APPEND" "$status" 'needs-decision [key=api-shape]: pick REST or RPC' \
    || fail "an ordinary key should append"
  grep -F 'needs-decision [key=api-shape]: pick REST or RPC' "$status" >/dev/null \
    || fail "the ordinary decision was not appended: $(cat "$status")"

  "$APPEND" "$status" 'needs-decision [key=pending-reply]: hyphen is part of the prefix' \
    || fail "a key that does not start with the reserved prefix should append"
  grep -F 'needs-decision [key=pending-reply]: hyphen is part of the prefix' "$status" >/dev/null \
    || fail "a non-matching key was not appended: $(cat "$status")"

  FM_CLASSIFY_RESERVED_KEY_PREFIXES='secret-' \
    "$APPEND" "$status" 'needs-decision [key=secret-abc]: keep this quiet' >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a key in the configured reserved list should be refused"
  assert_contains "$(cat "$err")" "reserved prefix 'secret-'" "the refusal should name the configured prefix"
  if grep -F 'secret-abc' "$status" >/dev/null; then
    fail "a refused configured prefix was written: $(cat "$status")"
  fi
  FM_CLASSIFY_RESERVED_KEY_PREFIXES='secret-' \
    "$APPEND" "$status" 'needs-decision [key=pending-reply-abc123]: which color should the button be' \
    || fail "a prefix outside the configured list should append"
  grep -F 'needs-decision [key=pending-reply-abc123]: which color should the button be' "$status" >/dev/null \
    || fail "a prefix outside the configured list was not appended: $(cat "$status")"
  pass "the status append helper refuses a reserved prefix before it writes"
}

test_folded_reserved_needs_decision_warns_once_per_line
test_branch_leaves_folded_decisions_unread_for_main
test_drain_warning_follows_the_reserved_prefix_list
test_status_append_refuses_reserved_key_before_write
test_buried_decision_still_surfaces
test_over_long_decision_note_is_capped_with_a_marker
test_explicit_resolution_closes_it
test_later_unrelated_terminal_line_does_not_close_it
test_reserved_key_namespace_is_owned_by_its_library
test_no_open_decisions_prints_nothing
test_open_decision_surfaces_even_with_an_unrelated_queued_wake
test_buried_decision_surfaces_on_the_empty_queue_fast_path
test_status_symlink_is_not_followed
