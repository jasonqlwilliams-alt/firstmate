#!/usr/bin/env bash
# Behavior tests for tests/lib.sh's shared fixture-tempdir helper
# (fm_test_tmproot / fm_test_cleanup / fm_test_reap_orphans).
#
# The near-universal call pattern across this suite is
# `TMP_ROOT=$(fm_test_tmproot prefix)`, which forks a subshell to capture the
# function's stdout. These tests spawn real, separate bash processes that use
# that exact pattern and assert the fixture root is actually gone once the
# owning process's guarded teardown has run - on a normal exit and on a
# terminating signal - plus that a stale marked fixture from a killed prior
# run gets reaped on the next source. Nothing here inspects tests/lib.sh's
# source text; it only observes filesystem state around the real helper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/tests/lib.sh"

test_fixture_root_gone_after_normal_exit() {
  local child_out child_dir
  child_out=$(bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-exit)
    printf "%s\n" "$d"
    if [ -d "$d" ]; then printf "mid:present\n"; else printf "mid:missing\n"; fi
  ')
  child_dir=$(printf '%s\n' "$child_out" | sed -n '1p')
  assert_contains "$child_out" "mid:present" \
    "the fixture root was not present while its owning process was still alive"
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived its owning process's normal exit"
  pass "fm_test_tmproot cleans up its fixture root on normal exit"
}

test_scratch_cleanup_failure_changes_only_a_successful_exit() {
  local harness status expected rc output blocked scratch independent
  harness=$(fm_test_tmproot fm-test-cleanup-exit-status)
  for status in 0 7; do
    expected=$status
    [ "$status" -ne 0 ] || expected=1
    output=$(TMPDIR="$harness" env -u TREEHOUSE_ROOT -u FM_TEST_TREEHOUSE_DIR bash -uc '
      . "$1"
      printf "%s\n" "$TREEHOUSE_ROOT" > "$3/refused"
      rm "$FM_TEST_TREEHOUSE_DIR/.fm-test-treehouse"
      independent=$(fm_test_tmproot fm-test-cleanup-independent) || exit 9
      fm_test_treehouse_setup
      fm_test_track_treehouse_scratch "$FM_TEST_TREEHOUSE_DIR"
      printf "%s\n" "$independent" > "$3/independent"
      printf "%s\n" "$TREEHOUSE_ROOT" > "$3/scratch"
      exit "$2"
    ' _ "$LIB" "$status" "$harness" 2>&1) && rc=0 || rc=$?
    assert_contains "$output" 'refusing to remove' "standalone cleanup reports the refused scratch root"
    expect_code "$expected" "$rc" "standalone cleanup preserves or upgrades exit status $status"
    blocked=$(cat "$harness/refused") || fail "the child did not report the refused root"
    independent=$(cat "$harness/independent") || fail "the child did not report the independent fixture"
    scratch=$(cat "$harness/scratch") || fail "the child did not report the independent scratch root"
    assert_present "$blocked" "parent cleanup bypassed the scratch removal guard"
    assert_absent "$independent" "scratch refusal stopped independent fixture cleanup"
    assert_absent "$scratch" "scratch refusal stopped cleanup of the next scratch root"
    touch "$(dirname "$blocked")/.fm-test-treehouse" || fail "could not restore the test directory marker"
    fm_test_treehouse_remove "$(dirname "$blocked")" || fail "could not remove the refused test directory"
  done
  pass "scratch cleanup failures preserve exit status and still clean independent fixtures"
}

test_custom_exit_chains_scratch_cleanup() {
  local harness output rc status root
  harness=$(fm_test_tmproot fm-test-custom-exit)
  for status in 0 7; do
    output=$(TMPDIR="$harness" env -u TREEHOUSE_ROOT -u FM_TEST_TREEHOUSE_DIR bash -uc '
      . "$1"
      cleanup() {
        test -d "$TREEHOUSE_ROOT" || return 1
        printf "custom cleanup ran\n"
        return 9
      }
      trap '\''fm_test_cleanup_exit "$?" fm_test_cleanup_after cleanup'\'' EXIT
      printf "%s\n" "$TREEHOUSE_ROOT" > "$3/root"
      exit "$2"
    ' _ "$LIB" "$status" "$harness" 2>&1) && rc=0 || rc=$?
    expect_code "$status" "$rc" "custom cleanup preserves exit status $status"
    assert_contains "$output" 'custom cleanup ran' "the suite cleanup ran before scratch removal"
    root=$(cat "$harness/root") || fail "the child did not report its scratch root"
    assert_absent "$root" "the custom exit left its scratch root behind"
  done
  pass "custom suite exits clean their scratch roots and preserve exit status"
}

test_codex_refusal_keeps_diagnostics_without_scratch() {
  local lab repo output rc root diagnostics
  lab=$(fm_test_tmproot fm-test-codex-refusal)
  repo="$lab/repo"
  mkdir -p "$repo/tests" "$repo/bin" "$lab/tools" "$lab/home"
  cp "$ROOT/tests/"{fm-codex-signin-live-e2e.test.sh,lib.sh,git-config-helpers.sh,treehouse-test-helpers.sh} "$repo/tests/"
  cp "$ROOT/bin/"{fm-wake-lib.sh,fm-session-lock-record-lib.sh} "$repo/bin/"
  printf '%s\n' 'fm_backend_codex_agent_pid() { return 1; }' \
    'fm_backend_agent_state() { printf "%s\n" unknown; }' > "$repo/bin/fm-backend.sh"
  printf '%s\n' 'fm_composer_codex_signin_screen() { return 0; }' > "$repo/bin/fm-composer-lib.sh"
  fm_fake_exit0 "$lab/tools" sleep
  cat > "$lab/tools/tmux" <<'SH'
#!/usr/bin/env bash
case "$3" in
  display-message) echo 12345 ;;
  capture-pane) echo chooser ;;
  kill-server) touch "$FM_TEST_CLEANUP_LAB/killed" ;;
esac
printf '%s\n' "${2%/*}" > "$FM_TEST_CLEANUP_LAB/diagnostics"
SH
  cat > "$lab/tools/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$FM_TEST_TREEHOUSE_DIR" > "$FM_TEST_CLEANUP_LAB/scratch"
printf '%s\n' 'codex fixture'
SH
  chmod +x "$lab/tools/tmux" "$lab/tools/codex"
  output=$(env -u FM_TEST_TREEHOUSE_DIR HOME="$lab/home" TMPDIR="$lab" PATH="$lab/tools:$PATH" \
    FM_TEST_CLEANUP_LAB="$lab" FM_CODEX_SIGNIN_LIVE=1 FM_CODEX_SIGNIN_CAPTURE= \
    bash "$repo/tests/fm-codex-signin-live-e2e.test.sh" 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "unknown Codex endpoint must fail"
  assert_contains "$output" 'endpoint identity is unknown; private endpoint retained' "cleanup reached the endpoint refusal"
  root=$(cat "$lab/scratch") || fail "the guard did not report its scratch directory"
  diagnostics=$(cat "$lab/diagnostics") || fail "the guard did not report its diagnostic directory"
  assert_absent "$root" "Codex refusal leaked scratch"
  assert_present "$diagnostics/mtimes-before" "Codex refusal deleted its diagnostic fixture"
  assert_absent "$lab/killed" "Codex refusal touched its private endpoint"
  pass "Codex identity refusal retains its endpoint and diagnostics while removing scratch"
}

test_fixture_root_gone_after_sigterm() {
  local harness dirfile child_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-sigterm-harness)
  dirfile="$harness/child-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-term)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the child never published its fixture root before the wait timed out"
  child_dir=$(cat "$dirfile")
  assert_present "$child_dir" "the child's fixture root did not exist before it was signaled"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived SIGTERM to its owning process"
  pass "fm_test_tmproot cleans up its fixture root on SIGTERM"
}

test_cleanup_registry_resists_precreation() {
  local harness shared_tmp victim
  harness=$(fm_test_tmproot fm-test-cleanup-registry-harness)
  shared_tmp="$harness/shared-tmp"
  victim="$harness/victim"
  mkdir -p "$shared_tmp" "$victim"

  TMPDIR="$shared_tmp" bash -c '
    printf "%s\n" "$1" > "$TMPDIR/.fm-test-cleanup.$$"
    . "$2"
  ' _ "$victim" "$LIB"

  assert_present "$victim" \
    "a precreated predictable cleanup registry injected an arbitrary deletion target"
  pass "the cleanup registry cannot be injected through path precreation"
}

test_fixture_registration_failure_rolls_back_root() {
  local harness failure_tmp registry_dir output leaked_root
  harness=$(fm_test_tmproot fm-test-cleanup-registration-harness)
  failure_tmp="$harness/tmp"
  registry_dir="$harness/registry-dir"
  mkdir -p "$failure_tmp" "$registry_dir"

  if output=$(TMPDIR="$failure_tmp" FM_TEST_CLEANUP_REGISTRY="$registry_dir" \
    fm_test_tmproot fm-test-cleanup-registration-failure 2>/dev/null); then
    fail "fm_test_tmproot succeeded after its cleanup registry rejected registration"
  fi
  [ -z "$output" ] || fail "fm_test_tmproot published an unregistered fixture root"
  for leaked_root in "$failure_tmp"/fm-test-cleanup-registration-failure.*; do
    [ ! -e "$leaked_root" ] || fail "fm_test_tmproot leaked a root after registration failed"
  done
  pass "failed fixture registration rolls back the new root"
}

test_orphan_sweep_respects_fixture_ownership() {
  local harness dirfile active_dir stale_dir fresh_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-orphan-harness)
  dirfile="$harness/active-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-active)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the active child never published its fixture root before the wait timed out"
  active_dir=$(cat "$dirfile")
  touch -t 202001010000 "$active_dir/.fm-test-fixture"

  stale_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-cleanup-stale.XXXXXX")
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale_dir/.fm-test-fixture"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"
  fresh_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-cleanup-fresh.XXXXXX")
  : > "$fresh_dir/.fm-test-fixture"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    fm_test_reap_orphans "$TMPDIR"
  '

  assert_absent "$stale_dir" \
    "a stale fixture root whose PID was reused by another process was not reaped"
  assert_present "$active_dir" \
    "the orphan reaper removed an old fixture root whose owning process was still alive"
  assert_present "$fresh_dir" \
    "the orphan reaper removed a fresh marked fixture root it does not own yet"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$active_dir" \
    "the active fixture root survived its owning process's teardown"
  rm -rf "$fresh_dir"
  pass "the orphan sweep reaps only old fixtures without a live owner"
}

test_orphan_sweep_reaps_read_only_package_tree() {
  local stale_dir package_dir
  stale_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-cleanup-read-only.XXXXXX")
  package_dir="$stale_dir/packages/extension"
  mkdir -p "$package_dir"
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale_dir/.fm-test-fixture"
  printf 'installed package\n' > "$package_dir/entrypoint.py"
  chmod -R a-w "$stale_dir/packages"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "$1"
    fm_test_reap_orphans "$TMPDIR"
  ' _ "$LIB"

  assert_absent "$stale_dir" \
    "the orphan reaper left a stale fixture containing a read-only package tree"
  pass "the orphan sweep reaps read-only package fixtures"
}

test_orphan_sweep_reaps_standalone_treehouse_scratch() {
  local harness receipt scratch pid attempt
  harness=$(fm_test_tmproot fm-test-cleanup-treehouse)
  receipt="$harness/scratch-path"
  TMPDIR="$harness" env -u TREEHOUSE_ROOT -u FM_TEST_TREEHOUSE_DIR bash -ec '
    . "$1"
    mkdir "$TREEHOUSE_ROOT/slot"
    : > "$TREEHOUSE_ROOT/slot/file"
    chmod u-w "$TREEHOUSE_ROOT/slot"
    printf "%s\n" "$TREEHOUSE_ROOT" > "$2"
    exec sleep 30
  ' _ "$LIB" "$receipt" &
  pid=$!
  for ((attempt=0; attempt<100; attempt++)); do
    [ -s "$receipt" ] && break
    sleep 0.05
  done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ -s "$receipt" ] || fail "standalone suite did not publish its scratch root"
  scratch=$(cat "$receipt")
  assert_present "$scratch/slot/file" "scratch fixture must survive SIGKILL before the sweep"

  TMPDIR="$harness" FM_TEST_ORPHAN_MAX_AGE_SECONDS=0 FM_TEST_SKIP_ORPHAN_REAP=1 \
    bash -ec '. "$1"; fm_test_reap_orphans "$(dirname "$2")" "$(basename "$2")"' \
    _ "$LIB" "$(dirname "$scratch")" || fail "the next suite failed to run its orphan sweep"
  assert_absent "$scratch" "the orphan sweep missed a killed suite's Treehouse scratch root"
  pass "the orphan sweep reclaims standalone Treehouse pools after SIGKILL"
}

test_fixture_root_gone_after_normal_exit
test_scratch_cleanup_failure_changes_only_a_successful_exit
test_custom_exit_chains_scratch_cleanup
test_codex_refusal_keeps_diagnostics_without_scratch
test_fixture_root_gone_after_sigterm
test_cleanup_registry_resists_precreation
test_fixture_registration_failure_rolls_back_root
test_orphan_sweep_respects_fixture_ownership
test_orphan_sweep_reaps_read_only_package_tree
test_orphan_sweep_reaps_standalone_treehouse_scratch
