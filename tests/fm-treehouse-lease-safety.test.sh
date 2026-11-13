#!/usr/bin/env bash
# Real Treehouse allocation with a fake terminal; no harness CLI is executed.
# A recorded slot must remain leased after shell exit. A lost/legacy lease must
# refuse before get can reset a slot, across registered local homes too.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
command -v treehouse >/dev/null || { echo 'skip: treehouse not found'; exit 0; }
TREEHOUSE_BIN=$(command -v treehouse)
TMP_ROOT=$(fm_test_tmproot fm-treehouse-lease-safety)
trap fm_test_cleanup EXIT
mkdir -p "$TMP_ROOT/home" "$TMP_ROOT/user" "$TMP_ROOT/state"
HOME_DIR="$TMP_ROOT/home"
PROJECT="$TMP_ROOT/project"
fm_git_init_commit "$PROJECT"
fm_test_spawn_home "$HOME_DIR" codex
printf 'tmux\n' > "$HOME_DIR/config/backend"
FAKEBIN=$(make_spawn_fakebin "$TMP_ROOT/fake")
export TREEHOUSE_ROOT="$TMP_ROOT/pool" XDG_CONFIG_HOME="$TMP_ROOT/user/.config" XDG_STATE_HOME="$TMP_ROOT/state"
export FM_TEST_REAL_TREEHOUSE="$TREEHOUSE_BIN" FM_TEST_CWD="$TMP_ROOT/cwd" FM_TEST_PROJECT="$PROJECT" FM_TEST_TREEHOUSE_CALLS="$TMP_ROOT/treehouse-calls"
# The shell used by the initial legacy get exits immediately, leaving no
# process-based protection. Every later acquisition comes from real fm-spawn.
cat > "$TMP_ROOT/shell" <<'EOF'
#!/usr/bin/env bash
pwd > "$FM_TEST_CWD"
EOF
chmod +x "$TMP_ROOT/shell"
(cd "$PROJECT" && HOME="$TMP_ROOT/user" SHELL="$TMP_ROOT/shell" "$TREEHOUSE_BIN" get --no-fetch) >/dev/null || fail 'could not allocate legacy fixture'
SLOT=$(cat "$FM_TEST_CWD")
# Keep the existing fake terminal mechanics, but execute only allocation shell
# commands. Capturing the resulting cwd proves we entered the allocated copy.
mv "$FAKEBIN/tmux" "$FAKEBIN/tmux-fixture"
cat > "$FAKEBIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'#{pane_current_path}'*) cat "$FM_TEST_CWD"; exit 0 ;;
esac
if [ "${1:-}" = send-keys ]; then
  for arg in "$@"; do
    case "$arg" in
      *'treehouse get'*)
        (cd "$FM_TEST_PROJECT" && eval "$arg" && pwd > "$FM_TEST_CWD") || exit 1
        ;;
    esac
  done
fi
exec "$(dirname "$0")/tmux-fixture" "$@"
EOF
cat > "$FAKEBIN/treehouse" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_TREEHOUSE_CALLS"
exec "$FM_TEST_REAL_TREEHOUSE" "$@"
EOF
chmod +x "$FAKEBIN/tmux" "$FAKEBIN/treehouse"
run_spawn() {
  local id=$1
  fm_test_spawn_brief "$HOME_DIR" "$id"
  printf '%s\n' "$PROJECT" > "$FM_TEST_CWD"
  fm_test_run_spawn "$HOME_DIR" "$SLOT" "$FAKEBIN" "$id" "$PROJECT" --scout --backend tmux
}
out=$(run_spawn first); rc=$?
expect_code 0 "$rc" "durable spawn failed: $out"
[ "$(cat "$FM_TEST_CWD")" = "$SLOT" ] || fail 'spawn did not enter its leased slot'
POOL_STATE="${SLOT%/*}/../treehouse-state.json"
jq -e --arg slot "$SLOT" '.worktrees | any(.[]; .path == $slot and .leased == true)' "$POOL_STATE" >/dev/null || fail 'spawn left only process-based protection'
next=$(cd "$PROJECT" && HOME="$TMP_ROOT/user" "$TREEHOUSE_BIN" get --lease --no-fetch --lease-holder next) || fail 'counterfactual durable get failed'
[ "$next" != "$SLOT" ] || fail 'Treehouse reused the durable slot after the stub shell exited'
pass 'durable spawn acquisition survives shell exit and is excluded by real Treehouse'
# Simulate the observed legacy/lost lease in isolated state only.
jq --arg slot "$SLOT" '(.worktrees[] | select(.path == $slot)) |= (.leased = false | del(.lease_id,.lease_holder,.leased_at))' "$POOL_STATE" > "$TMP_ROOT/state-next"
mv "$TMP_ROOT/state-next" "$POOL_STATE"
printf 'uncommitted work must survive\n' > "$SLOT/preserved.txt"
before=$(git -C "$SLOT" rev-parse HEAD)
calls=$(wc -l < "$FM_TEST_TREEHOUSE_CALLS")
for placement in same-home secondmate; do
  if [ "$placement" = secondmate ]; then
    mkdir -p "$TMP_ROOT/mate/state" "$TMP_ROOT/mate/data"
    mv "$HOME_DIR/state/first.meta" "$TMP_ROOT/mate/state/first.meta"
    printf -- '- mate - fixture (home: %s; scope: test; projects: project; added 2026-01-01)\n' "$TMP_ROOT/mate" > "$HOME_DIR/data/secondmates.md"
  fi
  out=$(run_spawn "later-$placement"); rc=$?
  [ "$rc" -ne 0 ] || fail 'spawn allocated despite a recorded unleased slot'
  assert_contains "$out" 'before Treehouse can reset' 'refusal did not explain pre-allocation protection'
  assert_contains "$out" 'first' 'refusal did not identify the held record'
  [ "$(wc -l < "$FM_TEST_TREEHOUSE_CALLS")" = "$calls" ] || fail 'refusal happened after calling Treehouse'
  assert_present "$SLOT/preserved.txt" 'allocation erased uncommitted work before refusing'
  [ "$(git -C "$SLOT" rev-parse HEAD)" = "$before" ] || fail 'allocation reset the recorded copy before refusing'
done
pass 'missing leases in this home or a registered home refuse before any Treehouse allocation'
mv "$POOL_STATE" "$TMP_ROOT/pool-state-saved"
out=$(run_spawn missing-state); rc=$?
[ "$rc" -ne 0 ] || fail 'missing pool state hid the recorded slot'
[ "$(wc -l < "$FM_TEST_TREEHOUSE_CALLS")" = "$calls" ] || fail 'missing pool state reached allocation'
mv "$TMP_ROOT/pool-state-saved" "$POOL_STATE"
# The supported repair changes state only, then normal allocation can resume.
(cd "$PROJECT" && HOME="$TMP_ROOT/user" "$TREEHOUSE_BIN" lease 1 --lease-holder fixture) >/dev/null || fail 'state-only repair failed'
out=$(run_spawn repaired); rc=$?
expect_code 0 "$rc" "durable lease repair did not unblock allocation: $out"
assert_present "$SLOT/preserved.txt" 'repair or later allocation reset the preserved copy'
[ "$(cat "$FM_TEST_CWD")" != "$SLOT" ] || fail 'allocation reused the repaired lease'
pass 'missing state refuses safely, and state-only lease repair permits a different slot'
