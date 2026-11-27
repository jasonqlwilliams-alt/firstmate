#!/usr/bin/env bash
# tests/fm-treehouse-scratch.test.sh - tests and reproductions never create
# Treehouse pool folders under the real root (bin/fm-treehouse-scratch.sh).
#
# The "real" root here is a fake HOME's default Treehouse root, so a regression
# can only ever write into this suite's own temp directory.

# Child shells below expand their own variables.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v treehouse >/dev/null || { echo 'skip: treehouse not found'; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-treehouse-scratch)
FAKE_HOME="$TMP_ROOT/home"
USER_ROOT="$TMP_ROOT/configured-user-root"
REPO_ROOT="$TMP_ROOT/configured-repo-root"
mkdir -p "$FAKE_HOME/.config/treehouse" "$USER_ROOT" "$REPO_ROOT"
printf 'root = "%s"\nworktree_path = "%s"\n' "$USER_ROOT" "$FAKE_HOME/.treehouse/user-{repo}-{slot}" \
  > "$FAKE_HOME/.config/treehouse/config.toml"

# Run a command as if from an operator shell: no inherited scratch root, and a
# HOME whose default Treehouse root is the one that must stay untouched.
as_operator() {
  env -u TREEHOUSE_ROOT -u FM_TREEHOUSE_SCRATCH_ROOT HOME="$FAKE_HOME" \
    XDG_CONFIG_HOME="$FAKE_HOME/.config" "$@"
}

# Treehouse keeps its own update-check cache under HOME's root whatever root a
# pool uses, so that one file is not a pool; anything else there is.
assert_no_pools() {  # <who>
  local extra
  extra=$(find "$FAKE_HOME/.treehouse" -mindepth 1 ! -name update-check.json 2>/dev/null)
  [ -z "$extra" ] || fail "$1 created pool folders under the real Treehouse root: $extra"
  [ -z "$(ls -A "$USER_ROOT")" ] || fail "$1 wrote into the configured user root"
  [ -z "$(ls -A "$REPO_ROOT")" ] || fail "$1 wrote into the configured repository root"
}

test_runner_leaves_real_root_untouched() {
  local repo="$TMP_ROOT/runner" seen="$TMP_ROOT/runner-seen" log="$TMP_ROOT/runner.log" root jobs rendezvous
  mkdir -p "$repo/bin" "$repo/tests" "$TMP_ROOT/rendezvous"
  cp "$ROOT/bin/fm-test-run.sh" "$ROOT/bin/fm-timeout-lib.sh" "$ROOT/bin/fm-treehouse-scratch.sh" "$repo/bin/"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  # The fixture suite records its root and allocates a real slot.
  cat > "$repo/tests/fm-test-run.test.sh" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "${TREEHOUSE_ROOT:-}" >> "$FM_TEST_SEEN"
[ -n "${TREEHOUSE_ROOT:-}" ] && [ -f "$TREEHOUSE_ROOT/.fm-treehouse-scratch" ]
proj=$(mktemp -d "${TMPDIR:-/tmp}/fm-scratch-proj.XXXXXX")
trap 'rm -rf "$proj"' EXIT
git init -q -b main "$proj"
git -C "$proj" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
printf 'root = "%s"\nworktree_path = "%s"\n' "$FM_CONFIGURED_REPO_ROOT" "$HOME/.treehouse/repo-{repo}-{slot}" > "$proj/treehouse.toml"
path=$(cd "$proj" && treehouse get --lease --lease-holder fixture)
case "$path" in "$TREEHOUSE_ROOT"/*) [ -d "$path" ] ;; *) exit 1 ;; esac
if [ -n "$FM_TEST_RENDEZVOUS" ]; then
  : > "$FM_TEST_RENDEZVOUS/${0##*/}"
  for ((attempt=0; attempt<200; attempt++)); do
    if [ -f "$FM_TEST_RENDEZVOUS/fm-test-run.test.sh" ] &&
      [ -f "$FM_TEST_RENDEZVOUS/fm-brief.test.sh" ]; then
      exit 0
    fi
    sleep 0.05
  done
  echo 'fixture workers did not run concurrently' >&2
  exit 1
fi
SH
  cp "$repo/tests/fm-test-run.test.sh" "$repo/tests/fm-brief.test.sh"
  for jobs in 1 2; do
    : > "$seen"
    rendezvous=
    [ "$jobs" -ne 2 ] || rendezvous="$TMP_ROOT/rendezvous"
    as_operator FM_TEST_RENDEZVOUS="$rendezvous" FM_TEST_SEEN="$seen" FM_CONFIGURED_REPO_ROOT="$REPO_ROOT" \
      "$repo/bin/fm-test-run.sh" --jobs "$jobs" tests/fm-test-run.test.sh tests/fm-brief.test.sh > "$log" 2>&1 \
      || fail "runner suite failed under a scratch root (jobs=$jobs): $(cat "$log")"
    assert_grep 'failed=0' "$log" "runner did not run the fixture suite (jobs=$jobs)"
    [ "$(sort -u "$seen" | wc -l)" -eq 2 ] \
      || fail "each suite run must get its own scratch root (jobs=$jobs): $(cat "$seen")"
    while IFS= read -r root; do
      case "$root" in
        "$FAKE_HOME"/*|'') fail "suite ran against the real root: '$root'" ;;
      esac
      assert_absent "$root" "scratch root $root survived the run (jobs=$jobs)"
    done < "$seen"
    assert_no_pools "runner suite (jobs=$jobs)"
  done
  pass "fm-test-run.sh gives each suite its own scratch root and removes it; the real root is untouched"
}

test_runner_overrides_an_inherited_real_root() {
  local repo="$TMP_ROOT/runner" seen="$TMP_ROOT/override-seen" log="$TMP_ROOT/override.log" real="$TMP_ROOT/real-root"
  mkdir -p "$real"
  : > "$seen"
  as_operator TREEHOUSE_ROOT="$real" TREEHOUSE_WORKTREE_PATH="$real/env-{repo}-{slot}" \
    FM_TEST_RENDEZVOUS= FM_TEST_SEEN="$seen" FM_CONFIGURED_REPO_ROOT="$REPO_ROOT" "$repo/bin/fm-test-run.sh" \
    tests/fm-test-run.test.sh > "$log" 2>&1 || fail "override run failed: $(cat "$log")"
  [ "$(cat "$seen")" != "$real" ] || fail "runner passed an inherited real TREEHOUSE_ROOT through"
  [ -z "$(ls -A "$real")" ] || fail "inherited real root gained entries: $(ls -A "$real")"
  pass "fm-test-run.sh replaces an inherited real TREEHOUSE_ROOT"
}

test_runner_reports_cleanup_failure() {
  local repo="$TMP_ROOT/runner" out
  printf '%s\n' '#!/usr/bin/env bash' 'rm "$TREEHOUSE_ROOT/.fm-treehouse-scratch"' > "$repo/tests/fm-test-isolation-proof.test.sh"
  if out=$(as_operator "$repo/bin/fm-test-run.sh" --jobs 1 tests/fm-test-isolation-proof.test.sh 2>&1); then
    fail "runner passed a suite whose scratch cleanup was refused"
  fi
  assert_contains "$out" 'total=1 failed=1' "scratch cleanup failure is counted"
  pass "scratch cleanup failure turns a passing suite into a failure"
}

test_lib_standalone_and_inherited() {
  local out root real="$TMP_ROOT/lib-real" active
  mkdir -p "$real"
  out=$(as_operator TREEHOUSE_ROOT="$real" bash -ec '
    . "$1"
    mkdir -p "$TREEHOUSE_ROOT/readonly/sub"
    : > "$TREEHOUSE_ROOT/readonly/sub/file"
    chmod u-w "$TREEHOUSE_ROOT/readonly"
    printf "%s\n" "$TREEHOUSE_ROOT"
  ' _ "$ROOT/tests/lib.sh") \
    || fail "tests/lib.sh did not enter a scratch root"
  root=$out
  [ "$root" != "$real" ] || fail "tests/lib.sh kept an inherited real TREEHOUSE_ROOT"
  assert_absent "$root" "tests/lib.sh did not remove its scratch root at exit"
  [ -z "$(ls -A "$real")" ] || fail "tests/lib.sh wrote into the inherited real root"

  # An active scratch root, such as the runner's, is kept and left for its creator.
  active=$(fm_treehouse_scratch_create "$TMP_ROOT") || fail "could not create an inherited scratch root"
  fm_test_track_treehouse_scratch "$active" || fail "could not register the inherited scratch root"
  out=$(env TREEHOUSE_ROOT="$active" FM_TREEHOUSE_SCRATCH_ROOT="$active" \
    bash -c '. "$1"; printf "%s\n" "$TREEHOUSE_ROOT"' _ "$ROOT/tests/lib.sh") \
    || fail "tests/lib.sh failed under an active scratch root"
  assert_equals "$active" "$out" "tests/lib.sh must keep an active scratch root"
  assert_present "$active/.fm-treehouse-scratch" "tests/lib.sh removed a scratch root it did not create"
  pass "tests/lib.sh enters and removes its own scratch root, and keeps an active one"
}

test_reproduction_helper() {
  local out rc root unmarked="$TMP_ROOT/unmarked" project="$TMP_ROOT/repro-project"
  fm_git_init_commit "$project"
  out=$(as_operator "$ROOT/bin/fm-treehouse-scratch.sh" run bash -c '
    path=$(cd "$1" && TREEHOUSE_ROOT="$2" treehouse get --lease --lease-holder fixture) || exit 1
    case "$path" in "$TREEHOUSE_ROOT"/*) [ -d "$path" ] || exit 1 ;; *) exit 1 ;; esac
    printf "%s\n" "$TREEHOUSE_ROOT"; exit 7
  ' _ "$project" "$USER_ROOT") && rc=0 || rc=$?
  expect_code 7 "$rc" "run must propagate the command's exit status"
  root=$out
  case "$root" in "$FAKE_HOME"/*|'') fail "run used the real root: '$root'" ;; esac
  assert_absent "$root" "run left its scratch root behind"
  assert_no_pools "fm-treehouse-scratch.sh run"

  mkdir -p "$unmarked"
  : > "$unmarked/keep"
  out=$(. "$ROOT/bin/fm-treehouse-scratch.sh"; fm_treehouse_scratch_remove "$unmarked" 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "remove must refuse a directory without the scratch marker"
  assert_present "$unmarked/keep" "remove deleted an unmarked directory"
  pass "fm-treehouse-scratch.sh run isolates a reproduction and removal refuses unmarked directories"
}

test_dollar_sign_root_is_refused() {
  local wrapper="$ROOT/bin/fm-treehouse-scratch.sh" bad="$TMP_ROOT/build\$LABEL" alias="$TMP_ROOT/parent-link" parent root out
  mkdir "$bad"
  ln -s "$bad" "$alias"
  for parent in "$bad" "$alias"; do
    if out=$(as_operator TMPDIR="$parent" "$wrapper" run true 2>&1); then
      fail "scratch creation accepted a dollar sign in its parent path"
    fi
    assert_contains "$out" 'scratch paths cannot contain a dollar sign' "scratch parent refusal"
    [ -z "$(ls -A "$bad")" ] || fail "scratch creation left a directory in the refused parent"
  done
  root=$(fm_treehouse_scratch_create "$TMP_ROOT") || fail "could not create a fixture root for the reuse check"
  mv "$root" "$bad/owned" || fail "could not move the fixture root"
  root="$bad/owned"
  fm_test_track_treehouse_scratch "$root" || fail "could not register the moved scratch root"
  if out=$(as_operator TREEHOUSE_ROOT="$root" FM_TREEHOUSE_SCRATCH_ROOT="$root" "$wrapper" run true 2>&1); then
    fail "scratch setup reused a root with a dollar sign"
  fi
  assert_contains "$out" 'scratch paths cannot contain a dollar sign' "scratch reuse refusal"
  if out=$(as_operator "$root/bin/treehouse" --version 2>&1); then
    fail "scratch shim delegated from a root with a dollar sign"
  fi
  assert_contains "$out" 'scratch paths cannot contain a dollar sign' "scratch invocation refusal"
  pass "scratch root creation and reuse refuse paths Treehouse would expand"
}

test_cleanup_preserves_linked_object_permissions() {
  local source="$TMP_ROOT/gitrepo" wrapper="$ROOT/bin/fm-treehouse-scratch.sh" object oid rel mode root
  fm_git_init_commit "$source"
  oid=$(git -C "$source" rev-parse HEAD) || fail "could not find the fixture commit"
  rel=".git/objects/${oid:0:2}/${oid:2}"
  object="$source/$rel"
  chmod 0444 "$object" || fail "could not make the source Git object read-only"
  mode=$(LC_ALL=C ls -ld "$object" | cut -c1-10)
  root=$(as_operator TMPDIR="$TMP_ROOT" "$wrapper" run bash -ec '
    git clone --local -q "$1" "$TREEHOUSE_ROOT/clone"
    test "$1/$2" -ef "$TREEHOUSE_ROOT/clone/$2"
    mkdir "$TREEHOUSE_ROOT/clone/readonly"
    : > "$TREEHOUSE_ROOT/clone/readonly/file"
    chmod u-w "$TREEHOUSE_ROOT/clone/readonly"
    printf "%s\n" "$TREEHOUSE_ROOT"
  ' _ "$source" "$rel") || fail "could not create and clean up the hardlinked clone"
  assert_absent "$root" "scratch cleanup left the read-only checkout content"
  assert_equals "$mode" "$(LC_ALL=C ls -ld "$object" | cut -c1-10)" "scratch cleanup changed the source Git object mode"
  pass "scratch cleanup removes read-only directories and preserves hardlinked Git objects"
}

test_allocation_rejects_external_locations() {
  local wrapper="$ROOT/bin/fm-treehouse-scratch.sh" project="$TMP_ROOT/flag-project" option out
  local -a args
  fm_git_init_commit "$project"
  for option in root-split root-equals path-split path-equals; do
    case "$option" in
      root-split) args=(--root "$FAKE_HOME" get --lease) ;;
      root-equals) args=(get --lease "--root=$FAKE_HOME") ;;
      path-split) args=(get --lease --worktree-path "$FAKE_HOME/.treehouse/{repo}-{slot}") ;;
      path-equals) args=(get --lease "--worktree-path=$FAKE_HOME/.treehouse/{repo}-{slot}") ;;
    esac
    if out=$(cd "$project" && as_operator "$wrapper" run treehouse "${args[@]}" 2>&1); then
      fail "Treehouse accepted an external location ($option)"
    fi
    assert_contains "$out" "fm-treehouse-scratch: use the scratch" "location refusal ($option)"
  done
  (cd "$project" && as_operator "$wrapper" run bash -ec '
    path=$(treehouse --root "$TREEHOUSE_ROOT" get --lease --worktree-path={pool}/{slot}/{repo})
    test -d "$path"
  ') || fail "explicit scratch locations were refused"
  assert_no_pools "explicit location checks"
  pass "explicit Treehouse flags cannot redirect allocations outside the scratch root"
}

test_return_refuses_an_external_worktree() {
  local wrapper="$ROOT/bin/fm-treehouse-scratch.sh" project="$TMP_ROOT/2026" live_root slot out
  fm_git_init_commit "$project"
  live_root=$(fm_treehouse_scratch_create "$TMP_ROOT") || fail "could not create a second fixture pool"
  fm_test_track_treehouse_scratch "$live_root" || fail "could not register the second fixture pool"
  slot=$(cd "$project" && as_operator "$live_root/bin/treehouse" get --lease) || fail "could not allocate an external fixture slot"
  printf 'preserve\n' > "$slot/dirty"
  ln -s "$slot" "$project/linked-slot" || fail "could not alias the external fixture slot"

  if out=$(cd "$project" && as_operator TREEHOUSE_DIR="$slot" "$wrapper" run treehouse return --force 2>&1); then
    fail "return used an inherited checkout from another pool"
  fi
  assert_contains "$out" "return requires a path inside the scratch root" "inherited checkout refusal"
  if out=$(cd "$slot" && as_operator TREEHOUSE_DIR= "$wrapper" run treehouse return --force 2>&1); then
    fail "return used a checkout from another pool via cwd"
  fi
  assert_contains "$out" "return requires a path inside the scratch root" "cwd checkout refusal"
  if out=$(cd "$project" && as_operator "$wrapper" run treehouse return --force -- linked-slot 2>&1); then
    fail "return followed a symlink to another pool"
  fi
  assert_contains "$out" "return requires a path inside the scratch root" "explicit checkout refusal"
  assert_equals preserve "$(cat "$slot/dirty")" "return changed the external checkout"

  (cd "$project" && as_operator "$wrapper" run bash -ec '
    slot=$(treehouse get --lease --lease-holder fixture)
    : > "$slot/dirty"
    TREEHOUSE_DIR="$slot" treehouse return --force --if-lease-holder fixture
    test ! -e "$slot/dirty"
  ') || fail "return did not clean the scratch checkout"
  mv "$slot" "$slot-moved" || fail "could not simulate a missing leased checkout"
  if out=$(cd "${slot%/*}" && as_operator "$wrapper" run treehouse return --force 2026 2>&1); then
    fail "return accepted a missing numeric checkout outside the scratch root"
  fi
  assert_contains "$out" "return requires a path inside the scratch root" "numeric checkout refusal"
  jq -e --arg slot "$slot" '.worktrees | any(.[]; .path == $slot and .leased == true)' \
    "${slot%/*/*}/treehouse-state.json" >/dev/null || fail "return changed the missing checkout lease"
  pass "return can clean its own checkout while preserving external slots"
}

test_destroy_is_refused() {
  local out
  if out=$(as_operator "$ROOT/bin/fm-treehouse-scratch.sh" run treehouse destroy --help 2>&1); then
    fail "scratch wrapper delegated destroy"
  fi
  assert_contains "$out" 'destroy is unavailable in scratch runs' "destroy refusal"
  pass "scratch wrapper refuses destroy before delegation"
}

test_old_treehouse_is_refused_at_invocation() {
  local fake_bin="$TMP_ROOT/old-bin" repo="$TMP_ROOT/runner" out
  local FM_TEST_OLD_PROBED="$TMP_ROOT/old-probed" FM_TEST_OLD_CALLED="$TMP_ROOT/old-called"
  local FM_TEST_UNRELATED_RAN="$TMP_ROOT/unrelated-ran"
  export FM_TEST_OLD_PROBED FM_TEST_OLD_CALLED FM_TEST_UNRELATED_RAN
  mkdir -p "$fake_bin"
  cat > "$fake_bin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "$1" = --version ]; then
  : > "$FM_TEST_OLD_PROBED"
  printf 'v2.0.1\n'
else
  : > "$FM_TEST_OLD_CALLED"
fi
SH
  chmod +x "$fake_bin/treehouse"
  printf '%s\n' '#!/usr/bin/env bash' 'touch "$FM_TEST_UNRELATED_RAN"' > "$repo/tests/fm-test-isolation-proof.test.sh"
  as_operator PATH="$fake_bin:$PATH" "$repo/bin/fm-test-run.sh" tests/fm-test-isolation-proof.test.sh \
    || fail "old Treehouse blocked a runner suite that did not call it"
  assert_present "$FM_TEST_UNRELATED_RAN" "unrelated runner suite did not execute"
  as_operator PATH="$fake_bin:$PATH" bash -ec '. "$1"; test -d "$TREEHOUSE_ROOT"' _ "$ROOT/tests/lib.sh" \
    || fail "old Treehouse blocked direct fixture setup"
  as_operator PATH="$fake_bin:$PATH" "$ROOT/bin/fm-treehouse-scratch.sh" run true \
    || fail "old Treehouse blocked a reproduction that did not call it"
  assert_absent "$FM_TEST_OLD_PROBED" "scratch setup probed Treehouse without an invocation"

  if out=$(as_operator PATH="$fake_bin:$PATH" "$ROOT/bin/fm-treehouse-scratch.sh" \
    run "$ROOT/bin/fm-treehouse-scratch.sh" run treehouse get --lease 2>&1); then
    fail "a nested reproduction ran an incompatible Treehouse"
  fi
  assert_contains "$out" "found v2.0.1" "invocation explains the incompatible tool"
  assert_present "$FM_TEST_OLD_PROBED" "Treehouse was not checked at invocation"
  assert_absent "$FM_TEST_OLD_CALLED" "the old Treehouse received an allocation command"
  if out=$(as_operator "$ROOT/bin/fm-treehouse-scratch.sh" run -- "$fake_bin/treehouse" get --lease 2>&1); then
    fail "reproduction ran a direct Treehouse binary"
  fi
  assert_contains "$out" "invoke treehouse by name" "direct binary refusal"
  assert_absent "$FM_TEST_OLD_CALLED" "a direct Treehouse binary received an allocation command"
  pass "older Treehouse leaves unrelated commands runnable and refuses allocation"
}

test_standalone_herdr_fixture_owns_root() {
  local fixture="$TMP_ROOT/herdr-fixture" root
  mkdir -p "$fixture"
  root=$(as_operator bash -ec '
    . "$1"
    herdr_treehouse_scratch "$2"
    mkdir -p "$TREEHOUSE_ROOT/readonly/sub"
    : > "$TREEHOUSE_ROOT/readonly/sub/file"
    chmod u-w "$TREEHOUSE_ROOT/readonly"
    printf "%s\n" "$TREEHOUSE_ROOT"
    herdr_treehouse_scratch_cleanup
  ' _ "$ROOT/tests/herdr-test-safety.sh" "$fixture") || fail "standalone Herdr scratch setup failed"
  case "$root" in "$fixture"/*) ;; *) fail "Herdr scratch root escaped its fixture: $root" ;; esac
  assert_absent "$root" "Herdr scratch root survived fixture cleanup"
  pass "standalone Herdr scratch is owned by the fixture directory"
}

test_runner_leaves_real_root_untouched
test_runner_overrides_an_inherited_real_root
test_runner_reports_cleanup_failure
test_lib_standalone_and_inherited
test_reproduction_helper
test_dollar_sign_root_is_refused
test_cleanup_preserves_linked_object_permissions
test_allocation_rejects_external_locations
test_return_refuses_an_external_worktree
test_destroy_is_refused
test_old_treehouse_is_refused_at_invocation
test_standalone_herdr_fixture_owns_root
