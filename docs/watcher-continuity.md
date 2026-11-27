# Watcher continuity

The watcher remains intentionally one-shot: one actionable reason closes one watcher cycle.
Successor ownership depends on the harness integration below; the [foreground checkpoint boundary](#foreground-checkpoint-boundary) covers model-owned continuation.

## Ownership

Pi's `.pi/extensions/fm-primary-pi-watch.ts`, omp's `.omp/extensions/fm-primary-omp-watch.ts`, and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` own continuous re-arm after an actionable child close.
Each adapter starts the next arm before delivering the wake prompt, checks current session-lock ownership at launch, preserves one child or scheduled retry at a time, and applies bounded exponential retry after an unexpected or failed close.
A failed follow-up never cancels continuity restoration.
Pi same-process session replacement follows the generation-owner contract in `.pi/extensions/fm-primary-pi-watch.ts`: an owning `session_start` arms the replacement generation without waiting for a model turn, and a state-scoped replacement handoff carries every actionable close whose delivery overlapped `session_shutdown`, including a main follow-up Pi accepted but had not yet consumed, branch handling, and a retiring child that reports after the bounded shutdown wait.
A main follow-up counts as delivered once Pi accepts it, never once the model reads it, because a follow-up queued while main is streaming joins the running run without a `before_agent_start`; the extension header owns how consumption is observed and why it only decides what a replacement replays.
omp's replacement follows the same generation-owner contract in `.omp/extensions/fm-primary-omp-watch.ts`, whose header owns the one difference: omp reports no shutdown reason, so every shutdown with a pending actionable close persists the handoff for the next owning `session_start` to replay.
Cursor's `.cursor/hooks.json` `stop` hook (`bin/fm-turnend-guard-cursor.sh`) owns routine tokenless re-arm for a Cursor primary by parking that awaited hook on `bin/fm-watch-arm.sh` and returning an actionable close as one follow-up; [`turnend-guard.md`](turnend-guard.md#harness-integrations) owns its Pi-host stand-down, loop bounds, and supersession baton.
Claude's `.claude/settings.json` Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`) owns routine re-arm.
Quiet waiting uses no model tokens between events, but ongoing Claude supervision needs one short maintenance turn about every six hours.
The hook bounds its foreground arm with the shared timeout runner at 21,600 seconds, before Claude's native 28,800-second hook deadline can kill that tree without delivering a wake.
The lease covers all retry attempts and produces at most one generation-owned exit-2 renewal.
Renewal rechecks supervision demand, AFK, supersession, and failure-alarm gates; a held backlog alone creates no demand.
Before notification, renewal uses the existing serialized lock helper to reclaim only a provably dead watcher lock and publishes the generation-bound handling marker, so its one handling turn can acknowledge the gap even when bounded teardown interrupted watcher cleanup.
A live lock holder remains protected, including when its identity is mismatched; a verified live attached watcher retains its lock.
No synthetic maintenance record is queued, so renewal cannot create its own supervision demand.
Handle renewal by draining and acknowledging any real wakes, then stop promptly: the next eligible Stop acquires the successor generation.
`FM_CLAUDE_AUTOARM_LEASE_SECONDS` may shorten the lease for isolated tests; zero, invalid values, and values above 21,600 use the six-hour bound.
The hook fires on every Stop, and an eligible primary with supervision need admits one home-scoped owner that foregrounds `bin/fm-watch-arm.sh` inside the hook-owned process tree.
The hook reclaims a stale numeric session-lock owner through `bin/fm-lock.sh` before changing auto-arm state, using the [shared session-lock liveness check](primary-recovery.md#start).
A live owner outside the hook's ancestry, an absent lock, or a malformed PID line keeps the hook inert.
The stale-owner claim occurs only after the existing AFK and supervision-need gates pass.
After each non-actionable arm close, the hook rechecks the identity-matched watcher lock and fresh beacon before retrying a bounded number of times.
A cycle-end failure is benign when that live-watcher predicate is true, and the hook suppresses the arm output and continues silently.
Only an exhausted failure with no verified watcher commits one last-resort notice for the continuous failure episode; a refused notice commit stays silent for a later retry, and after a successful notice later Stop cycles exit 2 without repeating it until the turn-end guard consumes the attended fail-open.
The Claude turn-end guard owns that notice commit contract, the monotonic failure progression, one-time attended fail-open, post-alarm continuation suppression, and positive recovery reset described in [`turnend-guard.md`](turnend-guard.md#harness-integrations).
While supervision is still needed and away mode remains inactive, an actionable close wakes the idle session through exit 2.

## Actionable wake ordering

After an actionable Pi, omp, or OpenCode child close, the adapter starts and verifies one singleton successor before it delivers the original wake.
It confirms the handling handoff against that successor before scheduling the follow-up, retries once against the current generation and successor, and treats a failed confirmation as a restoration failure: it classifies the error, retires a successor that is no longer alive, and surfaces exactly one typed message.
A failed confirmation is never swallowed.
It waits at most one readiness timeout per attempt, then sends TERM and waits a bounded retirement confirmation before the next lock-verified exponential retry.
If the unready arm does not retire within that bound, the adapter keeps ownership, starts no overlapping retry, and delivers the typed fallback immediately.
When that retained arm later closes, its actual close is classified as a new supervised event without replaying the earlier fallback.
After the configured retry bound is exhausted, it delivers the original wake with a typed continuity-restoration failure even if every successor arm hung without reporting readiness.
This is deliberate Option B ordering: the fleet is protected before the model handles the wake whenever restoration succeeds, but the model is never left blind when it does not.

Claude's Stop hook starts the successor arm at the next Stop after the handling turn, rather than before notification as Pi, omp, and OpenCode do.
The durable wake queue preserves actionable events during the residual active-turn window, and the bounded turn-end guard enforces recovery at Stop when no watcher is live and no open generation claim is still deciding, so a finished, hung, or identity-mismatched claim cannot suppress it ([`turnend-guard.md`](turnend-guard.md#harness-integrations) owns that boundary).
The recovery-episode contract below owns once-per-generation announcement.
A handling successor does not re-announce; it enters its poll loop immediately and keeps scanning signals, stale panes, and checks.
Claude's model no longer re-arms after ordinary wakes.
No PreToolUse hook denies fleet commands based on watcher status.
A genuine auto-arm failure describes the automatic mechanism as broken and never directs a routine manual background arm.
Terminal arm-output classification (`started`, `attached`, or `FAILED`) remains defense in depth for the manual recovery path.
Codex retains its bounded foreground checkpoint protocol.
Grok retains its tracked background-task notification protocol.
No adapter starts a replacement with shell `&`.

The turn-end guard remains the final backstop rather than the normal continuity mechanism and cooperates with the auto-arm in its `--claude` mode.

## Recorded endpoint loss

When the backend confirms that a local task's recorded endpoint is missing, the watcher clears pause tracking.
The watcher queues `stale: <window> (the recorded endpoint is gone)` once for that recorded endpoint unless a matching [retained-copy park mark](#parking-a-task-with-its-copy-retained) suppresses the report.
Routine polling checks local idle secondmate presence without capturing their screens and skips recorded-endpoint polling for remote mates.
A secondmate enters the pane-stale path only while its latest status declares `paused:` or `captain-held:`.
A backlog hold alone leaves the secondmate on the idle polling path.

The presence check in [`fm-backend.sh`](../bin/fm-backend.sh) returns `unreadable` when the evidence is inconclusive, and the watcher stays quiet.
tmux and Herdr can confirm loss on an idle presence check or after a failed screen capture.
For Zellij, an idle presence check can verify the recorded pane against its expected tab title.
A missing pane or a changed title is inconclusive because the recorded session may have been renamed or replaced.
Failed screen captures on Zellij, cmux, and Orca stay quiet in recorded-endpoint monitoring.
A cmux surface can move out of its recorded workspace, and a successful capture can read another surface in that workspace.
An Orca terminal can survive after its recorded handle goes stale.

The report is keyed to the recorded backend, target, and spawn generation, so a relaunch can report a fresh loss even when it reuses the target.
A successful capture or a positive presence verdict re-arms the report, and teardown keeps the loss record until it retires the task record.
The wake keeps its window key for routing and has a separate deduplication identity, so the drain presents both the endpoint loss and any ordinary stale wake for that window, collapsing repeated loss rows to one.
After handling both wakes, use the drain's [printed acknowledgement](#recovery-episode-acknowledgement) to retire them.
Where the away daemon runs, it routes the loss to its escalation digest and keeps pause tracking cleared while the loss still matches the current endpoint, even if the wait remains declared.

The [backend verification record](verification/runtime-backends.md#recorded-endpoint-loss) covers tmux and Herdr.
The [watcher triage regressions](../tests/fm-watch-triage.test.sh) cover wake ordering, park marks, idle secondmate polling, Zellij presence verdicts, and quiet capture failures on the experimental backends.

### Parking a task with its copy retained

On tmux or Herdr, use the `mark` action in [`fm-park-retained.sh`](../bin/fm-park-retained.sh) after deliberately closing a local ordinary task's worker window and retaining its isolated copy.
Marking requires a recovery-grade `missing` verdict for the recorded endpoint.
On Zellij, Orca, and cmux, the command refuses to set the mark and explains that the backend cannot confirm endpoint loss.
Both park actions leave the copy and its work intact.
With a current mark, the session-start fleet digest shows `endpoint: parked, copy retained` without probing the recorded endpoint, even when another worker now reuses that target.
Without a current mark, the regular endpoint check reports `dead` when it detects that the recorded endpoint is gone.
Deferred home-summary publication and inactive reconciliation also skip endpoint probes for tasks with a current mark.
Secondmates follow the reporting rule above.
A loss wake queued before marking remains pending until [normal wake acknowledgement](#per-actor-acknowledgement).
When resuming, use `clear` to remove the mark, including after the worker is running again.
Clearing restores reporting eligibility and preserves the existing loss deduplication, so an already reported loss stays deduplicated for that incarnation.
A park mark applies only to the worker incarnation that was marked.
A relaunched worker or another task that reuses the same target remains eligible for loss reporting.

The [session-start regressions](../tests/fm-session-start.test.sh) cover current, stale, and absent marks, including exact window-name reuse on tmux and a recycled Herdr pane during deferred startup.

## Foreground checkpoint boundary

Codex and the unknown-harness foreground fallback run one bounded watcher cycle through `bin/fm-watch-checkpoint.sh`.
The checkpoint returns the watcher result to its calling tool; it neither registers a model callback nor launches a successor.
A clean checkpoint return releases the watcher lock, leaving an interval without a polling watcher until the owning model handles the result and starts the next checkpoint.
Ending the model turn does not establish that next cycle, and a turn-end guard warning is a backstop rather than a callback adapter.
The harness protocols own the drain, handle, generation-bound acknowledgement, and repeat sequence.
Acknowledging an empty-queue recovery episode is still required when the drain requests it; omitting it can produce `check: rearm-resurface` on the next cycle.

The pull guard verifies a live watcher by its home, watcher path, process identity, and fresh beacon.
A recent beacon after the checkpoint has returned does not prove that a watcher remains alive.
Conversely, a running checkpoint wrapper or child PID does not prove complete lock publication, matching identity, or a fresh beacon: a suspended or stalled watcher can remain alive while polling has stopped.
Inspect those facts at the warning's timestamp before classifying an alarm during a foreground call.
While supervision is needed, the pull guard prints `NOTICE: between foreground checkpoints` when the watcher lock is absent and a clean-return receipt from the current lock-owning, attended Codex session is younger than `FM_GUARD_GRACE`.
The notice clears the guard's banner deduplication state so a later lapse gets a full alarm.
A quiet receipt requires a completed monitoring scan, and the guard checks that the beacon is still fresh when it reads that receipt.
If active capture cleanup cannot be confirmed after the checkpoint deadline, the checkpoint reports the cleanup failure on stderr, returns 124, and records no clean return.
If the beacon ages past the grace during the checkpoint or while the result is being handled, the guard can alarm before the quiet receipt expires.
A verified actionable wake can qualify even before the watcher writes its first beacon.
When monitoring is needed and no live watcher qualifies, a missing or expired receipt or a retained watcher lock triggers the usual alarm.
Read-only checks and sessions outside attended Codex foreground supervision use their usual liveness rules.
If removal of the previous receipt fails at checkpoint startup or during away-posture archival, the guard can still accept that receipt in the same session until its age reaches the guard grace.
[`fm-guard.sh`](../bin/fm-guard.sh) owns the receipt check and banner policy.
An unacknowledged `state/.watcher-down` generation alone does not cause a watcher-health alarm; queued wakes have their own independent warning.

A successful demonstration of a foreground wake, durable acknowledgement, and model-issued successor proves that sequence only.
It does not establish unattended notification or continuity after the owning model stops making calls.
An unknown API harness needs its own verified notification integration before it can claim that guarantee.
`tests/fm-watch-checkpoint.test.sh` exercises the foreground lifecycle, and `tests/fm-watcher-lock.test.sh` covers a suspended live watcher whose beacon becomes stale.

## Recovery episode acknowledgement

A recovery episode is one generation of `state/.watcher-down`, and it is retired only by the generation-bound acknowledgement the drain prints as `WAKE_ACK_REQUIRED`.
An unacknowledged downtime generation is announced at most once: the first recovery marks that generation announced, and later arms wait until a new down stretch mints a new generation.
A non-successor watcher start after an announced-but-unacked episode is a new down stretch and mints a fresh generation so buried decisions still resurface once.
Every watcher close and every durable queue append publishes downtime, so a downtime republication of any pending episode reuses its generation instead of minting a new one, and an already-announced generation stays announced.
That reuse keeps a watcher close inside the handling window from orphaning the acknowledgement already presented and trapping later arms in repeated recovery presentation.
An acknowledgement carries two separable facts: queue-row consumption is bound to the monotonic `--ack-through` sequence (further scoped per actor - see "Per-actor acknowledgement" below), while only retiring the episode is bound to `--recovery-generation`.
A generation mismatch therefore does not block consumption of rows through that sequence; it is a non-fatal result that names its own remedy - re-drain, then acknowledge the newer episode.
The acknowledgement retires the marker only when no rows remain after sequence-bound consumption.
A concurrently appended wake has a higher sequence, remains queued, and keeps the episode pending for presentation.
Consequently, an empty-queue downtime publication during handling can be retired by the outstanding acknowledgement without a dedicated recovery turn.
An acknowledged episode does not freeze the generation, because the next downtime after it opens an episode of its own.

## Per-actor acknowledgement

`bin/fm-wake-drain.sh` consumes the queue per actor, not per whole-queue cutoff, using `bin/fm-lease-lib.sh`'s existing `fm_lease_actor` identity (`FM_SUPERVISION_ACTOR`, unset or `main` for every non-Pi harness and Pi's own main session; `branch` only inside the Pi supervision branch's own bash tool calls, injected deterministically by the extension - never agent memory).
Every presented row is claimed to exactly one actor under the durable queue lock.
An ordinary presentation drain bounds both its initial queue-lock acquire and its later status-presentation-lock acquire at the deadline owned by the script header.
A live initial queue-lock holder produces one PID-naming advisory and skips the whole drain before any claim or mutation, while a live status-presentation-lock holder produces one such advisory after raw wake presentation and leaves status annotations, sections, and cursors retriable on the next drain.
Acknowledgement invocations and every other mutation-critical queue-lock acquire retain blocking semantics, so acknowledgement atomicity is unchanged.
Main records its presented set in `state/.main-eligible-rows`.
A branch grant is published through `bin/fm-wake-grant.sh` under that same lock in `state/.branch-eligible-rows`, bound to the live branch process and extension generation recorded in `state/.branch-eligible-owner`, and publication is refused if main already claimed any requested row.
A main drain validates that owner evidence under the queue lock and reclaims the grant when its process is gone or its identity no longer matches.
A main drain claims every currently unclaimed row and excludes an active branch grant from both presentation and acknowledgement.
Because that exclusion makes those rows invisible to main, `bin/fm-guard.sh`'s queued-wake warning counts only the rows the calling actor can itself present or retire, so an actor is never sent to a drain that provably has nothing for it.
`bin/fm-wake-lib.sh` owns that per-actor count (`fm_wake_actor_pending_count`) alongside the grant row-list and owner-record reads that the drain and `bin/fm-wake-grant.sh` share.
A row a live grant reserves is therefore never counted as drainable for main; rather than going silent about a visibly non-empty queue, the guard prints a distinct advisory naming the live supervision branch as the holder and saying not to drain those rows from here.
The branch actor's queued-wake output stays suppressed in every case.
A main drain with nothing of its own left, and a live grant still holding the queue, says so in one bounded line instead of exiting silently.
A row that lost the five appended fields or its numeric sequence can never be claimed, presented, or named by an `--ack-through` cutoff, so a main drain retires it under the queue lock and reports how many it removed together with those rows verbatim, bounded to the first 20 and a count of the rest, because the queue was their only durable record; a branch drain never does, because a grant can only name sequences that were structurally valid when it was published.
A retirement that cannot be read or written is reported and never fails the drain: the rows that remain usable are still presented with their acknowledgement command, the unusable ones stay queued for a later drain to retire, and failing the whole drain would strand the usable rows too.
Its `--ack-through <SEQ>` deletes only claimed main rows at or below the cutoff, while a branch acknowledgement deletes only claimed branch rows at or below its cutoff.
Every settled branch prompt releases any residual grant, so an omitted or failed acknowledgement leaves the durable row available to a later main drain; a successful acknowledgement has already removed it.
An acknowledgement whose cutoff removes none of the actor's rows while a presented row above the cutoff still waits is reported as having acknowledged nothing, together with the exact `--ack-through` and `--recovery-generation` command for that presented row; the presented set is read before any re-claim, so a row that arrived after presentation is never named for unseen acknowledgement.
If a branch offer loses the claim race to main, it rejects its settlement so the watcher retains the actionable close until Pi accepts its main follow-up.
[`pi-supervision-branch.md`](pi-supervision-branch.md#components-and-their-owners) owns branch eligibility, mixed-queue dispatch, the pre-drain recheck, and heartbeat's all-or-nothing rule.
A check-kind row is main-owned in every mode, including a heartbeat review, so it is never part of a branch claim and never defers one; main is woken for it on that check's own triggering close.
`fm-wake-drain.sh` filters the queue using the current actor's existing opaque claim before [presentation deduplication](#recorded-endpoint-loss), then presents and acknowledges only that actor-local view.
A missing or empty branch snapshot is refused loudly rather than read as "nothing eligible", because reaching the drain without the non-empty handoff promised by the extension is a wiring bug.
Because branch claims contain no check-kind rows, a branch acknowledgement skips check-specific receipt scans.
`tests/fm-wake-queue.test.sh`'s mixed-queue actor, stale-acknowledgement remedy, and presentation-deadline tests drive the real scripts: branch acknowledgement cannot swallow a main row, a concurrent main turn cannot present or acknowledge an active branch grant, a no-op stale acknowledgement names the current presented wake's exact command, live-holder presentation contention stays bounded and retriable, and acknowledgement locking remains blocking.
The same suite pins the counted-equals-presentable invariant against `bin/fm-guard.sh` and `bin/fm-wake-drain.sh` together: a branch-held row raises the held advisory rather than the ordinary queued-wake warning for main, and is presented with its acknowledgement command - with the ordinary warning restored - as soon as the grant clears, and structurally unusable rows are retired by main alone while every remaining row stays presentable and acknowledgeable.
`tests/fm-pi-branch-extension.test.sh` pins extension-side classification, claim publication and release, and the pre-drain recheck.

## Arm-layer cycle contract

`bin/fm-watch-arm.sh` never returns a clean empty success.
An actionable child output returns that reason normally.
A zero/empty child return rechecks the home lock and beacon, attaches to a verified healthy successor when one exists, or resolves the close against the watcher's bounded terminal-delivery ledger.
An attached arm follows verified identity-matched successors and resolves the same way when that chain ends without one, because it holds no handle on the watcher's stdout and cannot read the reason line itself.
Before releasing its singleton lock after printing an actionable reason, the watcher records that reason with its PID and process identity in `state/.watch-deliveries.log`.
A matching PID and identity lets an attached arm report the delivered reason and exit zero even after its durable wake was handled and acknowledged, while an unrelated queue producer or a recycled PID cannot satisfy the match.
Only a cycle with no matching delivery record emits `watcher: FAILED - cycle ended without an actionable reason` and exits nonzero.

The arm layer appends one tab-separated record per observed cycle to `state/.watch-cycle-exits.log`.
Each record includes arm and watcher PIDs, start and end timestamps, exit code and signal, classified reason, beacon age, lock identity before and after close, and successor disposition.
The file is size-capped through `FM_WATCH_CYCLE_LOG_MAX_BYTES` and `FM_WATCH_CYCLE_LOG_KEEP_LINES`.
`state/.watch-triage.log` remains only the watcher's bounded absorbed-wake debug log and carries no lifecycle semantics.

The watcher checks singleton lock ownership before updating `state/.last-watcher-beat` at cycle checkpoints, including between pending-reply records, around registered checks, and between slices of ordinary poll and signal-coalescing sleeps.
The mtime is authoritative for freshness, and the one-line content is informational.
The sleep slice limit is half the smaller positive value of the ordinary guard threshold (`FM_GUARD_GRACE`) and the watcher's resolved pre-acquisition threshold (`FM_WATCHER_STALE_GRACE`), rounded down and clamped to 1–150 seconds.
The slices add up to the requested sleep duration, including for a poll sleep entered after native event fallback.
The beacon is a progress signal, so a watcher that stops reaching checkpoints still ages out.
A native Herdr subscription waits uninterrupted, and an individual operation such as a check, recovery repost, or process-event launch keeps its own budget and can run past the freshness threshold between checkpoints.

When GNU `timeout` or `gtimeout` is available, the watcher uses the sleep slice limit as a deadline for each remote pending-reply observation.
At the deadline the capture process group gets a short shutdown allowance before KILL, and watcher shutdown also attempts to stop any active capture group.
After confirmed cleanup, a timed-out observation yields `unknown`, supplies no turn-completion evidence, and can be retried on a later poll while the reply is still pending.
If the watcher cannot verify that the remote capture group has no live members, it ends the cycle with an error.
Without GNU timeout, the watcher uses the ordinary remote observation path, whose queue wait can exceed the liveness grace.

## Regression coverage

`tests/fm-pi-watch-extension.test.sh` checks Pi's first-cycle-or-explicit-repair tool metadata and ownership-based redundant-call no-ops, then simulates actionable and empty child closes against the actual Pi and OpenCode close handlers, blocks prompt delivery to prove the successor launches first, verifies single-flight behavior, changes the session lock before close to prove ownership is rechecked, and hangs each successor arm to prove bounded fallback delivery includes the typed restoration failure.
The same suite covers ordinary same-process session replacement for `/new`, `/resume`, `/fork`, and reload, same-instance shutdown-plus-start, automatic re-arm before any model turn, a fresh extension-module rebind carrying all in-flight actionable closes exactly once, stale prior-generation callbacks, repeated transitions with exactly one live cycle, disappearance of the shutting-down refusal after a valid replacement activates, and terminal quit still refusing late rearm.
`tests/fm-watch-arm.test.sh` covers durable queue replay, real remote parent-replies ingestion into the authoritative status log, decision-only OPEN DECISIONS recovery, interrupted handling replay, generation-bound acknowledgement, a persistent live successor after recovery, a watcher close inside the handling window that must leave the printed acknowledgement valid, and the self-healing moved-generation acknowledgement that consumes its handled rows and names its remedy.
`tests/fm-watch-recovery-loop.test.sh` covers the once-per-generation announcement bound with the real Pi extension against a refused handling handshake, and a handling successor that must surface a real crew event instead of going blind.
`tests/fm-watcher-lock.test.sh` covers verified-successor attach, recovery publication before stale-lock removal, the typed self-eviction failure, bounded and successor-linked lifecycle rows, a poll's non-empty beacon that mtime-based readers judge by freshness alone and a size-based observer never reads as empty, and a SIGSTOP counterfactual that distinguishes a live PID from a stale beacon before classifying termination.
`tests/fm-subagent-pretool-check.test.sh` proves Claude retains only the non-status Bash seatbelts.
`tests/fm-claude-stop-autoarm.test.sh` covers the auto-arm's scope, stale and live session owners, unchanged AFK and need boundaries, single-flight, bounded failure retries, benign live-watcher cycle ends, one-notice failure episodes, and exit-2 translation.
It drives the real guard, watcher and Stop hook through a stalled remote observation, a long polling sleep, and a check sweep longer than the grace window, verifying delivery by the original owner and stale-beacon failure when the watcher stops making progress.
It checks observation cleanup on normal shutdown and Claude lease expiry, the errors and checkpoint receipt behavior when cleanup cannot be confirmed, and the operation budgets for checks, recovery reposts, and process-event launches.
It also covers generation-claim single-flight, stuck-claim supersession, superseded-owner silence, notice-marker refusal and retry, ownership-atomic episode reset, and the legacy upgrade shim; [`turnend-guard.md`](turnend-guard.md) owns those behavior contracts.
`FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh` starts with the reproduced stale-lock state, runs session start first, completes two immediate fixture cycles, and checks the competing-live-owner negative control.
It also runs a real parked watcher with a 40-second lease and 60-second native deadline, delivers an inbox note after that original deadline with no additional human turn, checks singleton ownership and exact acknowledgements, and verifies that held backlog alone does not renew.
Set `FM_CLAUDE_LIVE_E2E_KEEP=1` to retain the isolated transcripts and evidence.
`tests/fm-turnend-guard.test.sh` covers the cooperative `--claude` guard, including monotonic failed-epoch progression, the integrated bounded fail-open, post-alarm continuation suppression, and positive recovery reset; [`turnend-guard.md`](turnend-guard.md#regression-coverage) lists that suite's full generation and legacy claim coverage.

## Active limits and verification

The goal is continuity without a Pi, omp, or OpenCode model-memory re-arm step.
No zero-latency guarantee is claimed because lock verification, watcher startup, and bounded retry delays remain deliberate safety work.
OpenCode support targets persistent TUI sessions rather than headless `opencode run`.
Claude depends on the Stop `asyncRewake` rewake, Cursor depends on its awaited stop-hook park, Grok retains native background-completion notifications, and Codex retains bounded foreground checkpoints.

[`verification/supervision.md`](verification/supervision.md#watcher-continuity) records the current five-harness live evidence, the 2026-07-24 Stop-owned Claude auto-arm results, and exact opt-in commands.
