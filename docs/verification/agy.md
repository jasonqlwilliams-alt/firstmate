# agy (Antigravity CLI) adapter verification

Active empirical evidence for the agy crewmate and scout adapter.
Every fact below was measured against a real agy on the date named; nothing here is inferred from the vendor's documentation alone.
[`.agents/skills/harness-adapters/references/harness/agy.md`](../../.agents/skills/harness-adapters/references/harness/agy.md) is the operating reference that consumes these facts, and [`tests/fm-agy-harness.test.sh`](../../tests/fm-agy-harness.test.sh) is the portable regression that pins the resulting logic with no agy installed.

## Environment

Measured 2026-09-08 on Linux x86-64 (WSL2), Antigravity CLI 1.1.27, account signed in as a Google AI Ultra subscriber.

```
$ agy --version
1.1.27
$ file /home/jason/.local/bin/agy
ELF 64-bit LSB pie executable, x86-64 ... dynamically linked ... stripped
```

## Detection

`ANTIGRAVITY_AGENT=1` reaches tool subprocesses, and agy scrubs nothing it inherits.
Both halves come from one run: a print-mode turn was asked to dump its own tool environment while launched from a Claude Code session.

```
$ agy --dangerously-skip-permissions -p 'Run exactly this shell command ...: env | sort > .../env-dump.txt ...'
DONE.
$ grep -E '^(ANTIGRAVITY|CLAUDECODE)' env-dump.txt
ANTIGRAVITY_AGENT=1
ANTIGRAVITY_AGENTAPI_EXE=/home/jason/.local/bin/agy
ANTIGRAVITY_CONVERSATION_ID=cb762091-470e-49fe-a884-a8ba46503144
ANTIGRAVITY_LS_ADDRESS=localhost:43441
ANTIGRAVITY_LS_VERSION=cli-1.1.27
ANTIGRAVITY_PROJECT_ID=default-cli-project
ANTIGRAVITY_TRAJECTORY_ID=1be3d5ff-5016-4a1d-bbc1-dabe46d45d0a
CLAUDECODE=1
```

The inherited `CLAUDECODE=1` in that list is why `bin/fm-harness.sh` tests agy's marker before the `CLAUDECODE` line and why `bin/fm-spawn.sh` clears foreign markers at agy's launch boundary.
The marker is nonetheless required to appear alongside anchored `agy` ancestry, because the same `ANTIGRAVITY_*` namespace belongs to the Antigravity desktop app and IDE inside the same binary (`ANTIGRAVITY_EDITOR_READY`, `ANTIGRAVITY_EXTENSION_ACTIVATED`, `ANTIGRAVITY_SIDECAR_WEB_PORT` and others are present in it), so a terminal opened inside that app could export the name with no agy CLI running.

The live process name is the bare word `agy`:

```
$ ps -eo comm=,args= | grep -w agy
agy   agy --dangerously-skip-permissions -i Reply with exactly PONG and nothing else.
```

## Launch and workspace

`-i` (`--prompt-interactive`) starts the supervised TUI and auto-submits the brief with no extra Enter; the pane rendered the reply directly under the echoed prompt.

A SINGLE `--add-dir` REPLACES the workspace set rather than extending it.
Launched from a project directory with only the firstmate-owned hook directory added, the agent's own file tool could not see the project at all:

```
$ agy --dangerously-skip-permissions --add-dir <hooks-dir> -p 'Use your file-reading tool to read README.md ...'
TOOL-CANNOT-SEE-IT
... failed to read file: open <hooks-dir>/README.md: no such file or directory
```

and the hook payload's `workspacePaths` carried only `<hooks-dir>`.
Naming both restores the project and keeps the hook workspace:

```
$ agy --dangerously-skip-permissions --add-dir <project> --add-dir <hooks-dir> -p 'read README.md ... then run pwd'
probe
/.../agyprobe
workspacePaths = ['/.../agyprobe', '/.../agyhooks']
```

With no `--add-dir` at all, a shell tool call runs in the launch cwd, but the model may set its own `Cwd` argument on the call, so briefs must keep naming absolute paths.

## Hooks: the turn-end and busy source

agy loads `<workspace>/.agents/hooks.json` from every workspace path, including one outside the launch cwd.
A hooks file placed only in the added hook directory fired both handlers, in print mode and again in a supervised tmux pane.

The `Stop` payload observed at a normal turn end:

```json
{
  "conversationId": "8b9d0bd7-86f0-4210-a633-62e5b26aa4d4",
  "executionNum": 0,
  "error": "",
  "fullyIdle": true,
  "modelName": "gemini-3.8-flash-high",
  "terminationReason": "NO_TOOL_CALL",
  "transcriptPath": "/home/jason/.gemini/antigravity-cli/brain/<id>/.system_generated/logs/transcript_full.jsonl",
  "artifactDirectoryPath": "/home/jason/.gemini/antigravity-cli/brain/<id>",
  "workspacePaths": ["<hooks-dir>", "<project>"]
}
```

Two cautions recorded from that payload.
`workspacePaths` order is not stable: it matched the launch order in one run and was reversed in another, so nothing may key off position.
`fullyIdle` read `true` while a backgrounded shell task the same turn had started was still running, so it is not a reliable "everything finished" signal and firstmate does not read it.

`Stop` does NOT fire on a manual interrupt.
Escape sent mid-stream rendered `Interrupted . What should Antigravity CLI do instead?` and left the composer empty, and the hook's marker file was never recreated:

```
$ rm -f stop-hook.json ; <send Escape mid-turn> ; ls -l stop-hook.json
ls: cannot access 'stop-hook.json': No such file or directory
```

agy also exposes no session-end event; its five hook types are `PreToolUse`, `PostToolUse`, `PreInvocation`, `PostInvocation`, and `Stop`.
An interrupted or exited turn therefore leaves an open busy record standing, exactly as Claude's interrupt does, and the live endpoint read is what reclassifies it.

## Workspace trust

A fresh worktree is gated before the brief is read.
The dialog as captured from the pane:

```
Do you trust the contents of this project?

Antigravity CLI requires permission to read, edit, and execute files here.

> Yes, I trust this folder
  No, exit
```

`--dangerously-skip-permissions` does not suppress it; the launch above carried that flag and still showed the dialog.
Accepting it appended exactly the launched path to `trustedWorkspaces` in `~/.gemini/antigravity-cli/settings.json`, and the next launch in the same directory showed no dialog:

```
$ diff settings-before.json ~/.gemini/antigravity-cli/settings.json
14c14,15
<     "/home/jason/kun-agent-workspace"
---
>     "/home/jason/kun-agent-workspace",
>     "/.../scratchpad/agyprobe"
```

That store is a two-space pretty-printed JSON object whose other keys are `enableTelemetry` and `permissions`, which is the format [`bin/fm-agy-trust.sh`](../../bin/fm-agy-trust.sh) preserves.

## Autonomy, exit, and interrupt

`--dangerously-skip-permissions` auto-approved a bash tool call in a supervised pane with no gate; the busy pane rendered a braille spinner plus `Running command...` and a footer reading `esc to cancel`, against `? for shortcuts` at idle.

`/exit` (alias `/quit`) plus Enter exits cleanly and prints the resume line:

```
Resume with -c (or command below):
agy --conversation=84436b82-9899-4eb8-83be-cad8dd909af8
```

## Model and effort vocabularies

`agy models` reaches the account and lists ids the launch accepts.
The listing on the measured account was Gemini 3.8, 3.7, and 3.6 Flash at three efforts each, Gemini 3.1 Pro at two, `claude-sonnet-4-6`, `claude-opus-4-6-thinking`, and `gpt-oss-120b-medium`.
Both axes fail HARD rather than being ignored, which is why the spawn validates the model and caps the effort:

```
$ agy --effort xhigh -p 'hi'
Error: invalid model selection (--model "" --effort "xhigh"): invalid --effort "xhigh" (valid: low, medium, high)
$ agy --model not-a-real-model -p 'hi'
Error: invalid model selection (--model "not-a-real-model" --effort ""): model not-a-real-model is not recognized as a known model or custom model in settings
$ agy --effort high -p 'Reply OK'
OK
```

## Composer classification

agy draws the `separated` shape - a content row between two solid horizontal rules - whose content row carries a bare `>` glyph.
Fed a real captured idle pane, `bin/fm-composer-lib.sh` finds a valid separator pair and reaches the identity-gated verdict, which answers `unknown` because that verdict is scoped to an identity of exactly `pi`:

```
$ _fm_composer_scan_screen "$plain" 8
UNSAFE=0 BOX_TOP=-1 PI_PAIR_VALID=1 PI_OPEN=7 PI_CLOSE=9 SHELL_ROW=8
$ fm_composer_classify_screen "styled=1 cursor=1 identity=1" "$screen" 8 "pi<TAB>idle"
pending
```

That second line is the measurement that keeps the pi path from being widened to agy: pi's row classifier reads agy's `>` glyph as typed content, so extending it would replace a safe `unknown` with a wrong `pending`, and `pending` is the one verdict that SKIPS a steering doorbell in `bin/fm-task-inbox-lib.sh`.
`unknown` still rings the doorbell, so steering works; the gap is left open and documented rather than closed with a change that would break it.

## Workspace residue

None.
After a full launch, tool call, interrupt, and exit cycle, the project directory contained only its own files; agy's transcripts and artifacts live under `~/.gemini/antigravity-cli/`.

## Refreshing this record

Re-run the commands above against the installed agy after a version bump, and run [`tests/fm-agy-harness.test.sh`](../../tests/fm-agy-harness.test.sh) for the portable half.
A live opt-in guard in the `live-harness-optin` family does not yet exist for agy; adding one is the natural next step if agy is ever promoted beyond crewmate and scout work.
