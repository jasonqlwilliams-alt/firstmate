#!/usr/bin/env bash
# Hermetic behavior tests for the fork-safe push and pull-request boundary.
# Real git pushes terminate in temporary bare repositories and every GitHub
# identity/PR command is a local fake; this suite never contacts a forge.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-delivery-guard.sh"
GH_AXI_SHIM="$ROOT/bin/fm-delivery-shims/gh-axi"
GIT_SHIM="$ROOT/bin/fm-delivery-shims/git"
TMP_ROOT=$(fm_test_tmproot fm-delivery-guard)

make_policy() {  # <home>
  local home=$1
  mkdir -p "$home/config"
  cat > "$home/config/repository-policy.json" <<'JSON'
{
  "version": 1,
  "approvedOwners": ["captain"],
  "approvedAccounts": ["captain"],
  "repositories": {
    "widgets": {
      "upstreamFetchUrl": "https://github.com/upstream/widgets.git",
      "forkPushUrl": "https://github.com/captain/widgets.git",
      "defaultBranch": "main"
    }
  }
}
JSON
}

make_fake_tools() {  # <dir>
  local fakebin=$1
  mkdir -p "$fakebin"
cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = api ]; then
  [ "${GH_HOST:-}" = github.com ] || exit 3
  case " $* " in *" --hostname "*) exit 4 ;; esac
  printf 'api_response:\n  body: %s\n  truncated: false\n' "${FAKE_GH_ACCOUNT:-captain}"
  exit 0
fi
printf '%s\n' "$*" >> "${GH_AXI_LOG:?}"
printf 'https://github.com/captain/widgets/pull/1\n'
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = status ]; then
  printf '    repo:  fixture\n'
  printf '  remote:  %s\n' "${NM_UPSTREAM:?}"
  [ -z "${NM_FORK:-}" ] || printf '    fork:  %s\n' "$NM_FORK"
  printf '    gate:  fixture\n'
  exit 0
fi
exit 2
SH
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *captain/widgets.git*) exec git-receive-pack "${FAKE_GIT_REMOTE_ROOT:?}/fork.git" ;;
  *upstream/widgets.git*) exec git-receive-pack "${FAKE_GIT_REMOTE_ROOT:?}/upstream.git" ;;
esac
exit 2
SH
  chmod +x "$fakebin/gh-axi" "$fakebin/no-mistakes" "$fakebin/ssh"
}

make_repo() {  # <name>; echoes repo|home|fakebin|upstream-bare|fork-bare|gate-bare
  local name=$1 dir repo home fakebin upstream fork gate
  dir="$TMP_ROOT/$name"
  repo="$dir/repo"
  home="$dir/home"
  fakebin="$dir/fakebin"
  upstream="$dir/upstream.git"
  fork="$dir/fork.git"
  gate="$dir/gate.git"
  fm_git_init_commit "$repo"
  git -C "$repo" branch -M main
  git init -q --bare "$upstream"
  git init -q --bare "$fork"
  git init -q --bare "$gate"
  git -C "$repo" remote add origin git@github.com:upstream/widgets.git
  git -C "$repo" remote add fork git@github.com:captain/widgets.git
  make_policy "$home"
  make_fake_tools "$fakebin"
  printf '%s|%s|%s|%s|%s|%s\n' "$repo" "$home" "$fakebin" "$upstream" "$fork" "$gate"
}

test_upstream_push_refuses_and_fork_push_succeeds() {
  local rec repo home fakebin upstream fork gate out rc log
  rec=$(make_repo push-boundary)
  IFS='|' read -r repo home fakebin upstream fork gate <<EOF
$rec
EOF
  log="$home/gh.log"
  FM_HOME="$home" GH_AXI_LOG="$log" PATH="$fakebin:$PATH" "$GUARD" arm widgets "$repo" >/dev/null \
    || fail "guard arm failed for the push fixture"

  out=$(FM_HOME="$home" FAKE_GIT_REMOTE_ROOT="${repo%/repo}" GH_AXI_LOG="$log" PATH="$fakebin:$PATH" \
    git -C "$repo" push origin main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "push to original-author origin should have been refused"
  assert_contains "$out" "branch-push would write to github.com/upstream/widgets" \
    "upstream refusal did not name the unsafe repository"
  if git --git-dir="$upstream" show-ref --verify --quiet refs/heads/main; then
    fail "refused upstream push still wrote a branch"
  fi

  out=$(FM_HOME="$home" FAKE_GIT_REMOTE_ROOT="${repo%/repo}" GH_AXI_LOG="$log" PATH="$fakebin:$PATH" \
    git -C "$repo" push fork main 2>&1)
  rc=$?
  expect_code 0 "$rc" "push to the configured captain fork should succeed"
  assert_contains "$out" "DELIVERY TARGET: project=widgets action=branch-push repository=github.com/captain/widgets account=captain" \
    "allowed push did not name its repository and authenticated account"
  git --git-dir="$fork" show-ref --verify --quiet refs/heads/main \
    || fail "allowed fork push did not reach the hermetic bare destination"
  pass "delivery guard: third-party origin is refused and configured fork push succeeds"
}

test_authenticated_account_mismatch_refuses() {
  local rec repo home fakebin upstream fork gate out rc log
  rec=$(make_repo account-mismatch)
  IFS='|' read -r repo home fakebin upstream fork gate <<EOF
$rec
EOF
  log="$home/gh.log"
  FM_HOME="$home" GH_AXI_LOG="$log" PATH="$fakebin:$PATH" "$GUARD" arm widgets "$repo" >/dev/null
  out=$(FM_HOME="$home" FAKE_GIT_REMOTE_ROOT="${repo%/repo}" FAKE_GH_ACCOUNT=intruder GH_AXI_LOG="$log" PATH="$fakebin:$PATH" \
    git -C "$repo" push fork main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "unapproved authenticated account should refuse the push"
  assert_contains "$out" "authenticated GitHub account intruder is not captain-approved" \
    "account mismatch refusal was not explicit"
  git --git-dir="$fork" show-ref --verify --quiet refs/heads/main \
    && fail "account-mismatched push still reached the fork"
  pass "delivery guard: authenticated-account mismatch fails closed before transmission"
}

test_effective_push_url_rewrite_refuses() {
  local rec repo home fakebin upstream fork gate out rc log
  rec=$(make_repo effective-rewrite)
  IFS='|' read -r repo home fakebin upstream fork gate <<EOF
$rec
EOF
  log="$home/gh.log"
  FM_HOME="$home" GH_AXI_LOG="$log" PATH="$fakebin:$PATH" "$GUARD" arm widgets "$repo" >/dev/null
  git -C "$repo" config url.git@github.com:upstream/.pushInsteadOf git@github.com:captain/
  out=$(FM_HOME="$home" FAKE_GIT_REMOTE_ROOT="${repo%/repo}" GH_AXI_LOG="$log" PATH="$fakebin:$PATH" \
    git -C "$repo" push fork main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "pushInsteadOf rewrite to upstream should have been refused"
  assert_contains "$out" "branch-push would write to github.com/upstream/widgets" \
    "effective-URL refusal did not name the rewritten upstream destination"
  git --git-dir="$upstream" show-ref --verify --quiet refs/heads/main \
    && fail "effective-URL-refused push still reached upstream"
  git --git-dir="$fork" show-ref --verify --quiet refs/heads/main \
    && fail "effective-URL-refused push unexpectedly reached the fork"
  pass "delivery guard: Git URL rewriting cannot hide an unsafe effective push target"
}

test_no_mistakes_checks_branch_and_pr_targets() {
  local rec repo home fakebin upstream fork gate out rc log
  rec=$(make_repo no-mistakes-targets)
  IFS='|' read -r repo home fakebin upstream fork gate <<EOF
$rec
EOF
  log="$home/gh.log"
  git -C "$repo" remote add no-mistakes "$gate"
  FM_HOME="$home" GH_AXI_LOG="$log" PATH="$fakebin:$PATH" "$GUARD" arm widgets "$repo" >/dev/null

  out=$(FM_HOME="$home" GH_AXI_LOG="$log" NM_UPSTREAM=https://github.com/upstream/widgets.git \
    NM_FORK=https://github.com/captain/widgets.git PATH="$fakebin:$PATH" \
    git -C "$repo" push no-mistakes main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "no-mistakes upstream PR target should have been refused"
  assert_contains "$out" "pull-request would write to github.com/upstream/widgets" \
    "no-mistakes refusal did not identify its unsafe PR target"
  git --git-dir="$gate" show-ref --verify --quiet refs/heads/main \
    && fail "refused no-mistakes push still reached the local gate"

  out=$(FM_HOME="$home" GH_AXI_LOG="$log" NM_UPSTREAM=https://github.com/captain/widgets.git \
    NM_FORK=https://github.com/captain/widgets.git PATH="$fakebin:$PATH" \
    git -C "$repo" push no-mistakes main 2>&1)
  rc=$?
  expect_code 0 "$rc" "no-mistakes with captain-owned branch and PR targets should reach its local gate"
  assert_contains "$out" "action=branch-push repository=github.com/captain/widgets" \
    "no-mistakes allowed path did not name its branch destination"
  assert_contains "$out" "action=pull-request repository=github.com/captain/widgets" \
    "no-mistakes allowed path did not name its PR destination"
  git --git-dir="$gate" show-ref --verify --quiet refs/heads/main \
    || fail "allowed no-mistakes path did not reach the hermetic local gate"
  pass "delivery guard: no-mistakes must use the captain fork for both push and PR"
}

test_gh_axi_pr_write_shim_refuses_and_allows() {
  local rec repo home fakebin upstream fork gate out rc log
  rec=$(make_repo pr-shim)
  IFS='|' read -r repo home fakebin upstream fork gate <<EOF
$rec
EOF
  log="$home/gh.log"
  : > "$log"
  FM_HOME="$home" GH_AXI_LOG="$log" PATH="$fakebin:$PATH" "$GUARD" arm widgets "$repo" >/dev/null

  out=$(cd "$repo" && FM_HOME="$home" GH_REPO=upstream/widgets GH_AXI_LOG="$log" \
    FM_DELIVERY_GUARD_ROOT="$ROOT" FM_REAL_GH_AXI="$fakebin/gh-axi" PATH="$fakebin:$PATH" \
    "$GH_AXI_SHIM" pr create --title unsafe --body unsafe 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "gh-axi shim should refuse a third-party PR target"
  assert_contains "$out" "pull-request would write to github.com/upstream/widgets" \
    "gh-axi refusal did not name the unsafe repository"
  [ ! -s "$log" ] || fail "refused gh-axi PR command still reached the real executable"

  out=$(cd "$repo" && FM_HOME="$home" GH_REPO=captain/widgets GH_AXI_LOG="$log" \
    FM_DELIVERY_GUARD_ROOT="$ROOT" FM_REAL_GH_AXI="$fakebin/gh-axi" PATH="$fakebin:$PATH" \
    "$GH_AXI_SHIM" pr create --title safe --body safe 2>&1)
  rc=$?
  expect_code 0 "$rc" "gh-axi shim should allow the configured PR repository"
  assert_contains "$out" "DELIVERY TARGET: project=widgets action=pull-request repository=github.com/captain/widgets account=captain" \
    "allowed gh-axi PR did not announce its repository"
  assert_grep 'pr create --title safe --body safe' "$log" \
    "allowed gh-axi PR did not reach the real executable"

  out=$(cd "$repo" && FM_HOME="$home" GH_REPO=captain/widgets GH_AXI_LOG="$log" \
    FM_DELIVERY_GUARD_ROOT="$ROOT" FM_REAL_GH_AXI="$fakebin/gh-axi" PATH="$fakebin:$PATH" \
    "$GH_AXI_SHIM" api graphql -f query=mutation 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "gh-axi shim should fail closed for unresolvable GraphQL mutations"
  assert_contains "$out" "GraphQL is unavailable in a guarded worker" \
    "GraphQL refusal did not explain why its repository cannot be proven"
  out=$(cd "$repo" && FM_HOME="$home" GH_AXI_LOG="$log" \
    FM_DELIVERY_GUARD_ROOT="$ROOT" FM_REAL_GH_AXI="$fakebin/gh-axi" PATH="$fakebin:$PATH" \
    "$GH_AXI_SHIM" api /repos/upstream/widgets/pulls --field title=unsafe 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "implicit POST API write should be destination-guarded"
  assert_contains "$out" "pull-request would write to github.com/upstream/widgets" \
    "implicit POST API refusal did not identify the unsafe repository"
  out=$(cd "$repo" && FM_HOME="$home" GH_AXI_LOG="$log" \
    FM_DELIVERY_GUARD_ROOT="$ROOT" FM_REAL_GH_AXI="$fakebin/gh-axi" PATH="$fakebin:$PATH" \
    "$GH_AXI_SHIM" api --method=post /repos/upstream/widgets/pulls 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "lower-case API methods should be destination-guarded"
  assert_contains "$out" "pull-request would write to github.com/upstream/widgets" \
    "lower-case method refusal did not identify the unsafe repository"
  pass "delivery guard: gh-axi PR writes are refused or allowed by the same durable target"
}


# The guard is opt-in per home. These three cases pin the property that makes it
# safe to carry: a home that configures no config/repository-policy.json keeps
# exactly the delivery behavior it had before the guard existed.

test_unarmed_repository_pushes_anywhere() {
  local rec repo home fakebin upstream fork gate out rc
  rec=$(make_repo unarmed)
  IFS='|' read -r repo home fakebin upstream fork gate <<EOF
$rec
EOF
  rm -f "$home/config/repository-policy.json"
  # Deliberately never armed, exactly as fm-spawn.sh leaves a policy-free home.
  out=$(FM_HOME="$home" FAKE_GIT_REMOTE_ROOT="${repo%/repo}" PATH="$fakebin:$PATH" \
    git -C "$repo" push origin main 2>&1)
  rc=$?
  expect_code 0 "$rc" "an unarmed repository must push exactly as it did before the guard existed"
  git --git-dir="$upstream" show-ref --verify --quiet refs/heads/main \
    || fail "unarmed push did not reach its destination"
  pass "delivery guard: an unarmed repository keeps its pre-guard push behavior"
}

test_arm_refuses_without_a_policy_file() {
  local rec repo home fakebin upstream fork gate out rc
  rec=$(make_repo arm-without-policy)
  IFS='|' read -r repo home fakebin upstream fork gate <<EOF
$rec
EOF
  rm -f "$home/config/repository-policy.json"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$GUARD" arm widgets "$repo" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "arming without a policy file should refuse rather than authorize"
  assert_contains "$out" "repository delivery policy is missing or unsafe" \
    "missing-policy refusal did not name the absent policy"
  pass "delivery guard: an explicit arm request without a policy file refuses"
}

test_direct_pr_contract_is_unchanged_without_a_policy() {
  local home block
  home="$TMP_ROOT/dod-home"
  mkdir -p "$home/config"
  block=$(FM_HOME="$home" bash -c '. "$1"; fm_dod_block direct-PR demo' _ "$ROOT/bin/fm-dod-lib.sh")
  case "$block" in
    *fm-delivery-guard.sh*) fail "a policy-free home must not receive guard instructions in its ship contract" ;;
  esac
  assert_contains "$block" "push your branch and open a PR with" \
    "the policy-free direct-PR contract lost its ordinary push and PR instruction"

  make_policy "$home"
  block=$(FM_HOME="$home" bash -c '. "$1"; fm_dod_block direct-PR demo' _ "$ROOT/bin/fm-dod-lib.sh")
  assert_contains "$block" "fm-delivery-guard.sh\" pr-target ." \
    "an armed home did not receive the explicit pull-request target instruction"
  pass "delivery guard: the ship contract only names the guard in a home that configures a policy"
}

test_git_shim_blocks_hook_bypasses() {
  local dir fake log out rc
  dir="$TMP_ROOT/git-shim"
  fake="$dir/git-real"
  log="$dir/git.log"
  mkdir -p "$dir"
  cat > "$fake" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GIT_REAL_LOG:?}"
SH
  chmod +x "$fake"
  : > "$log"
  out=$(FM_REAL_GIT="$fake" GIT_REAL_LOG="$log" "$GIT_SHIM" push --no-verify origin main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "guarded git should refuse --no-verify"
  assert_contains "$out" "cannot bypass the Firstmate repository delivery guard" \
    "git --no-verify refusal was not explicit"
  out=$(FM_REAL_GIT="$fake" GIT_REAL_LOG="$log" "$GIT_SHIM" send-pack origin main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "guarded git should refuse send-pack"
  assert_contains "$out" "send-pack bypasses" "send-pack refusal was not explicit"
  out=$(FM_REAL_GIT="$fake" GIT_REAL_LOG="$log" "$GIT_SHIM" \
    -c core.hooksPath=/dev/null push origin main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "guarded git should refuse a core.hooksPath override"
  assert_contains "$out" "cannot override the Firstmate pre-push hook" \
    "core.hooksPath refusal was not explicit"
  out=$(FM_REAL_GIT="$fake" GIT_REAL_LOG="$log" \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null \
    "$GIT_SHIM" push origin main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "guarded git should refuse an environment hook override"
  assert_contains "$out" "cannot override the Firstmate pre-push hook" \
    "environment hook-override refusal was not explicit"
  [ ! -s "$log" ] || fail "a refused Git bypass still reached the real executable"
  FM_REAL_GIT="$fake" GIT_REAL_LOG="$log" "$GIT_SHIM" status
  assert_grep 'status' "$log" "ordinary Git commands did not reach the real executable"
  pass "delivery guard: worker Git cannot bypass target checks with --no-verify or send-pack"
}

test_upstream_push_refuses_and_fork_push_succeeds
test_authenticated_account_mismatch_refuses
test_effective_push_url_rewrite_refuses
test_no_mistakes_checks_branch_and_pr_targets
test_gh_axi_pr_write_shim_refuses_and_allows
test_unarmed_repository_pushes_anywhere
test_arm_refuses_without_a_policy_file
test_direct_pr_contract_is_unchanged_without_a_policy
test_git_shim_blocks_hook_bypasses
