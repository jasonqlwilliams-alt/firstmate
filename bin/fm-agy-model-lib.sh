#!/usr/bin/env bash
# The agy (Antigravity CLI) Gemini-only model rule.
# Sourced by bin/fm-spawn.sh, bin/fm-control.sh, and bin/fm-bootstrap.sh. This
# file is sourced by scripts and has no side effects on source.
#
# agy runs Gemini models only. Its own catalog (`agy models`) also lists
# Anthropic and OpenAI models, but those must run on each vendor's own harness:
# the `claude` harness for Anthropic models and the `codex` harness for OpenAI
# models. So every path that would launch agy - a fresh crewmate or scout
# spawn, a control-plane relaunch, and a dispatch profile that names agy -
# asks this one check before any launch side effect.
#
# An omitted model (no --model, an empty value, or `default`) is refused too:
# agy would then pick its own default, which this rule cannot vouch for.
#
# This is a single-harness rule, not a per-harness allowlist framework; the
# Cursor allowlist (config/cursor-model-allowlist) is a separate owner.

# fm_agy_model_allowed <model>: succeed silently for an explicit gemini-* id
# made only of the characters agy model ids use; otherwise print the refusal
# to stderr and fail.
fm_agy_model_allowed() {
  local model=${1:-}
  case "$model" in
    gemini-*[!A-Za-z0-9._-]*) ;;
    gemini-?*) return 0 ;;
  esac
  if [ -z "$model" ] || [ "$model" = default ]; then
    echo "error: agy runs Gemini models only and needs an explicit gemini-* model, but none was given (agy's own default model is not trusted); use the claude harness for Anthropic models or the codex harness for OpenAI models" >&2
  else
    echo "error: agy runs Gemini models only; refusing model '$model'; use the claude harness for Anthropic models or the codex harness for OpenAI models" >&2
  fi
  return 1
}
