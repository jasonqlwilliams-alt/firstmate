#!/usr/bin/env bash
# Replay the executable PR registration/watcher boundary with isolated forge data.
set -euo pipefail
repo_root=$(cd "${1:?pass the source worktree}" && pwd)
umask 022
replay_root=$(mktemp -d "$repo_root/.test-phase-metadata.XXXXXX")
trap 'rm -rf -- "$replay_root"' EXIT
printf 'Real interfaces: fm-pr-check.sh, fm-watch.sh, fm_pr_poll_artifacts_valid.\n'
printf 'Fixtures: gh reports a fixed head and MERGED; tmux reports no windows; guard is isolated. No live forge or worker is contacted.\n'
for scenario in legitimate unknown-field prefix-lookalike missing-equals duplicate-pr invalid-head modified-check opaque-shell-bytes; do
  case_dir="$replay_root/$scenario"
  state="$case_dir/home/state"
  mkdir -p "$state" "$case_dir/home/data" "$case_dir/home/config" "$case_dir/wt" "$case_dir/fakebin" "$case_dir/root/bin"
  printf '%s\n' "$$" > "$state/.lock"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$case_dir/root/bin/fm-guard.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$case_dir/fakebin/tmux"
  cat > "$case_dir/fakebin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$REPLAY_GH_LOG"
case "$*" in
  *headRefOid*) printf '0123456789abcdef0123456789abcdef01234567\n' ;;
  *'--json state'*) printf 'MERGED\n' ;;
  *) exit 2 ;;
esac
GH
  chmod +x "$case_dir/root/bin/fm-guard.sh" "$case_dir/fakebin/gh" "$case_dir/fakebin/tmux"
  printf 'window=firstmate:fm-task-a\nendpoint_task_id=task-a\nworktree=%s\nkind=ship\nmode=no-mistakes\n' "$case_dir/wt" > "$state/task-a.meta"
  printf '\nSCENARIO %s\n' "$scenario"
  env FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/root" FM_STATE_OVERRIDE="$state" REPLAY_GH_LOG="$case_dir/gh.log" PATH="$case_dir/fakebin:/usr/bin:/bin" \
    "$repo_root/bin/fm-pr-check.sh" task-a https://github.com/example/repo/pull/19
  printf 'control_relaunch_tx=12345.20260911T120000Z.6789\ntraceparent=00-0123456789abcdef0123456789abcdef-0123456789abcdef-01\ndecisions_reviewed=1\ndecision_keys=review-call\nspawn_gen=12345.20260911T120000Z.6789\nkind=ship\nmode=direct-PR\nyolo=off\nx_request=request-19\nx_request_ts=1789250000\nx_followups=2\nx_platform=x\nx_reply_max_chars=280\n' >> "$state/task-a.meta"
  expected=reject
  case "$scenario" in
    legitimate) expected=accept ;;
    unknown-field) printf 'unknown=value\n' >> "$state/task-a.meta" ;;
    prefix-lookalike) printf 'control_relaunch_tx_extra=value\n' >> "$state/task-a.meta" ;;
    missing-equals) printf 'control_relaunch_tx\n' >> "$state/task-a.meta" ;;
    duplicate-pr) printf 'pr=https://github.com/example/repo/pull/20\n' >> "$state/task-a.meta" ;;
    invalid-head) printf 'pr_head=invalid\n' >> "$state/task-a.meta" ;;
    modified-check) printf '\ntouch "%s"\n' "$case_dir/sentinel" >> "$state/task-a.check.sh" ;;
    opaque-shell-bytes) expected=accept; printf 'control_relaunch_tx=$(touch "%s")\n' "$case_dir/sentinel" >> "$state/task-a.meta" ;;
  esac
  sed -n '/^pr=/,$p' "$state/task-a.meta"
  validator_rc=0
  bash -c '. "$1"; fm_pr_poll_artifacts_valid "$2" task-a "$3"' _ \
    "$repo_root/bin/fm-pr-lib.sh" "$state" "$repo_root/bin/fm-pr-poll.sh" || validator_rc=$?
  printf 'validator exit=%s\n' "$validator_rc"
  forge_before=$(cat "$case_dir/gh.log")
  timeout 15s env FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$repo_root" FM_STATE_OVERRIDE="$state" \
    FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=2 FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
    REPLAY_GH_LOG="$case_dir/gh.log" PATH="$case_dir/fakebin:/usr/bin:/bin" \
    "$repo_root/bin/fm-watch.sh" > "$case_dir/watch.out" 2> "$case_dir/watch.err"
  cat "$case_dir/watch.out" "$case_dir/watch.err" "$state/.wake-queue"
  test ! -e "$case_dir/sentinel"
  if [ "$expected" = accept ]; then
    test "$validator_rc" -eq 0
    grep -q '^check: .*task-a.check.sh: merged$' "$case_dir/watch.out"
    grep -q 'check: merge landed: task-a https://github.com/example/repo/pull/19' "$state/.wake-queue"
    for suffix in check.sh pr-poll pr-poll-registration; do test ! -e "$state/task-a.$suffix"; done
    printf 'Observed: merge notification persisted; poll retired; injected bytes did not execute.\n'
  else
    test "$validator_rc" -ne 0
    grep -q '^check: rejected unauthenticated state checks:' "$case_dir/watch.out"
    ! grep -q 'merge landed:' "$state/.wake-queue"
    test "$forge_before" = "$(cat "$case_dir/gh.log")"
    for suffix in check.sh pr-poll pr-poll-registration; do test -f "$state/task-a.$suffix"; done
    printf 'Observed: rejection persisted; forge not queried; poll retained; modified bytes did not execute.\n'
  fi
done
