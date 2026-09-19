#!/usr/bin/env bash
# Behavior tests for the system-vault review-only Pi harness.
#
# Drive bin/fm-pi-system-vault-reviewer.sh and fm-spawn.sh through public
# commands. Do not assert implementation-source bytes of the skill or prompt.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

REVIEWER="$ROOT/bin/fm-pi-system-vault-reviewer.sh"
TMP_ROOT=$(fm_test_tmproot fm-pi-system-vault-reviewer)
PIN='openrouter/anthropic/claude-sonnet-5'

make_reviewer_pi() {
  local fakebin=$1
  cat > "$fakebin/pi" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --help ]; then
  printf '%s\n' 'Pi 0.84.1' 'Options: --help --tui-mode <mode>'
  exit 0
fi
if [ "${1:-}" = --list-models ]; then
  [ "${FM_FAKE_PI_LIST_STATUS:-0}" -eq 0 ] || exit "${FM_FAKE_PI_LIST_STATUS}"
  printf '%s\n' "${FM_FAKE_PI_MODELS:-provider     model
openrouter   anthropic/claude-sonnet-5                           1M       128K     yes       yes
openrouter   anthropic/claude-fable-5                            1M       128K     yes       yes
huggingface  deepseek-ai/DeepSeek-R1                             64K      32.8K    yes}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/pi"
  cp "$fakebin/pi" "$fakebin/pi-signed"
}

make_spawn_world() {
  local name=$1 harness=${2:-pi} case_dir home proj wt fakebin launchlog id=$3
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  chmod +x "$fakebin/timeout"
  make_reviewer_pi "$fakebin"
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@"
}

read_case_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

sample_receipt() {
  local path=$1 report=${2:-"$TMP_ROOT/data/task/report.md"}
  python3 -c '
import json, sys
path, report = sys.argv[1], sys.argv[2]
digest = "a" * 64
payload = {
    "session": "sess-1",
    "host": "pi",
    "reviewer": "pi",
    "model": "openrouter/anthropic/claude-sonnet-5",
    "model_slug": "openrouter/anthropic/claude-sonnet-5",
    "task": "vault-review-sample",
    "reviewed_at": "2026-09-18T00:00:00Z",
    "final_verdict": "APPROVE",
    "formal_rounds": 1,
    "rounds": [
        {
            "round": 1,
            "verdict": "APPROVE",
            "rationale": "Mechanical checks passed.",
            "concerns": [],
            "suggestions": [],
            "command": {
                "harness": "pi",
                "model_slug": "openrouter/anthropic/claude-sonnet-5",
                "task": "vault-review-sample",
                "launch": "fm-spawn.sh vault-review-sample proj --scout --harness pi --pi-posture system-vault-review",
            },
        }
    ],
    "reviewed_patch_sha256": digest,
    "reviewed_companions_sha256": {"file-hashes.json": digest},
    "preimage_hash_check": {"git_apply_check": "ok"},
    "report": report,
    "scope": "Independent review of a documentation patch.",
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh)
' "$path" "$report"
}

test_helper_prints_pin() {
  local out
  out=$("$REVIEWER" model)
  assert_equals "$PIN" "$out" "model pin drifted from the live OpenRouter discovery"
  pass "helper prints the pinned OpenRouter Sonnet 5 id"
}

test_helper_spawn_flags_are_review_only() {
  local flags
  flags=$("$REVIEWER" spawn-flags --root "$ROOT")
  assert_contains "$flags" "--tools read,grep,find,ls,bash" "spawn flags omitted the review tool allowlist"
  assert_contains "$flags" "--no-skills" "spawn flags omitted --no-skills"
  assert_contains "$flags" "--no-prompt-templates" "spawn flags omitted --no-prompt-templates"
  assert_contains "$flags" "--no-context-files" "spawn flags omitted --no-context-files"
  assert_contains "$flags" "--no-extensions" "spawn flags omitted --no-extensions"
  assert_contains "$flags" "--no-approve" "spawn flags omitted --no-approve"
  assert_contains "$flags" "--skill '$ROOT/.agents/skills/system-vault-reviewer/reviewer'" \
    "spawn flags omitted the reviewer skill path"
  assert_contains "$flags" "--append-system-prompt '$ROOT/.agents/skills/system-vault-reviewer/prompt.md'" \
    "spawn flags omitted the review prompt path"
  assert_not_contains "$flags" "--tools read,grep,find,ls,bash,edit" "spawn flags enabled edit"
  assert_not_contains "$flags" "--tools read,grep,find,ls,bash,write" "spawn flags enabled write"
  pass "spawn flags are the review-only Pi tool and resource posture"
}

test_helper_spawn_flags_refuse_missing_prompt() {
  local out status=0
  out=$("$REVIEWER" spawn-flags --root "$TMP_ROOT/missing-root" 2>&1) || status=$?
  expect_code 1 "$status" "spawn-flags should refuse a missing prompt"
  assert_contains "$out" "review prompt missing" "missing prompt did not name the prompt"
  pass "spawn-flags refuses when the review prompt is absent"
}

test_helper_refuses_fable_and_huggingface() {
  local out status
  out=$("$REVIEWER" check-model --model 'openrouter/anthropic/claude-fable-5' 2>&1) || status=$?
  expect_code 1 "${status:-0}" "Fable 5 should be refused"
  assert_contains "$out" "Fable" "Fable refusal did not name Fable"

  status=0
  out=$("$REVIEWER" check-model --model 'huggingface/deepseek-ai/DeepSeek-R1' 2>&1) || status=$?
  expect_code 1 "$status" "Hugging Face should be refused"
  assert_contains "$out" "Hugging Face" "Hugging Face refusal did not name the provider"
  pass "helper refuses Fable 5 and Hugging Face without guessing another model"
}

test_helper_catalog_miss_refuses_and_unreachable_is_not_a_verdict() {
  local fakebin out status
  fakebin=$(fm_fakebin "$TMP_ROOT/catalog-fake")
  make_reviewer_pi "$fakebin"

  status=0
  out=$("$REVIEWER" check-model --model 'openrouter/anthropic/claude-sonnet-4.6' --bin "$fakebin/pi" 2>&1) || status=$?
  expect_code 1 "$status" "unlisted model should be refused when the catalog is readable"
  assert_contains "$out" "not listed" "catalog miss did not name the listing"

  status=0
  out=$(FM_FAKE_PI_LIST_STATUS=1 "$REVIEWER" check-model --model "$PIN" --bin "$fakebin/pi" 2>&1) || status=$?
  expect_code 0 "$status" "unreachable catalog should not block the pin"
  assert_contains "$out" "unreachable" "unreachable catalog did not report uncertainty"
  pass "catalog miss refuses; unreachable listing is not a verdict"
}

test_receipt_accepts_shape_and_rejects_vault_report() {
  local ok bad status out
  ok="$TMP_ROOT/ok-receipt.json"
  bad="$TMP_ROOT/bad-receipt.json"
  sample_receipt "$ok" "$TMP_ROOT/data/vault-review-sample/report.md"
  "$REVIEWER" validate-receipt "$ok" || fail "valid task-data receipt was rejected"

  sample_receipt "$bad" "/mnt/c/continuum-system/Reports/review-receipt.json"
  status=0
  out=$("$REVIEWER" validate-receipt "$bad" 2>&1) || status=$?
  expect_code 1 "$status" "vault-mounted report path should be refused"
  assert_contains "$out" "task data/" "vault report refusal did not name task data/"

  sample_receipt "$bad" "/tmp/vault-review-sample/report.md"
  status=0
  out=$("$REVIEWER" validate-receipt "$bad" 2>&1) || status=$?
  expect_code 1 "$status" "report outside task data/ should be refused"
  assert_contains "$out" "task data/" "non-data report refusal did not name task data/"

  python3 -c '
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
del data["final_verdict"]
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh)
' "$ok"
  status=0
  out=$("$REVIEWER" validate-receipt "$ok" 2>&1) || status=$?
  expect_code 1 "$status" "receipt missing final_verdict should be refused"
  assert_contains "$out" "final_verdict" "missing-key refusal did not name the key"
  pass "receipt validator accepts the 2026-09-12 shape and refuses vault storage"
}

test_spawn_applies_posture_defaults_and_flags() {
  local rec id out status launch
  id=vault-review-scout-z1
  rec=$(make_spawn_world posture-defaults pi "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --scout --harness pi --pi-posture system-vault-review)
  status=$?
  expect_code 0 "$status" "review-only Pi scout should spawn"
  assert_contains "$out" "spawned $id harness=pi kind=scout" "spawn did not report the Pi scout"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--model '$PIN'" "launch omitted the pinned model"
  assert_contains "$launch" "--thinking 'xhigh'" "launch omitted default xhigh thinking"
  assert_contains "$launch" "--tools read,grep,find,ls,bash" "launch omitted the review tool allowlist"
  assert_contains "$launch" "--no-skills" "launch omitted --no-skills"
  assert_contains "$launch" "--no-prompt-templates" "launch omitted --no-prompt-templates"
  assert_contains "$launch" "--no-context-files" "launch omitted --no-context-files"
  assert_contains "$launch" "--no-approve" "launch omitted --no-approve"
  assert_contains "$launch" "--skill '$ROOT/.agents/skills/system-vault-reviewer/reviewer'" \
    "launch omitted the reviewer skill"
  assert_contains "$launch" "--append-system-prompt '$ROOT/.agents/skills/system-vault-reviewer/prompt.md'" \
    "launch omitted the review prompt"
  assert_contains "$launch" "-e '$HOME_DIR/state/$id.pi-ext.ts'" "launch dropped the turn-end extension"
  assert_grep "pi_posture=system-vault-review" "$HOME_DIR/state/$id.meta" "meta omitted pi_posture"
  assert_grep "model=$PIN" "$HOME_DIR/state/$id.meta" "meta omitted the pinned model"
  assert_grep "effort=xhigh" "$HOME_DIR/state/$id.meta" "meta omitted default xhigh"
  pass "scout spawn applies the review-only Pi posture, pin, and xhigh default"
}

test_normal_pi_scout_omits_review_posture() {
  local rec id out status launch
  id=vault-review-plain-z6
  rec=$(make_spawn_world posture-plain pi "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --scout --harness pi --model "$PIN" --effort high)
  status=$?
  expect_code 0 "$status" "ordinary Pi scout should still spawn"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--model '$PIN'" "ordinary launch omitted the requested model"
  assert_contains "$launch" "--thinking 'high'" "ordinary launch omitted requested thinking"
  assert_not_contains "$launch" "--tools read,grep,find,ls,bash" "ordinary launch gained the review tool allowlist"
  assert_not_contains "$launch" "--no-skills" "ordinary launch gained --no-skills"
  pass "ordinary Pi scout launch is unchanged without the review posture"
}

test_spawn_refuses_ship_non_pi_fable_and_unknown_posture() {
  local rec id out status
  id=vault-review-ship-z2
  rec=$(make_spawn_world posture-ship pi "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --harness pi --pi-posture system-vault-review)
  status=$?
  expect_code 1 "$status" "ship plus review posture should be refused"
  assert_contains "$out" "scout-only" "ship refusal did not say scout-only"
  assert_absent "$HOME_DIR/state/$id.meta" "ship refusal wrote meta"

  id=vault-review-claude-z3
  rec=$(make_spawn_world posture-claude claude "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --scout --harness claude --pi-posture system-vault-review)
  status=$?
  expect_code 1 "$status" "claude plus review posture should be refused"
  assert_contains "$out" "pi or pi-signed" "non-Pi refusal did not name pi"

  id=vault-review-fable-z4
  rec=$(make_spawn_world posture-fable pi "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --scout --harness pi --pi-posture system-vault-review \
    --model 'openrouter/anthropic/claude-fable-5')
  status=$?
  expect_code 1 "$status" "Fable 5 should be refused at spawn"
  assert_contains "$out" "Fable" "spawn Fable refusal did not name Fable"
  assert_absent "$HOME_DIR/state/$id.meta" "Fable refusal wrote meta"

  id=vault-review-hf-z7
  rec=$(make_spawn_world posture-hf pi "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --scout --harness pi --pi-posture system-vault-review \
    --model 'huggingface/deepseek-ai/DeepSeek-R1')
  status=$?
  expect_code 1 "$status" "Hugging Face should be refused at spawn"
  assert_contains "$out" "Hugging Face" "spawn Hugging Face refusal did not name the provider"
  assert_absent "$HOME_DIR/state/$id.meta" "Hugging Face refusal wrote meta"

  id=vault-review-bogus-z5
  rec=$(make_spawn_world posture-bogus pi "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --scout --harness pi --pi-posture review-only)
  status=$?
  expect_code 1 "$status" "unknown posture should be refused"
  assert_contains "$out" "system-vault-review" "unknown posture did not name the accepted value"
  pass "spawn refuses ship, non-Pi, Fable 5, Hugging Face, and unknown posture before records exist"
}

test_spawn_pi_signed_applies_posture() {
  local rec id out status launch
  id=vault-review-signed-z8
  rec=$(make_spawn_world posture-signed pi-signed "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --scout --harness pi-signed --pi-posture system-vault-review)
  status=$?
  expect_code 0 "$status" "review-only pi-signed scout should spawn"
  assert_contains "$out" "spawned $id harness=pi-signed kind=scout" "spawn did not report the pi-signed scout"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--model '$PIN'" "pi-signed launch omitted the pinned model"
  assert_contains "$launch" "--tools read,grep,find,ls,bash" "pi-signed launch omitted the review tool allowlist"
  assert_grep "harness=pi-signed" "$HOME_DIR/state/$id.meta" "meta omitted pi-signed"
  assert_grep "pi_posture=system-vault-review" "$HOME_DIR/state/$id.meta" "pi-signed meta omitted pi_posture"
  pass "pi-signed scout spawn applies the review-only posture"
}

test_helper_prints_pin
test_helper_spawn_flags_are_review_only
test_helper_spawn_flags_refuse_missing_prompt
test_helper_refuses_fable_and_huggingface
test_helper_catalog_miss_refuses_and_unreachable_is_not_a_verdict
test_receipt_accepts_shape_and_rejects_vault_report
test_spawn_applies_posture_defaults_and_flags
test_normal_pi_scout_omits_review_posture
test_spawn_refuses_ship_non_pi_fable_and_unknown_posture
test_spawn_pi_signed_applies_posture

echo "# all fm-pi-system-vault-reviewer tests passed"
