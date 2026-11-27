#!/usr/bin/env bash
# Shared launch policies. No side effects on source.
# fm_claude_permission_resolve <config-dir> sets CLAUDE_PERMISSION_MODE and
# CLAUDE_PERM_FLAG, preserving spawn's fail-closed configuration semantics.
# fm_launch_environment_clear removes operational-home and harness identities
# before starting a long-lived terminal server. The same list supplies env -u
# arguments when starting a primary inside an already-running server's pane.

# shellcheck source=bin/fm-config-inherit-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-config-inherit-lib.sh"

FM_LAUNCH_CLEAR_NAMES=(
  FM_SESSION_OWNER_ID FM_SESSION_OWNER_HOME FM_SESSION_OWNER_PID
  FM_SESSION_OWNER_START FM_SESSION_OWNER_KIND
  FM_BOOTSTRAP_NETWORK_LOCK_PID FM_BOOTSTRAP_NETWORK_LOCK_GEN
  FM_BOOTSTRAP_NETWORK_WORKER_PID FM_BOOTSTRAP_NETWORK_WORKER_START
  FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE
  CURSOR_AGENT CURSOR_INVOKED_AS CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT FM_SUPERVISION_MODEL
)

fm_launch_environment_clear() {
  unset "${FM_LAUNCH_CLEAR_NAMES[@]}"
}

fm_claude_permission_resolve() {  # <config-dir>
  local file="$1/claude-permission-mode" present
  present=$(fm_config_source_present "$file") || return 1
  CLAUDE_PERMISSION_MODE=bypass
  if [ "$present" = 1 ]; then
    if [ ! -f "$file" ] || [ ! -r "$file" ]; then
      echo "error: config/claude-permission-mode must be a readable regular file holding one of: bypass, auto" >&2
      return 1
    fi
    CLAUDE_PERMISSION_MODE=$(tr -d '[:space:]' < "$file") || return 1
    case "$CLAUDE_PERMISSION_MODE" in
      bypass|auto) ;;
      *)
        echo "error: config/claude-permission-mode holds '$CLAUDE_PERMISSION_MODE'; accepted values are: bypass (--dangerously-skip-permissions, the default when the file is absent), auto (--permission-mode auto)" >&2
        return 1
        ;;
    esac
  fi
  # shellcheck disable=SC2034 # Output for launch callers.
  case "$CLAUDE_PERMISSION_MODE" in
    auto) CLAUDE_PERM_FLAG='--permission-mode auto' ;;
    *) CLAUDE_PERM_FLAG='--dangerously-skip-permissions' ;;
  esac
}
