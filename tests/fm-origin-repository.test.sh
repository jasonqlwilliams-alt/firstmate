#!/usr/bin/env bash
# Regression tests for origin-based repository resolution and explicit --repo call sites.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-repository-policy-lib.sh
. "$ROOT/bin/fm-repository-policy-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-origin-repository)
TEARDOWN="$ROOT/bin/fm-teardown.sh"
export GIT_TERMINAL_PROMPT=0

make_repo_case() {
  local name=$1 origin_url=$2 insteadof_path=${3:-}
  local case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir"
  git init -q "$case_dir/repo"
  git -C "$case_dir/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "init"
  if [ -n "$origin_url" ]; then
    git -C "$case_dir/repo" remote add origin "$origin_url"
  fi
  if [ -n "$insteadof_path" ]; then
    git -C "$case_dir/repo" config "url.$insteadof_path.insteadOf" "$origin_url"
  fi
  printf '%s\n' "$case_dir"
}

test_origin_repository_https() {
  local case_dir repo cli_repo
  case_dir=$(make_repo_case https "https://github.com/my-org/my-project.git")

  repo=$(fm_origin_repository "$case_dir/repo")
  [ "$repo" = "my-org/my-project" ] || fail "https: expected my-org/my-project, got '$repo'"

  cli_repo=$("$ROOT/bin/fm-repository-policy-lib.sh" "$case_dir/repo")
  [ "$cli_repo" = "my-org/my-project" ] || fail "https cli: expected my-org/my-project, got '$cli_repo'"

  pass "fm_origin_repository resolves owner/repo from HTTPS origin remote URL"
}

test_origin_repository_ssh() {
  local case_dir repo cli_repo
  case_dir=$(make_repo_case ssh "git@github.com:another-org/another-repo.git")

  repo=$(fm_origin_repository "$case_dir/repo")
  [ "$repo" = "another-org/another-repo" ] || fail "ssh: expected another-org/another-repo, got '$repo'"

  cli_repo=$("$ROOT/bin/fm-repository-policy-lib.sh" "$case_dir/repo")
  [ "$cli_repo" = "another-org/another-repo" ] || fail "ssh cli: expected another-org/another-repo, got '$cli_repo'"

  pass "fm_origin_repository resolves owner/repo from SSH origin remote URL"
}

test_origin_repository_insteadof_rewriting() {
  local case_dir repo
  case_dir="$TMP_ROOT/insteadof"
  mkdir -p "$case_dir"
  git init -q --bare "$case_dir/local.git"
  git init -q "$case_dir/repo"
  git -C "$case_dir/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "init"
  git -C "$case_dir/repo" remote add origin "https://github.com/rewritten-org/rewritten-repo.git"
  git -C "$case_dir/repo" config "url.$case_dir/local.git.insteadOf" "https://github.com/rewritten-org/rewritten-repo.git"

  repo=$(fm_origin_repository "$case_dir/repo")
  [ "$repo" = "rewritten-org/rewritten-repo" ] || fail "insteadof: expected rewritten-org/rewritten-repo, got '$repo'"

  pass "fm_origin_repository resolves owner/repo when insteadOf rewrites remote get-url"
}

test_origin_repository_missing_origin() {
  local case_dir rc err
  case_dir=$(make_repo_case missing "")

  set +e
  err=$("$ROOT/bin/fm-repository-policy-lib.sh" "$case_dir/repo" 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-origin: should exit non-zero"
  case "$err" in
    *"error: repository "*"$case_dir/repo has no configured origin remote"*) ;;
    *) fail "missing-origin: unexpected error output: '$err'" ;;
  esac

  pass "fm_origin_repository fails loudly with clear error when origin remote is missing"
}

test_origin_repository_unparseable_origin() {
  local case_dir rc err
  case_dir=$(make_repo_case unparseable "https://gitlab.com/not-github/project.git")

  set +e
  err=$("$ROOT/bin/fm-repository-policy-lib.sh" "$case_dir/repo" 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "unparseable-origin: should exit non-zero"
  case "$err" in
    *"error: cannot resolve GitHub repository from origin URL: https://gitlab.com/not-github/project.git"*) ;;
    *) fail "unparseable-origin: unexpected error output: '$err'" ;;
  esac

  pass "fm_origin_repository fails loudly with clear error when origin is not a GitHub repository"
}

run_teardown() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@"
}

seed_backlog() {
  local case_dir=$1
  mkdir -p "$case_dir/data" "$case_dir/config"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$case_dir/data/backlog.md"
  tasks-axi add task-x1 "teardown fixture task" --kind ship \
    --file "$case_dir/data/backlog.md" >/dev/null
  tasks-axi start task-x1 --file "$case_dir/data/backlog.md" >/dev/null
}

test_teardown_pr_number_from_branch_passes_explicit_repo() {
  local case_dir rc head
  case_dir="$TMP_ROOT/td-pr-number"
  mkdir -p "$case_dir/fakebin" "$case_dir/state" "$case_dir/data/task-x1" "$case_dir/config"
  seed_backlog "$case_dir"

  git init -q --bare "$case_dir/origin.git"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "init"
  git -C "$case_dir/project" branch -M main
  git -C "$case_dir/project" push -q origin main
  git -C "$case_dir/project" config remote.origin.url "https://github.com/upstream-fork-test/project-fork.git"
  git -C "$case_dir/project" config "url.$case_dir/origin.git.insteadOf" "https://github.com/upstream-fork-test/project-fork.git"
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "task commit"

  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  cat > "$case_dir/fakebin/gh-axi" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/gh-axi.log"
case "\${1:-} \${2:-}" in
  "pr list")
    printf '%s\n' "count: 1 (showing first 1)" "pull_requests[1]{number,state}:" "  42,merged"
    exit 0
    ;;
esac
exit 1
EOF

  cat > "$case_dir/fakebin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/gh.log"
case "\${1:-} \${2:-}" in
  "pr view")
    printf '%s\t%s\t%s\n' 'MERGED' '$head' 'https://github.com/upstream-fork-test/project-fork/pull/42'
    exit 0
    ;;
esac
exit 1
EOF

  cat > "$case_dir/fakebin/treehouse" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat > "$case_dir/fakebin/tmux" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat > "$case_dir/fakebin/no-mistakes" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  chmod +x "$case_dir/fakebin/"*
  touch "$case_dir/state/.last-watcher-beat"

  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "spawn_gen=teardown-test-task-x1"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "teardown failed ($rc): $(cat "$case_dir/stderr")"
  [ -f "$case_dir/gh-axi.log" ] || fail "gh-axi was never invoked"
  grep -q -- "--repo upstream-fork-test/project-fork" "$case_dir/gh-axi.log" \
    || fail "gh-axi pr list was not called with --repo upstream-fork-test/project-fork: $(cat "$case_dir/gh-axi.log")"

  pass "teardown pr_number_from_branch passes explicit --repo derived from origin"
}

test_teardown_pr_is_merged_passes_explicit_repo() {
  local case_dir rc head
  case_dir="$TMP_ROOT/td-pr-merged"
  mkdir -p "$case_dir/fakebin" "$case_dir/state" "$case_dir/data/task-x1" "$case_dir/config"
  seed_backlog "$case_dir"

  git init -q --bare "$case_dir/origin.git"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "init"
  git -C "$case_dir/project" branch -M main
  git -C "$case_dir/project" push -q origin main
  git -C "$case_dir/project" config remote.origin.url "https://github.com/upstream-fork-test/project-fork.git"
  git -C "$case_dir/project" config "url.$case_dir/origin.git.insteadOf" "https://github.com/upstream-fork-test/project-fork.git"
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "task commit"

  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  cat > "$case_dir/fakebin/gh-axi" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/gh-axi.log"
exit 1
EOF

  cat > "$case_dir/fakebin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/gh.log"
case "\${1:-} \${2:-}" in
  "pr view")
    printf '%s\t%s\t%s\n' 'MERGED' '$head' 'https://github.com/upstream-fork-test/project-fork/pull/42'
    exit 0
    ;;
esac
exit 1
EOF

  cat > "$case_dir/fakebin/treehouse" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat > "$case_dir/fakebin/tmux" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat > "$case_dir/fakebin/no-mistakes" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  chmod +x "$case_dir/fakebin/"*
  touch "$case_dir/state/.last-watcher-beat"

  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "pr=https://github.com/upstream-fork-test/project-fork/pull/42" \
    "kind=ship" \
    "mode=no-mistakes" \
    "spawn_gen=teardown-test-task-x1"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "teardown failed ($rc): $(cat "$case_dir/stderr")"
  [ -f "$case_dir/gh.log" ] || fail "gh was never invoked"
  grep -q -- "--repo upstream-fork-test/project-fork" "$case_dir/gh.log" \
    || fail "gh pr view was not called with --repo upstream-fork-test/project-fork: $(cat "$case_dir/gh.log")"

  pass "teardown pr_is_merged passes explicit --repo derived from origin"
}

test_teardown_refuses_when_origin_unparseable() {
  local case_dir rc
  case_dir="$TMP_ROOT/td-unparseable"
  mkdir -p "$case_dir/fakebin" "$case_dir/state" "$case_dir/data/task-x1" "$case_dir/config"
  seed_backlog "$case_dir"

  git init -q --bare "$case_dir/origin.git"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "init"
  git -C "$case_dir/project" branch -M main
  git -C "$case_dir/project" push -q origin main
  # Set an unparseable origin URL
  git -C "$case_dir/project" remote set-url origin "https://gitlab.com/not-github/project.git"
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main
  # Add unpushed commit in wt so content is not in default branch
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "unpushed work"

  cat > "$case_dir/fakebin/gh-axi" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat > "$case_dir/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat > "$case_dir/fakebin/treehouse" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat > "$case_dir/fakebin/tmux" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat > "$case_dir/fakebin/no-mistakes" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  chmod +x "$case_dir/fakebin/"*
  touch "$case_dir/state/.last-watcher-beat"

  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "spawn_gen=teardown-test-task-x1"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "teardown should refuse unlanded work with unparseable origin"
  assert_grep "cannot resolve GitHub repository from origin URL" "$case_dir/stderr" \
    "teardown should report unparseable origin error"

  pass "teardown fails safely with clear error when origin repository is unparseable"
}

test_origin_repository_https
test_origin_repository_ssh
test_origin_repository_insteadof_rewriting
test_origin_repository_missing_origin
test_origin_repository_unparseable_origin
test_teardown_pr_number_from_branch_passes_explicit_repo
test_teardown_pr_is_merged_passes_explicit_repo
test_teardown_refuses_when_origin_unparseable
