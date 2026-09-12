# Triage wait validation

Target `3d2372fc769eddebb8d0c450af7c5710f9fdcd02` passed the focused behavioral checks.
The evidence supports correcting the test wait: production scripts are unchanged between historical `a67578d2` and the target.

The historical revision passed at normal speed ([transcript](baseline-unheld.log)).
With a controlled 3-second delay per simulated terminal capture, the historical test reproduced the exact reported failure: `not ok - [unheld-delivery] an unheld stale window stopped alarming on round 1` ([transcript](baseline-delayed-unheld.log)).
Under the identical delay, the target delivered and acknowledged each notification for two successive pane changes across unheld delivery, blocker, and ordinary worker status ([CLI output and durable queue records](target-delayed-unheld.log)).
This is a deterministic slow-dependency reproduction, not a claim that natural CPU saturation was reproduced on this host.
The historical delayed run timed out before it printed a notification; the original report's additional queued-before-timeout timing was not observed here.

The focused lifecycle checks also passed: an existing approval wait suppresses repeated pane churn, expiration permits a new notification, a failed durable queue write does not suppress the retry, and releasing then creating another approval wait permits its first notification ([CLI output, triage log, and persisted backlog](target-hold-regressions.log)).
The queue-write error in that transcript is deliberately injected and followed by a successful retry.

A negative control drove the actual watcher into legitimate repeated-hold suppression, then demanded a notification through the changed helper.
The helper returned failure after its bounded polls, left the queue empty, and reaped its child ([transcript](target-rejects-absorption.log)).
Thus the longer wait does not simply turn persistent missing notifications into passing results.

All scenarios execute real `fm-watch.sh` subprocesses, `tasks-axi`, `fm-captain-hold.sh`, and the existing drain/acknowledgement path in isolated fixture homes.
Terminal and crew-state inputs use the repository's existing hermetic fixtures; no live worker or operator backlog is involved.
Captured files are actual watcher output, the durable notification queue before acknowledgement, generated triage logs, and the backlog written by the real hold commands.
There is no UI change to render.

The historical source was exported inside the assigned worktree with `git archive a67578d2`; content, symlinks, and executable flags were verified against that archive.
A raw tar comparison reports extraction owner/umask differences, so provenance verification compared Git-owned content and executable flags instead.
The temporary historical source and fixture roots were removed after testing; no tracked source/test edits were needed.
Only this test phase was exercised.

The evidence runner loads the existing test definitions and executes only named selectors, avoiding the file's full unconditional invocation list.
Its initial launch hit the operating system's per-argument size limit before running a test; feeding the Bash script on stdin fixed the runner, and the focused checks were retried successfully.
The runner adds output capture, an opt-in delay around the fixture terminal executable, and the behavioral negative control; it does not assert implementation text.

Reproduction setup, from the assigned worktree:

```bash
mkdir -p .phase-triage-test/baseline .phase-triage-test/tmp
git archive a67578d2 | tar -x -C .phase-triage-test/baseline
```

Exact evidence-producing commands, in execution order:

```bash
TMPDIR="$PWD/.phase-triage-test/tmp" python3 /home/jason/.no-mistakes/evidence/01M2BZP9Z8XSXB3B531W0GRYRF/run-triage-selected.py .phase-triage-test/baseline /home/jason/.no-mistakes/evidence/01M2BZP9Z8XSXB3B531W0GRYRF baseline-unheld test_stale_churn_without_a_captain_call_still_alarms

FM_EVIDENCE_CAPTURE_DELAY=3 TMPDIR="$PWD/.phase-triage-test/tmp" python3 /home/jason/.no-mistakes/evidence/01M2BZP9Z8XSXB3B531W0GRYRF/run-triage-selected.py .phase-triage-test/baseline /home/jason/.no-mistakes/evidence/01M2BZP9Z8XSXB3B531W0GRYRF baseline-delayed-unheld test_stale_churn_without_a_captain_call_still_alarms

TMPDIR="$PWD/.phase-triage-test/tmp" python3 /home/jason/.no-mistakes/evidence/01M2BZP9Z8XSXB3B531W0GRYRF/run-triage-selected.py . /home/jason/.no-mistakes/evidence/01M2BZP9Z8XSXB3B531W0GRYRF target-hold-regressions test_stale_churn_without_a_captain_call_still_alarms test_open_captain_call_bounds_stale_churn test_failed_wake_append_does_not_arm_the_captain_hold_throttle test_reheld_captain_call_starts_its_own_resurface_window

FM_EVIDENCE_CAPTURE_DELAY=3 TMPDIR="$PWD/.phase-triage-test/tmp" python3 /home/jason/.no-mistakes/evidence/01M2BZP9Z8XSXB3B531W0GRYRF/run-triage-selected.py . /home/jason/.no-mistakes/evidence/01M2BZP9Z8XSXB3B531W0GRYRF target-delayed-unheld test_stale_churn_without_a_captain_call_still_alarms

TMPDIR="$PWD/.phase-triage-test/tmp" python3 /home/jason/.no-mistakes/evidence/01M2BZP9Z8XSXB3B531W0GRYRF/run-triage-selected.py . /home/jason/.no-mistakes/evidence/01M2BZP9Z8XSXB3B531W0GRYRF target-rejects-absorption test_evidence_surface_rejects_absorption
```
