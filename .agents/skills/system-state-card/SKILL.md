---
name: system-state-card
description: >-
  Read the generated live SYSTEM_STATE card instead of browsing Atlas or the
  vault for current revisions, holds, or routing.
  Load before answering what is live now, and before walking C:\continuum-system
  or the Atlas mount for those facts.
user-invocable: false
metadata:
  internal: true
---

# system-state-card

Load this before answering "what is live now" and before browsing Atlas, the vault Matrix, or `C:\continuum-system` for live revisions, runtime holds, or model routing.

The generated card is the live overlay.
Vault files remain SOPs.
Northstar remains outcomes.
Do not copy live SHAs into those files.

## Read the card

1. Open `data/system-state.md` in the effective Firstmate home (`FM_HOME`).
2. Treat it as unknown and regenerate when the file is absent, unreadable, or older than its `ttl` (default 60m).
   Compare `generated_at` to now; do not trust mtime alone when the header is present.
3. Regenerate with `bin/fm-system-state-card.sh` (no model tokens).
   The script header owns probes, publish paths, and flags.
4. If generate cannot run, say the live facts are unknown.
   Do not walk Atlas to fill the gap.

## Do not browse

For live rev, hold, or routing facts, stop.

Do not walk `C:\continuum-system`, the Atlas vault mount, or the Matrix banner to learn those facts.

Packet Router `Evidence/SYSTEM_STATE.md` is the same card for Atlas, Eleusis, Grokbots, and Windows sessions after Eleusis publishes the named C: target.

## Pointers, not copies

Session-start prints one `SYSTEM_STATE:` line.
Crew briefs tell workers to read this card.
Rakazo Atlas and Eleusis get a one-line instruction pointer through the locked patch path, not a copied card.
