#!/usr/bin/env python3
"""Real Claude parked-hook regression, invoked by the opt-in lifecycle test.

Only the fixture hook deadline and lease are accelerated. The real arm,
watcher, inbox and acknowledgement commands run in an isolated plain checkout.
One initial stream-input user message is sent; subsequent turns must be native
asyncRewake deliveries. Artifacts survive when the caller preserves its lab.
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

root, lab = map(Path, sys.argv[1:])
project = lab / 'quiet-project'
project.mkdir()
subprocess.run(['git', 'init', '-q', str(project)], check=True)
shutil.copytree(root / 'bin', project / 'bin')
(project / 'AGENTS.md').write_text('Isolated lifecycle test. Follow the supplied prompt.\n')
(project / 'CLAUDE.md').write_text('@AGENTS.md\n')
for name in ['state', 'config', 'data', '.claude']:
    (project / name).mkdir()
state = project / 'state'
(state / 'task.meta').write_text('kind=secondmate\nproject=fixture\n')
shutil.copyfile(root / '.tasks.toml', project / '.tasks.toml')
(project / 'data/backlog.md').write_text(
    '## Queued\n\n- [ ] parked-review - Parked review (repo: fixture) (kind: task) '
    '(since 2026-09-10) (hold: awaiting a decision) (hold-kind: parked)\n')
# Keep the shipped Stop registrations, including the synchronous guard.
# SessionStart is omitted: the test owns its local lock and starts no fleet
# bootstrap/network jobs. No user/global hooks or MCP servers enter the lab.
settings = json.loads((root / '.claude/settings.json').read_text())
settings = {'hooks': {'Stop': settings['hooks']['Stop']}}
for group in settings['hooks']['Stop']:
    for hook in group['hooks']:
        if hook.get('asyncRewake'):
            hook['timeout'] = 60
(project / '.claude/settings.json').write_text(json.dumps(settings))
env = os.environ.copy()
for key in ['FM_HOME', 'FM_ROOT', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE',
            'FM_CONFIG_OVERRIDE', 'CLAUDECODE', 'HERDR_ENV', 'HERDR_SOCKET_PATH',
            'TMUX', 'TMUX_PANE']:
    env.pop(key, None)
# Preserve unrelated delivery-tool guard variables, including FM_REAL_GIT.
env.update(FM_HOME=str(project), FM_POLL='1', FM_CHECK_INTERVAL='999999',
           FM_HEARTBEAT='999999', FM_CLAUDE_AUTOARM_LEASE_SECONDS='40',
           CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION='false')
prompt = '''Run `bin/fm-lock.sh` once with Bash, then reply PARKED and stop.
Whenever Stop hook feedback arrives, run `bin/fm-wake-drain.sh` first and
`bin/fm-inbox.sh drain`. If there is a note, read it and acknowledge that exact
note ID with `bin/fm-inbox.sh drain --ack ID`, then remove only state/task.meta
(the fixture's completed runtime obligation). If no note exists, leave the
runtime obligation in place. Run the exact WAKE_ACK_REQUIRED --ack-through
command printed by the wake drain, if any. Reply HANDLED and stop immediately.
Do not arm any watcher, poll, sleep, change other state, or work on the held
backlog. Lease renewal is only this short drain/ack turn.'''
cmd = ['claude', '-p', '--input-format', 'stream-json', '--output-format',
       'stream-json', '--verbose', '--dangerously-skip-permissions',
       '--setting-sources', 'project', '--strict-mcp-config', '--mcp-config',
       '{"mcpServers":{}}', '--effort', 'low', '--debug-file', str(lab / 'quiet-debug.log'),
       '--system-prompt', 'You are an isolated lifecycle test agent. Follow the test exactly.']
ledger = state / '.claude-autoarm-epoch'
evidence = {'native_deadline_seconds': 60, 'lease_seconds': 40, 'owners': {}}


def sample():
    if ledger.exists():
        fields = dict(re.findall(r'(\w+)=([^\s]+)', ledger.read_text()))
        evidence['owners'][fields['epoch']] = fields
    # Count only this lab's actual watcher executables, never shared sessions.
    watchers = {}
    needle = str(project / 'bin/fm-watch.sh').encode()
    for path in Path('/proc').glob('[0-9]*/cmdline'):
        try:
            args = path.read_bytes().split(b'\0')
            if needle in args:
                fields = (path.parent / 'stat').read_text().rsplit(')', 1)[1].split()
                watchers[int(path.parent.name)] = int(fields[1])
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            pass
    # Bash command substitutions inherit the script's argv. They are
    # children of the watcher, not independent singleton owners.
    owners = [pid for pid, parent in watchers.items() if parent not in watchers]
    assert len(owners) <= 1, f'competing live watcher roots: {watchers}'
    return owners


def wait_for(predicate, seconds, description):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        sample()
        if predicate():
            return
        assert proc.poll() is None, f'Claude exited early: {proc.returncode}'
        time.sleep(.5)
    raise AssertionError('timed out: ' + description)


with (lab / 'quiet-transcript.jsonl').open('w') as output:
    proc = subprocess.Popen(cmd, cwd=project, env=env, stdin=subprocess.PIPE,
                            stdout=output, stderr=subprocess.STDOUT, text=True)
    evidence['harness_pid'] = proc.pid
    try:
        proc.stdin.write(json.dumps({'type': 'user', 'message': {
            'role': 'user', 'content': prompt}}) + '\n')
        proc.stdin.flush()
        wait_for(lambda: bool(sample()) and ledger.exists(), 90, 'first parked watcher')
        first = ledger.read_text()
        first_started = int(dict(re.findall(r'(\w+)=([^\s]+)', first))['updated_at'])
        evidence['initial_ledger'] = first
        # An event before the original native deadline cannot prove renewal.
        wait_for(lambda: time.time() > first_started + 65, 75, 'original deadline')
        assert len(evidence['owners']) == 2, 'expected exactly one renewal, with no extra recovery turn'
        wait_for(lambda: bool(sample()), 30, 'parked successor after native deadline')
        subprocess.run(['bash', '-c',
                        '. "$1/bin/fm-wake-lib.sh"; fm_watcher_healthy "$1/state" "$1/bin/fm-watch.sh" 10 "$1"',
                        '_', str(project)], env=env, check=True)
        evidence['post_deadline_watcher'] = sample()
        evidence['note_at'] = time.time()
        subprocess.run([str(project / 'bin/fm-inbox.sh'), 'note',
                        'QUIET_EXPIRY_EXACTLY_ONCE'], cwd=project, env=env, check=True)
        notes = list((state / 'inbox').glob('*.note'))
        assert len(notes) == 1, 'expected one submitted note'
        note = notes[0].name
        queue = state / '.wake-queue'
        wait_for(lambda: (state / 'inbox/handled' / note).exists()
                 and queue.exists() and not queue.read_text()
                 and not (state / 'task.meta').exists(), 90, 'exact note and queue acknowledgement')
        assert not list((state / 'inbox').glob('*.note')), 'note still pending'
        assert len(list((state / 'inbox/handled').glob('*.note'))) == 1, 'duplicate handled note'
        wait_for(lambda: not sample(), 10, 'completed watcher exit')
        stable = ledger.read_text()
        # The parked backlog must not buy another maintenance turn.
        until = time.monotonic() + 45
        while time.monotonic() < until:
            sample()
            assert ledger.read_text() == stable, 'idle held work renewed a lease'
            time.sleep(.5)
        transcript = (lab / 'quiet-transcript.jsonl').read_text()
        debug = (lab / 'quiet-debug.log').read_text()
        assert debug.count('check: claude-lease-renewal') == 1, 'expected one maintenance hook delivery'
        calls = []
        for line in transcript.splitlines():
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if record.get('type') == 'assistant':
                calls.extend(block.get('input', {}).get('command', '')
                             for block in record.get('message', {}).get('content', [])
                             if block.get('type') == 'tool_use')
        assert not any('fm-watch-arm.sh' in call for call in calls), 'model armed watcher'
        note_id = note.removesuffix('.note')
        acks = [call for call in calls if 'fm-inbox.sh drain --ack ' in call and note_id in call]
        assert len(acks) == 1, f'expected one exact note acknowledgement, got {acks}'
        evidence.update(note=note, final_ledger=stable, exact_ack_calls=acks,
                        idle_observation_seconds=45, result='PASS')
        print('ok - real Claude quiet lease: native 60s deadline passed; successor handled '
              'one inbox note with no human turn, one watcher, exact ack, and no held-work renewal', flush=True)
    finally:
        (lab / 'quiet-evidence.json').write_text(json.dumps(evidence, indent=2))
        proc.stdin.close()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.terminate()
            proc.wait(timeout=10)
