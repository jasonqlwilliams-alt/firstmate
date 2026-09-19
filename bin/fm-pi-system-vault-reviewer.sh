#!/usr/bin/env bash
# fm-pi-system-vault-reviewer.sh - Continuum system-vault review-only Pi harness.
#
# Single owner of the pinned model id, the Pi launch flags that make a review
# worker, catalog/model refusals for that posture, and validation of the review
# receipt JSON (the 2026-09-12 receipt shape, stored under the task's data/
# directory rather than the C: vault).
#
# Usage:
#   fm-pi-system-vault-reviewer.sh model
#   fm-pi-system-vault-reviewer.sh spawn-flags [--root <firstmate-root>]
#   fm-pi-system-vault-reviewer.sh check-model --model <id> [--bin <pi>]
#   fm-pi-system-vault-reviewer.sh validate-receipt <file>
#
# model
#   Print the pinned Pi model id. Rediscover before a live review with
#   `pi --list-models` and `pi auth check --provider openrouter --json --no-refresh`.
#   Do not install credentials. If that check is not ready, stop for a decision
#   rather than guessing another id.
#
# spawn-flags
#   Print the extra Pi CLI flags (trailing space, already shell-quoted paths)
#   that fm-spawn.sh inserts for --pi-posture system-vault-review.
#
# check-model
#   Refuse Fable 5, refuse the Hugging Face provider, and when `pi --list-models`
#   succeeds require the id to appear. An unreachable listing is not a verdict.
#
# validate-receipt
#   Accept a JSON object with the 2026-09-12 review-receipt keys and types.
#   The report path must live under a task data/ directory, not a Windows vault
#   mount.
#
# Model pin:
#   openrouter/anthropic/claude-sonnet-5
#   Discovered 2026-09-18 from live `pi --list-models` (Pi 0.84.1).
#   `pi auth check --provider openrouter --json --no-refresh` reported ready.
#   A live `pi --no-session --no-tools --model openrouter/anthropic/claude-sonnet-5
#   --thinking low -p` ping returned pong.
#   Hugging Face also had a stored key; a 2026-09-14 filing recorded Inference
#   Provider HTTP 402, so it is not the pin.
#   openrouter/anthropic/claude-fable-5 is in the catalog and is forbidden.
#
# Environment:
#   FM_ROOT_OVERRIDE  alternate firstmate root (tests).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

PINNED_MODEL='openrouter/anthropic/claude-sonnet-5'
REVIEW_TOOLS='read,grep,find,ls,bash'
PROMPT_REL='.agents/skills/system-vault-reviewer/prompt.md'
SKILL_REL='.agents/skills/system-vault-reviewer/reviewer'

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail_usage() {
  printf 'fm-pi-system-vault-reviewer: %s\n' "$*" >&2
  exit 2
}

fail_check() {
  printf 'fm-pi-system-vault-reviewer: %s\n' "$*" >&2
  exit 1
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

cmd_model() {
  printf '%s\n' "$PINNED_MODEL"
}

cmd_spawn_flags() {
  local root=$FM_ROOT prompt skill
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --root)
        [ "$#" -ge 2 ] || fail_usage "--root requires a value"
        root=$2
        shift 2
        ;;
      --root=*)
        root=${1#--root=}
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail_usage "unknown spawn-flags argument: $1"
        ;;
    esac
  done
  [ -n "$root" ] || fail_usage "--root must be non-empty"
  prompt="$root/$PROMPT_REL"
  skill="$root/$SKILL_REL"
  [ -f "$prompt" ] || fail_check "review prompt missing: $prompt"
  [ -f "$skill/SKILL.md" ] || fail_check "reviewer skill missing: $skill/SKILL.md"
  printf -- '--no-extensions --no-skills --no-prompt-templates --no-context-files --no-approve --tools %s --skill %s --append-system-prompt %s ' \
    "$REVIEW_TOOLS" "$(shell_quote "$skill")" "$(shell_quote "$prompt")"
}

model_is_fable() {
  local model=$1
  case "$model" in
    *[Ff][Aa][Bb][Ll][Ee]*) return 0 ;;
  esac
  return 1
}

model_is_huggingface() {
  local model=$1
  case "$model" in
    huggingface/*|HuggingFace/*|hf/*) return 0 ;;
  esac
  return 1
}

catalog_has_model() {
  local model=$1 provider id
  case "$model" in
    */*)
      provider=${model%%/*}
      id=${model#*/}
      ;;
    *)
      provider=
      id=$model
      ;;
  esac
  python3 -c '
import sys
model, provider, ident = sys.argv[1:4]
want = model.strip()
prov = provider.strip()
ident = ident.strip()
listing = sys.stdin.read()
for raw in listing.splitlines():
    line = raw.strip()
    if not line or line.lower().startswith("provider"):
        continue
    cols = line.split()
    if len(cols) < 2:
        continue
    cat_prov, cat_id = cols[0], cols[1]
    if cat_id.startswith("~"):
        cat_id = cat_id[1:]
    if want == f"{cat_prov}/{cat_id}" or want == cat_id:
        sys.exit(0)
    if prov and cat_prov == prov and cat_id == ident:
        sys.exit(0)
sys.exit(1)
' "$model" "$provider" "$id"
}

cmd_check_model() {
  local model="" bin="" listing
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --model)
        [ "$#" -ge 2 ] || fail_usage "--model requires a value"
        model=$2
        shift 2
        ;;
      --model=*)
        model=${1#--model=}
        shift
        ;;
      --bin)
        [ "$#" -ge 2 ] || fail_usage "--bin requires a value"
        bin=$2
        shift 2
        ;;
      --bin=*)
        bin=${1#--bin=}
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail_usage "unknown check-model argument: $1"
        ;;
    esac
  done
  [ -n "$model" ] || fail_usage "check-model requires --model"
  if model_is_fable "$model"; then
    fail_check "model '$model' is Fable; the system-vault-review posture never uses Fable 5"
  fi
  if model_is_huggingface "$model"; then
    fail_check "model '$model' uses Hugging Face; that provider is not the pin (2026-09-14 Inference Provider HTTP 402). Choose a live OpenRouter id from pi --list-models"
  fi
  if [ -z "$bin" ]; then
    return 0
  fi
  listing=$("$bin" --list-models 2>/dev/null) || {
    echo "notice: $bin --list-models was unreachable; launching '$model' unvalidated" >&2
    return 0
  }
  [ -n "$listing" ] || {
    echo "notice: $bin --list-models printed nothing; launching '$model' unvalidated" >&2
    return 0
  }
  if printf '%s\n' "$listing" | catalog_has_model "$model"; then
    return 0
  fi
  fail_check "model '$model' is not listed by '$bin --list-models'; choose a listed id or omit --model to use $PINNED_MODEL"
}

cmd_validate_receipt() {
  local file=${1-}
  [ -n "$file" ] || fail_usage "validate-receipt requires a file"
  [ -f "$file" ] || fail_check "receipt file missing: $file"
  python3 -c '
import json, re, sys

path = sys.argv[1]
required = (
    "session",
    "host",
    "reviewer",
    "model",
    "model_slug",
    "task",
    "reviewed_at",
    "final_verdict",
    "formal_rounds",
    "rounds",
    "reviewed_patch_sha256",
    "reviewed_companions_sha256",
    "preimage_hash_check",
    "report",
    "scope",
)
verdicts = {"APPROVE", "REVISE", "REJECT"}
sha = re.compile(r"^[a-fA-F0-9]{64}$")
vault_prefixes = (
    "/mnt/c/",
    "/mnt/e/",
    "/mnt/s/",
    "C:\\\\",
    "C:/",
    "c:\\\\",
    "c:/",
    "E:\\\\",
    "E:/",
    "S:\\\\",
    "S:/",
)

def fail(msg):
    print(f"fm-pi-system-vault-reviewer: {msg}", file=sys.stderr)
    sys.exit(1)

try:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
except json.JSONDecodeError as exc:
    fail(f"receipt is not JSON: {exc}")
except OSError as exc:
    fail(f"receipt unreadable: {exc}")

if not isinstance(data, dict):
    fail("receipt must be a JSON object")

missing = [key for key in required if key not in data]
if missing:
    fail("receipt missing keys: " + ", ".join(missing))

for key in ("session", "host", "reviewer", "model", "model_slug", "task", "reviewed_at", "report", "scope"):
    value = data[key]
    if not isinstance(value, str) or not value.strip():
        fail(f"{key} must be a non-empty string")

if data["final_verdict"] not in verdicts:
    fail("final_verdict must be APPROVE, REVISE, or REJECT")

rounds_n = data["formal_rounds"]
if not isinstance(rounds_n, int) or isinstance(rounds_n, bool) or rounds_n < 1:
    fail("formal_rounds must be an integer >= 1")

if not sha.fullmatch(str(data["reviewed_patch_sha256"])):
    fail("reviewed_patch_sha256 must be 64 hex characters")

companions = data["reviewed_companions_sha256"]
if not isinstance(companions, dict) or not companions:
    fail("reviewed_companions_sha256 must be a non-empty object of filename to sha256")
for name, digest in companions.items():
    if not isinstance(name, str) or not name.strip():
        fail("reviewed_companions_sha256 keys must be non-empty strings")
    if not isinstance(digest, str) or not sha.fullmatch(digest):
        fail(f"reviewed_companions_sha256[{name}] must be 64 hex characters")

if not isinstance(data["preimage_hash_check"], dict):
    fail("preimage_hash_check must be an object")

report = data["report"]
for prefix in vault_prefixes:
    if report.startswith(prefix):
        fail("report must be stored under the task data/ directory, not a Windows vault mount")
norm = "/" + report.replace("\\", "/")
if "/data/" not in norm:
    fail("report must be stored under the task data/ directory, not a Windows vault mount")

rounds = data["rounds"]
if not isinstance(rounds, list) or len(rounds) < 1:
    fail("rounds must be a non-empty array")
if len(rounds) != rounds_n:
    fail("formal_rounds must equal the length of rounds")

round_required = ("round", "verdict", "rationale", "concerns", "suggestions", "command")
for index, item in enumerate(rounds, start=1):
    if not isinstance(item, dict):
        fail(f"rounds[{index}] must be an object")
    missing_round = [key for key in round_required if key not in item]
    if missing_round:
        fail(f"rounds[{index}] missing keys: " + ", ".join(missing_round))
    if not isinstance(item["round"], int) or isinstance(item["round"], bool) or item["round"] < 1:
        fail(f"rounds[{index}].round must be an integer >= 1")
    if item["verdict"] not in verdicts:
        fail(f"rounds[{index}].verdict must be APPROVE, REVISE, or REJECT")
    if not isinstance(item["rationale"], str) or not item["rationale"].strip():
        fail(f"rounds[{index}].rationale must be a non-empty string")
    for list_key in ("concerns", "suggestions"):
        values = item[list_key]
        if not isinstance(values, list) or any(not isinstance(entry, str) for entry in values):
            fail(f"rounds[{index}].{list_key} must be an array of strings")
    command = item["command"]
    if not isinstance(command, dict):
        fail(f"rounds[{index}].command must be an object")
    for key in ("harness", "model_slug", "task", "launch"):
        value = command.get(key)
        if not isinstance(value, str) or not value.strip():
            fail(f"rounds[{index}].command.{key} must be a non-empty string")
' "$file"
}

main() {
  local cmd=${1:-}
  [ -n "$cmd" ] || fail_usage "missing command"
  shift || true
  case "$cmd" in
    -h|--help|help)
      usage
      exit 0
      ;;
    model)
      cmd_model "$@"
      ;;
    spawn-flags)
      cmd_spawn_flags "$@"
      ;;
    check-model)
      cmd_check_model "$@"
      ;;
    validate-receipt)
      cmd_validate_receipt "$@"
      ;;
    *)
      fail_usage "unknown command: $cmd"
      ;;
  esac
}

main "$@"
