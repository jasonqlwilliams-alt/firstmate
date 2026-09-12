# Metadata writer audit

Source inspected: target commit `2a5addf6f901911fe6f5c00051c294379661f022`, compared with base `512b2fe4283d0ff98a3d4d7fe9be12e8ff83fabe`.

| Producer | Ordering after a PR is registered | Validation coverage |
| --- | --- | --- |
| `bin/fm-spawn.sh`, invoked by `bin/fm-control.sh relaunch` | Rewrites owned task fields before preserved metadata, then appends `control_relaunch_tx`. Trace-enabled publication additionally appends `traceparent`. | Both keys are allowed. The real relaunch regression checks tracing off/on, unchanged poll hashes and device:inode bindings, and a real watcher-generated durable merge wake. |
| `bin/fm-promote.sh` | Preserves PR metadata, removes the old delivery fields, then appends `kind`, `mode`, and `yolo`. | All three keys are allowed. The promotion regression invokes the real command and watcher, checks the durable merge wake, and checks poll retirement. |
| `bin/fm-captain-hold.sh complete` | Appends `decisions_reviewed` and `decision_keys` under the metadata lock. | Both keys are allowed and exercised as serialized metadata through the validator and real watcher in `metadata-boundary.log`. |
| `bin/fm-teardown.sh` legacy-record stamping | Appends `spawn_gen` after validating the legacy task; adds a terminating newline first only when needed. | The key is allowed and exercised in `metadata-boundary.log`. Full teardown is outside this focused lifecycle test. |
| `bin/fm-x-lib.sh`, used by `bin/fm-x-link.sh` and follow-up writers | Replaces and appends `x_request`, `x_request_ts`, `x_followups`, `x_platform`, and `x_reply_max_chars`; clear removes only those fields. | These keys were already allowed before this patch. |
| `bin/fm-pr-check.sh`, also used by `bin/fm-pr-merge.sh` | Replaces PR identity and appends exactly one canonical `pr` plus a valid optional `pr_head`. | Registration is executed in both regressions and every manual boundary case. |
| Fresh/local and remote-secondmate spawn metadata publication | Constructs a new task record; local relaunch uses the preservation path above. | No additional append-after-PR fields found. |

The writer inventory is source inspection, not a substitute for behavioral proof of each producer.
The executable regressions and CLI transcript provide the behavioral evidence for relaunch, promotion, and the metadata validation boundary.
No additional append-after-PR key missing from the allowlist was identified.

The same newly added regressions were run against a base-commit source snapshot, with only the test files copied from the target.
Both fail after the real lifecycle command succeeds: relaunch at `real relaunch invalidated the registered merge poll`, and promotion at `promoted task's PR poll no longer authenticates`.
The relaunch transcript also shows unchanged poll hashes and device:inode bindings at the failure.

All evidence uses isolated fixture homes and deterministic forge replies.
The relaunch regression uses a stubbed terminal provider; PR registration, lifecycle commands, metadata validation, watcher execution, and durable wake publication use the real Firstmate scripts.
No real PR was merged and no vendor agent was launched.
