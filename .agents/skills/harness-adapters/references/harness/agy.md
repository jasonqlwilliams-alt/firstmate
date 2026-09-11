# agy (Antigravity CLI)

Verified 2026-09-08 on Antigravity CLI 1.1.27 for crewmate and scout work only.
Not verified, and not currently verifiable, as a secondmate or primary: agy has no supervision protocol under `../../../../docs/supervision-protocols/`, and this task verified only the crewmate-side launch, trust, busy state, interrupt, and exit.
The captain's standing rule also keeps Antigravity out of owning coding, refs, merges, and deploys, so the primary and secondmate roles are exactly the shapes agy must not take.
The router owns that task-kind boundary, and `../../../../bin/fm-spawn.sh` refuses a `--secondmate` launch on agy the same way it refuses muse, gemini, and rovo.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `resolve_agy_binary` in `../../../bin/fm-spawn.sh` resolves `agy` from `PATH`, then falls back to `$HOME/.local/bin/agy`; spawning refuses if neither is executable. A single native Go executable, not a script bundle. |
| Launch | Foreign markers cleared, then `agy --dangerously-skip-permissions --add-dir <worktree> --add-dir <hook-root> [--model] [--effort] -i <one positional brief>`. `-i` is `--prompt-interactive`: it starts the supervised TUI AND auto-submits the brief, so no launch-then-send gate is needed. |
| Workspace | agy takes its workspace set from `--add-dir`, and a SINGLE `--add-dir` REPLACES it rather than extending it - see "Two workspaces" below. Without any `--add-dir`, shell tool calls default to the launch cwd, but the model may pass its own `Cwd` argument, so briefs must keep using absolute paths. |
| Busy state | `../../../bin/fm-busy-lib.sh` source `agy-hook`: the per-task `hooks.json` marks busy at `PreInvocation` and idle at `Stop`. Verified as a clean open/close pair in print mode AND in a supervised tmux pane. |
| Turn end | The same `Stop` hook touches `state/<id>.turn-ended`. `Stop` fires on normal turn end with `terminationReason` (`NO_TOOL_CALL` observed) and `fullyIdle`; a reply without `"decision":"continue"` lets the turn end. |
| Exit command | `/exit` (alias `/quit`), one Enter; prints `Resume with -c (or command below):` and an `agy --conversation=<uuid>` line. |
| Interrupt | Single Escape; renders an `Interrupted` line offering a new instruction and leaves the composer EMPTY, so no clear key. No hook fires - see "No interrupt or session-end event". |
| Skill invocation | `/<skill>`, the Claude and Grok form; `/skills` lists what is loaded. agy reads `.agents/skills/` in its workspaces, the same directory firstmate's own repo uses. |
| Model flag | `--model <id>`, validated before launch against `agy models`; an unlisted id is a HARD launch failure, not an ignored flag. |
| Effort flag | `--effort <low\|medium\|high>` only. `xhigh` and `max` are CAPPED onto `high` by the spawn rather than dropped, and the requested value is still recorded as `effort=` in task metadata. An unsupported value is a hard launch failure: `agy --effort xhigh -p hi` printed `invalid --effort "xhigh" (valid: low, medium, high)` and ran nothing. |
| Model discovery | `agy models` prints one `<id><TAB><label>` row per model the authenticated account can use. The observed live list (Gemini 3.8/3.7/3.6 Flash at three efforts each, Gemini 3.1 Pro, Claude Sonnet 4.6, Claude Opus 4.6 Thinking, GPT-OSS 120B) is per-account and must never be hardcoded. `agy -p "/usage"` reports quota. |
| Marker | `ANTIGRAVITY_AGENT=1` on tool subprocesses, alongside `ANTIGRAVITY_AGENTAPI_EXE`, `ANTIGRAVITY_CONVERSATION_ID`, `ANTIGRAVITY_LS_ADDRESS`, `ANTIGRAVITY_LS_VERSION`, `ANTIGRAVITY_PROJECT_ID`, `ANTIGRAVITY_SOURCE_METADATA`, and `ANTIGRAVITY_TRAJECTORY_ID`. Only `ANTIGRAVITY_AGENT` is an identity; the rest carry a path, an id, or a version. |
| Process name | `comm=agy` for the supervised pane process; `../../../bin/backends/tmux.sh` classifies that anchored name `agent`. |
| Composer | The existing `separated` shape - content rows between two solid `-` rules - whose content row carries a bare shell-family `>` glyph, with a footer that reads `? for shortcuts` at idle and `esc to cancel` while working. See "Composer verdict" below for the bounded consequence. |
| Autonomy | `--dangerously-skip-permissions` auto-approves every tool request; verified running a bash tool call in a supervised pane with no approval gate. It does NOT cover the workspace-trust dialog. |
| Trust | A real dialog on any folder agy has never seen - see "Workspace trust" below. |
| Resume | `-c/--continue`, `--conversation <id>`, and the id printed at exit; no verified pane-resume contract, so use deterministic relaunch. |
| Workspace residue | None. agy writes its transcripts and artifacts under `~/.gemini/antigravity-cli/`, never into the workspace, so a torn-down worktree carries nothing of agy's. |

## Two workspaces, and why both are load-bearing

The launch names the worktree AND a firstmate-owned hook root, in that order, and dropping either one breaks something specific.

A single `--add-dir <hook-root>` was verified to REPLACE the workspace set, not extend it: the agent's own file tool then reported `failed to read file: .../README.md: no such file or directory` for a file sitting in the launch cwd, and the `Stop` payload's `workspacePaths` listed only the hook root.
Naming the worktree first restores it, and the repeatable flag then carries both.

The hook root exists because agy loads `<workspace>/.agents/hooks.json` from EVERY workspace path, which was verified live for a hooks file outside the worktree.
Writing the hooks into the worktree's own `.agents/` instead would collide with a project's real customizations - it is where firstmate's own repo keeps `.agents/skills/` - and would leave an uncommitted file that `../../../bin/fm-teardown.sh` must refuse.
The global alternative is worse: agy's shared `~/.gemini/config/hooks.json` is the operator's own file and already carries other tools' entries, so a per-task write there would be fleet-wide contamination.
`../../../bin/fm-spawn.sh` therefore writes `state/<id>.agy-hooks/.agents/hooks.json` and teardown removes that whole root.

The hook contract itself: five events (`PreToolUse`, `PostToolUse`, `PreInvocation`, `PostInvocation`, `Stop`), the tool-scoped two using a `matcher`/`hooks` wrapper and the other three a flat handler array.
Each handler is `{"type":"command","command":"..."}` with an optional `timeout` (default 30s), run through `sh -c` with its working directory set to the directory holding `hooks.json`.
Context arrives as JSON on stdin (camelCase, including `conversationId`, `workspacePaths`, `transcriptPath`, `modelName`) and the result must be a JSON object on stdout.
Hooks run synchronously and block the agent loop.

## No interrupt or session-end event

agy's `Stop` hook was verified NOT to fire on a manual Escape interrupt: the turn ended, the pane rendered its `Interrupted` line, and no hook ran.
agy also has no session-end event at all, so `/exit` closes no record either.
The consequence is the same one Claude's interrupt has: an open busy record survives a cancelled or exited turn, and the live endpoint read - not a forged idle event - is what reclassifies it.
`../../../bin/fm-control-lib.sh` records `fm_control_interrupt_ack_source` as `none` for agy for exactly this reason, so the control plane sends the key and lets its own postcondition decide whether the agent stopped.
This is a real gap, stated rather than papered over; nothing here fakes a hook agy does not fire.

## Workspace trust

Every folder agy has never seen is gated by an interactive dialog reading `Do you trust the contents of this project?` with `> Yes, I trust this folder` preselected above `No, exit`.
`--dangerously-skip-permissions` does not cover it, so every fresh task worktree would hit it.
Firstmate's key plane cannot answer a dialog: it carries only Enter, Escape and C-c, it cannot see which row a future version preselects, and a reordered menu would make the same keystroke choose `No, exit`.
`../../../bin/fm-agy-trust.sh` therefore pre-registers the resolved worktree in agy's own store - the `trustedWorkspaces` array in `$HOME/.gemini/antigravity-cli/settings.json` - before launch, under the same structural worktree scope test and atomic read-modify-write that `../../../bin/fm-claude-trust.sh` uses.
Accepting the dialog by hand was verified to append exactly that path, and the next launch in the same worktree showed no dialog.
A refusal blocks the spawn rather than launching a worker that would park before reading its brief.

## Composer verdict: a known, bounded gap

agy draws the `separated` shape the shared classifier already knows, but its content row carries a bare `>` glyph rather than pi's blank row.
The shared classifier answers `unknown` for an idle agy composer, because `_fm_composer_pi_verdict` in `../../../bin/fm-composer-lib.sh` is gated on an identity of exactly `pi`.
This is deliberately left as is rather than widened, and the measurement is why: fed a real captured agy pane, pi's own row classifier returns `pending`, because the `>` glyph reads as typed content.
Extending the pi path to agy would therefore turn a safe `unknown` into a wrong `pending`, and `pending` is the ONE verdict that skips a steering doorbell (`../../../bin/fm-task-inbox-lib.sh`), so the "fix" would starve steering rather than improve it.
Under `unknown` the doorbell still rings, so ordinary steering works; the practical cost is bounded to away-mode injection, which declines to type into a pane it cannot prove empty, and agy is a crewmate/scout adapter that away mode never injects into anyway.
A real fix needs a harness-scoped glyph rule the shared classifier does not currently carry.

## Detection

`../../../bin/fm-harness.sh` tests `ANTIGRAVITY_AGENT=1` FIRST among the marker layer, and as a CONJUNCTION with anchored `agy` ancestry.
First, because agy scrubs nothing it inherits: a tool subprocess under a Claude-launched agy worker was verified carrying `CLAUDECODE=1` straight through, so any marker tested above agy's own would outrank it inside a real agy worker.
A conjunction, because `ANTIGRAVITY_AGENT` is a vendor name shared with the Antigravity desktop app and IDE, whose own `ANTIGRAVITY_*` variables this same binary carries; a terminal opened inside that app could export it with no agy CLI present, and a bare marker test would relabel every harness in that terminal.
Demanding a real anchored `agy` ancestor makes the marker a precedence override rather than evidence on its own, the same shape `FM_OMP_HARNESS` has for omp.
The anchored ancestry arm in the walk below covers a hand-started agy carrying no marker at all.
`../../../bin/fm-spawn.sh` additionally clears every foreign marker at agy's launch boundary, so both layers cover their own case exactly as cursor's and rovo's do.

agy is deliberately absent from `../../../bin/fm-session-lock-lib.sh`, which owns PRIMARY-session identity only: agy never holds a home's session lock, so the anchored arm in `../../../bin/backends/tmux.sh` is what classifies an agy pane as a live agent.

## Verification

`../../../../tests/fm-agy-harness.test.sh` is the portable regression: detection and marker precedence with real processes, tmux liveness, the control tables, busy-source trust, the launch line, the hook wiring, the trust pre-registration, the effort cap, model validation, and the secondmate refusal.
`../../../../docs/verification/agy.md` owns the dated live evidence behind each fact above and the commands that refresh it.
