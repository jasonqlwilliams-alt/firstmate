#!/usr/bin/env bash
# Regression tests for the pinned shared no-mistakes gate action.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACTION_REF=76fa0921a9797b09e120c8b5979c4d0e65f88922
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

write_live_pr_api_fixture() {
  # GitHub's pull request REST response is the pinned verifier's live input contract.
  cat > "$TMP_ROOT/live_pr_api.py" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from threading import Thread


def pr_facts(signature, head, attested, status="completed"):
    attestation = {
        "head_sha": attested,
        "steps": [{"step": step, "status": status} for step in ("review", "test", "document")],
    }
    return {
        "number": 3006,
        "user": {"login": "regression"},
        "head": {"sha": head, "ref": "regression"},
        "body": signature + "\n<!-- no-mistakes-pipeline-attestation:v1 " + json.dumps(attestation) + " -->",
    }


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.requests.append((self.path, self.headers.get("Authorization")))
        self.send_response(self.server.response_status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(self.server.payload).encode())

    def log_message(self, *args):
        pass


class LivePrApi:
    def __init__(self, verifier, root):
        self.verifier = verifier
        self.root = Path(root)

    def __enter__(self):
        self.server = HTTPServer(("127.0.0.1", 0), Handler)
        self.thread = Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        # No real credentials or runner output files may leak into this subprocess.
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("GITHUB_", "PR_", "NM_EXEMPT_"))}
        self.env.update({
            "GITHUB_API_URL": f"http://127.0.0.1:{self.server.server_port}",
            "GITHUB_TOKEN": "fixture-token",
            "GITHUB_REPOSITORY": "fixture/repository",
            "GITHUB_EVENT_PATH": str(self.root / "event.json"),
            "GITHUB_OUTPUT": str(self.root / "outputs"),
            "no_proxy": "127.0.0.1",
            "NO_PROXY": "127.0.0.1",
        })
        return self

    def __exit__(self, *exc):
        self.server.shutdown()
        self.thread.join()
        self.server.server_close()

    def verify(self, event, live, status=200, action=None):
        payload = {"pull_request": event}
        if action:
            payload["action"] = action
        (self.root / "event.json").write_text(json.dumps(payload), encoding="utf-8")
        (self.root / "outputs").write_text("", encoding="utf-8")
        self.server.payload, self.server.response_status, self.server.requests = live, status, []
        result = subprocess.run([sys.executable, self.verifier], env=self.env, capture_output=True, text=True, timeout=20)
        outputs = dict(line.split("=", 1) for line in (self.root / "outputs").read_text().splitlines())
        assert self.server.requests == [("/repos/fixture/repository/pulls/3006", "Bearer fixture-token")], \
            result.stdout + result.stderr
        return result, outputs
PY
}

test_live_pr_facts_override_cached_event() {
  python3 - "$VERIFY" "$TMP_ROOT" "$SIGNATURE" "$OLD_SHA" "$NEW_SHA" <<'PY' || fail "shared action live PR regression failed"
import sys

verifier, root, signature, old_sha, new_sha = sys.argv[1:]
sys.path.insert(0, root)
from live_pr_api import LivePrApi, pr_facts


def facts(head, attested, status="completed"):
    return pr_facts(signature, head, attested, status)


cases = [
    ("stale synchronize body with refreshed live attestation", facts(new_sha, old_sha), facts(new_sha, new_sha), 200, True),
    ("old passing event with a newly unattested head", facts(old_sha, old_sha), facts(new_sha, old_sha), 200, False),
    ("live skipped required steps", facts(old_sha, old_sha), facts(new_sha, new_sha, "skipped"), 200, False),
    ("API permission failure with a passing cached event", facts(old_sha, old_sha), {}, 403, False),
    ("malformed live response with a passing cached event", facts(old_sha, old_sha), {}, 200, False),
]
with LivePrApi(verifier, root) as api:
    for name, event, live, status, compliant in cases:
        result, outputs = api.verify(event, live, status)
        output = result.stdout + result.stderr
        assert result.returncode == (0 if compliant else 1), f"{name}: {output}"
        assert outputs.get("compliant") == str(compliant).lower(), f"{name}: {outputs}"
        assert outputs.get("exempt") == "false", f"{name}: {outputs}"
        print(f"ok - shared action handles {name}")
PY
}

test_repair_push_event_requires_refreshed_attestation() {
  # A CI repair push moves the PR head before older publishers refresh the body,
  # so each run and rerun of those events must judge the live body and head.
  python3 - "$VERIFY" "$TMP_ROOT" "$SIGNATURE" "$OLD_SHA" "$NEW_SHA" <<'PY' || fail "repair-push event attestation lifecycle failed"
import sys

verifier, root, signature, old_sha, new_sha = sys.argv[1:]
sys.path.insert(0, root)
from live_pr_api import LivePrApi, pr_facts

opened = (old_sha, old_sha)
stale = (new_sha, old_sha)
refreshed = (new_sha, new_sha)
other_head = (old_sha, new_sha)

with LivePrApi(verifier, root) as api:
    def verify(action, event, live, expected):
        result, outputs = api.verify(pr_facts(signature, *event), pr_facts(signature, *live), action=action)
        assert result.returncode == expected, result.stdout + result.stderr
        assert outputs.get("compliant") == ("false" if expected else "true"), outputs
        if expected:
            head, attested = live
            assert attested in result.stderr and head in result.stderr, result.stderr

    verify("opened", opened, opened, 0)
    verify("synchronize", stale, stale, 1)
    # Re-running the frozen event re-reads the live body, which is still stale.
    verify("synchronize", stale, stale, 1)
    # Once the publisher refreshes the body, its edit and a rerun of the frozen event both pass.
    verify("edited", refreshed, refreshed, 0)
    verify("synchronize", stale, refreshed, 0)
    verify("edited", other_head, other_head, 1)
PY
  pass "repair-push events reject stale attestations and accept a matching refresh"
}

fetch_shared_verifier
write_live_pr_api_fixture
test_matching_head_and_completed_steps_pass
test_mismatched_head_fails_with_both_shas
test_missing_head_fails
test_live_pr_facts_override_cached_event
test_repair_push_event_requires_refreshed_attestation
