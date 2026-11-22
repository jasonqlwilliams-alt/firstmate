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

test_folded_reserved_needs_decision_warns_without_consuming_annotations() {
  local dir state out warns
  dir=$(make_case folded-reserved)
  state="$dir/state"
  out="$dir/drain.out"
  {
    printf 'blocked [key=pending-reply-credentials]: credentials unavailable\n'
    printf 'needs-decision [key=pending-reply-abc123]: which color should the button be\n'
    printf 'needs-decision: [key=pending-reply-colon] which shape\n'
    printf 'needs-decision [key=api-shape]: pick REST or RPC\n'
    printf 'needs-decision [key=pending-reply-owner1]: pending-reply-missed: task=t pending-reply-id=owner1 request=ok\n'
    printf 'blocked [key=pending-reply-foreign]: shipping is blocked on infra\n'
  } > "$state/task-fold.status"

  printf 'working: unrelated task\n' > "$state/other.status"
  append_wake "$state" signal other.status 'signal: unrelated task' || fail "could not queue the unrelated wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a folded reserved needs-decision"

  warns=$(grep -cF 'folded reserved-prefix needs-decision' "$out" || true)
  [ "$warns" = 2 ] || fail "expected one warning per folded needs-decision, got $warns: $(cat "$out")"
  grep -Fxq 'warning: task=task-fold key=pending-reply-abc123 folded reserved-prefix needs-decision: which color should the button be' "$out" \
    || fail "the unrelated drain lost the documented-position question: $(cat "$out")"
  grep -Fxq 'warning: task=task-fold key=pending-reply-colon folded reserved-prefix needs-decision: which shape' "$out" \
    || fail "the unrelated drain lost the colon-first question: $(cat "$out")"
  if grep -Eq '^task-fold \[key=pending-reply-(abc123|colon)\] needs-decision:' "$out"; then
    fail "a folded reserved needs-decision appeared in OPEN DECISIONS: $(cat "$out")"
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
  if grep -Eq 'credentials unavailable|shipping is blocked on infra' "$out"; then
    fail "the unrelated drain displayed a blocker without its task signal: $(cat "$out")"
  fi

  append_wake "$state" signal task-fold.status 'signal: task-fold' || fail "could not queue the delayed wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on the delayed task signal"
  grep -Fq $'\tsignal\ttask-fold.status\t' "$out" || fail "the delayed task wake was not presented"
  grep -Fq 'task-fold.status: blocked [key=pending-reply-credentials]: credentials unavailable' "$out" \
    || fail "the warning consumed the earlier blocker's delayed annotation: $(cat "$out")"
  grep -Fq 'task-fold.status: blocked [key=pending-reply-foreign]: shipping is blocked on infra' "$out" \
    || fail "the warning consumed the later blocker's delayed annotation: $(cat "$out")"

  printf 'needs-decision [key=button-color]: which color should the button be\n' >> "$state/task-fold.status"
  printf 'note: unrelated delivery\n' > "$state/other.status"
  append_wake "$state" signal other.status 'note: unrelated delivery' || fail "could not queue the unrelated wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after the decision was reissued"
  if grep -F 'folded reserved-prefix needs-decision' "$out" >/dev/null; then
    fail "the unrelated drain replayed a presented warning: $(cat "$out")"
  fi
  grep -F 'task-fold [key=button-color] needs-decision: which color should the button be' "$out" >/dev/null \
    || fail "the reissued decision did not surface with its ordinary key: $(cat "$out")"
  pass "warnings preserve delayed blocker annotations and stop after the task signal"
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

  grep -Fxq 'warning: task=task-custom key=secret-abc folded reserved-prefix needs-decision: keep this quiet' "$out" \
    || fail "the configured reserved prefix was not warned with its question: $(cat "$out")"
  if grep -Fq 'task-custom [key=secret-abc] needs-decision:' "$out"; then
    fail "a needs-decision in the configured reserved namespace appeared in OPEN DECISIONS: $(cat "$out")"
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

test_unrelated_branch_drain_leaves_warning_unread_for_main() {
  local dir state branch_out main_out grant
  dir=$(make_case branch-warning)
  state="$dir/state"
  branch_out="$dir/branch.out"
  main_out="$dir/main.out"
  grant="$ROOT/bin/fm-wake-grant.sh"

  printf 'note: already read\n' > "$state/direct.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > /dev/null || fail "main could not present the earlier note"
  printf 'working: continuing branch work\n\nnote: résumé ready for branch\n' >> "$state/direct.status"
  append_wake "$state" signal direct.status 'signal: direct' || fail "could not queue the direct branch row"
  FM_STATE_OVERRIDE="$state" "$grant" activate "$$" reserved-warning || fail "could not activate branch owner"
  FM_STATE_OVERRIDE="$state" "$grant" publish reserved-warning 1 || fail "could not publish branch grant"

  printf 'needs-decision [key=pending-reply-fleet]: choose a color\n' > "$state/fleet.status"
  append_wake "$state" signal fleet.status 'signal: fleet decision' || fail "could not queue the main fleet row"

  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" > "$branch_out" 2> "$dir/branch.err" \
    || fail "branch drain failed: $(cat "$dir/branch.err")"
  grep -Fq 'direct.status: working: continuing branch work' "$branch_out" || fail "the granted branch annotation was suppressed"
  grep -Fxq 'direct note: résumé ready for branch' "$branch_out" || fail "the granted branch note was suppressed"
  grep -Fxq 'warning: task=fleet key=pending-reply-fleet folded reserved-prefix needs-decision: choose a color' "$branch_out" \
    || fail "the branch deferred the warning: $(cat "$branch_out")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$main_out" 2> "$dir/main.err" \
    || fail "main drain failed: $(cat "$dir/main.err")"
  grep -Fxq 'warning: task=fleet key=pending-reply-fleet folded reserved-prefix needs-decision: choose a color' "$main_out" \
    || fail "the unrelated branch drain consumed the main warning: $(cat "$main_out")"
  grep -Fq 'fleet.status: needs-decision [key=pending-reply-fleet]: choose a color' "$main_out" \
    || fail "the unrelated branch drain consumed the main annotation: $(cat "$main_out")"
  if grep -Eq 'already read|continuing branch work|ready for branch' "$main_out"; then
    fail "main replayed already presented branch status: $(cat "$main_out")"
  fi
  pass "an unrelated branch drain leaves the warning and annotation available to main"
}

test_note_presents_the_captured_span() {
  local dir state out
  dir=$(make_case note-receipt)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'note: report attached\ndone: delivered\n' > "$state/report.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "empty-queue note drain failed"
  grep -Fxq 'report note: report attached' "$out" || fail "the fleet note was omitted"
  grep -Fxq 'report done: delivered' "$out" || fail "the terminal backstop was omitted"

  append_wake "$state" signal report.status 'signal: report' || fail "could not queue the delayed report wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "delayed report drain failed"
  grep -Fq $'\tsignal\treport.status\t' "$out" || fail "the delayed report wake was not presented"
  if grep -Eq 'report attached|done: delivered' "$out"; then
    fail "the delayed wake replayed status already presented in the note's span: $(cat "$out")"
  fi
  pass "an informational note acknowledges the captured span"
}

test_warning_and_note_share_a_successful_span_read() {
  local dir state status out reader offset
  dir=$(make_case warning-note-shared-read)
  state="$dir/state"
  status="$state/shared.status"
  out="$dir/drain.out"
  reader="$dir/read-span"
  printf 'note: already presented\n' > "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > /dev/null || fail "could not prime the status receipt"
  offset=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  printf 'needs-decision [key=pending-reply-color]: choose a color\nnote: decision context\n' >> "$status"

  cat > "$reader" <<SH
#!/usr/bin/env bash
if [ "\$1" = "$status" ] && [ "\$2" = "$offset" ]; then
  if [ -e "$dir/read-once" ]; then exit 1; fi
  touch "$dir/read-once"
fi
exec dd if="\$1" bs=1 skip="\$2" count="\$3"
SH
  chmod +x "$reader"
  FM_STATE_OVERRIDE="$state" FM_STATUS_SPAN_READER="$reader" "$DRAIN" > "$out" \
    || fail "could not drain the shared span"
  [ -f "$dir/read-once" ] || fail "the fault fixture did not serve the first span read"
  grep -Fxq 'shared note: decision context' "$out" || fail "the note was omitted"
  grep -Fxq 'warning: task=shared key=pending-reply-color folded reserved-prefix needs-decision: choose a color' "$out" \
    || fail "the drain acknowledged a note without warning about the question from the same span"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "could not drain after the shared presentation"
  [ ! -s "$out" ] || fail "the accepted note receipt replayed its span: $(cat "$out")"
  pass "a successful status span read presents both the note and its folded question"
}

test_failed_first_receipt_rename_still_prints_decisions() {
  local dir state fakebin real_mv out
  dir=$(make_case first-rename-failure)
  state="$dir/state"
  out="$dir/drain.out"
  fakebin=$(fm_fakebin "$dir/fake")
  real_mv=$(command -v mv)
  cat > "$fakebin/mv" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do last=\$arg; done
case "\${last:-}" in
  "$state/.status-presentation-cursor") touch "$dir/rejected"; exit 1 ;;
esac
exec "$real_mv" "\$@"
SH
  chmod +x "$fakebin/mv"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/decision.status"
  printf 'needs-decision [key=pending-reply-color]: choose a color\n' > "$state/warning.status"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "first receipt rename failure changed the drain exit"
  [ -f "$dir/rejected" ] || fail "the first receipt rename was never attempted"
  grep -Fq 'OPEN DECISIONS' "$out" || fail "receipt rename failure suppressed the decisions section"
  grep -Fxq 'decision [key=api-shape] needs-decision: pick REST or RPC' "$out" \
    || fail "receipt rename failure suppressed the decision"
  grep -Fxq 'warning: task=warning key=pending-reply-color folded reserved-prefix needs-decision: choose a color' "$out" \
    || fail "receipt rename failure suppressed the warning"
  pass "the first failed receipt rename leaves status presentation intact"
}

test_first_drain_output_failure_leaves_warning_for_main() {
  local actor dir state grant fakebin real_cat
  real_cat=$(command -v cat)
  grant="$ROOT/bin/fm-wake-grant.sh"
  for actor in main branch; do
    dir=$(make_case "failed-first-$actor")
    state="$dir/state"
    fakebin=$(fm_fakebin "$dir/fake")
    cat > "$fakebin/cat" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  "$state"/.status-presentation.prepared.*) touch "$dir/rejected"; exit 1 ;;
esac
exec "$real_cat" "\$@"
SH
    chmod +x "$fakebin/cat"
    printf 'note: outside the legacy unread span\nneeds-decision [key=pending-reply-retry]: choose a color\n' > "$state/retry.status"
    if [ "$actor" = branch ]; then
      printf 'working: unrelated granted work\n' > "$state/routine.status"
      append_wake "$state" signal routine.status 'signal: routine' || fail "could not queue branch row"
      FM_STATE_OVERRIDE="$state" "$grant" activate "$$" retry-warning || fail "could not activate branch owner"
      FM_STATE_OVERRIDE="$state" "$grant" publish retry-warning 1 || fail "could not publish branch grant"
    fi

    PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR="$actor" "$DRAIN" \
      > "$dir/failed.out" 2> "$dir/failed.err" || fail "first $actor drain changed its compatibility exit"
    [ -f "$dir/rejected" ] || fail "first $actor drain did not reach the failed output consumer"
    FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=main "$DRAIN" > "$dir/retry.out" 2> "$dir/retry.err" \
      || fail "main retry after $actor failed: $(cat "$dir/retry.err")"
    grep -Fxq 'warning: task=retry key=pending-reply-retry folded reserved-prefix needs-decision: choose a color' "$dir/retry.out" \
      || fail "the first $actor drain lost the warning when delivery failed: $(cat "$dir/retry.out")"
    if grep -Fq 'outside the legacy unread span' "$dir/retry.out"; then
      fail "warning recovery broadened the existing unread note span: $(cat "$dir/retry.out")"
    fi
  done
  pass "a first drain with failed output leaves the folded warning unread for main"
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

test_folded_reserved_needs_decision_warns_without_consuming_annotations
test_unrelated_branch_drain_leaves_warning_unread_for_main
test_note_presents_the_captured_span
test_warning_and_note_share_a_successful_span_read
test_failed_first_receipt_rename_still_prints_decisions
test_first_drain_output_failure_leaves_warning_for_main
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
