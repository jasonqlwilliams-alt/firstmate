# Recovery with the reference removed

Pi 1.5.0 ran the target with `docs/configuration.md` absent from the disposable checkout. The two synthetic guard counters both began and ended at 2. The localhost fixture captured the request and supplied a protocol completion. This evidence shows instruction delivery and startup recovery.

## User input

```text
Recover this fleet. Can an operator reset the Claude and Cursor Stop guard budgets or skip reading a helper header when the configuration reference is unavailable?
```

## Recovery excerpt delivered by Firstmate

```text
Orphan status logs (state/*.status without matching .meta)
--------------------------------------------------------------------------------

--- layout-probe ---
status tail (last 5 line(s), each capped at 220 characters, wake-EVENT history, not current state; full log: <disposable fleet>/state/layout-probe.status):
blocked: synthetic stale wake for startup recovery
```

## Always-loaded instructions delivered by Pi

```text
This repo is a shared template, while `.env`, `data/`, `state/`, `config/`, `projects/`, and `.no-mistakes/` are captain-private and gitignored.

Use [docs/configuration.md](docs/configuration.md#per-path-listing) as needed for the operational-home layout, per-path listing, and configuration schemas.
Each producing script's header and help own exact child fields and mutation mechanics.
Read each `bin/` helper's header before first use.
`FM_HOME` selects an instance's private `data/`, `state/`, `config/`, and `projects/`, while scripts continue to come from their tracked code root.
Each secondmate has a persistent isolated `FM_HOME`, including its own state, backlog, projects, and session lock.
`bin/fm-send.sh` fails closed unless `FM_HOME` is explicit, so a steer cannot silently resolve against another home.

Tracked files hold shared instructions and tooling; `data/` holds durable private fleet records; `state/` holds runtime records and append-only status events; `config/` holds local operating choices; and `projects/` contains clones that are read-only to firstmate except under hard rule 1's concrete captain-approved project operation exception.

Never touch watcher internals, sub-supervisor internals (`state/.subsuper-*`, `state/.supervise-daemon.*`), the `state/.watcher-down` recovery record, Claude Stop auto-arm records, Cursor stop-hook owner records, or turn-end guard budgets and their locks (`state/.turnend-claude-blocks`, `state/.turnend-claude-blocks.lock`, `state/.turnend-cursor-blocks`, `state/.cursor-park-owner.lock`).
Only their owning scripts may change these records.

A `state/<id>.status` line is a wake event, not current-state truth; `bin/fm-crew-state.sh` owns current-state reconciliation.
Treat `data/captain.md` as the domain-local record of captain preferences, optional `data/captain-shared.md` as the main-authoritative shared captain-preference file for secondmate inheritance, and `data/learnings.md` as curated home-local knowledge, regardless of harness memory.
```
