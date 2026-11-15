#!/usr/bin/env bash
# Cold-start a missing primary without restarting its terminal server or fleet.
#
# Usage:
#   fm-primary-start.sh start --home <absolute-home> --backend herdr --session <name>
#     --harness claude
#   fm-primary-start.sh ready --home <absolute-home> --backend herdr --session <name>
#     --harness claude [--workspace <exact-id>]
#
# Only Herdr + Claude is supported. Home must be a primary checkout with its
# tracked Claude hooks and existing state directory, not a secondmate or task
# worktree. Session selection is mandatory, including for "default".
# start validates config/claude-permission-mode (absent/bypass or auto), holds
# state/.primary-start.lock using the shared lock owner, and reuses a proven
# home workspace or creates one. It launches only in a freshly returned pane,
# never in an arbitrary restored shell. It never closes or moves old panes.
# The per-pane command clears home/harness overrides, binds FM_HOME, and starts
# interactive Claude with one initial recovery instruction. Native SessionStart
# owns the session lock and recovery; Claude Stop owns watcher arm/re-arm.
# A live primary is reported without another launch or prompt. Unknown identity,
# live foreign lock ownership, or an ambiguous partial launch refuses. A receipt
# in state/.primary-start records partial effects; it is never pane authority.
# No force, lock-file deletion, resume, provider switch, or live refresh exists.
#
# ready is read-only, including when the server is stopped. It prints separate
# agent_detected, primary_initialized, recovery_ready, and supervision_healthy
# fields, plus exact discovered IDs and reasons for incomplete recovery.
# Exit 0 means initialized and recovery ready (the layout gate); 1 means pending;
# 2 means invalid input or ambiguous identity. Supervision is reported separately
# because the first Stop may arm it after a successful recovery turn.
# start exits 0 once the exact primary agent is detected, 2 on refusal/timeout;
# its output never equates agent detection with initialized/recovered/healthy.
# Detection polling is bounded internally after submission, not a model turn.
# Every CLI call has an explicit trailing --session. No default session is
# stopped, deleted, reselected, or reconfigured by this command.
#
# docs/primary-recovery.md owns the operator sequence and supported limits.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODE=${1:-}
case "$MODE" in -h|--help|help) sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit 0 ;; esac
[ "$#" -gt 0 ] && shift
PRIMARY_HOME='' PRIMARY_SESSION='' PRIMARY_BACKEND='' PRIMARY_HARNESS='' PRIMARY_WORKSPACE=
primary_die() { printf 'primary-start: %s\n' "$*" >&2; exit 2; }
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] && [ -n "$2" ] || primary_die "option $1 requires a value"
  case "$1" in
    --home) PRIMARY_HOME=$2 ;;
    --session) PRIMARY_SESSION=$2 ;;
    --backend) PRIMARY_BACKEND=$2 ;;
    --harness) PRIMARY_HARNESS=$2 ;;
    --workspace) PRIMARY_WORKSPACE=$2 ;;
    *) primary_die "unknown option $1" ;;
  esac
  shift 2
done
case "$MODE" in start|ready) ;; *) primary_die "expected start or ready; see --help" ;; esac
[ "$PRIMARY_BACKEND" = herdr ] && [ "$PRIMARY_HARNESS" = claude ] \
  || primary_die "only explicit --backend herdr --harness claude is supported"
case "$PRIMARY_HOME" in /*) ;; *) primary_die "--home must be absolute" ;; esac
case "$PRIMARY_SESSION" in ''|*[!A-Za-z0-9_-]*) primary_die "--session must be explicit and contain only letters, digits, _ or -" ;; esac
PRIMARY_HOME=$(cd -- "$PRIMARY_HOME" 2>/dev/null && pwd -P) || primary_die "home is unavailable"
# An operator may invoke this from another agent; ambient operational overrides
# must not redirect even read-only checks into that agent's home.
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
FM_HOME=$PRIMARY_HOME
export FM_HOME
STATE="$FM_HOME/state"
FM_WAKE_NO_MKDIR=1
# shellcheck source=bin/fm-primary-start-lib.sh
. "$SCRIPT_DIR/fm-primary-start-lib.sh"
primary_validate_home
fm_backend_herdr_tool_check || exit 2
if [ "$MODE" = ready ]; then
  primary_report
  exit $?
fi
[ -z "$PRIMARY_WORKSPACE" ] || primary_die "--workspace is a readiness constraint, not authority to launch in a pane"
fm_claude_permission_resolve "$FM_HOME/config" || exit 2
PRIMARY_CLAUDE=$(command -v claude) || primary_die "claude executable is unavailable"
case "$PRIMARY_CLAUDE" in /*) ;; *) primary_die "claude must resolve to an executable path" ;; esac
fm_lock_try_acquire "$STATE/.primary-start.lock" || primary_die "another primary launch is in progress"
trap 'fm_lock_release "$STATE/.primary-start.lock"' EXIT
primary_start
