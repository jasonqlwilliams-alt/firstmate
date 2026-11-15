# Recover a missing primary

Firstmate owns cold boot of its primary; the terminal backend restores topology, while the new primary restores fleet supervision from durable records.
Use [`bin/fm-primary-start.sh`](../bin/fm-primary-start.sh) from an ordinary operator terminal when the primary is absent.
Its header and `--help` own the exact flags, launch receipt, refusal behavior, readiness fields, and exit statuses.
The first version supports Herdr with Claude only.
It does not configure host autostart or restart a running primary.

## Start

Run the command from an installed Firstmate checkout, selecting the operational home and named Herdr session explicitly:

```sh
bin/fm-primary-start.sh start \
  --home /absolute/path/to/firstmate --backend herdr --session default \
  --harness claude
```

The home must already be a primary checkout with its tracked Claude hooks and private state directory.
Use the actual operational home rather than a task worktree or secondmate home.
The launch adopts the home's [Claude permission mode](configuration.md#claude-permission-mode-configclaude-permission-mode), including its fail-closed handling of invalid settings.
It selects no model or effort override.
The initial instruction is supplied once to interactive Claude; do not send another `fm` prompt after submission.

The launcher reuses a running compatible Herdr server or starts a positively stopped selected server through the existing backend owner.
It preserves other workspaces and creates a fresh launch pane only in a workspace with both the home's exact Herdr label and structural primary-home evidence, or creates a new home workspace.
A display-renamed helm workspace is not adopted on cold boot; the launcher creates a fresh primary workspace.
A label or old endpoint ID alone never authorizes adoption.
An already-live primary is reported without another launch or prompt.
It never stops, updates, deletes, moves, or reconfigures a server or pre-existing pane.

On a timeout or unknown create/launch outcome, inspect the retained launch receipt and exact pane before retrying.
The command deliberately refuses a queued or unaccounted partial launch rather than sending the startup instruction again.
Resolve any trust or first-use permission dialog interactively; the launcher does not answer it with keys.
Never delete the session lock to make a second primary start.

## Finish recovery in the primary

1. Read the native SessionStart digest and verify lock acquisition and completed initialization.
   If the hook did not deliver it, run session-start exactly once inside the new primary, following its normal startup contract.
2. Keep private utility tabs and relabel helpers deferred while the current startup generation recovers secondmates.
   The digest is composed concurrently with that recovery, so a completed digest does not establish that the deferred work finished.
3. Read `bin/fm-startup-network.sh report`, handle its results, and follow the existing secondmate recovery owners.
   If the stage is still running, use its bounded wait or ordinary completion wake; do not start a competing sweep.
   After a settled failed or incomplete run, its foreground `run --locked 1` path can retry under the lock-owning primary.
4. Verify readiness with the exact discovered primary workspace and session.
   Only after recovery is ready may a home-specific layout run, with those exact IDs.

```sh
bin/fm-primary-start.sh ready \
  --home /absolute/path/to/firstmate --backend herdr --session default \
  --harness claude --workspace <exact-workspace-id>
```

`agent_detected` proves an interactive primary was found; `primary_initialized` additionally binds its live process to the session lock and completed startup.
`recovery_ready` requires the current successful locked startup generation and verified secondmate endpoint ownership.
Readiness exits successfully for the initialized, recovered primary so it can gate a private layout.
It performs no repairs or lifecycle actions and starts no server.

Recovery verification needs the separate second-mate home-binding support whenever registered secondmates exist.
If local binding support is absent or remote control rejects the bound-home state check, readiness reports recovery as unverified and keeps the other results independent.
Missing, malformed, duplicate, foreign, or unreadable routes remain unready, including remote secondmates whose current binding cannot be confirmed.
An unreachable mate can therefore defer cosmetic tabs while the primary continues supervision.

`supervision_healthy` is a separate result: [Claude's emitted supervision protocol](supervision-protocols/claude.md) owns Stop-hook watcher arming and re-arming.
The outer launcher and readiness check never arm a second watcher.
During the first recovery turn, readiness can succeed before the first Stop arms the watcher; verify supervision health after that Stop when supervision is required.
Under Claude autoarm, a fresh watcher beacon remains healthy during the next turn after the watcher exits; stale or absent evidence is unhealthy unless the current autoarm recovery generation proves the handoff.
No watcher is needed when the home has no supervision demand.

## Ownership boundaries

Keep any home-specific layout behind the read-only readiness gate, immediately before its first side effect.
Private wrappers should select the home and session, then delegate to the tracked command.
The tracked launcher never executes private layout scripts.
Changing private helpers or standing home preferences is a separate operation for that home's owner.

The [backup helm](backup-helm.md) remains the owner of quota-triggered live handover to a successor in an existing pane.
The secondmate restart tool remains the owner of persist-before-restart updates to running secondmates.
Neither is a cold-boot prerequisite.

The fake-backed regression entry point is `bin/fm-test-run.sh tests/fm-primary-start.test.sh`.
It does not launch real harnesses or certify end-to-end interactive recovery on an operator's host.
