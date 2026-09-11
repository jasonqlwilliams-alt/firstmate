#!/usr/bin/env bash
# Hermetic regression matrix for fork-safe upstream synchronization.
# Every "GitHub" fetch/push terminates in a temporary bare repository through a
# fake SSH transport; gh-axi identity and release responses are local fakes.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SYNC="$ROOT/bin/fm-upstream-sync.sh"
TMP_ROOT=$(fm_test_tmproot fm-upstream-sync)

make_fake_tools() {  # <fixture-root>
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
[ "${GH_HOST:-}" = github.com ] || exit 3
case " $* " in *" --hostname "*) exit 4 ;; esac
case " $* " in
  *" /user "*)
    printf 'api_response:\n  body: %s\n  truncated: false\n' "${FAKE_GH_ACCOUNT:-captain}"
    ;;
  *" /repos/upstream/widgets/releases?per_page=100 "*)
    json=$(printf '%s\n' "${FAKE_RELEASE_TAGS:-}" | jq -Rsc '
      split("\n") | map(select(length > 0)) | map({tag_name: .})')
    encoded=$(printf '%s' "$json" | base64 | tr -d '\n')
    printf 'api_response:\n  body: %s\n  truncated: false\n' "$encoded"
    ;;
  *) exit 2 ;;
esac
SH
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TRANSPORT_LOG:?}"
case "$*" in
  *"git-upload-pack 'upstream/widgets.git'"*) exec git-upload-pack "${FIXTURE_ROOT:?}/upstream.git" ;;
  *"git-upload-pack 'captain/widgets.git'"*)
    [ "${FAKE_FORK_MISSING:-0}" != 1 ] || exit 128
    exec git-upload-pack "${FIXTURE_ROOT:?}/fork.git"
    ;;
  *"git-receive-pack 'captain/widgets.git'"*)
    [ "${FAKE_FORK_MISSING:-0}" != 1 ] || exit 128
    exec git-receive-pack "${FIXTURE_ROOT:?}/fork.git"
    ;;
  *"git-receive-pack 'upstream/widgets.git'"*) exec git-receive-pack "${FIXTURE_ROOT:?}/upstream.git" ;;
esac
exit 2
SH
  chmod +x "$fakebin/gh-axi" "$fakebin/ssh"
}

write_policy() {  # <home> [extra upstreamSync JSON member]
  local home=$1 extra=${2:-}
  mkdir -p "$home/config" "$home/state"
  cat > "$home/config/repository-policy.json" <<JSON
{
  "version": 1,
  "approvedOwners": ["captain"],
  "approvedAccounts": ["captain"],
  "repositories": {
    "widgets": {
      "upstreamFetchUrl": "git@github.com:upstream/widgets.git",
      "forkPushUrl": "git@github.com:captain/widgets.git",
      "defaultBranch": "main",
      "upstreamSync": {
        "validationCommand": ["sh", "validate.sh"]${extra:+,
        $extra}
      }
    }
  }
}
JSON
}

make_fixture() {  # <name> [extra policy member]; echoes fixture path
  local name=$1 extra=${2:-} dir="$TMP_ROOT/$1" seed
  dir="$TMP_ROOT/$name"
  seed="$dir/seed"
  mkdir -p "$dir"
  fm_git_init_commit "$seed"
  git -C "$seed" branch -M main
  printf 'base\n' > "$seed/shared.txt"
  cat > "$seed/validate.sh" <<'SH'
#!/usr/bin/env sh
[ "${VALIDATION_FAIL:-0}" != 1 ]
SH
  git -C "$seed" add shared.txt validate.sh
  git -C "$seed" -c user.name=fmtest -c user.email=fmtest@example.invalid \
    commit -qm 'fixture validation'
  git clone -q --bare "$seed" "$dir/upstream.git"
  git clone -q --bare "$seed" "$dir/fork.git"
  git --git-dir="$dir/upstream.git" symbolic-ref HEAD refs/heads/main
  git --git-dir="$dir/fork.git" symbolic-ref HEAD refs/heads/main
  : > "$dir/transport.log"
  make_fake_tools "$dir"
  write_policy "$dir/home" "$extra"
  printf '%s\n' "$dir"
}

upstream_commit() {  # <fixture> <path> <content> [tag]
  local dir=$1 path=$2 content=$3 tag=${4:-} seed="$1/seed"
  mkdir -p "$(dirname "$seed/$path")"
  printf '%s\n' "$content" > "$seed/$path"
  git -C "$seed" add "$path"
  git -C "$seed" -c user.name=fmtest -c user.email=fmtest@example.invalid \
    commit -qm "upstream $path $content"
  [ -z "$tag" ] || git -C "$seed" tag "$tag"
  git -C "$seed" push -q "$dir/upstream.git" main
  [ -z "$tag" ] || git -C "$seed" push -q "$dir/upstream.git" "$tag"
}

fork_commit() {  # <fixture> <path> <content>
  local dir=$1 path=$2 content=$3 work="$1/fork-work"
  git clone -q "$dir/fork.git" "$work"
  mkdir -p "$(dirname "$work/$path")"
  printf '%s\n' "$content" > "$work/$path"
  git -C "$work" add "$path"
  git -C "$work" -c user.name=fmtest -c user.email=fmtest@example.invalid \
    commit -qm "fork $path $content"
  git -C "$work" push -q origin main
}

run_sync() {  # <fixture> [extra env assignments expressed by caller]
  local dir=$1
  shift
  env FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FIXTURE_ROOT="$dir" TRANSPORT_LOG="$dir/transport.log" \
    GIT_SSH_COMMAND="$dir/fakebin/ssh" PATH="$dir/fakebin:$PATH" \
    "$@" "$SYNC" check widgets
}

run_scheduled() {  # <fixture> [extra env assignments expressed by caller]
  local dir=$1
  shift
  env FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FIXTURE_ROOT="$dir" TRANSPORT_LOG="$dir/transport.log" \
    GIT_SSH_COMMAND="$dir/fakebin/ssh" PATH="$dir/fakebin:$PATH" \
    "$@" "$SYNC" scheduled widgets
}

fork_oid() { git --git-dir="$1/fork.git" rev-parse refs/heads/main; }
upstream_oid() { git --git-dir="$1/upstream.git" rev-parse refs/heads/main; }
review_ref() { git --git-dir="$1/fork.git" for-each-ref --format='%(refname)' refs/heads/fm/upstream-sync-* | head -1; }
receive_count() { grep -c "git-receive-pack 'captain/widgets.git'" "$1/transport.log" 2>/dev/null || true; }

test_original_author_fetch_and_captain_fork_push() {
  local dir out rc baseline
  dir=$(make_fixture explicit-pair)
  upstream_commit "$dir" upstream.txt newer
  out=$(run_sync "$dir" 2>&1); rc=$?
  expect_code 0 "$rc" "explicit upstream/fork synchronization should succeed"
  assert_grep "git-upload-pack 'upstream/widgets.git'" "$dir/transport.log" \
    "workflow did not fetch the explicit original-author URL"
  assert_grep "git-receive-pack 'captain/widgets.git'" "$dir/transport.log" \
    "workflow did not push the explicit captain fork URL"
  if grep -Fq "git-receive-pack 'upstream/widgets.git'" "$dir/transport.log"; then
    fail "workflow wrote to the original-author repository"
  fi
  [ "$(fork_oid "$dir")" = "$(upstream_oid "$dir")" ] \
    || fail "captain fork did not reach the upstream commit"

  git clone -q "$dir/upstream.git" "$dir/task-worktree"
  git -C "$dir/task-worktree" checkout -q --detach HEAD^
  baseline=$(env FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FIXTURE_ROOT="$dir" TRANSPORT_LOG="$dir/transport.log" \
    GIT_SSH_COMMAND="$dir/fakebin/ssh" PATH="$dir/fakebin:$PATH" \
    "$SYNC" baseline widgets "$dir/task-worktree")
  assert_contains "$baseline" "UPSTREAM BASELINE: project=widgets repository=github.com/captain/widgets" \
    "baseline selection did not name the captain fork"
  [ "$(git -C "$dir/task-worktree" rev-parse HEAD)" = "$(fork_oid "$dir")" ] \
    || fail "normal-work baseline did not use the newest accepted fork commit"
  pass "upstream sync: original-author fetch and captain-fork push are explicit"
}

test_effective_fetch_url_rewrite_refuses() {
  local dir out rc
  dir=$(make_fixture fetch-rewrite)
  out=$(run_sync "$dir" GIT_CONFIG_COUNT=1 \
    'GIT_CONFIG_KEY_0=url.git@github.com:captain/.insteadOf' \
    'GIT_CONFIG_VALUE_0=git@github.com:upstream/' 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an upstream insteadOf redirect should be refused"
  assert_contains "$out" \
    "upstream-fetch would read from github.com/captain/widgets, but project widgets explicitly configures github.com/upstream/widgets" \
    "fetch rewrite refusal did not name the effective and configured repositories"
  [ ! -s "$dir/transport.log" ] || fail "refused fetch rewrite still contacted a repository"
  pass "upstream sync: Git URL rewriting cannot silently redirect an explicit fetch"
}

test_upstream_release_fast_forwards_cleanly() {
  local dir out rc
  dir=$(make_fixture release-fast-forward)
  run_sync "$dir" FAKE_RELEASE_TAGS=v1 >/dev/null 2>&1
  upstream_commit "$dir" release.txt v2 v2
  out=$(run_sync "$dir" FAKE_RELEASE_TAGS=$'v1\nv2' 2>&1); rc=$?
  expect_code 0 "$rc" "clean release synchronization should succeed"
  assert_contains "$out" "new upstream tag v2" "new upstream tag was not detected"
  assert_contains "$out" "new upstream release v2" "new upstream release was not detected"
  assert_contains "$out" "fast-forwarded captain fork" "clean validated release did not fast-forward"
  [ "$(fork_oid "$dir")" = "$(upstream_oid "$dir")" ] || fail "release fast-forward missed the fork"
  pass "upstream sync: a new validated release fast-forwards the fork"
}

test_fork_unique_commits_create_review_branch() {
  local dir out before branch packet
  dir=$(make_fixture fork-unique)
  fork_commit "$dir" captain.txt captain-only
  before=$(fork_oid "$dir")
  upstream_commit "$dir" upstream.txt upstream-only
  out=$(run_sync "$dir" 2>&1) || fail "fork-unique review staging failed: $out"
  assert_contains "$out" "REVIEW_REQUIRED" "fork-unique candidate did not require review"
  [ "$(fork_oid "$dir")" = "$before" ] || fail "fork-unique review changed the fork default"
  branch=$(review_ref "$dir")
  [ -n "$branch" ] || fail "fork-unique candidate did not create an isolated branch"
  packet=$(find "$dir/home/state/upstream-sync/reviews" -type f -name 'widgets-*.md' | head -1)
  assert_grep 'fork default has 1 unique commit' "$packet" "review packet missed fork-only history"
  pass "upstream sync: fork-only commits preserve default and create an isolated review branch"
}

test_upstream_merge_conflict_is_reported() {
  local dir out packet before
  dir=$(make_fixture merge-conflict)
  fork_commit "$dir" shared.txt captain-change
  before=$(fork_oid "$dir")
  upstream_commit "$dir" shared.txt upstream-change
  out=$(run_sync "$dir" 2>&1) || fail "conflict review staging failed: $out"
  assert_contains "$out" "REVIEW_REQUIRED" "merge conflict did not require review"
  packet=$(find "$dir/home/state/upstream-sync/reviews" -type f -name 'widgets-*.md' | head -1)
  assert_grep 'Merge assessment: conflict' "$packet" "packet did not identify the merge conflict"
  [ "$(fork_oid "$dir")" = "$before" ] || fail "merge conflict changed the fork default"
  pass "upstream sync: an upstream merge conflict is preserved for review"
}

test_missing_captain_fork_refuses() {
  local dir out rc
  dir=$(make_fixture missing-fork)
  upstream_commit "$dir" upstream.txt newer
  out=$(run_sync "$dir" FAKE_FORK_MISSING=1 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "missing captain fork should refuse synchronization"
  assert_contains "$out" "fork github.com/captain/widgets is missing" \
    "missing-fork refusal did not name the destination"
  [ "$(receive_count "$dir")" -eq 0 ] || fail "missing fork path attempted a push"
  pass "upstream sync: a missing captain fork fails closed"
}

test_authenticated_account_mismatch_refuses_push() {
  local dir out rc before
  dir=$(make_fixture account-mismatch)
  before=$(fork_oid "$dir")
  upstream_commit "$dir" upstream.txt newer
  out=$(run_sync "$dir" FAKE_GH_ACCOUNT=intruder 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "unapproved account should refuse synchronization push"
  assert_contains "$out" "authenticated GitHub account intruder is not captain-approved" \
    "account refusal was not explicit"
  [ "$(fork_oid "$dir")" = "$before" ] || fail "account mismatch changed the fork"
  [ "$(receive_count "$dir")" -eq 0 ] || fail "account mismatch reached git-receive-pack"
  pass "upstream sync: authenticated-account mismatch refuses before transmission"
}

test_failed_repository_checks_create_review_branch() {
  local dir out before packet
  dir=$(make_fixture validation-failure)
  before=$(fork_oid "$dir")
  upstream_commit "$dir" upstream.txt newer
  out=$(run_sync "$dir" VALIDATION_FAIL=1 2>&1) \
    || fail "validation-failure review staging failed: $out"
  assert_contains "$out" "REVIEW_REQUIRED" "failed validation did not require review"
  packet=$(find "$dir/home/state/upstream-sync/reviews" -type f -name 'widgets-*.md' | head -1)
  assert_grep 'Repository validation: failed(exit=1)' "$packet" \
    "packet did not record failed repository checks"
  [ "$(fork_oid "$dir")" = "$before" ] || fail "failed checks changed the fork default"
  [ -n "$(review_ref "$dir")" ] || fail "failed checks did not preserve a review branch"
  pass "upstream sync: failed repository checks block default and stage review"
}

test_protected_deployment_or_migration_paths_require_review() {
  local dir out packet before
  dir=$(make_fixture protected-paths '"deploymentPaths": ["deploy/**"],
        "migrationPaths": ["migrations/**"]')
  before=$(fork_oid "$dir")
  upstream_commit "$dir" deploy/release.sh changed
  upstream_commit "$dir" migrations/001.sql changed
  out=$(run_sync "$dir" 2>&1) || fail "protected-path review staging failed: $out"
  assert_contains "$out" "REVIEW_REQUIRED" "protected deployment/migration paths did not require review"
  packet=$(find "$dir/home/state/upstream-sync/reviews" -type f -name 'widgets-*.md' | head -1)
  assert_grep 'deployment:deploy/release.sh' "$packet" "deployment path gate was not recorded"
  assert_grep 'migration:migrations/001.sql' "$packet" "migration path gate was not recorded"
  [ "$(fork_oid "$dir")" = "$before" ] || fail "protected paths changed the fork default"
  pass "upstream sync: protected deployment and migration paths require captain review"
}

test_repeated_poll_does_not_duplicate_work() {
  local dir first second count_before count_after packets
  dir=$(make_fixture repeated-poll)
  upstream_commit "$dir" upstream.txt newer
  first=$(run_sync "$dir" VALIDATION_FAIL=1 2>&1) || fail "initial review staging failed: $first"
  count_before=$(receive_count "$dir")
  second=$(run_sync "$dir" VALIDATION_FAIL=1 2>&1) || fail "repeated review poll failed: $second"
  count_after=$(receive_count "$dir")
  [ "$count_before" -eq "$count_after" ] || fail "repeated poll duplicated the review-branch push"
  assert_contains "$second" "already has a review packet; no duplicate work" \
    "repeated poll did not identify its idempotent path"
  packets=$(find "$dir/home/state/upstream-sync/reviews" -type f -name 'widgets-*.md' | wc -l)
  [ "$packets" -eq 1 ] || fail "repeated poll created duplicate review packets"
  pass "upstream sync: repeated polling of one release creates no duplicate work"
}

test_scheduled_check_defaults_to_daily() {
  local dir before early due
  dir=$(make_fixture daily-schedule)
  run_sync "$dir" FM_UPSTREAM_SYNC_NOW=100000 >/dev/null 2>&1
  upstream_commit "$dir" upstream.txt newer
  before=$(receive_count "$dir")
  early=$(run_scheduled "$dir" FM_UPSTREAM_SYNC_NOW=186399 2>&1) \
    || fail "not-yet-due scheduled check failed: $early"
  [ -z "$early" ] || fail "not-yet-due daily check should be silent, got: $early"
  [ "$(receive_count "$dir")" -eq "$before" ] || fail "daily scheduler ran before 24 hours"
  due=$(run_scheduled "$dir" FM_UPSTREAM_SYNC_NOW=186400 2>&1) \
    || fail "due scheduled check failed: $due"
  assert_contains "$due" "fast-forwarded captain fork" "daily scheduler did not run at 24 hours"
  pass "upstream sync: scheduled checks default conservatively to a 24-hour interval"
}

test_recovers_after_interruption_without_duplicate_push() {
  local dir first rc second count_before count_after
  dir=$(make_fixture interruption-recovery)
  upstream_commit "$dir" upstream.txt newer
  first=$(run_sync "$dir" FM_UPSTREAM_SYNC_INTERRUPT_AFTER=default-push 2>&1); rc=$?
  [ "$rc" -eq 99 ] || fail "fixture interruption should exit 99, got $rc: $first"
  [ "$(fork_oid "$dir")" = "$(upstream_oid "$dir")" ] \
    || fail "interrupted run did not reach the intended post-push boundary"
  [ ! -f "$dir/home/state/upstream-sync/projects/widgets/check.state" ] \
    || fail "interrupted run published completed state prematurely"
  count_before=$(receive_count "$dir")
  second=$(run_sync "$dir" 2>&1) || fail "recovery run failed: $second"
  count_after=$(receive_count "$dir")
  [ "$count_before" -eq "$count_after" ] || fail "recovery duplicated an already-completed push"
  assert_contains "$second" "fork default already matches upstream" \
    "recovery did not reconcile remote truth after interruption"
  [ -f "$dir/home/state/upstream-sync/projects/widgets/check.state" ] \
    || fail "recovery did not publish completed durable state"
  pass "upstream sync: interruption recovery reconciles remote state without duplicate writes"
}

run_baseline() {  # <fixture> [primary]
  local dir=$1
  shift
  env FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FIXTURE_ROOT="$dir" TRANSPORT_LOG="$dir/transport.log" \
    GIT_SSH_COMMAND="$dir/fakebin/ssh" PATH="$dir/fakebin:$PATH" \
    "$SYNC" baseline widgets "$dir/task-worktree" "$@"
}

test_baseline_preserves_committed_primary_and_pool_history() {
  local dir out before primary_before fork_before rc
  dir=$(make_fixture baseline-primary-ahead)
  git clone -q "$dir/fork.git" "$dir/task-worktree"
  printf 'accepted local work\n' > "$dir/seed/local.txt"
  git -C "$dir/seed" add local.txt
  git -C "$dir/seed" -c user.name=fmtest -c user.email=fmtest@example.invalid \
    commit -qm 'accepted local work'
  primary_before=$(git -C "$dir/seed" rev-parse HEAD)
  fork_before=$(fork_oid "$dir")
  out=$(run_baseline "$dir" "$dir/seed" 2>&1); rc=$?
  expect_code 0 "$rc" "a lagging fork must not hide accepted primary work: $out"
  [ "$(git -C "$dir/task-worktree" rev-parse HEAD)" = "$primary_before" ] \
    || fail "task baseline omitted the primary-only commit"
  assert_contains "$out" 'source=primary' "baseline did not disclose primary selection"
  [ "$(git -C "$dir/seed" rev-parse HEAD)" = "$primary_before" ] || fail "baseline moved primary HEAD"
  [ "$(fork_oid "$dir")" = "$fork_before" ] || fail "baseline changed the fork"
  [ -z "$(git -C "$dir/seed" status --porcelain)" ] || fail "baseline dirtied primary"

  # Same primary, one fork-only commit: the original incident must now refuse.
  fork_commit "$dir" fork.txt 'accepted fork work'
  before=$(git -C "$dir/task-worktree" rev-parse HEAD)
  out=$(run_baseline "$dir" "$dir/seed" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "divergent primary and fork were silently selected around"
  assert_contains "$out" 'diverge; reconcile both histories' "divergence did not identify the remedy"
  [ "$(git -C "$dir/task-worktree" rev-parse HEAD)" = "$before" ] || fail "divergence moved pooled HEAD"

  # A normal merge preserves both sides and makes exactly the same input usable.
  git -C "$dir/seed" fetch -q "$dir/fork.git" main
  git -C "$dir/seed" -c user.name=fmtest -c user.email=fmtest@example.invalid \
    merge -q --no-ff --no-edit FETCH_HEAD
  out=$(run_baseline "$dir" "$dir/seed" 2>&1); rc=$?
  expect_code 0 "$rc" "reconciled primary should unblock baseline selection: $out"
  git -C "$dir/task-worktree" merge-base --is-ancestor "$primary_before" HEAD \
    || fail "reconciled baseline lost primary history"
  git -C "$dir/task-worktree" merge-base --is-ancestor "$(fork_oid "$dir")" HEAD \
    || fail "reconciled baseline lost fork history"
  pass "baseline retains local work, refuses divergence, and accepts an ordinary reconciliation"
}

test_baseline_fork_ahead_and_pool_refusals() {
  local dir out rc before branch
  dir=$(make_fixture baseline-fork-ahead)
  git clone -q "$dir/fork.git" "$dir/task-worktree"
  fork_commit "$dir" fork.txt newer
  before=$(git -C "$dir/seed" rev-parse HEAD)
  out=$(run_baseline "$dir" "$dir/seed" 2>&1); rc=$?
  expect_code 0 "$rc" "a containing fork tip should remain eligible: $out"
  [ "$(git -C "$dir/task-worktree" rev-parse HEAD)" = "$(fork_oid "$dir")" ] \
    || fail "fork-ahead selection did not advance the task"
  [ "$(git -C "$dir/seed" rev-parse HEAD)" = "$before" ] || fail "fork-ahead selection moved primary"

  git -C "$dir/task-worktree" checkout -qb pool-work
  printf 'unlanded\n' > "$dir/task-worktree/unlanded.txt"
  git -C "$dir/task-worktree" add unlanded.txt
  git -C "$dir/task-worktree" -c user.name=fmtest -c user.email=fmtest@example.invalid \
    commit -qm 'unlanded pool work'
  before=$(git -C "$dir/task-worktree" rev-parse HEAD)
  out=$(run_baseline "$dir" "$dir/seed" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "baseline discarded pool-only commits"
  assert_contains "$out" 'has commits outside selected baseline' "pool-only refusal missing"
  [ "$(git -C "$dir/task-worktree" rev-parse HEAD)" = "$before" ] || fail "refusal changed pooled HEAD"
  branch=$(git -C "$dir/task-worktree" symbolic-ref --short HEAD)
  [ "$branch" = pool-work ] || fail "refusal detached or changed the pooled branch"
  printf 'dirty\n' >> "$dir/task-worktree/unlanded.txt"
  out=$(run_baseline "$dir" "$dir/seed" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "baseline accepted dirty pooled work"
  assert_grep dirty "$dir/task-worktree/unlanded.txt" "baseline discarded dirty bytes"
  out=$(run_baseline "$dir" "$dir/task-worktree" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "baseline accepted its own primary as a target"
  assert_contains "$out" 'baseline target is the primary checkout' "primary isolation gate was not reached"
  pass "baseline allows a containing fork but preserves divergent commits and dirty pooled bytes"
}


test_spawn_policy_uses_primary_history() {
  local dir fakebin out rc id primary
  dir=$(make_fixture spawn-primary-ahead)
  # Share the normal spawn fixture while retaining the explicit-URL fake forge.
  fakebin=$(make_spawn_fakebin "$dir/spawn-tools")
  cp "$dir/fakebin/gh-axi" "$dir/fakebin/ssh" "$fakebin/"
  git clone -q "$dir/fork.git" "$dir/widgets"
  git -C "$dir/widgets" worktree add -q --detach "$dir/task-worktree" HEAD
  printf 'accepted primary code\n' > "$dir/widgets/primary.txt"
  git -C "$dir/widgets" add primary.txt
  git -C "$dir/widgets" -c user.name=fmtest -c user.email=fmtest@example.invalid \
    commit -qm 'accepted primary code'
  primary=$(git -C "$dir/widgets" rev-parse HEAD)
  id="baseline-primary-spawn"
  fm_test_spawn_home "$dir/home" codex
  fm_test_spawn_brief "$dir/home" "$id"
  out=$(FM_GATE_REFUSE_BYPASS=0 FIXTURE_ROOT="$dir" TRANSPORT_LOG="$dir/transport.log" \
    GIT_SSH_COMMAND="$fakebin/ssh" \
    fm_test_run_spawn "$dir/home" "$dir/task-worktree" "$fakebin" \
    "$id" "$dir/widgets" --scout 2>&1); rc=$?
  expect_code 0 "$rc" "policy-enabled spawn must retain primary history: $out"
  assert_contains "$out" 'source=primary' "spawn did not select its primary default"
  [ "$(git -C "$dir/task-worktree" rev-parse HEAD)" = "$primary" ] \
    || fail "spawn dropped the primary-only commit"
  [ "$(git -C "$dir/widgets" rev-parse main)" = "$primary" ] \
    || fail "spawn moved the primary default"
  pass "policy-enabled spawn starts its isolated worker from committed primary history"
}


test_spawn_policy_uses_primary_history
test_baseline_preserves_committed_primary_and_pool_history
test_baseline_fork_ahead_and_pool_refusals
test_original_author_fetch_and_captain_fork_push
test_effective_fetch_url_rewrite_refuses
test_upstream_release_fast_forwards_cleanly
test_fork_unique_commits_create_review_branch
test_upstream_merge_conflict_is_reported
test_missing_captain_fork_refuses
test_authenticated_account_mismatch_refuses_push
test_failed_repository_checks_create_review_branch
test_protected_deployment_or_migration_paths_require_review
test_repeated_poll_does_not_duplicate_work
test_scheduled_check_defaults_to_daily
test_recovers_after_interruption_without_duplicate_push
