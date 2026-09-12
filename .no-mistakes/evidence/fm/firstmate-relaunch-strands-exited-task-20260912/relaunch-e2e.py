#!/usr/bin/env python3
"""Reproduce exited-shell recovery through real tmux and the public control CLI.
Uses a compiled, inert harness stand-in; no vendor agent or credentials are used.
Usage: python3 relaunch-e2e.py CODE_ROOT FIXTURE_ROOT [--expect-refusal]
"""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import time

code = Path(sys.argv[1]).resolve()
case = Path(sys.argv[2]).resolve()
expect_refusal = '--expect-refusal' in sys.argv
case.mkdir(parents=True)
proj, wt, home, shim = [case / name for name in ('project', 'worktree', 'home', 'shim')]
for folder in (proj, home / 'state', home / 'data', shim):
    folder.mkdir(parents=True, exist_ok=True)
id = f'e2e-relaunch-{os.getpid()}'
endpoint = f'relaunch:fm-{id}'
socket = f'fm-relaunch-evidence-{os.getpid()}'
env = {**os.environ, 'HOME': str(home), 'FM_HOME': str(home),
       'FM_GATE_REFUSE_BYPASS': '1', 'FM_SPAWN_NO_GUARD': '1',
       'FM_CONTROL_POLL': '0.1', 'FM_CONTROL_EXIT_WAIT': '5',
       'FM_CONTROL_LAUNCH_WAIT': '8', 'FM_CONTROL_PREPARE_WAIT': '15',
       'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null',
       'FM_E2E_RUNLOG': str(case / 'agents.log')}
for key in ('FM_STATE_OVERRIDE', 'FM_BACKEND', 'FM_TASK_ID', 'TMUX', 'TMUX_PANE',
            'HERDR_SESSION', 'HERDR_PANE_ID', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND'):
    env.pop(key, None)

def run(args, check=True, **kwargs):
    return subprocess.run([str(arg) for arg in args], env=env, text=True,
                          capture_output=True, check=check, **kwargs)

def tmux(*args, check=True):
    return run(['/usr/bin/tmux', '-L', socket, *args], check=check)

def send(line):
    tmux('send-keys', '-t', endpoint, '-l', line)
    tmux('send-keys', '-t', endpoint, 'Enter')

def cwd():
    return tmux('display-message', '-p', '-t', endpoint, '#{pane_current_path}').stdout.strip()

def command():
    return tmux('display-message', '-p', '-t', endpoint, '#{pane_current_command}').stdout.strip()

def wait_for(predicate):
    for _ in range(100):
        if predicate():
            return
        time.sleep(.1)
    raise AssertionError('Timed out waiting for fixture state')

def control(*args, wanted=0):
    cmd = [code / 'bin/fm-control.sh', id, *args]
    result = run(cmd, check=False)
    print('$', shlex.join([str(p) for p in cmd]), flush=True)
    print(result.stdout + result.stderr, end='', flush=True)
    print(f'exit={result.returncode}; pane_command={command()}; pane_cwd={cwd()}', flush=True)
    assert result.returncode == wanted
    return result

run(['git', '-C', proj, 'init', '-q'])
(proj / 'task.txt').write_text('committed task work\n')
run(['git', '-C', proj, 'add', 'task.txt'])
run(['git', '-C', proj, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
     'commit', '-qm', 'fixture'])
run(['git', '-C', proj, 'worktree', 'add', '-qb', 'preserved-work', wt])
(wt / 'task.txt').write_text('committed task work\nunfinished task work\n')
head = run(['git', '-C', wt, 'rev-parse', 'HEAD']).stdout.strip()
(wt / 'R&D').mkdir()
(wt / 'bin').mkdir()
source = case / 'agent.c'
source.write_text(r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(void) {
  char cwd[4096], line[8192]; getcwd(cwd, sizeof(cwd));
  FILE *log = fopen(getenv("FM_E2E_RUNLOG"), "a");
  fprintf(log, "pid=%ld cwd=%s\n", (long)getpid(), cwd); fclose(log);
  printf("fixture agent running: pid=%ld cwd=%s\n", (long)getpid(), cwd); fflush(stdout);
  while (fgets(line, sizeof(line), stdin)) {
    if (strstr(line, "/quit") || strstr(line, "/exit")) return 0;
  }
  return 0;
}
''')
run(['cc', source, '-o', wt / 'R&D/codex'])
shutil.copy2(wt / 'R&D/codex', wt / 'bin/cursor-agent')
shutil.copy2(wt / 'R&D/codex', wt / 'bin/opencode')
(shim / 'tmux').write_text('#!/bin/sh\nexec /usr/bin/tmux -L ' + shlex.quote(socket) + ' "$@"\n')
(shim / 'tmux').chmod(0o755)
env['PATH'] = str(shim) + ':/usr/bin:/bin'
(home / 'data' / id).mkdir()
(home / 'data' / id / 'brief.md').write_text('# Task\n## Captain\'s intent\nPreserve task work and recover an exited agent.\n\n## Firstmate spec\nContinue in the recorded worktree.\n')
meta = home / 'state' / f'{id}.meta'
meta.write_text(f'window={endpoint}\nendpoint_task_id={id}\nworktree={wt}\nproject={proj}\nharness=codex\nkind=ship\nmode=no-mistakes\nyolo=off\nmodel=default\neffort=default\n')
print('Real tmux lifecycle evidence; agent is an inert compiled fixture.', flush=True)
try:
    tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'relaunch', '-n', 'fm-' + id,
         '-c', home, '-x', '160', '-y', '35', '/bin/bash --noprofile --norc')
    tmux('set-option', '-t', 'relaunch', 'automatic-rename', 'off')
    ready = case / 'shell-ready'
    send('export PATH=\'./R&D:./bin:/usr/bin:/bin\'; touch ' + shlex.quote(str(ready)))
    wait_for(ready.exists)
    send('( cd ' + shlex.quote(str(wt)) + '; codex )')
    wait_for(lambda: command() == 'codex')
    print(f'Initial agent: command={command()}; cwd={cwd()}; HEAD={head}', flush=True)
    control('exit')
    wait_for(lambda: cwd() == str(home))
    print('Agent exited; real subshell unwound to the parent home.', flush=True)
    result = control('relaunch', '--note', 'Continue the preserved task.', wanted=1 if expect_refusal else 0)
    if expect_refusal:
        assert command() == 'bash' and cwd() == str(home)
        print('BASELINE REPRODUCED: relaunch refused and task remains agent-free.', flush=True)
    else:
        assert command() == 'codex' and cwd() == str(wt)
        pid_before = (case / 'agents.log').read_text().splitlines()[-1]
        bytes_before = meta.read_bytes()
        brief_before = (home / 'data' / id / 'brief.md').read_bytes()
        control('relaunch', '--harness', 'gemini', '--note', 'Missing executable must preserve this worker.', wanted=1)
        assert command() == 'codex' and meta.read_bytes() == bytes_before
        assert (home / 'data' / id / 'brief.md').read_bytes() == brief_before
        assert (case / 'agents.log').read_text().splitlines()[-1] == pid_before
        (wt / '.opencode').mkdir(exist_ok=True)
        (wt / '.opencode/plugins').write_text('project-owned file\n')
        control('relaunch', '--harness', 'opencode', '--note', 'Invalid plugin path must preserve this worker.', wanted=1)
        assert command() == 'codex' and meta.read_bytes() == bytes_before
        assert (case / 'agents.log').read_text().splitlines()[-1] == pid_before
        print('Both refusals retained the same running worker: ' + pid_before, flush=True)
        control('exit')
        send('cd ' + shlex.quote(str(home)))
        wait_for(lambda: cwd() == str(home))
        control('relaunch', '--harness', 'cursor', '--note', 'Resolve Cursor from the worktree-relative PATH.')
        assert command() == 'cursor-agent' and cwd() == str(wt)
        assert run(['git', '-C', wt, 'rev-parse', 'HEAD']).stdout.strip() == head
        assert (wt / 'task.txt').read_text() == 'committed task work\nunfinished task work\n'
        assert f'window={endpoint}\n' in meta.read_text()
        print('Persisted task metadata:\n' + meta.read_text(), flush=True)
        print('Persisted control journal:\n' + (home / 'state' / f'{id}.control-relaunch').read_text(), flush=True)
        print('Preserved task.txt:\n' + (wt / 'task.txt').read_text(), flush=True)
        print('Actual launched process log:\n' + (case / 'agents.log').read_text(), flush=True)
        print('TARGET VERIFIED: same endpoint, same worktree and HEAD, uncommitted work preserved.', flush=True)
finally:
    print('Terminal capture:\n' + tmux('capture-pane', '-p', '-t', endpoint, '-S', '-80', check=False).stdout, flush=True)
    tmux('kill-server', check=False)
    shutil.rmtree('/tmp/fm-' + id, ignore_errors=True)
