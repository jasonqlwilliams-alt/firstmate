# Automatic Claude-runway backup helm

When Claude Max `all_models` projected runway drops under 12 hours, this home can start the proven Cursor Grok 4.6 high primary by itself.

The switch is armed in advance.
It is not exercised by installing this procedure, and it never targets a home until `bin/fm-backup-helm.sh arm` is run in that home with `FM_HOME` set.

`bin/fm-backup-helm.sh` owns the exact flags, the Cursor catalog probe, and the fail-closed handover mechanics.

## Trigger

The trigger is Claude `all_models` runway from `quota-axi --json`.

It fires when that exact scope is `exhausted_now`, or when `runway.status` is `projected_exhaustion` and `usableRunwaySeconds` is under 43200 (12 hours).
A sibling Claude window at 0 percent, including a Fable model window, does not satisfy this watch.
Unknown quota stays false, so the watch keeps polling instead of acting on an unreadable snapshot.
A missing Claude provider, a missing `all_models` row, invalid JSON, or a missing `quota-axi` is an error and wakes firstmate without switching helms.

This is a firstmate-owned `when` watch named `backup-helm-claude-runway`.
It is not the percent-threshold quota adapter, and it does not use that adapter's best-scope status.

Do not arm `bin/fm-procevent-quota.sh` for this handover, and do not revive a retired percent-threshold Claude quota watch.
That watch treats any exhausted Claude window as exhausted, so a Fable window at 0 percent can wake while `all_models` still has hours of runway.

## Arm

Run this from the live Claude helm pane, with `FM_HOME` pointing at that operational home:

```sh
FM_HOME=/path/to/home bin/fm-backup-helm.sh arm
```

Pass `--backend` and `--target` when the pane cannot be discovered.
The frozen pane is the one `/stow` and `/exit` are typed into later.

Arm probes Cursor first and refuses if `cursor-agent --list-models` does not list exactly `cursor-grok-4.6-high`.
It also refuses unless the workspace contains `.cursor/hooks.json`, because Cursor project hooks do not load without `--trust` on that checkout.

The watch polls every 60 seconds and requires two consecutive true polls before it fires.
The handover itself is bounded at 3600 seconds.

Do not compose `bin/fm-procevent-when.sh` argv by hand for this watch.
Re-arm after changing `bin/fm-backup-helm.sh`, because the when adapter hash-binds the action executable.

## Handover

When the watch fires, the action is `bin/fm-backup-helm.sh handover` with the frozen home, backend, target, and workspace.

1. Probe Cursor Grok 4.6 high again.
   Fail closed if the catalog no longer contains that model, or if `cursor-agent` cannot be resolved.
2. Confirm the frozen pane still exists.
3. If the session lock is held by a live harness, wait until the Claude pane is idle.
   A mid-turn Claude is waited out.
   The action does not send Escape, does not interrupt, and does not `/exit` through a busy turn.
   If the idle bound expires, the action fails, Claude keeps the helm, and the lock file is left untouched.
4. Submit `/stow` into an empty Claude composer, then wait until idle again so session knowledge is filed before the process exits.
5. Submit `/exit`.
6. Wait until `bin/fm-lock.sh status` reads free or stale.
   Never delete `state/.lock` by hand.
   The next helm's session start reclaims a free or stale lock.
7. In that same pane, launch interactive Cursor with the proven primary contract:
   `--trust --yolo --workspace`, model `cursor-grok-4.6-high`, foreign harness markers cleared with `env -u`, and no `cursor-agent -p`.
8. Do not arm the watcher from this script.
   Cursor's stop-hook park owns it.
9. Do not restart Herdr.
   tmux and Herdr send into the existing pane; any other backend is refused.

The proven launch shape is the same interactive Cursor primary used by `tests/fm-cursor-primary-live-e2e.test.sh`.

If the lock is already free or stale when the action starts, `/stow` and `/exit` are skipped and only the Cursor launch runs.
If the lock is neither held by a live harness nor free or stale, the action fails closed and does not launch.

## After it fires

The when-watch is terminal.
Firstmate on the new helm drains an ordinary `when` wake, classifies it, acknowledges it, and retires the watch.
Do not run handover again from that wake.

A `fired` outcome means the Cursor helm was launched.
`action-failed` means Claude was left in place.
Read the captured output, then re-arm only after the blocker is gone.

## Switching back

This procedure does not switch back automatically after a Claude refresh.

To return to Claude later: `/stow` on the Cursor helm, `/exit`, wait for the lock to read free or stale without deleting it, then start interactive `claude` in that checkout with foreign Cursor markers cleared.
Do not use this script for that reverse path.

## Out of scope

Arming does not launch or lock another home.
Merge of the change that adds this procedure still waits for the captain.
Spawn model allowlisting is a separate change.
