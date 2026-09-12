#!/usr/bin/env bash
# Reproducible CLI evidence. Forge responses and the guard are fixture stubs;
# PR registration, promotion, authentication, watcher, and wake drain are real.
set -euo pipefail
SOURCE_ROOT=${1:?usage: bash metadata-watcher-replay.sh SOURCE_ROOT}
. "$SOURCE_ROOT/tests/lib.sh"
. "$SOURCE_ROOT/bin/fm-pr-lib.sh"
CASE=$(fm_test_tmproot fm-metadata-watcher-evidence)
mkdir -p "$CASE/home/state" "$CASE/home/data/task-a" "$CASE/wt" "$CASE/fakebin" "$CASE/guard/bin"
export FM_HOME="$CASE/home" FM_TEST_GH_LOG="$CASE/forge.log"
export FM_TEST_GH_STATE=OPEN
cat > "$CASE/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "$*" in
  *headRefOid*) printf '0123456789abcdef0123456789abcdef01234567\n' ;;
  *'--json state'*) printf '%s\n' "$FM_TEST_GH_STATE" ;;
  *) exit 2 ;;
esac
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$CASE/guard/bin/fm-guard.sh"
chmod +x "$CASE/fakebin/gh" "$CASE/guard/bin/fm-guard.sh"
export PATH="$CASE/fakebin:/usr/bin:/bin:/usr/sbin:/sbin"
fm_write_meta "$FM_HOME/state/task-a.meta" \
  'window=firstmate:fm-task-a' 'endpoint_task_id=task-a' \
  "worktree=$CASE/wt" "project=$CASE/project" 'kind=scout'
cat > "$FM_HOME/data/task-a/brief.md" <<'MD'
# Task
## Captain's intent
Preserve the recorded PR notification when promoting this task.

## Firstmate spec
Continue implementing the existing PR.
MD
printf 'Fixture: deterministic forge responses; real Firstmate CLI and persisted wake queue.\n'
printf '$ fm-pr-check.sh task-a https://github.com/example/repo/pull/19\n'
FM_ROOT_OVERRIDE="$CASE/guard" "$ROOT/bin/fm-pr-check.sh" task-a https://github.com/example/repo/pull/19
printf '$ fm-promote.sh task-a --mode direct-PR --yolo off\n'
FM_ROOT_OVERRIDE="$CASE/guard" "$ROOT/bin/fm-promote.sh" task-a --mode direct-PR --yolo off
STATE="$FM_HOME/state"
fm_pr_poll_artifacts_valid "$STATE" task-a "$ROOT/bin/fm-pr-poll.sh"
cp "$STATE/task-a.meta" "$CASE/authentic.meta"
printf 'Persisted metadata after promotion:\n'
cat "$STATE/task-a.meta"
BEFORE=$(cat "$CASE/forge.log")
printf '\nInject an unrecognized trailing field: unknown=value\n'
printf 'unknown=value\n' >> "$STATE/task-a.meta"
printf '$ fm-watch.sh (forge fixture now reports MERGED)\n'
FM_TEST_GH_STATE=MERGED FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=2 \
  FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
  timeout 15 "$ROOT/bin/fm-watch.sh" > "$CASE/rejected.out"
cat "$CASE/rejected.out"
assert_grep 'rejected unauthenticated state checks:' "$CASE/rejected.out" 'watcher accepted tampered metadata'
[ "$BEFORE" = "$(cat "$CASE/forge.log")" ] || fail 'tampered poll queried the forge'
[ -f "$STATE/task-a.pr-poll-registration" ] || fail 'tampered poll was retired'
printf 'Forge calls unchanged; rejected poll remains registered.\n'
printf 'Durable rejection wake:\n'
cat "$STATE/.wake-queue"

# Acknowledge the rejection through the operator interface before the next cycle.
FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-wake-drain.sh" > "$CASE/drain.out" 2> "$CASE/drain.err"
SEQUENCE=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$CASE/drain.err")
GENERATION=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$CASE/drain.err")
FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$SEQUENCE" --recovery-generation "$GENERATION"
cp "$CASE/authentic.meta" "$STATE/task-a.meta"
printf '\nRestore the authentic promoted metadata; do not re-register the poll.\n'
fm_pr_poll_artifacts_valid "$STATE" task-a "$ROOT/bin/fm-pr-poll.sh"
printf '$ fm-watch.sh (forge fixture reports MERGED)\n'
FM_TEST_GH_STATE=MERGED FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=2 \
  FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
  timeout 15 "$ROOT/bin/fm-watch.sh" > "$CASE/merged.out"
cat "$CASE/merged.out"
[ "$(cat "$CASE/merged.out")" = "check: $STATE/task-a.check.sh: merged" ] || fail 'watcher lost the merge after promotion'
printf 'Durable merge wake:\n'
cat "$STATE/.wake-queue"
assert_grep 'https://github.com/example/repo/pull/19' "$STATE/.wake-queue" 'merge wake lost the PR identity'
for SUFFIX in check.sh pr-poll pr-poll-registration; do
  [ ! -e "$STATE/task-a.$SUFFIX" ] || fail 'merged poll did not retire'
done
printf 'Merged poll retired after its notification was durably queued.\n'
