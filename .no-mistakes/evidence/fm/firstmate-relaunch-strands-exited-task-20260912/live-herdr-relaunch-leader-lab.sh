#!/usr/bin/env bash
# Live relaunch of a LIVE agent on a REAL Herdr server, in a private fm-lab-*
# session (bin/fm-herdr-lab.sh contract). The stand-in agent (a process named
# claude) runs a same-process-group child whose PATH names a decoy codex.
# Usage: live-herdr-relaunch-leader-lab.sh <firstmate-root> <lab-name-suffix>
set -u
ROOT=$(cd "$1" && pwd)
TESTS_ROOT=/home/jason/.no-mistakes/worktrees/e95238b70e4e/01M2DPX9WYSYV8N9CRFCNRVDRH
# shellcheck source=/dev/null
. "$TESTS_ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
SESSION="fm-lab-relaunch-leader-$2-$$"
export HERDR_SESSION="$SESSION"
LAB=$(mktemp -d /tmp/fm-live-herdr-relaunch.XXXXXX)
LAB=$(cd "$LAB" && pwd -P)
ID=hlab
log() { printf '%s\n' "$*"; }
cleanup() {
  herdr_safe_stop_and_delete "$SESSION" >/dev/null 2>&1 || true
  pkill -f "$LAB/" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT
fm_herdr_lab_prepare "$SESSION" || { log "SETUP FAIL: lab prepare"; exit 2; }

mkdir -p "$LAB/home/state" "$LAB/home/data/$ID" "$LAB/user-home" "$LAB/leader-bin" "$LAB/child-bin" "$LAB/agentbin"
ln -s "$(command -v python3)" "$LAB/agentbin/claude"
ln -s "$(command -v sleep)" "$LAB/agentbin/codex"
for where in leader child; do
  cat > "$LAB/$where-bin/codex" <<SH
#!/usr/bin/env bash
printf '%s cwd=%s argc=%s\n' $where "\$PWD" "\$#" >> "$LAB/launched"
exec "$LAB/agentbin/codex" 900
SH
  chmod +x "$LAB/$where-bin/codex"
done
cat > "$LAB/agent.py" <<'PY'
import os, subprocess, sys
lab = sys.argv[1]
env = dict(os.environ, PATH=os.environ["LAB_CHILD_PATH"])
child = subprocess.Popen(["/bin/sleep", "900"], env=env)
open(f"{lab}/child.pid", "w").write(str(child.pid))
open(f"{lab}/agent.pid", "w").write(str(os.getpid()))
for line in sys.stdin:
    if "/exit" in line:
        break
child.terminate()
child.wait()
PY

git init -q "$LAB/proj"
printf '# lab\n' > "$LAB/proj/README.md"
git -C "$LAB/proj" add README.md
git -C "$LAB/proj" -c user.name=Lab -c user.email=lab@example.invalid commit -qm initial
WT="$LAB/wt"
git -C "$LAB/proj" worktree add --quiet -b "task-$ID" "$WT"
cat > "$LAB/home/data/$ID/brief.md" <<EOF
# Task
## Captain's intent
Exercise live Herdr relaunch in a lab.

## Firstmate spec
Keep the worktree intact.
EOF

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || { log "SETUP FAIL: backend"; exit 2; }
CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || { log "SETUP FAIL: container"; exit 2; }
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
read -r TAB_ID PANE_ID <<EOF
$(fm_backend_herdr_create_task "$CONTAINER" "fm-$ID" "$WT" "$SEEDED_TAB_ID")
EOF
{
  echo "window=$SESSION:$PANE_ID"
  echo "endpoint_task_id=$ID"
  echo "worktree=$WT"
  echo "project=$LAB/proj"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$LAB/home/state/$ID.meta"

T="$SESSION:$PANE_ID"
send() { fm_backend_herdr_send_text_line "$T" "$1"; }
# A clean, known pane environment: no host PATH, so no real harness can resolve.
send "exec env -i HOME='$LAB/user-home' PATH='$LAB/leader-bin:/usr/bin:/bin' TERM=xterm-256color LANG=C.UTF-8 /bin/bash --norc --noprofile -i"
sleep 1
send "LAB_CHILD_PATH='$LAB/child-bin:/usr/bin:/bin' '$LAB/agentbin/claude' '$LAB/agent.py' '$LAB'"
for _ in $(seq 1 50); do
  [ "$(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")" = agent ] && break
  sleep 0.1
done
herdr pane report-agent "$PANE_ID" --source fm-live-lab --agent fm-live-lab-agent --state idle --session "$SESSION" >/dev/null 2>&1 \
  || { log "SETUP FAIL: report-agent"; exit 2; }

log "== live Herdr relaunch lab (live agent + same-group child) root=$ROOT"
log "herdr: $(herdr --version 2>&1 | head -1) session=$SESSION pane=$PANE_ID"
log "recorded worktree: $WT"
log "agent state before: $(fm_backend_agent_state herdr "$T")"
log "herdr pane process-info foreground_processes (pid name) with kernel pgid:"
herdr pane process-info --pane "$PANE_ID" --session "$SESSION" 2>/dev/null \
  | jq -r '.result.process_info.foreground_processes[] | "\(.pid) \(.name)"' \
  | while read -r pid name; do printf '  pid=%s name=%s pgid=%s PATH=%s\n' "$pid" "$name" \
      "$(ps -o pgid= -p "$pid" | tr -d ' ')" "$(tr '\0' '\n' < /proc/"$pid"/environ 2>/dev/null | sed -n 's/^PATH=//p')"; done
log "child pid (from the stand-in): $(cat "$LAB/child.pid") pgid=$(ps -o pgid= -p "$(cat "$LAB/child.pid")" | tr -d ' ') PATH=$(tr '\0' '\n' < /proc/"$(cat "$LAB/child.pid")"/environ | sed -n 's/^PATH=//p')"
log "pane cwd before: $(fm_backend_herdr_current_path "$T")"

log "\$ bin/fm-control.sh $ID relaunch --harness codex --note 'Live Herdr lab relaunch.'"
# Real HOME, as tests/fm-control-herdr-smoke.test.sh does: the herdr client finds its lab server through ~/.config/herdr.
out=$(env FM_HOME="$LAB/home" HERDR_SESSION="$SESSION" \
  CODEX_HOME="$LAB/user-home/.codex" GROK_HOME="$LAB/grokhome" FM_SPAWN_NO_GUARD=1 \
  FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=15 FM_CONTROL_LAUNCH_WAIT=20 \
  "$ROOT/bin/fm-control.sh" "$ID" relaunch --harness codex --note 'Live Herdr lab relaunch.' 2>&1); rc=$?
log "$out"
log "exit code: $rc"
for _ in $(seq 1 30); do [ -s "$LAB/launched" ] && break; sleep 0.1; done
log "-- after --"
log "agent state after: $(fm_backend_agent_state herdr "$T")"
log "pane cwd after: $(fm_backend_herdr_current_path "$T")"
if kill -0 "$(cat "$LAB/agent.pid")" 2>/dev/null; then log "old agent: STILL RUNNING"; else log "old agent: stopped"; fi
if [ -s "$LAB/launched" ]; then log "replacement launched: $(cat "$LAB/launched")"; else log "replacement launched: NONE"; fi
log "recorded harness after: $(sed -n 's/^harness=//p' "$LAB/home/state/$ID.meta" | tail -1)"
herdr pane get "$PANE_ID" --session "$SESSION" >/dev/null 2>&1 && log "endpoint reused: yes ($PANE_ID)" || log "endpoint reused: NO"
log "pane screen (last lines):"
fm_backend_herdr_capture "$T" 14 2>/dev/null | sed '/^[[:space:]]*$/d' | tail -8 | cut -c1-200 | sed 's/^/  | /'
