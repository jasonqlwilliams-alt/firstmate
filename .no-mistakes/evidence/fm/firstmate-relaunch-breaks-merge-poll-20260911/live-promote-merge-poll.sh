#!/usr/bin/env bash
# Live drive: a scout records a real (already merged) PR with the real
# bin/fm-pr-check.sh, is promoted to ship with the real bin/fm-promote.sh, and the
# real bin/fm-watch.sh runs the armed poll against GitHub (gh read-only).
# Usage: live-promote-merge-poll.sh <firstmate-root>
set -u
ROOT=$1
ID=sc-live
URL=https://github.com/jasonqlwilliams-alt/firstmate/pull/5
SB=$(mktemp -d /tmp/fm-live-promote-XXXXXX)
HOMEDIR="$SB/home"; STATE="$HOMEDIR/state"
mkdir -p "$STATE" "$HOMEDIR/data/$ID" "$HOMEDIR/config" "$SB/wt" "$SB/project" "$SB/user-home"
export GH_CONFIG_DIR=/home/jason/.config/gh GH_NO_UPDATE_NOTIFIER=1 FM_GATE_REFUSE_BYPASS=1
trap 'rm -rf "$SB"' EXIT
{
  echo "window=firstmate:fm-$ID"
  echo "endpoint_task_id=$ID"
  echo "worktree=$SB/wt"
  echo "project=$SB/project"
  echo "kind=scout"
} > "$STATE/$ID.meta"
cat > "$HOMEDIR/data/$ID/brief.md" <<'EOF'
# Task
## Captain's intent
Investigate the existing PR and implement the recommended changes.

## Firstmate spec
Preserve the existing task and its PR notification when promoting it to ship.
EOF
printf '%s\n' "$$" > "$STATE/.lock"

printf '\n### 1. real fm-pr-check.sh records the PR on a scout\n'
HOME="$SB/user-home" FM_HOME="$HOMEDIR" "$ROOT/bin/fm-pr-check.sh" "$ID" "$URL" 2>/dev/null; echo "fm-pr-check exit=$?"
printf '\n### 2. real fm-promote.sh %s --mode direct-PR --yolo off\n' "$ID"
HOME="$SB/user-home" FM_HOME="$HOMEDIR" "$ROOT/bin/fm-promote.sh" "$ID" --mode direct-PR --yolo off 2>&1 | grep -v '━\|●' ; echo "fm-promote exit=${PIPESTATUS[0]}"
echo "--- state/$ID.meta after promotion"; cat "$STATE/$ID.meta"
printf '\n### 3. real fm-watch.sh runs the armed poll against the real GitHub PR\n'
perl -e 'my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } local $SIG{ALRM}=sub { kill "TERM", $pid; waitpid $pid, 0; exit 124 }; alarm 60; waitpid $pid, 0; alarm 0; exit($? >> 8)' \
  env HOME="$SB/user-home" FM_HOME="$HOMEDIR" PATH="/usr/local/bin:/usr/bin:/bin" \
  FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=20 FM_POLL=0.2 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
  "$ROOT/bin/fm-watch.sh" > "$SB/watch.out" 2> "$SB/watch.err"
echo "fm-watch exit=$?"
echo "--- watcher stdout"; cat "$SB/watch.out"
echo "--- state/.wake-queue"; cat "$STATE/.wake-queue" 2>/dev/null || echo "(no wake queue)"
echo "--- remaining poll artifacts"; ls -1 "$STATE" | grep -E "^$ID\.(check\.sh|pr-poll|pr-poll-registration)$" || echo "(none: poll retired)"
