#!/usr/bin/env bash
# Behavior tests for tests/lib.sh primitives and tests/fixtures.sh builders.
#
# Cases call shared primitives directly or write stubs into a fakebin and exec
# them as a test would. Assertions are on observable output, exit status, and
# filesystem effects - never on helper source text. Migrated spawn suites cover
# fm_test_run_spawn through the real fm-spawn.sh; this file pins the shared
# primitives and stubs those suites use.
#
# It is also the fixture Git-config isolation regression, with host signing
# armed on a scratch config file: it drives every entry point that must reach
# tests/git-config-helpers.sh - the shared helpers, bin/fm-test-run.sh's
# per-suite wrapper, and the standalone scripts runnable without a live vendor.
# That helper's header owns the contract and the layers it leaves in force.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-test-fixtures)

test_runner_isolates_treehouse() (
  local dir="$TMP_ROOT/treehouse-runner" home tmp root pool
  local script jobs runner_pid receipt owner_pid owner_state attempt
  home="$dir/home"
  tmp="$home/.treehouse/tmp"
  mkdir -p "$dir/bin" "$dir/tests" "$dir/tools" "$tmp"
  cp "$ROOT/bin/fm-test-run.sh" "$dir/bin/"
  cp "$ROOT/tests/git-config-helpers.sh" "$ROOT/tests/treehouse-test-helpers.sh" "$dir/tests/"
  cp "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-session-lock-record-lib.sh" "$dir/bin/"
  cat > "$dir/tools/treehouse" <<'SH'
#!/usr/bin/env bash
set -eu
root="$HOME/.treehouse"
if [ "${1:-}" = --root ]; then
  root=$2
  shift 2
fi
[ "$*" = 'get --lease' ]
mkdir "$root/fixture-pool"
printf '%s\n' "$root/fixture-pool"
SH
  chmod +x "$dir/tools/treehouse"
  cat > "$dir/tests/fm-treehouse-lease-safety.test.sh" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$TREEHOUSE_ROOT" > "$FM_TEST_ROOT_RECEIPT"
env -u TREEHOUSE_ROOT treehouse get --lease > "$FM_TEST_POOL_RECEIPT"
if [ -n "${FM_TEST_CANCEL_DIR:-}" ]; then
  printf '%s\n' "$PPID" > "$FM_TEST_CANCEL_DIR/owner"
  kill -KILL "$(cat "$FM_TEST_CANCEL_DIR/runner")"
  for ((attempt=0; attempt<300; attempt++)); do
    if [ -e "$FM_TEST_CANCEL_DIR/stop" ]; then
      kill -KILL "$PPID"
      exit 0
    fi
    sleep 0.1
  done
  exit 1
fi
SH
  export HOME="$home" PATH="$dir/tools:$PATH" TMPDIR="$tmp"
  export FM_TEST_ROOT_RECEIPT="$dir/root" FM_TEST_POOL_RECEIPT="$dir/pool"
  unset FM_TEST_TREEHOUSE_BIN FM_TEST_TREEHOUSE_DIR
  "$dir/bin/fm-test-run.sh" --jobs 1 tests/fm-treehouse-lease-safety.test.sh > "$dir/run.log" 2>&1 ||
    fail "Treehouse runner fixture failed: $(cat "$dir/run.log")"
  root=$(cat "$dir/root") || fail "the test did not record its Treehouse root"
  pool=$(cat "$dir/pool") || fail "the test did not record its pool"
  assert_equals "$root/fixture-pool" "$pool" "Treehouse received the explicit test root"
  case "$root" in "$home/.treehouse"/*) fail "the test root is inside the live root" ;; esac
  assert_absent "$home/.treehouse/fixture-pool" "the test allocated a pool in the live root"
  assert_absent "$(dirname "$root")" "the runner left its Treehouse directory behind"
  assert_grep 'expected_gate_skip=treehouse' "$dir/run.log" "the suite reports its Treehouse prerequisite"
  pass "the runner passes a disposable root explicitly and leaves the live Treehouse root untouched"

  cp "$dir/tests/fm-treehouse-lease-safety.test.sh" "$dir/tests/fm-test-run.test.sh"
  printf '%s\n' 'exit 0' > "$dir/tests/fm-test-isolation-proof.test.sh"
  stat() {
    [ "${!#}" -ef "${FM_TEST_CANCEL_MARKER:-}" ] && command stat "$@"
  }
  export -f stat

  for jobs in 1 2; do
    receipt="$dir/cancel-$jobs"
    mkdir "$receipt"
    script=tests/fm-treehouse-lease-safety.test.sh
    [ "$jobs" -eq 1 ] || script=tests/fm-test-run.test.sh
    if FM_TEST_CANCEL_DIR="$receipt" FM_TEST_ROOT_RECEIPT="$receipt/root" \
      bash -c 'printf "%s\n" "$$" > "$FM_TEST_CANCEL_DIR/runner"; exec "$@"' \
      _ "$dir/bin/fm-test-run.sh" --jobs "$jobs" --per-script-timeout-secs 0 "$script" > "$receipt/run.log" 2>&1; then
      fail "the interrupted runner unexpectedly succeeded"
    fi
    runner_pid=$(cat "$receipt/runner") || fail "the runner did not publish its PID"
    owner_pid=$(cat "$receipt/owner") || fail "the interrupted suite did not publish its supervisor PID"
    root=$(cat "$receipt/root") || fail "the interrupted run did not record its Treehouse root"
    root=${root%/pool}
    fm_test_track_treehouse_scratch "$root" || fail "could not register the interrupted fixture for cleanup"
    [ "$owner_pid" != "$runner_pid" ] || fail "the suite supervisor did not survive runner cancellation"
    assert_present "$root/pool/fixture-pool" "the runner was interrupted during its suite"
    touch -t 202001010000 "$root/.fm-test-fixture" || fail "could not age the interrupted owner's record"

    ln -s "$root" "$receipt/scratch-alias" || fail "could not alias the interrupted scratch directory"
    export FM_TEST_CANCEL_MARKER="$receipt/scratch-alias/.fm-test-fixture"
    FM_TEST_SKIP_ORPHAN_REAP=0 FM_TEST_ORPHAN_MAX_AGE_SECONDS=3600 \
      "$dir/bin/fm-test-run.sh" --jobs 1 tests/fm-test-isolation-proof.test.sh > "$receipt/sweep.log" 2>&1 ||
      fail "the runner failed during startup recovery: $(cat "$receipt/sweep.log")"
    assert_present "$root/pool/fixture-pool" "runner startup deleted a live suite's pool (jobs=$jobs)"

    touch "$receipt/stop"
    for ((attempt=0; attempt<100; attempt++)); do
      owner_state=$(ps -p "$owner_pid" -o stat= 2>/dev/null) || break
      case "$owner_state" in ''|Z*) break ;; esac
      sleep 0.05
    done
    [ "$attempt" -lt 100 ] || fail "the interrupted suite supervisor did not exit"
    FM_TEST_SKIP_ORPHAN_REAP=0 FM_TEST_ORPHAN_MAX_AGE_SECONDS=3600 \
      "$dir/bin/fm-test-run.sh" --jobs 1 tests/fm-test-isolation-proof.test.sh > "$receipt/sweep.log" 2>&1 ||
      fail "the runner failed during startup recovery: $(cat "$receipt/sweep.log")"
    assert_absent "$root" "runner startup left a dead suite's pool behind (jobs=$jobs)"
  done
  pass "runner startup preserves live suites' pools and reaps them after interruption"
)

test_git_config_isolation() (
  local dir="$TMP_ROOT/git-config" helper jobs timeout fakebin rc
  mkdir -p "$dir/runner/bin" "$dir/runner/tests"
  git init -q "$dir/caller"
  git -C "$dir/caller" config commit.gpgsign false
  cd "$dir/caller" || exit 1
  cp "$ROOT/bin/fm-test-run.sh" "$ROOT/bin/fm-timeout-lib.sh" "$dir/runner/bin/"
  cp "$ROOT/tests/git-config-helpers.sh" "$ROOT/tests/treehouse-test-helpers.sh" "$dir/runner/tests/"
  cp "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-session-lock-record-lib.sh" "$dir/runner/bin/"
  fakebin=$(fm_fakebin "$dir/standalone")
  fm_fake_exit0 "$fakebin" pi
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -eu
while [ "$#" -gt 0 ]; do
  if [ "$1" = -c ]; then
    git -C "$2" log -1 --format=%s > "${FM_TEST_STANDALONE_COMMIT:?}"
    exit 1
  fi
  shift
done
SH
  chmod +x "$fakebin/tmux"
  cat > "$dir/runner/tests/fm-test-run.test.sh" <<'SH'
#!/usr/bin/env bash
set -eu
repo=$(mktemp -d "${TMPDIR:-/tmp}/fm-git-runner.XXXXXX")
trap 'rm -rf "$repo"' EXIT
git init -q "$repo"
git -C "$repo" config user.name 'Runner Fixture'
git -C "$repo" config user.email runner@example.invalid
git -C "$repo" commit -q --allow-empty -m initial
[ "$(git -C "$repo" log -1 --format='%s:%an:%ae')" = 'initial:Runner Fixture:runner@example.invalid' ]
[ "$(git -C "$repo" config --get fixture.input)" = preserved ]
[ "$(GIT_CONFIG_GLOBAL="$FM_TEST_GIT_CONFIG" git config --global --get commit.gpgsign)" = true ]
SH
  chmod +x "$dir/runner/tests/fm-test-run.test.sh"
  export GIT_CONFIG_GLOBAL="$dir/global" GIT_CONFIG_SYSTEM="$dir/system"
  export GIT_CONFIG_NOSYSTEM=0
  unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS

  # A failing signer exposes inherited config without requiring GPG or keys.
  arm_host_signing() {  # <scope>: only this layer carries the failing signer
    : > "$dir/global"
    : > "$dir/system"
    git config --file "$dir/$1" commit.gpgsign true
    git config --file "$dir/$1" gpg.format openpgp
    git config --file "$dir/$1" gpg.program /usr/bin/false
    cp "$dir/$1" "$dir/expected"
  }

  assert_helper_isolates() {  # <helper> <scope>
    bash -eus -- "$ROOT/tests/$1.sh" "$dir/$2-$1" "$dir/$2" <<'SH' || exit 1
. "$1"
fm_git_init_commit "$2"
[ "$(git -C "$2" log -1 --format=%s)" = initial ] || fail "fixture has no initial commit"
fm_git_identity
# Child Git processes and direct commits inherit the same isolation.
bash -eu -c 'git -C "$1" commit -q --allow-empty -m child' _ "$2"
# Repository-local config and explicit command inputs remain authoritative.
git -C "$2" config commit.gpgsign true
git -C "$2" config gpg.program /usr/bin/false
if git -C "$2" commit -q --allow-empty -m signed > "$2/signing.log" 2>&1; then
  fail "repository-local signing config was ignored"
fi
assert_grep 'gpg failed to sign' "$2/signing.log" "local signing was not attempted"
git -C "$2" -c commit.gpgsign=false commit -q --allow-empty -m explicit
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
  git -C "$2" commit -q --allow-empty -m environment
# A config test can deliberately supply its own global file after sourcing.
[ "$(GIT_CONFIG_GLOBAL="$3" git config --global --get commit.gpgsign)" = true ] || fail "explicit global config was ignored"
SH
  }

  assert_host_config_still_governs() {  # <scope>
    # Sourcing in test subprocesses cannot change the caller or its config files.
    [ "$(git config --"$1" --get commit.gpgsign)" = true ] || fail "caller lost signing preference"
    cmp -s "$dir/$1" "$dir/expected" || fail "host config file was changed"
    git init -q "$dir/$1-outside"
    if git -C "$dir/$1-outside" -c user.name=test -c user.email=test@example.invalid \
      commit -q --allow-empty -m outside > "$dir/outside.log" 2>&1; then
      fail "commit outside fixtures bypassed signing"
    fi
    assert_grep 'gpg failed to sign' "$dir/outside.log" "outside commit did not attempt signing"
  }

  # Every fixture entry point, once. Each only has to reach the shared helper;
  # which layers that helper neutralizes is the helper's own property, settled
  # by the system-layer case below.
  arm_host_signing global
  for helper in lib fixtures secondmate-helpers wake-helpers; do
    assert_helper_isolates "$helper" global
  done
  bash -eus -- "$ROOT/tests/herdr-test-safety.sh" "$dir/global-herdr" <<'SH' || exit 1
. "$1"
git init -q "$2"
git -C "$2" -c user.name=test -c user.email=test@example.invalid \
  commit -q --allow-empty -m initial
[ "$(git -C "$2" log -1 --format=%s)" = initial ]
SH
  for jobs in 1 2; do
    for timeout in 0 30; do
      GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=fixture.input GIT_CONFIG_VALUE_0=preserved \
        FM_TEST_GIT_CONFIG="$dir/global" \
        "$dir/runner/bin/fm-test-run.sh" --jobs "$jobs" --per-script-timeout-secs "$timeout" \
        tests/fm-test-run.test.sh > "$dir/runner.log" 2>&1 \
        || fail "runner inherited global config (jobs=$jobs, timeout=$timeout): $(cat "$dir/runner.log")"
      assert_grep 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0' "$dir/runner.log" \
        "runner did not execute the Git fixture"
    done
  done
  rc=0
  FM_SESSIONSTART_INSTRUCTION_REFRESH_LIVE_E2E=1 FM_SESSIONSTART_INSTRUCTION_REFRESH_REF=HEAD \
    FM_SESSIONSTART_INSTRUCTION_REFRESH_EXPECT=updated \
    FM_TEST_STANDALONE_COMMIT="$dir/global-standalone-commit" PATH="$fakebin:$PATH" \
    bash "$ROOT/tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh" \
    > "$dir/standalone.log" 2>&1 || rc=$?
  [ "$rc" = 1 ] || fail "standalone fixture did not stop at the tmux launch"
  assert_grep 'could not start isolated Pi session' "$dir/standalone.log" \
    "standalone fixture failed before the tmux launch: $(cat "$dir/standalone.log")"
  [ "$(cat "$dir/global-standalone-commit")" = 'test: initial instruction contract' ] \
    || fail "standalone fixture did not create its initial commit"
  bash "$ROOT/tests/fm-gitignore-config.test.sh" > "$dir/gitignore.log" 2>&1 \
    || fail "standalone gitignore fixture inherited global config: $(cat "$dir/gitignore.log")"
  assert_host_config_still_governs global

  # The system layer is the shared helper's other half: one entry point settles
  # it, and the caller still signing proves the layer was genuinely armed.
  arm_host_signing system
  assert_helper_isolates lib system
  assert_host_config_still_governs system

  pass "runner and shared helpers isolate host Git config and preserve explicit config and outside commits"
)

test_touch_epoch_preserves_repeated_dst_hour() {
  local TZ=Europe/Paris epoch path actual
  export TZ
  for epoch in 1761438600 1761442200; do
    fm_touch_epoch "$epoch" "$TMP_ROOT/epoch-one" "$TMP_ROOT/epoch two"
    for path in "$TMP_ROOT/epoch-one" "$TMP_ROOT/epoch two"; do
      actual=$(stat -c %Y "$path" 2>/dev/null || stat -f %m "$path" 2>/dev/null) \
        || fail "could not read fixture mtime for $path"
      [ "$actual" = "$epoch" ] \
        || fail "fm_touch_epoch should preserve epoch $epoch, got $actual"
    done
  done
  pass "fm_touch_epoch preserves both epochs in the repeated DST hour"
}

test_no_mistakes_version_constant() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/nm")
  fm_test_fake_no_mistakes "$fakebin"
  out=$("$fakebin/no-mistakes" --version)
  [ "$out" = "$FM_TEST_NO_MISTAKES_FAKE_VERSION" ] || \
    fail "fake no-mistakes --version should be the shared constant, got '$out'"
  out=$(FM_FAKE_NO_MISTAKES_VERSION="$FM_TEST_NO_MISTAKES_FAKE_VERSION_TS" \
    "$fakebin/no-mistakes" --version)
  [ "$out" = "$FM_TEST_NO_MISTAKES_FAKE_VERSION_TS" ] || \
    fail "timestamped banner override should round-trip, got '$out'"
  case "$out" in
    "$FM_TEST_NO_MISTAKES_FAKE_VERSION "*) ;;
    *) fail "timestamped banner '$out' is not the shared constant plus a suffix" ;;
  esac
  out=$(FM_FAKE_NO_MISTAKES_VERSION='no-mistakes version v9.9.9 (fake)' \
    "$fakebin/no-mistakes" --version)
  [ "$out" = 'no-mistakes version v9.9.9 (fake)' ] || \
    fail "FM_FAKE_NO_MISTAKES_VERSION should override the default banner, got '$out'"
  "$fakebin/no-mistakes" doctor
  expect_code 0 $? "fake no-mistakes non-version verbs should exit 0"
  pass "fake no-mistakes --version is the shared constant and overridable"
}

test_no_mistakes_init_doctor_markers() {
  local fakebin dir rc
  dir="$TMP_ROOT/nm-init"
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  fm_test_fake_no_mistakes_init_doctor "$fakebin"
  ( cd "$dir" && "$fakebin/no-mistakes" init )
  assert_present "$dir/.no-mistakes-init" "init did not touch the marker"
  ( cd "$dir" && "$fakebin/no-mistakes" doctor )
  assert_present "$dir/.no-mistakes-doctor" "doctor did not touch the marker"
  rc=0
  ( cd "$dir" && "$fakebin/no-mistakes" axi ) || rc=$?
  expect_code 2 "$rc" "unknown no-mistakes verb should exit 2"
  pass "init/doctor no-mistakes stub touches markers and refuses other verbs"
}

test_fake_gh_and_gh_axi() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/gh")
  fm_test_fake_gh "$fakebin"
  fm_test_fake_gh_axi "$fakebin"
  "$fakebin/gh" auth status
  expect_code 0 $? "fake gh auth status should succeed"
  "$fakebin/gh" pr list
  expect_code 0 $? "fake gh other verbs should exit 0"
  out=$("$fakebin/gh-axi" --version)
  [ "$out" = "$FM_TEST_GH_AXI_VERSION" ] || \
    fail "fake gh-axi --version should be $FM_TEST_GH_AXI_VERSION, got '$out'"
  out=$(FM_FAKE_GH_AXI_VERSION=0.9.9 "$fakebin/gh-axi" --version)
  [ "$out" = 0.9.9 ] || fail "FM_FAKE_GH_AXI_VERSION should override, got '$out'"
  pass "fake gh authenticates and fake gh-axi reports the shared version"
}

test_spawn_tmux_and_fakebin() {
  local fakebin out log
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn" gh-axi)
  log="$TMP_ROOT/spawn/launch.log"
  : > "$log"
  out=$(FM_FAKE_PANE_PATH=/tmp/wt "$fakebin/tmux" display-message -p '#{pane_current_path}')
  [ "$out" = /tmp/wt ] || fail "spawn tmux pane path should be FM_FAKE_PANE_PATH, got '$out'"
  out=$(unset FM_FAKE_PANE_PATH; "$fakebin/tmux" display-message -p '#{pane_current_path}')
  [ -z "$out" ] || fail "spawn tmux pane path should default to empty, got '$out'"
  out=$("$fakebin/tmux" display-message -p '#S')
  [ "$out" = firstmate ] || fail "spawn tmux session name should be firstmate, got '$out'"
  FM_FAKE_LAUNCH_LOG="$log" "$fakebin/tmux" send-keys -t @w -l 'codex --yolo'
  assert_grep 'codex --yolo' "$log" "send-keys -l payload was not logged"
  [ -x "$fakebin/treehouse" ] || fail "spawn fakebin should include treehouse"
  [ -x "$fakebin/gh-axi" ] || fail "extra exit-0 tools should land in the spawn fakebin"
  "$fakebin/treehouse" get
  expect_code 0 $? "fake treehouse should exit 0"
  pass "spawn fakebin answers pane path, logs -l payloads, and installs extra tools"
}

test_spawn_fixture_tracks_only_task_temp_roots() {
  local fakebin task_tmp scratch
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/task-tmp")
  task_tmp=$("$fakebin/mktemp" -d /tmp/fm-fixture-task+XXXXXX) || fail "could not allocate a task root"
  if ! grep -Fxq -- "$task_tmp" "$FM_TEST_CLEANUP_REGISTRY"; then
    FM_TEST_CLEANUP_DIRS+=("$task_tmp")
    fail "the exact task root was not registered"
  fi
  scratch=$("$fakebin/mktemp" -d /tmp/fm-fixture-bootstrap.XXXXXX) || fail "could not allocate a scratch directory"
  FM_TEST_CLEANUP_DIRS+=("$scratch")
  [ -d "$task_tmp" ] && [ -d "$scratch" ] || fail "the shim did not create both directories"
  if grep -Fxq -- "$scratch" "$FM_TEST_CLEANUP_REGISTRY"; then
    fail "the unrelated scratch directory entered the task root registry"
  fi
  pass "spawn fixtures register only exact task temp allocations"
}

test_send_stubs_and_ssh() {
  local fakebin log ssh_log out
  fakebin=$(make_stubs "$TMP_ROOT/send")
  log="$TMP_ROOT/send/send.log"
  ssh_log="$TMP_ROOT/send/ssh.log"
  : > "$log"
  fm_test_fake_ssh "$fakebin"
  FM_SEND_LOG="$log" "$fakebin/tmux" send-keys -t sess:w -l 'hello steer'
  assert_grep 'hello steer' "$log" "send stubs did not log the -l payload"
  out=$("$fakebin/tmux" display-message -p '#{cursor_y}')
  [ "$out" = 1 ] || fail "send tmux cursor_y should be 1, got '$out'"
  out=$("$fakebin/tmux" capture-pane -p)
  case "$out" in
    *'╭────╮'*) ;;
    *) fail "send tmux capture-pane should render an empty composer, got '$out'" ;;
  esac
  printf 'ignored\n' | FM_SSH_LOG="$ssh_log" "$fakebin/fake-ssh" host -- cmd
  assert_grep 'host -- cmd' "$ssh_log" "fake ssh did not record argv"
  FM_FAKE_SSH_RC=7 "$fakebin/fake-ssh" x < /dev/null
  expect_code 7 $? "fake ssh should honor FM_FAKE_SSH_RC"
  pass "send stubs log typed text and fake ssh records argv with a controllable exit"
}

test_spawn_home_layout() {
  local home="$TMP_ROOT/home"
  fm_test_spawn_home "$home" claude
  fm_test_spawn_brief "$home" t1 'do the thing'
  assert_present "$home/data" "spawn home missing data/"
  assert_present "$home/state/.last-watcher-beat" "spawn home missing watcher beat"
  assert_grep claude "$home/config/crew-harness" "crew-harness was not pinned"
  assert_grep 'do the thing' "$home/data/t1/brief.md" "brief text was not written"
  pass "spawn-home layout writes harness pin, beat, and brief"
}

test_runner_isolates_treehouse || fail "Treehouse fixture isolation"
test_git_config_isolation || fail "Git fixture config isolation"
test_touch_epoch_preserves_repeated_dst_hour
test_no_mistakes_version_constant
test_no_mistakes_init_doctor_markers
test_fake_gh_and_gh_axi
test_spawn_tmux_and_fakebin
test_spawn_fixture_tracks_only_task_temp_roots
test_send_stubs_and_ssh
test_spawn_home_layout
