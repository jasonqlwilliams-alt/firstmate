#!/usr/bin/env bash
# Run only the missing-endpoint relaunch tests from fm-control-relaunch.test.sh
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-trace-context-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"

CONTROL="$ROOT/bin/fm-control.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"

TMP_ROOT=$(fm_test_tmproot fm-missing-endpoint)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
TASK_TMPS=()

relaunch_cleanup() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  rm -rf "$TMP_ROOT"
}
trap relaunch_cleanup EXIT

# Reuse the helpers from fm-control-relaunch.test.sh
make_tmux_stub() {
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit)
          if [ -x "$D/before-exit" ]; then
            "$D/before-exit" || exit 1
          fi
          printf 'zsh' > "$D/command"
          ;;
        claude|opencode|codex|grok|gemini|pi|rovo|kimi|muse|agy|omp)
          printf '%s' "$payload" > "$D/command"
          ;;
      esac
    fi
    ;;
  capture-pane)
    for a in "$@"; do
      case "$a" in
        *pane_current_command*) printf 'zsh' ;;
      esac
    done | head -1
    ;;
  list-windows)
    if [ -f "$D/windows" ]; then
      cat "$D/windows"
    fi
    exit 0 ;;
  has-session|new-session|set-window-option) exit 0 ;;
  new-window)
    name=
    cwd=
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        -n) name=$2; shift 2 ;;
        -c) cwd=$2; shift 2 ;;
        -t|-F) shift 2 ;;
        -dP|-d|-P) shift ;;
        *) shift ;;
      esac
    done
    [ -z "$name" ] || printf '%s\n' "$name" >> "$D/windows"
    [ -z "$cwd" ] || printf '%s' "$cwd" > "$D/cwd"
    printf '@recreated\n'
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
}

new_case() {
  local id=${2:-t1} dir="$TMP_ROOT/$1-$RANDOM" tool
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  make_tmux_stub "$dir"
  for tool in claude codex opencode grok gemini pi; do
    printf '#!/bin/sh\nexit 0\n' > "$dir/fakebin/$tool"
    chmod +x "$dir/fakebin/$tool"
  done
  printf '%s\n' "$dir"
}

add_ship_task() {
  local dir=$1 id=$2 harness=${3:-claude}
  local home="$dir/home" proj="$dir/proj" wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise relaunch behavior for $id.
## Firstmate spec
Preserve the task while replacing its agent process.
EOF
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=$harness"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
  } > "$home/state/$id.meta"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
  TASK_TMPS+=("/tmp/fm-$id")
}

run_spawn() {
  local dir=$1 pane_pid rc; shift
  mkdir -p "$dir/user-home"
  env PATH="$dir/fakebin:$PATH" /bin/sleep 120 >/dev/null 2>&1 &
  pane_pid=$!
  env FM_FAKE_PANE_PID="$pane_pid" FM_FAKE_PANE_PATH="$dir/fakebin:$PATH" \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$@" 2>&1
  rc=$?
  kill "$pane_pid" 2>/dev/null || true
  wait "$pane_pid" 2>/dev/null || true
  return "$rc"
}

run_control() {
  local dir=$1 pane_pid rc; shift
  mkdir -p "$dir/user-home"
  env PATH="$dir/fakebin:$PATH" /bin/sleep 120 >/dev/null 2>&1 &
  pane_pid=$!
  env FM_FAKE_PANE_PID="$pane_pid" FM_FAKE_PANE_PATH="$dir/fakebin:$PATH" \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$CONTROL" "$@" 2>&1
  rc=$?
  kill "$pane_pid" 2>/dev/null || true
  wait "$pane_pid" 2>/dev/null || true
  return "$rc"
}

meta_field() {
  local dir=$1 id=$2 field=$3
  awk -F= -v f="$field" '$1 == f { print $2; exit }' "$dir/home/state/$id.meta"
}

journal_field() {
  local dir=$1 id=$2 field=$3
  awk -F= -v f="$field" '$1 == f { print $2; exit }' "$dir/home/state/$id.journal"
}

expect_code() {
  local expected=$1 actual=$2 msg=$3
  [ "$actual" = "$expected" ] || fail "exit $actual vs $expected: $msg"
}

assert_contains() {
  local needle=$1 haystack=$2 msg=${3:-}
  case "$haystack" in
    *"$needle"*) : ;;
    *) fail "${msg}: expected to contain '$needle'" ;;
  esac
}

assert_grep() {
  local needle=$1 file=$2 msg=${3:-}
  grep -Fq "$needle" "$file" || fail "${msg}: expected '$needle' in $(cat "$file" 2>/dev/null)"
}

# --- Test: spawn relaunch recreates a missing endpoint ---
test_spawn_relaunch_recreates_a_missing_endpoint() {
  local dir out rc window_after
  dir=$(new_case missing-spawn rl-missing)
  add_ship_task "$dir" rl-missing claude
  : > "$dir/fake/windows"
  printf 'zsh' > "$dir/fake/command"
  out=$(TMUX='' run_spawn "$dir" rl-missing --relaunch --harness claude); rc=$?
  expect_code 0 "$rc" "relaunching a missing endpoint should recreate it"$'\n'"$out"
  window_after=$(meta_field "$dir" rl-missing window)
  [ -n "$window_after" ] || fail "missing-endpoint relaunch published no endpoint"
  case "$window_after" in
    *:fm-rl-missing) ;;
    *) fail "missing-endpoint relaunch published $window_after, not a recreated fm-rl-missing endpoint" ;;
  esac
  [ "$(meta_field "$dir" rl-missing worktree)" = "$dir/wt" ] \
    || fail "missing-endpoint relaunch replaced the recorded copy"
  grep -Fxq -- "fm-rl-missing" "$dir/fake/windows" \
    || fail "missing-endpoint relaunch did not create a replacement window"
  assert_grep "encode launch-brief" "$dir/fake/literal" \
    "the replacement should have been launched into the new endpoint"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "the recreated endpoint did not launch the replacement agent"
  pass "fm-spawn --relaunch: a missing endpoint is recreated into the recorded copy"
}

# --- Test: control relaunch recreates a missing endpoint ---
test_control_relaunch_recreates_a_missing_endpoint() {
  local dir out rc window_after
  dir=$(new_case missing-control rl-missctl)
  add_ship_task "$dir" rl-missctl claude
  : > "$dir/fake/windows"
  printf 'zsh' > "$dir/fake/command"
  out=$(TMUX='' run_control "$dir" rl-missctl relaunch --note "pane was closed; continue"); rc=$?
  expect_code 0 "$rc" "control relaunch of a missing endpoint should succeed"$'\n'"$out"
  assert_contains "$out" "relaunched rl-missctl harness=claude from=claude" \
    "the outcome should name the missing-endpoint relaunch"
  window_after=$(meta_field "$dir" rl-missctl window)
  [ -n "$window_after" ] || fail "control relaunch published no endpoint"
  case "$window_after" in
    *:fm-rl-missctl) ;;
    *) fail "control relaunch published $window_after, not a recreated fm-rl-missctl endpoint" ;;
  esac
  [ "$(meta_field "$dir" rl-missctl worktree)" = "$dir/wt" ] \
    || fail "control relaunch replaced the recorded copy"
  ! grep -Fq "/exit" "$dir/fake/literal" \
    || fail "a missing endpoint must not be sent an exit command"
  assert_grep "encode launch-brief" "$dir/fake/literal" \
    "the replacement should have been launched into the recreated endpoint"
  [ "$(journal_field "$dir" rl-missctl phase)" = complete ] \
    || fail "the transaction journal should end complete"
  pass "fm-control relaunch: a missing endpoint is recreated instead of becoming a one-way door"
}

# Run the tests
echo "=== Missing-Endpoint Relaunch Tests ==="
test_spawn_relaunch_recreates_a_missing_endpoint
test_control_relaunch_recreates_a_missing_endpoint
echo "=== All missing-endpoint tests passed ==="