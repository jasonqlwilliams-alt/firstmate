#!/usr/bin/env bash
# The scheduled prune uses Treehouse's stale-worktree rules inside a fixture pool.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v treehouse >/dev/null 2>&1 || { echo 'skip: treehouse not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
command -v setsid >/dev/null 2>&1 || { echo 'skip: setsid not found'; exit 0; }
fm_treehouse_scratch_active || fail "suite is not running under a scratch Treehouse root"

TMP_ROOT=$(fm_test_tmproot fm-treehouse-prune)
PRUNE="$ROOT/bin/fm-treehouse-prune.sh"
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
ORIGIN="$TMP_ROOT/origin.git"
PROJ="$HOME_DIR/projects/proj#fixture"
CHECK_ID=treehouse-prune+schedule
CHECK="$STATE/$CHECK_ID.check.sh"
TRUST="$STATE/$CHECK_ID.check-trust"
RECORD="$STATE/.treehouse-prune"
LOG="$STATE/.treehouse-prune.log"
LIST="$HOME_DIR/config/treehouse-prune-protected"
export FM_HOME="$HOME_DIR" HOME="$TMP_ROOT/user" XDG_CONFIG_HOME="$TMP_ROOT/user/.config"
unset FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
mkdir -p "$STATE" "$HOME_DIR/config" "$HOME_DIR/projects" "$HOME"

fm_git_init_commit "$TMP_ROOT/seed"
git clone -q --bare "$TMP_ROOT/seed" "$ORIGIN" || fail "could not create fixture origin"
git clone -q "$ORIGIN" "$PROJ" || fail "could not create fixture repository"

pool() {
  (cd "$PROJ" && treehouse "$@")
}

lease_slot() {
  local slot
  slot=$(pool get --lease --no-fetch --lease-holder fixture) || return 1
  case "$slot" in "$TREEHOUSE_ROOT"/*) printf '%s\n' "$slot" ;; *) return 1 ;; esac
}

read_record() {
  [ ! -f "$RECORD" ] || sed -n "s/^$1=//p" "$RECORD"
}

run_due_check() {
  local expected=$1 pid i
  printf 'last_start=0\n' > "$RECORD"
  setsid bash "$CHECK" > "$TMP_ROOT/check.out" &
  pid=$!
  wait "$pid" || fail "scheduled check failed: $(cat "$TMP_ROOT/check.out")"
  kill -TERM -- "-$pid" 2>/dev/null || true
  for i in $(seq 1 100); do
    case "$(read_record last_result)" in ok|failed) break ;; esac
    sleep 0.1
  done
  assert_equals "$expected" "$(read_record last_result)" "scheduled sweep result (log: $(cat "$LOG" 2>/dev/null))"
  for i in $(seq 1 100); do
    if [ ! -e "$STATE/.treehouse-prune.lock" ] && [ ! -L "$STATE/.treehouse-prune.lock" ]; then
      break
    fi
    sleep 0.01
  done
}

test_check_ownership() {
  local foreign="$STATE/treehouse-prune.check.sh"
  printf 'foreign task poll\n' > "$foreign"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$CHECK"
  chmod 700 "$CHECK"
  "$ROOT/bin/fm-check-register.sh" "$CHECK_ID" >/dev/null || fail "could not register fixture check"
  "$PRUNE" arm >/dev/null 2>&1 && fail "arm replaced a foreign check"
  "$PRUNE" disarm >/dev/null 2>&1 && fail "disarm retired a foreign check"
  assert_equals $'#!/usr/bin/env bash\nexit 0' "$(cat "$CHECK")" "foreign check changed"
  assert_present "$TRUST" "foreign check lost its trust binding"
  "$ROOT/bin/fm-check-unregister.sh" "$CHECK_ID" >/dev/null || fail "could not retire fixture check"
  "$PRUNE" arm >/dev/null || fail "arm failed"
  "$PRUNE" arm >/dev/null || fail "repeated arm failed"
  assert_present "$TRUST" "arm did not register the check"
  assert_equals 'foreign task poll' "$(cat "$foreign")" "arm replaced a task poll"
  pass "registration rejects a foreign check and leaves task polls intact"
}

test_protected_slots_and_stale_prune() {
  local available leased protected dirty unmerged out unrelated name
  available=$(lease_slot) && leased=$(lease_slot) && protected=$(lease_slot) &&
    dirty=$(lease_slot) && unmerged=$(lease_slot) || fail "could not allocate fixture slots"
  pool return --force "$available" && pool return --force "$protected" &&
    pool return --force "$dirty" && pool return --force "$unmerged" || fail "could not return fixture slots"
  printf 'dirty\n' > "$dirty/local-file"
  git -C "$unmerged" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m unmerged ||
    fail "could not create unmerged fixture"
  git clone -q "$ORIGIN" "$TMP_ROOT/unrelated" || fail "could not create unrelated fixture pool"
  unrelated=$(cd "$TMP_ROOT/unrelated" && treehouse get --lease --no-fetch) ||
    fail "could not allocate outside the home's pools"
  (cd "$TMP_ROOT/unrelated" && treehouse return --force "$unrelated") ||
    fail "could not return unrelated fixture"
  printf '  # full-line comment\n\n%s\n' "$protected" > "$LIST"

  : > "$LOG"
  chmod 644 "$LOG"
  (umask 022; run_due_check failed) || fail "scheduled protection check did not complete"
  assert_present "$available" "preflight failure did not stop pruning"
  assert_contains "$(cat "$LOG")" "Protected slot needs a Treehouse lease: $protected" "literal protected path"
  [ -n "$(find "$LOG" -perm 0600 -print)" ] || fail "sweep log is not private"
  out=$(bash "$CHECK")
  assert_contains "$out" "Treehouse pool prune failed" "watcher sees a failed sweep"
  assert_equals '' "$(bash "$CHECK")" "watcher reports failure once"
  assert_present "$available" "sweep ran again before the daily interval"

  name=$(pool status --json | jq -r --arg path "$protected" '.[] | select(.path == $path) | .name')
  [ -n "$name" ] || fail "could not identify the protected fixture slot"
  assert_equals "$protected" "$(pool lease "$name")" "could not lease the protected fixture slot"
  printf '%s\n%s\n' "$protected" "${protected%/*}" > "$LIST"
  run_due_check ok
  assert_absent "$available" "an idle, clean, merged slot should be pruned"
  assert_present "$leased" "the sweep removed a leased slot"
  assert_present "$protected" "the sweep removed a listed leased slot"
  assert_present "$dirty/local-file" "the sweep removed dirty work"
  assert_present "$unmerged" "the sweep removed an unmerged commit"
  assert_present "$unrelated" "the sweep pruned outside the home's pools"
  rm -f -- "$LIST"
  pass "listed slots require a lease before pruning and Treehouse keeps protected work"
}

test_in_use_slot_is_kept() {
  local slot pid i
  slot=$(lease_slot) || fail "could not allocate active fixture"
  pool return --force "$slot" || fail "could not return active fixture"
  (
    cd "$slot" || exit 1
    printf 'ready\n' > "$TMP_ROOT/process-ready"
    exec sleep 60
  ) &
  pid=$!
  trap 'kill "$pid" 2>/dev/null || true; fm_test_cleanup' EXIT
  for i in $(seq 1 100); do
    [ ! -f "$TMP_ROOT/process-ready" ] || break
    sleep 0.01
  done
  assert_present "$TMP_ROOT/process-ready" "no process entered the fixture slot"
  kill -0 "$pid" || fail "fixture process stopped before pruning"
  run_due_check ok
  assert_present "$slot" "the sweep removed a slot with a running process"
  kill "$pid"
  wait "$pid" 2>/dev/null || true
  trap fm_test_cleanup EXIT
  run_due_check ok
  assert_absent "$slot" "the slot was still retained after its process exited"
  pass "an otherwise prunable slot survives while a process uses it"
}

test_task_records_fail_closed() {
  local slot field meta="$STATE/held.meta"
  slot=$(lease_slot) || fail "could not allocate task fixture"
  pool return --force "$slot" || fail "could not return task fixture"
  for field in worktree home; do
    printf '%s=%s\n' "$field" "$slot" > "$meta"
    run_due_check failed
    assert_present "$slot" "the sweep removed a recorded $field"
    assert_contains "$(cat "$LOG")" "lacks a durable lease" "missing lease for $field"
  done
  rm -f -- "$meta"
  ln -s "$TMP_ROOT/missing-record" "$meta" || fail "could not create unreadable task record"
  run_due_check failed
  assert_contains "$(cat "$LOG")" "cannot inspect task record" "unreadable task record"
  assert_present "$slot" "the sweep pruned with an unreadable record"
  rm -f -- "$meta"
  run_due_check ok
  assert_absent "$slot" "retiring the task record should allow pruning"
  pass "both task record fields and unreadable records stop a sweep"
}

test_prune_failures_are_reported() {
  local real_treehouse fake_bin="$TMP_ROOT/fake-bin"
  real_treehouse=$(command -v treehouse)
  mkdir -p "$fake_bin"
  cat > "$fake_bin/treehouse" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = prune ]; then
  if [ "$PRUNE_FAILURE" = command ]; then
    exit 124
  fi
  printf '🌳 No stale worktrees pruned.\n🌳 Skipped 1 unsafe idle worktree:\n  remove failed:\n'
  exit 0
fi
exec "$REAL_TREEHOUSE" "$@"
STUB
  chmod +x "$fake_bin/treehouse"
  PATH="$fake_bin:$PATH" REAL_TREEHOUSE="$real_treehouse" PRUNE_FAILURE=command run_due_check failed
  PATH="$fake_bin:$PATH" REAL_TREEHOUSE="$real_treehouse" PRUNE_FAILURE=removal run_due_check failed
  pass "command and per-slot removal failures reach the sweep record"
}

test_custom_checkout_location() {
  local repo="$HOME_DIR/projects/custom" slot field meta="$STATE/held.meta"
  git clone -q "$ORIGIN" "$repo" || fail "could not create custom-location repository"
  slot=$(cd "$repo" && treehouse get --lease --no-fetch --worktree-path "$TMP_ROOT/checkouts/{repo}-{slot}") ||
    fail "could not allocate a custom-location fixture"
  case "$slot" in "$TMP_ROOT/checkouts/"*) ;; *) fail "fixture did not use the custom checkout location" ;; esac

  printf '%s\n' "${slot%/*}" > "$LIST"
  run_due_check failed
  assert_contains "$(cat "$LOG")" "Protected slot needs a Treehouse lease: ${slot%/*}" "unmanaged parent is not a slot directory"
  printf '%s\n' "$slot" > "$LIST"
  run_due_check ok
  assert_present "$slot" "the exact listed checkout did not survive"
  rm -f -- "$LIST"
  (cd "$repo" && treehouse return --force "$slot") || fail "could not return the custom checkout"

  for field in worktree home; do
    printf '%s=%s\n' "$field" "$slot" > "$meta"
    run_due_check failed
    assert_contains "$(cat "$LOG")" "($field) but lacks a durable lease" "custom checkout recorded as $field"
    assert_present "$slot" "the sweep removed the custom checkout named by $field"
  done
  rm -f -- "$meta"
  run_due_check ok
  assert_absent "$slot" "retiring the task record should allow pruning the custom checkout"
  pass "protection and task records use the checkout path reported by Treehouse"
}

test_interrupted_sweep_is_reported() {
  local out
  printf '%s\n' "last_start=$(date +%s)" 'last_result=running' 'reported=0' > "$RECORD"
  out=$(bash "$CHECK") || fail "watcher check failed after an interrupted sweep"
  assert_contains "$out" "Treehouse pool prune failed" "watcher reports a sweep that exited without a result"
  assert_equals failed "$(read_record last_result)" "interrupted sweep is recorded as failed"
  assert_equals '' "$(bash "$CHECK")" "watcher reports the interruption once"
  pass "an interrupted sweep is reported after its worker releases the lock"
}

test_check_ownership
test_protected_slots_and_stale_prune
test_in_use_slot_is_kept
test_task_records_fail_closed
test_prune_failures_are_reported
test_custom_checkout_location
test_interrupted_sweep_is_reported
"$PRUNE" disarm >/dev/null || fail "disarm failed"
assert_absent "$CHECK" "disarm did not retire the check"
assert_absent "$TRUST" "disarm did not retire the trust binding"
assert_absent "$RECORD" "disarm did not remove the record"
assert_absent "$LOG" "disarm did not remove the log"
pass "disarm retires its registration and records"
