---
name: system-vault-review
description: >-
  Independent adversarial review of a Continuum system-vault documentation
  patch.
  Use on every system-vault review turn to run mechanical checks, reach a
  verdict, and write the task report plus receipt JSON.
user-invocable: false
metadata:
  internal: true
---

# system-vault-review

You are the independent reviewer, not the patch author.
Read the brief, the patch bundle, and the live vault bytes.
Do not edit the patch and do not write the vault.

## Safety

Do not write `/mnt/c`, `/mnt/e`, `/mnt/s`, `C:\`, `E:\`, or `S:\`.
Do not clone repositories.
Do not appoint a reviewer, change a grant, declare Notion retired, or promote an E/Arch/S path.
Scratch copies for `git apply` belong under `/tmp` and must be deleted.

## Mechanical checks

For each formal round, against the patch the brief names:

1. Confirm every `before_sha256` in `file-hashes.json` matches the live vault file.
2. Confirm new-file targets are absent when the bundle says they are new.
3. Run `git apply --check` and apply into a scratch git copy.
4. Confirm every `after_sha256`, that line endings are preserved, and that `git status` shows only declared paths.
5. Check citations at their sources.
6. Resolve relative links added by the patch.

Record those results in `preimage_hash_check`.

## Verdicts

Use exactly `REVISE`, `APPROVE`, or `REJECT`.

- `REVISE` when concerns are addressable without new evidence gathering, or when a snapshot would land already stale against records the author could read.
- `APPROVE` only for the exact `reviewed_patch_sha256` you checked, when every concern from prior rounds is fixed or explicitly non-blocking.
- `REJECT` when the patch is out of scope, unsafe, or unsupported after a revision.

Non-blocking notes do not change an `APPROVE`.
Taking a note that changes patch bytes requires another formal round against the new hash.

## Artifacts

Write only these two files under the Firstmate task `data/<id>/` directory from your instructions, never under the C: vault:

- `report.md` - the human report, including round table, mechanical checks, and concern disposition.
- `review-receipt.json` - the machine receipt.

The receipt must match the 2026-09-12 shape owned by `bin/fm-pi-system-vault-reviewer.sh validate-receipt`.
Required top-level keys: `session`, `host`, `reviewer`, `model`, `model_slug`, `task`, `reviewed_at`, `final_verdict`, `formal_rounds`, `rounds`, `reviewed_patch_sha256`, `reviewed_companions_sha256`, `preimage_hash_check`, `report`, `scope`.

Set `host` to `pi`.
Set `reviewer` to `pi`.
Set `model` and `model_slug` to the id you actually ran.
Set `report` to the absolute task-data path of `report.md`.
Each `rounds[]` entry includes `round`, `verdict`, `rationale`, `concerns`, `suggestions`, and `command` with `harness`, `model_slug`, `task`, and `launch`.

`concerns` and `suggestions` are arrays of strings.
`formal_rounds` equals the length of `rounds`.
`reviewed_patch_sha256` and each companion digest are 64 lowercase or mixed hex characters.

After writing both files, stop.
A later apply task, not this review, may land an approved patch.
