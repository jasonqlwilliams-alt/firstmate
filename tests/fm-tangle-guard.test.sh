#!/usr/bin/env bash
# Behavior tests for the worktree-tangle guards.
#
# Firstmate is a treehouse-pooled git repo of itself: linked worktrees and
# secondmate homes all sit at a detached HEAD on the default branch, while the
# PRIMARY checkout (FM_ROOT) is a normal checkout on a real branch. The "tangle"
# is a crewmate branching/committing in the primary instead of its own worktree,
# stranding the primary on a feature branch. Two guards cover it:
#   GUARD 1 (prevention) - the brief asserts isolation before its branch step, and
#            fm-spawn refuses to launch unless the resolved worktree is isolated.
#   GUARD 2 (detection)  - fm-guard and fm-bootstrap alarm when the primary is on
#            a feature branch, and stay silent on the default branch or detached.
# These cases pin: the shared lib's branch classification, the fm-guard banner,
# the fm-bootstrap problem line, the brief assertion ordering, and the fm-spawn
# abort - all hermetic over temp git repos and fakebins.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-tangle-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-tangle-guard)
fm_git_identity fmtest fmtest@example.invalid

# A fresh git repo on `main` with one commit and a local origin. Echoes its path.
make_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  fm_git_add_origin "$dir" "$dir.origin.git"
  printf '%s\n' "$dir"
}

# --- shared lib: branch classification --------------------------------------

# fm_primary_tangle_branch is the whole scoping decision: a NAMED non-default
# branch is the tangle; the default branch and detached HEAD are healthy.
test_lib_classification() {
  local repo n=0 label state branch expect out
  repo=$(make_repo "$TMP_ROOT/lib-repo")
  while IFS='|' read -r label state branch expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case "$state" in
      default)  git -C "$repo" checkout -q main ;;
      feature)  git -C "$repo" checkout -q -B "$branch" ;;
      detached) git -C "$repo" checkout -q main; git -C "$repo" checkout -q --detach ;;
    esac
    out=$(fm_primary_tangle_branch "$repo" || true)
    [ "$out" = "$expect" ] || fail "$label: expected tangle='$expect', got '$out'"
  done <<'ROWS'
on the default branch is healthy|default||
on a feature branch is the tangle|feature|fm/readme-restructure-d3|fm/readme-restructure-d3
detached HEAD on default is healthy (worktrees, secondmate homes)|detached||
ROWS
  # A non-git directory is not a tangle and must not error.
  out=$(fm_primary_tangle_branch "$TMP_ROOT" || true)
  [ -z "$out" ] || fail "non-git dir wrongly reported a tangle: '$out'"
  pass "fm_primary_tangle_branch: feature branch alarms; default/detached/non-git stay silent"
}

# --- GUARD 2a: fm-guard banner ----------------------------------------------

run_guard() {
  # Scope the guard to a temp repo as the primary checkout; state lives under it.
  FM_ROOT_OVERRIDE="$1" FM_HOME="$1" "$ROOT/bin/fm-guard.sh" 2>&1
}

test_guard_banner() {
  local repo out
  repo=$(make_repo "$TMP_ROOT/guard-repo")

  out=$(run_guard "$repo")
  assert_not_contains "$out" "WORKTREE TANGLE" "guard alarmed while primary was on main"

  git -C "$repo" checkout -q --detach
  out=$(run_guard "$repo")
  assert_not_contains "$out" "WORKTREE TANGLE" "guard alarmed on a detached HEAD (legitimate worktree state)"

  git -C "$repo" checkout -q -B fm/tangle-aa1
  out=$(run_guard "$repo")
  assert_contains "$out" "WORKTREE TANGLE" "guard did not alarm on a feature branch in the primary"
  assert_contains "$out" "fm/tangle-aa1" "guard banner did not name the offending branch"
  assert_contains "$out" "checkout main" "guard banner did not print the restore remediation"
  out=$(FM_GUARD_READ_ONLY=1 run_guard "$repo")
  assert_contains "$out" "WORKTREE TANGLE" "read-only guard did not keep the tangle alarm"
  assert_contains "$out" "read-only session must leave restore work" "read-only guard did not explain restore ownership"
  assert_not_contains "$out" "checkout main" "read-only guard printed a state-changing restore command"
  pass "fm-guard: bordered tangle banner fires only for a feature branch and suppresses repair commands in read-only mode"
}

# --- GUARD 2b: fm-bootstrap problem line ------------------------------------

run_bootstrap() {
  # No projects/ under the home keeps fleet sync inert; grep isolates the line.
  FM_ROOT_OVERRIDE="$1" FM_HOME="$1" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

test_bootstrap_line() {
  local repo out
  repo=$(make_repo "$TMP_ROOT/bootstrap-repo")

  out=$(run_bootstrap "$repo" | grep '^TANGLE:' || true)
  [ -z "$out" ] || fail "bootstrap emitted a TANGLE line while on main: $out"

  git -C "$repo" checkout -q --detach
  out=$(run_bootstrap "$repo" | grep '^TANGLE:' || true)
  [ -z "$out" ] || fail "bootstrap emitted a TANGLE line on a detached HEAD: $out"

  git -C "$repo" checkout -q -B fm/tangle-bb2
  out=$(run_bootstrap "$repo" | grep '^TANGLE:' || true)
  assert_contains "$out" "fm/tangle-bb2" "bootstrap did not report the tangled branch"
  assert_contains "$out" "checkout main" "bootstrap TANGLE line lacked the restore remediation"
  out=$(FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null | grep '^TANGLE:' || true)
  assert_contains "$out" "fm/tangle-bb2" "detect-only bootstrap did not report the tangled branch"
  assert_contains "$out" "read-only session must leave restore work" "detect-only bootstrap did not explain restore ownership"
  assert_not_contains "$out" "checkout main" "detect-only bootstrap printed a state-changing restore command"
  pass "fm-bootstrap: TANGLE problem line fires only for a feature branch and suppresses repair commands in detect-only mode"
}

# --- GUARD 1a: brief isolation assertion ------------------------------------

# The generated ship brief must carry the isolation assertion AHEAD of the
# `git checkout -b` step, so the crewmate verifies its worktree before branching.
test_brief_assertion_precedes_branch() {
  local home brief iso br
  home="$TMP_ROOT/brief-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" tangle-brief-cc3 alpha --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/tangle-brief-cc3/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "blocked: launched in primary checkout, not an isolated worktree" "$brief" \
    "brief is missing the isolation blocked-status contract"
  assert_grep "The path check is authoritative" "$brief" \
    "brief must make the path check authoritative"
  assert_no_grep "A reliable test that you are in a linked worktree" "$brief" \
    "brief must not present git-dir/common-dir as decisive"
  assert_no_grep "they are identical in the primary checkout" "$brief" \
    "brief must not claim the primary checkout has identical git dirs"
  iso=$(grep -n 'launched in primary checkout, not an isolated worktree' "$brief" | head -1 | cut -d: -f1)
  br=$(grep -n 'git checkout -b fm/' "$brief" | head -1 | cut -d: -f1)
  if [ -z "$iso" ] || [ -z "$br" ]; then
    fail "brief missing assertion ($iso) or branch step ($br)"
  fi
  [ "$iso" -lt "$br" ] || fail "isolation assertion (line $iso) must precede the branch step (line $br)"
  pass "fm-brief: ship brief asserts worktree isolation before the branch step"
}

# --- GUARD 1b: fm-spawn isolation abort -------------------------------------

# Spawn isolation uses the shared spawn fakebin (pane path + window ops).
run_spawn() {
  local home=$1 id=$2 proj=$3 pane=$4 fakebin=$5
  fm_test_spawn_brief "$home" "$id" brief
  fm_test_run_spawn "$home" "$pane" "$fakebin" \
    "$id" "$proj" codex --mode no-mistakes --yolo off
}

test_spawn_isolation_abort() {
  local home proj fakebin out status
  home="$TMP_ROOT/spawn-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-proj")
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn-fake")
  # The assertions concern identity, not how long an unchanged cwd is polled.
  fm_test_fake_sleep_noop "$fakebin"
  # A genuine isolated linked worktree of the project, detached on the default.
  git -C "$proj" worktree add -q --detach "$TMP_ROOT/spawn-wt" >/dev/null 2>&1
  # The non-git case must BE non-git wherever this suite runs. A directory under
  # TMPDIR is not one when TMPDIR itself sits inside a git repository - git walks
  # up and finds that repo, and the spawn reports the subdirectory cause instead.
  # GIT_CEILING_DIRECTORIES stops that upward walk: git does not chdir up into a
  # listed directory, though it never excludes the directory being searched, so
  # the ceiling is the PARENT of the path handed to the spawn (git(1),
  # "GIT_CEILING_DIRECTORIES").
  mkdir -p "$TMP_ROOT/spawn-notgit-root/plain" "$proj/sub"

  # Abort: the pane resolves to a plain non-git directory (not a worktree at all).
  # The discovery poll screens every candidate with the isolation conditions, so
  # a path like this is never adopted and the refusal comes from the poll's own
  # deadline, naming the path and why it was rejected. The assertions pin which
  # cause fired, not the operator wording that explains it.
  out=$(GIT_CEILING_DIRECTORIES="$TMP_ROOT/spawn-notgit-root" \
    run_spawn "$home" abort-notgit-dd4 "$proj" "$TMP_ROOT/spawn-notgit-root/plain" "$fakebin"); status=$?
  expect_code 1 "$status" "spawn into a non-worktree dir should abort"
  assert_contains "$out" "did not enter an isolated worktree" "non-worktree spawn lacked the isolation error"
  assert_contains "$out" "not inside a git worktree" "non-worktree spawn did not say why the path was rejected"
  assert_absent "$home/state/abort-notgit-dd4.meta" "aborted spawn must not record meta"

  # Abort: the pane resolves INTO the primary checkout (a subdir of PROJ_ABS).
  out=$(run_spawn "$home" abort-primary-ee5 "$proj" "$proj/sub" "$fakebin"); status=$?
  expect_code 1 "$status" "spawn landing inside the primary checkout should abort"
  assert_contains "$out" "did not enter an isolated worktree" "primary-checkout spawn lacked the isolation error"
  assert_contains "$out" "not a worktree root" "primary-checkout spawn did not say why the path was rejected"
  assert_absent "$home/state/abort-primary-ee5.meta" "aborted spawn must not record meta"

  # Proceed: the pane resolves to a genuine, isolated worktree.
  out=$(run_spawn "$home" ok-isolated-ff6 "$proj" "$TMP_ROOT/spawn-wt" "$fakebin"); status=$?
  expect_code 0 "$status" "spawn into a genuine isolated worktree should succeed"
  assert_contains "$out" "spawned ok-isolated-ff6" "isolated spawn did not report success"
  assert_not_contains "$out" "isolated worktree" "isolated spawn wrongly tripped the guard"
  pass "fm-spawn: aborts unless the resolved worktree is a genuine, isolated worktree"
}

# --- GUARD 1c: fm-spawn tmux window construction ----------------------------

make_spawn_record_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_test_track_task_tmps "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_TMUX_REC:-}" ] && printf 'tmux %s\n' "$*" >> "$FM_TMUX_REC"
case "${1:-}" in
  -V) printf '%s\n' "${FM_FAKE_TMUX_VERSION:-tmux 3.2}"; exit 0 ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    if [ "${FM_FAKE_TMUX_SERVER:-}" = legacy ] && [[ " $* " = *' -f '* ]]; then
      printf 'unknown flag -f\n' >&2
      exit 1
    fi
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

run_spawn_record() {
  local home=$1 id=$2 proj=$3 pane=$4 fakebin=$5 rec=$6
  fm_test_spawn_brief "$home" "$id" brief
  FM_TMUX_REC="$rec" \
    fm_test_run_spawn "$home" "$pane" "$fakebin" \
    "$id" "$proj" codex --mode no-mistakes --yolo off
}

test_spawn_tmux_window_construction() (
  local home proj fakebin rec wt out status client server diagnostic
  local real_tmux socket launcher pane launch_env session_id
  home="$TMP_ROOT/spawn-rec-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-rec-proj")
  fakebin=$(make_spawn_record_fakebin "$TMP_ROOT/spawn-rec-fake")
  rec="$TMP_ROOT/spawn-rec.log"
  : > "$rec"
  wt="$TMP_ROOT/spawn-rec-wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1

  while IFS='|' read -r client server diagnostic; do
    : > "$rec"
    out=$(FM_FAKE_TMUX_VERSION="$client" FM_FAKE_TMUX_SERVER="$server" \
      run_spawn_record "$home" rec-win-gg7 "$proj" "$wt" "$fakebin" "$rec"); status=$?
    expect_code 1 "$status" "spawn should refuse $client with a $server server: $out"
    assert_contains "$out" "$diagnostic" "spawn did not explain the tmux prerequisite failure"
    if grep -Eq '^tmux (new-session|new-window|send-keys)( |$)' "$rec"; then
      fail "spawn allocated a tmux endpoint or requested a lease without compatible tmux"
    fi
    assert_absent "$home/state/rec-win-gg7.meta" "incompatible tmux should leave no worker record"
  done <<'ROWS'
tmux 3.1c|modern|requires a tmux client version 3.2
tmux 3.2|legacy|could not verify list-windows -f support
ROWS

  real_tmux=$(command -v tmux) || { printf 'skip - real tmux spawn placement requires tmux\n'; return 0; }
  socket="$TMP_ROOT/spawn.sock"
  unset TMUX TMUX_PANE
  trap '"$real_tmux" -S "$socket" kill-server 2>/dev/null || true' EXIT
  mkdir -p "$home/user-home"
  HOME="$home/user-home" "$real_tmux" -S "$socket" -f /dev/null new-session -d -s decoy -n initial -c "$proj" sleep 300 \
    || fail "could not start the private tmux server"
  "$real_tmux" -S "$socket" set-option -g base-index 1 || fail "could not set base-index"
  "$real_tmux" -S "$socket" set-option -g default-shell "$BASH" || fail "could not set the fixture shell"
  "$real_tmux" -S "$socket" set-option -g default-command 'exec bash --noprofile --norc' \
    || fail "could not set the fixture shell command"
  "$real_tmux" -S "$socket" set-window-option -g automatic-rename on || fail "could not enable automatic-rename"
  "$real_tmux" -S "$socket" set-window-option -g allow-rename on || fail "could not enable allow-rename"
  launcher=$("$real_tmux" -S "$socket" new-session -dP -F '#{pane_id}' -s '$0' -n initial -c "$proj") \
    || fail "could not create the literal ID-shaped destination"
  session_id=$("$real_tmux" -S "$socket" display-message -p -t "$launcher" '#{session_id}')
  launch_env=$("$real_tmux" -S "$socket" display-message -p -t "$launcher" '#{socket_path},#{pid}')
  "$real_tmux" -S "$socket" set-environment -t "$session_id" PATH "$fakebin:$PATH" || fail "could not set the worker PATH"
  "$real_tmux" -S "$socket" set-environment -t "$session_id" FM_TREEHOUSE_TEST_SLOT "$wt" || fail "could not set the fixture slot"
  "$real_tmux" -S "$socket" set-environment -t "$session_id" FM_TREEHOUSE_TEST_RECEIPT "$rec" || fail "could not set the receipt path"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
exec "$real_tmux" -S "$socket" "\$@"
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$TMUX_PANE" "$*" > "$FM_TREEHOUSE_TEST_RECEIPT"
printf '%s\n' "$FM_TREEHOUSE_TEST_SLOT"
SH
  fm_fake_exit0 "$fakebin" codex

  : > "$rec"
  out=$(TMUX="$launch_env,${session_id#\$}" TMUX_PANE="$launcher" \
    run_spawn "$home" rec-win-gg7 "$proj" "$wt" "$fakebin"); status=$?
  expect_code 0 "$status" "spawn into a genuine worktree should succeed: $out"
  assert_contains "$out" "spawned rec-win-gg7" "spawn did not report success"
  grep -Fxq "worktree=$wt" "$home/state/rec-win-gg7.meta" \
    || fail "spawn must record the worktree the worker entered"
  [ "$("$real_tmux" -S "$socket" list-windows -t "$session_id:" -F '#{window_index} #{window_name}')" = \
    $'1 initial\n2 fm-rec-win-gg7' ] || fail "spawn must append its pinned window to the literal session"
  [ "$("$real_tmux" -S "$socket" list-windows -t '$0:' -F '#{window_name}')" = initial ] \
    || fail "spawn changed the ID-shaped session's decoy"
  pane=$("$real_tmux" -S "$socket" display-message -p -t "$session_id:2" '#{pane_id}')
  [ "$("$real_tmux" -S "$socket" show-window-options -v -t "$pane" automatic-rename)" = off ] &&
    [ "$("$real_tmux" -S "$socket" show-window-options -v -t "$pane" allow-rename)" = off ] \
    || fail "spawn did not pin both rename options on the worker"
  [ "$(cat "$rec")" = "$pane"$'\n''get --lease --lease-holder rec-win-gg7' ] \
    || fail "the new worker pane did not run the durable Treehouse lease command"
  pass "fm-spawn: appends a pinned window and acquires its lease in the worker pane"
)

test_lib_classification
test_guard_banner
test_bootstrap_line
test_brief_assertion_precedes_branch
test_spawn_isolation_abort
test_spawn_tmux_window_construction || exit $?
