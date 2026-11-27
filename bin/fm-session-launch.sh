#!/usr/bin/env bash
# Usage: fm-session-launch.sh [--home <absolute-home>] -- <foreground-command> [args...]
# Drop any inherited launch context, then exec the foreground command with a
# fresh home-bound identity when that home has enabled launch ownership.
# A daemonizing command needs native registration in the continuing process.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-${SCRIPT_DIR%/*}}}"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
fm_session_owner_clear
if [ "${1:-}" = --home ] && [ "$#" -ge 3 ]; then
  FM_HOME=$2
  unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE
  shift 2
fi
if [ "${1:-}" != -- ] || [ "$#" -lt 2 ]; then
  echo 'usage: fm-session-launch.sh [--home <absolute-home>] -- <foreground-command> [args...]' >&2
  exit 2
fi
shift
FM_HOME=$(fm_session_owner_home) || exit 1
export FM_HOME
if fm_session_owner_enabled && ! fm_session_owner_bind "$$" launch; then
  echo 'error: cannot establish the session launcher process lifetime' >&2
  exit 1
fi
exec "$@"
