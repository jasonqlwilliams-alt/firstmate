# Isolated foreground watcher verification

This test phase executed the submitted renderer and real watcher/checkpoint/drain/guard interfaces from the gate worktree. All FM_HOME state was isolated beneath `.test-phase/home`. No live-home supervision mutations or callback integration were attempted.

Setup: created state/demo.meta with kind=ship and config/x-mode.env exporting FM_POLL=1, FM_SIGNAL_GRACE=0, FM_CHECK_INTERVAL=999999, FM_HEARTBEAT=999999, FM_SUPERVISION_MODEL=persistent. Synthetic worker status lines are test inputs, not real fleet outcomes. Checkpoints used direct foreground tool commands with literal home exports. Each yielded tool session was explicitly collected by this owning agent; this proves no unattended callback.

Results: two status wakes returned via foreground tool completion; this agent drained and separately acknowledged the exact generations and issued a successor. The live watcher had a fresh beacon and silent guard. Post-exit guard detected the missing watcher despite a fresh beacon. Suspending the successor produced a truthful stale-beacon warning; resuming restored health. A quiet timeout returned 124 and required ack-through 0 with its exact generation. Final queue is empty and the recovery record is acknowledged.

Probe corrections retained below: an initial 2-second guard grace collided with normal polling latency before suspension, so the controlled check was repeated with 5-second grace and 7-second suspension. An initial cleanup assertion incorrectly expected the recovery file to disappear; the real persisted contract records `acked:handling:<generation>`, which the corrected assertion verifies. Neither was a product failure.

Limits: no live-main-home recovery, real parent session-lock integration, historical alarm attribution, or idle unknown/API model callback was established. Owner of each next checkpoint was this test agent. At the end all bounded cycles exited; the demonstration is finished, with no continuing watcher owner.

Targeted tests: `TMPDIR="$PWD/.test-phase/tmp" bash tests/fm-supervision-instructions.test.sh` and `TMPDIR="$PWD/.test-phase/tmp" bash tests/fm-watch-checkpoint.test.sh` passed. The target renderer test against a worktree-local extraction of base commit 7d7f328 failed as expected: `unknown fallback omitted its supported foreground command`. No linters, full suite, or other pipeline phase ran.

# Commands and tool results

## 1

```sh
export FM_HOME='/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home'; bin/fm-supervision-instructions.sh --harness unknown
```

Exit: 0

```text
================================================================================
SUPERVISION OPERATING INSTRUCTIONS - primary harness: unknown
================================================================================
Current state:
- Lock: held by this session; this session owns normal supervision unless away mode says otherwise.
- Away mode: inactive.
- X mode: active; source /home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home/config/x-mode.env before launching any watcher process so the 30s cadence is inherited.
- Ordinary wake: follow the continuation in the harness protocol below; do not use shell &.

Mode: Unknown harness fallback.

This primary harness does not have a verified watcher wake adapter.
When this session holds the fleet lock and away mode is inactive, use the bounded foreground fallback:

1. Run `bin/fm-wake-drain.sh`, handle all emitted wakes, reconcile open decisions and unread status lines, then run the exact command printed as `WAKE_ACK_REQUIRED`, including its recovery generation.
   An empty queue can still require that acknowledgement; before it completes, interruption leaves the recovery episode open.
2. From this session's code root, run this export-prefixed command as one standalone foreground tool call:

   ```sh
   export FM_HOME='/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home'; [ -f '/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home/config/x-mode.env' ] && . '/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home/config/x-mode.env'; bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"
   ```

   The rendered paths select this session's home and source its Relay cadence when present.
   Keep setup, drain, and acknowledgement work in separate calls; [`arm-pretool-check.md`](../arm-pretool-check.md#blessed-syntax-tree) owns the accepted command shape.
3. After every return, including `check: rearm-resurface` and a quiet exit 124, repeat the drain, handling, and acknowledgement step.
   Inspect other failures before trying a fresh checkpoint.
4. The owning model must start the next checkpoint while supervision remains required.
   Return the foreground tool result to that same model; a process that survives a tool call is not evidence of notification delivery.

This fallback provides no callback continuity after the model stops issuing tool calls.
[`watcher-continuity.md`](../watcher-continuity.md#foreground-checkpoint-boundary) owns the checkpoint lifetime, warning interpretation, and verification limit.
Use `bin/fm-watch-arm.sh` only after verifying a harness-owned tracked background mechanism that survives the call and notifies the owning model on exit.
Never use shell `&` for watcher supervision or treat a successful arm as proof of that callback.

Record new verification evidence before promoting an unknown harness to a named snippet.


```

## 2

```sh
export FM_HOME='/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home'; export FM_ROOT_OVERRIDE='/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home'; export FM_SUPERVISION_MODEL=persistent; bin/fm-wake-drain.sh
```

Exit: 0

```text
●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
●  WATCHER DOWN - SUPERVISION IS OFF
●  1 task(s) in flight, but no watcher has a fresh beacon (last beat: never, grace 300s).
●  Trust the emitted supervision protocol for this harness; do not use shell & for watcher repair.
●  This is a supervision warning only; the guarded operation WILL still run.
●  source '/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home/config/x-mode.env' first, then repair missing watcher supervision with a foreground checkpoint: bin/fm-watch-checkpoint.sh --seconds 180.
●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

```

## 3

```sh
export FM_HOME='/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home'; [ -f '/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home/config/x-mode.env' ] && . '/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home/config/x-mode.env'; bin/fm-watch-checkpoint.sh --seconds 60
```

Exit: running; tracked tool session 21608

```text
(no output)
```

## 4

```sh
export FM_HOME='/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home'; export FM_ROOT_OVERRIDE='/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home'; export FM_SUPERVISION_MODEL=persistent
python3 - <<'PY'
from pathlib import Path
import os, time, subprocess
s=Path(os.environ['FM_HOME'])/'state'
pid=int((s/'.watch.lock/pid').read_text())
print('Watcher-written lock: pid='+str(pid))
print('Watcher-written identity: '+(s/'.watch.lock/pid-identity').read_text())
print('Beacon age seconds:',round(time.time()-(s/'.last-watcher-beat').stat().st_mtime,2))
subprocess.run(['ps','-p',str(pid),'-o','pid=,ppid=,stat=,args='],check=True)
r=subprocess.run(['bin/fm-guard.sh'],text=True,capture_output=True,check=True)
print('Live guard output:',r.stdout+r.stderr or '(silent)')
assert 'WATCHER DOWN' not in r.stdout+r.stderr
(s/'demo.status').write_text('done: test-phase known wake 1 delivered to owning Codex agent\n')
print('Injected synthetic worker status: done: test-phase known wake 1 delivered to owning Codex agent')
PY
```

Exit: 0

```text
3066624 3066623 S    bash /home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/bin/fm-watch.sh
Watcher-written lock: pid=3066624
Watcher-written identity: linux-starttime=31987839 cmdline-hex=62617368002f686f6d652f6a61736f6e2f2e6e6f2d6d697374616b65732f776f726b74726565732f6563636665303131313131392f30314d3157375a384737414b4d333143313233584d42515a32422f62696e2f666d2d77617463682e736800

Beacon age seconds: 0.48
Live guard output: (silent)
Injected synthetic worker status: done: test-phase known wake 1 delivered to owning Codex agent

```

## 5

```sh
Foreground tool completion from first checkpoint (write_stdin)
```

Exit: 0

```text
signal: /home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home/state/demo.status

```

## 6

```sh
export FM_HOME='/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home'; export FM_ROOT_OVERRIDE='/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home'; export FM_SUPERVISION_MODEL=persistent; bin/fm-wake-drain.sh
```

Exit: 0

```text
1788728310	2	signal	demo.status	signal: /home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home/state/demo.status
WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 2 --recovery-generation 3077891.1788728310.sCxoiI
wake annotation: latest wake-EVENT observed at drain, not current state: demo.status: done: test-phase known wake 1 delivered to owning Codex agent
●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
●  WATCHER DOWN - SUPERVISION IS OFF
●  1 task(s) in flight, but no live watcher process holds this home lock (last beat: 13s ago).
●  Trust the emitted supervision protocol for this harness; do not use shell & for watcher repair.
●  This is a supervision warning only; the guarded operation WILL still run.
●  After draining queued wakes, source '/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home/config/x-mode.env' first, then repair missing watcher supervision with a foreground checkpoint: bin/fm-watch-checkpoint.sh --seconds 180.
●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else.

```

## 7

```sh
export FM_HOME='/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home'; bin/fm-wake-drain.sh --ack-through 2 --recovery-generation 3077891.1788728310.sCxoiI
```

Exit: 0

```text
(no output)
```

## 8

```sh
export FM_HOME='/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home'; [ -f '/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home/config/x-mode.env' ] && . '/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home/config/x-mode.env'; bin/fm-watch-checkpoint.sh --seconds 60
```

Exit: running; tracked tool session 72783

```text
(no output)
```

## 9

```sh
export FM_HOME='/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home'; export FM_ROOT_OVERRIDE='/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home'; export FM_SUPERVISION_MODEL=persistent; export FM_GUARD_GRACE=2
python3 -u - <<'PY'
from pathlib import Path
import os, signal, time, subprocess
s=Path(os.environ['FM_HOME'])/'state'
assert (s/'.wake-queue').stat().st_size==0
print('Durable queue after first acknowledgement: empty')
pid=int((s/'.watch.lock/pid').read_text())
assert pid != 3066624
print('Successor watcher PID:',pid)
subprocess.run(['ps','-p',str(pid),'-o','pid=,ppid=,stat=,args='],check=True)
print('Successor beacon age seconds:',round(time.time()-(s/'.last-watcher-beat').stat().st_mtime,2))
def guard():
    r=subprocess.run(['bin/fm-guard.sh'],text=True,capture_output=True,check=True)
    return r.stdout+r.stderr
out=guard()
print('Successor live guard:',out or '(silent)')
assert 'WATCHER DOWN' not in out
try:
    os.kill(pid,signal.SIGSTOP)
    time.sleep(4)
    os.kill(pid,0)
    print('Suspended watcher remains alive; beacon age seconds:',round(time.time()-(s/'.last-watcher-beat').stat().st_mtime,2))
    out=guard()
    print(out)
    assert 'WATCHER DOWN' in out and 'fresh beacon' in out
finally:
    os.kill(pid,signal.SIGCONT)
time.sleep(2)
out=guard()
print('Resumed watcher guard:',out or '(silent)')
assert 'WATCHER DOWN' not in out and 'watcher still down' not in out
with (s/'demo.status').open('a') as f:
    f.write('done: test-phase known wake 2 from caller-issued successor\n')
print('Injected synthetic worker status: done: test-phase known wake 2 from caller-issued successor')
PY
```

Exit: 1

```text
Durable queue after first acknowledgement: empty
Successor watcher PID: 3087227
3087227 3087226 S    bash /home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/bin/fm-watch.sh
Successor beacon age seconds: 1.24
Successor live guard: ●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
●  WATCHER DOWN - SUPERVISION IS OFF
●  1 task(s) in flight, but no watcher has a fresh beacon (last beat: 2s ago, grace 2s).
●  Trust the emitted supervision protocol for this harness; do not use shell & for watcher repair.
●  This is a supervision warning only; the guarded operation WILL still run.
●  source '/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home/config/x-mode.env' first, then repair missing watcher supervision with a foreground checkpoint: bin/fm-watch-checkpoint.sh --seconds 180.
●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Traceback (most recent call last):
  File "<stdin>", line 16, in <module>
AssertionError

```

## 10

```sh
export FM_HOME='/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home'; export FM_ROOT_OVERRIDE='/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home'; export FM_SUPERVISION_MODEL=persistent; export FM_GUARD_GRACE=5
python3 -u - <<'PY'
from pathlib import Path
import os, signal, time, subprocess
s=Path(os.environ['FM_HOME'])/'state'
assert (s/'.wake-queue').stat().st_size==0
print('Durable queue after first acknowledgement: empty')
pid=int((s/'.watch.lock/pid').read_text())
assert pid != 3066624
print('Successor watcher PID:',pid)
subprocess.run(['ps','-p',str(pid),'-o','pid=,ppid=,stat=,args='],check=True)
print('Successor beacon age seconds:',round(time.time()-(s/'.last-watcher-beat').stat().st_mtime,2))
def guard():
    r=subprocess.run(['bin/fm-guard.sh'],text=True,capture_output=True,check=True)
    return r.stdout+r.stderr
out=guard()
print('Successor live guard:',out or '(silent)')
assert 'WATCHER DOWN' not in out
try:
    os.kill(pid,signal.SIGSTOP)
    time.sleep(7)
    os.kill(pid,0)
    print('Suspended watcher remains alive; beacon age seconds:',round(time.time()-(s/'.last-watcher-beat').stat().st_mtime,2))
    out=guard()
    print(out)
    assert 'WATCHER DOWN' in out and 'fresh beacon' in out
finally:
    os.kill(pid,signal.SIGCONT)
time.sleep(2)
out=guard()
print('Resumed watcher guard:',out or '(silent)')
assert 'WATCHER DOWN' not in out and 'watcher still down' not in out
with (s/'demo.status').open('a') as f:
    f.write('done: test-phase known wake 2 from caller-issued successor\n')
print('Injected synthetic worker status: done: test-phase known wake 2 from caller-issued successor')
PY
```

Exit: running; tracked tool session 16287

```text
Durable queue after first acknowledgement: empty
Successor watcher PID: 3087227
3087227 3087226 S    bash /home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/bin/fm-watch.sh
Successor beacon age seconds: 0.74
Successor live guard: (silent)

```

## 11

```sh
Complete isolated suspend/resume observation
```

Exit: 0

```text
Suspended watcher remains alive; beacon age seconds: 7.79
●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
●  WATCHER DOWN - SUPERVISION IS OFF
●  1 task(s) in flight, but no watcher has a fresh beacon (last beat: 8s ago, grace 5s).
●  Trust the emitted supervision protocol for this harness; do not use shell & for watcher repair.
●  This is a supervision warning only; the guarded operation WILL still run.
●  source '/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home/config/x-mode.env' first, then repair missing watcher supervision with a foreground checkpoint: bin/fm-watch-checkpoint.sh --seconds 180.
●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Resumed watcher guard: (silent)
Injected synthetic worker status: done: test-phase known wake 2 from caller-issued successor

```

## 12

```sh
Foreground tool completion from caller-issued successor (write_stdin)
```

Exit: 0

```text
signal: /home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home/state/demo.status

```

## 13

```sh
export FM_HOME='/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home'; export FM_ROOT_OVERRIDE='/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home'; export FM_SUPERVISION_MODEL=persistent; bin/fm-wake-drain.sh
```

Exit: 0

```text
1788728380	4	signal	demo.status	signal: /home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home/state/demo.status
WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 4 --recovery-generation 3111099.1788728379.TCEi49
wake annotation: latest wake-EVENT observed at drain, not current state: demo.status: done: test-phase known wake 2 from caller-issued successor
●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
●  WATCHER DOWN - SUPERVISION IS OFF
●  1 task(s) in flight, but no live watcher process holds this home lock (last beat: 15s ago).
●  Trust the emitted supervision protocol for this harness; do not use shell & for watcher repair.
●  This is a supervision warning only; the guarded operation WILL still run.
●  After draining queued wakes, source '/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home/config/x-mode.env' first, then repair missing watcher supervision with a foreground checkpoint: bin/fm-watch-checkpoint.sh --seconds 180.
●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else.

```

## 14

```sh
export FM_HOME='/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home'; bin/fm-wake-drain.sh --ack-through 4 --recovery-generation 3111099.1788728379.TCEi49
```

Exit: 0

```text
(no output)
```

## 15

```sh
export FM_HOME='/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home'; [ -f '/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home/config/x-mode.env' ] && . '/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home/config/x-mode.env'; bin/fm-watch-checkpoint.sh --seconds 1
```

Exit: 124

```text
checkpoint: no actionable wake within 1s

```

## 16

```sh
export FM_HOME='/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home'; export FM_ROOT_OVERRIDE='/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home'; export FM_SUPERVISION_MODEL=persistent; bin/fm-wake-drain.sh
```

Exit: 0

```text
WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 0 --recovery-generation 3121802.1788728413.gbg4QQ
WARNING: watcher still down (same stale episode; last beat: 10s ago, grace 300s) - full banner already printed this episode.

```

## 17

```sh
export FM_HOME='/home/jason/.no-mistakes/worktrees/eccfe0111119/01M1W7Z8G7AKM31C123XMBQZ2B/.test-phase/home'; bin/fm-wake-drain.sh --ack-through 0 --recovery-generation 3121802.1788728413.gbg4QQ
```

Exit: 0

```text
(no output)
```

## 18

```sh
python3 - <<'PY'
from pathlib import Path
import json, subprocess
s=Path('.test-phase/home/state')
state={
 'queue_bytes': (s/'.wake-queue').stat().st_size,
 'watcher_lock_pid_exists': (s/'.watch.lock/pid').exists(),
 'recovery_episode_exists': (s/'.watcher-down').exists(),
 'worker_status': (s/'demo.status').read_text(),
}
print(json.dumps(state,indent=2))
assert state['queue_bytes']==0
assert not state['watcher_lock_pid_exists']
assert not state['recovery_episode_exists']
r=subprocess.run(['ps','-eo','pid=,args='],capture_output=True,text=True,check=True)
for line in r.stdout.splitlines():
    if line.strip().startswith(('3066624 ', '3087227 ')):
        raise AssertionError('demonstration watcher PID survived: '+line)
PY
```

Exit: 1

```text
{
  "queue_bytes": 0,
  "watcher_lock_pid_exists": false,
  "recovery_episode_exists": true,
  "worker_status": "done: test-phase known wake 1 delivered to owning Codex agent\ndone: test-phase known wake 2 from caller-issued successor\n"
}
Traceback (most recent call last):
  File "<stdin>", line 13, in <module>
AssertionError

```

## 19

```sh
python3 - <<'PY'
from pathlib import Path
import json, subprocess
s=Path('.test-phase/home/state')
state={
 'queue_bytes': (s/'.wake-queue').stat().st_size,
 'watcher_lock_pid_exists': (s/'.watch.lock/pid').exists(),
 'recovery_record': (s/'.watcher-down').read_text().strip(),
 'worker_status': (s/'demo.status').read_text(),
}
print(json.dumps(state,indent=2))
assert state['queue_bytes']==0
assert not state['watcher_lock_pid_exists']
assert state['recovery_record']=='acked:handling:3121802.1788728413.gbg4QQ'
r=subprocess.run(['ps','-eo','pid=,args='],capture_output=True,text=True,check=True)
for line in r.stdout.splitlines():
    if line.strip().startswith(('3066624 ', '3087227 ')):
        raise AssertionError('demonstration watcher PID survived: '+line)
PY
```

Exit: 0

```text
{
  "queue_bytes": 0,
  "watcher_lock_pid_exists": false,
  "recovery_record": "acked:handling:3121802.1788728413.gbg4QQ",
  "worker_status": "done: test-phase known wake 1 delivered to owning Codex agent\ndone: test-phase known wake 2 from caller-issued successor\n"
}

```

