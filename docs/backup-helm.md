# Automatic Claude-runway backup helm

When Claude Max `all_models` projected runway drops under 12 hours, this home can hand the helm to a configured successor primary by itself.

The switch is armed in advance.
It is not exercised by installing this procedure, and it never targets a home until `bin/fm-backup-helm.sh arm` is run in that home with `FM_HOME` set.

`bin/fm-backup-helm.sh` owns the exact flags, the successor file format, the successor probe, and the fail-closed handover mechanics.

## Successor

The successor is named in `config/backup-helm-successor`, one line in the same `<harness> [<model>] [<effort>]` shape as `config/secondmate-harness`:

```sh
printf 'pi\n' > "$FM_HOME/config/backup-helm-successor"
```

There is no default successor.
An absent file, a file with no successor line, or a `default` harness makes arm refuse and say so, because a handover to a guessed successor is a safety net made of nothing.

Eligible successors are the verified primary harnesses other than Claude: `codex`, `pi`, `pi-signed`, `omp`, `opencode`, `grok`, and `cursor`.
Claude is refused because its runway is what triggers the handover, and crewmate-only harnesses such as `agy` are refused because they cannot hold a primary role.
A cursor successor needs an explicit model other than `auto`.
An effort the harness has no flag for is refused rather than silently dropped.

The successor must also have its tracked primary integration in the checkout it starts in, for example `.pi/extensions/` for Pi or `.cursor/hooks.json` for Cursor.

## Probe

Arm refuses unless the successor answers.
The probe sends one bounded headless request to the configured harness and model and requires the correct answer to a one-time question.
A model catalog or login check is not enough: a provider behind a billing block or a spent usage limit still lists its models, and only a real request shows it will not serve one.

The probe runs outside every git checkout with the home variables cleared, so no project hook can start a session or take a lock.
It prints one `probe=` line; on failure the line carries the provider's own one-line reason, such as an unpaid invoice or a usage limit.
Run `FM_HOME=/path/to/home bin/fm-backup-helm.sh probe` to check the configured successor without arming.

The handover probes the successor again before it touches Claude, because a provider can die between arming and firing.

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

Arm reads the successor, validates it, probes it, and freezes it into the watch.
Changing `config/backup-helm-successor` later does not change an armed watch: retire and re-arm to adopt a new successor.

The watch polls every 60 seconds and requires two consecutive true polls before it fires.
The handover itself is bounded at 3600 seconds.

Do not compose `bin/fm-procevent-when.sh` argv by hand for this watch.
Re-arm after changing `bin/fm-backup-helm.sh`, because the when adapter hash-binds the action executable.

## Handover

When the watch fires, the action is `bin/fm-backup-helm.sh handover` with the frozen home, successor, backend, target, and workspace.

1. Probe the successor again.
   Fail closed before touching Claude if it does not answer or its executable cannot be resolved.
2. Confirm the frozen pane still exists.
3. If the session lock is held by a live harness, wait until the Claude pane is idle.
   A mid-turn Claude is waited out.
   The action does not send Escape, does not interrupt, and does not `/exit` through a busy turn.
   If the idle bound expires, the action fails, Claude keeps the helm, and the lock file is left untouched.
4. Submit `/stow` into an empty Claude composer, then wait until idle again so session knowledge is filed before the process exits.
5. Submit `/exit`.
6. Wait until `bin/fm-lock.sh status` reads free or stale.
   Never delete `state/.lock` by hand.
   The successor's session start reclaims a free or stale lock.
7. In that same pane, launch the successor interactively in the checkout with `FM_HOME` bound, foreign harness markers cleared, its unattended-approval flags, and the session-start instruction as its first message, so it takes the helm and arms its own supervision without waiting for a captain message.
   A headless launch is never used.
8. Do not arm the watcher from this script.
   The successor's own supervision protocol owns it.
9. Do not restart Herdr.
   tmux and Herdr send into the existing pane; any other backend is refused.

If the lock is already free or stale when the action starts, `/stow` and `/exit` are skipped and only the successor launch runs.
If the lock is neither held by a live harness nor free or stale, the action fails closed and does not launch.

## After it fires

The when-watch is terminal.
Firstmate on the new helm drains an ordinary `when` wake, classifies it, acknowledges it, and retires the watch.
Do not run handover again from that wake.

A `fired` outcome means the successor was launched.
`action-failed` means Claude was left in place.
Read the captured output, then re-arm only after the blocker is gone.

## Switching back

This procedure does not switch back automatically after a Claude refresh.

To return to Claude later: `/stow` on the successor helm, exit it, wait for the lock to read free or stale without deleting it, then start interactive `claude` in that checkout with foreign harness markers cleared.
Do not use this script for that reverse path.

## Out of scope

Arming does not launch or lock another home.
Merge of the change that adds this procedure still waits for the captain.
Spawn model allowlisting is a separate change.
