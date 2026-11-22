#!/usr/bin/env bash
# Public-interface regressions for primary cold boot and readiness. All terminal
# commands and process views are fakes; the only real process is a sleep used
# as a live PID for the existing session-lock owner's kill-0 checks.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-primary-start)
CODE="$TMP_ROOT/code"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$CODE" "$FAKEBIN"
cp -R "$ROOT/bin" "$CODE/"
cp "$ROOT/tests/primary-start-herdr-fixture.py" "$FAKEBIN/herdr"
cp "$ROOT/tests/primary-start-herdr-fixture.py" "$FAKEBIN/ps"
chmod +x "$FAKEBIN/herdr" "$FAKEBIN/ps" "$CODE/bin/fm-primary-start.sh"
printf '#!/bin/sh\nexit 99\n' > "$FAKEBIN/claude"
chmod +x "$FAKEBIN/claude"
sleep 240 &
FM_PRIMARY_TEST_PID=$!
export FM_PRIMARY_TEST_PID
cleanup() { kill "$FM_PRIMARY_TEST_PID" 2>/dev/null || true; fm_test_cleanup; }
trap cleanup EXIT
export PATH="$FAKEBIN:$PATH"
export FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1
export FM_PRIMARY_TEST_STATE="$TMP_ROOT/server.json"
export FM_PRIMARY_TEST_LOG="$TMP_ROOT/cli.jsonl"
BIN="$CODE/bin/fm-primary-start.sh"
HOME_FIXTURE="$TMP_ROOT/home with spaces"
mkdir -p "$HOME_FIXTURE/state" "$HOME_FIXTURE/data" "$HOME_FIXTURE/config" "$HOME_FIXTURE/.claude"
git -C "$HOME_FIXTURE" init -q
ln -s "$CODE/bin" "$HOME_FIXTURE/bin"
: > "$HOME_FIXTURE/AGENTS.md"
cp "$ROOT/.claude/settings.json" "$HOME_FIXTURE/.claude/settings.json"

reset_world() {
  python3 - "$HOME_FIXTURE" <<'PY'
from pathlib import Path
import json, os
home = Path(__import__('sys').argv[1])
for directory in ('state', 'config', 'data'):
    for entry in (home/directory).iterdir():
        if entry.is_file() or entry.is_symlink():
            entry.unlink()
Path(os.environ['FM_PRIMARY_TEST_STATE']).write_text(json.dumps({'workspaces': [], 'panes': []}))
Path(os.environ['FM_PRIMARY_TEST_LOG']).write_text('')
PY
}
world() { python3 - "$@" <<'PY'
import json, os, sys
from pathlib import Path
p=Path(os.environ['FM_PRIMARY_TEST_STATE']); s=json.loads(p.read_text())
for arg in sys.argv[1:]:
    key,value=arg.split('=',1)
    s[key]=json.loads(value)
p.write_text(json.dumps(s))
PY
}
helm() { "$BIN" "$1" --home "$HOME_FIXTURE" --backend herdr --harness claude --session fixture "${@:2}"; }
capture() {
  RC=0
  OUT=$(helm "$@" 2>&1) || RC=$?
}
expect_rc() { [ "$RC" = "$1" ] || fail "expected exit $1, got $RC: $OUT"; }
contains() { case "$OUT" in *"$1"*) ;; *) fail "missing '$1': $OUT" ;; esac; }
no_mutation() {
  python3 - <<'PY'
import json, os
rows=[json.loads(l)['args'] for l in open(os.environ['FM_PRIMARY_TEST_LOG'])]
assert not any(r[0]=='server' or r[:2] in [['workspace','create'],['tab','create'],['pane','run'],['agent','rename']] for r in rows), rows
PY
}
initialize_primary() {
  local identity
  identity=$(FM_WAKE_NO_MKDIR=1 FM_HOME="$HOME_FIXTURE" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_pid_identity "$2"' _ "$ROOT" "$FM_PRIMARY_TEST_PID")
  identity=$(printf '%s' "$identity" | base64 | tr -d '\r\n')
  printf '%s\n' "$FM_PRIMARY_TEST_PID" > "$HOME_FIXTURE/state/.lock"
  printf '%s\n' "$FM_PRIMARY_TEST_PID" > "$HOME_FIXTURE/state/.session-start-complete"
  cat > "$HOME_FIXTURE/state/.startup-network.status" <<EOF
state=done
rc=0
locked=1
lock_pid=$FM_PRIMARY_TEST_PID
lock_identity=$identity
generation=fixture-generation
phases=probe,sweeps
report_published=1
EOF
  : > "$HOME_FIXTURE/state/.startup-network.report"
}

reset_world
capture start
expect_rc 0
contains 'agent_detected=true'
contains 'primary_initialized=false'
python3 - "$HOME_FIXTURE" <<'PY'
import json, os, shlex, sys
s=json.load(open(os.environ['FM_PRIMARY_TEST_STATE']))
argv=shlex.split(s['submitted'])
assert sys.argv[1] in argv and 'FM_HOME='+sys.argv[1] in argv, argv
assert '--dangerously-skip-permissions' in argv and '--permission-mode' not in argv
assert argv[-1].count('Take the primary role') == 1 and 'recovery_ready=true' in argv[-1]
assert 'FM_TASK_ID' in argv and 'CLAUDECODE' in argv and 'FM_ROOT_OVERRIDE' in argv
rows=[json.loads(l)['args'] for l in open(os.environ['FM_PRIMARY_TEST_LOG'])]
assert sum(r[:2]==['pane','run'] for r in rows)==1
assert any(r[:2]==['workspace','create'] and r[r.index('--label')+1]=='firstmate' for r in rows)
assert any(r[:2]==['agent','rename'] and r[-1]=='helm' for r in rows)
assert not any(r[:2] in [['agent','prompt'],['agent','send-keys'],['pane','send-keys']] for r in rows)
PY
pass 'fresh boot submits one environment-bound interactive Claude launch and distinguishes initialization'

: > "$FM_PRIMARY_TEST_LOG"
capture start
expect_rc 0
no_mutation
pass 'repeated start recognizes the live home primary without sending another prompt'

reset_world
world "workspaces=[{\"workspace_id\":\"w1\",\"label\":\"firstmate\"}]" \
  "panes=[{\"pane_id\":\"w1:p1\",\"workspace_id\":\"w1\",\"tab_id\":\"w1:t1\",\"terminal_id\":\"unrelated\",\"cwd\":\"$HOME_FIXTURE\",\"active\":true}]" \
  rename_fail_once=true
capture start
expect_rc 2
contains 'naming failed'
python3 - "$HOME_FIXTURE/state/.primary-start" <<'PY'
import sys
fields = dict(line.split('=', 1) for line in open(sys.argv[1]).read().splitlines())
assert fields['phase'] == 'detecting'
PY
capture start
expect_rc 0
python3 - "$HOME_FIXTURE/state/.primary-start" <<'PY'
import json, os, shlex, sys
s=json.load(open(os.environ['FM_PRIMARY_TEST_STATE']))
rows=[json.loads(l)['args'] for l in open(os.environ['FM_PRIMARY_TEST_LOG'])]
fields=dict(line.split('=', 1) for line in open(sys.argv[1]).read().splitlines())
assert fields['phase']=='launched' and fields['pane']=='w1:p2'
assert len(s['panes'])==2 and s['panes'][0].get('agent_name') is None
assert s['panes'][1]['agent_name']=='helm'
assert sum(r[:2]==['pane','run'] for r in rows)==1
assert sum(r[:2]==['tab','create'] for r in rows)==1
assert [r[2] for r in rows if r[:2]==['agent','rename']]==['w1:p2','w1:p2']
assert shlex.split(s['submitted'])[-1].count('Take the primary role')==1
PY
pass 'retry finishes the pending helm name without relaunching or touching another agent'

reset_world
world "workspaces=[{\"workspace_id\":\"w1\",\"label\":\"firstmate\"}]" \
  "panes=[{\"pane_id\":\"w1:p1\",\"workspace_id\":\"w1\",\"tab_id\":\"w1:t1\",\"terminal_id\":\"unrelated\",\"cwd\":\"$HOME_FIXTURE\",\"active\":true}]"
capture ready
expect_rc 1
contains 'agent_detected=false'
no_mutation
capture start
expect_rc 0
python3 - <<'PY'
import json, os
s=json.load(open(os.environ['FM_PRIMARY_TEST_STATE']))
rows=[json.loads(l)['args'] for l in open(os.environ['FM_PRIMARY_TEST_LOG'])]
assert len(s['panes'])==2 and all(p['active'] for p in s['panes'])
assert s['panes'][0]['terminal_id']=='unrelated'
assert [r[2] for r in rows if r[:2] in (['pane','run'],['agent','rename'])]==['w1:p2','w1:p2']
PY
pass 'an unrelated home Claude is preserved while a fresh helm pane is launched'

reset_world
world "workspaces=[{\"workspace_id\":\"w1\",\"label\":\"firstmate\"}]" \
  "panes=[{\"pane_id\":\"w1:p1\",\"workspace_id\":\"w1\",\"tab_id\":\"w1:t1\",\"terminal_id\":\"unrelated-busy\",\"cwd\":\"$HOME_FIXTURE\",\"active\":true,\"process\":\"python\"}]"
capture ready
expect_rc 1
contains 'agent_detected=false'
no_mutation
capture start
expect_rc 0
python3 - <<'PY'
import json, os
s=json.load(open(os.environ['FM_PRIMARY_TEST_STATE']))
rows=[json.loads(l)['args'] for l in open(os.environ['FM_PRIMARY_TEST_LOG'])]
assert len(s['panes'])==2 and s['panes'][0]['active'] and s['panes'][0]['process']=='python'
assert s['panes'][1]['active']
assert [r[2] for r in rows if r[:2] in (['pane','run'],['agent','rename'])]==['w1:p2','w1:p2']
PY
pass 'an unrelated busy Claude is preserved while a fresh helm pane is launched'

reset_world
world "workspaces=[{\"workspace_id\":\"w1\",\"label\":\"personal\"}]" \
  "panes=[{\"pane_id\":\"w1:p1\",\"workspace_id\":\"w1\",\"tab_id\":\"w1:t1\",\"terminal_id\":\"personal-agent\",\"cwd\":\"$HOME_FIXTURE\",\"active\":true}]"
capture start
expect_rc 0
python3 - <<'PY'
import json, os
s=json.load(open(os.environ['FM_PRIMARY_TEST_STATE']))
rows=[json.loads(l)['args'] for l in open(os.environ['FM_PRIMARY_TEST_LOG'])]
assert s['workspaces']==[{'workspace_id':'w1','label':'personal'},{'workspace_id':'w2','label':'firstmate'}]
assert s['panes'][0]['active'] and s['panes'][0]['terminal_id']=='personal-agent'
assert s['panes'][1]['active'] and s['panes'][1]['workspace_id']=='w2'
assert not any(r[:2]==['tab','create'] or r[:3]==['agent','rename','w1:p1'] for r in rows)
PY
pass 'a personal workspace at the primary home is not adopted'

reset_world
world "workspaces=[{\"workspace_id\":\"w1\",\"label\":\"FirstMate\"}]" \
  "panes=[{\"pane_id\":\"w1:p1\",\"workspace_id\":\"w1\",\"tab_id\":\"w1:t1\",\"terminal_id\":\"renamed-utility\",\"cwd\":\"$HOME_FIXTURE\",\"active\":false}]"
capture start
expect_rc 0
python3 - <<'PY'
import json, os
s=json.load(open(os.environ['FM_PRIMARY_TEST_STATE']))
assert s['workspaces']==[{'workspace_id':'w1','label':'FirstMate'},{'workspace_id':'w2','label':'firstmate'}]
assert not s['panes'][0]['active'] and s['panes'][1]['active']
assert s['panes'][1]['workspace_id']=='w2'
PY
pass 'a display-renamed helm workspace does not collide or get adopted'

reset_world
world launch_process='"python"'
capture start
expect_rc 0
contains 'agent_detected=true'
contains 'primary_initialized=false'
: > "$FM_PRIMARY_TEST_LOG"
capture start
expect_rc 0
no_mutation
pass 'a terminal-bound launch receipt proves the new helm during a foreground tool'

reset_world
world "workspaces=[{\"workspace_id\":\"w1\",\"label\":\"firstmate\"}]" \
  "panes=[{\"pane_id\":\"w1:p1\",\"workspace_id\":\"w1\",\"tab_id\":\"w1:t1\",\"terminal_id\":\"recycled\",\"cwd\":\"$HOME_FIXTURE\",\"active\":true}]"
cat > "$HOME_FIXTURE/state/.primary-start" <<EOF
phase=launched
home=$HOME_FIXTURE
session=fixture
workspace=w1
pane=w1:p1
terminal=original
EOF
capture ready
expect_rc 1
contains 'agent_detected=false'
capture start
expect_rc 0
python3 - <<'PY'
import json, os
s=json.load(open(os.environ['FM_PRIMARY_TEST_STATE']))
assert len(s['panes'])==2 and s['panes'][0]['active'] and s['panes'][0]['terminal_id']=='recycled'
assert s['panes'][1]['active']
PY
pass 'a recycled pane id without the recorded terminal cannot prove primary identity'

reset_world
world "workspaces=[{\"workspace_id\":\"w1\",\"label\":\"firstmate\"}]" \
  "panes=[{\"pane_id\":\"w1:p1\",\"workspace_id\":\"w1\",\"tab_id\":\"w1:t1\",\"terminal_id\":\"locked\",\"cwd\":\"$HOME_FIXTURE\",\"active\":true}]"
initialize_primary
capture ready
expect_rc 0
contains 'agent_detected=true'
contains 'primary_initialized=true'
: > "$FM_PRIMARY_TEST_LOG"
capture start
expect_rc 0
no_mutation
pass 'a live session lock proves the exact primary pane without a launch receipt'

reset_world
world "workspaces=[{\"workspace_id\":\"w1\",\"label\":\"firstmate\"}]" \
  "panes=[{\"pane_id\":\"w1:p1\",\"workspace_id\":\"w1\",\"tab_id\":\"w1:t1\",\"terminal_id\":\"locked-busy\",\"cwd\":\"$HOME_FIXTURE\",\"active\":true,\"process\":\"python\"}]"
initialize_primary
capture ready
expect_rc 0
contains 'agent_detected=true'
contains 'primary_initialized=true'
contains 'recovery_ready=true'
: > "$FM_PRIMARY_TEST_LOG"
capture start
expect_rc 0
no_mutation
pass 'a lock-proven busy helm remains ready without another launch'

reset_world
printf 'auto\n' > "$HOME_FIXTURE/config/claude-permission-mode"
world running=false
capture start
expect_rc 0
python3 - <<'PY'
import json, os, shlex
s=json.load(open(os.environ['FM_PRIMARY_TEST_STATE']))
a=shlex.split(s['submitted']); assert '--permission-mode' in a and 'auto' in a and '--dangerously-skip-permissions' not in a
r=[json.loads(l) for l in open(os.environ['FM_PRIMARY_TEST_LOG'])]
server=next(x for x in r if x['args']==['server'])
assert server['fm_home'] is None and server['claudecode'] is None,server
PY
pass 'auto mode and the existing cleaned server-start owner are used'

for invalid in nope empty dangling; do
  reset_world
  case "$invalid" in
    nope) printf 'nope\n' > "$HOME_FIXTURE/config/claude-permission-mode" ;;
    empty) : > "$HOME_FIXTURE/config/claude-permission-mode" ;;
    dangling) ln -s "$TMP_ROOT/absent" "$HOME_FIXTURE/config/claude-permission-mode" ;;
  esac
  capture start
  expect_rc 2
  no_mutation
done
pass 'invalid, empty and dangling permission policy refuse before terminal mutation'

reset_world
printf '%s\n' "$FM_PRIMARY_TEST_PID" > "$HOME_FIXTURE/state/.lock"
capture start
expect_rc 2
no_mutation
[ "$(sed -n '1p' "$HOME_FIXTURE/state/.lock")" = "$FM_PRIMARY_TEST_PID" ] || fail 'lock changed'
pass 'a live harness lock without a matching primary refuses and preserves ownership'

reset_world
printf 'invalid\n' > "$HOME_FIXTURE/state/.lock"
capture start
expect_rc 2
no_mutation
pass 'malformed session ownership fails closed'

reset_world
world compatible=false
capture start
expect_rc 2
no_mutation
pass 'an incompatible server is preserved without restart'

reset_world
world "workspaces=[{\"workspace_id\":\"w1\",\"label\":\"firstmate\"}]" \
  "panes=[{\"pane_id\":\"w1:p1\",\"workspace_id\":\"w1\",\"tab_id\":\"w1:t1\",\"terminal_id\":\"old-utility\",\"cwd\":\"$HOME_FIXTURE\",\"active\":false}]"
capture start
expect_rc 0
python3 - <<'PY'
import json,os
s=json.load(open(os.environ['FM_PRIMARY_TEST_STATE']))
assert not s['panes'][0]['active'] and s['panes'][1]['active']
assert len(s['workspaces'])==1
PY
pass 'restored home workspace gets a fresh launch tab while its utility shell is preserved'

reset_world
world "workspaces=[{\"workspace_id\":\"w1\",\"label\":\"firstmate\"}]"
capture start
expect_rc 0
python3 - <<'PY'
import json, os
s=json.load(open(os.environ['FM_PRIMARY_TEST_STATE']))
assert s['workspaces']==[{'workspace_id':'w1','label':'firstmate'},{'workspace_id':'w2','label':'firstmate'}]
assert len(s['panes'])==1 and s['panes'][0]['workspace_id']=='w2' and s['panes'][0]['active']
PY
pass 'a matching label without home evidence gets a fresh primary workspace'

reset_world
world change_terminal=true
capture start
expect_rc 2
python3 - <<'PY'
import json,os
s=json.load(open(os.environ['FM_PRIMARY_TEST_STATE']))
assert 'submitted' not in s
PY
pass 'a changed terminal between creation and submission prevents command delivery'

reset_world
world lost_create=true
capture start
expect_rc 2
: > "$FM_PRIMARY_TEST_LOG"
capture start
expect_rc 2
no_mutation
contains 'prior create outcome is unknown'
pass 'a lost create response retains uncertainty and prevents duplicate creation on retry'

reset_world
world stall=true
export FM_PRIMARY_TEST_DATE_COUNT="$TMP_ROOT/date-count"
cat > "$FAKEBIN/date" <<'SH'
#!/bin/sh
if [ "$1" = '+%s' ]; then
  count=$(cat "$FM_PRIMARY_TEST_DATE_COUNT" 2>/dev/null || printf 0)
  count=$((count + 31))
  printf '%s\n' "$count" > "$FM_PRIMARY_TEST_DATE_COUNT"
  printf '%s\n' "$count"
else
  /bin/date "$@"
fi
SH
chmod +x "$FAKEBIN/date"
capture start
expect_rc 2
: > "$FM_PRIMARY_TEST_LOG"
capture start
expect_rc 2
no_mutation
contains 'prior launch may still be queued'
rm "$FAKEBIN/date"
pass 'a timed-out launch is not resubmitted into its retained shell'

reset_world
world running=false
capture ready
expect_rc 1
contains 'agent_detected=false'
no_mutation
pass 'ready never starts a stopped server'

reset_world
capture start
expect_rc 0
initialize_primary
: > "$FM_PRIMARY_TEST_LOG"
capture ready
expect_rc 0
contains 'primary_initialized=true'
contains 'recovery_ready=true'
contains 'supervision_healthy=true'
no_mutation
pass 'current initialized generation with no mates or supervision demand is ready'

printf 'kind=ship\n' > "$HOME_FIXTURE/state/ordinary.meta"
capture ready
expect_rc 0
contains 'recovery_ready=true'
contains 'supervision_healthy=false'
pass 'recovery readiness and first-Stop supervision health are independent'

for bad in running failed stale-owner probe-only recycled-pid; do
  initialize_primary
  case "$bad" in
    running) printf 'state=running\n' >> "$HOME_FIXTURE/state/.startup-network.status" ;;
    failed) printf 'state=failed\nrc=1\n' >> "$HOME_FIXTURE/state/.startup-network.status" ;;
    stale-owner) printf 'lock_pid=99999999\n' >> "$HOME_FIXTURE/state/.startup-network.status" ;;
    probe-only) printf 'locked=0\nphases=probe\n' >> "$HOME_FIXTURE/state/.startup-network.status" ;;
    recycled-pid) printf 'lock_identity=old-process\n' >> "$HOME_FIXTURE/state/.startup-network.status" ;;
  esac
  capture ready
  expect_rc 1
  contains 'recovery_ready=false'
done
pass 'unfinished, failed, stale-owner, recycled-pid and probe-only generations do not satisfy the gate'

initialize_primary
mkdir -p "$TMP_ROOT/mate"
printf -- '- mate - Test (home: %s; scope: tests; projects: none; added 2026-11-14)\n' "$TMP_ROOT/mate" > "$HOME_FIXTURE/data/secondmates.md"
capture ready
expect_rc 1
contains 'no valid route metadata'
cat > "$HOME_FIXTURE/state/mate.meta" <<EOF
kind=secondmate
harness=claude
backend=herdr
window=fixture:w2:p1
herdr_session=fixture
herdr_pane_id=w2:p1
herdr_tab_id=w2:t1
home=$TMP_ROOT/mate
herdr_workspace_id=w2
EOF
capture ready
expect_rc 1
contains 'home-bound secondmate recovery support is not installed'
contains 'recovery unverified'
contains 'primary_initialized=true'
contains 'supervision_healthy=false'
pass 'registered missing mates and unavailable home-binding support keep layout gated'

# The separate recovery change supplies this API. Model its public contract
# here without incorporating or altering its out-of-scope implementation.
cat >> "$CODE/bin/backends/herdr.sh" <<'SH'
fm_backend_herdr_pane_home_state() { printf '%s' "${FM_PRIMARY_TEST_HOME_STATE:-match}"; }
SH
world "workspaces=[{\"workspace_id\":\"w1\",\"label\":\"firstmate\"},{\"workspace_id\":\"w2\",\"label\":\"mate\"}]" \
  "panes=[{\"pane_id\":\"w1:p1\",\"workspace_id\":\"w1\",\"tab_id\":\"w1:t1\",\"terminal_id\":\"primary\",\"cwd\":\"$HOME_FIXTURE\",\"active\":true},{\"pane_id\":\"w2:p1\",\"workspace_id\":\"w2\",\"tab_id\":\"w2:t1\",\"terminal_id\":\"mate\",\"cwd\":\"$TMP_ROOT/mate\",\"active\":true}]"
capture ready
expect_rc 0
FM_PRIMARY_TEST_HOME_STATE=mismatch capture ready
expect_rc 1
contains 'recovery_ready=false'
pass 'only the existing home-binding owner can establish a recovered mate endpoint'

reset_world
capture start --harness codex
expect_rc 2
capture start --backend tmux
expect_rc 2
for option in --workspace-label --agent-name --timeout; do
  capture start "$option" unused
  expect_rc 2
  contains "unknown option $option"
done
no_mutation
pass 'unsupported primary harnesses and backends refuse before mutation'

reset_world
world delay_create=1
helm start > "$TMP_ROOT/first-start.out" 2>&1 &
first_start=$!
for _ in $(seq 1 200); do
  [ ! -f "$HOME_FIXTURE/state/.primary-start.lock/pid" ] || break
  sleep 0.01
done
capture start
expect_rc 2
contains 'another primary launch is in progress'
wait "$first_start" || fail 'first concurrent start failed'
pass 'simultaneous starts serialize before workspace creation'

reset_world
capture start
expect_rc 0
initialize_primary
cat > "$CODE/bin/fm-on.sh" <<'SH'
#!/bin/sh
case "$3" in
  state) [ "${FM_PRIMARY_TEST_REMOTE_BINDING:-supported}" = supported ] && [ "$5" = --bound-home ] || exit 2; printf '%s\n' "${FM_PRIMARY_TEST_REMOTE_STATE:-alive}" ;;
  route) printf 'backend=herdr\ntarget=%s\nharness=claude\n' "${FM_PRIMARY_TEST_REMOTE_TARGET:-fm-remote:w9:p1}" ;;
  *) exit 2 ;;
esac
SH
chmod +x "$CODE/bin/fm-on.sh"
printf '%s\n' '- remote-mate - Test (host: fixture-remote; root: /remote/code; home: /remote/mate; scope: tests; projects: none; added 2026-11-14)' > "$HOME_FIXTURE/data/secondmates.md"
cat > "$HOME_FIXTURE/state/remote-mate.meta" <<'EOF'
kind=secondmate
harness=claude
backend=herdr
window=fm-remote:w9:p1
remote_host=fixture-remote
EOF
capture ready
expect_rc 0
FM_PRIMARY_TEST_REMOTE_BINDING=unsupported capture ready
expect_rc 1
contains 'home-bound state check is unavailable; recovery unverified'
contains 'primary_initialized=true'
contains 'supervision_healthy=false'
FM_PRIMARY_TEST_REMOTE_STATE=unreadable capture ready
expect_rc 1
FM_PRIMARY_TEST_REMOTE_TARGET=fm-remote:foreign capture ready
expect_rc 1
pass 'remote readiness requires home-bound liveness and a matching parent endpoint'

snapshot_state() {
  python3 - "$HOME_FIXTURE/state" <<'PY'
import hashlib, sys
from pathlib import Path
for p in sorted(Path(sys.argv[1]).rglob('*')):
    if p.is_file():
        print(str(p),hashlib.sha256(p.read_bytes()).hexdigest())
PY
}
before=$(snapshot_state)
capture ready
expect_rc 0
[ "$before" = "$(snapshot_state)" ] || fail 'ready changed private state'
pass 'ready leaves all durable private-state bytes unchanged'

[ ! -e "$HOME_FIXTURE/state/.watch.lock" ] || fail 'watcher lock unexpectedly exists'
touch "$HOME_FIXTURE/state/.last-watcher-beat"
capture ready
expect_rc 0
contains 'supervision_healthy=true'
contains 'recovery_ready=true'
FM_SUPERVISION_MODEL=persistent capture ready
expect_rc 0
contains 'supervision_healthy=true'
pass 'Claude autoarm accepts a fresh beacon after the watcher exits'

python3 - "$HOME_FIXTURE/state/.last-watcher-beat" <<'PY'
import os, sys
os.utime(sys.argv[1], (1, 1))
PY
capture ready
expect_rc 0
contains 'supervision_healthy=false'
contains 'supervision_reason=stale-beacon'
contains 'recovery_ready=true'
rm "$HOME_FIXTURE/state/.last-watcher-beat"
capture ready
expect_rc 0
contains 'supervision_healthy=false'
contains 'supervision_reason=stale-beacon'
contains 'recovery_ready=true'
pass 'stale and absent Claude autoarm evidence remain unhealthy without blocking recovery'

RC=0
FM_HOME="$TMP_ROOT/absent-home" "$CODE/bin/fm-startup-network.sh" ready "$FM_PRIMARY_TEST_PID" || RC=$?
[ "$RC" = 1 ] && [ ! -e "$TMP_ROOT/absent-home" ] || fail 'network ready created a missing state directory'
pass 'the public startup-generation readiness probe creates no state even for an absent home'
