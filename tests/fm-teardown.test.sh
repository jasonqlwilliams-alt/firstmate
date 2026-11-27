#!/usr/bin/env bash
# Tests for bin/fm-teardown.sh's landed-work safety and stale-lock recovery.
#
# The check refuses to tear down a worktree whose work has not LANDED, because
# treehouse return hard-resets the worktree. "Landed" means reachable from a remote
# OR - for a normal ship task whose commits are not so reachable - its PR is merged
# and GitHub reports a PR head that contains the current local work, or its content
# is already in the up-to-date default branch.
#
# Covers three fixes:
#   - local-only fork-remote: a fork IS a remote, so fork-pushed upstream-
#     contribution PRs are teardown-eligible (the pre-fix code false-refused them).
#   - squash-merge-then-delete-branch: the branch's own commits live nowhere on a
#     remote after a squash merge deletes the head branch, yet the change is fully in
#     main. Reachability alone false-refused this common GitHub flow; the check now
#     recognizes a merged PR head containing the local work (or the content already
#     in main) as landed.
#   - teardown-lock-race: a killed crew process can leave a transient worktree
#     git index.lock that blocks teardown. The return path retries on the lock
#     error signature (even if the lock self-clears mid-check), then only removes a
#     provably stale lock before re-running safety checks.
#
# Matrix:
#   (a) local-only + HEAD on a fork remote-tracking branch     -> ALLOW  (fork fix)
#   (b) local-only + truly unpushed work (no remote, not main) -> REFUSE (safety)
#   (c) local-only + merged into local main, no remote         -> ALLOW  (no regression)
#   (d) no-mistakes + HEAD on origin remote-tracking branch    -> ALLOW  (no regression)
#   (e) no-mistakes + unpushed, no PR, content not in default  -> REFUSE (safety)
#   (f) local-only + truly unpushed + --force                  -> ALLOW  (escape hatch)
#   (g) no-mistakes + squash-merged PR, exact PR head          -> ALLOW  (squash fix)
#   (h) no-mistakes + no PR but content already in default     -> ALLOW  (content fallback)
#   (i) no-mistakes + dirty worktree, even when work landed     -> REFUSE (dirty wins)
#   (j) no-mistakes + gh lookup errors + content not in default -> REFUSE (fail-safe)
#   (k) no-mistakes + merged PR but HEAD moved afterward        -> REFUSE (stale PR)
#   (l) no-mistakes + stale origin/main but fetched content     -> ALLOW  (fresh fetch)
#   (m) no-mistakes + local HEAD ancestor of merged PR head     -> ALLOW  (lagging local)
#   (n) no-mistakes + replayed unpushed patch in merged PR head -> ALLOW  (replayed local)
#   (o) fm-pr-check rerun after HEAD moved                      -> no stale pr_head
#   (p) fm-pr-check when local HEAD lags                        -> record remote PR head
#   (q) no-mistakes + NO pr= recorded, PR discovered by branch  -> ALLOW  (yolo/no-CI merge)
#   (q2) no-mistakes + squash-merged, local followed pipeline rebase -> ALLOW
#   (q3) no-mistakes + squash-merged, same file, different content   -> REFUSE
#   (q4) no-mistakes + squash-merged rebased local plus extra commit -> REFUSE
#   (q5) gh down + squash-merged stale local, content not in default -> REFUSE
#
# Also covers backlog teardown-lock-race: a git index.lock left in the worktree by a
# killed crew process (bin/fm-teardown.sh's teardown_treehouse_return).
#   (r) provably-stale index.lock (old mtime, no live holder) -> lock removed, ALLOW
#   (s) index.lock with a live holder, any age                -> lock kept, REFUSE
#   (t) lsof error while checking index.lock                  -> lock kept, REFUSE
#   (u) dirty worktree after stale lock cleanup               -> lock removed, REFUSE
#   (v) non-linked repo index.lock                            -> lock removed, ALLOW
#   (w) index.lock mtime read failure                         -> lock kept, REFUSE
#   (x) transient lock cleared after first failed return      -> retry ALLOW
#   (y) persistent lock (never clears, not provably stale)    -> REFUSE loudly
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-tests)
REAL_GIT_FOR_TEST=$(command -v git)
export REAL_GIT_FOR_TEST
REAL_PS_FOR_TEST=$(command -v ps)
export REAL_PS_FOR_TEST
REAL_LSOF_FOR_TEST=$(command -v lsof)
export REAL_LSOF_FOR_TEST
REAL_RM_FOR_TEST=$(command -v rm)
export REAL_RM_FOR_TEST

# Build a fresh sandbox for one test case. Sets up:
#   $CASE/state/        - firstmate state dir (with a fresh watcher beacon)
#   $CASE/fakebin/      - mocks for treehouse, tmux (PATH-prepended by caller)
#   $CASE/origin.git/   - bare upstream repo (so the project clone has origin)
#   $CASE/project/      - clone of origin; acts as the firstmate project dir
#   $CASE/wt/           - a worktree of the project (the task worktree)
# Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data" "$case_dir/home/state" "$fakebin"

  # Mocks for the post-check teardown steps. Refuse logic exits before these
  # run; the ALLOW cases need them so the script can complete cleanly.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
# `treehouse return --force <wt>`: succeed silently.
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
# tmux kill-window etc.: succeed silently.
exit 0
SH
  # Default gh-axi mock: no PR is associated with the branch, and viewing any PR
  # number fails. This keeps the landed-work check hermetic (never reaching the real
  # gh-axi) and represents the common "no GitHub PR" baseline. Tests that need a
  # merged PR or a lookup error override this file with the helpers below.
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  # Default hermetic no-mistakes stub: `axi status` answers FM_FAKE_AXI_STATUS
  # verbatim (empty by default, i.e. no active run - the pre-teardown run-abort
  # step is then a no-op), `axi abort` appends one line to
  # FM_FAKE_NM_ABORT_LOG when set, the top-level `runs` listing answers
  # FM_FAKE_NM_RUNS_LIST verbatim (the real `no-mistakes runs --limit N` is
  # plain text with no run id and no quoting - see the ledger fixtures below),
  # and `runs` appends its own invocation to FM_FAKE_NM_RUNS_LOG when set, so
  # a test can prove whether the ledger fallback ever engaged.
  # This keeps every case hermetic - without it, `command -v no-mistakes`
  # would fall through to whatever real binary happens to be on the test
  # runner's own PATH. Tests exercising the run-abort path override
  # FM_FAKE_AXI_STATUS/FM_FAKE_NM_ABORT_LOG/FM_FAKE_NM_RUNS_LIST before
  # run_teardown.
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      status)
        shift
        run_id=""
        if [ "${1:-}" = --run ]; then run_id=${2:-}; fi
        if [ -n "${FM_FAKE_NM_ABORT_LOG:-}" ] \
           && grep -Fxq "abort --run $run_id" "$FM_FAKE_NM_ABORT_LOG" 2>/dev/null \
           && [ "${FM_FAKE_NM_ABORT_NOOP:-0}" != 1 ]; then
          if [ "${FM_FAKE_NM_NOT_FOUND_AFTER_ABORT:-0}" = 1 ]; then
            printf 'error: "run \\"%s\\" not found"\n' "$run_id" >&2
            exit 1
          elif [ "${FM_FAKE_NM_EMPTY_AFTER_ABORT:-0}" = 1 ]; then
            exit 0
          elif [ -n "${FM_FAKE_AXI_STATUS_AFTER_ABORT:-}" ]; then
            printf '%s\n' "$FM_FAKE_AXI_STATUS_AFTER_ABORT"
          else
            printf 'run:\n  id: "%s"\n  outcome: cancelled\n' "$run_id"
          fi
        else
          printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"
        fi
        ;;
      abort)
        shift
        [ -z "${FM_FAKE_NM_ABORT_LOG:-}" ] || printf 'abort %s\n' "$*" >> "$FM_FAKE_NM_ABORT_LOG"
        exit 0 ;;
    esac
    ;;
  runs)
    [ -z "${FM_FAKE_NM_RUNS_LOG:-}" ] || printf 'runs %s\n' "$*" >> "$FM_FAKE_NM_RUNS_LOG"
    printf '%s\n' "${FM_FAKE_NM_RUNS_LIST:-}" ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/gh-axi" "$fakebin/gh" "$fakebin/no-mistakes"

  # Bare origin so the clone has an `origin` remote and origin/HEAD.
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  # Seed origin with one commit BEFORE cloning so the clone is not empty.
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  # Clone as the project; give it a `main` branch and an origin/HEAD.
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" config remote.origin.url "https://github.com/example/repo.git"
  git -C "$case_dir/project" config "url.$case_dir/origin.git.insteadOf" "https://github.com/example/repo.git"
  # Add a worktree on a fresh task branch; that branch is where the crewmate commits.
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  # Fresh watcher beacon so fm-guard stays quiet.
  touch "$case_dir/state/.last-watcher-beat"

  printf '%s\n' "$case_dir"
}

# Write a meta file for the task. Args: case_dir mode kind
write_meta() {
  local case_dir=$1 mode=$2 kind=$3
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=$mode" \
    "spawn_gen=teardown-test-task-x1"
}

# Commit something on the worktree's task branch. Args: case_dir [message]
wt_commit() {
  local case_dir=$1 msg=${2:-wt work}
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "$msg"
}

# Add a fork bare repo and register it as a remote on the project, then push
# the worktree's task branch to it and fetch into the project so the worktree
# sees the remote-tracking ref. Args: case_dir
add_fork_with_pushed_branch() {
  local case_dir=$1
  git init -q --bare "$case_dir/fork.git"
  git -C "$case_dir/project" remote add fork "$case_dir/fork.git"
  # Push the task branch from the worktree to the fork, then fetch into project
  # so refs/remotes/fork/fm-task-x1 is visible from the worktree (shared object db).
  git -C "$case_dir/wt" push -q fork fm/task-x1
  git -C "$case_dir/project" fetch -q fork
}

# Commit a real file change on the worktree's task branch (unlike wt_commit, which
# makes an empty commit). A non-empty tree is what the content-in-default check
# inspects. Args: case_dir file content [message]
wt_commit_file() {
  local case_dir=$1 file=$2 content=$3 msg=${4:-add $2}
  printf '%s\n' "$content" > "$case_dir/wt/$file"
  git -C "$case_dir/wt" add -- "$file"
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q -m "$msg"
}

# Land <file>=<content> as a single commit on origin's default branch, simulating a
# squash merge whose net change matches the task branch but whose commit differs.
# After this, the branch's content is in origin/main even though the branch's own
# commits are not reachable from it. Args: case_dir file content
land_on_origin_main() {
  local case_dir=$1 file=$2 content=$3 tmp
  tmp="$case_dir/_land"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "squash $file"
  git -C "$tmp" push -q origin HEAD:main
  rm -rf "$tmp"
}

# Override GitHub lookups to report PR 7 as merged with the supplied head.
add_gh_pr_merged_for_head() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list")
    printf '%s\n' "count: 1 (showing first 1)" "pull_requests[1]{number,state}:" "  7,merged" ; exit 0 ;;
  "pr view")
    printf '%s\n' "pull_request:" "  number: 7" "  state: merged" '  merged: "2026-06-26T00:00:00Z"' ; exit 0 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *"state,headRefOid,url"*) printf '%s\t%s\t%s\n' 'MERGED' '$head' 'https://github.com/example/repo/pull/7' ; exit 0 ;;
      *"headRefOid"*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
echo "error: pull request not found" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Squash-merged history whose pipeline rebased the branch onto a newer main that
# edited the same shared file. A local copy left behind by that rebase holds
# different content for the shared file, so its per-commit patch ids against the
# PR head differ and merge-tree against main conflicts; teardown refuses it on
# purpose rather than reading a shared path as proof the local content landed.
# local_mode: rebased | stale | rebased-plus-unlanded
# Echoes: <pr_head>
setup_squash_rebased_history() {
  local case_dir=$1 local_mode=$2 tmp local_head pr_head
  tmp="$case_dir/_shared_base"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' base > "$tmp/shared.txt"
  git -C "$tmp" add -- shared.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "shared base"
  git -C "$tmp" push -q origin main
  git -C "$case_dir/wt" fetch -q origin
  git -C "$case_dir/wt" reset -q --hard origin/main
  rm -rf "$tmp"

  wt_commit_file "$case_dir" feature.txt hello "add feature"
  printf '%s\n' base feature-edit > "$case_dir/wt/shared.txt"
  git -C "$case_dir/wt" add -- shared.txt
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q -m "edit shared from feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)

  tmp="$case_dir/_main_move"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' base main-edit > "$tmp/shared.txt"
  git -C "$tmp" add -- shared.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "main edits shared"
  git -C "$tmp" push -q origin main
  rm -rf "$tmp"

  tmp="$case_dir/_pipeline"
  git clone -q "$case_dir/origin.git" "$tmp"
  git -C "$tmp" checkout -q -b fm/task-x1
  printf '%s\n' hello > "$tmp/feature.txt"
  git -C "$tmp" add -- feature.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "add feature"
  printf '%s\n' base main-edit feature-edit > "$tmp/shared.txt"
  git -C "$tmp" add -- shared.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t \
    commit -q -m "edit shared from feature"
  pr_head=$(git -C "$tmp" rev-parse HEAD)
  git -C "$tmp" push -q origin "HEAD:refs/pull/7/head"
  git -C "$tmp" checkout -q main
  git -C "$tmp" merge -q --squash fm/task-x1 >/dev/null
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "feat: squash (#7)"
  git -C "$tmp" push -q origin main
  rm -rf "$tmp"

  git -C "$case_dir/project" fetch -q origin
  git -C "$case_dir/wt" fetch -q origin "refs/pull/7/head:refs/fm-test/pr-head"
  case "$local_mode" in
    rebased)
      git -C "$case_dir/wt" reset -q --hard "$pr_head"
      ;;
    stale)
      git -C "$case_dir/wt" reset -q --hard "$local_head"
      ;;
    rebased-plus-unlanded)
      git -C "$case_dir/wt" reset -q --hard "$pr_head"
      wt_commit_file "$case_dir" later.txt local-only "local follow-up"
      ;;
    *)
      fail "setup_squash_rebased_history: unknown local_mode $local_mode"
      ;;
  esac
  printf '%s\n' "$pr_head"
}

# A refusal must leave every recovery route intact: the isolated copy, its task
# branch still at the unlanded commit, and the durable task record. A completed
# teardown detaches and deletes that branch and removes the record, so these hold
# only while nothing destructive ran before the refusal was reported.
# Args: case_dir label head-before-teardown
assert_refusal_retained_task_state() {
  local case_dir=$1 label=$2 head=$3
  [ -d "$case_dir/wt" ] || fail "$label: refusal removed the isolated copy"
  [ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" = fm/task-x1 ] \
    || fail "$label: refusal dropped the task branch"
  [ "$(git -C "$case_dir/wt" rev-parse HEAD 2>/dev/null)" = "$head" ] \
    || fail "$label: refusal moved the task branch off the unlanded commit"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "$label: refusal erased the durable task record"
}

append_pr_meta_for_current_head() {
  local case_dir=$1 head
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$head" >> "$case_dir/state/task-x1.meta"
}

append_pr_meta_url() {
  local case_dir=$1
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
}

commit_tree_from_wt_head() {
  local case_dir=$1 parent=$2 msg=$3 tree
  tree=$(git -C "$case_dir/wt" rev-parse "$parent^{tree}") || return 1
  printf '%s\n' "$msg" | git -C "$case_dir/wt" commit-tree "$tree" -p "$parent"
}

land_equivalent_patch_on_origin_branch() {
  local case_dir=$1 branch=$2 file=$3 content=$4 msg=$5 tmp
  tmp="$case_dir/_equiv"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "$msg"
  git -C "$tmp" push -q origin "HEAD:refs/heads/$branch"
  git -C "$case_dir/project" fetch -q origin "$branch"
  rm -rf "$tmp"
  git -C "$case_dir/project" rev-parse "refs/remotes/origin/$branch"
}

# Override gh-axi so every call fails, simulating an API/network error.
add_gh_axi_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
echo "error: gh-axi unavailable" >&2
exit 1
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo "error: gh unavailable" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Override fakebin/treehouse so `treehouse return --force <wt>` fails with a
# git "file exists" lock error whenever the worktree's real index.lock is
# present, and succeeds once it is gone. This drives the lock through
# fm-teardown.sh's own retry-then-stale-cleanup logic (teardown_treehouse_return
# in bin/fm-teardown.sh) rather than hand-simulating that logic in the test.
add_lock_aware_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    echo "fatal: Unable to create '$lock': File exists." >&2
    exit 128
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# treehouse return fails once with the index.lock signature, then clears the lock
# (simulating a dying crew git process finishing) so the next retry succeeds.
# The first failure always reports the lock path even if the file is removed in
# the same attempt - matching the production race where the lock self-clears
# between the failed return and the supervisor's existence check.
add_transient_lock_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  count_file="${TREEHOUSE_ATTEMPT_FILE:?}"
  count=0
  if [ -f "$count_file" ]; then
    count=$(cat "$count_file")
  fi
  count=$(( count + 1 ))
  printf '%s\n' "$count" > "$count_file"
  if [ "$count" -eq 1 ]; then
    # Emit the real git signature, then drop the lock so a lock-existence-only
    # recovery path would wrongly abort without retrying.
    if [ -n "$lock" ]; then
      echo "fatal: Unable to create '$lock': File exists." >&2
      rm -f "$lock"
    else
      echo "fatal: Unable to create 'index.lock': File exists." >&2
    fi
    exit 128
  fi
  git -C "$wt" checkout --detach -q main
  exit $?
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# treehouse return always fails with the lock signature while the lock file
# remains; used to assert exhausted retries still refuse loudly.
add_persistent_lock_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  if [ -z "$lock" ]; then
    lock="index.lock"
  fi
  echo "fatal: Unable to create '$lock': File exists." >&2
  exit 128
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

git_index_lock_path() {
  local dir=$1 lock abs_dir
  lock=$(git -C "$dir" rev-parse --git-path index.lock)
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      abs_dir=$(cd "$dir" && pwd -P)
      printf '%s/%s\n' "$abs_dir" "$lock"
      ;;
  esac
}

# fakebin/lsof stub: no process ever holds anything open (lsof's not-found exit
# code), so a lock's staleness is decided by age alone. The cwd scan is a
# separate successful empty query.
add_lsof_no_holder() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" -d cwd "*) exit 0 ;;
esac
exit 1
SH
  chmod +x "$case_dir/fakebin/lsof"
}

# fakebin/lsof stub: a live process holds every queried path open, so a lock is
# never judged stale regardless of its age.
add_lsof_live_holder() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/lsof"
}

add_lsof_index_lock_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" -d cwd "*) exit 0 ;;
  " -- "*/index.lock" ")
    echo "lsof: simulated failure for $2" >&2
    exit 2
    ;;
esac
exit 1
SH
  chmod +x "$case_dir/fakebin/lsof"
}

add_stat_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/stat" <<'SH'
#!/usr/bin/env bash
echo "stat: simulated failure" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/stat"
}

add_git_status_lock_failure() {
  local case_dir=$1
  cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
dir=
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C)
      dir=$2
      args+=("$1" "$2")
      shift 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
if [ -n "$dir" ] && [ "${args[2]:-}" = status ] && [ "${args[3]:-}" = --porcelain ]; then
  lock=$("$real" -C "$dir" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$dir/$lock" ;;
  esac
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    echo "fatal: Unable to create '$lock': File exists." >&2
    exit 128
  fi
fi
exec "$real" "${args[@]}"
SH
  chmod +x "$case_dir/fakebin/git"
}

# Run teardown with PATH mocking. Args: case_dir [extra args...]
run_teardown() {
  local case_dir=$1; shift
  # FM_DATA_OVERRIDE is pinned to the case dir because teardown closes this
  # home's backlog item itself; without it $DATA would resolve to the real
  # repo's own home and a test could mutate live records.
  FM_HOME="${FM_HOME:-$case_dir/home}" FM_ROOT_OVERRIDE="${FM_TEARDOWN_TEST_ROOT:-$ROOT}" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:${FM_TEARDOWN_TEST_PATH:-$PATH}" \
    "$TEARDOWN" task-x1 "$@"
}

# Seed a real backlog carrying task-x1 as In flight, so a teardown in this case
# has a row to close. Uses the real tasks-axi (the fixture's default fakebin has
# no tasks-axi stub, so PATH resolves the installed one).
seed_backlog_in_flight() {
  local kind=${2:-ship} id=${3:-task-x1} data=${4:-$1/data}
  mkdir -p "$data"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$data/backlog.md"
  tasks-axi add "$id" "teardown fixture task" --kind "$kind" \
    --file "$data/backlog.md" >/dev/null
  tasks-axi start "$id" --file "$data/backlog.md" >/dev/null
}

backlog_row_state() {
  local case_dir=$1
  tasks-axi show task-x1 --file "$case_dir/data/backlog.md" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

# Build the teardown test's executable search path without lsof, regardless of
# whether the host installs it in /usr/bin, /usr/sbin, or a package-manager bin.
make_path_without_lsof() {  # <case-dir>
  local path_dir="$1/path-without-lsof" cmd resolved
  mkdir -p "$path_dir"
  for cmd in awk bash basename cat chmod cp cut date dirname env find git grep head hostname id jq ln \
    mkdir mktemp mv perl ps readlink realpath rm sed sh sha256sum shasum sleep sort stat tail timeout tr uname wc xargs; do
    resolved=$(command -v "$cmd" 2>/dev/null) || continue
    case "$resolved" in /*) ln -sf "$resolved" "$path_dir/$cmd" ;; esac
  done
  printf '%s\n' "$path_dir"
}

test_local_only_fork_remote_allows() {
  local case_dir rc
  case_dir=$(make_case fork-allow)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "fix the thing"
  add_fork_with_pushed_branch "$case_dir"
  # The supervision branch's bounded per-task outcome cache is a footprint of
  # the retired task, not a record anything reads after it is gone.
  printf 'fm-branch-outcome-index-v1\t5\t0\t-\n' > "$case_dir/state/.task-x1.branch-outcome-index"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "fork-allow: teardown should succeed when HEAD is on a fork remote"
  ! grep -q REFUSED "$case_dir/stderr" || fail "fork-allow: teardown printed a REFUSED line"
  [ ! -e "$case_dir/state/.task-x1.branch-outcome-index" ] \
    || fail "fork-allow: teardown left the task's branch outcome index behind"
  # The supervision branch reports the teardown it just performed AFTER the
  # task's records are gone (bin/fm-branch-prompt.sh); that report must be
  # stored, must publish its ready sequence, and must not recreate the index.
  post_seq=$(FM_STATE_OVERRIDE="$case_dir/state" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-x1 --verdict captain --summary 'PR merged and cleaned up') \
    || fail "fork-allow: post-teardown branch report was refused"
  [ "$post_seq" = 1 ] || fail "fork-allow: post-teardown branch report got seq $post_seq, expected 1"
  grep -q '"task":"task-x1"' "$case_dir/state/branch-outcomes.jsonl" \
    || fail "fork-allow: post-teardown branch report was not stored"
  [ ! -e "$case_dir/state/.task-x1.branch-outcome-index" ] \
    || fail "fork-allow: post-teardown branch report recreated the retired task index"
  [ "$(cat "$case_dir/state/.branch-outcome-index-ready")" = 1 ] \
    || fail "fork-allow: post-teardown branch report did not publish its ready sequence"
  jq -e --arg id task-x1 '
    .schema == "fm-secondmate-home-summary.v1"
    and all(.endpoints[]; .id != $id)
  ' "$case_dir/state/home-summary.json" >/dev/null \
    || fail "successful task teardown did not publish the task's removal from the home summary ledger"
  pass "local-only worktree with HEAD on a fork remote is torn down and the home summary is refreshed"
}

test_teardown_closes_the_backlog_item_itself() {
  local case_dir out
  case_dir=$(make_case tasks-axi-close)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"

  out=$(run_teardown "$case_dir") || fail "teardown failed with a real backlog"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "teardown returned success while its backlog item was still open: $(backlog_row_state "$case_dir")"
  assert_grep 'https://github.com/example/repo/pull/7' "$case_dir/data/backlog.md" \
    "closed backlog item did not record the task's PR"
  assert_absent "$case_dir/state/task-x1.backlog-close" \
    "a landed close left its pending-close record behind"
  printf '%s\n' "$out" | grep -F 'bin/fm-tasks-axi.sh ready' >/dev/null \
    || fail "teardown dropped the dependency-cleared follow-up: $out"
  printf '%s\n' "$out" | grep -F 'check date gates' >/dev/null \
    || fail "teardown did not preserve date-gate check: $out"
  printf '%s\n' "$out" | grep -F 'Run tasks-axi done' >/dev/null \
    && fail "teardown still asked a later turn to close the item it already closed: $out"
  pass "teardown closes its own backlog item before reporting success"
}

test_teardown_manual_backend_leaves_the_backlog_to_the_operator() {
  local case_dir out backlog_path
  case_dir=$(make_case tasks-axi-manual-optout)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  printf '%s\n' manual > "$case_dir/config/backlog-backend"
  seed_backlog_in_flight "$case_dir"

  out=$(run_teardown "$case_dir") || fail "teardown failed with manual backlog backend"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "manual backlog backend was mutated by teardown anyway"
  backlog_path=$(cd "$case_dir/data" && pwd -P)/backlog.md
  printf '%s\n' "$out" | grep -F "Update $backlog_path - move task-x1 to Done" >/dev/null \
    || fail "teardown did not prompt manual backlog update under opt-out: $out"
  pass "teardown honors config/backlog-backend=manual and still finishes cleanly"
}

test_endpoint_loss_marker_survives_failed_task_retirement() {
  local case_dir meta marker recorded_loss mark recorded_park
  case_dir=$(make_case endpoint-loss-retirement)
  write_meta "$case_dir" local-only ship
  meta="$case_dir/state/task-x1.meta"
  marker="$case_dir/state/task-x1.missing-endpoint"
  recorded_loss=$'tmux:firstmate:fm-task-x1\tteardown-test-task-x1'
  printf '%s\n' "$recorded_loss" > "$marker"
  mark="$case_dir/state/task-x1.parked-retained"
  PATH="$case_dir/fakebin:$PATH" FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-park-retained.sh" task-x1 mark >/dev/null \
    || fail "could not mark the parked task"
  recorded_park=$(cat "$mark") || fail "could not read the saved park mark"

  cat > "$case_dir/fakebin/rm" <<'SH'
#!/usr/bin/env bash
if [ "$#" -eq 2 ] && [ "$1" = -f ] && [ "$2" = "$FM_TEST_FAIL_META_UNLINK" ]; then
  exit 1
fi
exec "$REAL_RM_FOR_TEST" "$@"
SH
  chmod +x "$case_dir/fakebin/rm"
  if FM_TEST_FAIL_META_UNLINK="$meta" run_teardown "$case_dir" > "$case_dir/failed.out" 2>&1; then
    fail "teardown succeeded despite failing to remove the task record"
  fi
  assert_grep 'task record could not be removed' "$case_dir/failed.out" \
    "teardown did not reach the injected record removal failure"
  assert_present "$meta" "failed teardown removed the task record"
  [ "$(cat "$marker")" = "$recorded_loss" ] \
    || fail "failed teardown lost the acknowledged endpoint-loss record"
  [ "$(cat "$mark")" = "$recorded_park" ] || fail "failed teardown lost the park mark"

  rm -f "$case_dir/fakebin/rm"
  run_teardown "$case_dir" > "$case_dir/retry.out" 2>&1 \
    || fail "teardown retry failed: $(cat "$case_dir/retry.out")"
  assert_absent "$meta" "teardown retry kept the task record"
  assert_absent "$marker" "teardown retry kept the endpoint-loss record"
  assert_absent "$mark" "teardown retry kept the park mark"
  pass "teardown keeps endpoint-loss and park records until the task record is retired"
}

# A parked retained-copy mark only silences endpoint-loss reporting: cleanup
# must still refuse a copy holding unlanded work, keep the mark while the task
# record survives, and retire it with the record once the work has landed.
test_parked_retained_mark_does_not_relax_cleanup() {
  local case_dir mark rc
  case_dir=$(make_case parked-retained-mark)
  write_meta "$case_dir" local-only ship
  mark="$case_dir/state/task-x1.parked-retained"
  PATH="$case_dir/fakebin:$PATH" FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-park-retained.sh" task-x1 mark > /dev/null \
    || fail "could not mark the parked task"
  assert_present "$mark" "the park mark was not recorded"
  wt_commit "$case_dir" "unlanded parked work"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "parked mark: teardown should still refuse unlanded work"
  grep -q REFUSED "$case_dir/stderr" || fail "parked mark: no REFUSED line in stderr"
  assert_present "$mark" "a refused cleanup dropped the park mark"

  git -C "$case_dir/wt" reset -q --hard HEAD~1 || fail "could not drop the fixture commit"
  run_teardown "$case_dir" > "$case_dir/retry.out" 2>&1 \
    || fail "teardown of the landed parked task failed: $(cat "$case_dir/retry.out")"
  assert_absent "$mark" "cleanup kept the park mark after retiring the task record"
  pass "a parked retained-copy mark leaves cleanup's unlanded-work refusal intact and is retired with the record"
}

test_local_only_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case truly-unpushed)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unpushed work"
  # No fork, no push to origin, not merged into main.

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "truly-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "truly-unpushed: no REFUSED line in stderr"
  pass "local-only worktree with truly unpushed work is refused (safety preserved)"
}

test_local_only_merged_to_local_main_allows() {
  local case_dir rc
  case_dir=$(make_case merged-main)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "merged work"
  # Fast-forward the project's main to the worktree's HEAD commit so HEAD is
  # reachable from main. update-ref works whether or not main is checked out,
  # and the worktree shares the project's object db so the commit is visible.
  local wt_head
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "merged-main: teardown should succeed when work is merged into local main"
  ! grep -q REFUSED "$case_dir/stderr" || fail "merged-main: teardown printed a REFUSED line"
  pass "local-only worktree with work merged into local main is torn down (no regression)"
}

test_no_mistakes_origin_remote_allows() {
  local case_dir rc
  case_dir=$(make_case nm-origin)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  # Push the task branch to origin and fetch so the worktree sees it.
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "nm-origin: teardown should succeed when HEAD is on origin"
  ! grep -q REFUSED "$case_dir/stderr" || fail "nm-origin: teardown printed a REFUSED line"
  grep -F 'blockers are gone and date is due' "$case_dir/stdout" >/dev/null \
    || fail "nm-origin: teardown manual prompt did not preserve date-gate check"
  pass "no-mistakes worktree with HEAD on origin is torn down (no regression)"
}

test_no_mistakes_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case nm-unpushed)
  write_meta "$case_dir" no-mistakes ship
  # Real content that is not pushed, has no PR (default gh-axi mock), and never
  # landed on origin/main: genuinely unlanded work that must still refuse.
  wt_commit_file "$case_dir" feature.txt hello "unpushed work"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "nm-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "nm-unpushed: no REFUSED line in stderr"
  pass "no-mistakes worktree with genuinely unlanded work is refused (safety preserved)"
}

test_squash_merged_branch_deleted_allows() {
  local case_dir rc pr_head
  case_dir=$(make_case squash-merged)
  write_meta "$case_dir" no-mistakes ship
  # Real branch content that is NOT pushed and NOT on origin/main: a squash merge
  # rewrote it into a different commit on main and auto-deleted the head branch, so
  # HEAD is unreachable from every remote-tracking branch. The matching merged PR is
  # the only signal that the work landed.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-merged: teardown should succeed when the PR is merged"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-merged: teardown printed a REFUSED line"
  pass "squash-merged + deleted-branch worktree (PR merged) is torn down (the fix)"
}

test_squash_merged_pr_allows_when_head_ancestor_of_pr_head() {
  local case_dir rc local_head pr_head
  case_dir=$(make_case squash-ancestor)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes follow-up")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-ancestor: teardown should succeed when local HEAD is in the merged PR head"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-ancestor: teardown printed a REFUSED line"
  pass "squash-merged PR accepts a local HEAD that is an ancestor of the final PR head"
}

test_no_pr_recorded_discovers_merged_pr_by_branch_allows() {
  local case_dir rc local_head pr_head
  case_dir=$(make_case no-pr-branch-discovery)
  write_meta "$case_dir" no-mistakes ship
  # Reproduces the real false-refusal report exactly, with NO pr=/pr_head=
  # recorded in meta at all (fm-pr-check.sh was never run, e.g. a yolo merge on
  # a repo with no PR CI so the "checks green" trigger that fires it never
  # happened): a branch with a commit, a no-mistakes auto-fix commit pushed on
  # top that never made it back into the local worktree, a squash merge onto
  # main under a brand-new SHA, and the head branch deleted (simulated here by
  # never pushing fm/task-x1 at all, so no refs/remotes/origin/fm/task-x1
  # exists to make HEAD "reachable").
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes auto-fix")
  land_on_origin_main "$case_dir" feature.txt hello
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  seed_backlog_in_flight "$case_dir"
  # No append_pr_meta_* call: state/task-x1.meta has no pr= or pr_head= line.

  ! grep -qE '^(pr|pr_head)=' "$case_dir/state/task-x1.meta" \
    || fail "no-pr-branch-discovery: test setup bug, meta unexpectedly has a pr= line"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "no-pr-branch-discovery: teardown should succeed by discovering the merged PR from the branch name"
  ! grep -q REFUSED "$case_dir/stderr" || fail "no-pr-branch-discovery: teardown printed a REFUSED line"
  assert_grep 'https://github.com/example/repo/pull/7' "$case_dir/data/backlog.md" \
    "no-pr-branch-discovery: resolved PR URL was not recorded on completion"
  pass "teardown discovers a merged PR by branch name and tears down when no pr= was ever recorded"
}

test_squash_merged_pr_allows_replayed_unpushed_patch() {
  local case_dir rc parent_head pr_head
  case_dir=$(make_case squash-replayed-patch)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" local-parent.txt parent "local parent"
  parent_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/wt" push -q origin "$parent_head:refs/heads/fm/task-x1"
  git -C "$case_dir/project" fetch -q origin fm/task-x1
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  pr_head=$(land_equivalent_patch_on_origin_branch "$case_dir" pr-head feature.txt hello "add feature")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-replayed-patch: teardown should succeed when unpushed local patch is in the merged PR head"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-replayed-patch: teardown printed a REFUSED line"
  pass "squash-merged PR accepts replayed unpushed local patches contained in the PR head"
}

test_merged_pr_with_later_local_commit_refuses() {
  local case_dir rc pr_head
  case_dir=$(make_case stale-pr-head)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  wt_commit_file "$case_dir" later.txt local-only "local follow-up"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-pr-head: teardown should refuse when HEAD moved after PR recording"
  grep -q REFUSED "$case_dir/stderr" || fail "stale-pr-head: no REFUSED line in stderr"
  pass "merged PR does not allow teardown after a later local commit"
}

test_squash_merged_rebased_branch_allows() {
  local case_dir rc pr_head
  case_dir=$(make_case squash-rebased)
  write_meta "$case_dir" no-mistakes ship
  pr_head=$(setup_squash_rebased_history "$case_dir" rebased)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-rebased: teardown should succeed when the worktree followed the pipeline rebase"$'\n'"$(cat "$case_dir/stderr")"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-rebased: teardown printed a REFUSED line"
  pass "squash-merged task whose local branch followed the pipeline rebase is torn down"
}

test_squash_merged_same_file_different_content_refuses() {
  local case_dir rc pr_head local_head
  case_dir=$(make_case squash-same-path-diverged)
  write_meta "$case_dir" no-mistakes ship
  # The pipeline rebase produced a different blob for shared.txt than the stale
  # local still holds, then squash-merged. Same path is not proof the local
  # content landed.
  pr_head=$(setup_squash_rebased_history "$case_dir" stale)
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "squash-same-path-diverged: teardown should refuse when the same file has different content"$'\n'"$(cat "$case_dir/stderr")"
  grep -q REFUSED "$case_dir/stderr" || fail "squash-same-path-diverged: no REFUSED line in stderr"
  assert_refusal_retained_task_state "$case_dir" squash-same-path-diverged "$local_head"
  pass "squash-merged same-path different content still refuses"
}

# The local branch followed the pipeline rebase, so without later.txt this is the
# q2 ALLOW case exactly. The one unlanded follow-up commit is the sole difference
# and must be the sole reason teardown refuses.
test_squash_merged_rebased_local_with_unlanded_commit_refuses() {
  local case_dir rc pr_head local_head
  case_dir=$(make_case squash-rebased-unlanded)
  write_meta "$case_dir" no-mistakes ship
  pr_head=$(setup_squash_rebased_history "$case_dir" rebased-plus-unlanded)
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "squash-rebased-unlanded: teardown should refuse extra local commits that never landed"$'\n'"$(cat "$case_dir/stderr")"
  grep -q REFUSED "$case_dir/stderr" || fail "squash-rebased-unlanded: no REFUSED line in stderr"
  assert_refusal_retained_task_state "$case_dir" squash-rebased-unlanded "$local_head"
  pass "squash-merged rebased local still refuses a genuinely unlanded follow-up commit"
}

test_squash_merged_stale_local_refuses_when_forge_unreachable() {
  local case_dir rc pr_head local_head
  case_dir=$(make_case squash-stale-offline)
  write_meta "$case_dir" no-mistakes ship
  pr_head=$(setup_squash_rebased_history "$case_dir" stale)
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
  add_gh_axi_error "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "squash-stale-offline: teardown should refuse when the forge is down and trees conflict"$'\n'"$(cat "$case_dir/stderr")"
  grep -q REFUSED "$case_dir/stderr" || fail "squash-stale-offline: no REFUSED line in stderr"
  assert_refusal_retained_task_state "$case_dir" squash-stale-offline "$local_head"
  pass "squash-merged stale local still refuses when the forge is unreachable"
}

test_pr_check_does_not_refresh_stale_pr_head() {
  local case_dir rc pr_head new_head count
  case_dir=$(make_case pr-check-stale)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_HOME="$case_dir" FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  wt_commit_file "$case_dir" later.txt local-only "local follow-up"
  new_head=$(git -C "$case_dir/wt" rev-parse HEAD)

  FM_HOME="$case_dir" FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  count=$(grep -c '^pr_head=' "$case_dir/state/task-x1.meta" || true)
  expect_code 1 "$count" "pr-check-stale: stale rerun should not append a second pr_head"
  ! grep -qxF "pr_head=$new_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-stale: stale rerun recorded the later local HEAD"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "pr-check-stale: teardown should refuse after a later local commit"
  grep -q REFUSED "$case_dir/stderr" || fail "pr-check-stale: no REFUSED line in stderr"
  pass "fm-pr-check does not refresh PR head after HEAD moves"
}

test_pr_check_records_remote_head_when_local_lags() {
  local case_dir local_head pr_head
  case_dir=$(make_case pr-check-local-lags)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes follow-up")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_HOME="$case_dir" FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  grep -qxF "pr_head=$pr_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-local-lags: did not record GitHub PR head"
  ! grep -qxF "pr_head=$local_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-local-lags: recorded local HEAD instead of remote PR head"
  pass "fm-pr-check records the remote PR head when the local worktree lags"
}

test_content_in_default_fallback_allows() {
  local case_dir rc
  case_dir=$(make_case content-landed)
  write_meta "$case_dir" no-mistakes ship
  # No pr= recorded and the default gh-axi mock reports no PR, so the merged-PR path
  # cannot fire and the content check must carry it. The branch adds feature.txt, and
  # the same net change has independently landed on origin/main via a squash commit.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${FM_TEST_TREEHOUSE_LOG:?}"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  set +e
  FM_TEST_TREEHOUSE_LOG="$case_dir/treehouse.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-landed: teardown should succeed when content is already in the default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-landed: teardown printed a REFUSED line"
  assert_present "$case_dir/treehouse.log" \
    "content-landed: teardown never reached destructive worktree cleanup"
  assert_absent "$case_dir/state/task-x1.meta" \
    "content-landed: teardown left task metadata after destructive cleanup"
  pass "worktree whose content already landed in the default branch is torn down (content fallback)"
}

test_content_fallback_refreshes_stale_origin_ref() {
  local case_dir rc
  case_dir=$(make_case content-stale-ref)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  git -C "$case_dir/project" config --unset-all remote.origin.fetch
  git -C "$case_dir/project" config --add remote.origin.fetch '+refs/heads/not-main:refs/remotes/origin/not-main'
  land_on_origin_main "$case_dir" feature.txt hello

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-stale-ref: teardown should use the freshly fetched default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-stale-ref: teardown printed a REFUSED line"
  pass "content fallback refreshes origin default before comparing trees"
}

test_dirty_worktree_refuses() {
  local case_dir rc pr_head
  case_dir=$(make_case dirty-wt)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  # The committed work has fully landed (merged PR + content in default), but an
  # uncommitted edit remains. Dirtiness must refuse regardless: the reset would
  # discard those changes.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  printf '%s\n' "uncommitted edit" > "$case_dir/wt/feature.txt"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "dirty-wt: teardown should refuse a dirty worktree even when the committed work has landed"
  grep -q REFUSED "$case_dir/stderr" || fail "dirty-wt: no REFUSED line in stderr"
  grep -q "uncommitted changes" "$case_dir/stderr" || fail "dirty-wt: refusal did not cite uncommitted changes"
  pass "dirty worktree is refused even when its committed work has landed (dirty always wins)"
}

test_gh_error_and_content_absent_refuses() {
  local case_dir rc
  case_dir=$(make_case gh-error)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  # Real content not pushed, the PR lookup errors, and origin/main never gained the
  # content. The fail-safe must refuse rather than allow on a transient gh failure.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  add_gh_axi_error "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gh-error: teardown should refuse when the PR lookup errors and content is not landed"
  grep -q REFUSED "$case_dir/stderr" || fail "gh-error: no REFUSED line in stderr"
  pass "gh lookup error with content not in default refuses (fail-safe)"
}

# Write a meta that predates the spawn_gen field entirely. Args: case_dir mode kind
write_legacy_meta() {
  local case_dir=$1 mode=$2 kind=$3
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=$mode" \
    "harness=codex"
}

# Count spawn_gen fields in the task's meta, so a refusal can prove it left the
# record byte-equivalent rather than stamped.
legacy_meta_gen_count() {
  local case_dir=$1
  awk -F= '$1 == "spawn_gen" { count++ } END { print count + 0 }' \
    "$case_dir/state/task-x1.meta" 2>/dev/null || printf '0\n'
}

# Override fakebin/tmux so the recovery-grade classifier reads the endpoint as
# unreadable (a session inventory failure it cannot attribute), never dead.
add_unreadable_tmux() {
  local case_dir=$1
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) echo "error connecting to fixture: permission denied" >&2 ; exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
}

test_legacy_record_without_the_flag_refuses() {
  local case_dir rc
  case_dir=$(make_case legacy-noflag)
  write_legacy_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "legacy-noflag: a record without spawn_gen must refuse without --legacy-record"
  grep -q -- '--legacy-record' "$case_dir/stderr" \
    || fail "legacy-noflag: the refusal did not name the --legacy-record path"
  [ "$(legacy_meta_gen_count "$case_dir")" = 0 ] \
    || fail "legacy-noflag: the refusal stamped a spawn generation into the record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-noflag: the refusal closed the backlog item anyway"
  assert_present "$case_dir/state/task-x1.meta" \
    "legacy-noflag: the refusal removed the task record"
  pass "a record predating spawn_gen refuses teardown until --legacy-record is passed"
}

test_legacy_record_teardown_completes_when_landed_and_endpoint_dead() {
  local case_dir out
  case_dir=$(make_case legacy-allow)
  write_legacy_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"
  # The default fakebin tmux answers every query with success and no output, so
  # the classifier reads the recorded window as authoritatively missing.

  out=$(run_teardown "$case_dir" --legacy-record) \
    || fail "legacy-allow: teardown refused a landed legacy record with a dead endpoint"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "legacy-allow: teardown returned success with its backlog item still open"
  printf '%s\n' "$out" | grep -Fq 'legacy record accepted without spawn_gen: endpoint missing, incarnation legacy-' \
    || fail "legacy-allow: the teardown line did not log the accepted legacy incarnation: $out"
  assert_absent "$case_dir/state/task-x1.backlog-close" \
    "legacy-allow: a landed legacy close left its pending-close record behind"
  assert_absent "$case_dir/state/task-x1.meta" \
    "legacy-allow: teardown left the task record behind"
  pass "a landed legacy record with a dead endpoint tears down and logs its accepted incarnation"
}

test_legacy_record_teardown_refuses_unlanded_work() {
  local case_dir rc before
  case_dir=$(make_case legacy-unlanded)
  write_legacy_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  # Real content committed but pushed nowhere and merged nowhere.
  wt_commit_file "$case_dir" feature.txt unique-legacy-content "real unlanded work"
  before=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "legacy-unlanded: --legacy-record must not relax the unlanded-work refusal"
  grep -q REFUSED "$case_dir/stderr" \
    || fail "legacy-unlanded: no REFUSED line for unlanded legacy work"
  [ "$(legacy_meta_gen_count "$case_dir")" = 0 ] \
    || fail "legacy-unlanded: the unlanded refusal stamped a spawn generation into the record"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "legacy-unlanded: the unlanded refusal modified the task record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-unlanded: the unlanded refusal closed the backlog item anyway"
  pass "--legacy-record never relaxes the unlanded-work refusal"
}

test_legacy_record_teardown_refuses_an_ambiguous_endpoint() {
  local case_dir rc before
  case_dir=$(make_case legacy-ambiguous)
  write_legacy_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"
  add_unreadable_tmux "$case_dir"
  before=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "legacy-ambiguous: an unreadable endpoint must refuse the legacy acceptance"
  grep -q "not confidently dead or agent-less" "$case_dir/stderr" \
    || fail "legacy-ambiguous: the refusal did not name the endpoint state"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "legacy-ambiguous: the endpoint refusal modified the task record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-ambiguous: the endpoint refusal closed the backlog item anyway"
  pass "an endpoint that cannot be confidently read as dead refuses --legacy-record teardown"
}

test_legacy_record_rolls_the_stamp_back_when_the_marker_write_fails() {
  local case_dir rc before
  case_dir=$(make_case legacy-stamp-rollback)
  write_legacy_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=not-a-valid-url' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"
  before=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" \
    "legacy-stamp-rollback: an unrecordable close must fail the teardown after accepting the legacy record"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "legacy-stamp-rollback: the failed marker write left the record modified"
  grep -q "rolled back" "$case_dir/stderr" \
    || fail "legacy-stamp-rollback: the refusal did not report the rolled-back stamp"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-stamp-rollback: the failed teardown closed the backlog item anyway"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  rc=$?
  set -e
  expect_code 1 "$rc" \
    "legacy-stamp-rollback: the flag-less retry must not sail past the endpoint gate on the rolled-back record"
  grep -q -- '--legacy-record' "$case_dir/stderr2" \
    || fail "legacy-stamp-rollback: the retry refusal did not name the flag path"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "legacy-stamp-rollback: the flag-less retry modified the record"
  pass "--legacy-record teardown rolls its stamp back when the close marker write fails"
}

# Override fakebin/perl so ONLY the stamp rollback's truncate fails; every other
# perl call in the lifecycle still runs the real interpreter, so the abandoned
# attempt leaves its stamp behind for exactly the reason under test.
add_failing_truncate_perl() {
  local case_dir=$1 real
  real=$(command -v perl)
  cat > "$case_dir/fakebin/perl" <<SH
#!/usr/bin/env bash
case "\$*" in
  *truncate*) exit 1 ;;
esac
exec "$real" "\$@"
SH
  chmod +x "$case_dir/fakebin/perl"
}

test_retained_legacy_stamp_still_faces_the_endpoint_gate() {
  local case_dir rc stamped
  case_dir=$(make_case legacy-stamp-retained)
  write_legacy_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=not-a-valid-url' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"
  add_failing_truncate_perl "$case_dir"

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" \
    "legacy-stamp-retained: an unrecordable close must fail the teardown after accepting the legacy record"
  grep -q "could not be rolled back" "$case_dir/stderr" \
    || fail "legacy-stamp-retained: the fixture did not exercise a failed rollback"
  [ "$(legacy_meta_gen_count "$case_dir")" = 1 ] \
    || fail "legacy-stamp-retained: the abandoned attempt did not leave its stamp on the record"
  stamped=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  # The stamp the failed rollback left behind is the whole risk: a retry must
  # not read it as an incarnation some spawn published and sail past the
  # dead-or-agent-less endpoint gate onto a reused endpoint.
  add_unreadable_tmux "$case_dir"
  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  rc=$?
  set -e
  expect_code 1 "$rc" \
    "legacy-stamp-retained: the retry must re-run the endpoint gate on the retained stamp"
  grep -q "not confidently dead or agent-less" "$case_dir/stderr2" \
    || fail "legacy-stamp-retained: the retry skipped the dead-or-agent-less endpoint gate"
  [ "$(legacy_meta_gen_count "$case_dir")" = 1 ] \
    || fail "legacy-stamp-retained: the retry stamped a second incarnation into the record"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$stamped" ] \
    || fail "legacy-stamp-retained: the endpoint refusal modified the task record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-stamp-retained: the endpoint refusal closed the backlog item anyway"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout3" 2> "$case_dir/stderr3"
  rc=$?
  set -e
  expect_code 1 "$rc" \
    "legacy-stamp-retained: a flag-less retry must refuse the retained legacy stamp"
  grep -q -- '--legacy-record' "$case_dir/stderr3" \
    || fail "legacy-stamp-retained: the flag-less refusal did not name the flag path"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$stamped" ] \
    || fail "legacy-stamp-retained: the flag-less refusal modified the task record"
  pass "a legacy stamp a failed rollback left behind still faces the endpoint gate"
}

test_legacy_record_never_accepts_a_corrupt_spawn_gen() {
  local case_dir rc
  case_dir=$(make_case legacy-corrupt)
  write_legacy_meta "$case_dir" no-mistakes ship
  printf 'spawn_gen=one\nspawn_gen=two\n' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "legacy-corrupt: an ambiguous spawn_gen must refuse even with --legacy-record"
  grep -q "unreadable spawn_gen" "$case_dir/stderr" \
    || fail "legacy-corrupt: the refusal did not name the unreadable spawn_gen"
  [ "$(legacy_meta_gen_count "$case_dir")" = 2 ] \
    || fail "legacy-corrupt: the refusal rewrote the corrupt record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-corrupt: the refusal closed the backlog item anyway"
  pass "a corrupt spawn_gen is never accepted as a legacy record"
}

test_stale_index_lock_cleared_and_teardown_succeeds() {
  local case_dir rc lock
  case_dir=$(make_case stale-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "stale-index-lock: teardown should succeed after clearing the provably stale lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "stale-index-lock: teardown did not report clearing the stale lock"
  assert_absent "$lock" "stale-index-lock: stale lock file should have been removed"
  pass "provably-stale worktree index.lock (old, no live holder) is cleared and teardown succeeds"
}

test_live_index_lock_is_never_removed_and_teardown_refuses() {
  local case_dir rc lock
  case_dir=$(make_case live-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  # Even an old mtime must not be enough on its own: a live holder always wins.
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "live-index-lock: teardown should refuse when the lock has a live holder"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "live-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "live-index-lock: teardown removed a lock with a live holder"
  [ -e "$lock" ] || fail "live-index-lock: live-held lock file was removed"
  pass "live-held worktree index.lock is never removed and teardown refuses"
}

test_lsof_error_never_clears_index_lock() {
  local case_dir rc lock
  case_dir=$(make_case lsof-error-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_index_lock_error "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "lsof-error-index-lock: teardown should refuse when lsof errors"
  assert_grep "lsof check failed: lsof: simulated failure for $lock" "$case_dir/stderr" \
    "lsof-error-index-lock: teardown did not report the lsof failure"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "lsof-error-index-lock: teardown removed a lock after lsof failed"
  [ -e "$lock" ] || fail "lsof-error-index-lock: lock file was removed after lsof failed"
  pass "lsof errors leave worktree index.lock in place and refuse teardown"
}

test_worktree_safety_refusal_cancels_close() {
  local mode=$1 case_dir rc=0 lock
  case_dir=$(make_case "worktree-safety-refusal-$mode")
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt landed "landed work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  printf '%s\n' dirty > "$case_dir/wt/feature.txt"
  seed_backlog_in_flight "$case_dir"
  printf 'PR closure evidence\n' > "$case_dir/state/task-x1.pr-poll-closed"
  (
    # shellcheck disable=SC2030 # The fixture home is scoped to this subshell.
    export FM_HOME="$case_dir/home"
    # shellcheck source=bin/fm-backlog-transition-lib.sh
    . "$ROOT/bin/fm-backlog-transition-lib.sh"
    fm_backlog_close_marker_write "$case_dir/state" task-x1 "$case_dir/data" teardown-test-task-x1 --note 'local main'
  ) || fail 'could not stage the interrupted teardown close'

  add_lsof_no_holder "$case_dir"
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then touch "$FM_TEST_RETURN_LOG"; fi
SH
  chmod +x "$case_dir/fakebin/treehouse"
  if [ "$mode" = stale ]; then
    add_git_status_lock_failure "$case_dir"
    lock=$(git_index_lock_path "$case_dir/wt")
    touch -t 200001010000 "$lock"
  fi
  FM_TEST_RETURN_LOG="$case_dir/treehouse.log" \
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "worktree safety ($mode) should refuse dirty work"
  if [ "$mode" = stale ]; then
    assert_grep 'removed provably-stale git lock' "$case_dir/stderr" 'teardown did not report clearing the stale lock'
    assert_absent "$lock" 'teardown left the stale lock in place'
  fi
  assert_grep 'uncommitted changes present' "$case_dir/stderr" 'teardown did not report the dirty worktree'
  assert_absent "$case_dir/treehouse.log" 'safety refusal invoked Treehouse return'
  [ "$(cat "$case_dir/wt/feature.txt")" = dirty ] || fail 'safety refusal lost uncommitted work'
  [ "$(git -C "$case_dir/wt" symbolic-ref --short HEAD)" = fm/task-x1 ] || fail 'safety refusal changed the checkout'
  assert_pending_close_replay_preserves_task "$case_dir" task-x1 "$case_dir/home" \
    || fail 'startup replay changed the task after a safety refusal'
  pass "worktree safety refusal preserves dirty work and cancels the pending close ($mode)"
}

test_non_linked_index_lock_path_is_checked_from_worktree() {
  local case_dir rc lock
  case_dir=$(make_case non-linked-index-lock)
  git -C "$case_dir/project" worktree remove --force "$case_dir/wt"
  git clone -q "$case_dir/origin.git" "$case_dir/wt"
  git -C "$case_dir/wt" checkout -q -b fm/task-x1
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable normal clone work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/wt" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "non-linked-index-lock: teardown should clear a normal repo index.lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "non-linked-index-lock: teardown did not report clearing the stale lock"
  assert_absent "$lock" "non-linked-index-lock: stale lock file should have been removed"
  pass "normal repo index.lock is resolved from the worktree and cleared when stale"
}

test_index_lock_mtime_read_failure_refuses() {
  local case_dir rc lock
  # The mtime fault is injected by a fake stat on PATH; on Darwin the lock
  # helper now calls /usr/bin/stat directly, so the fake can never fire there.
  # Skip the Darwin run of this case.
  if [ "$(uname)" = Darwin ]; then
    pass "index-lock mtime fault injection is PATH-based; skipped on Darwin where stat is /usr/bin/stat"
    return
  fi
  case_dir=$(make_case mtime-error-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"
  add_stat_error "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "mtime-error-index-lock: teardown should refuse when lock mtime cannot be read"
  assert_grep "cannot read mtime for git lock" "$case_dir/stderr" \
    "mtime-error-index-lock: teardown did not report the mtime read failure"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "mtime-error-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "mtime-error-index-lock: teardown removed a lock after mtime read failed"
  [ -e "$lock" ] || fail "mtime-error-index-lock: lock file was removed after mtime read failed"
  pass "lock mtime read failures leave worktree index.lock in place and refuse teardown"
}

test_transient_index_lock_clears_after_first_attempt_and_retry_succeeds() {
  local case_dir rc lock attempt_file
  case_dir=$(make_case transient-index-lock-retry)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_transient_lock_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  # Fresh lock: not old enough for the force-remove path; patience must win.
  touch "$lock"

  attempt_file="$case_dir/treehouse-attempts"
  : > "$attempt_file"

  set +e
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=2 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "transient-index-lock: teardown should succeed on retry after lock self-clears"
  assert_grep "succeeded on retry" "$case_dir/stderr" \
    "transient-index-lock: teardown did not report success on retry"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "transient-index-lock: teardown force-removed a lock that only needed patience"
  [ "$(cat "$attempt_file")" = 2 ] \
    || fail "transient-index-lock: expected exactly 2 treehouse return attempts, got $(cat "$attempt_file")"
  assert_absent "$lock" "transient-index-lock: lock should remain cleared after success"
  if git -C "$case_dir/wt" show-ref --verify --quiet refs/heads/fm/task-x1; then
    fail 'successful lock retry retained the task branch'
  fi
  pass "transient index.lock cleared after first failed return is retried successfully without force-remove"
}

test_persistent_index_lock_exhausts_retries_and_refuses_loudly() {
  local case_dir rc lock
  case_dir=$(make_case persistent-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_persistent_lock_treehouse "$case_dir"
  seed_backlog_in_flight "$case_dir"
  printf 'PR closure evidence\n' > "$case_dir/state/task-x1.pr-poll-closed"
  # Fresh lock with a live holder: never provably stale, never force-removed.
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch "$lock"

  set +e
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=2 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "persistent-index-lock: teardown should refuse when the lock never clears"
  assert_grep "persisted across" "$case_dir/stderr" \
    "persistent-index-lock: teardown did not mention the exhausted retry window"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "persistent-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "persistent-index-lock: teardown removed a non-stale lock"
  [ -e "$lock" ] || fail "persistent-index-lock: lock file was removed"
  [ -f "$case_dir/state/task-x1.meta" ] \
    || fail "persistent-index-lock: teardown completed despite persistent lock"
  [ "$(git -C "$case_dir/wt" symbolic-ref --short HEAD)" = fm/task-x1 ] \
    || fail "persistent-index-lock: teardown left the task detached"
  assert_pending_close_replay_preserves_task "$case_dir" task-x1 "$case_dir/home" \
    || fail 'startup replay changed the task after a persistent lock'
  pass "persistent index.lock exhausts retries and refuses without force-removing the lock"
}

test_treehouse_owns_checkout_and_cancels_failed_close() {
  local mode=$1 case_dir copy tip expected_branch=fm/task-x1 rc=0
  if [ "$mode" = reftable ]; then
    case_dir=$(GIT_DEFAULT_REF_FORMAT=reftable make_case "treehouse-checkout-$mode")
    if [ "$(git -C "$case_dir/wt" config --local --get extensions.refStorage)" != reftable ]; then
      printf 'skip: Git does not support reftable fixtures\n'
      return 0
    fi
  else
    case_dir=$(make_case "treehouse-checkout-$mode")
  fi
  copy="$case_dir/wt"
  write_meta "$case_dir" no-mistakes ship
  if [ "$mode" = success ]; then
    mkdir -p "$case_dir/project/.Claude" "$case_dir/shared-settings/plugins"
    printf 'project settings\n' > "$case_dir/project/.Claude/README.md"
    printf 'project settings\n' > "$case_dir/project/.fm-Kimi-turnend"
    printf 'shared settings\n' > "$case_dir/shared-settings/plugins/fm-turn-end.js"
    ln -s ../shared-settings "$case_dir/project/.opencode"
    git -C "$case_dir/project" add -f .Claude/README.md .fm-Kimi-turnend .opencode
    git -C "$case_dir/project" commit -qm 'Track project settings on main'
  fi
  land_shippable_commit "$case_dir"
  seed_backlog_in_flight "$case_dir"
  printf 'PR closure evidence\n' > "$case_dir/state/task-x1.pr-poll-closed"
  tip=$(git -C "$copy" rev-parse HEAD)
  if [ "$mode" = detached ]; then
    git -C "$copy" checkout --detach -q
    expected_branch=HEAD
  fi
  add_lsof_no_holder "$case_dir"
  printf 'configured hook\n' > "$copy/.fm-grok-turnend"
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$(git -C "$3" rev-parse --abbrev-ref HEAD)" "$(git -C "$3" rev-parse HEAD)" > "$FM_TEST_RETURN_LOG"
if [ "$FM_TEST_RETURN_MODE" = success ]; then
  git -C "$3" checkout --detach -q main || exit $?
  mkdir -p "$3/.claude" || exit $?
  printf 'configured hook\n' > "$3/.claude/settings.local.json" || exit $?
  if [ "$3/.fm-Kimi-turnend" -ef "$3/.fm-kimi-turnend" ]; then
    mv "$3/.fm-Kimi-turnend" "$3/renaming-hook" || exit $?
    mv "$3/renaming-hook" "$3/.fm-kimi-turnend" || exit $?
  else
    printf 'configured hook\n' > "$3/.fm-kimi-turnend" || exit $?
  fi
  exit $?
fi
echo 'treehouse: simulated return error before checkout' >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/treehouse"
  FM_TEST_RETURN_MODE=$mode FM_TEST_RETURN_LOG="$case_dir/treehouse.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$(cat "$case_dir/treehouse.log")" = "$expected_branch $tip" ] \
    || fail 'Treehouse did not receive the original checkout'
  if [ "$mode" = success ]; then
    expect_code 0 "$rc" "Treehouse should return the copy and retire the record: $(cat "$case_dir/stderr")"
    assert_absent "$case_dir/state/task-x1.meta" 'successful return retained the task record'
    [ "$(backlog_row_state "$case_dir")" = 'done' ] || fail 'successful return did not close the task'
    [ "$(git -C "$copy" rev-parse --abbrev-ref HEAD)" = HEAD ] \
      && [ "$(git -C "$copy" rev-parse HEAD)" = "$(git -C "$copy" rev-parse main)" ] \
      || fail 'teardown changed the checkout left by Treehouse'
    [ "$(cat "$copy/.Claude/README.md")" = 'project settings' ] || fail 'return removed tracked project settings'
    assert_absent "$copy/.claude/settings.local.json" 'return retained a task hook under a project directory'
    [ "$(cat "$copy/.fm-Kimi-turnend")" = 'project settings' ] \
      || fail 'return removed tracked settings with a Unicode spelling'
    if [ "$case_dir/project/.fm-Kimi-turnend" -ef "$case_dir/project/.fm-kimi-turnend" ]; then
      [ "$copy/.fm-Kimi-turnend" -ef "$copy/.fm-kimi-turnend" ] \
        || fail 'return removed tracked settings through a filesystem alias'
    else
      assert_absent "$copy/.fm-kimi-turnend" 'return retained a distinct untracked task hook'
    fi
    [ "$(cat "$case_dir/shared-settings/plugins/fm-turn-end.js")" = 'shared settings' ] \
      || fail 'return removed settings outside the returned copy'
    assert_absent "$copy/.fm-grok-turnend" 'return retained an untracked task hook'
    git -C "$copy" checkout -qb fm/task-x1 || fail 'a fresh dispatch could not create the same task branch'
  else
    expect_code 1 "$rc" "failed Treehouse return ($mode) should retain the copy"
    assert_grep 'treehouse: simulated return error before checkout' "$case_dir/stderr" 'cleanup did not reach the failed return'
    [ "$(git -C "$copy" rev-parse --abbrev-ref HEAD)" = "$expected_branch" ] \
      && [ "$(git -C "$copy" rev-parse HEAD)" = "$tip" ] \
      || fail 'failed return changed the retained checkout'
    [ "$(git -C "$copy" rev-parse --verify refs/heads/fm/task-x1)" = "$tip" ] \
      || fail 'failed return changed the task ref'
    [ "$(cat "$copy/.fm-grok-turnend")" = 'configured hook' ] || fail 'failed return changed the task hook'
    assert_pending_close_replay_preserves_task "$case_dir" task-x1 "$case_dir/home" \
      || fail 'startup replay changed the retained task'
  fi
  pass "Treehouse owns the checkout and teardown handles its result ($mode)"
}

test_empty_retry_wait_uses_default_without_aborting() {
  local case_dir rc lock attempt_file
  case_dir=$(make_case empty-retry-wait)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_transient_lock_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"

  attempt_file="$case_dir/treehouse-attempts"
  : > "$attempt_file"

  set +e
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "empty-retry-wait: teardown should fall back to the default wait"
  assert_grep "waiting 1s and retrying" "$case_dir/stderr" \
    "empty-retry-wait: teardown did not use the default retry wait"
  [ "$(cat "$attempt_file")" = 2 ] \
    || fail "empty-retry-wait: expected exactly 2 treehouse return attempts, got $(cat "$attempt_file")"
  pass "empty retry wait overrides use the default without aborting teardown"
}

test_fractional_legacy_retry_wait_refuses_without_arithmetic_error() {
  local case_dir rc lock
  case_dir=$(make_case fractional-legacy-retry-wait)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_persistent_lock_treehouse "$case_dir"
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"

  set +e
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0.1 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "fractional-legacy-retry-wait: teardown should fail only for the persistent lock"
  assert_grep "waiting 0.1s each" "$case_dir/stderr" \
    "fractional-legacy-retry-wait: teardown did not preserve the legacy fractional wait"
  assert_not_contains "$(cat "$case_dir/stderr")" "syntax error" \
    "fractional-legacy-retry-wait: teardown hit an arithmetic error"
  pass "fractional legacy retry wait remains supported without arithmetic"
}

test_local_only_force_overrides_unpushed() {
  local case_dir rc
  case_dir=$(make_case force-override)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unpushed work"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "force-override: --force should bypass the unpushed-work check"
  ! grep -q REFUSED "$case_dir/stderr" || fail "force-override: REFUSED printed despite --force"
  pass "local-only worktree with unpushed work is torn down under --force (escape hatch)"
}

# Mark the case's home as a secondmate home bound to a parent: teardown and
# fm-pr-check run with FM_HOME="$case_dir/home" so the parent-channel
# publishers resolve that binding while the task state stays in $case_dir/state.
configure_secondmate_home() {  # <case-dir> <local|remote> [<parent-home>]
  local case_dir=$1 route=$2 parent=${3:-} home="$1/home"
  mkdir -p "$home"
  printf 'mate-x\n' > "$home/.fm-secondmate-home"
  {
    printf 'schema=fm-secondmate-parent.v1\nroute=%s\n' "$route"
    [ "$route" != local ] || printf 'parent_home=%s\n' "$parent"
  } > "$home/.fm-secondmate-parent"
  if [ "$route" = local ]; then
    # A local parent registers the mate; teardown resolves that registration.
    mkdir -p "$parent/state" "$parent/data"
    fm_write_secondmate_meta "$parent/state/mate-x.meta" "$home"
    printf -- '- mate-x - fixture scope (home: %s; scope: fixture; projects: alpha; added 2026-07-14)\n' \
      "$home" > "$parent/data/secondmates.md"
  fi
}

# Registering a PR inside a secondmate home publishes the child's ready line
# with the canonical URL on the parent channel from fm-pr-check itself, once;
# a main home publishes nothing.
test_secondmate_pr_registration_publishes_ready_line() {
  local case_dir pr_head channel url main_home
  url=https://github.com/example/repo/pull/7
  case_dir=$(make_case mate-pr-ready)
  configure_secondmate_home "$case_dir" local "$case_dir/parent"
  mkdir -p "$case_dir/parent/state"
  channel="$case_dir/parent/state/mate-x.status"
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    PATH="$case_dir/fakebin:$PATH" "$PR_CHECK" task-x1 "$url" > "$case_dir/pr-check.out" 2> "$case_dir/pr-check.err" \
    || fail "mate-pr-ready: fm-pr-check failed: $(cat "$case_dir/pr-check.err")"
  grep -q '^armed:' "$case_dir/pr-check.out" || fail "mate-pr-ready: poll was not armed"
  assert_grep "done [key=child-pr-task-x1]: child task-x1 PR ready: $url mode=no-mistakes" "$channel" \
    "mate-pr-ready: the ready line did not reach the parent channel"
  ! grep -q '^actionable:' "$case_dir/pr-check.err" \
    || fail "mate-pr-ready: registration reported a channel problem: $(cat "$case_dir/pr-check.err")"
  FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    PATH="$case_dir/fakebin:$PATH" "$PR_CHECK" task-x1 "$url" >/dev/null 2>&1 \
    || fail "mate-pr-ready: re-registration failed"
  [ "$(grep -c 'child-pr-task-x1' "$channel")" -eq 1 ] \
    || fail "mate-pr-ready: re-registration duplicated the ready line"

  case_dir=$(make_case main-pr-ready)
  main_home="$case_dir/main-home"
  mkdir -p "$main_home/state" "$main_home/data"
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  add_gh_pr_merged_for_head "$case_dir" "$(git -C "$case_dir/wt" rev-parse HEAD)"
  FM_HOME="$main_home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    PATH="$case_dir/fakebin:$PATH" "$PR_CHECK" task-x1 "$url" >/dev/null 2> "$case_dir/pr-check.err" \
    || fail "main-pr-ready: fm-pr-check failed"
  ! grep -q '^actionable:' "$case_dir/pr-check.err" \
    || fail "main-pr-ready: a main home reported a channel problem"
  [ ! -e "$main_home/state/parent-replies.status" ] \
    || fail "main-pr-ready: a main home wrote a parent reply"
  [ ! -e "$main_home/state/mate-x.status" ] \
    || fail "main-pr-ready: a main home published to a parent channel"
  [ ! -e "$case_dir/state/parent-replies.status" ] \
    || fail "main-pr-ready: a main home wrote a parent reply to task state"
  pass "fm-pr-check publishes the PR-ready line on a secondmate's parent channel once"
}

# Tearing a child down inside a secondmate home delivers the child's final
# ledger line to the parent before the record goes, and refuses (retaining
# every record) while the parent channel cannot be written; a rerun after the
# repair delivers and completes.
test_secondmate_home_teardown_delivers_final_line_or_refuses() {
  local case_dir rc channel wt_head err seq generation

  case_dir=$(make_case mate-teardown-delivers)
  configure_secondmate_home "$case_dir" local "$case_dir/parent"
  mkdir -p "$case_dir/parent/state"
  channel="$case_dir/parent/state/mate-x.status"
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "merged work"
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"
  printf 'working: shipping\ndone: PR https://github.com/example/repo/pull/9 checks green\n' \
    > "$case_dir/state/task-x1.status"
  set +e
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "mate-teardown-delivers: teardown should succeed: $(cat "$case_dir/stderr")"
  grep -Eq '^done \[key=child-outcome-task-x1-done-[0-9a-f]{8}\]: child task-x1 done: PR https://github.com/example/repo/pull/9 checks green pr=https://github.com/example/repo/pull/9 mode=local-only$' "$channel" \
    || fail "mate-teardown-delivers: the final ledger line did not reach the parent: $(cat "$channel" 2>/dev/null)"
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "mate-teardown-delivers: teardown left the task record"

  case_dir=$(make_case mate-teardown-refuses)
  configure_secondmate_home "$case_dir" local "$case_dir/parent"
  # The channel path is occupied by a directory, so no line can be appended.
  mkdir -p "$case_dir/parent/state/mate-x.status"
  channel="$case_dir/parent/state/mate-x.status"
  write_meta "$case_dir" local-only ship
  mkdir -p "$case_dir/tasktmp"
  printf '!\n' > "$case_dir/state/task-x1.grok-turnend-token"
  printf '!\n' > "$case_dir/state/task-x1.kimi-turnend-token"
  printf 'tasktmp=%s\n' "$case_dir/tasktmp" >> "$case_dir/state/task-x1.meta"
  wt_commit "$case_dir" "merged work"
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"
  printf 'done: PR https://github.com/example/repo/pull/9 checks green\n' > "$case_dir/state/task-x1.status"
  set +e
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "mate-teardown-refuses: teardown proceeded with an undelivered final line"
  grep -q 'has not reached the parent channel' "$case_dir/stderr" \
    || fail "mate-teardown-refuses: refusal did not name the parent channel: $(cat "$case_dir/stderr")"
  [ -f "$case_dir/state/task-x1.meta" ] && [ -f "$case_dir/state/task-x1.status" ] \
    || fail "mate-teardown-refuses: refusal did not retain the task records"
  [ -f "$case_dir/state/task-x1.grok-turnend-token" ] \
    && [ -f "$case_dir/state/task-x1.kimi-turnend-token" ] \
    && [ -d "$case_dir/tasktmp" ] \
    || fail "mate-teardown-refuses: refusal removed endpoint records before parent delivery"
  rmdir "$channel"
  err=$(FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-wake-drain.sh" 2>&1 >/dev/null)
  seq=$(printf '%s\n' "$err" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p')
  generation=$(printf '%s\n' "$err" | sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p')
  [ -z "$seq" ] || FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$generation" >/dev/null
  set +e
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  rc=$?
  set -e
  expect_code 0 "$rc" "mate-teardown-refuses: rerun after repair should succeed: $(cat "$case_dir/stderr2")"
  grep -Eq '^done \[key=child-outcome-task-x1-done-[0-9a-f]{8}\]: child task-x1 done: PR https://github.com/example/repo/pull/9 checks green' "$channel" \
    || fail "mate-teardown-refuses: the rerun did not deliver the final line"
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "mate-teardown-refuses: rerun left the task record"
  pass "a secondmate home's teardown delivers the child's final line or refuses until it can"
}

test_teardown_missing_busy_sidecar_completes() {
  local case_dir gen rc
  case_dir=$(make_case missing-busy-sidecar)
  write_meta "$case_dir" local-only ship
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$case_dir/state" task-x1)
  printf 'busy_gen=%s\n' "$gen" >> "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.busy-gen"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "missing-busy-sidecar: teardown should treat the incarnation as already retired"
  assert_absent "$case_dir/state/task-x1.busy-state" \
    "missing-busy-sidecar: teardown left the orphan busy record"
  assert_absent "$case_dir/state/task-x1.meta" \
    "missing-busy-sidecar: teardown remained incomplete"
  pass "teardown completes when an exact busy-state sidecar is already absent"
}

test_herdr_teardown_clears_escalation_marker() {
  local case_dir marker
  case_dir=$(make_case herdr-marker-cleanup)
  write_meta "$case_dir" local-only ship
  sed -i.bak 's/^window=.*/window=default:wG:pQ/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=default' \
    'herdr_workspace_id=wG' \
    'herdr_tab_id=wG:tQ' \
    'herdr_pane_id=wG:pQ' 'herdr_terminal_id=term-task' >> "$case_dir/state/task-x1.meta"
  # A reachable session whose exact pane is already structurally gone: the
  # locked close is a no-op and the record gate sees a confirmed-gone pane.
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "session list") printf '%s\n' '{"sessions":[{"name":"default","running":true,"socket_path":"$case_dir/herdr.sock"}]}' ;;
  "status --json") printf '%s\n' '{"server":{"running":true}}' ;;
  "pane get") printf '%s\n' '{"error":{"code":"pane_not_found"}}'; exit 1 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
  marker="$case_dir/state/.herdr-escalated-default_wG_pQ"
  : > "$marker"

  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-marker-cleanup: forced teardown failed: $(cat "$case_dir/stderr")"
  [ ! -e "$marker" ] || fail "herdr-marker-cleanup: teardown left the pane's escalation marker behind"
  pass "herdr teardown removes pane-owned escalation dedupe state"
}

# Flat (non-projected) Herdr endpoint whose fake pane exists until a locked
# close removes it. The socket path is case-local so the derived presentation
# lock never collides with another test or a real fleet session.
configure_flat_herdr_teardown_case() {  # <case-dir>
  local case_dir=$1
  sed -i.bak 's/^window=.*/window=default:wG:pQ/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=default' \
    'herdr_workspace_id=wG' \
    'herdr_tab_id=wG:tQ' \
    'herdr_pane_id=wG:pQ' 'herdr_terminal_id=term-task' >> "$case_dir/state/task-x1.meta"
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "\${FM_FAKE_HERDR_LOG:?}"
case "\${1:-} \${2:-}" in
  "workspace list")
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"wH","active_tab_id":"wH:t1","focused":true},{"workspace_id":"wG","active_tab_id":"wG:tQ","focused":false}]}}'
    ;;
  "tab list")
    case "\$*" in
      *"--workspace wH"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"wH:t1","focused":true}]}}' ;;
      *"--workspace wG"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"wG:tQ","workspace_id":"wG"}]}}' ;;
      *) printf '%s\n' '{"result":{"tabs":[]}}' ;;
    esac
    ;;
  "pane list")
    printf '%s\n' '{"result":{"panes":[{"pane_id":"wG:pQ","tab_id":"wG:tQ"}]}}'
    ;;
  "status --json")
    printf '%s\n' '{"server":{"running":true}}'
    ;;
  "session list")
    if [ "\${FM_FAKE_HERDR_SESSION_LIST_GARBAGE:-0}" = 1 ]; then
      printf '%s\n' 'not-json'
    else
      printf '%s\n' '{"sessions":[{"name":"default","running":true,"socket_path":"$case_dir/herdr.sock"}]}'
    fi
    ;;
  "pane close")
    : > "\${FM_FAKE_HERDR_CLOSED:?}"
    ;;
  "pane get")
    if [ "\${FM_FAKE_HERDR_PANE_GET_GARBAGE:-0}" = 1 ]; then
      printf '%s\n' 'not-json'
      exit 0
    fi
    if [ -e "\${FM_FAKE_HERDR_CLOSED:?}" ]; then
      printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
      exit 1
    fi
    printf '%s\n' '{"result":{"pane":{"pane_id":"wG:pQ","tab_id":"wG:tQ","workspace_id":"wG","terminal_id":"term-task"}}}'
    ;;
  "agent get")
    printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
    exit 1
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_herdr_flat_teardown_refuses_orphaning_records_then_retry_completes() {
  local case_dir log closed lock ready release holder_pid rc thlog
  case_dir=$(make_case herdr-orphan-refusal)
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; : > "$log"
  closed="$case_dir/closed"
  : > "$case_dir/state/task-x1.status"
  : > "$case_dir/state/task-x1.turn-ended"
  # Record every treehouse invocation: the contended-lock refusal must fire
  # BEFORE the isolated copy is returned, so phase 1 may not invoke it at all.
  thlog="$case_dir/treehouse.log"; : > "$thlog"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$thlog"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  lock=$(FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" PATH="$case_dir/fakebin:$PATH" \
    bash -c '. "$0/bin/fm-backend.sh" && fm_backend_source herdr; fm_backend_herdr_presentation_session_lock_path default' "$ROOT") \
    || fail "herdr-orphan-refusal: could not resolve the fixture presentation lock path"
  ready="$case_dir/lock-ready"; release="$case_dir/lock-release"
  ROOT="$ROOT" LOCK="$lock" READY="$ready" RELEASE="$release" bash -c '
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$LOCK" || exit 1
    : > "$READY"
    while [ ! -e "$RELEASE" ]; do sleep 0.1; done
    fm_lock_release "$LOCK"
  ' &
  holder_pid=$!
  local waited=0
  while [ ! -e "$ready" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  [ -e "$ready" ] || fail "herdr-orphan-refusal: the contending lock holder never started"

  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  if [ "$rc" -eq 0 ]; then
    : > "$release"; wait "$holder_pid" 2>/dev/null || true
    fail "herdr-orphan-refusal: teardown reported success while the exact pane still existed under lock contention"
  fi
  [ -e "$case_dir/state/task-x1.meta" ] || { : > "$release"; fail "herdr-orphan-refusal: refusal erased the durable endpoint metadata"; }
  [ -e "$case_dir/state/task-x1.status" ] || { : > "$release"; fail "herdr-orphan-refusal: refusal erased the task status record"; }
  [ -e "$case_dir/state/task-x1.turn-ended" ] || { : > "$release"; fail "herdr-orphan-refusal: refusal erased the turn-end record"; }
  assert_grep "presentation lock is contended" "$case_dir/stderr" \
    "herdr-orphan-refusal: the pre-return refusal was not explained visibly"
  if [ -s "$thlog" ]; then
    : > "$release"; fail "herdr-orphan-refusal: the contended refusal still returned the isolated copy: $(cat "$thlog")"
  fi
  [ -d "$case_dir/wt" ] || { : > "$release"; fail "herdr-orphan-refusal: the contended refusal removed the isolated copy"; }
  if [ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" != "fm/task-x1" ]; then
    : > "$release"; fail "herdr-orphan-refusal: the contended refusal dropped the task branch before refusing"
  fi
  if grep -q "teardown task-x1 complete" "$case_dir/stdout"; then
    : > "$release"; fail "herdr-orphan-refusal: refusal still reported cleanup complete"
  fi
  if grep -q "^pane close" "$log"; then
    : > "$release"; fail "herdr-orphan-refusal: an unlocked pane close was attempted under contention"
  fi

  : > "$release"
  wait "$holder_pid" 2>/dev/null || true
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout2" 2> "$case_dir/stderr2" \
    || fail "herdr-orphan-refusal: the retry after lock release failed: $(cat "$case_dir/stderr2")"
  [ -e "$closed" ] || fail "herdr-orphan-refusal: the retry never closed the pane under the lock"
  [ -s "$thlog" ] || fail "herdr-orphan-refusal: the successful retry never returned the isolated copy"
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "herdr-orphan-refusal: the successful retry left the metadata behind"
  [ ! -e "$case_dir/state/task-x1.status" ] || fail "herdr-orphan-refusal: the successful retry left the status record behind"
  grep -q "teardown task-x1 complete" "$case_dir/stdout2" \
    || fail "herdr-orphan-refusal: the successful retry did not report completion"
  pass "herdr flat teardown refuses before returning the isolated copy under lock contention and the retry completes cleanly"
}

test_herdr_flat_teardown_refuses_records_on_unparseable_presence() {
  local case_dir log closed rc
  case_dir=$(make_case herdr-garbage-presence)
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; : > "$log"
  closed="$case_dir/closed"
  : > "$case_dir/state/task-x1.status"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_PANE_GET_GARBAGE=1 \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "herdr-garbage-presence: teardown erased records on an unparseable pane presence"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "herdr-garbage-presence: ambiguous presence erased the durable endpoint metadata"
  [ -e "$case_dir/state/task-x1.status" ] \
    || fail "herdr-garbage-presence: ambiguous presence erased the task status record"
  assert_grep "identity 'unreadable'" "$case_dir/stderr" \
    "herdr-garbage-presence: the ambiguity refusal was not explained visibly"
  pass "herdr flat teardown never erases records when pane presence is unparseable"
}

assert_herdr_teardown_preflight_refuses_before_changes() {
  local mode=$1 case_dir log closed rc thlog teardown_bin
  case_dir=$(make_case "herdr-preflight-$mode")
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; : > "$log"
  closed="$case_dir/closed"
  : > "$case_dir/state/task-x1.status"
  : > "$case_dir/state/task-x1.turn-ended"
  thlog="$case_dir/treehouse.log"; : > "$thlog"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$thlog"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  teardown_bin=$TEARDOWN
  case "$mode" in
    missing-adapter|missing-parser|missing-explicit-close-helper)
      mkdir -p "$case_dir/test-root"
      cp -R "$ROOT/bin" "$case_dir/test-root/bin"
      if [ "$mode" = missing-adapter ]; then
        rm -f "$case_dir/test-root/bin/backends/herdr.sh"
      elif [ "$mode" = missing-explicit-close-helper ]; then
        sed -i.bak 's/^fm_backend_herdr_explicit_close_pane_confirmed()/fm_backend_herdr_explicit_close_pane_confirmed_unavailable()/' \
          "$case_dir/test-root/bin/backends/herdr.sh"
        rm -f "$case_dir/test-root/bin/backends/herdr.sh.bak"
      else
        sed -i.bak 's/^fm_backend_herdr_parse_target()/fm_backend_herdr_parse_target_unavailable()/' \
          "$case_dir/test-root/bin/backends/herdr.sh"
        rm -f "$case_dir/test-root/bin/backends/herdr.sh.bak"
      fi
      teardown_bin="$case_dir/test-root/bin/fm-teardown.sh"
      ;;
  esac
  rc=0
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
    FM_CONFIG_OVERRIDE="$case_dir/config" FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    FM_FAKE_HERDR_SESSION_LIST_GARBAGE="$([ "$mode" = unresolvable-lock ] && printf 1 || printf 0)" \
    PATH="$case_dir/fakebin:$PATH" \
    "$teardown_bin" task-x1 --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-preflight-$mode: teardown continued without its required preflight"
  assert_grep "nothing was changed" "$case_dir/stderr" \
    "herdr-preflight-$mode: the retryable pre-return refusal was not explained visibly"
  [ -d "$case_dir/wt" ] || fail "herdr-preflight-$mode: refusal removed the isolated copy"
  [ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "fm/task-x1" ] \
    || fail "herdr-preflight-$mode: refusal dropped the task branch"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "herdr-preflight-$mode: refusal erased the durable endpoint metadata"
  [ -e "$case_dir/state/task-x1.status" ] \
    || fail "herdr-preflight-$mode: refusal erased the task status record"
  [ -e "$case_dir/state/task-x1.turn-ended" ] \
    || fail "herdr-preflight-$mode: refusal erased the turn-end record"
  [ ! -s "$thlog" ] || fail "herdr-preflight-$mode: refusal returned the isolated copy"
  [ ! -e "$closed" ] || fail "herdr-preflight-$mode: refusal attempted an unlocked pane close"
}

test_herdr_flat_teardown_preflight_refuses_before_changes() {
  assert_herdr_teardown_preflight_refuses_before_changes unresolvable-lock
  assert_herdr_teardown_preflight_refuses_before_changes missing-adapter
  assert_herdr_teardown_preflight_refuses_before_changes missing-parser
  assert_herdr_teardown_preflight_refuses_before_changes missing-explicit-close-helper
  pass "herdr flat teardown preflight refuses before every destructive change"
}

configure_secondmate_with_herdr_child() {  # <case-dir>
  local case_dir=$1 home="$1/secondmate-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  fm_write_meta "$home/state/child-herdr.meta" \
    "window=childsession:wC:p1" \
    "endpoint_task_id=child-herdr" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only" \
    "backend=herdr" \
    "herdr_session=childsession" \
    "herdr_workspace_id=wC" \
    "herdr_tab_id=wC:t1" \
    "herdr_pane_id=wC:p1" "herdr_terminal_id=term-task"
  : > "$home/state/child-herdr.status"
  : > "$home/state/child-herdr.turn-ended"
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "\${FM_FAKE_HERDR_LOG:?}"
case "\${1:-} \${2:-}" in
  "session list")
    if [ "\${FM_FAKE_HERDR_SESSION_LIST_GARBAGE:-0}" = 1 ]; then
      printf '%s\n' 'not-json'
    else
      printf '%s\n' '{"sessions":[{"name":"childsession","running":true,"socket_path":"$case_dir/child.sock"}]}'
    fi
    ;;
  "workspace list") exit 1 ;;
  "pane get")
    if [ -e "\${FM_FAKE_HERDR_CLOSED:?}" ]; then
      if [ "\${FM_FAKE_HERDR_PRESENCE_UNKNOWN:-0}" = 1 ]; then
        printf '%s\n' 'not-json'
      else
        printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
        exit 1
      fi
    else
      printf '%s\n' '{"result":{"pane":{"pane_id":"wC:p1","tab_id":"wC:t1","workspace_id":"wC","terminal_id":"term-task"}}}'
    fi
    ;;
  "pane close") : > "\${FM_FAKE_HERDR_CLOSED:?}" ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_forced_secondmate_herdr_child_preflight_refuses_before_changes() {
  local case_dir home log closed rc thlog
  case_dir=$(make_case herdr-child-preflight)
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_herdr_child "$case_dir"
  home="$case_dir/secondmate-home"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; thlog="$case_dir/treehouse.log"
  : > "$log"; : > "$thlog"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$thlog"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    FM_FAKE_HERDR_SESSION_LIST_GARBAGE=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-child-preflight: teardown continued through an unresolvable child lock"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "herdr-child-preflight: refusal erased the parent record"
  [ -e "$home/state/child-herdr.meta" ] || fail "herdr-child-preflight: refusal erased the child record"
  [ -e "$home/state/child-herdr.status" ] || fail "herdr-child-preflight: refusal erased child status"
  [ -d "$home" ] || fail "herdr-child-preflight: refusal removed the secondmate home"
  [ ! -s "$thlog" ] || fail "herdr-child-preflight: refusal returned work before child preflight"
  [ ! -e "$closed" ] || fail "herdr-child-preflight: refusal attempted a child close"
  assert_grep "nothing was changed" "$case_dir/stderr" \
    "herdr-child-preflight: refusal did not explain its non-mutating boundary: $(cat "$case_dir/stderr")"
  pass "forced secondmate teardown preflights every Herdr child before cleanup mutation"
}

configure_secondmate_with_tmux_children() {  # <case-dir> [child-b-worktree]
  local case_dir=$1 home="$1/secondmate-home" child child_wt
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  for child in child-a child-b; do
    child_wt="$case_dir/$child-wt"
    [ "$child" != child-b ] || child_wt=${2:-$child_wt}
    git -C "$case_dir/project" worktree add -q -b "fm/$child" "$child_wt" main
    fm_write_meta "$home/state/$child.meta" \
      "window=firstmate:fm-$child" \
      "endpoint_task_id=$child" \
      "worktree=$child_wt" \
      "project=$case_dir/project" \
      "kind=ship" \
      "mode=local-only"
    : > "$home/state/$child.status"
  done
}

seed_descendant_close_for_replay() (
  # shellcheck disable=SC2030,SC2031 # Use the descendant home only while staging its close marker.
  export FM_HOME=$1
  local id=$2 state="$1/state" data=${3:-$1/data} gen=descendant-fixture-gen
  printf 'spawn_gen=%s\n' "$gen" >> "$state/$id.meta"
  printf 'PR closure evidence\n' > "$state/$id.pr-poll-closed"
  seed_backlog_in_flight "$FM_HOME" ship "$id" "$data" || exit 1
  # shellcheck source=bin/fm-backlog-transition-lib.sh
  . "$ROOT/bin/fm-backlog-transition-lib.sh"
  fm_backlog_close_marker_write "$state" "$id" "$data" "$gen" --note 'local main'
)

assert_pending_close_replay_preserves_task() (
  # shellcheck disable=SC2030,SC2031 # Use the fixture home only during replay and its assertions.
  export FM_HOME=${3:-$1}
  local id=$2 state="$1/state" data=${4:-$1/data} row
  # shellcheck source=bin/fm-tasks-axi-lib.sh
  . "$ROOT/bin/fm-tasks-axi-lib.sh"
  # shellcheck source=bin/fm-backlog-transition-lib.sh
  . "$ROOT/bin/fm-backlog-transition-lib.sh"
  fm_backlog_close_marker_replay "$state" "$state/$id.backlog-close" "$data" \
    || fail 'startup replay failed after teardown failure'
  assert_absent "$state/$id.backlog-close" 'teardown failure left a replayable close'
  assert_present "$state/$id.meta" 'startup replay retired the retained task'
  [ "$(cat "$state/$id.pr-poll-closed")" = 'PR closure evidence' ] || fail 'startup replay removed PR evidence'
  row=$(tasks-axi show "$id" --file "$data/backlog.md") || fail 'could not read the retained backlog row'
  [[ "$row" == *'state: in_flight'* ]] || fail 'startup replay changed the retained backlog row'
)

test_child_removal_failure_preserves_copy() {
  local mode=$1 case_dir home copy marker rc=0 expected_rc diagnostic test_path=$PATH
  case_dir=$(make_case "child-failed-return-$mode")
  home="$case_dir/secondmate-home"
  copy="$case_dir/child-a-wt"
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_tmux_children "$case_dir"
  seed_descendant_close_for_replay "$home" child-a || fail 'could not stage the descendant close'
  marker="$home/state/child-a.backlog-close"
  cp "$marker" "$case_dir/close-before"
  if [ "$mode" = nested ]; then
    printf '%s\n' child-a > "$copy/.fm-secondmate-home"
    fm_write_meta "$home/state/child-a.meta" kind=secondmate "home=$copy" "worktree=$copy" \
      "project=$case_dir/project" window=firstmate:fm-child-a endpoint_task_id=child-a spawn_gen=descendant-fixture-gen
  fi
  if [ "$mode" = lock ]; then
    add_persistent_lock_treehouse "$case_dir"
    add_lsof_live_holder "$case_dir"
    touch "$(git_index_lock_path "$copy")"
    expected_rc=2
    diagnostic='not provably stale'
  else
    add_lsof_no_holder "$case_dir"
    cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
echo 'treehouse: simulated child return error' >&2
exit 1
SH
    cat > "$case_dir/fakebin/rm" <<'SH'
#!/usr/bin/env bash
if [ "${*: -1}" = "$FM_TEST_RETAINED_CHILD_COPY" ]; then
  echo 'rm: simulated child removal failure' >&2
  exit 1
fi
exec "$REAL_RM_FOR_TEST" "$@"
SH
    chmod +x "$case_dir/fakebin/treehouse" "$case_dir/fakebin/rm"
    expected_rc=1
    diagnostic='rm: simulated child removal failure'
    if [ "$mode" = direct ]; then
      rm "$case_dir/fakebin/treehouse"
      test_path=$(make_path_without_lsof "$case_dir")
    fi
  fi
  FM_TEST_RETAINED_CHILD_COPY="$copy" \
    FM_TEARDOWN_TEST_PATH="$test_path" \
    FM_TREEHOUSE_RETURN_LOCK_RETRIES=0 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code "$expected_rc" "$rc" "child return ($mode) should retain the copy"
  assert_grep "$diagnostic" "$case_dir/stderr" "child return ($mode) did not reach the expected failure"
  [ "$(git -C "$copy" symbolic-ref --short HEAD)" = fm/child-a ] || fail 'child failure changed the checkout'
  assert_present "$case_dir/state/task-x1.meta" 'child failure retired the parent record'
  if [ "$mode" = direct ] || [ "$mode" = nested ]; then
    cmp -s "$case_dir/close-before" "$marker" || fail 'plain removal failure changed the pending close'
    assert_present "$home/state/child-a.meta" 'plain removal failure retired the child record'
  else
    assert_pending_close_replay_preserves_task "$home" child-a || fail 'startup replay changed the retained child task'
  fi
  pass "failed child removal retains the copy and handles its pending close ($mode)"
}

test_forced_secondmate_teardown_preflights_all_child_copies() {
  local layout=$1 case_dir home child_b backlog_data rc=0
  case_dir=$(make_case "descendant-caller-$layout")
  home="$case_dir/secondmate-home"
  backlog_data="$case_dir/relocated/data"
  child_b="$case_dir/child-b-wt"
  if [ "$layout" = pool ]; then
    child_b="$case_dir/pool/2/project"
    mkdir -p "$case_dir/pool/2"
    printf '{}\n' > "$case_dir/pool/treehouse-state.json"
  fi
  git -C "$case_dir/project" worktree add -q --detach "$home" main
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_tmux_children "$case_dir" "$child_b"
  seed_descendant_close_for_replay "$home" child-b "$backlog_data" || fail 'could not stage the descendant close'
  (
    # shellcheck disable=SC2030,SC2031 # Scope the secondmate home to the replay subtest.
    export FM_HOME="$home"
    # shellcheck source=bin/fm-tasks-axi-lib.sh
    . "$ROOT/bin/fm-tasks-axi-lib.sh"
    # shellcheck source=bin/fm-backlog-transition-lib.sh
    . "$ROOT/bin/fm-backlog-transition-lib.sh"
    if fm_backlog_close_marker_replay "$home/state" "$home/state/child-b.backlog-close" "$home/data"; then
      fail 'startup replay accepted a close for a foreign data directory'
    fi
    assert_present "$home/state/child-b.meta" 'foreign data replay retired the child record'
    assert_present "$home/state/child-b.backlog-close" 'foreign data replay removed the pending close'
  ) || exit 1

  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
[ "$*" = '-a -d cwd -Fpn' ] || exit 1
printf 'p%s\nfcwd\nn%s\n' "$FM_TEST_CALLER_PID" "$FM_TEST_CALLER_CWD"
SH
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
SH
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\$1" in if-shell|kill-window|list-windows) printf '%s\n' "\$*" >> "$case_dir/kill.log" ;; esac
SH
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/treehouse" "$case_dir/fakebin/tmux"

  (
    export -f run_teardown
    # shellcheck disable=SC2016 # The child Bash expands its own PID and arguments.
    TEARDOWN="$TEARDOWN" FM_TEARDOWN_TEST_ROOT="$case_dir/project" FM_TEARDOWN_GUARD_DONE=1 \
      "$BASH" -uc '
        cd "$1" || exit 1
        FM_TEST_CALLER_PID=$$ FM_TEST_CALLER_CWD=$(pwd -P) run_teardown "$2" --force
        exit "$?"
      ' descendant-caller "$child_b" "$case_dir"
  ) > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "descendant caller ($layout): forced retirement should refuse"
  assert_grep "is in Treehouse copy $child_b" "$case_dir/stderr" 'refusal did not identify the second child copy'
  assert_absent "$case_dir/treehouse.log" 'refusal returned an earlier sibling before checking the second child'
  assert_absent "$case_dir/kill.log" 'refusal attempted cleanup of an earlier sibling endpoint'
  assert_present "$home/state/child-a.meta" 'refusal removed the first child record from the leased home'
  assert_present "$home/state/child-b.meta" 'refusal removed the second child record from the leased home'
  assert_pending_close_replay_preserves_task "$home" child-b "$home" "$backlog_data" \
    || fail 'descendant replay did not preserve the preflight refusal with relocated data'
  assert_present "$case_dir/state/task-x1.meta" 'refusal retired the leased home record'
  pass "forced retirement preflights every child before touching the leased home ($layout)"
}

test_forced_secondmate_teardown_holds_descendant_lifecycle_locks() {
  local case_dir home lock ready release holder_pid rc waited=0 child
  case_dir=$(make_case descendant-locks)
  write_meta "$case_dir" local-only secondmate
  mkdir -p "$case_dir/project/.OpenCode/Plugins" "$case_dir/project/.claude"
  mkdir -p "$case_dir/project/.fm-grok-turnend"
  printf 'project plugin\n' > "$case_dir/project/.OpenCode/Plugins/fm-busy-state.js"
  printf '{}\n' > "$case_dir/project/.claude/settings.local.json"
  printf 'project data\n' > "$case_dir/project/.fm-grok-turnend/data"
  printf 'project hook\n' > "$case_dir/project/.fm-Kimi-turnend"
  git -C "$case_dir/project" add -f .OpenCode/Plugins/fm-busy-state.js .claude/settings.local.json \
    .fm-grok-turnend/data .fm-Kimi-turnend
  git -C "$case_dir/project" commit -qm 'Track project plugin on main'
  configure_secondmate_with_tmux_children "$case_dir"
  mkdir -p "$case_dir/child-a-wt/.opencode/plugins"
  printf 'task hook\n' > "$case_dir/child-a-wt/.opencode/plugins/fm-turn-end.js"
  if [ ! -e "$case_dir/child-a-wt/.fm-kimi-turnend" ]; then
    ln "$case_dir/child-a-wt/.fm-Kimi-turnend" "$case_dir/child-a-wt/.fm-kimi-turnend"
  fi
  home="$case_dir/secondmate-home"
  : > "$case_dir/kill.log"
  : > "$case_dir/treehouse.log"
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
log="$(dirname "$0")/../kill.log"
case "$1" in
  list-windows)
    [ "$#" = 5 ] && [ "$2 $3 $4" = '-t =firstmate -F' ] || exit 1
    case "$5" in
      '#{?#{==:#{window_name},fm-child-a},'*) number=11 name=fm-child-a ;;
      '#{?#{==:#{window_name},fm-child-b},'*) number=12 name=fm-child-b ;;
      '#{?#{==:#{window_name},fm-task-x1},'*) number=13 name=fm-task-x1 ;;
      *) exit 1 ;;
    esac
    printf '@%s:1:$1:%s:2147483647:%%%s:/dev/ttys0%s:\n' "$number" "$name" "$number" "$number" \
      | tee "$log.snapshot-@$number"
    ;;
  if-shell)
    window_id=${4#=firstmate:}
    if [ "$#" = 7 ] && [ "$2 $3" = '-F -t' ] && [[ "$window_id" =~ ^@[0-9]+$ ]] \
      && snapshot=$(cat "$log.snapshot-$window_id") \
      && [ "$5" = '#{==:#{window_id}:#{pid}:#{session_id}:#{window_name}:#{P:#{pane_pid}:#{pane_id}:#{pane_tty}:},'"$snapshot}" ] \
      && [ "$6" = "kill-window -t '\$1:$window_id'" ] \
      && [ "$7" = 'display-message -p changed' ]; then
      printf '%s\n' "$window_id" >> "$log"
    else
      printf 'unexpected request\n' >> "$log"
      exit 1
    fi ;;
  kill-window) printf 'unguarded close request\n' >> "$log"; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "$1 $2" = '-o tty=' ]; then
  printf 'ttys099\n'
  exit 0
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux" "$case_dir/fakebin/ps" "$case_dir/fakebin/treehouse"

  lock="$home/state/.control-child-b.lock"
  ready="$case_dir/lock-ready"
  release="$case_dir/lock-release"
  ROOT="$ROOT" LOCK="$lock" READY="$ready" RELEASE="$release" \
    HOME_STATE="$home/state" OWNER_PID="$$" bash -c '
    export FM_STATE_OVERRIDE="$HOME_STATE"
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$LOCK" || exit 1
    : > "$READY"
    while [ ! -e "$RELEASE" ] && kill -0 "$OWNER_PID" 2>/dev/null; do sleep 0.1; done
    fm_lock_release "$LOCK"
  ' &
  holder_pid=$!
  while [ ! -e "$ready" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -e "$ready" ] || fail "descendant-locks: the contending lifecycle action never acquired its lock"

  rc=0
  TMUX_PANE= run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  if [ "$rc" -eq 0 ]; then
    : > "$release"
    wait "$holder_pid" 2>/dev/null || true
    fail "descendant-locks: forced teardown ignored a descendant lifecycle lock"
  fi
  assert_grep "descendant task child-b has a lifecycle action in flight" "$case_dir/stderr" \
    "descendant-locks: refusal did not name the contended descendant"
  [ ! -e "$home/state/.control-child-a.lock" ] \
    && [ ! -e "$home/state/.meta-child-a.lock" ] \
    || { : > "$release"; wait "$holder_pid" 2>/dev/null || true; fail "descendant-locks: refusal leaked earlier descendant locks"; }
  [ ! -s "$case_dir/kill.log" ] \
    || { : > "$release"; wait "$holder_pid" 2>/dev/null || true; fail "descendant-locks: refusal killed an endpoint"; }
  [ ! -s "$case_dir/treehouse.log" ] \
    || { : > "$release"; wait "$holder_pid" 2>/dev/null || true; fail "descendant-locks: refusal returned a worktree"; }
  [ -e "$case_dir/state/task-x1.meta" ] && [ -d "$home" ] \
    || { : > "$release"; wait "$holder_pid" 2>/dev/null || true; fail "descendant-locks: refusal removed parent state"; }
  for child in child-a child-b; do
    [ -e "$home/state/$child.meta" ] && [ -d "$case_dir/$child-wt" ] \
      || { : > "$release"; wait "$holder_pid" 2>/dev/null || true; fail "descendant-locks: refusal removed $child state or worktree"; }
  done

  : > "$release"
  wait "$holder_pid" 2>/dev/null || true
  rc=0
  TMUX_PANE= run_teardown "$case_dir" --force > "$case_dir/retry.stdout" 2> "$case_dir/retry.stderr" || rc=$?
  expect_code 0 "$rc" "descendant-locks: uncontended retry should complete"
  [ ! -e "$case_dir/state/task-x1.meta" ] && [ ! -d "$home" ] \
    || fail "descendant-locks: uncontended retry retained retired task state"
  [ "$(sort "$case_dir/kill.log")" = "$(printf '@11\n@12\n@13')" ] \
    || fail "descendant-locks: retry did not request guarded closure of both children and the parent: $(cat "$case_dir/kill.log")"
  [ -s "$case_dir/treehouse.log" ] || fail "descendant-locks: uncontended retry did not return worktrees"
  [ "$(cat "$case_dir/child-a-wt/.OpenCode/Plugins/fm-busy-state.js")" = 'project plugin' ] \
    || fail 'child return removed a tracked project plugin'
  [ "$(cat "$case_dir/child-a-wt/.claude/settings.local.json")" = '{}' ] \
    || fail 'child return removed tracked project settings'
  assert_absent "$case_dir/child-a-wt/.opencode/plugins/fm-turn-end.js" \
    'child return retained a task hook under a project plugin directory'
  [ "$(cat "$case_dir/child-a-wt/.fm-grok-turnend/data")" = 'project data' ] \
    || fail 'child return removed a project directory at a hook path'
  assert_not_contains "$(cat "$case_dir/retry.stderr")" '.fm-grok-turnend' \
    'child return attempted to unlink a project directory'
  [ "$(cat "$case_dir/child-a-wt/.fm-Kimi-turnend")" = 'project hook' ] \
    || fail 'child return removed the tracked hook'
  if [ "$case_dir/project/.fm-Kimi-turnend" -ef "$case_dir/project/.fm-kimi-turnend" ]; then
    [ "$case_dir/child-a-wt/.fm-Kimi-turnend" -ef "$case_dir/child-a-wt/.fm-kimi-turnend" ] \
      || fail 'child return removed a tracked hook through a spelling alias'
  else
    assert_absent "$case_dir/child-a-wt/.fm-kimi-turnend" 'child return retained a distinct untracked hard link'
  fi
  pass "forced secondmate teardown holds every descendant lifecycle and metadata lock"
}

test_return_retires_slot_after_hook_error() {
  local layout=$1 failure=$2 case_dir copy worktree id home claim rc=0
  if [ "$failure" = unlink ] && [ "$(id -u)" = 0 ]; then
    printf 'skip: hook unlink permission fixture requires an unprivileged user\n'
    return 0
  fi
  case_dir=$(make_case "returned-hook-error-$layout-$failure")
  copy="$case_dir/pool/1/project"
  mkdir -p "${copy%/*}"
  printf '{}\n' > "$case_dir/pool/treehouse-state.json"
  if [ "$layout" = child ]; then
    write_meta "$case_dir" local-only secondmate
    configure_secondmate_with_tmux_children "$case_dir" "$copy"
    worktree=$copy
    id='child-b'
    home="$case_dir/secondmate-home"
  else
    write_meta "$case_dir" local-only ship
    worktree="$case_dir/wt"
    git -C "$case_dir/project" worktree move "$worktree" "$copy"
    ln -s "$copy" "$worktree"
    id=task-x1
    home="$case_dir"
  fi
  claim="${copy%/*}/.fm-slot-owner"
  printf 'task=%s\nhome=%s\n' "$id" "$home" > "$claim"
  add_lsof_no_holder "$case_dir"
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -eu
[ "${3:-}" = "$FM_TEST_HOOK_WORKTREE" ] || exit 0
mkdir -p "$3/.claude"
printf 'task hook\n' > "$3/.claude/settings.local.json"
printf 'task hook\n' > "$3/.fm-grok-turnend"
if [ "$FM_TEST_HOOK_FAILURE" = unlink ]; then
  chmod a-w "$3/.claude"
fi
: > "$FM_TEST_HOOK_RETURNED"
SH
  cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "$FM_TEST_HOOK_FAILURE" = index ] && [ -f "$FM_TEST_HOOK_RETURNED" ] \
   && [ "${1:-}" = -C ] && [ "${3:-}" = ls-files ]; then
  exit 1
fi
exec "$REAL_GIT_FOR_TEST" "$@"
SH
  chmod +x "$case_dir/fakebin/treehouse" "$case_dir/fakebin/git"
  FM_TEST_HOOK_WORKTREE="$worktree" FM_TEST_HOOK_RETURNED="$case_dir/returned" FM_TEST_HOOK_FAILURE="$failure" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  if [ -d "$copy/.claude" ]; then
    chmod u+w "$copy/.claude"
  fi
  assert_present "$case_dir/returned" 'fixture did not reach the successful Treehouse return'
  expect_code 0 "$rc" "hook cleanup failure interrupted retirement: $(cat "$case_dir/stderr")"
  assert_grep 'incomplete task hook cleanup' "$case_dir/stderr" 'hook cleanup failure was not reported'
  assert_absent "$claim" 'hook cleanup failure stranded the returned slot claim'
  assert_absent "$home/state/$id.meta" 'hook cleanup failure stranded the retired task record'
  assert_present "$copy/.claude/settings.local.json" 'hook cleanup removed the hook it could not verify or unlink'
  if [ "$failure" = unlink ]; then
    assert_absent "$copy/.fm-grok-turnend" 'one unlink failure prevented removal of another hook'
  else
    assert_present "$copy/.fm-grok-turnend" 'hook cleanup deleted a path without a readable index'
  fi
  pass "successful Treehouse return retires the slot after a reported hook cleanup error ($layout, $failure)"
}

test_forced_secondmate_herdr_child_retains_records_when_close_unconfirmed() {
  local case_dir home log closed rc
  case_dir=$(make_case herdr-child-unconfirmed-close)
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_herdr_child "$case_dir"
  home="$case_dir/secondmate-home"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_PRESENCE_UNKNOWN=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-child-unconfirmed-close: teardown erased records after an ambiguous close"
  [ -e "$closed" ] || fail "herdr-child-unconfirmed-close: fixture did not attempt the child close"
  [ -e "$home/state/child-herdr.meta" ] || fail "herdr-child-unconfirmed-close: ambiguous close erased child metadata"
  [ -e "$home/state/child-herdr.status" ] || fail "herdr-child-unconfirmed-close: ambiguous close erased child status"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "herdr-child-unconfirmed-close: failed child cleanup erased parent metadata"
  [ -d "$home" ] || fail "herdr-child-unconfirmed-close: failed child cleanup removed the secondmate home"
  assert_grep "retaining that child's durable identity records" "$case_dir/stderr" \
    "herdr-child-unconfirmed-close: refusal did not explain child record retention"
  pass "forced secondmate teardown retains Herdr child identity until exact pane disappearance"
}

configure_nested_secondmate_with_herdr_grandchild() {  # <case-dir>
  local case_dir=$1 home="$1/secondmate-home" nested_home="$1/secondmate-home/nested-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  mkdir -p "$nested_home/state" "$nested_home/data" "$nested_home/config" "$nested_home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' nested-sm > "$nested_home/.fm-secondmate-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  fm_write_meta "$home/state/nested-sm.meta" \
    "window=firstmate:fm-nested-sm" \
    "endpoint_task_id=nested-sm" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=secondmate" \
    "mode=local-only" \
    "home=$nested_home"
  fm_write_meta "$nested_home/state/grandchild-herdr.meta" \
    "window=grandchildsession:wG:p1" \
    "endpoint_task_id=grandchild-herdr" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only" \
    "backend=herdr" \
    "herdr_session=grandchildsession" \
    "herdr_workspace_id=wG" \
    "herdr_tab_id=wG:t1" \
    "herdr_pane_id=wG:p1" "herdr_terminal_id=term-task"
  : > "$nested_home/state/grandchild-herdr.status"
  : > "$nested_home/state/grandchild-herdr.turn-ended"
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "\${FM_FAKE_HERDR_LOG:?}"
case "\${1:-} \${2:-}" in
  "session list")
    printf '%s\n' '{"sessions":[{"name":"grandchildsession","running":true,"socket_path":"$case_dir/grandchild.sock"}]}'
    ;;
  "workspace list") exit 1 ;;
  "pane get")
    if [ -e "\${FM_FAKE_HERDR_CLOSED:?}" ]; then
      printf '%s\n' 'not-json'
    else
      printf '%s\n' '{"result":{"pane":{"pane_id":"wG:p1","tab_id":"wG:t1","workspace_id":"wG","terminal_id":"term-task"}}}'
    fi
    ;;
  "pane close") : > "\${FM_FAKE_HERDR_CLOSED:?}" ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_forced_teardown_retains_nested_secondmate_home_when_grandchild_close_unconfirmed() {
  local case_dir home nested_home log closed rc
  case_dir=$(make_case herdr-grandchild-unconfirmed-close)
  write_meta "$case_dir" local-only secondmate
  configure_nested_secondmate_with_herdr_grandchild "$case_dir"
  home="$case_dir/secondmate-home"; nested_home="$home/nested-home"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "herdr-grandchild-unconfirmed-close: teardown erased records after an ambiguous grandchild close"
  [ -e "$closed" ] \
    || fail "herdr-grandchild-unconfirmed-close: fixture did not attempt the grandchild close"
  [ -d "$nested_home" ] \
    || fail "herdr-grandchild-unconfirmed-close: the recursive failure still removed the nested secondmate home"
  [ -e "$nested_home/state/grandchild-herdr.meta" ] \
    || fail "herdr-grandchild-unconfirmed-close: ambiguous close erased the grandchild's metadata"
  [ -e "$nested_home/state/grandchild-herdr.status" ] \
    || fail "herdr-grandchild-unconfirmed-close: ambiguous close erased the grandchild's status record"
  [ -e "$home/state/nested-sm.meta" ] \
    || fail "herdr-grandchild-unconfirmed-close: the recursive failure erased the nested secondmate's own record"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "herdr-grandchild-unconfirmed-close: the recursive failure erased the top-level secondmate's record"
  pass "forced teardown retains a nested secondmate home and its grandchild's Herdr identity when the grandchild close is unconfirmed"
}

configure_herdr_projection_teardown_case() {  # <case-dir>
  local case_dir=$1 token=AbCdEfGhIjKlMnOpQrStUv
  sed -i.bak 's/^window=.*/window=fmtest:w1:p2/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=fmtest' \
    'herdr_workspace_id=w1' \
    'herdr_tab_id=w1:t2' \
    'herdr_pane_id=w1:p2' 'herdr_terminal_id=term-task' >> "$case_dir/state/task-x1.meta"
  printf '%s\n' \
    'version=1' \
    'task_id=task-x1' \
    "projection_id=$token" > "$case_dir/state/task-x1.herdr-presentation"
  cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_HERDR_LOG:?}"
case "${1:-} ${2:-}" in
  "workspace list")
    if [ -e "${FM_FAKE_HERDR_RESTORED:?}" ]; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","label":"2ndmate-alpha","focused":false}]}}'
    elif [ -e "${FM_FAKE_HERDR_CLOSED:?}" ]; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":false},{"workspace_id":"w3","active_tab_id":"w3:t1","label":"2ndmate-alpha","focused":true}]}}'
    else
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t2","label":"firstmate/task-x1 · p:AbCdEfGhIjKlMnOpQrStUv","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","label":"2ndmate-alpha","focused":false}]}}'
    fi
    ;;
  "tab list")
    case "$*" in
      *"--workspace w2"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","focused":true}]}}' ;;
      *"--workspace w3"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"w3:t1","focused":true}]}}' ;;
      *) printf '%s\n' '{"result":{"tabs":[]}}' ;;
    esac
    ;;
  "status --json")
    printf '%s\n' '{"server":{"running":true}}'
    ;;
  "session list")
    printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fmtest.sock"}]}'
    ;;
  "pane close")
    if [ "${FM_FAKE_HERDR_CLOSE_FAIL:-0}" = 1 ]; then
      exit 1
    fi
    : > "${FM_FAKE_HERDR_CLOSED:?}"
    ;;
  "pane get")
    if [ -e "${FM_FAKE_HERDR_CLOSED:?}" ]; then
      if [ "${FM_FAKE_HERDR_PRESENCE_UNKNOWN:-0}" = 1 ]; then
        printf '%s\n' '{"error":{"code":"internal"}}' >&2
        exit 1
      fi
      printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
      exit 1
    fi
    printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p2","tab_id":"w1:t2","workspace_id":"w1","terminal_id":"term-task"}}}'
    ;;
  "tab get")
    printf '%s\n' '{"result":{"tab":{"tab_id":"w2:t2","workspace_id":"w2"}}}'
    ;;
  "tab focus")
    if [ "${FM_FAKE_HERDR_RESTORE_FAIL:-0}" = 1 ]; then
      exit 1
    fi
    : > "${FM_FAKE_HERDR_RESTORED:?}"
    printf '%s\n' '{"result":{"tab":{"tab_id":"w2:t2","workspace_id":"w2","focused":true}}}'
    ;;
  "agent get")
    printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
    exit 1
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_herdr_projection_teardown_retires_journal_only_after_confirmed_close() {
  local case_dir log closed restored
  case_dir=$(make_case herdr-projection-confirmed-close)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-projection-confirmed-close: forced teardown failed"
  [ ! -e "$case_dir/state/task-x1.herdr-presentation" ] \
    || fail "confirmed exact-pane close did not retire the presentation journal"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "projected teardown must never call workspace close"
  assert_contains "$(cat "$log")" "tab focus w2:t2" \
    "projected teardown did not restore the exact pre-close active tab"
  pass "herdr projection teardown retires its journal only after confirming the exact recorded pane is gone"
}

test_herdr_projection_teardown_retains_journal_when_close_unconfirmed() {
  local case_dir log closed restored
  case_dir=$(make_case herdr-projection-unconfirmed-close)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"

  local rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" FM_FAKE_HERDR_PRESENCE_UNKNOWN=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "herdr-projection-unconfirmed-close: teardown reported success after an unknown post-close presence read"
  [ -e "$closed" ] \
    || fail "herdr-projection-unconfirmed-close: regression did not exercise an attempted close"
  [ -e "$case_dir/state/task-x1.herdr-presentation" ] \
    || fail "unconfirmed task-pane close incorrectly retired the presentation journal"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "unconfirmed task-pane close erased the durable endpoint metadata"
  assert_grep "close could not be confirmed" "$case_dir/stderr" \
    "unconfirmed projected close did not explain why the journal was retained"
  assert_grep "not confirmed gone" "$case_dir/stderr" \
    "unconfirmed projected close did not explain why the records were retained"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "unconfirmed projected close must not escalate to workspace cleanup"
  pass "herdr projection teardown retains every record when post-close presence is unknown"
}

test_herdr_projection_teardown_surfaces_restore_failure_without_blocking_cleanup() {
  local case_dir log closed restored
  case_dir=$(make_case herdr-projection-restore-failure)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" \
    FM_FAKE_HERDR_RESTORE_FAIL=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-projection-restore-failure: a confirmed close with a failed focus restore blocked teardown"
  [ -e "$closed" ] \
    || fail "herdr-projection-restore-failure: regression did not exercise the exact projected-pane close"
  [ ! -e "$case_dir/state/task-x1.herdr-presentation" ] \
    || fail "herdr-projection-restore-failure: confirmed closure did not retire the presentation journal"
  assert_grep "exact-tab restoration failed" "$case_dir/stderr" \
    "herdr-projection-restore-failure: teardown swallowed the focus helper's restore warning"
  pass "herdr projection teardown surfaces failed focus restoration without turning confirmed cleanup into a hard failure"
}

# --- Fix 1: conclude/abort the task's own parked no-mistakes run before the
# worker is removed, and Fix 2: reap leaked descendant processes rooted under
# the task's own worktree/tasktmp - both exercised through the real teardown
# path (bin/fm-teardown.sh), never by matching its source text. ------------

# A parked-at-a-gate `axi status` TOON payload for <branch>/<head>, matching
# the shape no-mistakes actually emits (see tests/fm-crew-state.test.sh's
# run_parked fixture, the same shape bin/fm-crew-state.sh's own tests pin).
parked_axi_status_toon() {  # <branch> <head> [run-id]
  cat <<EOF
run:
  id: "${3:-01RUN}"
  branch: $1
  status: awaiting_approval
  awaiting_agent: parked 2m10s
  head: "$2"
  pr: ""
  findings: none
gate: review
EOF
}

running_axi_status_toon() {  # <branch> <head> [run-id]
  cat <<EOF
run:
  id: "${3:-01RUN}"
  branch: $1
  status: running
  head: "$2"
  pr: ""
steps[1]{step,status,findings,summary}:
  test,running,0,"agent under way"
EOF
}

# One row of the real `no-mistakes runs` ledger: plain text, newest-first,
# no run id, no quoting - "<status> <branch> <short-sha> <date> <time> [<pr-url>]"
# (the same shape tests/fm-crew-state.test.sh's runs-list fixtures pin).
ledger_row() {  # <status> <branch> <short-sha> <date> <time> [pr-url]
  printf '  %-10s %-24s %-8s  %s %s' "$1" "$2" "$3" "$4" "$5"
  [ -z "${6:-}" ] || printf '  %s' "$6"
  printf '\n'
}

# Commit <n> pipeline fix rounds on top of the task branch in a separate
# clone of origin that the task copy NEVER fetches from, mirroring how the
# no-mistakes daemon commits fix rounds in its own gate-repo clone. Echoes
# the newest short sha, which is genuinely absent from the task worktree's
# object store. Args: case_dir [rounds]
make_unfetched_pipeline_heads() {
  local case_dir=$1 rounds=${2:-1} i
  git clone -q "$case_dir/origin.git" "$case_dir/pipeline-clone"
  git -C "$case_dir/pipeline-clone" checkout -q fm/task-x1
  for i in $(seq 1 "$rounds"); do
    git -C "$case_dir/pipeline-clone" -c user.email=t@t -c user.name=t \
      commit -q --allow-empty -m "pipeline fix round $i"
  done
  git -C "$case_dir/pipeline-clone" rev-parse --short=7 HEAD
}

assert_head_absent_from_worktree() {  # <worktree> <short-sha> <label>
  [ -z "$(git -C "$1" rev-parse --verify --quiet "${2}^{commit}" 2>/dev/null)" ] \
    || fail "$3: fixture broke - the pipeline head resolved in the task copy"
}

# Land a shippable commit on the task branch and push it to origin, the same
# "definitely landed, teardown must ALLOW" shape test_no_mistakes_origin_remote_allows
# uses, so these new cases exercise the abort/reap steps on a real successful
# teardown rather than a refusal path.
land_shippable_commit() {
  local case_dir=$1
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
}

test_parked_own_run_is_aborted_before_teardown() {
  local case_dir rc head
  case_dir=$(make_case parked-run-abort)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  local rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-abort: teardown should still succeed"
  assert_present "$case_dir/nm-abort.log" \
    "parked-run-abort: no-mistakes axi abort was never invoked for the task's own parked run"
  assert_grep "abort --run 01RUN" "$case_dir/nm-abort.log" \
    "parked-run-abort: no-mistakes axi abort did not target the verified run id"
  assert_grep "parked at a gate; aborting" "$case_dir/stderr" \
    "parked-run-abort: teardown did not report aborting the parked run before removing the worker"
  pass "a task's own parked no-mistakes run is aborted, not orphaned, before the worker is removed"
}

# The pipeline advanced the parked run past the submitted head in its own
# repo, so the run head object does not exist in the task copy at all and the
# strict object-local identity rule cannot bind the run. The daemon's own
# runs ledger is what still proves the run is this task's continuation: its
# newest fm/task-x1 row is active at the unfetched head, anchored by the
# immediately older fm/task-x1 row ending exactly at this worktree's HEAD.
# Teardown must conclude the run instead of orphaning a parked gate wait that
# would otherwise hold a fleet slot forever (observed 2026-09-03). Foreign
# branches' rows interleaved in the ledger must not matter.
test_parked_run_advanced_past_unfetched_head_is_still_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-pipeline-advanced-unfetched)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-pipeline-advanced-unfetched"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/other-task aaaaaaa 2026-09-03 22:10)
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
$(ledger_row completed fm/third-task bbbbbbb 2026-09-01 11:00)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-pipeline-advanced-unfetched: teardown should still succeed"
  assert_grep "abort --run 01RUN" "$case_dir/nm-abort.log" \
    "parked-run-pipeline-advanced-unfetched: teardown did not abort the parked run the ledger proves is this task's continuation"
  assert_grep "parked at a gate; aborting" "$case_dir/stderr" \
    "parked-run-pipeline-advanced-unfetched: teardown did not report aborting the parked run"
  pass "a parked run the pipeline advanced past the task copy is still concluded from the runs ledger, not orphaned"
}

test_parked_run_with_mismatched_ledger_head_is_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-mismatched-ledger-head)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-mismatched-ledger-head"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 deadbee 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-mismatched-ledger-head: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-mismatched-ledger-head: teardown aborted a ledger run with a different head"
  pass "a ledger row for a different head never authorizes a parked-run abort"
}

test_parked_run_with_malformed_ledger_row_is_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-malformed-ledger-row)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-malformed-ledger-row"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
running fm/task-x1 $advanced_short
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-malformed-ledger-row: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-malformed-ledger-row: teardown aborted from a malformed ledger row"
  pass "a malformed ledger row never authorizes a parked-run abort"
}

test_parked_run_with_impossible_ledger_date_is_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-impossible-ledger-date)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-impossible-ledger-date"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$advanced_short" 2026-02-31 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-02-28 06:36)
EOF
)" \
  FM_FAKE_NM_RUNS_LOG="$case_dir/nm-runs.log" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-impossible-ledger-date: teardown should still succeed"
  assert_present "$case_dir/nm-runs.log" \
    "parked-run-impossible-ledger-date: fixture broke - the ledger fallback never engaged"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-impossible-ledger-date: teardown aborted from an impossible ledger date"
  pass "an impossible ledger date never authorizes a parked-run abort"
}

test_terminal_status_with_gate_never_queries_or_aborts_ledger_fallback() {
  local case_dir rc advanced_short anchor_short terminal_status
  case_dir=$(make_case parked-run-terminal-status-gate)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-terminal-status-gate"
  terminal_status=$(parked_axi_status_toon fm/task-x1 "$advanced_short")
  terminal_status=${terminal_status/status: awaiting_approval/status: completed}

  rc=0
  FM_FAKE_AXI_STATUS="$terminal_status" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_RUNS_LOG="$case_dir/nm-runs.log" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-terminal-status-gate: teardown should still succeed"
  assert_absent "$case_dir/nm-runs.log" \
    "parked-run-terminal-status-gate: terminal status queried the ledger fallback"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-terminal-status-gate: terminal status with a stale gate aborted"
  pass "a terminal status with a stale gate never reaches ledger cleanup"
}

# Counterfactual twin of the unfetched defect above: the SAME parked-run shape
# with the pipeline's advanced fix head FETCHED into the task copy (objects
# only - no ref moves) resolves through the strict object-local rule alone,
# because a fix round's commits descend from this worktree's submitted HEAD.
# With an EMPTY ledger, teardown must still abort - and must never query the
# ledger at all - proving the fallback stays dormant whenever the run head's
# object is present locally (no ledger dependency on the strict-rule path).
test_parked_run_advanced_head_locally_fetched_is_still_aborted() {
  local case_dir rc advanced_short
  case_dir=$(make_case parked-run-advanced-fetched)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  # The one changed condition vs the defect case: fetch the fix commits into
  # the project clone's object store (shared with the task worktree) without
  # moving any ref, so fm_nm_resolve_commit sees the head again.
  git -C "$case_dir/project" fetch -q "$case_dir/pipeline-clone" fm/task-x1
  [ -n "$(git -C "$case_dir/wt" rev-parse --verify --quiet "${advanced_short}^{commit}" 2>/dev/null)" ] \
    || fail "parked-run-advanced-fetched: fixture broke - the pipeline head never reached the task copy"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="" \
  FM_FAKE_NM_RUNS_LOG="$case_dir/nm-runs.log" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-advanced-fetched: teardown should still succeed"
  assert_grep "abort --run 01RUN" "$case_dir/nm-abort.log" \
    "parked-run-advanced-fetched: teardown did not abort the parked run the strict object-local rule binds"
  assert_absent "$case_dir/nm-runs.log" \
    "parked-run-advanced-fetched: the ledger fallback fired even though the advanced head resolves locally"
  pass "an advanced head present locally aborts through the strict rule alone - the ledger fallback stays dormant"
}

# No anchor: the unresolvable active row is the branch's ONLY row, so nothing
# proves the run ever touched this worktree's head - a branch-name coincidence
# or an arbitrary daemon-side run must not be concluded.
test_parked_advanced_run_without_anchor_is_never_aborted() {
  local case_dir rc advanced_short
  case_dir=$(make_case parked-run-advanced-no-anchor)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-advanced-no-anchor"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/other-task aaaaaaa 2026-09-03 22:10)
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 07:55)
$(ledger_row completed fm/third-task bbbbbbb 2026-09-01 11:00)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-advanced-no-anchor: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-advanced-no-anchor: teardown aborted an unanchored run it cannot prove is its own"
  pass "an unresolvable active row with no same-branch anchor is never concluded (conservative refusal)"
}

# The anchor row resolves but to an OLDER commit: the worktree advanced past
# it since the run was submitted, so exact-equality fails and the run is not
# provably this worktree's submission. Ancestor-only anchors must never bind.
test_parked_advanced_run_ancestor_anchor_is_never_aborted() {
  local case_dir rc advanced_short parent_short
  case_dir=$(make_case parked-run-advanced-ancestor-anchor)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  parent_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD~1)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-advanced-ancestor-anchor"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$parent_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-advanced-ancestor-anchor: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-advanced-ancestor-anchor: teardown aborted on an ancestor-only anchor"
  pass "an ancestor-only anchor never binds an advanced parked run to this task"
}

# The branch's newest same-branch row is TERMINAL at an unfetched head: a
# finished run is history, never the branch's current run, and the anchored
# older row never answers for it. Teardown must not conclude a run from a
# stale terminal row.
test_parked_terminal_unfetched_row_is_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-terminal-unfetched)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-terminal-unfetched"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row failed fm/task-x1 "$advanced_short" 2026-09-03 08:20)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-terminal-unfetched: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-terminal-unfetched: teardown concluded a run from a terminal unfetched row"
  pass "a terminal unfetched-head row is stale history and never concludes a run"
}

# The crafted d15 boundary, tightened deliberately: the axi-reported head is
# unresolvable and the branch's newest ledger row is TERMINAL at exactly this
# worktree's head - a perfectly anchored, already-finished run. A finished run
# is history, so the ledger fallback authorizes cleanup only when its proved
# answer is the explicitly active word (`running`): a terminal newest row,
# even anchored at this head, never authorizes an abort. The runs log proves
# the fallback actually engaged, so the refusal is this tightened boundary
# and not an earlier guard.
test_parked_run_terminal_newest_row_at_own_head_is_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-terminal-newest-at-head)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-terminal-newest-at-head"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/other-task aaaaaaa 2026-09-03 22:10)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-03 06:36)
EOF
)" \
  FM_FAKE_NM_RUNS_LOG="$case_dir/nm-runs.log" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-terminal-newest-at-head: teardown should still succeed"
  assert_present "$case_dir/nm-runs.log" \
    "parked-run-terminal-newest-at-head: fixture broke - the ledger fallback never engaged"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-terminal-newest-at-head: teardown aborted a run whose newest anchored ledger row is terminal"
  pass "a terminal newest row anchored at this worktree's head never authorizes an abort"
}

# The branch's newest row resolves in this copy to a head that DIVERGED from
# this worktree's HEAD (the branch was rewritten or moved on by a newer run
# from another worktree of the same project): not equal, not a descendant,
# so the shared rule answers nothing and every older row - including this
# task's parked run - stays stale history. Neither this task's run nor the
# unrelated newer run may be concluded here.
test_parked_run_behind_diverged_newer_row_is_never_aborted() {
  local case_dir rc advanced_short diverged_short
  case_dir=$(make_case parked-run-behind-newer-row)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-behind-newer-row"
  # A newer fm/task-x1 head that THIS copy resolves but that diverged from
  # the worktree's HEAD: rewritten from origin/main and pushed over the
  # branch (the fixture origin allows the non-fast-forward rewrite), then
  # fetched into the project clone (shared object store).
  git -C "$case_dir/origin.git" config receive.denyNonFastForwards false
  git clone -q "$case_dir/origin.git" "$case_dir/newer-clone"
  git -C "$case_dir/newer-clone" checkout -q origin/main
  git -C "$case_dir/newer-clone" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "newer run's diverged work"
  git -C "$case_dir/newer-clone" push -q --force origin HEAD:fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  diverged_short=$(git -C "$case_dir/wt" rev-parse --short=7 origin/fm/task-x1)
  git -C "$case_dir/wt" merge-base --is-ancestor HEAD "$diverged_short" \
    && fail "parked-run-behind-newer-row: fixture broke - the newer row is a descendant, not diverged"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$diverged_short" 2026-09-03 09:00)
$(ledger_row failed fm/task-x1 "$advanced_short" 2026-09-03 07:55)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-behind-newer-row: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-behind-newer-row: teardown concluded this task from another run's ledger row"
  pass "a resolvable diverged newer same-branch row makes every older row stale history; no run is concluded"
}

# Two consecutive unresolvable running rows for the branch: the ledger cannot
# prove which row is current or where the submission boundary is. Ambiguity
# must refuse, never guess.
test_parked_advanced_run_ambiguous_rows_are_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-advanced-ambiguous)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir" 2)
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-advanced-ambiguous"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 08:30)
$(ledger_row failed fm/other-task ccccccc 2026-09-03 08:10)
$(ledger_row running fm/task-x1 ddddddd 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-advanced-ambiguous: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-advanced-ambiguous: teardown guessed through ambiguous ledger rows"
  pass "consecutive unresolvable rows are ambiguous and never conclude a run"
}

# The ledger proves the continuation, but the run is NOT parked at a gate -
# it is autonomously running/fixing against the daemon's own clone. Teardown
# must leave that work alone even when the attribution proof would bind it.
test_ledger_proven_continuation_never_aborts_active_run() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-ledger-active)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-ledger-active"

  rc=0
  FM_FAKE_AXI_STATUS="$(running_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-ledger-active: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-ledger-active: teardown aborted an actively running run the ledger happened to bind"
  pass "a ledger-proven continuation is still left alone while the run is autonomously active"
}

test_mismatched_run_after_abort_refuses_unconfirmed() {
  local case_dir rc head
  case_dir=$(make_case parked-run-replaced)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head" 01RUN)" \
  FM_FAKE_AXI_STATUS_AFTER_ABORT="$(parked_axi_status_toon fm/task-x1 "$head" 02RUN)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "parked-run-replaced: a different run does not confirm the targeted abort"
  assert_grep "abort --run 01RUN" "$case_dir/nm-abort.log" \
    "parked-run-replaced: teardown did not abort only the verified run"
  assert_present "$case_dir/wt" "parked-run-replaced: teardown removed the worktree without confirmation"
  pass "a different run cannot confirm the targeted abort"
}

test_empty_status_after_abort_refuses_unconfirmed() {
  local case_dir rc head
  case_dir=$(make_case parked-run-empty-confirmation)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_NM_EMPTY_AFTER_ABORT=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "parked-run-empty-confirmation: empty status should refuse"
  assert_present "$case_dir/wt" "parked-run-empty-confirmation: teardown removed the worktree"
  pass "empty post-abort status is not accepted as confirmation"
}

test_not_found_status_after_abort_confirms_completion() {
  local case_dir rc head
  case_dir=$(make_case parked-run-not-found-confirmation)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_NM_NOT_FOUND_AFTER_ABORT=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-not-found-confirmation: explicit not-found should confirm completion"
  pass "the CLI's exact run-not-found signal confirms completion"
}

test_parked_own_run_refuses_when_abort_is_unconfirmed() {
  local case_dir rc head pid
  case_dir=$(make_case parked-run-abort-unconfirmed)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  seed_backlog_in_flight "$case_dir"
  printf 'PR closure evidence\n' > "$case_dir/state/task-x1.pr-poll-closed"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  ( cd "$case_dir/wt" && exec sleep 300 ) &
  pid=$!
  disown

  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
printf 'return\n' >> "$case_dir/treehouse.log"
EOF
  chmod +x "$case_dir/fakebin/treehouse"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_NM_ABORT_NOOP=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "parked-run-abort-unconfirmed: teardown should refuse"
  assert_grep "REFUSED: no-mistakes run for task-x1 is still parked after axi abort" "$case_dir/stderr" \
    "parked-run-abort-unconfirmed: teardown did not explain the parked-run refusal"
  assert_present "$case_dir/wt" \
    "parked-run-abort-unconfirmed: teardown removed the worktree after refusing"
  assert_present "$case_dir/state/task-x1.meta" \
    "parked-run-abort-unconfirmed: teardown removed task metadata after refusing"
  assert_absent "$case_dir/treehouse.log" \
    "parked-run-abort-unconfirmed: teardown returned the worktree after refusing"
  kill -0 "$pid" 2>/dev/null || fail "parked-run-abort-unconfirmed: process reap ran before refusal"
  kill -KILL "$pid" 2>/dev/null || true
  assert_pending_close_replay_preserves_task "$case_dir" task-x1 "$case_dir/home" \
    || fail 'startup replay changed the retained task after a parked-run refusal'
  pass "an unconfirmed parked-run abort preserves the copy and cancels the pending close"
}

test_another_branchs_parked_run_is_never_touched() {
  local case_dir rc
  case_dir=$(make_case parked-run-not-ours)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"

  local rc=0
  # A parked run reported for a DIFFERENT branch - e.g. another crew's task
  # still validating on the shared gate - must never be aborted by this task's
  # teardown.
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/some-other-task deadbeef)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-not-ours: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-not-ours: teardown called axi abort for a run on another branch"
  assert_not_contains "$(cat "$case_dir/stderr")" "aborting" \
    "parked-run-not-ours: teardown reported aborting a run it does not own"
  pass "a parked run on another branch is never aborted by this task's teardown (ownership is precise)"
}

test_own_autonomous_run_is_left_alone() {
  local case_dir rc head
  case_dir=$(make_case autonomous-run-left-alone)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(running_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "autonomous-run-left-alone: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "autonomous-run-left-alone: teardown aborted a task-owned autonomous run"
  assert_not_contains "$(cat "$case_dir/stderr")" "aborting" \
    "autonomous-run-left-alone: teardown reported aborting an autonomous run"
  pass "a task-owned autonomous running step is left alone rather than aborted"
}

test_leaked_worktree_process_is_reaped() {
  local case_dir rc pid cwd i survived=0
  case_dir=$(make_case leaked-process-reap)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"

  # The sleeper is outside the task's pane, so teardown must find it by cwd.
  # Keep it as a test-owned child so Bash can reap it after teardown kills it.
  ( cd "$case_dir/wt" && pwd -P > "$case_dir/sleeper.cwd" && exec sleep 300 ) &
  pid=$!
  for ((i=0; i<100; i++)); do
    [ ! -s "$case_dir/sleeper.cwd" ] || break
    sleep 0.05
  done
  if ! cwd=$(cat "$case_dir/sleeper.cwd" 2>/dev/null) || [ -z "$cwd" ] || ! kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "leaked-process-reap: setup sleeper did not start in the worktree"
  fi

  # Keep the lsof scan path covered even when the host has no lsof binary.
  if [ -z "$REAL_LSOF_FOR_TEST" ]; then
    cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
[ "$*" = '-a -d cwd -Fpn' ] || exit 1
if kill -0 "$FM_TEST_LEAK_PID" 2>/dev/null; then
  printf 'p%s\nfcwd\nn%s\n' "$FM_TEST_LEAK_PID" "$FM_TEST_LEAK_CWD"
fi
SH
    chmod +x "$case_dir/fakebin/lsof"
  fi

  rc=0
  FM_TEST_LEAK_PID="$pid" FM_TEST_LEAK_CWD="$cwd" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  if kill -0 "$pid" 2>/dev/null; then
    survived=1
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$rc" "leaked-process-reap: teardown should still succeed"
  [ "$survived" -eq 0 ] || fail "leaked-process-reap: leaked worktree process survived teardown"
  assert_grep "reaping leaked worktree process" "$case_dir/stderr" \
    "leaked-process-reap: teardown did not report reaping the leaked process"
  pass "a leaked descendant process rooted under the task's worktree is reaped by teardown, not left surviving"
}

require_lsof_for_case() {
  [ -n "$REAL_LSOF_FOR_TEST" ] && return 0
  printf 'skip: %s requires lsof\n' "$1"
  return 1
}

test_leaked_tasktmp_process_is_reaped() {
  local case_dir rc pid
  require_lsof_for_case leaked-tasktmp-reap || return 0
  case_dir=$(make_case leaked-tasktmp-reap)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' "tasktmp=$case_dir/tasktmp" >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/tasktmp"
  land_shippable_commit "$case_dir"

  ( cd "$case_dir/tasktmp" && exec sleep 300 ) &
  pid=$!
  disown
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "leaked-tasktmp-reap: setup sleeper did not start"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "leaked-tasktmp-reap: teardown should still succeed"
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "leaked-tasktmp-reap: leaked tasktmp process survived teardown"
  fi
  assert_grep "reaping leaked worktree process" "$case_dir/stderr" \
    "leaked-tasktmp-reap: teardown did not report reaping the leaked tasktmp process"
  pass "a leaked descendant process rooted under the task's per-task tasktmp is reaped by teardown too"
}

configure_teardown_ancestry_ps() {
  local case_dir=$1
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -o pipefail
case "$*" in
  '-axo pid=,ppid=') exit 1 ;;
  '-A -o pid= -o ppid=')
    "$REAL_PS_FOR_TEST" "$@" | awk -v hidden="${FM_TEST_HIDDEN_ANCESTOR:-}" '$1 != hidden'
    ;;
  *) exec "$REAL_PS_FOR_TEST" "$@" ;;
esac
SH
  chmod +x "$case_dir/fakebin/ps"
}

test_lsof_absent_reaps_detached_linux_process() (
  if [ "$(uname -s)" != Linux ]; then
    printf 'skip: detached /proc cwd scan requires Linux\n'
    return 0
  fi
  local visibility=$1 case_dir rc=0 pid='' tmp_pid='' sibling_pid='' path_without_lsof i
  local nested=$'nested -> dir\nleaf' sibling=$'wt\n'
  case_dir=$(make_case "lsof-absent-detached-reap-café-$visibility")
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  path_without_lsof=$(make_path_without_lsof "$case_dir")
  if PATH="$case_dir/fakebin:$path_without_lsof" command -v lsof >/dev/null 2>&1; then
    fail 'lsof-absent-detached-reap: fixture path unexpectedly exposes lsof'
  fi
  {
    cat <<'SH'
#!/usr/bin/env bash
for arg; do
  [ "$arg" != -ignore_readdir_race ] || exit 1
done
SH
    printf 'exec %q "$@"\n' "$path_without_lsof/find"
  } > "$case_dir/fakebin/find"
  chmod +x "$case_dir/fakebin/find"
  if [ "$visibility" = hidden ]; then
    # shellcheck disable=SC2030 # Only this fixture's child processes need this value.
    export FM_TEST_HIDDEN_ANCESTOR=$$
  fi
  configure_teardown_ancestry_ps "$case_dir"

  mkdir -p "$case_dir/wt/$nested" "$case_dir/$sibling" "$case_dir/tasktmp"
  printf 'tasktmp=%s\n' "$case_dir/tasktmp" >> "$case_dir/state/task-x1.meta"
  ln -s "$case_dir/wt/$nested" "$case_dir/cwd-alias"
  trap 'for child in "$pid" "$tmp_pid" "$sibling_pid"; do
    [ -n "$child" ] || continue
    kill -KILL "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
  done' EXIT
  if [ "$visibility" = visible ]; then
    # The in-copy sleeper ignores TERM to exercise the identity and cwd recheck before KILL.
    perl -MPOSIX -e 'POSIX::setsid() > 0 or die; $SIG{TERM} = "IGNORE"; chdir shift or die; exec "sleep", "300"' "$case_dir/cwd-alias" &
    pid=$!
  fi
  perl -MPOSIX -e 'POSIX::setsid() > 0 or die; chdir shift or die; exec "sleep", "300"' "$case_dir/tasktmp" &
  tmp_pid=$!
  perl -MPOSIX -e 'POSIX::setsid() > 0 or die; chdir shift or die; exec "sleep", "300"' "$case_dir/$sibling" &
  sibling_pid=$!
  for ((i=0; i<100; i++)); do
    if { [ -z "$pid" ] || [ "$(readlink "/proc/$pid/cwd" 2>/dev/null)" = "$case_dir/wt/$nested" ]; } \
       && [ "$(readlink "/proc/$tmp_pid/cwd" 2>/dev/null)" = "$case_dir/tasktmp" ] \
       && [[ "/proc/$sibling_pid/cwd" -ef "$case_dir/$sibling" ]]; then
      break
    fi
    sleep 0.05
  done
  [ "$i" -lt 100 ] || fail 'lsof-absent-detached-reap: sleepers did not enter their directories'

  FM_TEARDOWN_TEST_PATH="$path_without_lsof" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  kill -0 "$tmp_pid" 2>/dev/null || fail 'lsof-absent-detached-reap: cleanup signalled a process in tasktmp'
  kill -0 "$sibling_pid" 2>/dev/null || fail 'lsof-absent-detached-reap: sibling process was killed'
  if [ "$visibility" = hidden ]; then
    expect_code 1 "$rc" 'lsof-absent-detached-reap: return should refuse unknown caller ancestry'
    assert_grep 'cannot verify teardown caller ancestry' "$case_dir/stderr" 'missing return refusal'
    assert_present "$case_dir/state/task-x1.meta" 'refusal retired task metadata'
    pass 'Linux teardown refuses to return a copy when caller ancestry is incomplete even without a cwd match'
    return 0
  fi
  [ "$rc" -eq 0 ] || cat "$case_dir/stderr" >&2
  expect_code 0 "$rc" 'lsof-absent-detached-reap: teardown should succeed'
  if [ -n "$pid" ]; then
    ! kill -0 "$pid" 2>/dev/null || fail 'lsof-absent-detached-reap: detached worktree process survived successful teardown'
    wait "$pid" 2>/dev/null || true
    pid=''
    assert_grep 'force-killing leaked worktree process(es)' "$case_dir/stderr" \
      'lsof-absent-detached-reap: teardown did not escalate after TERM'
  fi
  assert_absent "$case_dir/tasktmp" 'lsof-absent-detached-reap: cleanup left the tasktmp directory'
  pass "Linux teardown without lsof scopes reaping to its owned worktree ($visibility ancestry)"
)

test_proc_cwd_read_failure_preserves_copy() (
  if [ "$(uname -s)" != Linux ]; then
    printf 'skip: unreadable /proc cwd fixture requires Linux\n'
    return 0
  fi
  local case_dir path_without_lsof rc=0 leak_pid i
  case_dir=$(make_case proc-cwd-read-failure)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  path_without_lsof=$(make_path_without_lsof "$case_dir")
  ( cd "$case_dir/wt" && exec sleep 300 ) &
  leak_pid=$!
  trap 'kill -KILL "$leak_pid" 2>/dev/null || true; wait "$leak_pid" 2>/dev/null || true' EXIT
  for ((i=0; i<100; i++)); do
    [[ ! "/proc/$leak_pid/cwd" -ef "$case_dir/wt" ]] || break
    sleep 0.05
  done
  [ "$i" -lt 100 ] || fail 'proc-cwd-read-failure: leak did not enter the worktree'

  # shellcheck disable=SC2016 # The generated readlink stub expands its own arguments.
  printf '#!/usr/bin/env bash\n[ "$1" != %q ] || exit 1\nexec %q "$@"\n' \
    "/proc/$leak_pid/cwd" "$path_without_lsof/readlink" > "$case_dir/fakebin/readlink"
  printf '#!/usr/bin/env bash\n: > %q\n' "$case_dir/returned" > "$case_dir/fakebin/treehouse"
  chmod +x "$case_dir/fakebin/readlink"

  FM_TEARDOWN_TEST_PATH="$path_without_lsof" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" 'proc-cwd-read-failure: cleanup should refuse'
  assert_grep 'cannot verify caller working directories' "$case_dir/stderr" 'proc-cwd-read-failure: missing scan refusal'
  assert_present "$case_dir/state/task-x1.meta" 'proc-cwd-read-failure: cleanup retired task metadata'
  assert_absent "$case_dir/returned" 'proc-cwd-read-failure: cleanup returned the worktree'
  kill -0 "$leak_pid" 2>/dev/null || fail 'proc-cwd-read-failure: cleanup signalled the leak'
  pass 'a failed cwd read for a live directory refuses teardown'
)

test_hidden_intermediate_parent_refuses_reap() (
  if [ "$(uname -s)" != Linux ]; then
    printf 'skip: hidden parent fixture requires Linux\n'
    return 0
  fi
  local scanner=$1 case_dir path_without_lsof rc=0 leak_pid i
  case_dir=$(make_case "reap-hidden-parent-$scanner")
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  configure_teardown_ancestry_ps "$case_dir"
  path_without_lsof=$(make_path_without_lsof "$case_dir")
  if [ "$scanner" = lsof ]; then
    cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
printf 'p%s\nfcwd\nn%s\n' "$FM_TEST_LEAK_PID" "$FM_TEST_WORKTREE" "$FM_TEST_IN_COPY_CALLER" "$FM_TEST_WORKTREE"
SH
    chmod +x "$case_dir/fakebin/lsof"
  fi
  ( cd "$case_dir/wt" && exec sleep 300 ) &
  leak_pid=$!
  trap 'kill -KILL "$leak_pid" 2>/dev/null || true; wait "$leak_pid" 2>/dev/null || true' EXIT
  for ((i=0; i<100; i++)); do
    [ "$(readlink "/proc/$leak_pid/cwd" 2>/dev/null)" != "$case_dir/wt" ] || break
    sleep 0.05
  done
  [ "$i" -lt 100 ] || fail 'hidden intermediate parent: leak did not start in the worktree'

  (
    cd "$case_dir/wt" || exit 1
    export FM_TEST_IN_COPY_CALLER=$BASHPID FM_TEST_LEAK_PID=$leak_pid FM_TEST_WORKTREE="$case_dir/wt"
    (
      # shellcheck disable=SC2030,SC2031 # Only descendants of this subshell use its PID.
      export FM_TEST_HIDDEN_ANCESTOR=$BASHPID
      cd "$case_dir" || exit 1
      FM_TEARDOWN_TEST_PATH="$path_without_lsof" run_teardown "$case_dir" || exit "$?"
    )
    rc=$?
    printf 'survived\n' > "$case_dir/caller"
    exit "$rc"
  ) > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "hidden intermediate parent ($scanner): cleanup should refuse"
  assert_present "$case_dir/caller" "hidden intermediate parent ($scanner): cleanup signalled the calling shell"
  kill -0 "$leak_pid" 2>/dev/null || fail "hidden intermediate parent ($scanner): cleanup signalled another match before refusing"
  assert_present "$case_dir/state/task-x1.meta" "hidden intermediate parent ($scanner): cleanup retired task metadata"
  assert_grep 'REFUSED: cannot verify teardown caller ancestry' "$case_dir/stderr" \
    "hidden intermediate parent ($scanner): cleanup did not report the ambiguous ancestry"
  pass "cleanup with $scanner refuses an ambiguous ancestor without signalling either cwd match"
)

test_non_treehouse_reap_with_unverified_session() (
  [ "$(uname -s)" = Linux ] || return 0
  local mode=$1 case_dir dir pid i rc=0
  case_dir=$(make_case "session-unverified-$mode")
  dir="$case_dir/wt"
  if [ "$mode" = orca ]; then
    command -v node >/dev/null 2>&1 || { printf 'skip: Orca fixture requires node\n'; return 0; }
    fm_write_meta "$case_dir/state/task-x1.meta" window=fm-task-x1 endpoint_task_id=task-x1 \
      "worktree=$dir" "project=$case_dir/project" kind=scout mode=local-only \
      backend=orca terminal=term-7 orca_worktree_id=worktree-9
    cat > "$case_dir/fakebin/orca" <<SH
#!/usr/bin/env bash
case "\$1 \$2" in
  'worktree show') printf '%s\n' '{"ok":true,"result":{"path":"$dir"}}' ;;
  'worktree rm') : > "$case_dir/orca-removed" ;;
  'terminal close') ;;
  *) exit 1 ;;
esac
SH
    chmod +x "$case_dir/fakebin/orca"
  else
    write_meta "$case_dir" local-only scout
    mkdir -p "$case_dir/pool/1"
    git -C "$case_dir/project" worktree move "$dir" "$case_dir/pool/1/project"
    ln -s pool/1/project "$dir"
    printf '{}\n' > "$case_dir/pool/treehouse-state.json"
    printf 'task=other-task\nhome=%s\n' "$case_dir/home" > "$case_dir/pool/1/.fm-slot-owner"
    dir="$case_dir/tasktmp"
    mkdir "$dir"
    printf 'tasktmp=%s\n' "$dir" >> "$case_dir/state/task-x1.meta"
  fi
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  '-o sid= -p '*) printf '%s\n' 99999999 ;;
  '-A -o pid= -o ppid= -o sid=') "$REAL_PS_FOR_TEST" "$@" | awk '{$3=99999999; print}' ;;
  *) exec "$REAL_PS_FOR_TEST" "$@" ;;
esac
SH
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
if cwd=$(readlink "/proc/$FM_TEST_LEAK_PID/cwd" 2>/dev/null); then
  printf 'p%s\nfcwd\nn%s\n' "$FM_TEST_LEAK_PID" "$cwd"
fi
SH
  printf '#!/usr/bin/env bash\nexit 2\n' > "$case_dir/fakebin/treehouse"
  chmod +x "$case_dir/fakebin/ps" "$case_dir/fakebin/lsof" "$case_dir/fakebin/treehouse"
  ( cd "$dir" && : > "$case_dir/ready" && exec sleep 30 ) &
  pid=$!
  trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT
  for ((i=0; i<100; i++)); do
    [ ! -e "$case_dir/ready" ] || break
    sleep 0.05
  done
  assert_present "$case_dir/ready" 'leaked process did not enter the fixture'
  FM_TEST_LEAK_PID=$pid run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" = 0 ] || fail "non-Treehouse reaping ($mode) refused: $(cat "$case_dir/stderr")"
  if kill -0 "$pid" 2>/dev/null; then fail "non-Treehouse reaping ($mode) left the leak alive"; fi
  if [ "$mode" = orca ]; then
    assert_present "$case_dir/orca-removed" 'Orca cleanup did not remove its copy'
  else
    assert_present "$case_dir/pool/1/.fm-slot-owner" 'task-temp cleanup changed the reassigned slot'
  fi
  assert_absent "$case_dir/state/task-x1.meta" 'non-Treehouse cleanup did not retire the task record'
  pass "non-Treehouse cleanup reaps leaks without requiring a verified Linux session ($mode)"
)

test_reparented_teardown_preserves_original_caller() (
  if [ "$(uname -s)" != Linux ]; then
    printf 'skip: reparented caller fixture requires Linux\n'
    return 0
  fi
  local mode=$1 case_dir leak_pid rc=0 i lock retries=1 copy task_branch hook parent
  local backlog_case=0 prior_close=${2:-none} prior_gen replay_data
  local -a teardown_args=()
  case_dir=$(make_case "reparented-teardown-$mode-$prior_close")
  if [[ "$mode" == child* ]]; then
    write_meta "$case_dir" local-only secondmate
    configure_secondmate_with_tmux_children "$case_dir"
    seed_descendant_close_for_replay "$case_dir/secondmate-home" child-a || fail 'could not stage the descendant close'
    copy="$case_dir/child-a-wt"
    task_branch=fm/child-a
    hook="$copy/.opencode/plugins/fm-busy-state.js"
    teardown_args=(--force)
  else
    write_meta "$case_dir" no-mistakes ship
    case "$mode" in
      inside)
        printf '%s\n' manual > "$case_dir/config/backlog-backend"
        ;;
      inside-backlog|retry|stale|stale-edit)
        backlog_case=1
        seed_backlog_in_flight "$case_dir"
        printf 'PR closure evidence\n' > "$case_dir/state/task-x1.pr-poll-closed"
        ;;
    esac
    if [ "$mode" = retry ]; then
      write_legacy_meta "$case_dir" no-mistakes ship
      teardown_args=(--legacy-record)
    fi
    if [ "$mode" = stale-edit ]; then
      wt_commit_file "$case_dir" feature.txt landed
    fi
    land_shippable_commit "$case_dir"
    copy="$case_dir/wt"
    task_branch=fm/task-x1
    hook="$copy/.claude/settings.local.json"
  fi
  if [ "$backlog_case" = 1 ]; then
    replay_data="$case_dir/data"
    if [ "$prior_close" = relocated ]; then
      replay_data="$case_dir/relocated/data"
      seed_backlog_in_flight "$case_dir" ship task-x1 "$replay_data" || fail 'could not seed the relocated backlog'
    fi
    cp "$case_dir/state/task-x1.meta" "$case_dir/meta-before"
    if [ "$prior_close" != none ]; then
      prior_gen=teardown-test-task-x1
      [ "$prior_close" != unrelated ] || prior_gen=older-task-incarnation
      (
        # shellcheck disable=SC2030,SC2031 # Scope the fixture home to staging the prior close.
        export FM_HOME="$case_dir/home"
        # shellcheck source=bin/fm-backlog-transition-lib.sh
        . "$ROOT/bin/fm-backlog-transition-lib.sh"
        fm_backlog_close_marker_write "$case_dir/state" task-x1 "$replay_data" "$prior_gen" --note 'local main'
      ) || fail 'could not seed the pre-existing close marker'
      cp "$case_dir/state/task-x1.backlog-close" "$case_dir/close-before"
    fi
  fi
  printf '/%s\n' "${hook#"$copy"/}" >> "$case_dir/project/.git/info/exclude"
  mkdir -p "${hook%/*}"
  printf 'configured hook\n' > "$hook"
  lock=$(git_index_lock_path "$copy")
  case "$mode" in stale|stale-edit) retries=0 ;; esac
  mkfifo "$case_dir/result" || fail 'reparented teardown: could not create result pipe'
  if [ "$mode" = hidden ]; then
    configure_teardown_ancestry_ps "$case_dir"
  fi

  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
[ "$1" != -- ] || exit 1
if [[ "$FM_TEST_REPARENT_MODE" == child* ]]; then
  : > "$FM_TEST_REPARENT_DIR/release"
fi
if [ -f "$FM_TEST_REPARENT_DIR/release" ] || [ -f "$FM_TEST_REPARENT_DIR/term" ]; then
  for ((i=0; i<100; i++)); do
    parent=$(ps -o ppid= -p "$FM_TEST_REAP_RUNNER" | tr -d '[:space:]')
    [ -z "$parent" ] || [ "$parent" = "$FM_TEST_REAP_WRAPPER" ] || break
    sleep 0.05
  done
  [ "$i" -lt 100 ] || exit 1
  : > "$FM_TEST_REPARENT_DIR/reparented"
fi
for pid in "$FM_TEST_REAP_CALLER" "$FM_TEST_REAP_LEAK"; do
  cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || continue
  printf 'p%s\nfcwd\nn%s\n' "$pid" "$cwd"
done
SH
  chmod +x "$case_dir/fakebin/lsof"

  if [ "$retries" -eq 0 ]; then
    cat > "$case_dir/fakebin/rm" <<'SH'
#!/usr/bin/env bash
"$REAL_RM_FOR_TEST" "$@" || exit $?
[ "$#" = 2 ] && [ "$2" = "$FM_TEST_REPARENT_LOCK" ] || exit 0
: > "$FM_TEST_REPARENT_DIR/move-caller"
for ((i=0; i<100; i++)); do
  [ ! -f "$FM_TEST_REPARENT_DIR/caller-moved" ] || exit 0
  sleep 0.05
done
exit 1
SH
    chmod +x "$case_dir/fakebin/rm"
  fi

  # Model Treehouse's second scan without signalling even a disposable caller.
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
log="$FM_TEST_REPARENT_DIR/treehouse.log"
printf 'return\n' >> "$log"
pid=$$
while [ "$pid" -gt 0 ]; do
  [ "$pid" != "$FM_TEST_REAP_CALLER" ] || exit 0
  pid=$(ps -o ppid= -p "$pid" | tr -d '[:space:]')
  [ -n "$pid" ] || exit 1
done
if [[ "/proc/$FM_TEST_REAP_CALLER/cwd" -ef "$3" ]]; then
  printf '%s\n' "$FM_TEST_REAP_CALLER" > "$FM_TEST_REPARENT_DIR/would-stop"
fi
[ "$(wc -l < "$log" | tr -d '[:space:]')" = 1 ] || exit 0
case "$FM_TEST_REPARENT_MODE" in
  retry|child|child-error)
    : > "$FM_TEST_REPARENT_DIR/move-caller"
    for ((i=0; i<100; i++)); do
      [ ! -f "$FM_TEST_REPARENT_DIR/caller-moved" ] || break
      sleep 0.05
    done
    [ "$i" -lt 100 ] || exit 1
    if [ "$FM_TEST_REPARENT_MODE" = child-error ]; then
      echo 'treehouse: simulated child return error' >&2
      exit 1
    fi
    ;;
  stale|stale-edit)
    : > "$FM_TEST_REPARENT_LOCK"
    touch -t 200001010000 "$FM_TEST_REPARENT_LOCK"
    ;;
  *) exit 0 ;;
esac
printf "fatal: Unable to create '%s': File exists.\n" "$FM_TEST_REPARENT_LOCK" >&2
exit 128
SH
  chmod +x "$case_dir/fakebin/treehouse"

  perl -MPOSIX -e '
    my ($dir) = @ARGV;
    chdir "$dir/wt" or die;
    $SIG{TERM} = sub { open my $term, ">", "$dir/term" or die; exit 0; };
    open my $ready, ">", "$dir/ready" or die;
    POSIX::pause();
  ' "$case_dir" &
  leak_pid=$!
  trap 'kill -KILL "$leak_pid" 2>/dev/null || true; wait "$leak_pid" 2>/dev/null || true' EXIT
  for ((i=0; i<100; i++)); do
    [ ! -f "$case_dir/ready" ] || break
    sleep 0.05
  done
  [ -f "$case_dir/ready" ] || fail 'reparented teardown: leak did not start'

  (
    if [ "$mode" = inside ] || [ "$mode" = inside-backlog ] || [ "$mode" = hidden ] || [ "$mode" = before-start ]; then
      cd "$copy" || exit 1
    fi
    if [ "$mode" = inside ]; then
      FM_FAKE_AXI_STATUS=$(parked_axi_status_toon "$task_branch" "$(git rev-parse HEAD)")
      export FM_FAKE_AXI_STATUS FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log"
    fi
    exec 3<>"$case_dir/result"
    export FM_TEST_REAP_CALLER=$BASHPID FM_TEST_REAP_LEAK=$leak_pid FM_TEST_REPARENT_DIR="$case_dir"
    export FM_TEST_REPARENT_MODE=$mode FM_TEST_REPARENT_LOCK=$lock
    (
      cd "$case_dir" || exit 1
      # shellcheck disable=SC2031 # This fixture exports its own wrapper PID.
      export FM_TEST_REAP_WRAPPER=$BASHPID FM_TEST_HIDDEN_ANCESTOR=$BASHPID
      (
        export FM_TEST_REAP_RUNNER=$BASHPID
        if [ "$mode" = before-start ]; then
          for ((i=0; i<100; i++)); do
            parent=$(ps -o ppid= -p "$FM_TEST_REAP_RUNNER")
            parent=${parent//[[:space:]]/}
            [ -z "$parent" ] || [ "$parent" = "$FM_TEST_REAP_WRAPPER" ] || break
            sleep 0.05
          done
          [ "$i" -lt 100 ] || exit 1
          : > "$case_dir/reparented"
        fi
        FM_TREEHOUSE_RETURN_LOCK_RETRIES=$retries FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
          run_teardown "$case_dir" ${teardown_args[@]+"${teardown_args[@]}"} || rc=$?
        : > "$case_dir/finished"
        printf '%s\n' "$rc" >&3
      ) &
      [ "$mode" != before-start ] || exit 0
      for ((i=0; i<300; i++)); do
        if [ -f "$case_dir/release" ] || [ -f "$case_dir/term" ] || [ -f "$case_dir/finished" ]; then
          exit 0
        fi
        sleep 0.05
      done
      exit 1
    ) || exit 1
    if [ "$mode" = retry ] || [ "$retries" -eq 0 ] || [[ "$mode" == child* ]]; then
      for ((i=0; i<100; i++)); do
        [ ! -f "$case_dir/move-caller" ] || break
        sleep 0.05
      done
      [ "$i" -lt 100 ] || exit 1
      cd "$copy" || exit 1
      if [ "$mode" = stale-edit ] || [ "$mode" = child-error ]; then
        printf 'caller edit\n' > feature.txt
      fi
      : > "$case_dir/caller-moved"
    fi
    IFS= read -r -t 20 rc <&3 || exit 1
    printf 'survived\n' > "$case_dir/caller"
    exit "$rc"
  ) > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  case "$mode" in
    inside|inside-backlog|hidden) ;;
    *) assert_present "$case_dir/reparented" 'reparented teardown: parent did not change' ;;
  esac
  assert_present "$case_dir/caller" 'reparented teardown: cleanup signalled the original caller'
  assert_absent "$case_dir/would-stop" 'Treehouse return would have stopped the original caller'
  if [ "$mode" = hidden ] || [ "$mode" = before-start ]; then
    expect_code 1 "$rc" 'reparented teardown: unknown startup ancestry should block cleanup'
    assert_present "$case_dir/state/task-x1.meta" 'reparented teardown: refusal retired task metadata'
    assert_absent "$case_dir/treehouse.log" 'reparented teardown: returned a copy with unknown startup ancestry'
    assert_absent "$case_dir/term" 'reparented teardown: refusal came after sending TERM'
    kill -0 "$leak_pid" 2>/dev/null || fail 'reparented teardown: refusal came after killing the leak'
    assert_grep 'REFUSED: cannot verify teardown caller ancestry' "$case_dir/stderr" \
      'reparented teardown: refusal did not report ambiguous ancestry'
    pass "cleanup refuses cwd matches with unknown startup ancestry ($mode)"
    return 0
  fi
  if [ "$mode" = inside ] || [ "$mode" = inside-backlog ]; then
    assert_absent "$case_dir/term" 'initial caller refusal let the reaper signal the leak'
    kill -0 "$leak_pid" 2>/dev/null || fail 'initial caller refusal came after killing the leak'
    assert_absent "$case_dir/nm-abort.log" 'initial caller refusal let teardown cancel a parked run'
  elif [[ "$mode" != child* ]]; then
    wait "$leak_pid" || fail 'reparented teardown: leak did not exit through its TERM handler'
    trap - EXIT
  fi
  if [ "$mode" = outside ]; then
    expect_code 0 "$rc" 'reparented teardown: cleanup should return the copy with the caller outside'
    assert_present "$case_dir/treehouse.log" 'reparented teardown: did not return the copy'
    assert_absent "$case_dir/state/task-x1.meta" 'reparented teardown: cleanup left the task record'
    assert_absent "$hook" 'successful teardown left the task hook behind'
  else
    if [[ "$mode" == child* ]]; then
      expect_code 5 "$rc" 'child teardown should propagate a caller refusal'
      assert_present "$case_dir/secondmate-home/state/child-a.meta" 'refusal retired the child task record'
      assert_pending_close_replay_preserves_task "$case_dir/secondmate-home" child-a || fail 'descendant replay did not preserve the return refusal'
      if [ "$mode" = child-error ]; then
        assert_grep 'treehouse: simulated child return error' "$case_dir/stderr" 'fallback fixture missed the non-lock return error'
        [ "$(cat "$copy/feature.txt")" = 'caller edit' ] || fail 'child fallback lost the caller edit'
      fi
    else
      expect_code 1 "$rc" "reparented teardown ($mode): cleanup should refuse an in-copy caller"
    fi
    if [ "$mode" = stale-edit ]; then
      assert_grep 'return aborted after stale-lock cleanup because safety checks failed' "$case_dir/stderr" 'missing safety refusal after the caller edit'
      [ "$(cat "$copy/feature.txt")" = 'caller edit' ] || fail 'reparented teardown: refusal lost the caller edit'
    else
      assert_grep 'teardown caller or ancestor (PID ' "$case_dir/stderr" 'missing caller refusal'
      assert_grep 'Retry from a separate terminal outside the task copy.' "$case_dir/stderr" \
        'caller refusal did not direct the operator to a separate terminal'
    fi
    assert_present "$copy" 'reparented teardown: refusal removed the copy'
    assert_present "$case_dir/state/task-x1.meta" 'reparented teardown: refusal retired task metadata'
    git -C "$copy" show-ref --verify --quiet "refs/heads/$task_branch" \
      || fail 'reparented teardown: refusal deleted the task branch'
    [ "$(git -C "$copy" symbolic-ref --short HEAD)" = "$task_branch" ] \
      || fail 'reparented teardown: refusal detached the task branch'
    [ "$(cat "$hook")" = 'configured hook' ] || fail 'reparented teardown: refusal changed the task hook'
    if [ "$mode" = inside ] || [ "$mode" = inside-backlog ]; then
      assert_absent "$case_dir/treehouse.log" 'reparented teardown: invoked Treehouse despite an in-copy caller'
    else
      [ "$(cat "$case_dir/treehouse.log")" = return ] \
        || fail 'reparented teardown: Treehouse ran again after the caller moved inside'
    fi
    if [ "$retries" -eq 0 ]; then
      assert_grep 'removed provably-stale git lock' "$case_dir/stderr" 'stale retry was not reached'
    fi
    if [ "$backlog_case" = 1 ]; then
      if [ "$prior_close" = unrelated ]; then
        cmp -s "$case_dir/close-before" "$case_dir/state/task-x1.backlog-close" \
          || fail 'caller refusal changed a marker for another incarnation'
      fi
      assert_pending_close_replay_preserves_task "$case_dir" task-x1 "$case_dir/home" "$replay_data" \
        || fail 'startup replay changed the retained task after caller refusal'
      cmp -s "$case_dir/meta-before" "$case_dir/state/task-x1.meta" \
        || fail 'caller refusal or startup replay changed the task record'
      [ "$(backlog_row_state "$case_dir")" = in_flight ] || fail 'startup replay closed a refused task'
    fi
    if [ "$mode" = retry ]; then
      # shellcheck disable=SC2016 # The Treehouse stub expands its own third argument.
      printf '#!/usr/bin/env bash\ngit -C "$3" checkout --detach -q main\n' > "$case_dir/fakebin/treehouse"
      rm -f "$case_dir/fakebin/lsof"
      run_teardown "$case_dir" --legacy-record > "$case_dir/retry.stdout" 2> "$case_dir/retry.stderr" \
        || fail 'reparented teardown: subsequent cleanup from outside the copy failed'
      assert_absent "$case_dir/state/task-x1.meta" 'subsequent cleanup left the task record'
      if git -C "$copy" show-ref --verify --quiet "refs/heads/$task_branch"; then
        fail 'subsequent cleanup retained the task branch'
      fi
    fi
  fi
  pass "cleanup protects its original caller after reparenting ($mode, prior close: $prior_close)"
)

test_non_linux_skips_process_group_reap() (
  local mode=$1 scope=$2 case_dir test_path real_uname rc=0
  case_dir=$(make_case "fallback-group-$mode-$scope")
  write_meta "$case_dir" local-only ship
  if [ "$scope" = tasktmp ]; then
    mkdir -p "$case_dir/pool/1"
    git -C "$case_dir/project" worktree move "$case_dir/wt" "$case_dir/pool/1/project" || exit 1
    ln -s pool/1/project "$case_dir/wt"
    printf '{}\n' > "$case_dir/pool/treehouse-state.json"
    printf 'task=other-task\nhome=%s\n' "$case_dir/home" > "$case_dir/pool/1/.fm-slot-owner"
  else
    git -C "$case_dir/project" worktree remove "$case_dir/wt" || exit 1
  fi
  mkdir "$case_dir/tasktmp"
  printf 'tasktmp=%s\n' "$case_dir/tasktmp" >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir" || fail 'could not seed the fallback backlog'
  ln -s "$(command -v tasks-axi)" "$case_dir/fakebin/tasks-axi"
  ln -s "$(command -v node)" "$case_dir/fakebin/node"
  test_path=$(make_path_without_lsof "$case_dir")
  real_uname=$(command -v uname)
  cat > "$case_dir/fakebin/uname" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = -s ]; then printf 'Darwin\n'; else exec '$real_uname' "\$@"; fi
EOF
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
snapshot='@17:1:$1:fm-task-x1:'"$(cat "$CASE_DIR/target")"':%17:/dev/ttys017:'
if [ "${1:-}" = display-message ] && [ "${*: -1}" = '#{pane_pid}' ]; then
  cat "$CASE_DIR/target"
elif [ "${1:-}" = list-windows ]; then
  [ "$#" = 5 ] && [ "$2 $3 $4" = '-t =firstmate -F' ] || exit 1
  case "$5" in
    '#{?#{==:#{window_name},fm-task-x1},'*) ;;
    *) exit 1 ;;
  esac
  printf '%s\n' "$snapshot"
elif [ "${1:-}" = if-shell ] || [ "${1:-}" = kill-window ]; then
  if [ "$#" = 7 ] && [ "$1 $2 $3 $4" = 'if-shell -F -t =firstmate:@17' ] \
    && [ "$5" = '#{==:#{window_id}:#{pid}:#{session_id}:#{window_name}:#{P:#{pane_pid}:#{pane_id}:#{pane_tty}:},'"$snapshot}" ] \
    && [ "$6" = "kill-window -t '\$1:@17'" ] && [ "$7" = 'display-message -p changed' ]; then
    printf 'guarded-close @17\n' >> "$CASE_DIR/window-close-request"
  else
    printf 'unexpected request\n' >> "$CASE_DIR/window-close-request"
    exit 1
  fi
fi
SH
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  '-o tty= -p '*)
    if [ "$TEST_MODE" = headless ]; then printf '??\n'; else printf 'ttys099\n'; fi
    exit 0 ;;
  '-u '*'-o pid=,command=') exit 0 ;;  # Disable the independent host-wide orphan sweep.
esac
exec "$REAL_PS_FOR_TEST" "$@"
SH
  chmod +x "$case_dir/fakebin/uname" "$case_dir/fakebin/tmux" "$case_dir/fakebin/ps"

  TMUX_PANE= CASE_DIR=$case_dir TEST_MODE=$mode FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
    FM_CONFIG_OVERRIDE="$case_dir/config" PATH="$case_dir/fakebin:$test_path" \
    FM_TEARDOWN_GUARD_DONE=1 FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" \
    perl - "$TEARDOWN" "$REAL_PS_FOR_TEST" > "$case_dir/stdout" 2> "$case_dir/stderr" <<'PL' || rc=$?
use strict;
use warnings;
use Time::HiRes qw(sleep);
my ($teardown, $ps) = @ARGV;
my $dir = $ENV{CASE_DIR};
sub record {
    my ($name, $value) = @_;
    open my $out, '>', "$dir/$name" or die $!;
    print $out "$value\n";
    close $out or die $!;
}
chdir "$dir/tasktmp" or die $!;
setpgrp(0, 0) or die $!;
$SIG{TERM} = sub { record('term', $$) };
my $caller = $$;
my $leak;
if ($ENV{TEST_MODE} ne 'caller') {
    $leak = fork // die $!;
    if (!$leak) {
        setpgrp(0, 0) or die $!;
        record('target', $$);
        alarm 30;
        sleep 0.05 until -e "$dir/release";
        exit 0;
    }
    for (1..100) {
        last if -s "$dir/target";
        sleep 0.05;
    }
    die 'leak group did not start' unless -s "$dir/target";
} else {
    record('target', $caller);
}
my $cleanup = fork // die $!;
if (!$cleanup) {
    setpgrp(0, 0) or die $!;
    my $caller_group = qx($ps -o pgid= -p $caller);
    my $cleanup_group = qx($ps -o pgid= -p $$);
    die 'caller and cleanup must occupy separate groups'
        unless $caller_group =~ /^\s*$caller\s*$/ && $cleanup_group =~ /^\s*$$\s*$/;
    chdir $dir or die $!;
    exec $teardown, 'task-x1' or die $!;
}
alarm 25;
waitpid($cleanup, 0) == $cleanup or die 'could not wait for teardown';
my $cleanup_status = $?;
if (defined $leak) {
    record('release', 1);
    waitpid($leak, 0) == $leak or die 'could not wait for target process';
    die "target process did not exit normally after teardown (wait status $?)" if $? != 0;
}
die "teardown failed (wait status $cleanup_status)" if $cleanup_status != 0;
PL
  [ "$rc" = 0 ] || fail "fallback-group-$mode-$scope: fixture exited $rc: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/term" 'fallback sent TERM to the target group'
  assert_grep 'warning: lsof is unavailable on this platform; leaving leaked processes running for tmux task task-x1 because teardown cannot verify caller safety' \
    "$case_dir/stderr" "fallback did not explain why it skipped reaping: $(cat "$case_dir/stderr")"
  if [ "$mode" = caller ]; then
    assert_absent "$case_dir/window-close-request" 'teardown requested closure of the caller window'
    assert_grep 'is teardown or its ancestor' "$case_dir/stderr" 'caller window refusal had no diagnostic'
  else
    [ -f "$case_dir/window-close-request" ] \
      && [ "$(cat "$case_dir/window-close-request")" = 'guarded-close @17' ] \
      || fail 'teardown did not request guarded closure of the recorded window'
  fi
  assert_absent "$case_dir/tasktmp" 'teardown left the task temp directory'
  assert_absent "$case_dir/state/task-x1.meta" 'teardown left the task record'
  assert_absent "$case_dir/state/task-x1.backlog-close" 'teardown left a pending backlog close'
  [ "$(backlog_row_state "$case_dir")" = 'done' ] || fail 'teardown left the backlog item open'
  pass "non-Linux cleanup skips reaping the $mode group ($scope)"
)

test_lsof_absent_on_non_linux_preserves_tmux_process_group() {
  local case_dir rc pid path_without_lsof real_uname
  case_dir=$(make_case lsof-absent-process-group-reap)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  path_without_lsof=$(make_path_without_lsof "$case_dir")
  PATH="$path_without_lsof" command -v lsof >/dev/null 2>&1 \
    && fail "lsof-absent-process-group-reap: fixture path unexpectedly exposes lsof"
  real_uname=$(command -v uname)
  cat > "$case_dir/fakebin/uname" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = -s ]; then printf 'Darwin\n'; else exec '$real_uname' "\$@"; fi
EOF
  chmod +x "$case_dir/fakebin/uname"

  perl -e 'setpgrp(0, 0); chdir shift or die; exec "sleep", "300"' "$case_dir/wt" &
  pid=$!
  disown
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "lsof-absent-process-group-reap: setup sleeper did not start"
  cat > "$case_dir/fakebin/tmux" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = display-message ] && [ "\${*: -1}" = '#{pane_pid}' ]; then
  printf '%s\n' '$pid'
fi
# The exact-window read confirms the task window in this inventory.
if [ "\${1:-}" = list-windows ]; then
  printf '%s\n' '@1 firstmate:fm-task-x1' | fm_fake_tmux_window_ids "\$@"
fi
exit 0
EOF
  chmod +x "$case_dir/fakebin/tmux"

  rc=0
  FM_TEARDOWN_TEST_PATH="$path_without_lsof" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "lsof-absent-process-group-reap: return should refuse without a cwd scanner"
  assert_grep 'cannot verify caller working directories' "$case_dir/stderr" \
    "lsof-absent-process-group-reap: teardown did not report the return refusal"
  assert_present "$case_dir/state/task-x1.meta" "lsof-absent-process-group-reap: refusal retired task metadata"
  kill -0 "$pid" 2>/dev/null || fail "lsof-absent-process-group-reap: refusal killed the tmux process group"
  kill -KILL "$pid" 2>/dev/null || true
  pass "missing lsof on a non-Linux host refuses Treehouse return before reaping the tmux pane process group"
}

test_lsof_error_refuses_before_removal() {
  local case_dir rc
  case_dir=$(make_case lsof-error-refusal)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
printf 'return\n' >> "$case_dir/treehouse.log"
EOF
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/treehouse"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "lsof-error-refusal: teardown should refuse"
  assert_grep 'cannot verify caller working directories' "$case_dir/stderr" \
    "lsof-error-refusal: teardown did not explain the lsof refusal"
  assert_present "$case_dir/wt" "lsof-error-refusal: teardown removed the worktree"
  assert_present "$case_dir/state/task-x1.meta" "lsof-error-refusal: teardown removed task metadata"
  assert_absent "$case_dir/treehouse.log" "lsof-error-refusal: teardown returned the worktree"
  pass "an erroring lsof scan refuses teardown and preserves the task"
}

test_reused_pid_identity_is_not_force_killed() (
  local case_dir rc pid i
  case_dir=$(make_case reused-pid-identity)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"

  perl -MPOSIX -e '
    my $dir = shift;
    $SIG{TERM} = sub { open my $term, ">", "$dir/term" or die; };
    open my $ready, ">", "$dir/ready" or die;
    while (1) { POSIX::pause(); }
  ' "$case_dir" &
  pid=$!
  trap 'kill -KILL "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT
  for ((i=0; i<100; i++)); do
    [ ! -f "$case_dir/ready" ] || break
    sleep 0.05
  done
  assert_present "$case_dir/ready" 'reused-pid-identity: fixture process did not start'
  cat > "$case_dir/fakebin/lsof" <<EOF
#!/usr/bin/env bash
if [ ! -f '$case_dir/replacement-sampled' ]; then
  printf 'p%s\nfcwd\nn%s\n' '$pid' '$case_dir/wt'
fi
EOF
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${FM_FAKE_REUSED_PID:-}" ] \
   && [ "${3:-}" = -o ] && [ "${4:-}" = lstart= ]; then
  if [ -f "$FM_FAKE_PID_EVENTS/post-term-sampled" ]; then
    : > "$FM_FAKE_PID_EVENTS/replacement-sampled"
    printf 'Tue Aug  4 10:00:01 2026\n'
  else
    if [ -f "$FM_FAKE_PID_EVENTS/term" ]; then
      : > "$FM_FAKE_PID_EVENTS/post-term-sampled"
    fi
    printf 'Tue Aug  4 10:00:00 2026\n'
  fi
  exit 0
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/ps"

  rc=0
  FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" \
  FM_FAKE_REUSED_PID="$pid" FM_FAKE_PID_EVENTS="$case_dir" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "reused-pid-identity: teardown should skip the replacement process"
  assert_present "$case_dir/replacement-sampled" 'reused-pid-identity: teardown did not sample the replacement identity'
  if ! kill -0 "$pid" 2>/dev/null; then
    fail "reused-pid-identity: teardown force-killed a process whose start time changed"
  fi
  pass "a reused pid with a different start time is never force-killed"
)

test_exec_changed_process_is_still_reaped() {
  local case_dir rc pid marker done_flag survived=0
  require_lsof_for_case exec-changed-process || return 0
  case_dir=$(make_case exec-changed-process)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  marker="$case_dir/exec-now"
  done_flag="$case_dir/exec-done"

  ( cd "$case_dir/wt" && exec perl -e '
      my ($marker, $done) = @ARGV;
      until (-e $marker) { select undef, undef, undef, 0.01; }
      exec "bash", "-c", q{
        trap "" TERM
        : > "$1" || exit 1
        exec sleep 300
      }, "exec-changed-process", $done;
    ' "$marker" "$done_flag" ) &
  pid=$!
  disown
  sleep 0.2
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${FM_FAKE_EXEC_PID:-}" ] \
   && [ "${3:-}" = -o ] && [ "${4:-}" = lstart= ]; then
  out=$("$REAL_PS_FOR_TEST" "$@") || exit $?
  [ -e "$FM_FAKE_EXEC_MARKER" ] || : > "$FM_FAKE_EXEC_MARKER"
  printf '%s\n' "$out"
  exit 0
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
if [ -e "$FM_FAKE_EXEC_MARKER" ]; then
  i=0
  while [ "$i" -lt 100 ]; do
    [ ! -e "$FM_FAKE_EXEC_DONE" ] || break
    sleep 0.01
    i=$((i + 1))
  done
  [ -e "$FM_FAKE_EXEC_DONE" ] || exit 1
fi
exec "$REAL_LSOF_FOR_TEST" "$@"
SH
  chmod +x "$case_dir/fakebin/ps" "$case_dir/fakebin/lsof"

  rc=0
  FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" \
  FM_FAKE_EXEC_PID="$pid" FM_FAKE_EXEC_MARKER="$marker" \
  FM_FAKE_EXEC_DONE="$done_flag" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  if kill -0 "$pid" 2>/dev/null; then
    survived=1
    kill -KILL "$pid" 2>/dev/null || true
  fi
  expect_code 0 "$rc" "exec-changed-process: teardown should succeed"
  assert_present "$done_flag" 'exec-changed-process: replacement program did not become ready'
  [ "$survived" -eq 0 ] || fail "exec-changed-process: exec-changed leaked process survived teardown"
  pass "an exec change preserves birth identity and the process is reaped"
}

test_process_spawned_during_grace_is_reaped_on_later_pass() {
  local case_dir rc pid child_file child_pid="" parent_survived=0 child_survived=0
  require_lsof_for_case grace-spawn-convergence || return 0
  case_dir=$(make_case grace-spawn-convergence)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  child_file="$case_dir/child.pid"

  ( cd "$case_dir/wt" && exec perl -e '
      my $file = shift;
      $SIG{TERM} = sub {
        my $child = fork();
        die "fork" unless defined $child;
        if (!$child) { exec "sleep", "300"; }
        open my $fh, ">", $file or die "open";
        print {$fh} "$child\n";
        close $fh;
        exit 0;
      };
      sleep 300;
    ' "$child_file" ) &
  pid=$!
  disown
  sleep 0.2

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  if [ -f "$child_file" ]; then child_pid=$(cat "$child_file"); fi
  if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
    child_survived=1
    kill -KILL "$child_pid" 2>/dev/null || true
  fi
  if kill -0 "$pid" 2>/dev/null; then
    parent_survived=1
    kill -KILL "$pid" 2>/dev/null || true
  fi
  expect_code 0 "$rc" "grace-spawn-convergence: teardown should converge"
  assert_present "$child_file" "grace-spawn-convergence: TERM handler did not spawn a child"
  [ "$child_survived" -eq 0 ] || fail "grace-spawn-convergence: spawned child survived"
  [ "$parent_survived" -eq 0 ] || fail "grace-spawn-convergence: original process survived"
  pass "a process spawned during grace is reaped on a later pass"
}

test_persistent_scan_refuses_after_bounded_retries() {
  local case_dir rc wt_path fake_pid=99999999
  case_dir=$(make_case persistent-reap-refusal)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  wt_path=$(cd "$case_dir/wt" && pwd -P)
  cat > "$case_dir/fakebin/lsof" <<EOF
#!/usr/bin/env bash
printf 'p%s\nfcwd\nn%s\n' '$fake_pid' '$wt_path'
EOF
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${FM_FAKE_PERSISTENT_PID:-}" ] \
   && [ "${3:-}" = -o ] && [ "${4:-}" = lstart= ]; then
  printf 'Tue Aug  4 10:00:00 2026\n'
  exit 0
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/ps"

  rc=0
  FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" FM_FAKE_PERSISTENT_PID="$fake_pid" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "persistent-reap-refusal: teardown should refuse"
  assert_grep "remain after 3 reap attempts" "$case_dir/stderr" \
    "persistent-reap-refusal: teardown did not report bounded non-convergence"
  assert_present "$case_dir/wt" "persistent-reap-refusal: teardown removed the worktree"
  assert_present "$case_dir/state/task-x1.meta" "persistent-reap-refusal: teardown removed task metadata"
  pass "persistent leaked processes refuse teardown after bounded retries"
}

test_process_exit_during_identity_lookup_does_not_refuse() {
  local case_dir rc wt_path fake_pid=99999998
  case_dir=$(make_case identity-exit-convergence)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  wt_path=$(cd "$case_dir/wt" && pwd -P)
  cat > "$case_dir/fakebin/lsof" <<EOF
#!/usr/bin/env bash
if [ ! -f "$case_dir/missing-identity-sampled" ]; then
  printf 'p%s\nfcwd\nn%s\n' '$fake_pid' '$wt_path'
fi
EOF
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${FM_FAKE_EXITED_PID:-}" ] \
   && [ "${3:-}" = -o ] && [ "${4:-}" = lstart= ]; then
  : > "$FM_FAKE_MISSING_IDENTITY_SAMPLE"
  exit 1
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
printf 'returned\n' > "$case_dir/treehouse.log"
EOF
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/ps" "$case_dir/fakebin/treehouse"

  rc=0
  FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" FM_FAKE_EXITED_PID="$fake_pid" \
    FM_FAKE_MISSING_IDENTITY_SAMPLE="$case_dir/missing-identity-sampled" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "identity-exit-convergence: teardown should succeed"
  assert_present "$case_dir/missing-identity-sampled" 'identity-exit-convergence: teardown did not sample the missing identity'
  assert_present "$case_dir/treehouse.log" \
    "identity-exit-convergence: teardown did not reach worktree return"
  ! grep -q REFUSED "$case_dir/stderr" || \
    fail "identity-exit-convergence: a disappeared process caused teardown refusal"
  pass "a process exiting during identity lookup does not block teardown"
}

test_run_abort_precedes_process_reap_precedes_worktree_removal() {
  local case_dir rc head pid abort_log
  require_lsof_for_case abort-then-reap-then-remove-order || return 0
  case_dir=$(make_case abort-then-reap-then-remove-order)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  abort_log="$case_dir/nm-abort.log"

  ( cd "$case_dir/wt" && exec sleep 300 ) &
  pid=$!
  disown
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "abort-then-reap-then-remove-order: setup sleeper did not start"

  # A treehouse fake that snapshots, at the exact moment the destructive
  # worktree return runs, whether the run was already aborted and whether the
  # leaked process was already reaped - direct causal proof of ordering from
  # real observed state, not a source-text or line-number correlation.
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
if [ -s "$abort_log" ]; then echo "abort-already-happened" >> "$case_dir/order.log"; fi
if ! kill -0 $pid 2>/dev/null; then echo "reap-already-happened" >> "$case_dir/order.log"; fi
exit 0
EOF
  chmod +x "$case_dir/fakebin/treehouse"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$abort_log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "abort-then-reap-then-remove-order: teardown should still succeed"
  kill -0 "$pid" 2>/dev/null && { kill -KILL "$pid" 2>/dev/null || true; }

  assert_present "$case_dir/order.log" \
    "abort-then-reap-then-remove-order: the destructive worktree return was never invoked"
  assert_grep "abort-already-happened" "$case_dir/order.log" \
    "abort-then-reap-then-remove-order: the run was not yet aborted when the worktree return ran"
  assert_grep "reap-already-happened" "$case_dir/order.log" \
    "abort-then-reap-then-remove-order: the leaked process was not yet reaped when the worktree return ran"
  pass "the run abort and the leaked-process reap both complete before the destructive worktree return"
}

# Canned transport with an inert, real process birth identity; the opt-in lab
# below proves these shell/cwd assumptions against a real Herdr pane as well.
configure_keep_pane_case() {
  local case_dir=$1
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  mkdir -p "$case_dir/pool/1"
  git -C "$case_dir/project" worktree move "$case_dir/wt" "$case_dir/pool/1/project"
  ln -s pool/1/project "$case_dir/wt"
  printf '{}\n' > "$case_dir/pool/treehouse-state.json"
  printf 'task=task-x1\nhome=%s\n' "$case_dir" > "$case_dir/pool/1/.fm-slot-owner"
  printf 'harness=codex\n' >> "$case_dir/state/task-x1.meta"
  cat > "$case_dir/fakebin/keep-ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  '-axo pid=,ppid=')
    printf '%s 1\n' "$FM_KEEP_PID"
    [ "${FM_KEEP_MODE:-}" != child ] || printf '999999 %s\n' "$FM_KEEP_PID"
    ;;
  *) printf 'S\n' ;;
esac
SH
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
printf 'p%s\n' "$FM_KEEP_PID"
if [ -f "$FM_KEEP_CASE/detached" ]; then printf 'n/\n'; else printf 'n%s/wt\n' "$FM_KEEP_CASE"; fi
SH
  cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_KEEP_CASE/herdr.log"
case "${1:-} ${2:-}" in
  'session list') printf '{"sessions":[{"name":"default","running":true,"socket_path":"%s/herdr.sock"}]}\n' "$FM_KEEP_CASE" ;;
  'status --json') printf '{"server":{"running":true}}\n' ;;
  'pane close') : > "$FM_KEEP_CASE/closed" ;;
  'pane get')
    if [ -f "$FM_KEEP_CASE/closed" ] || [ "${FM_KEEP_MODE:-}" = missing ]; then
      printf '{"error":{"code":"pane_not_found"}}\n'; exit 1
    fi
    if [ "${FM_KEEP_MODE:-}" = unknown ]; then printf 'not-json\n'; exit 0; fi
    printf '{"result":{"pane":{"pane_id":"wG:pQ","workspace_id":"wG","tab_id":"wG:tQ","terminal_id":"term-task"}}}\n'
    ;;
  'pane process-info')
    name=bash
    [ "${FM_KEEP_MODE:-}" != alive ] || name=node
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"wG:pQ","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"%s","argv0":"%s"}]}}}\n' "$FM_KEEP_PID" "$FM_KEEP_PID" "$FM_KEEP_PID" "$name" "$name"
    ;;
  'pane run')
    [ "${3:-}" = wG:pQ ] && [ "${4:-}" = 'cd /' ] || exit 9
    [ "${FM_KEEP_MODE:-}" != detach-fails ] || exit 1
    if [ -p "$FM_KEEP_CASE/shell-input" ]; then
      printf '%s\n' "$4" 1<>"$FM_KEEP_CASE/shell-input" || exit 1
    fi
    : > "$FM_KEEP_CASE/detached"
    ;;
  'workspace list')
    if [ "${FM_KEEP_MODE:-}" = journal-ambiguous ]; then
      printf '{"result":{"workspaces":[{"workspace_id":"wG","label":"└ task-x1 · p:AbCdEfGhIjKlMnOpQrStUv"},{"workspace_id":"wH","label":"other · p:AbCdEfGhIjKlMnOpQrStUv"}]}}\n'
    elif [ "${FM_KEEP_MODE:-}" = journal-mismatch ]; then
      printf '{"result":{"workspaces":[{"workspace_id":"wH","label":"└ task-x1 · p:AbCdEfGhIjKlMnOpQrStUv"}]}}\n'
    else
      printf '{"result":{"workspaces":[{"workspace_id":"wG","label":"└ task-x1 · p:AbCdEfGhIjKlMnOpQrStUv"}]}}\n'
    fi
    ;;
  'agent get') printf '{"error":{"code":"agent_not_found"}}\n'; exit 1 ;;
esac
SH
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_KEEP_CASE/treehouse.log"
[ "${FM_KEEP_MODE:-}" != return-fails ] || exit 1
git -C "$3" checkout --detach -q main || exit 1
[ "${FM_KEEP_MODE:-}" != lost-after-return ] || : > "$FM_KEEP_CASE/closed"
exit 0
SH
  chmod +x "$case_dir/fakebin/keep-ps" "$case_dir/fakebin/herdr" "$case_dir/fakebin/lsof" "$case_dir/fakebin/treehouse"
  cat > "$case_dir/fakebin/rm" <<'SH'
#!/usr/bin/env bash
if [ "${FM_KEEP_MODE:-}" = journal-remove-fails ]; then
  for arg in "$@"; do
    [ "$arg" != "$FM_KEEP_CASE/state/task-x1.herdr-presentation" ] || exit 1
  done
fi
exec "$REAL_RM_FOR_TEST" "$@"
SH
  chmod +x "$case_dir/fakebin/rm"
}

run_keep_pane_case() {
  local case_dir=$1; shift
  FM_KEEP_CASE="$case_dir" FM_KEEP_PID="$KEEP_TEST_PID" \
    FM_HERDR_PS_BIN="$case_dir/fakebin/keep-ps" FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    run_teardown "$case_dir" "$@"
}

test_keep_pane_without_lsof() (
  if [ "$(uname -s)" != Linux ]; then
    printf 'skip: keep-pane /proc cwd proof requires Linux\n'
    return 0
  fi
  local case_dir path_without_lsof shell_pid='' leak_pid='' i
  case_dir=$(make_case keep-pane-no-lsof)
  configure_keep_pane_case "$case_dir"
  rm -f "$case_dir/fakebin/lsof"
  path_without_lsof=$(make_path_without_lsof "$case_dir")
  if PATH="$case_dir/fakebin:$path_without_lsof" command -v lsof >/dev/null 2>&1; then
    fail 'keep-pane-no-lsof: fixture path unexpectedly exposes lsof'
  fi
  # shellcheck disable=SC2016 # The generated readlink stub expands its own arguments.
  printf '#!/usr/bin/env bash\n[ "${1:-}" != -e ] || exit 1\nexec %q "$@"\n' \
    "$path_without_lsof/readlink" > "$case_dir/fakebin/readlink"
  chmod +x "$case_dir/fakebin/readlink"
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "$#" -ne 3 ] || [ "$1" != return ] || [ "$2" != --force ] || [ "$3" != "$FM_KEEP_CASE/wt" ]; then
  printf 'unexpected Treehouse return arguments: %s\n' "$*" >&2
  exit 1
fi
if ! [[ "/proc/$FM_KEEP_PID/cwd" -ef / ]]; then
  printf 'original pane shell was not at / when Treehouse returned the copy\n' >&2
  exit 1
fi
if kill -0 "$FM_KEEP_LEAK_PID" 2>/dev/null; then
  printf 'the detached leak was still alive when Treehouse returned the copy\n' >&2
  exit 1
fi
: > "$FM_KEEP_CASE/return-verified"
SH
  mkfifo "$case_dir/shell-input" || fail 'keep-pane-no-lsof: could not create pane input'
  trap 'for child in "$shell_pid" "$leak_pid"; do
    [ -n "$child" ] || continue
    kill -KILL "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
  done' EXIT
  (
    cd "$case_dir/wt" || exit 1
    exec perl -MPOSIX -e 'POSIX::setsid() > 0 or die; exec @ARGV' bash -c '
      IFS= read -r -t "$FM_TEST_STUB_MAX_BLOCK_SECONDS" command &&
        [ "$command" = "cd /" ] && cd / && IFS= read -r -t "$FM_TEST_STUB_MAX_BLOCK_SECONDS"
    ' <>"$case_dir/shell-input"
  ) &
  shell_pid=$!
  perl -MPOSIX -e 'POSIX::setsid() > 0 or die; chdir shift or die; exec "sleep", "300"' "$case_dir/wt" &
  leak_pid=$!
  for ((i=0; i<100; i++)); do
    if [ "$(ps -p "$shell_pid" -o comm=)" = bash ] \
       && [ "$(readlink "/proc/$shell_pid/cwd" 2>/dev/null)" = "$case_dir/pool/1/project" ] \
       && [ "$(readlink "/proc/$leak_pid/cwd" 2>/dev/null)" = "$case_dir/pool/1/project" ]; then
      break
    fi
    sleep 0.05
  done
  [ "$i" -lt 100 ] || fail 'keep-pane-no-lsof: shell and leak did not start in the worktree'

  FM_KEEP_CASE="$case_dir" FM_KEEP_PID="$shell_pid" FM_KEEP_LEAK_PID="$leak_pid" \
    FM_TEARDOWN_TEST_PATH="$path_without_lsof" \
    run_teardown "$case_dir" --keep-pane > "$case_dir/out" 2> "$case_dir/err" \
    || fail "keep-pane-no-lsof: retirement failed: $(cat "$case_dir/err")"
  [ "$(readlink "/proc/$shell_pid/cwd" 2>/dev/null)" = / ] || fail 'keep-pane-no-lsof: original shell did not survive at /'
  ! kill -0 "$leak_pid" 2>/dev/null || fail 'keep-pane-no-lsof: detached worktree process survived'
  wait "$leak_pid" 2>/dev/null || true
  leak_pid=''
  assert_absent "$case_dir/closed" 'keep-pane-no-lsof: cleanup closed the exact pane'
  assert_present "$case_dir/return-verified" 'keep-pane-no-lsof: cleanup did not return the worktree after reaping and detaching'
  assert_absent "$case_dir/state/task-x1.meta" 'keep-pane-no-lsof: cleanup retained task metadata'
  pass 'Linux keep-pane cleanup without lsof detaches the shell and reaps the leak before returning the worktree'
)

test_keep_pane_retirement() {
  local case_dir mode rc before show
  sleep 300 &
  KEEP_TEST_PID=$!
  trap 'kill "$KEEP_TEST_PID" 2>/dev/null || true; fm_test_cleanup' EXIT

  case_dir=$(make_case keep-pane-success)
  configure_keep_pane_case "$case_dir"
  seed_backlog_in_flight "$case_dir"
  printf 'version=2\ntask_id=task-x1\nprojection_id=AbCdEfGhIjKlMnOpQrStUv\nhome=%s\nsession=default\nworkspace_id=wG\ntab_id=wG:tQ\npane_id=wG:pQ\nparent_workspace_id=wH\nparent_label=parent\nworkspace_label=└ task-x1 · p:AbCdEfGhIjKlMnOpQrStUv\ntask_label=fm-task-x1\n' \
    "$case_dir/home" > "$case_dir/state/task-x1.herdr-presentation"
  run_keep_pane_case "$case_dir" --keep-pane > "$case_dir/out" 2> "$case_dir/err" \
    || fail "keep-pane retirement failed: $(cat "$case_dir/err")"
  assert_absent "$case_dir/closed" "keep-pane closed the exact pane"
  assert_present "$case_dir/detached" "keep-pane returned copy before shell detach"
  assert_present "$case_dir/treehouse.log" "keep-pane did not return the copy"
  assert_absent "$case_dir/pool/1/.fm-slot-owner" "keep-pane leaked its slot claim"
  assert_absent "$case_dir/state/task-x1.meta" "keep-pane leaked task metadata"
  assert_absent "$case_dir/state/task-x1.herdr-presentation" "keep-pane leaked a correlated journal"
  if git -C "$case_dir/wt" show-ref --verify --quiet refs/heads/fm/task-x1; then
    fail 'successful keep-pane cleanup retained the task branch'
  fi
  [ "$(backlog_row_state "$case_dir")" = "done" ] || fail "keep-pane failed backlog close"
  assert_grep 'pane default:wG:pQ preserved' "$case_dir/out" "keep-pane did not report preservation"
  pass "keep-pane retires a landed task and its own slot with exact pane survival and shell detachment"

  case_dir=$(make_case keep-pane-stale-workspace)
  configure_keep_pane_case "$case_dir"
  seed_backlog_in_flight "$case_dir"
  sed -i.bak 's/^herdr_workspace_id=.*/herdr_workspace_id=wStale/' "$case_dir/state/task-x1.meta"
  printf 'version=1\ntask_id=task-x1\nprojection_id=AbCdEfGhIjKlMnOpQrStUv\n' > "$case_dir/state/task-x1.herdr-presentation"
  run_keep_pane_case "$case_dir" --keep-pane > "$case_dir/out" 2> "$case_dir/err" \
    || fail "keep-pane stale workspace failed: $(cat "$case_dir/err")"
  assert_absent "$case_dir/state/task-x1.herdr-presentation" "stale workspace left an actionable journal"
  assert_absent "$case_dir/state/task-x1.meta" "stale workspace left the task record"
  assert_absent "$case_dir/closed" "stale workspace closed the pane"
  pass "keep-pane retires its exact journal when the recorded workspace id is stale"

  for mode in journal-ambiguous journal-mismatch journal-unreadable journal-wrong-pane journal-remove-fails; do
    case_dir=$(make_case "keep-pane-$mode")
    configure_keep_pane_case "$case_dir"
    seed_backlog_in_flight "$case_dir"
    printf 'version=1\ntask_id=task-x1\nprojection_id=AbCdEfGhIjKlMnOpQrStUv\n' > "$case_dir/state/task-x1.herdr-presentation"
    if [ "$mode" = journal-unreadable ]; then
      printf 'projection_id=AbCdEfGhIjKlMnOpQrStUv\n' >> "$case_dir/state/task-x1.herdr-presentation"
    elif [ "$mode" = journal-wrong-pane ]; then
      printf 'version=2\ntask_id=task-x1\nprojection_id=AbCdEfGhIjKlMnOpQrStUv\nhome=%s\nsession=default\nworkspace_id=wG\ntab_id=wG:tQ\npane_id=wG:pOther\nparent_workspace_id=wH\nparent_label=parent\nworkspace_label=└ task-x1 · p:AbCdEfGhIjKlMnOpQrStUv\ntask_label=fm-task-x1\n' \
        "$case_dir/home" > "$case_dir/state/task-x1.herdr-presentation"
    fi
    rc=0
    FM_KEEP_MODE="$mode" run_keep_pane_case "$case_dir" --keep-pane > "$case_dir/out" 2> "$case_dir/err" || rc=$?
    [ "$rc" -ne 0 ] || fail "keep-pane $mode unexpectedly succeeded"
    assert_present "$case_dir/state/task-x1.herdr-presentation" "keep-pane $mode removed an unretired journal"
    assert_present "$case_dir/state/task-x1.meta" "keep-pane $mode removed its task identity"
    assert_absent "$case_dir/closed" "keep-pane $mode closed a pane"
    [ "$(backlog_row_state "$case_dir")" = in_flight ] || fail "keep-pane $mode closed backlog"
    if [ "$mode" = journal-remove-fails ]; then
      assert_present "$case_dir/treehouse.log" "keep-pane journal removal failure did not reach retirement"
    else
      assert_absent "$case_dir/treehouse.log" "keep-pane $mode returned copy before correlation"
    fi
  done
  pass "keep-pane refuses ambiguous, invalid, or unretirable journals without losing task identity"

  # Counterfactual: the identical finished task without the option closes.
  case_dir=$(make_case keep-pane-counterfactual)
  configure_keep_pane_case "$case_dir"
  run_keep_pane_case "$case_dir" > "$case_dir/out" 2> "$case_dir/err" \
    || fail "default cleanup failed: $(cat "$case_dir/err")"
  assert_present "$case_dir/closed" "counterfactual: default cleanup unexpectedly kept the pane"
  assert_absent "$case_dir/state/task-x1.meta" "default cleanup retained metadata"
  pass "counterfactual: pane survival fails without keep-pane; default cleanup still closes"

  for mode in dirty unlanded alive child missing unknown wrong-task wrong-incarnation collision foreign-claim detach-fails; do
    case_dir=$(make_case "keep-pane-$mode")
    configure_keep_pane_case "$case_dir"
    seed_backlog_in_flight "$case_dir"
    case "$mode" in
      dirty) printf 'unfinished\n' > "$case_dir/wt/dirty.txt" ;;
      unlanded) wt_commit_file "$case_dir" unlanded.txt work ;;
      wrong-task) sed -i.bak 's/^endpoint_task_id=.*/endpoint_task_id=another-task/' "$case_dir/state/task-x1.meta" ;;
      wrong-incarnation) printf 'spawn_gen=duplicate\n' >> "$case_dir/state/task-x1.meta" ;;
      collision) cp "$case_dir/state/task-x1.meta" "$case_dir/state/other-task.meta" ;;
      foreign-claim) printf 'task=another-task\nhome=%s\n' "$case_dir" > "$case_dir/pool/1/.fm-slot-owner" ;;
    esac
    before=$(cat "$case_dir/state/task-x1.meta")
    rc=0
    FM_KEEP_MODE="$mode" run_keep_pane_case "$case_dir" --keep-pane > "$case_dir/out" 2> "$case_dir/err" || rc=$?
    [ "$rc" -ne 0 ] || fail "keep-pane $mode unexpectedly succeeded"
    [ "$(cat "$case_dir/state/task-x1.meta")" = "$before" ] || fail "keep-pane $mode changed record"
    assert_absent "$case_dir/closed" "keep-pane $mode closed pane"
    assert_absent "$case_dir/treehouse.log" "keep-pane $mode returned copy"
    [ "$(backlog_row_state "$case_dir")" = in_flight ] || fail "keep-pane $mode closed backlog"
  done
  pass "keep-pane refuses dirty/unlanded work, running or ambiguous endpoints, incarnation drift and slot ownership conflicts before return"

  for mode in return-fails lost-after-return; do
    case_dir=$(make_case "keep-pane-$mode")
    configure_keep_pane_case "$case_dir"
    seed_backlog_in_flight "$case_dir"
    rc=0
    FM_KEEP_MODE="$mode" run_keep_pane_case "$case_dir" --keep-pane > "$case_dir/out" 2> "$case_dir/err" || rc=$?
    [ "$rc" -ne 0 ] || fail "keep-pane $mode unexpectedly succeeded"
    assert_present "$case_dir/state/task-x1.meta" "keep-pane $mode lost endpoint record"
    [ "$(backlog_row_state "$case_dir")" = in_flight ] || fail "keep-pane $mode closed backlog"
    if [ "$mode" = return-fails ]; then
      git -C "$case_dir/wt" show-ref --verify --quiet refs/heads/fm/task-x1 \
        || fail "failed return lost the task branch"
      assert_absent "$case_dir/state/task-x1.backlog-close" "keep-pane $mode left a replayable close"
    else
      assert_present "$case_dir/state/task-x1.backlog-close" "keep-pane $mode lost durable transition"
      (
        # shellcheck disable=SC2031 # Scope the fixture home to startup replay.
        export FM_HOME="$case_dir/home"
        # shellcheck source=bin/fm-tasks-axi-lib.sh
        . "$ROOT/bin/fm-tasks-axi-lib.sh"
        # shellcheck source=bin/fm-backlog-transition-lib.sh
        . "$ROOT/bin/fm-backlog-transition-lib.sh"
        fm_backlog_close_marker_replay "$case_dir/state" "$case_dir/state/task-x1.backlog-close" "$case_dir/data" \
          || fail "startup could not replay the close after the copy was returned: $FM_BACKLOG_TRANSITION_ERROR"
      ) || exit 1
      [ "$(backlog_row_state "$case_dir")" = 'done' ] || fail 'startup replay did not close the returned task'
      git -C "$case_dir/wt" checkout -qb fm/task-x1 \
        || fail 'startup replay left the returned task branch in the way of fresh dispatch'
    fi
  done
  pass "keep-pane retains records and keeps the pending close only after the copy is returned"

  case_dir=$(make_case keep-pane-captain-call)
  configure_keep_pane_case "$case_dir"
  seed_backlog_in_flight "$case_dir"
  FM_HOME="$case_dir" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-captain-hold.sh" hold task-x1 --reason 'Choose the follow-up' >/dev/null \
    || fail "could not seed captain call"
  run_keep_pane_case "$case_dir" --keep-pane > "$case_dir/out" 2> "$case_dir/err" \
    || fail "keep-pane captain call cleanup failed: $(cat "$case_dir/err")"
  show=$(tasks-axi show task-x1 --full --file "$case_dir/data/backlog.md")
  printf '%s\n' "$show" | grep -F 'hold_kind: captain' >/dev/null || fail "keep-pane dropped captain call"
  [ "$(backlog_row_state "$case_dir")" = queued ] || fail "keep-pane closed captain call"
  assert_absent "$case_dir/closed" "captain call cleanup closed pane"
  pass "keep-pane retires worker records while retaining the open captain call"

  for mode in tmux scout secondmate force legacy stale; do
    case_dir=$(make_case "keep-pane-unsupported-$mode")
    configure_keep_pane_case "$case_dir"
    case "$mode" in
      tmux) sed -i.bak 's/backend=herdr/backend=tmux/' "$case_dir/state/task-x1.meta" ;;
      scout|secondmate) sed -i.bak "s/kind=ship/kind=$mode/" "$case_dir/state/task-x1.meta" ;;
    esac
    rc=0
    case "$mode" in
      force) run_keep_pane_case "$case_dir" --keep-pane --force > "$case_dir/out" 2> "$case_dir/err" || rc=$? ;;
      legacy) run_keep_pane_case "$case_dir" --keep-pane --legacy-record > "$case_dir/out" 2> "$case_dir/err" || rc=$? ;;
      stale) run_keep_pane_case "$case_dir" --keep-pane --retire-stale-record > "$case_dir/out" 2> "$case_dir/err" || rc=$? ;;
      *) run_keep_pane_case "$case_dir" --keep-pane > "$case_dir/out" 2> "$case_dir/err" || rc=$? ;;
    esac
    [ "$rc" -ne 0 ] || fail "keep-pane accepted unsupported $mode"
    assert_present "$case_dir/state/task-x1.meta" "unsupported $mode lost record"
    assert_absent "$case_dir/herdr.log" "unsupported $mode contacted endpoint"
    assert_absent "$case_dir/treehouse.log" "unsupported $mode returned copy"
  done
  pass "keep-pane explicitly refuses unsupported kinds, backends and discard/legacy/stale combinations"
  kill "$KEEP_TEST_PID" 2>/dev/null || true
  wait "$KEEP_TEST_PID" 2>/dev/null || true
  trap fm_test_cleanup EXIT
}

# Token-free real lifecycle proof. Every Herdr call, including calls from the
# candidate teardown, routes through the named lab helper and fleet tripwire.
test_keep_pane_lab() (
  [ "${FM_TEARDOWN_KEEP_PANE_LAB:-0}" = 1 ] || return 0
  require_lsof_for_case 'keep-pane lab' || return 0
  local case_dir out ws tab pane shell_pid after rc=0 original_path=$PATH arg mode duplicate_ws landed_head
  case_dir=$(make_case keep-pane-real-lab)
  configure_keep_pane_case "$case_dir"
  rm -f "$case_dir/fakebin/lsof" "$case_dir/fakebin/keep-ps"
  HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
  HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name teardown-keep-pane-option-20261102) || fail "lab name refused"
  export HERDR_LAB_HELPER HERDR_LAB_SESSION
  trap 'env PATH="$original_path" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || exit 1' EXIT
  "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail "lab provisioning refused"
  lab_keep() { env PATH="$original_path" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
  out=$(lab_keep status --json) || fail "lab status unavailable"
  printf 'Herdr keep-pane lab version: %s\n' "$(printf '%s' "$out" | jq -r '.client.version // .server.version // "unknown"')"
  out=$(lab_keep workspace create --cwd "$case_dir/wt" --label '└ task-x1 · p:AbCdEfGhIjKlMnOpQrStUv' --no-focus) || fail "lab workspace create failed"
  ws=$(printf '%s' "$out" | jq -er '.result.workspace.workspace_id') || fail "missing lab workspace"
  tab=$(printf '%s' "$out" | jq -er '.result.tab.tab_id') || fail "missing lab tab"
  pane=$(printf '%s' "$out" | jq -er '.result.root_pane.pane_id') || fail "missing lab pane"
  lab_keep pane run "$pane" 'exec bash --noprofile --norc -i' >/dev/null || fail "lab shell launch failed"
  sleep 0.5
  shell_pid=$(lab_keep pane process-info --pane "$pane" | jq -er '.result.process_info.shell_pid') || fail "lab shell identity missing"
  cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
args=("$@")
last=$((${#args[@]} - 1)); flag=$((last - 1))
[ "$flag" -ge 0 ] && [ "${args[$flag]}" = --session ] && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ] || exit 9
unset 'args[last]' 'args[flag]'
for arg in "${args[@]}"; do case "$arg" in --session|--session=*) exit 9 ;; esac; done
exec env PATH="$FM_KEEP_LAB_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "${args[@]}"
SH
  chmod +x "$case_dir/fakebin/herdr"
  lab_seed_task() {
    fm_write_meta "$case_dir/state/task-x1.meta" \
      "window=$HERDR_LAB_SESSION:$pane" 'endpoint_task_id=task-x1' \
      "worktree=$case_dir/wt" "project=$case_dir/project" 'kind=ship' \
      'mode=local-only' 'harness=codex' 'backend=herdr' 'spawn_gen=keep-pane-lab' \
      "herdr_session=$HERDR_LAB_SESSION" "herdr_workspace_id=$ws" "herdr_tab_id=$tab" "herdr_pane_id=$pane" \
      "herdr_terminal_id=$(lab_keep pane get "$pane" | jq -er '.result.pane.terminal_id')"
    printf 'task=task-x1\nhome=%s\n' "$case_dir" > "$case_dir/pool/1/.fm-slot-owner"
    seed_backlog_in_flight "$case_dir"
  }
  lab_retire() {
    FM_KEEP_LAB_PATH="$original_path" FM_KEEP_CASE="$case_dir" run_teardown "$case_dir" "$@"
  }
  lab_seed_task

  for arg in --force --legacy-record --retire-stale-record; do
    rc=0
    lab_retire --keep-pane "$arg" > "$case_dir/out" 2> "$case_dir/err" || rc=$?
    [ "$rc" = 2 ] || fail "real cleanup accepted --keep-pane with $arg"
    assert_present "$case_dir/state/task-x1.meta" "option refusal retired task identity"
    [ "$(lab_keep pane process-info --pane "$pane" | jq -r '.result.process_info.shell_pid')" = "$shell_pid" ] \
      || fail "option refusal replaced the real pane shell"
  done
  pass "real cleanup CLI refuses incompatible keep-pane options without touching its pane"

  landed_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  wt_commit_file "$case_dir" unlanded.txt work
  rc=0
  lab_retire --keep-pane > "$case_dir/out" 2> "$case_dir/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "real keep-pane accepted unlanded work"
  assert_present "$case_dir/state/task-x1.meta" "unlanded refusal retired task identity"
  git -C "$case_dir/wt" reset --hard "$landed_head" >/dev/null
  sed -i.bak 's/^endpoint_task_id=.*/endpoint_task_id=another-task/' "$case_dir/state/task-x1.meta"
  rc=0
  lab_retire --keep-pane > "$case_dir/out" 2> "$case_dir/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "real keep-pane accepted an unverified endpoint"
  assert_present "$case_dir/state/task-x1.meta" "unverified endpoint refusal retired task identity"
  sed -i.bak 's/^endpoint_task_id=.*/endpoint_task_id=task-x1/' "$case_dir/state/task-x1.meta"
  [ "$(lab_keep pane process-info --pane "$pane" | jq -r '.result.process_info.shell_pid')" = "$shell_pid" ] \
    || fail "safety refusals replaced the real pane shell"
  pass "real Herdr pane survives unlanded-work and unverified-endpoint refusals"

  for mode in journal-unreadable journal-mismatch journal-ambiguous journal-remove-fails; do
    printf 'version=1\ntask_id=task-x1\nprojection_id=AbCdEfGhIjKlMnOpQrStUv\n' > "$case_dir/state/task-x1.herdr-presentation"
    case "$mode" in
      journal-unreadable)
        printf 'projection_id=AbCdEfGhIjKlMnOpQrStUv\n' >> "$case_dir/state/task-x1.herdr-presentation" ;;
      journal-mismatch)
        printf 'version=1\ntask_id=task-x1\nprojection_id=AbCdEfGhIjKlMnOpQrStUx\n' > "$case_dir/state/task-x1.herdr-presentation" ;;
      journal-ambiguous)
        out=$(lab_keep workspace create --cwd "$case_dir/project" --label 'copy · p:AbCdEfGhIjKlMnOpQrStUv' --no-focus) \
          || fail "could not create ambiguous lab workspace"
        duplicate_ws=$(printf '%s' "$out" | jq -er '.result.workspace.workspace_id') \
          || fail "missing ambiguous lab workspace id" ;;
    esac
    rc=0
    FM_KEEP_MODE="$mode" lab_retire --keep-pane > "$case_dir/out" 2> "$case_dir/err" || rc=$?
    [ "$rc" -ne 0 ] || fail "real keep-pane accepted $mode"
    assert_present "$case_dir/state/task-x1.herdr-presentation" "$mode removed an unretired journal"
    assert_present "$case_dir/state/task-x1.meta" "$mode retired task identity"
    [ "$(lab_keep pane process-info --pane "$pane" | jq -r '.result.process_info.shell_pid')" = "$shell_pid" ] \
      || fail "$mode replaced the real pane shell"
    if [ "$mode" = journal-ambiguous ]; then
      lab_keep workspace rename "$duplicate_ws" unrelated >/dev/null || fail "could not clear lab ambiguity"
    fi
    rm -f "$case_dir/state/task-x1.herdr-presentation"
  done
  rm -f "$case_dir/state/task-x1.backlog-close"
  pass "real Herdr journal failures retain task identity and the exact pane"

  rc=0
  lab_retire --keep-pane > "$case_dir/out" 2> "$case_dir/err" || rc=$?
  [ "$rc" = 0 ] || fail "real keep-pane retirement failed: $(cat "$case_dir/err")"
  after=$(lab_keep pane process-info --pane "$pane" | jq -er '.result.process_info.shell_pid') || fail "real pane disappeared"
  [ "$after" = "$shell_pid" ] || fail "real pane shell was replaced"
  lsof -a -p "$shell_pid" -d cwd -Fn | grep -Fx 'n/' >/dev/null || fail "real surviving shell still in returned copy"
  assert_absent "$case_dir/state/task-x1.meta" "real keep-pane metadata survived"
  assert_absent "$case_dir/pool/1/.fm-slot-owner" "real keep-pane slot claim survived"
  [ "$(backlog_row_state "$case_dir")" = "done" ] || fail "real keep-pane backlog remained open"
  pass "real Herdr lab: keep-pane retires records and slot while the identical pane and detached shell survive"
  lab_seed_task
  sed -i.bak 's/^herdr_workspace_id=.*/herdr_workspace_id=stale-workspace/' "$case_dir/state/task-x1.meta"
  printf 'version=1\ntask_id=task-x1\nprojection_id=AbCdEfGhIjKlMnOpQrStUv\n' > "$case_dir/state/task-x1.herdr-presentation"
  lab_retire --keep-pane > "$case_dir/out" 2> "$case_dir/err" \
    || fail "real stale-workspace retirement failed: $(cat "$case_dir/err")"
  assert_absent "$case_dir/state/task-x1.herdr-presentation" "real stale-workspace journal survived"
  assert_absent "$case_dir/state/task-x1.meta" "real stale-workspace task identity survived"
  [ "$(lab_keep pane process-info --pane "$pane" | jq -r '.result.process_info.shell_pid')" = "$shell_pid" ] \
    || fail "real stale-workspace retirement replaced the pane shell"
  pass "real Herdr stale-workspace journal retires without closing the pane"
  # Reset only the disposable fixture branch/record for the default-path
  # counterfactual; the real endpoint is still exactly the retained lab pane.
  lab_seed_task
  lab_retire > "$case_dir/default.out" 2> "$case_dir/default.err" \
    || fail "real default cleanup failed: $(cat "$case_dir/default.err")"
  out=$(lab_keep pane get "$pane" 2>&1) || true
  [ "$(printf '%s' "$out" | jq -r '.error.code')" = pane_not_found ] || fail "real counterfactual did not close pane"
  pass "real Herdr lab counterfactual: default retirement closes the previously preserved exact pane"
)

test_non_linux_skips_process_group_reap caller worktree || exit 1
test_non_linux_skips_process_group_reap caller tasktmp || exit 1
test_non_linux_skips_process_group_reap headless worktree || exit 1
test_non_linux_skips_process_group_reap leak worktree || exit 1
test_non_linux_skips_process_group_reap leak tasktmp || exit 1
test_leaked_worktree_process_is_reaped
test_lsof_absent_reaps_detached_linux_process visible || exit 1
test_lsof_absent_reaps_detached_linux_process hidden || exit 1
test_proc_cwd_read_failure_preserves_copy || exit 1
test_hidden_intermediate_parent_refuses_reap proc || exit 1
test_hidden_intermediate_parent_refuses_reap lsof || exit 1
test_non_treehouse_reap_with_unverified_session orca || exit 1
test_non_treehouse_reap_with_unverified_session tasktmp || exit 1
test_reparented_teardown_preserves_original_caller inside || exit 1
test_reparented_teardown_preserves_original_caller inside-backlog || exit 1
test_reparented_teardown_preserves_original_caller inside-backlog matching || exit 1
test_reparented_teardown_preserves_original_caller inside-backlog relocated || exit 1
test_reparented_teardown_preserves_original_caller outside || exit 1
test_reparented_teardown_preserves_original_caller retry || exit 1
test_reparented_teardown_preserves_original_caller stale || exit 1
test_reparented_teardown_preserves_original_caller stale matching || exit 1
test_reparented_teardown_preserves_original_caller stale relocated || exit 1
test_reparented_teardown_preserves_original_caller stale unrelated || exit 1
test_reparented_teardown_preserves_original_caller stale-edit || exit 1
test_reparented_teardown_preserves_original_caller hidden || exit 1
test_reparented_teardown_preserves_original_caller before-start || exit 1
test_reparented_teardown_preserves_original_caller child || exit 1
test_reparented_teardown_preserves_original_caller child-error || exit 1
test_keep_pane_without_lsof || exit 1
test_keep_pane_retirement
test_keep_pane_lab || fail "real Herdr keep-pane lab failed"

test_local_only_fork_remote_allows
test_teardown_closes_the_backlog_item_itself
test_teardown_manual_backend_leaves_the_backlog_to_the_operator
test_endpoint_loss_marker_survives_failed_task_retirement
test_parked_retained_mark_does_not_relax_cleanup
test_local_only_truly_unpushed_refuses
test_local_only_merged_to_local_main_allows
test_no_mistakes_origin_remote_allows
test_no_mistakes_truly_unpushed_refuses
test_local_only_force_overrides_unpushed
test_secondmate_pr_registration_publishes_ready_line
test_secondmate_home_teardown_delivers_final_line_or_refuses
test_teardown_missing_busy_sidecar_completes
test_herdr_teardown_clears_escalation_marker
test_herdr_flat_teardown_refuses_orphaning_records_then_retry_completes
test_herdr_flat_teardown_refuses_records_on_unparseable_presence
test_herdr_flat_teardown_preflight_refuses_before_changes
test_forced_secondmate_herdr_child_preflight_refuses_before_changes
test_forced_secondmate_teardown_holds_descendant_lifecycle_locks
test_return_retires_slot_after_hook_error direct unlink
test_return_retires_slot_after_hook_error child unlink
test_return_retires_slot_after_hook_error direct index
test_return_retires_slot_after_hook_error child index
test_forced_secondmate_teardown_preflights_all_child_copies linked
test_forced_secondmate_teardown_preflights_all_child_copies pool
test_child_removal_failure_preserves_copy lock
test_child_removal_failure_preserves_copy remove
test_child_removal_failure_preserves_copy direct
test_child_removal_failure_preserves_copy nested
test_forced_secondmate_herdr_child_retains_records_when_close_unconfirmed
test_forced_teardown_retains_nested_secondmate_home_when_grandchild_close_unconfirmed
test_herdr_projection_teardown_retires_journal_only_after_confirmed_close
test_herdr_projection_teardown_retains_journal_when_close_unconfirmed
test_herdr_projection_teardown_surfaces_restore_failure_without_blocking_cleanup
test_squash_merged_branch_deleted_allows
test_squash_merged_pr_allows_when_head_ancestor_of_pr_head
test_no_pr_recorded_discovers_merged_pr_by_branch_allows
test_squash_merged_pr_allows_replayed_unpushed_patch
test_merged_pr_with_later_local_commit_refuses
test_squash_merged_rebased_branch_allows
test_squash_merged_same_file_different_content_refuses
test_squash_merged_rebased_local_with_unlanded_commit_refuses
test_squash_merged_stale_local_refuses_when_forge_unreachable
test_pr_check_does_not_refresh_stale_pr_head
test_pr_check_records_remote_head_when_local_lags
test_content_in_default_fallback_allows
test_content_fallback_refreshes_stale_origin_ref
test_dirty_worktree_refuses
test_gh_error_and_content_absent_refuses
test_legacy_record_without_the_flag_refuses
test_legacy_record_teardown_completes_when_landed_and_endpoint_dead
test_legacy_record_teardown_refuses_unlanded_work
test_legacy_record_teardown_refuses_an_ambiguous_endpoint
test_legacy_record_rolls_the_stamp_back_when_the_marker_write_fails
test_retained_legacy_stamp_still_faces_the_endpoint_gate
test_legacy_record_never_accepts_a_corrupt_spawn_gen
test_stale_index_lock_cleared_and_teardown_succeeds
test_live_index_lock_is_never_removed_and_teardown_refuses
test_lsof_error_never_clears_index_lock
test_worktree_safety_refusal_cancels_close initial
test_worktree_safety_refusal_cancels_close stale
test_non_linked_index_lock_path_is_checked_from_worktree
test_index_lock_mtime_read_failure_refuses
test_transient_index_lock_clears_after_first_attempt_and_retry_succeeds
test_persistent_index_lock_exhausts_retries_and_refuses_loudly
test_treehouse_owns_checkout_and_cancels_failed_close files
test_treehouse_owns_checkout_and_cancels_failed_close detached
test_treehouse_owns_checkout_and_cancels_failed_close reftable
test_treehouse_owns_checkout_and_cancels_failed_close success
test_empty_retry_wait_uses_default_without_aborting
test_fractional_legacy_retry_wait_refuses_without_arithmetic_error
test_parked_own_run_is_aborted_before_teardown
test_parked_run_advanced_past_unfetched_head_is_still_aborted
test_parked_run_with_mismatched_ledger_head_is_never_aborted
test_parked_run_with_malformed_ledger_row_is_never_aborted
test_parked_run_with_impossible_ledger_date_is_never_aborted
test_terminal_status_with_gate_never_queries_or_aborts_ledger_fallback
test_parked_run_advanced_head_locally_fetched_is_still_aborted
test_parked_advanced_run_without_anchor_is_never_aborted
test_parked_advanced_run_ancestor_anchor_is_never_aborted
test_parked_terminal_unfetched_row_is_never_aborted
test_parked_run_terminal_newest_row_at_own_head_is_never_aborted
test_parked_run_behind_diverged_newer_row_is_never_aborted
test_parked_advanced_run_ambiguous_rows_are_never_aborted
test_ledger_proven_continuation_never_aborts_active_run
test_parked_own_run_refuses_when_abort_is_unconfirmed
test_mismatched_run_after_abort_refuses_unconfirmed
test_empty_status_after_abort_refuses_unconfirmed
test_not_found_status_after_abort_confirms_completion
test_another_branchs_parked_run_is_never_touched
test_own_autonomous_run_is_left_alone
test_leaked_tasktmp_process_is_reaped
test_lsof_absent_on_non_linux_preserves_tmux_process_group
test_lsof_error_refuses_before_removal
test_reused_pid_identity_is_not_force_killed || exit 1
test_exec_changed_process_is_still_reaped
test_process_spawned_during_grace_is_reaped_on_later_pass
test_persistent_scan_refuses_after_bounded_retries
test_process_exit_during_identity_lookup_does_not_refuse
test_run_abort_precedes_process_reap_precedes_worktree_removal
