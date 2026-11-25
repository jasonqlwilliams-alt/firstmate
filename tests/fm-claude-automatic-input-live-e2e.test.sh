#!/usr/bin/env bash
# Real Claude Code drift guard for automatic input to its composer and its
# background-tasks exit confirmation. Runs only in a private named tmux server.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_CLAUDE_AUTOMATIC_INPUT_LIVE
if [ -z "${FM_CLAUDE_AUTOMATIC_INPUT_API_KEY:-}" ]; then
  printf 'skip: live: set FM_CLAUDE_AUTOMATIC_INPUT_API_KEY to a lab Anthropic API key\n'
  exit 0
fi
fm_live_gate opt-in FM_CLAUDE_AUTOMATIC_INPUT_LIVE claude tmux git node

VERSION=$(claude --version)
LAB=$(fm_test_tmproot fm-claude-automatic-input)
SESSION=fm-test-claude-input-$$
TASK=claude-input
WINDOW="fm-$TASK"
TARGET="$SESSION:$WINDOW"
REAL_TMUX=$(command -v tmux)
REAL_CLAUDE=$(command -v claude)
WORKTREE="$LAB/worktree"

live_fail() { fail "Claude $VERSION: $*"; }
cleanup() {
  "$REAL_TMUX" -f /dev/null -L "$SESSION" kill-server 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

export FM_HOME="$LAB/home" CLAUDE_CONFIG_DIR="$LAB/claude-config"
inbox="$FM_HOME/state/$TASK.inbox"
printf -v list_inbox 'ls %q' "$inbox"
printf -v read_record 'cat %q' "$inbox/001.msg"
printf -v move_record 'mv %q %q' "$inbox/001.msg" "$inbox/handled/"
umask 077
mkdir -p "$FM_HOME/state" "$CLAUDE_CONFIG_DIR" "$LAB/bin" "$LAB/user"
fm_git_worktree "$LAB/project" "$WORKTREE" claude-input \
  || live_fail 'could not create the disposable linked worktree'
printf '{"hasCompletedOnboarding":true}\n' > "$CLAUDE_CONFIG_DIR/.claude.json"
cat > "$CLAUDE_CONFIG_DIR/settings.json" <<'JSON'
{"apiKeyHelper":"printf '%s\\n' \"$FM_CLAUDE_AUTOMATIC_INPUT_API_KEY\""}
JSON
"$ROOT/bin/fm-claude-trust.sh" "$WORKTREE" "$LAB/project" >/dev/null \
  || live_fail 'could not register trust in the isolated Claude config'

export FM_CLAUDE_INPUT_TMUX="$REAL_TMUX" FM_CLAUDE_INPUT_SESSION="$SESSION"
cat > "$LAB/bin/tmux" <<'SH'
#!/usr/bin/env bash
exec "$FM_CLAUDE_INPUT_TMUX" -f /dev/null -L "$FM_CLAUDE_INPUT_SESSION" "$@"
SH
chmod +x "$LAB/bin/tmux"
export PATH="$LAB/bin:$PATH"
unset TMUX TMUX_PANE
(
  export HOME="$LAB/user" FM_CLAUDE_AUTOMATIC_INPUT_API_KEY
  unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN \
    ANTHROPIC_BASE_URL ANTHROPIC_CUSTOM_HEADERS CLAUDE_CODE_USE_BEDROCK \
    CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY
  tmux new-session -d -s "$SESSION" -n "$WINDOW" -x 160 -y 45 -c "$WORKTREE" \
    env "CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
    "$REAL_CLAUDE" --model haiku --tools Bash --allowedTools 'Bash(sleep 180)' \
    "Bash($list_inbox)" "Bash($read_record)" "Bash($move_record)"
) \
  || live_fail 'could not launch the isolated tmux session'
fm_write_meta "$FM_HOME/state/$TASK.meta" 'backend=tmux' "window=$TARGET" 'harness=claude' \
  "endpoint_task_id=$TASK" 'kind=ship' "worktree=$WORKTREE" "project=$LAB/project"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || live_fail 'could not load the tmux backend'
wait_for_screen() {  # <verdict> <seconds>
  local i state
  for ((i=0; i<$2; i++)); do
    state=$(fm_backend_guarded_composer_state tmux "$TARGET" "$WINDOW" '' claude '' automatic)
    [ "$state" != "$1" ] || return 0
    sleep 1
  done
  live_fail "expected screen verdict '$1', last observed '$state'"
}

wait_for_transcript_marker() {  # <present|absent>
  local i screen seen
  for ((i=0; i<60; i++)); do
    if screen=$(tmux capture-pane -p -t "$TARGET") && [ -n "$screen" ]; then
      seen=absent
      if [[ "$screen" = *"$marker"* ]]; then seen=present; fi
      if [ "$seen" = "$1" ] && [ "$(fm_pane_busy_state "$TARGET" claude)" = idle ] \
        && [ "$(fm_backend_guarded_composer_state tmux "$TARGET" "$WINDOW" '' claude '' automatic)" = empty ]; then
        return 0
      fi
    fi
    sleep 1
  done
  live_fail "expected the transcript marker to be $1 with an idle composer"
}

wait_for_screen empty 60
marker="firstmate-clear-probe-$$"
tmux send-keys -t "$TARGET" -l "Reply with only OK. Transcript marker $marker"
tmux send-keys -t "$TARGET" Enter
wait_for_transcript_marker present
FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" "$TASK" /clear \
  || live_fail 'a native command did not submit from the empty composer'
wait_for_transcript_marker absent

"$ROOT/bin/fm-send.sh" "$TASK" \
  "Use these exact Bash commands to handle the doorbell. List the inbox and read this record:
$list_inbox
$read_record
Run the following command with run_in_background set to true and leave it running:
sleep 180
Then acknowledge this record with the following command and reply BACKGROUND_READY:
$move_record" \
  || live_fail 'the doorbell could not enqueue the background-task instruction'
for ((i=0; i<90; i++)); do
  [ ! -f "$inbox/handled/001.msg" ] || break
  sleep 1
done
[ -f "$inbox/handled/001.msg" ] || live_fail 'the doorbell did not reach the real worker'
wait_for_screen empty 30

# Open the modal deliberately inside the private pane. Keep the confirmation
# open while exercising all three ordinary automatic entry points.
tmux send-keys -t "$TARGET" -l /exit
tmux send-keys -t "$TARGET" Enter
wait_for_screen exit-confirm 15
out=$("$ROOT/bin/fm-send.sh" "$TASK" 'guard probe' 2>&1) \
  || live_fail "the refused doorbell should still enqueue: $out"
assert_contains "$out" 'blocked the doorbell' "Claude $VERSION: the doorbell did not report its refusal"
wait_for_screen exit-confirm 1

if out=$("$ROOT/bin/fm-send.sh" "$TASK" /help 2>&1); then
  live_fail 'the native command reported success with the dialog open'
fi
assert_contains "$out" 'text not typed' "Claude $VERSION: the native send did not refuse before typing"
wait_for_screen exit-confirm 1

if out=$("$ROOT/bin/fm-control.sh" "$TASK" interrupt 2>&1); then
  live_fail 'the recovery interrupt reported success with the dialog open'
fi
assert_contains "$out" 'interrupt-refused' "Claude $VERSION: the recovery interrupt did not report its refusal"
wait_for_screen exit-confirm 1

"$ROOT/bin/fm-send.sh" "$TASK" --key Escape || live_fail 'the explicit operator Escape was blocked'
wait_for_screen empty 15
pass "Claude $VERSION: automatic sends and recovery interrupt left the exit dialog open, and explicit Escape dismissed it"
