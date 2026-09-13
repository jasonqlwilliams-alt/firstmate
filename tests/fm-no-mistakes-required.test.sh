#!/usr/bin/env bash
# Regression tests for the pinned shared no-mistakes gate action.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACTION_REF=32d396ac0f29135daf7fcb9964aba9d5f4e796d6
TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-required)
VERIFY="$TMP_ROOT/verify.py"
OLD_SHA=1111111111111111111111111111111111111111
NEW_SHA=2222222222222222222222222222222222222222
SIGNATURE='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
COMPLETED_STEPS='[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]'

fetch_shared_verifier() {
  command -v curl >/dev/null 2>&1 || fail "curl is required to exercise the pinned shared action"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to exercise the pinned shared action"
  curl --fail --silent --show-error --location \
    "https://raw.githubusercontent.com/kunchenguid/no-mistakes/${ACTION_REF}/.github/actions/require-no-mistakes/verify.py" \
    > "$VERIFY" || fail "could not fetch the pinned shared action verifier"
  [ -s "$VERIFY" ] || fail "the pinned shared action verifier was empty"
}

run_verifier() {
  local body=$1 head=$2
  PR_BODY="$body" PR_HEAD_SHA="$head" PR_AUTHOR=regression PR_NUMBER=3006 \
    python3 "$VERIFY" 2>&1
}

test_matching_head_and_completed_steps_pass() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$NEW_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  expect_code 0 "$rc" "shared action rejected an attestation bound to the current PR head"
  assert_contains "$output" "Found structurally compliant pipeline step attestation." \
    "shared action did not report the matching attestation as compliant"
  pass "shared action accepts a matching head_sha with completed required steps"
}

test_mismatched_head_fails_with_both_shas() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$OLD_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted an attestation from a different PR head"
  assert_contains "$output" "$OLD_SHA" \
    "mismatched-head failure did not name the attestation head SHA"
  assert_contains "$output" "$NEW_SHA" \
    "mismatched-head failure did not name the actual PR head SHA"
  pass "shared action rejects a mismatched head_sha and names both SHAs"
}

test_missing_head_fails() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted an attestation without head_sha"
  assert_contains "$output" "structured pipeline step attestation" \
    "missing-head failure did not explain that the attestation is invalid"
  pass "shared action rejects an attestation with no head_sha"
}

test_repair_push_event_requires_refreshed_attestation() {
  # GitHub's serialized event payload is the action's public input contract.
  # Exercise the same empty-input fallback used by the workflow, including the
  # stale body left by publishers that push a CI repair without attesting it.
  python3 - "$VERIFY" "$TMP_ROOT" "$SIGNATURE" "$COMPLETED_STEPS" "$OLD_SHA" "$NEW_SHA" <<'PY' || fail "repair-push event attestation lifecycle failed"
import json
import os
from pathlib import Path
import subprocess
import sys

verifier, root, signature, steps_json, old_sha, new_sha = sys.argv[1:]
steps = json.loads(steps_json)
event_path = Path(root) / "pull-request-event.json"
env = {
    key: value for key, value in os.environ.items()
    if not key.startswith(("PR_", "NM_EXEMPT_"))
    and key not in ("GITHUB_EVENT_PATH", "GITHUB_OUTPUT")
}
env["GITHUB_EVENT_PATH"] = str(event_path)

def verify_event(attested, head, action, expected):
    body = signature + "\n<!-- no-mistakes-pipeline-attestation:v1 " + json.dumps({
        "head_sha": attested, "steps": steps,
    }) + " -->"
    event_path.write_text(json.dumps({
        "action": action,
        "pull_request": {
            "number": 3006, "body": body,
            "head": {"sha": head, "ref": "repair-fixture"},
            "user": {"login": "regression"},
        },
    }), encoding="utf-8")
    result = subprocess.run(
        [sys.executable, verifier], env=env, capture_output=True, text=True,
    )
    assert result.returncode == expected, result.stdout + result.stderr
    if expected:
        assert attested in result.stderr and head in result.stderr, result.stderr

verify_event(old_sha, old_sha, "opened", 0)
verify_event(old_sha, new_sha, "synchronize", 1)
# Re-running the frozen event cannot repair its stale attestation.
verify_event(old_sha, new_sha, "synchronize", 1)
# A publisher's refreshed body must bind to the head carried by the new event.
verify_event(new_sha, new_sha, "edited", 0)
verify_event(new_sha, new_sha, "synchronize", 0)
verify_event(new_sha, old_sha, "edited", 1)
PY
  pass "repair-push events reject stale attestations and accept a matching refresh"
}

fetch_shared_verifier
test_matching_head_and_completed_steps_pass
test_mismatched_head_fails_with_both_shas
test_missing_head_fails
test_repair_push_event_requires_refreshed_attestation
