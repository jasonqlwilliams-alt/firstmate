#!/usr/bin/env bash
# Isolated CLI verification: real PR registration, validator, watcher and wake
# queue; deterministic forge replies and no running worker or external writes.
set -eu
repo=${1:?pass the source worktree}
. "$repo/tests/lib.sh"
. "$repo/bin/fm-pr-lib.sh"
scratch=$(fm_test_tmproot metadata-boundary)
url=https://github.com/example/repo/pull/19
head=0123456789abcdef0123456789abcdef01234567

verify_case() {
  local name=$1 appended=$2 expected=$3 dir state result rc suffix calls
  dir="$scratch/$name"
  state="$dir/home/state"
  mkdir -p "$state" "$dir/home/config" "$dir/home/data" "$dir/wt" "$dir/fakebin" "$dir/root/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/root/bin/fm-guard.sh"
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_FORGE_LOG"
case "$*" in
  *headRefOid*) printf '0123456789abcdef0123456789abcdef01234567\n' ;;
  *'--json state'*) printf 'MERGED\n' ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$dir/root/bin/fm-guard.sh" "$dir/fakebin/gh"
  printf 'window=firstmate:fm-task\nendpoint_task_id=task\nworktree=%s\nkind=ship\nmode=no-mistakes\n' "$dir/wt" > "$state/task.meta"
  printf '\nCASE %s\n$ fm-pr-check.sh task %s\n' "$name" "$url"
  env FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/root" FM_TEST_FORGE_LOG="$dir/forge.log" PATH="$dir/fakebin:$PATH" \
    "$repo/bin/fm-pr-check.sh" task "$url"
  [ "$(tail -2 "$state/task.meta")" = "pr=$url"$'\n'"pr_head=$head" ] || fail "registration ordering differs"
  fm_pr_poll_artifacts_valid "$state" task "$repo/bin/fm-pr-poll.sh" || fail "initial registration failed"
  printf 'control_relaunch_tx=test.20260912.1\ntraceparent=00-0123456789abcdef0123456789abcdef-0123456789abcdef-01\ndecisions_reviewed=1\ndecision_keys=review\nspawn_gen=s123.456.789\nkind=ship\nmode=direct-PR\nyolo=off\n' >> "$state/task.meta"
  [ -z "$appended" ] || printf '%s\n' "$appended" >> "$state/task.meta"
  printf 'Metadata following PR registration:\n'
  sed -n '/^pr=/,$p' "$state/task.meta"
  rc=0
  fm_pr_poll_artifacts_valid "$state" task "$repo/bin/fm-pr-poll.sh" || rc=$?
  printf 'Validator exit: %s (expected %s)\n' "$rc" "$expected"
  [ "$rc" -eq "$expected" ] || fail "unexpected metadata validation result"
  printf '$ fm-watch.sh\n'
  perl -e 'my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } local $SIG{ALRM}=sub { kill "TERM", $pid; waitpid $pid, 0; exit 124 }; alarm 15; waitpid $pid, 0; alarm 0; exit($? >> 8)' \
    env FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$repo" FM_TEST_FORGE_LOG="$dir/forge.log" PATH="$dir/fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
    FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=2 FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
    "$repo/bin/fm-watch.sh" > "$dir/watch.out" 2> "$dir/watch.err"
  cat "$dir/watch.out" "$dir/watch.err"
  printf 'Persisted wake queue:\n'
  cat "$state/.wake-queue"
  printf 'Forge requests:\n'
  cat "$dir/forge.log"
  calls=$(wc -l < "$dir/forge.log")
  if [ "$expected" = 0 ]; then
    assert_grep 'task.check.sh: merged' "$dir/watch.out"
    assert_grep "$url" "$state/.wake-queue"
    [ "$calls" -eq 2 ] || fail "valid poll did not query forge exactly once"
    for suffix in check.sh pr-poll pr-poll-registration; do
      [ ! -e "$state/task.$suffix" ] || fail "merged poll was not retired"
    done
    printf 'Merged notification persisted; poll artifacts retired.\n'
  else
    assert_grep 'rejected unauthenticated state checks:' "$dir/watch.out"
    assert_no_grep 'merge landed:' "$state/.wake-queue"
    [ "$calls" -eq 1 ] || fail "tampered poll reached forge"
    for suffix in check.sh pr-poll pr-poll-registration; do
      [ -f "$state/task.$suffix" ] || fail "rejected poll artifacts were removed"
    done
    printf 'Tampering rejected before forge polling; artifacts retained; no merge wake.\n'
  fi
}

verify_case legitimate-lifecycle-metadata '' 0
verify_case unknown-key 'unknown=value' 1
verify_case lookalike-key 'control_relaunch_tx_extra=value' 1
verify_case malformed-key 'control_relaunch_tx' 1
verify_case invalid-head 'pr_head=invalid' 1
verify_case duplicate-pr 'pr=https://github.com/example/repo/pull/20' 1
verify_case opaque-shell-bytes 'control_relaunch_tx=$(touch '"$scratch"'/must-not-execute)' 0
[ ! -e "$scratch/must-not-execute" ] || fail 'opaque metadata executed shell code'
printf '\nOpaque metadata stayed data: command substitution did not execute.\n'
