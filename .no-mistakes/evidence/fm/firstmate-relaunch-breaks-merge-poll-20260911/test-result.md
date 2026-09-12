# Test-phase result

The selected PR merge, PR security, control, relaunch, watcher arm, checkpoint, lock, and recovery-loop suites passed after correcting fixture placement for the relaunch suite.
No source or test files were changed.

The initial command set `TMPDIR` to a temporary directory inside the worktree.
That caused `test_secondmate_relaunch_picks_up_the_configured_harness_pin` to hit the real placement guard: `secondmate home cannot be inside the firstmate repo`.
Only `tests/fm-control-relaunch.test.sh` was rerun, using `TMPDIR=/tmp`; its complete suite passed.
The initial transcript is retained as `targeted-tests.log`, and the corrected run is `relaunch-retry.log`.

## Behavioral evidence

- [Relaunch, tracing off and on](relaunch-merge-wakes.log): real registration, real lifecycle command, unchanged poll hashes and device:inode bindings, and durable watcher merge wakes.
- [Promotion](promotion-merge-wake.log): real promotion followed by the durable merge wake.
- [Tampering rejection](metadata-boundary.log): legitimate lifecycle fields accepted; unknown/lookalike/malformed keys, invalid heads, and duplicate PRs rejected by the real watcher before a forge poll; shell-like metadata remains inert.
- [Before-fix reproductions](before-fix-reproductions.log): both regressions fail against the base-commit production snapshot after their lifecycle command succeeds.
- [Metadata writer audit](metadata-writer-audit.md): other append-after-PR producers checked against the validation boundary.
- [Reproducible boundary check](verify-metadata-boundary.sh): run with `bash verify-metadata-boundary.sh /path/to/source-worktree`.

The evidence uses real Firstmate scripts with isolated homes and deterministic forge/terminal stubs, not a live GitHub merge or vendor-agent launch.
The acknowledged pre-existing `fm-watch-triage.test.sh` failure was excluded as instructed.
No complete repository suite, linter, formatter, static analysis, delivery command, or CI phase was run.
All temporary files created inside the worktree were removed; evidence remains in this directory.
