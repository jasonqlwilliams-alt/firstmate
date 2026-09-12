#!/usr/bin/env bash
# Replay the changed test file, then exercise its generated hook interface.
# Usage: bash verify-agy-hooks.sh <worktree> <evidence-dir>
# The caller supplies TMPDIR inside the worktree for disposable fixtures.
set -uo pipefail
cd "$1" || exit 1
EVIDENCE_DIR=$2
export FM_TEST_SKIP_ORPHAN_REAP=1 FM_BACKEND=tmux
. tests/fm-agy-harness.test.sh

python3 - "$TMP_ROOT" "$ROOT" "$EVIDENCE_DIR" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

fixtures, root, evidence = map(Path, sys.argv[1:])
report = {
    "scope": "Real fm-spawn CLI and generated hooks; tmux and agy are fixture binaries, with no vendor session or model call.",
    "tasks": [],
}
for kind, task in [("ship", "agy-kind-ship-q7"), ("scout", "agy-kind-scout-q8")]:
    case = fixtures / f"kind-{kind}"
    state = case / "home/state"
    hooks_path = state / f"{task}.agy-hooks/.agents/hooks.json"
    assert hooks_path.is_file(), hooks_path
    assert not (case / "wt/.agents/hooks.json").exists()
    hooks = json.loads(hooks_path.read_text())
    item = {"kind": kind, "task": task, "hooks_path": str(hooks_path),
            "hooks_in_project_worktree": False, "lifecycle": []}
    def snapshot(event, expected_state, expected_source, expected_seq):
        record = (state / f"{task}.busy-state").read_text().strip()
        version, *fields = record.split()
        values = dict(field.split("=", 1) for field in fields)
        assert version == "v1"
        assert values["state"] == expected_state, record
        assert values["source"] == expected_source, record
        assert int(values["seq"]) == expected_seq, record
        result = subprocess.run(
            ["bash", "-c", '. "$1/bin/fm-busy-lib.sh"; fm_busy_classify tmux fake:w agy "$2" "$3"',
             "_", str(root), task, str(state)], text=True, capture_output=True, check=True)
        assert result.stdout.strip() == f"{expected_state} {expected_source}", result.stdout
        item["lifecycle"].append({"event": event, "busy_record": record,
                                  "classification": result.stdout.strip(),
                                  "turn_ended": (state / f"{task}.turn-ended").exists()})
    snapshot("spawn", "busy", "fm-spawn", 1)
    for event, expected_state, expected_seq in [("PreInvocation", "busy", 2), ("Stop", "idle", 3)]:
        replies = []
        for handler in hooks["fm-busy-state"][event]:
            assert handler["type"] == "command"
            result = subprocess.run(["bash", "-c", handler["command"]],
                                    text=True, capture_output=True, check=True)
            assert json.loads(result.stdout) == {}, result.stdout
            replies.append(result.stdout)
        snapshot(event, expected_state, "agy-hook", expected_seq)
        item["lifecycle"][-1]["hook_replies"] = replies
    assert item["lifecycle"][-1]["turn_ended"]
    for source, name in [(hooks_path, "hooks.json"), (case / "launch.log", "launch.txt"),
                         (state / f"{task}.meta", "meta.txt"),
                         (state / f"{task}.busy-state", "busy-state.txt")]:
        shutil.copyfile(source, evidence / f"{kind}-{name}")
    report["tasks"].append(item)

version = subprocess.run(["bash", "--noprofile", "--norc", "-c", "command -v actionlint && actionlint -version"],
                         text=True, capture_output=True, check=True)
assert version.stdout.splitlines()[1] == "1.7.12", version.stdout
report["actionlint"] = {"check": "PATH resolution and version metadata only; no lint run", "output": version.stdout}
(evidence / "hook-lifecycle.json").write_text(json.dumps(report, indent=2) + "\n")
(evidence / "actionlint-version.txt").write_text(
    "$ bash --noprofile --norc -c 'command -v actionlint && actionlint -version'\n" + version.stdout)
print(json.dumps(report, indent=2))
PY
expect_code 0 "$?" 'generated hooks must drive the recorded lifecycle for both task kinds'

# Remove a generated output after a successful real spawn. This tests whether
# the changed assertion actually catches a missing scout hook file.
(
  TMP_ROOT="$TMP_ROOT/missing-scout-hook"
  run_scout_spawn() {
    local home=$1 wt=$2 fakebin=$3 launchlog=$4 status
    shift 4
    FM_FAKE_LAUNCH_LOG="$launchlog" fm_test_run_spawn "$home" "$wt" "$fakebin" "$@" --scout
    status=$?
    if [ "$status" -eq 0 ]; then
      rm "$home/state/agy-kind-scout-q8.agy-hooks/.agents/hooks.json"
    fi
    return "$status"
  }
  test_ship_and_scout_launch_shapes_match
) > "$EVIDENCE_DIR/missing-scout-hook.log" 2>&1
mutation_status=$?
expect_code 1 "$mutation_status" 'the restored scout assertion must reject a missing generated hook file'
assert_grep 'an agy scout must get the same hook wiring as a crewmate' "$EVIDENCE_DIR/missing-scout-hook.log" 'failure must come from the restored behavioral assertion'
printf 'Missing-hook counterfactual: exit=%s; restored assertion rejected the missing scout hooks.\n' "$mutation_status"
cat "$EVIDENCE_DIR/missing-scout-hook.log"
