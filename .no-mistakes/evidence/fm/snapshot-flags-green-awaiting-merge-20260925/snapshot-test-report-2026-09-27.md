# Fleet snapshot focused test result

Tested source head: `80558c7ab06c9f6b491dbbbcb7e1321d2a2af09f`.
The focused command `FM_SNAPSHOT_TEST_EVIDENCE_DIR=/home/jason/.no-mistakes/evidence/01M3GRK04F7ZVTXQRYG70GPJ3G bash tests/fm-fleet-snapshot-view.test.sh` passed in this worktree on 2026-09-27.
Its public snapshot regression covers a captain-held task with no metadata `pr=` field, an attributable current green run, and the contradictory no-checks, different-PR, stale-run, unavailable-run, and teardown cases using scripted native responses.
The generated `scripted-native-green-summary.json` and `scripted-no-checks-summary.json` are fixture outputs, not live PR 29 outputs.

The captain supplied a post-fix live recheck performed at 2026-09-27T08:21:20Z against the pipeline-owned snapshot binary with `FM_HOME` set to the actual PR 29 task home.
It reported `valid:false`, with `invalidity.kind=terminal_in_flight` and the sole invalidity ID `gh-axi-resolves-fork-upstream-20260922`.
The PR 29 task `remote-control-lib-sourcing-scope-20260924` was absent from invalidity IDs, appeared as a structured captain hold, and had an endpoint with `state=done` and `source=run-step`.
The central no-metadata current-green PR 29 classification is therefore a live pass; the home-level result remains invalid because of the unrelated terminal task.
This recheck was supplied by the captain and was not rerun from this isolated worktree, which has no PR 29 task home.
The captain identifies `data/snapshot-test-evidence-2026-09-27.md` in the secondmate home as the location of the exact live output; that home was not accessed in this test phase.

Live no-checks, different-PR or later-pending validation, and close-together teardown scenarios remain untested here.
Their focused scripted regressions passed, but they do not substitute for live verification.
`test-2` remains unapproved and inconclusive.
