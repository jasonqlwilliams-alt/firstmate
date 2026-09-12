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

test_live_pr_facts_override_cached_event() {
  python3 - "$VERIFY" "$TMP_ROOT" "$SIGNATURE" "$OLD_SHA" "$NEW_SHA" <<'PY' || fail "shared action live PR regression failed"
import json
import os
from pathlib import Path
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from threading import Thread

verifier, root, signature, old_sha, new_sha = sys.argv[1:]
root = Path(root)


def facts(head, attested, status="completed"):
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


server = HTTPServer(("127.0.0.1", 0), Handler)
thread = Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    # No real credentials or runner output files may leak into this subprocess.
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("GITHUB_", "PR_", "NM_EXEMPT_"))}
    env.update({
        "GITHUB_API_URL": f"http://127.0.0.1:{server.server_port}",
        "GITHUB_TOKEN": "fixture-token",
        "GITHUB_REPOSITORY": "fixture/repository",
        "GITHUB_EVENT_PATH": str(root / "event.json"),
        "GITHUB_OUTPUT": str(root / "outputs"),
        "no_proxy": "127.0.0.1",
        "NO_PROXY": "127.0.0.1",
    })
    cases = [
        ("stale synchronize body with refreshed live attestation", facts(new_sha, old_sha), facts(new_sha, new_sha), 200, True),
        ("old passing event with a newly unattested head", facts(old_sha, old_sha), facts(new_sha, old_sha), 200, False),
        ("live skipped required steps", facts(old_sha, old_sha), facts(new_sha, new_sha, "skipped"), 200, False),
        ("API permission failure with a passing cached event", facts(old_sha, old_sha), {}, 403, False),
        ("malformed live response with a passing cached event", facts(old_sha, old_sha), {}, 200, False),
    ]
    for name, event, live, status, compliant in cases:
        (root / "event.json").write_text(json.dumps({"pull_request": event}), encoding="utf-8")
        (root / "outputs").write_text("", encoding="utf-8")
        server.payload, server.response_status, server.requests = live, status, []
        result = subprocess.run([sys.executable, verifier], env=env, capture_output=True, text=True, timeout=20)
        output = result.stdout + result.stderr
        assert result.returncode == (0 if compliant else 1), f"{name}: {output}"
        outputs = dict(line.split("=", 1) for line in (root / "outputs").read_text().splitlines())
        assert outputs.get("compliant") == str(compliant).lower(), f"{name}: {outputs}"
        assert outputs.get("exempt") == "false", f"{name}: {outputs}"
        assert server.requests == [("/repos/fixture/repository/pulls/3006", "Bearer fixture-token")], name
        print(f"ok - shared action handles {name}")
finally:
    server.shutdown()
    thread.join()
    server.server_close()
PY
}

fetch_shared_verifier
test_matching_head_and_completed_steps_pass
test_mismatched_head_fails_with_both_shas
test_missing_head_fails
test_live_pr_facts_override_cached_event
