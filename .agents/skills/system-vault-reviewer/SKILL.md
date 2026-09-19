---
name: system-vault-reviewer
description: >-
  Agent-only owner of Continuum system-vault review on a purpose-curated
  review-only Pi worker.
  Load before dispatching that review, before spawning the worker, and before
  treating its receipt as complete.
user-invocable: false
metadata:
  internal: true
---

# system-vault-reviewer

Load this before dispatching Continuum system-vault review, before spawning that review worker, and before treating its receipt as complete.
`../../../bin/fm-pi-system-vault-reviewer.sh` owns the pinned model id, Pi launch flags, model refusals, and receipt JSON validation.

This posture replaces the Codex-primary reviewer default recorded in the 2026-09-11 currentness pass.
It does not appoint Continuum agents, rewrite C: vault indexes, or run a live review by itself.

## When to spawn

Spawn one scout on Pi with this posture.
Do not use a ship worker, a secondmate, Cursor ACP, or a Fable 5 model.
Do not switch the shared no-mistakes pipeline agent.

The worker runs as an ordinary spawned Pi scout in an isolated disposable worktree of a project that can already read the vault named in the brief.
Do not clone continuum-system or other projects for the review, and do not write `/mnt/c`, `/mnt/e`, or `/mnt/s`.

## Model

Print the pin with `../../../bin/fm-pi-system-vault-reviewer.sh model`.
Before a live review, confirm it against current credentials:

1. `pi --list-models` lists the pin.
2. `pi auth check --provider openrouter --json --no-refresh` reports ready.
3. Do not pass `--credentials` and do not install keys.

If those checks are not ready, stop for a decision rather than guessing another model.
Never select a Fable 5 id.
Do not pin Hugging Face: a 2026-09-14 filing recorded Inference Provider HTTP 402.

## Spawn

Pass all of:

- `--scout`
- `--harness pi` (or `pi-signed`)
- `--pi-posture system-vault-review`
- `--model` set to the pin (omit only to let spawn apply that same pin)
- `--effort xhigh` unless a current instruction names another level

`fm-spawn.sh --help` owns flag parsing.
The posture refuses a ship, a secondmate, a non-Pi harness, Fable 5, and Hugging Face.
It allowlists Pi tools `read,grep,find,ls,bash`, appends the review prompt, loads only the reviewer skill, and disables skill, prompt-template, context-file, and extension discovery except the Firstmate-owned `-e` turn-end extension.

`bash` remains so the worker can hash, `git apply --check`, and write artifacts.
`edit` and `write` stay off.
The prompt and reviewer skill forbid writing the vault; the only durable writes are the task report and receipt.

## Record

The review is a scout deliverable:

- `data/<id>/report.md` is the human report.
- `data/<id>/review-receipt.json` is the machine receipt.

Both live in this Firstmate home's task `data/` directory, not in the C: vault.
Validate the receipt with `../../../bin/fm-pi-system-vault-reviewer.sh validate-receipt` before treating the review as complete.
That command owns the 2026-09-12 receipt shape: session, host, reviewer, model, model_slug, task, reviewed_at, final_verdict, formal_rounds, rounds, reviewed_patch_sha256, reviewed_companions_sha256, preimage_hash_check, report, and scope, plus the per-round command object.

Do not copy the receipt onto `C:\continuum-system`.
A `REVISE` verdict is evidence for the authoring worker, not authorization to apply a patch.
An `APPROVE` verdict is evidence for a separately authorized apply task.
