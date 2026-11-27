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

TMP_ROOT=$(fm_test_tmproot fm-treehouse-scratch)
FAKE_HOME="$TMP_ROOT/home"
mkdir -p "$FAKE_HOME/.config"

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
}

test_runner_leaves_real_root_untouched() {
  local repo="$TMP_ROOT/runner" seen="$TMP_ROOT/runner-seen" log="$TMP_ROOT/runner.log" root
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$ROOT/bin/fm-test-run.sh" "$ROOT/bin/fm-timeout-lib.sh" "$ROOT/bin/fm-treehouse-scratch.sh" "$repo/bin/"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  # The fixture suite records the root it was given and, when Treehouse is
  # installed, allocates a real pool slot from a fixture repository.
  cat > "$repo/tests/fm-test-run.test.sh" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "${TREEHOUSE_ROOT:-}" >> "$FM_TEST_SEEN"
[ -n "${TREEHOUSE_ROOT:-}" ] && [ -f "$TREEHOUSE_ROOT/.fm-treehouse-scratch" ]
if command -v treehouse >/dev/null 2>&1; then
  proj=$(mktemp -d "${TMPDIR:-/tmp}/fm-scratch-proj.XXXXXX")
  trap 'rm -rf "$proj"' EXIT
  git init -q -b main "$proj"
  git -C "$proj" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
  (cd "$proj" && SHELL=/bin/true treehouse get --no-fetch </dev/null >/dev/null 2>&1)
  ls "$TREEHOUSE_ROOT/.treehouse" | grep -q '^fm-scratch-proj'
fi
SH
  cp "$repo/tests/fm-test-run.test.sh" "$repo/tests/fm-test-isolation-proof.test.sh"
  for jobs in 1 2; do
    : > "$seen"
    as_operator FM_TEST_SEEN="$seen" "$repo/bin/fm-test-run.sh" --jobs "$jobs" \
      tests/fm-test-run.test.sh tests/fm-test-isolation-proof.test.sh > "$log" 2>&1 \
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
  as_operator TREEHOUSE_ROOT="$real" FM_TEST_SEEN="$seen" "$repo/bin/fm-test-run.sh" \
    tests/fm-test-run.test.sh > "$log" 2>&1 || fail "override run failed: $(cat "$log")"
  [ "$(cat "$seen")" != "$real" ] || fail "runner passed an inherited real TREEHOUSE_ROOT through"
  [ -z "$(ls -A "$real")" ] || fail "inherited real root gained entries: $(ls -A "$real")"
  pass "fm-test-run.sh replaces an inherited real TREEHOUSE_ROOT"
}

test_lib_standalone_and_inherited() {
  local out root real="$TMP_ROOT/lib-real" active
  mkdir -p "$real"
  out=$(as_operator TREEHOUSE_ROOT="$real" bash -c '. "$1"; printf "%s\n" "$TREEHOUSE_ROOT"; [ -f "$TREEHOUSE_ROOT/.fm-treehouse-scratch" ]' _ "$ROOT/tests/lib.sh") \
    || fail "tests/lib.sh did not enter a scratch root"
  root=$out
  [ "$root" != "$real" ] || fail "tests/lib.sh kept an inherited real TREEHOUSE_ROOT"
  assert_absent "$root" "tests/lib.sh did not remove its scratch root at exit"
  [ -z "$(ls -A "$real")" ] || fail "tests/lib.sh wrote into the inherited real root"

  # An active scratch root, such as the runner's, is kept and left for its creator.
  active=$(. "$ROOT/bin/fm-treehouse-scratch.sh"; fm_treehouse_scratch_create "$TMP_ROOT")
  out=$(env TREEHOUSE_ROOT="$active" FM_TREEHOUSE_SCRATCH_ROOT="$active" \
    bash -c '. "$1"; printf "%s\n" "$TREEHOUSE_ROOT"' _ "$ROOT/tests/lib.sh") \
    || fail "tests/lib.sh failed under an active scratch root"
  assert_equals "$active" "$out" "tests/lib.sh must keep an active scratch root"
  assert_present "$active/.fm-treehouse-scratch" "tests/lib.sh removed a scratch root it did not create"
  pass "tests/lib.sh enters and removes its own scratch root, and keeps an active one"
}

test_reproduction_helper() {
  local out rc root unmarked="$TMP_ROOT/unmarked"
  out=$(as_operator "$ROOT/bin/fm-treehouse-scratch.sh" run bash -c 'printf "%s\n" "$TREEHOUSE_ROOT"; exit 7') && rc=0 || rc=$?
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

test_runner_leaves_real_root_untouched
test_runner_overrides_an_inherited_real_root
test_lib_standalone_and_inherited
test_reproduction_helper
