---
name: lineup
description: >-
  Open an interactive Lavish board to choose harness, model, and effort for
  Firstmate roles and crew-dispatch tiers. Use on /lineup, /models, a request to
  choose the model lineup, or a procevent lavish wake whose source id matches the lineup board path.
metadata:
  internal: true
---

# Lineup

`bin/fm-lineup-board.sh --help` owns the payload, benchmark-cache, apply, filesystem, and command contracts.
This skill owns the agent's invocation and submission-resolution workflow.
The board uses the Firstmate design tokens from the shipped Bearings board.

## Open the board

1. Read the active home's dispatch configuration and role pins, and identify the live helm through `bin/fm-harness.sh` and its launch metadata.
   Read all existing dispatch rules, including their `when` and `why`, and the default; do not substitute a fixed list of tiers for the home's own rules.
   When no dispatch rules exist, show the roles and default only.
   Resolve inherited secondmate defaults through `bin/fm-harness.sh` and display the effective current tuple, explaining the inheritance in the reason.
   Show unset only when no effective choice exists, such as an unconfigured backup successor; suggest a concrete valid tuple before applying.
2. Load `quota-array-dispatch` and use its procedure to compute suggestions for every row from one fresh `quota-axi` snapshot.
   Load `harness-adapters` for catalog, authentication, provider discovery, and effort capability evidence.
   Establish every model/provider relation yourself; never infer it in a shell routing table.
   Record a plain-language reason for each suggestion, including any missing quota, authentication, or benchmark evidence.
   Keep unavailable quota values explicit rather than inventing headroom.
3. Compose the versioned board payload with current and suggested profiles, reasons, quota display strings, and concrete catalog-backed offered tuples per row.
   Include helm, backup helm successor, second mates, each existing dispatch rule, and the default.
   Offer the catalog-backed harness/model/effort combinations the operator can choose, including supported effort alternatives; do not restrict options to your suggestions.
   Use the board script's existing validators to preflight eligibility; a refusal is a request to fix the offered catalog, never permission to weaken a fence.
   A current legacy tuple may be displayed but must not be offered when it violates a fence.
   Ordered suggestions may include fallback candidates whose order you explain.
4. Run the board script's `build` command and return its verified live session URL.
   The script owns serving, reopening, listener proof, and process-event arming; never run a second conversational poll.
   Opening or rebuilding the board changes no dispatch settings.

## Benchmark evidence

Read the gitignored benchmark cache specified by the board script.
Each entry's task field is a board row id, so the board groups the evidence by the actual dispatch tasks rather than an invented global model ranking.
A missing cache, missing exact model match, or missing task match means `no public score`.
Never transfer a related model's score or invent a number for a preview, alias, or unlisted model.

During ordinary `/lineup` preparation, research the offered models against primary benchmark publishers and model vendors using the home's normal research dispatch procedure.
The research deliverable names exact evaluated model ids, benchmark versions, scores and units in benchmark labels, source URLs, and as-of dates.
Verify those sources and write only supported entries into the private cache; unsupported models retain no score.
Refresh supported cache entries before building the board.
Do not ship a real benchmark snapshot, a provider mapping, or operator-specific routing values in tracked files.

## Handle the board wake

Compare the wake's source id to `bin/fm-procevent-lavish.sh source-id` for the path returned by the lineup board script.
For a matching source load `process-event-sources` and follow its result-read, classify, and handled-acknowledgement contract.
Use `bin/fm-procevent-lavish.sh classify` and `read` on the captured result; consume every annotation and session-ending message, including feedback sent without clicking Apply.
An empty close changes nothing.
The board submits one `fm-lineup-answer.v1` choice with complete rows, fallback and restart booleans, and untruncated instructions, plus readable JSON in its choice text so the adapter presents the complete submission.
It intentionally has no captain-hold binding.

Resolve the entire submission yourself before invoking apply.
Typed instructions, including per-element notes and session-ending prose, take precedence over conflicting dropdown picks.
Keep dates and constraints explicit, preserve existing rule `when`/`why` provenance, and append a new rule for a newly requested exception rather than rewriting another rule's provenance.
If an instruction leaves the requested lineup ambiguous, obtain the missing decision before applying; do not silently apply conflicting picks.
Invalid combinations are refused and reported, never replaced silently with your suggestion.
Refresh catalog and eligibility evidence at apply time; the board's old options are evidence of what was offered, not authority to bypass a changed allowlist.

Compose the final resolved apply payload using the live canonical dispatch object, not board text as configuration authority.
Map rule rows by index only after comparing their captured exact `when` condition to the live configuration; rebuild a stale board rather than overwriting newer changes.
Preserve all existing fields except selected `use` profiles and the default.
Honor the explicit fallback-array choice; when off, emit single profile objects.
Include the original typed instructions and a plain explanation of how you resolved them whenever they are nonblank.
A helm change is a handover instruction only; never switch the live helm.
Restart is off unless the operator explicitly selected it or explicitly requested it in their typed instructions.
For an authorized restart, resolve the running secondmate ids from the live inventory and include only those ids in the resolved payload.

Run the apply subcommand only after all instructions have been resolved.
It rechecks fences, preserves provenance, publishes the three config files, propagates through `bin/fm-config-push.sh`, and calls `bin/fm-secondmate-restart.sh` only for explicit restart authorization.
Do not manually duplicate propagation or restart mechanics.
Report the profile changes, any helm handover instruction, restart outcome, and any propagation failure faithfully.
Persist standing or dated instructions through the existing captain-preference and process-event workflows where applicable; do not describe a dated rule as automatically expiring unless its expiry has actually been armed.
Acknowledge the captured event after handling, then rebuild from fresh state so Current reflects the saved lineup.
