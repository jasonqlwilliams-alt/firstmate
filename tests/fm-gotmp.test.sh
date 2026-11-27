#!/usr/bin/env bash
# Behavior tests for per-task GOTMPDIR support (fm-gotmp).
#
# fm-spawn gives each task a private temp root with Go's build temp nested at
# gotmp/, exports GOTMPDIR into the crewmate pane, and records tasktmp= in the task's
# meta. fm-teardown reads tasktmp= and removes the whole root on cleanup.
#
# These tests exercise fm-teardown directly as a subprocess against a fake FM_HOME/FM_ROOT
# built so the real script resolves into it, with stub helper scripts.
# The isolated fm-spawn subprocess in fm-kimi-harness.test.sh covers temp-root creation,
# metadata publication, and the pane environment export.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-gotmp-tests)
LEGACY_SLEEPER_PID=
LEGACY_SLEEPER_IDENTITY=
trap 'fm_test_stop_sleeper "$LEGACY_SLEEPER_PID" "$LEGACY_SLEEPER_IDENTITY"; fm_test_cleanup' EXIT

# Build a fake FM_HOME/FM_ROOT so the real fm-teardown.sh (symlinked in) resolves
# state and helper scripts inside it. Stub the helper scripts fm-teardown calls so no
# live tmux/treehouse/fleet state is touched. A nonexistent worktree path makes both
# `if [ -d "$WT" ]` guards skip, so teardown runs straight to the cleanup + state rm.
make_fake_root() {
  local id=$1 tasktmp=$2
  local fake="$TMP_ROOT/$id"
  mkdir -p "$fake/bin/backends" "$fake/state" "$fake/data"
  # Symlink the REAL teardown so the test exercises actual code, not a copy.
  ln -s "$TEARDOWN" "$fake/bin/fm-teardown.sh"
  # fm-backend.sh is real, while its adapter is stubbed so this temp-cleanup
  # test cannot depend on or mutate a host tmux server.
  ln -s "$ROOT/bin/fm-backend.sh" "$fake/bin/fm-backend.sh"
  cat > "$fake/bin/backends/tmux.sh" <<'SH'
fm_backend_tmux_kill() { return 0; }
SH
  ln -s "$ROOT/bin/fm-tmux-lib.sh" "$fake/bin/fm-tmux-lib.sh"
  ln -s "$ROOT/bin/fm-cursor-lib.sh" "$fake/bin/fm-cursor-lib.sh"
  ln -s "$ROOT/bin/fm-composer-lib.sh" "$fake/bin/fm-composer-lib.sh"
  ln -s "$ROOT/bin/fm-nm-run-lib.sh" "$fake/bin/fm-nm-run-lib.sh"
  # fm-lock-lib.sh: teardown sources it for the shared lock-staleness proof.
  ln -s "$ROOT/bin/fm-lock-lib.sh" "$fake/bin/fm-lock-lib.sh"
  # fm-lease-lib.sh: teardown sources it for the supervision lease guard.
  ln -s "$ROOT/bin/fm-lease-lib.sh" "$fake/bin/fm-lease-lib.sh"
  # Lifecycle serialization, status presentation retirement, and shared adapter
  # ownership are sourced by teardown.
  ln -s "$ROOT/bin/fm-control-lib.sh" "$fake/bin/fm-control-lib.sh"
  ln -s "$ROOT/bin/fm-classify-lib.sh" "$fake/bin/fm-classify-lib.sh"
  # fm-timeout-lib.sh: the shared hard bound fm-classify-lib.sh sources for the
  # wedge detector's bounded worktree write probe.
  ln -s "$ROOT/bin/fm-timeout-lib.sh" "$fake/bin/fm-timeout-lib.sh"
  ln -s "$ROOT/bin/fm-wake-lib.sh" "$fake/bin/fm-wake-lib.sh"
  ln -s "$ROOT/bin/fm-session-lock-record-lib.sh" "$fake/bin/fm-session-lock-record-lib.sh"
  # fm-gate-refuse-lib.sh: teardown sources it before any fleet mutation.
  ln -s "$ROOT/bin/fm-gate-refuse-lib.sh" "$fake/bin/fm-gate-refuse-lib.sh"
  # fm-pr-lib.sh: teardown uses its canonical task-ID validator for poll cleanup.
  ln -s "$ROOT/bin/fm-pr-lib.sh" "$fake/bin/fm-pr-lib.sh"
  # fm-public-followup-lib.sh (and the fm-x-lib.sh it sources): teardown sources
  # it for the relay-activation gate on the promised-public-reply check. Neither
  # does anything in this fixture, which has no .env, but both are real siblings
  # teardown now requires.
  ln -s "$ROOT/bin/fm-public-followup-lib.sh" "$fake/bin/fm-public-followup-lib.sh"
  ln -s "$ROOT/bin/fm-x-lib.sh" "$fake/bin/fm-x-lib.sh"
  ln -s "$ROOT/bin/fm-secondmate-registry-lib.sh" "$fake/bin/fm-secondmate-registry-lib.sh"
  ln -s "$ROOT/bin/fm-secondmate-parent-lib.sh" "$fake/bin/fm-secondmate-parent-lib.sh"
  # Receiver-wake retirement sources the pending-reply library, which in turn
  # requires the marker helper even for this ordinary-task teardown fixture.
  ln -s "$ROOT/bin/fm-pending-reply-lib.sh" "$fake/bin/fm-pending-reply-lib.sh"
  ln -s "$ROOT/bin/fm-marker-lib.sh" "$fake/bin/fm-marker-lib.sh"
  ln -s "$ROOT/bin/fm-workset-lib.sh" "$fake/bin/fm-workset-lib.sh"
  ln -s "$ROOT/bin/fm-operational-input.sh" "$fake/bin/fm-operational-input.sh"
  # Ordinary teardown reports any final ledger outcome before removing records.
  ln -s "$ROOT/bin/fm-inactive-reconcile.sh" "$fake/bin/fm-inactive-reconcile.sh"
  ln -s "$ROOT/bin/fm-parent-channel-lib.sh" "$fake/bin/fm-parent-channel-lib.sh"
  # fm-repository-policy-lib.sh: teardown sources it at the top level for the
  # origin-repository identity that pins gh/gh-axi PR lookups to this project.
  ln -s "$ROOT/bin/fm-repository-policy-lib.sh" "$fake/bin/fm-repository-policy-lib.sh"
  # fm-guard.sh: stub (teardown calls it with `|| true`).
  cat > "$fake/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-guard.sh"
  # fm-fleet-sync.sh: stub (called for non-scout/non-local-only teardowns).
  cat > "$fake/bin/fm-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-fleet-sync.sh"
  # fm-tasks-axi-lib.sh: stub (teardown sources it). Report no backend so the
  # fused backlog close is skipped and the follow-up echo takes the plain-message
  # path; there is no tasks-axi and no backlog in this fixture.
  cat > "$fake/bin/fm-tasks-axi-lib.sh" <<'SH'
FM_TASKS_AXI_MIN=0.2.4
fm_tasks_axi_backend() { printf 'markdown\n'; }
fm_tasks_axi_backend_available() { return 1; }
fm_tasks_axi_compatible() { return 1; }
fm_backlog_backend_manual() { return 1; }
SH
  ln -s "$ROOT/bin/fm-backlog-transition-lib.sh" "$fake/bin/fm-backlog-transition-lib.sh"
  # Meta with a nonexistent worktree so the dirty/treehouse blocks skip.
  cat > "$fake/state/$id.meta" <<META
window=fakeses:fm-$id
worktree=$TMP_ROOT/nonexistent-worktree-$id
project=$TMP_ROOT/nonexistent-project-$id
harness=claude
kind=ship
mode=no-mistakes
yolo=off
tasktmp=$tasktmp
META
  printf '%s' "$fake"
}

# --- fm-teardown side (real subprocess) ---

test_teardown_removes_tasktmp_dir() {
  local id=td-rm-z2
  local task_tmp="$TMP_ROOT/fm-$id"
  mkdir -p "$task_tmp/gotmp"
  printf 'leftover\n' > "$task_tmp/gotmp/build-artifact"
  local fake
  fake=$(make_fake_root "$id" "$task_tmp")
  # Sanity: dir + contents exist before teardown.
  [ -d "$task_tmp/gotmp" ] || fail "precondition: gotmp missing before teardown"
  # Run the REAL teardown against the fake root.
  FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero with a valid tasktmp"
  [ ! -e "$task_tmp" ] \
    || fail "teardown did not remove the tasktmp dir ($task_tmp still exists)"
  pass "fm-teardown removes the dir pointed to by tasktmp= in meta"
}

test_teardown_removes_tasktmp_dir_by_equivalent_spelling() {
  local variant=$1 id task_tmp recorded fake
  id="td-sp-$variant"
  task_tmp="$TMP_ROOT/fm-$id+private"
  mkdir -p "$task_tmp/gotmp"
  printf 'leftover\n' > "$task_tmp/gotmp/build-artifact"
  case "$variant" in
    doubled-slash) recorded="/${task_tmp//\//\/\/}" ;;
    trailing-slash) recorded="$task_tmp/" ;;
    trailing-dot) recorded="$task_tmp/." ;;
    linked-parent)
      ln -s "$TMP_ROOT" "$TMP_ROOT/root-link-$id"
      recorded="$TMP_ROOT/root-link-$id/${task_tmp##*/}"
      ;;
  esac
  [ "$recorded" -ef "$task_tmp" ] || fail "precondition: $recorded does not name $task_tmp"
  fake=$(make_fake_root "$id" "$recorded")
  FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" > "$fake/teardown.log" 2>&1 \
    || fail "$variant teardown failed: $(cat "$fake/teardown.log")"
  [ ! -e "$task_tmp" ] || fail "teardown did not recognise its own root through the $variant spelling $recorded"
  [ "$variant" != linked-parent ] || [ -L "$TMP_ROOT/root-link-$id" ] \
    || fail "teardown removed the symlinked parent instead of the task root"
  pass "fm-teardown removes its own task temp root recorded with a $variant spelling"
}

test_teardown_preserves_replacement_tasktmp() {
  local phase=$1 id task_tmp alias fake hook
  id="td-move-$phase"
  task_tmp="$TMP_ROOT/$id-original/task-root"
  alias="$TMP_ROOT/$id-link"
  mkdir -p "$task_tmp"
  ln -s "${task_tmp%/*}" "$alias"
  fake=$(make_fake_root "$id" "$alias/task-root")
  hook="$fake/bin/fm-remote-job-reap-orphans.sh"
  if [ "$phase" = scan ]; then hook="$fake/bin/lsof"; fi
  cat > "$hook" <<'SH'
#!/usr/bin/env bash
set -e
mv "$MOVE_TASK_TMP" "$MOVE_TASK_TMP-new"
mkdir "$MOVE_TASK_TMP"
printf 'unrelated data\n' > "$MOVE_TASK_TMP/keep"
if [ "$MOVE_TASK_PHASE" = cleanup ]; then
  mkdir "$MOVE_TASK_TMP-parent"
  mv "$MOVE_TASK_TMP-new" "$MOVE_TASK_TMP-parent/task-root"
  rm "$MOVE_TASK_ALIAS"
  ln -s "$MOVE_TASK_TMP-parent" "$MOVE_TASK_ALIAS"
fi
SH
  chmod +x "$hook"
  local rc=0
  FM_HOME="$fake" PATH="$fake/bin:$PATH" MOVE_TASK_TMP="$task_tmp" MOVE_TASK_ALIAS="$alias" MOVE_TASK_PHASE="$phase" \
    bash "$fake/bin/fm-teardown.sh" "$id" > "$fake/teardown.log" 2>&1 || rc=$?
  assert_present "$task_tmp/keep" "teardown removed a replacement directory it did not own"
  if [ "$phase" = scan ]; then
    expect_code 1 "$rc" "teardown should refuse a root move during process enumeration: $(cat "$fake/teardown.log")"
    assert_present "$fake/state/$id.meta" "teardown retired a task after an incomplete scan"
    assert_present "$task_tmp-new" "teardown removed the moved root after an incomplete scan"
  else
    expect_code 0 "$rc" "teardown should follow the original root through the updated alias: $(cat "$fake/teardown.log")"
    assert_absent "$alias/task-root" "teardown did not remove the moved root"
  fi
  pass "fm-teardown preserves a replacement directory when the task root moves during $phase"
}

test_teardown_retains_uninspectable_tasktmp() {
  local phase=$1 scope=$2 id task_tmp restricted fake rc=0
  id="td-inspect-$phase-$scope"
  task_tmp="$TMP_ROOT/$id-parent/private"
  restricted=$task_tmp
  [ "$scope" != parent ] || restricted=${task_tmp%/*}
  mkdir -p "$task_tmp/gotmp"
  printf 'build output\n' > "$task_tmp/gotmp/artifact"
  chmod 600 "$restricted"
  if (cd "$task_tmp") 2>/dev/null; then
    chmod 700 "$restricted"
    printf 'skip: task temp inspection test requires directory permissions to restrict this user\n'
    return 0
  fi
  fake=$(make_fake_root "$id" "$task_tmp")
  cp "$fake/state/$id.meta" "$fake/meta.before"
  if [ "$phase" = removal ]; then
    chmod 700 "$restricted"
    cat > "$fake/bin/fm-remote-job-reap-orphans.sh" <<'SH'
#!/usr/bin/env bash
chmod 600 "$INSPECTION_TEST_ROOT"
SH
    chmod +x "$fake/bin/fm-remote-job-reap-orphans.sh"
  fi
  FM_HOME="$fake" INSPECTION_TEST_ROOT="$restricted" \
    bash "$fake/bin/fm-teardown.sh" "$id" > "$fake/teardown.log" 2>&1 || rc=$?
  chmod 700 "$restricted"
  expect_code 1 "$rc" "teardown should refuse a $scope inspection failure during $phase: $(cat "$fake/teardown.log")"
  assert_grep "cannot inspect task temporary directory $task_tmp" "$fake/teardown.log" \
    "teardown did not identify the unreadable directory"
  cmp -s "$fake/meta.before" "$fake/state/$id.meta" || fail "teardown changed or retired the task record"
  assert_present "$task_tmp/gotmp/artifact" "teardown removed the build artifact"
  pass "fm-teardown retains the task record when temp $scope inspection fails during $phase"
}

test_teardown_preserves_shared_tasktmp() {
  local variant=$1 id fake legacy_task_tmp task_tmp
  legacy_task_tmp=$(mktemp -d /tmp/fm-legacy-XXXXXX) || fail "could not allocate legacy fixture"
  FM_TEST_CLEANUP_DIRS+=("$legacy_task_tmp")
  id=${legacy_task_tmp#/tmp/fm-}
  mkdir "$legacy_task_tmp/gotmp"
  printf 'another home still needs this\n' > "$legacy_task_tmp/gotmp/keep"
  task_tmp=$legacy_task_tmp
  case "$variant" in
    symlink)
      task_tmp="$TMP_ROOT/tasktmp-link"
      ln -s "$legacy_task_tmp" "$task_tmp"
      ;;
    # Equivalent spellings of the shared legacy root that a literal string
    # comparison with /tmp/fm-<id> does not recognise.
    symlink-dot)
      ln -s "$legacy_task_tmp" "$TMP_ROOT/tasktmp-link-dot"
      task_tmp="$TMP_ROOT/tasktmp-link-dot/."
      ;;
    doubled-slash) task_tmp="//tmp//fm-$id" ;;
    dot-segment) task_tmp="/tmp/./fm-$id" ;;
    dotdot-segment) task_tmp="/tmp/../tmp/fm-$id" ;;
    trailing-dot) task_tmp="/tmp/fm-$id/." ;;
    linked-parent)
      ln -s /tmp "$TMP_ROOT/tmp-link-$id"
      task_tmp="$TMP_ROOT/tmp-link-$id/fm-$id"
      ;;
    relative)
      task_tmp="../../../../../../../../../../../../../../../../tmp/fm-$id"
      ;;
  esac
  [ "$variant" = relative ] || [ "$task_tmp" -ef "$legacy_task_tmp" ] \
    || fail "precondition: $variant spelling $task_tmp does not name the shared root"
  fake=$(make_fake_root "$id" "$task_tmp")
  if command -v lsof >/dev/null; then
    ( cd "$legacy_task_tmp/gotmp" && exec sleep 300 ) &
    LEGACY_SLEEPER_PID=$!
    LEGACY_SLEEPER_IDENTITY=$(fm_test_cwd_sleeper_identity "$LEGACY_SLEEPER_PID") \
      || fail "legacy sleeper did not start inside the shared root"
  else
    printf 'skip: %s task temp process preservation requires lsof\n' "$variant"
  fi
  ( cd "$fake" && FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" ) > "$fake/teardown.log" 2>&1 \
    || fail "$variant teardown failed: $(cat "$fake/teardown.log")"
  [ ! -e "$fake/state/$id.meta" ] || fail "$variant teardown left the task record"
  [ -f "$legacy_task_tmp/gotmp/keep" ] || fail "$variant teardown removed a potentially shared temp root"
  [ "$variant" != symlink ] || [ -L "$task_tmp" ] || fail "symlink teardown removed the recorded link"
  if [ -n "$LEGACY_SLEEPER_IDENTITY" ]; then
    fm_test_owner_is_alive "$LEGACY_SLEEPER_PID" "$LEGACY_SLEEPER_IDENTITY" \
      || fail "$variant teardown signalled a process in the shared temp root"
    fm_test_stop_sleeper "$LEGACY_SLEEPER_PID" "$LEGACY_SLEEPER_IDENTITY"
    LEGACY_SLEEPER_PID=''
    LEGACY_SLEEPER_IDENTITY=''
  fi
  pass "fm-teardown leaves the $variant task temp path alone"
}

test_teardown_skips_gracefully_without_tasktmp() {
  # Backward compat: a meta from a pre-fix task has no tasktmp= line. Teardown must
  # not error and must not remove anything.
  local id=td-absent-z3
  local fake="$TMP_ROOT/$id-root"
  mkdir -p "$fake/bin/backends" "$fake/state" "$fake/data"
  ln -s "$TEARDOWN" "$fake/bin/fm-teardown.sh"
  ln -s "$ROOT/bin/fm-backend.sh" "$fake/bin/fm-backend.sh"
  cat > "$fake/bin/backends/tmux.sh" <<'SH'
fm_backend_tmux_kill() { return 0; }
SH
  ln -s "$ROOT/bin/fm-tmux-lib.sh" "$fake/bin/fm-tmux-lib.sh"
  ln -s "$ROOT/bin/fm-cursor-lib.sh" "$fake/bin/fm-cursor-lib.sh"
  ln -s "$ROOT/bin/fm-composer-lib.sh" "$fake/bin/fm-composer-lib.sh"
  ln -s "$ROOT/bin/fm-nm-run-lib.sh" "$fake/bin/fm-nm-run-lib.sh"
  ln -s "$ROOT/bin/fm-lock-lib.sh" "$fake/bin/fm-lock-lib.sh"
  # fm-lease-lib.sh: teardown sources it for the supervision lease guard.
  ln -s "$ROOT/bin/fm-lease-lib.sh" "$fake/bin/fm-lease-lib.sh"
  ln -s "$ROOT/bin/fm-control-lib.sh" "$fake/bin/fm-control-lib.sh"
  ln -s "$ROOT/bin/fm-classify-lib.sh" "$fake/bin/fm-classify-lib.sh"
  # fm-timeout-lib.sh: the shared hard bound fm-classify-lib.sh sources for the
  # wedge detector's bounded worktree write probe.
  ln -s "$ROOT/bin/fm-timeout-lib.sh" "$fake/bin/fm-timeout-lib.sh"
  ln -s "$ROOT/bin/fm-wake-lib.sh" "$fake/bin/fm-wake-lib.sh"
  ln -s "$ROOT/bin/fm-session-lock-record-lib.sh" "$fake/bin/fm-session-lock-record-lib.sh"
  # fm-gate-refuse-lib.sh: teardown sources it before any fleet mutation.
  ln -s "$ROOT/bin/fm-gate-refuse-lib.sh" "$fake/bin/fm-gate-refuse-lib.sh"
  # fm-pr-lib.sh: teardown uses its canonical task-ID validator for poll cleanup.
  ln -s "$ROOT/bin/fm-pr-lib.sh" "$fake/bin/fm-pr-lib.sh"
  # fm-public-followup-lib.sh (and the fm-x-lib.sh it sources): teardown sources
  # it for the relay-activation gate on the promised-public-reply check. Neither
  # does anything in this fixture, which has no .env, but both are real siblings
  # teardown now requires.
  ln -s "$ROOT/bin/fm-public-followup-lib.sh" "$fake/bin/fm-public-followup-lib.sh"
  ln -s "$ROOT/bin/fm-x-lib.sh" "$fake/bin/fm-x-lib.sh"
  ln -s "$ROOT/bin/fm-secondmate-registry-lib.sh" "$fake/bin/fm-secondmate-registry-lib.sh"
  ln -s "$ROOT/bin/fm-secondmate-parent-lib.sh" "$fake/bin/fm-secondmate-parent-lib.sh"
  ln -s "$ROOT/bin/fm-pending-reply-lib.sh" "$fake/bin/fm-pending-reply-lib.sh"
  ln -s "$ROOT/bin/fm-marker-lib.sh" "$fake/bin/fm-marker-lib.sh"
  ln -s "$ROOT/bin/fm-workset-lib.sh" "$fake/bin/fm-workset-lib.sh"
  ln -s "$ROOT/bin/fm-operational-input.sh" "$fake/bin/fm-operational-input.sh"
  ln -s "$ROOT/bin/fm-inactive-reconcile.sh" "$fake/bin/fm-inactive-reconcile.sh"
  ln -s "$ROOT/bin/fm-parent-channel-lib.sh" "$fake/bin/fm-parent-channel-lib.sh"
  # fm-repository-policy-lib.sh: teardown sources it at the top level for the
  # origin-repository identity that pins gh/gh-axi PR lookups to this project.
  ln -s "$ROOT/bin/fm-repository-policy-lib.sh" "$fake/bin/fm-repository-policy-lib.sh"
  cat > "$fake/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-guard.sh"
  cat > "$fake/bin/fm-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-fleet-sync.sh"
  cat > "$fake/bin/fm-tasks-axi-lib.sh" <<'SH'
FM_TASKS_AXI_MIN=0.2.4
fm_tasks_axi_backend() { printf 'markdown\n'; }
fm_tasks_axi_backend_available() { return 1; }
fm_tasks_axi_compatible() { return 1; }
fm_backlog_backend_manual() { return 1; }
SH
  ln -s "$ROOT/bin/fm-backlog-transition-lib.sh" "$fake/bin/fm-backlog-transition-lib.sh"
  # No tasktmp= line at all.
  cat > "$fake/state/$id.meta" <<META
window=fakeses:fm-$id
worktree=$TMP_ROOT/nonexistent-wt-$id
project=$TMP_ROOT/nonexistent-proj-$id
harness=claude
kind=ship
mode=no-mistakes
yolo=off
META
  FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero when tasktmp= was absent"
  pass "fm-teardown skips gracefully when tasktmp= is absent (backward compat)"
}

test_teardown_skips_gracefully_when_dir_missing() {
  # tasktmp= points to a path that does not exist. Teardown must not error.
  local id=td-missing-z4
  local task_tmp="$TMP_ROOT/never-created-fm-$id"
  # Intentionally do NOT create $task_tmp.
  [ ! -e "$task_tmp" ] || fail "precondition: task_tmp should not exist yet"
  local fake
  fake=$(make_fake_root "$id" "$task_tmp")
  FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero when tasktmp dir was missing"
  [ ! -e "$task_tmp" ] || fail "teardown created/left the tasktmp dir unexpectedly"
  pass "fm-teardown skips gracefully when tasktmp= points to a nonexistent dir"
}

test_teardown_removes_tasktmp_dir
for variant in doubled-slash trailing-slash trailing-dot linked-parent; do
  test_teardown_removes_tasktmp_dir_by_equivalent_spelling "$variant"
done
test_teardown_preserves_replacement_tasktmp scan
test_teardown_preserves_replacement_tasktmp cleanup
for scope in leaf parent; do
  test_teardown_retains_uninspectable_tasktmp capture "$scope"
  test_teardown_retains_uninspectable_tasktmp removal "$scope"
done
test_teardown_preserves_shared_tasktmp legacy
test_teardown_preserves_shared_tasktmp symlink
for variant in symlink-dot doubled-slash dot-segment dotdot-segment trailing-dot linked-parent relative; do
  test_teardown_preserves_shared_tasktmp "$variant"
done
test_teardown_skips_gracefully_without_tasktmp
test_teardown_skips_gracefully_when_dir_missing
