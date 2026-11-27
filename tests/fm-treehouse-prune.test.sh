#!/usr/bin/env bash
# tests/fm-treehouse-prune.test.sh - the scheduled Treehouse pool prune removes
# only available slots and keeps every slot that is in use, leased, protected,
# claimed, or named by a task record (bin/fm-treehouse-prune.sh).
#
# Real Treehouse, against this suite's own disposable TREEHOUSE_ROOT (entered by
# tests/lib.sh); no real pool is ever read or changed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v treehouse >/dev/null 2>&1 || { echo 'skip: treehouse not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
fm_treehouse_scratch_active || fail "suite is not running under a scratch Treehouse root"

TMP_ROOT=$(fm_test_tmproot fm-treehouse-prune)
PRUNE="$ROOT/bin/fm-treehouse-prune.sh"
HOME_DIR="$TMP_ROOT/home"
ORIGIN="$TMP_ROOT/origin.git"
PROJ="$HOME_DIR/projects/proj"
export HOME="$TMP_ROOT/user" XDG_CONFIG_HOME="$TMP_ROOT/user/.config"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects" "$HOME"

fm_git_init_commit "$TMP_ROOT/seed"
git clone -q --bare "$TMP_ROOT/seed" "$ORIGIN"
git clone -q "$ORIGIN" "$PROJ"

prune() {
  FM_HOME="$HOME_DIR" "$PRUNE" "$@"
}

lease_slot() {
  (cd "$PROJ" && treehouse get --lease --no-fetch --lease-holder fixture 2>/dev/null)
}

return_slot() {
  (cd "$PROJ" && treehouse return --force "$1" >/dev/null 2>&1) || fail "could not return fixture slot $1"
}

slot_status() {  # <path>
  (cd "$PROJ" && treehouse status --json) | jq -r --arg p "$1" '.[] | select(.path == $p) | .status'
}

# Six held slots, then return the ones that must read as available.
AVAIL=$(lease_slot) LEASED=$(lease_slot) PROTECTED=$(lease_slot)
CLAIMED=$(lease_slot) RECORDED=$(lease_slot) UNMERGED=$(lease_slot)
for s in "$AVAIL" "$LEASED" "$PROTECTED" "$CLAIMED" "$RECORDED" "$UNMERGED"; do
  [ -d "$s" ] || fail "fixture slot was not allocated: '$s'"
  case "$s" in "$TREEHOUSE_ROOT"/*) ;; *) fail "fixture slot $s is outside the scratch root" ;; esac
done
for s in "$AVAIL" "$PROTECTED" "$CLAIMED" "$RECORDED" "$UNMERGED"; do
  return_slot "$s"
done
printf 'task=other-task\nhome=%s\n' "$TMP_ROOT/elsewhere" > "${CLAIMED%/*}/.fm-slot-owner"
printf 'worktree=%s\n' "$RECORDED" > "$HOME_DIR/state/recorded-task.meta"
git -C "$UNMERGED" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m unmerged
printf '# protected for the captain\n\n%s\n' "${PROTECTED%/*}" > "$HOME_DIR/config/treehouse-prune-protected"
for s in "$AVAIL" "$PROTECTED" "$CLAIMED" "$RECORDED" "$UNMERGED"; do
  assert_equals available "$(slot_status "$s")" "fixture slot $s must read as available"
done
assert_equals leased "$(slot_status "$LEASED")" "fixture slot $LEASED must read as leased"

test_dry_run_removes_nothing() {
  local out
  out=$(prune run --dry-run) || fail "dry run failed: $out"
  assert_contains "$out" "would remove $AVAIL" "dry run must offer the available slot"
  assert_contains "$out" "summary: would remove 2, keep 4" "dry run summary"
  assert_present "$AVAIL" "dry run removed a slot"
  assert_absent "$HOME_DIR/state/.treehouse-prune" "dry run must not write the sweep record"
  pass "a dry run lists candidates and removes nothing"
}

test_sweep_removes_only_available_slots() {
  local out
  out=$(prune run) || fail "sweep failed: $out"
  assert_contains "$out" "removed $AVAIL" "available slot must be removed"
  assert_contains "$out" "kept $LEASED: treehouse reports it leased" "leased slot must be kept"
  assert_contains "$out" "kept $PROTECTED: protected" "protected slot must be kept"
  assert_contains "$out" "kept $CLAIMED: carries a Firstmate slot-owner claim" "claimed slot must be kept"
  assert_contains "$out" "kept $RECORDED: named by task record recorded-task" "recorded slot must be kept"
  assert_contains "$out" "kept $UNMERGED: treehouse declined" "unmerged slot must be kept"
  assert_contains "$out" "summary: removed 1, kept 5" "sweep summary"
  assert_absent "$AVAIL" "available slot still on disk"
  for s in "$LEASED" "$PROTECTED" "$CLAIMED" "$RECORDED" "$UNMERGED"; do
    assert_present "$s" "kept slot $s was removed"
  done
  assert_equals ok "$(sed -n 's/^last_result=//p' "$HOME_DIR/state/.treehouse-prune")" "sweep record result"
  pass "a sweep removes the available slot and keeps leased, protected, claimed, recorded, and unmerged slots"
}

test_in_use_slot_is_kept() {
  local slot pid out
  slot=$(lease_slot)
  return_slot "$slot"
  ( cd "$slot" && exec sleep 60 ) &
  pid=$!
  sleep 0.5
  out=$(prune run) || { kill "$pid" 2>/dev/null; fail "sweep failed: $out"; }
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  assert_present "$slot" "slot with a running process was removed"
  assert_contains "$out" "kept $slot" "slot with a running process must be reported kept"
  pass "a slot with a running process is kept"
}

test_unusable_protected_list_stops_the_sweep() {
  local out rc
  printf 'relative/path\n' > "$HOME_DIR/config/treehouse-prune-protected"
  out=$(prune run) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "sweep must stop on an unusable protected list"
  assert_contains "$out" "stopped: protected-slot list is unusable" "stop reason"
  assert_present "$PROTECTED" "a stopped sweep removed a slot"
  assert_equals failed "$(sed -n 's/^last_result=//p' "$HOME_DIR/state/.treehouse-prune")" "failed sweep record"
  printf '%s\n' "${PROTECTED%/*}" > "$HOME_DIR/config/treehouse-prune-protected"
  pass "an unusable protected-slot list stops the sweep before anything is removed"
}

test_check_reports_failure_once_and_schedules() {
  local out now last
  # The failed sweep above is reported once, then silence.
  out=$(FM_TREEHOUSE_PRUNE_NOW=1 prune check)
  assert_contains "$out" "treehouse pool prune failed: stopped: protected-slot list is unusable" "failure report"
  out=$(FM_TREEHOUSE_PRUNE_NOW=1 prune check)
  assert_equals "" "$out" "a reported failure must not repeat"

  # Not due: nothing starts.
  last=$(sed -n 's/^last_start=//p' "$HOME_DIR/state/.treehouse-prune")
  now=$((last + 60))
  out=$(FM_TREEHOUSE_PRUNE_NOW=$now prune check)
  assert_equals "" "$out" "check is silent when no sweep is due"
  assert_equals "$last" "$(sed -n 's/^last_start=//p' "$HOME_DIR/state/.treehouse-prune")" "no sweep before the interval"

  # Due: a detached sweep starts and records its result.
  now=$((last + 86400))
  out=$(FM_TREEHOUSE_PRUNE_NOW=$now prune check)
  assert_equals "" "$out" "starting a sweep is silent"
  for _ in $(seq 1 100); do
    [ "$(sed -n 's/^last_result=//p' "$HOME_DIR/state/.treehouse-prune")" = ok ] && break
    sleep 0.2
  done
  assert_equals ok "$(sed -n 's/^last_result=//p' "$HOME_DIR/state/.treehouse-prune")" "scheduled sweep result"
  assert_grep 'summary: removed 0, kept 5' "$HOME_DIR/state/.treehouse-prune.log" "scheduled sweep log"
  pass "check reports a failed sweep once and starts a sweep only when one is due"
}

test_arm_and_disarm() {
  local out
  out=$(prune arm) || fail "arm failed: $out"
  assert_present "$HOME_DIR/state/treehouse-prune.check.sh" "arm must write the check"
  assert_present "$HOME_DIR/state/treehouse-prune.check-trust" "arm must register the check"
  assert_contains "$(prune status)" "armed: yes" "status after arm"
  out=$(prune disarm) || fail "disarm failed: $out"
  assert_absent "$HOME_DIR/state/treehouse-prune.check.sh" "disarm must remove the check"
  assert_absent "$HOME_DIR/state/treehouse-prune.check-trust" "disarm must remove the trust binding"
  assert_absent "$HOME_DIR/state/.treehouse-prune" "disarm must remove the record"
  assert_contains "$(prune status)" "armed: no" "status after disarm"
  pass "arm registers the scheduled check and disarm retires it"
}

test_dry_run_removes_nothing
test_sweep_removes_only_available_slots
test_in_use_slot_is_kept
test_unusable_protected_list_stops_the_sweep
test_check_reports_failure_once_and_schedules
test_arm_and_disarm
