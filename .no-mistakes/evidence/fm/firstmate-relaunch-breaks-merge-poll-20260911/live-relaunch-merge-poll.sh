#!/usr/bin/env bash
# Live drive of the 2026-09-11 sequence against the real Firstmate scripts:
#   real bin/fm-pr-check.sh  -> arms a merge poll with the real gh CLI
#   real bin/fm-control.sh <id> relaunch -> replaces a worker in a REAL tmux pane
#   real bin/fm-watch.sh     -> runs the armed poll against the real GitHub PR
# The target PR is jasonqlwilliams-alt/firstmate#5, which is already MERGED, so a
# healthy poll must deliver a durable merge wake. gh is used read-only.
# Isolation: throwaway FM_HOME, HOME, and a private tmux server socket.
#
# Usage: live-relaunch-merge-poll.sh <firstmate-root> <trace off|on> [tamper-line]
set -u
ROOT=$1
TRACE=${2:-off}
TAMPER=${3:-}
ID=rl-live
URL=https://github.com/jasonqlwilliams-alt/firstmate/pull/5

SB=$(mktemp -d /tmp/fm-live-XXXXXX)
HOMEDIR="$SB/home"; STATE="$HOMEDIR/state"; WT="$SB/wt"; PROJ="$SB/proj"
mkdir -p "$STATE" "$HOMEDIR/data/$ID" "$HOMEDIR/config" "$SB/user-home" "$SB/tmux" "$SB/agentbin"
export TMUX_TMPDIR="$SB/tmux"
unset TMUX
export GH_CONFIG_DIR=/home/jason/.config/gh GH_NO_UPDATE_NOTIFIER=1
export FM_GATE_REFUSE_BYPASS=1   # the same sandbox exemption tests/lib.sh exports
cleanup() { tmux kill-server >/dev/null 2>&1 || true; rm -rf "$SB"; }
trap cleanup EXIT

say() { printf '\n### %s\n' "$*"; }

git init -q -b main "$PROJ"
git -C "$PROJ" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git init -q --bare "$PROJ.origin.git"
git -C "$PROJ" remote add origin "$PROJ.origin.git"
git -C "$PROJ" push -q origin main
git -C "$PROJ" worktree add -q -b "task-$ID" "$WT"

# A stand-in agent process named `claude` (exec'd directly so the pane's
# foreground command really is `claude`). It renders a box and exits on /exit.
cat > "$SB/agentbin/claude" <<SH
#!/bin/bash
printf '\xe2\x95\xad\xe2\x94\x80\xe2\x94\x80\xe2\x95\xae\n\xe2\x94\x82 claude stand-in pid \$\$ \xe2\x94\x82\n\xe2\x95\xb0\xe2\x94\x80\xe2\x94\x80\xe2\x95\xaf\n'
printf 'start pid=%s cwd=%s\n' "\$\$" "\$PWD" >> "$SB/agent.log"
while IFS= read -r line; do
  printf 'input: %s\n' "\$line" >> "$SB/agent.log"
  case "\$line" in *"/exit"*|*"/quit"*) printf 'exit pid=%s\n' "\$\$" >> "$SB/agent.log"; exit 0 ;; esac
done
SH
chmod +x "$SB/agentbin/claude"

cat > "$HOMEDIR/data/$ID/brief.md" <<EOF
# Task
## Captain's intent
Live relaunch of a task whose PR is already recorded.

## Firstmate spec
Keep the merge poll armed across relaunch.
EOF
{
  echo "window=fmses:fm-$ID"
  echo "endpoint_task_id=$ID"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "tasktmp=/tmp/fm-$ID"
  echo "model=default"
  echo "effort=default"
} > "$STATE/$ID.meta"

PANE_PATH="$SB/agentbin:/usr/local/bin:/usr/bin:/bin"
env -i HOME="$SB/user-home" PATH="$PANE_PATH" TERM=xterm-256color TMUX_TMPDIR="$TMUX_TMPDIR" \
  tmux new-session -d -s fmses -n "fm-$ID" -x 200 -y 50 -c "$WT" "bash --noprofile --norc"
tmux send-keys -t "fmses:fm-$ID" "claude" Enter
for _ in $(seq 50); do [ "$(tmux display-message -p -t "fmses:fm-$ID" '#{pane_current_command}')" = claude ] && break; sleep 0.1; done
say "real tmux pane before relaunch"
tmux display-message -p -t "fmses:fm-$ID" 'pane_current_command=#{pane_current_command} pane_pid=#{pane_pid} cwd=#{pane_current_path}'

printf '%s\n' "$$" > "$STATE/.lock"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-trace-context-lib.sh"
FM_TRACE_CONTEXT="$TRACE" fm_trace_context_session_start "$HOMEDIR/config" "$STATE/.trace-context-effective"

say "1. real fm-pr-check.sh records the PR (real gh reads the head)"
FM_HOME="$HOMEDIR" FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-pr-check.sh" "$ID" "$URL"; echo "fm-pr-check exit=$?"
echo "--- tail of state/$ID.meta"; tail -3 "$STATE/$ID.meta"
ls -1 "$STATE" | grep "^$ID\." | sed 's/^/armed artifact: /'

say "2. real fm-control.sh $ID relaunch (trace=$TRACE)"
env HOME="$SB/user-home" CLAUDE_CONFIG_DIR='' PATH="$SB/agentbin:$PATH" FM_HOME="$HOMEDIR" \
  FM_SPAWN_NO_GUARD=1 FM_TRACE_CONTEXT="$TRACE" \
  FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=15 FM_CONTROL_LAUNCH_WAIT=30 \
  "$ROOT/bin/fm-control.sh" "$ID" relaunch --note 'Continue reviewing the recorded PR.' 2>&1
echo "fm-control relaunch exit=$?"
echo "--- stand-in agent log (old agent exit, new agent start)"; cat "$SB/agent.log"
tmux display-message -p -t "fmses:fm-$ID" 'after relaunch: pane_current_command=#{pane_current_command}'
echo "--- state/$ID.meta from pr= onward (after relaunch)"; sed -n '/^pr=/,$p' "$STATE/$ID.meta"

if [ -n "$TAMPER" ]; then
  say "ADVERSARIAL: append tampering line after relaunch: $TAMPER"
  printf '%s\n' "$TAMPER" >> "$STATE/$ID.meta"
  sed -n '/^pr=/,$p' "$STATE/$ID.meta"
fi

say "3. real fm-watch.sh runs the armed poll against the real GitHub PR"
perl -e 'my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } local $SIG{ALRM}=sub { kill "TERM", $pid; waitpid $pid, 0; exit 124 }; alarm 60; waitpid $pid, 0; alarm 0; exit($? >> 8)' \
  env HOME="$SB/user-home" FM_HOME="$HOMEDIR" PATH="/usr/local/bin:/usr/bin:/bin" \
  FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=20 FM_POLL=0.2 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
  "$ROOT/bin/fm-watch.sh" > "$SB/watch.out" 2> "$SB/watch.err"
echo "fm-watch exit=$?"
echo "--- watcher stdout"; cat "$SB/watch.out"
echo "--- watcher stderr"; cat "$SB/watch.err"
echo "--- state/.wake-queue"; cat "$STATE/.wake-queue" 2>/dev/null || echo "(no wake queue)"
echo "--- remaining poll artifacts"; ls -1 "$STATE" | grep -E "^$ID\.(check\.sh|pr-poll|pr-poll-registration)$" || echo "(none: poll retired)"
