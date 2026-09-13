#!/usr/bin/env bash
# Live relaunch lab on a REAL tmux server (private -L socket, throwaway homes).
# Usage: live-tmux-relaunch-lab.sh <firstmate-root> <scenario>
# Scenarios:
#   group-leader    live claude stand-in with a same-group child whose PATH differs
#   exited-shell    agent already exited, shell unwound to the parent directory
#   raw-tilde       exited shell, fm-spawn --relaunch with a '~/...' raw command
#   pool-mine-live  live agent in a Treehouse pool slot it owns; exit unwinds the subshell
#   pool-stolen     same, but a successor claims the slot while the agent stops
#   pool-locked     another holder owns the project lock; pool-slot relaunch
#   nonpool-locked  another holder owns the project lock; ordinary worktree relaunch
#   exited-noclobber exited shell whose pane shell has `set -o noclobber`
#   cursor-fallback exited shell; Cursor only in ~/.local/bin, an unrelated `agent` on the pane PATH
set -u
ROOT=$(cd "$1" && pwd)
SCENARIO=$2
REAL_TMUX=$(command -v tmux)
SOCKET="fm-lab-relaunch-$$"
LAB=$(mktemp -d /tmp/fm-live-relaunch.XXXXXX)
LAB=$(cd "$LAB" && pwd -P)
ID=lab1
HOLDER_PID=
log() { printf '%s\n' "$*"; }
cleanup() {
  [ -z "$HOLDER_PID" ] || kill "$HOLDER_PID" 2>/dev/null || true
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  pkill -f "$LAB/" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB/shim" "$LAB/home/state" "$LAB/home/data/$ID" "$LAB/user-home/lab-bin" \
  "$LAB/leader-bin" "$LAB/child-bin" "$LAB/agentbin" "$LAB/parent"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
ln -s "$(command -v python3)" "$LAB/agentbin/claude"
ln -s "$(command -v sleep)" "$LAB/agentbin/codex"

# Replacement stand-ins: each records which install was launched, then stays
# alive as a process named codex so control can confirm the replacement.
for where in leader child tilde; do
  case "$where" in
    leader) bin="$LAB/leader-bin/codex" ;;
    child) bin="$LAB/child-bin/codex" ;;
    tilde) bin="$LAB/user-home/lab-bin/codex" ;;
  esac
  cat > "$bin" <<SH
#!/usr/bin/env bash
printf '%s cwd=%s argc=%s\n' $where "\$PWD" "\$#" >> "$LAB/launched"
exec "$LAB/agentbin/codex" 900
SH
  chmod +x "$bin"
done

mkdir -p "$LAB/user-home/.local/bin"
ln -s "$(command -v sleep)" "$LAB/agentbin/cursor-agent"
cat > "$LAB/user-home/.local/bin/cursor-agent" <<SH
#!/usr/bin/env bash
printf 'cursor-local-bin cwd=%s argc=%s\n' "\$PWD" "\$#" >> "$LAB/launched"
exec "$LAB/agentbin/cursor-agent" 900
SH
cat > "$LAB/leader-bin/agent" <<SH
#!/usr/bin/env bash
case "\${1:-}" in --help|-h) echo "usage: agent - an unrelated deployment helper"; exit 0 ;; esac
printf 'UNRELATED-agent-launched\n' >> "$LAB/launched"
SH
chmod +x "$LAB/user-home/.local/bin/cursor-agent" "$LAB/leader-bin/agent"

cat > "$LAB/agent.py" <<'PY'
import os, subprocess, sys
lab = sys.argv[1]
child = None
if os.environ.get("LAB_CHILD_PATH"):
    env = dict(os.environ, PATH=os.environ["LAB_CHILD_PATH"])
    child = subprocess.Popen(["/bin/sleep", "900"], env=env)
    with open(f"{lab}/child.pid", "w") as f:
        f.write(str(child.pid))
with open(f"{lab}/agent.pid", "w") as f:
    f.write(str(os.getpid()))
for line in sys.stdin:
    if "/exit" in line:
        hook = os.environ.get("LAB_EXIT_HOOK")
        if hook:
            subprocess.run(["bash", hook], check=False)
        break
if child:
    child.terminate()
    child.wait()
PY

git init -q "$LAB/proj"
printf '# lab\n' > "$LAB/proj/README.md"
git -C "$LAB/proj" add README.md
git -C "$LAB/proj" -c user.name=Lab -c user.email=lab@example.invalid commit -qm initial
git clone -q --bare "$LAB/proj" "$LAB/proj.origin.git"
git -C "$LAB/proj" remote add origin "$LAB/proj.origin.git"
case "$SCENARIO" in
  pool-*)
    WT="$LAB/pool/1/proj"
    mkdir -p "$LAB/pool/1"
    printf '{}\n' > "$LAB/pool/treehouse-state.json"
    ;;
  *) WT="$LAB/wt" ;;
esac
git -C "$LAB/proj" worktree add --quiet -b "task-$ID" "$WT"
cat > "$LAB/home/data/$ID/brief.md" <<EOF
# Task
## Captain's intent
Exercise live relaunch in a lab.

## Firstmate spec
Keep the worktree intact.
EOF
{
  echo "window=fmlab:fm-$ID"
  echo "endpoint_task_id=$ID"
  echo "worktree=$WT"
  echo "project=$LAB/proj"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
} > "$LAB/home/state/$ID.meta"

wake() {  # <bash snippet> run with fm-wake-lib sourced against the lab home
  FM_HOME="$LAB/home" STATE="$LAB/home/state" bash -c ". '$ROOT/bin/fm-wake-lib.sh'; $1"
}
LOCK=$(wake "fm_treehouse_project_lock_path '$LAB/proj'")
case "$SCENARIO" in
  pool-*) wake "fm_treehouse_slot_owner_claim '$WT' $ID '$LAB/home'" ;;
esac

PANE_PATH="$LAB/leader-bin:/usr/bin:/bin"
PANE_SHELL="env -i HOME='$LAB/user-home' PATH='$PANE_PATH' TERM=xterm-256color SHELL=/bin/bash LANG=C.UTF-8 /bin/bash --norc --noprofile -i"
env -i HOME="$LAB/user-home" PATH="$PANE_PATH" TERM=xterm-256color SHELL=/bin/bash LANG=C.UTF-8 \
  "$REAL_TMUX" -L "$SOCKET" -f /dev/null new-session -d -s fmlab -n base -x 220 -y 50 "$PANE_SHELL"
T="fmlab:fm-$ID"
tmux() { "$LAB/shim/tmux" "$@"; }
case "$SCENARIO" in
  pool-*|exited-shell|exited-noclobber|raw-tilde|cursor-fallback) start_dir="$LAB/parent" ;;
  *) start_dir="$WT" ;;
esac
tmux new-window -d -t fmlab -n "fm-$ID" -c "$start_dir" "$PANE_SHELL"
sleep 0.5

state() { PATH="$LAB/shim:$PATH" bash -c ". '$ROOT/bin/fm-backend.sh'; fm_backend_source tmux; fm_backend_tmux_agent_state '$T'"; }
pane_cwd() { tmux display-message -p -t "$T" '#{pane_current_path}'; }
wait_for() {  # <tries> <cmd...>
  local n=$1; shift
  for _ in $(seq 1 "$n"); do "$@" && return 0; sleep 0.1; done
  return 1
}
is_alive() { [ "$(state)" = alive ]; }

case "$SCENARIO" in
  pool-mine-live)
    cat > "$LAB/exit-hook.sh" <<SH
FM_HOME="$LAB/home"; STATE="$LAB/home/state"
. "$ROOT/bin/fm-wake-lib.sh"
if fm_lock_try_acquire "$LOCK"; then echo free > "$LAB/lock-at-stop"; fm_lock_release "$LOCK"; else echo "held-by-pid=\$FM_LOCK_HELD_PID" > "$LAB/lock-at-stop"; fi
SH
    ;;
  pool-stolen)
    cat > "$LAB/exit-hook.sh" <<SH
FM_HOME="$LAB/home"; STATE="$LAB/home/state"
. "$ROOT/bin/fm-wake-lib.sh"
if fm_lock_try_acquire "$LOCK"; then
  fm_treehouse_slot_owner_claim "$WT" successor "$LAB/home" && echo "successor-claimed-under-lock" > "$LAB/lock-at-stop"
  fm_lock_release "$LOCK"
else
  echo "held-by-pid=\$FM_LOCK_HELD_PID (successor could not take the slot)" > "$LAB/lock-at-stop"
fi
SH
    ;;
esac

case "$SCENARIO" in
  group-leader|nonpool-locked|pool-locked)
    agent_cmd="LAB_CHILD_PATH='$LAB/child-bin:/usr/bin:/bin' '$LAB/agentbin/claude' '$LAB/agent.py' '$LAB'"
    [ "$SCENARIO" = pool-locked ] && agent_cmd="( cd '$WT' && LAB_CHILD_PATH='$LAB/child-bin:/usr/bin:/bin' exec '$LAB/agentbin/claude' '$LAB/agent.py' '$LAB' )"
    tmux send-keys -t "$T" -l "$agent_cmd"; tmux send-keys -t "$T" Enter
    wait_for 50 is_alive || { log "SETUP FAIL: stand-in agent not alive ($(state))"; exit 2; }
    ;;
  pool-mine-live|pool-stolen)
    agent_cmd="( cd '$WT' && LAB_EXIT_HOOK='$LAB/exit-hook.sh' exec '$LAB/agentbin/claude' '$LAB/agent.py' '$LAB' )"
    tmux send-keys -t "$T" -l "$agent_cmd"; tmux send-keys -t "$T" Enter
    wait_for 50 is_alive || { log "SETUP FAIL: stand-in agent not alive ($(state))"; exit 2; }
    ;;
  exited-shell|exited-noclobber|raw-tilde|cursor-fallback)
    if [ "$SCENARIO" = exited-noclobber ]; then
      tmux send-keys -t "$T" -l "set -o noclobber"; tmux send-keys -t "$T" Enter
    fi
    # The agent ran inside a treehouse-style subshell and exited; the shell unwound.
    tmux send-keys -t "$T" -l "( cd '$WT' && exec '$LAB/agentbin/claude' -c 'pass' )"; tmux send-keys -t "$T" Enter
    sleep 0.5
    ;;
esac
case "$SCENARIO" in
  pool-locked|nonpool-locked)
    FM_HOME="$LAB/home" STATE="$LAB/home/state" bash -c ". '$ROOT/bin/fm-wake-lib.sh'; fm_lock_try_acquire '$LOCK' || exit 1; exec sleep 600" &
    HOLDER_PID=$!
    wait_for 30 test -f "$LOCK/pid" || { log "SETUP FAIL: holder did not take the project lock"; exit 2; }
    ;;
esac

log "== live tmux relaunch lab: scenario=$SCENARIO root=$ROOT"
log "tmux: $("$REAL_TMUX" -V) socket=-L $SOCKET"
log "recorded worktree: $WT"
[ -f "$LAB/agent.pid" ] && log "old agent pid: $(cat "$LAB/agent.pid")"
if [ -f "$LAB/child.pid" ]; then
  log "pane foreground group before relaunch (pid pgid tpgid comm):"
  tty=$(tmux display-message -p -t "$T" '#{pane_tty}')
  ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= | sed 's/^/  /'
  log "leader PATH: $(tr '\0' '\n' < /proc/"$(cat "$LAB/agent.pid")"/environ | sed -n 's/^PATH=//p')"
  log "child  PATH: $(tr '\0' '\n' < /proc/"$(cat "$LAB/child.pid")"/environ | sed -n 's/^PATH=//p')"
fi
shell_pid=$(tmux display-message -p -t "$T" '#{pane_pid}')
log "pane shell PATH: $(tr '\0' '\n' < /proc/"$shell_pid"/environ | sed -n 's/^PATH=//p'); pane shell HOME: $(tr '\0' '\n' < /proc/"$shell_pid"/environ | sed -n 's/^HOME=//p')"
log "pane state before: $(state); pane cwd before: $(pane_cwd)"
[ -f "$LOCK/pid" ] && log "project lock held before relaunch by pid $(cat "$LOCK/pid")"
[ -f "$LAB/pool/1/.fm-slot-owner" ] && log "slot claim before: $(tr '\n' ' ' < "$LAB/pool/1/.fm-slot-owner")"

common_env=(env PATH="$LAB/shim:$PATH" FM_HOME="$LAB/home" HOME="$LAB/user-home" CLAUDE_CONFIG_DIR=
  CODEX_HOME="$LAB/user-home/.codex" GROK_HOME="$LAB/grokhome" FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1
  FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=15 FM_CONTROL_LAUNCH_WAIT=20)
if [ "$SCENARIO" = raw-tilde ]; then
  log "\$ bin/fm-spawn.sh $ID --relaunch --harness '~/lab-bin/codex --lab-flag'"
  mkdir -p "$LAB/spawn-home"
  log "(fm-spawn runs with HOME=$LAB/spawn-home; the pane shell HOME is $LAB/user-home)"
  out=$("${common_env[@]}" HOME="$LAB/spawn-home" "$ROOT/bin/fm-spawn.sh" "$ID" --relaunch --harness '~/lab-bin/codex --lab-flag' 2>&1); rc=$?
else
  harness=codex
  [ "$SCENARIO" = cursor-fallback ] && harness=cursor
  [ "$SCENARIO" = cursor-fallback ] && log "pane PATH has an unrelated agent: $(command -v -p true >/dev/null; ls "$LAB/leader-bin"); Cursor install: $LAB/user-home/.local/bin/cursor-agent (not on the pane PATH)"
  log "\$ bin/fm-control.sh $ID relaunch --harness $harness --note 'Live lab relaunch.'"
  out=$("${common_env[@]}" "$ROOT/bin/fm-control.sh" "$ID" relaunch --harness "$harness" --note 'Live lab relaunch.' 2>&1); rc=$?
fi
log "$out"
log "exit code: $rc"
wait_for 50 test -s "$LAB/launched" || true
sleep 0.5
log "-- after --"
log "pane state after: $(state); pane cwd after: $(pane_cwd)"
if [ -f "$LAB/agent.pid" ]; then
  if kill -0 "$(cat "$LAB/agent.pid")" 2>/dev/null; then log "old agent: STILL RUNNING"; else log "old agent: stopped"; fi
fi
if [ -s "$LAB/launched" ]; then log "replacement launched: $(cat "$LAB/launched")"; else log "replacement launched: NONE"; fi
[ -f "$LAB/lock-at-stop" ] && log "project lock observed while the old agent was stopping: $(cat "$LAB/lock-at-stop")"
if [ -e "$LOCK" ]; then log "project lock after: present (pid $(cat "$LOCK/pid" 2>/dev/null))"; else log "project lock after: released"; fi
[ -f "$LAB/pool/1/.fm-slot-owner" ] && log "slot claim after: $(tr '\n' ' ' < "$LAB/pool/1/.fm-slot-owner")"
log "recorded harness after: $(sed -n 's/^harness=//p' "$LAB/home/state/$ID.meta" | tail -1)"
log "pane screen (last lines):"
tmux capture-pane -p -t "$T" -S -12 | sed '/^$/d' | tail -12 | sed 's/^/  | /'
exit 0
