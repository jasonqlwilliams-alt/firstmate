#!/usr/bin/env bash
# Automatic Claude-runway backup helm.
#
# Arms a firstmate-owned condition->action watch that starts the proven Cursor
# Grok 4.6 high primary when Claude's all_models usableRunwaySeconds drops
# under 12 hours. The trigger reads that exact all_models row; a sibling Claude
# window at 0% (for example Fable) must not satisfy it. Do not revive a
# retired percent-threshold quota watch for this handover.
#
# Usage:
#   fm-backup-helm.sh arm [options]
#   fm-backup-helm.sh condition [options]
#   fm-backup-helm.sh probe
#   fm-backup-helm.sh handover --backend <tmux|herdr> --target <target> [options]
#   fm-backup-helm.sh retire
#   fm-backup-helm.sh source-id
#
# arm        Probe Cursor Grok, freeze the live Claude pane, and register
#            when-watch "backup-helm-claude-runway" through fm-procevent-when.sh.
#            FM_HOME must be explicit. Run this from the live Claude helm pane,
#            or pass --backend and --target. Does not start the handover.
# condition  One quota-axi evaluation for the when adapter: exit 0 when Claude
#            all_models runway is exhausted_now or usableRunwaySeconds is below
#            the threshold, 1 when the condition is cleanly false, 2 on error.
#            Unknown quota is false, not an error, so the watch keeps polling.
# probe      Fail closed unless a verified cursor-agent catalog contains exactly
#            cursor-grok-4.6-high. Prints one probe= line.
# handover   The when-watch action. Waits for an idle Claude pane, sends /stow,
#            sends /exit, waits for the session lock to read free or stale, then
#            launches interactive Cursor Grok 4.6 high in that pane. Never
#            deletes state/.lock, never restarts Herdr, never uses cursor-agent
#            -p, and never launches Composer, Claude, Opus, Fable, GPT, Gemini,
#            or auto. A mid-turn Claude is waited out; the action fails closed
#            rather than interrupting if the idle bound expires.
# retire     Retire the when-watch. Idempotent.
# source-id  Print the canonical when-watch source id.
#
# Arm options, before any frozen handover flags:
#   --backend <tmux|herdr>   freeze this backend instead of discovering it
#   --target <target>         freeze this pane instead of discovering it
#   --workspace <abs>         Cursor --workspace (must contain .cursor/hooks.json)
#   --interval <secs>          when-watch poll cadence (default 60)
#   --stable <n>              consecutive true polls to fire (default 2)
#   --action-timeout <secs>  bound on handover (default 3600)
#   --runway-seconds <n>      trigger threshold (default 43200)
#   --provider <id>          quota-axi provider (default claude)
#   --scope <scope>          quota-axi scope (default all_models)
#
# Handover options:
#   --home <abs>              operational home (otherwise FM_HOME is required)
#   --backend <tmux|herdr>   required unless frozen by arm
#   --target <target>         required unless frozen by arm
#   --workspace <abs>        Cursor workspace
#
# Environment:
#   FM_HOME                      required for arm, handover, and retire
#   FM_BACKUP_HELM_IDLE_TIMEOUT  seconds to wait for Claude to go idle (default 1200)
#   FM_BACKUP_HELM_STOW_TIMEOUT  seconds to wait after /stow (default 1200)
#   FM_BACKUP_HELM_LOCK_TIMEOUT   seconds to wait for lock free/stale (default 180)
#   FM_BACKUP_HELM_POLL          idle/lock poll interval seconds (default 2)
#   FM_BACKUP_HELM_DRIVER         test-only driver: target-exists|lock-status|busy|composer|send|launch
#
# The operator procedure is docs/backup-helm.md. This header owns flags and
# failure mechanics.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

WATCH_NAME=backup-helm-claude-runway
DEFAULT_PROVIDER=claude
DEFAULT_SCOPE=all_models
DEFAULT_RUNWAY_SECONDS=43200
HELM_MODEL=cursor-grok-4.6-high
STOW_COMMAND=/stow
EXIT_COMMAND=/exit

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
die_cond() { printf 'error: %s\n' "$1" >&2; exit 2; }

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}

positive_int() { case "${1-}" in ''|*[!0-9]*) return 1 ;; 0) return 1 ;; *) return 0 ;; esac }

positive_number() {
  local n=${1-}
  local LC_ALL=C
  [[ "$n" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  [ "$n" != 0 ] && [[ ! "$n" =~ ^0+(\.0+)?$ ]]
}

provider_valid() {
  local LC_ALL=C
  [[ "${1-}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
}

scope_valid() {
  [ -n "${1-}" ] || return 1
  case "$1" in *$'\n'*|*$'\t'*) return 1 ;; esac
}

backend_supported() {
  case "${1-}" in tmux|herdr) return 0 ;; *) return 1 ;; esac
}

require_home() {
  if [ -z "${FM_HOME:-}" ]; then
    die "FM_HOME is not set; refusing to resolve another home"
  fi
  [ -d "$FM_HOME" ] || die "FM_HOME '$FM_HOME' is not a directory"
  STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
}

abs_path() {
  local path=$1 dir base
  [ -n "$path" ] || return 1
  case "$path" in
    /*) ;;
    *) die "path must be absolute: $path" ;;
  esac
  dir=$(CDPATH='' cd -- "$(dirname -- "$path")" 2>/dev/null && pwd -P) || return 1
  base=$(basename -- "$path")
  printf '%s/%s\n' "$dir" "$base"
}

default_workspace() {
  if [ -f "$FM_HOME/.cursor/hooks.json" ]; then
    printf '%s\n' "$FM_HOME"
    return 0
  fi
  if [ -f "$FM_ROOT/.cursor/hooks.json" ]; then
    printf '%s\n' "$FM_ROOT"
    return 0
  fi
  return 1
}

# --- probe -------------------------------------------------------------------

cmd_probe() {
  # shellcheck source=bin/fm-cursor-lib.sh
  . "$SCRIPT_DIR/fm-cursor-lib.sh"
  local bin list
  bin=$(fm_cursor_resolve_binary) || {
    printf 'probe=cursor-grok status=unavailable model=%s\n' "$HELM_MODEL"
    return 1
  }
  list=$(fm_cursor_list_models "$bin") || {
    printf 'probe=cursor-grok status=indeterminate model=%s\n' "$HELM_MODEL"
    return 1
  }
  if printf '%s\n' "$list" | fm_cursor_catalog_has_model "$HELM_MODEL"; then
    printf 'probe=cursor-grok status=ok model=%s bin=%s\n' "$HELM_MODEL" "$bin"
    return 0
  fi
  printf 'probe=cursor-grok status=missing-model model=%s\n' "$HELM_MODEL"
  return 1
}

# --- condition ---------------------------------------------------------------

quota_json() {
  local timeout=${1:-20} output
  # shellcheck source=bin/fm-quota-axi-lib.sh
  . "$SCRIPT_DIR/fm-quota-axi-lib.sh"
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$SCRIPT_DIR/fm-timeout-lib.sh"
  fm_quota_axi_compatible "$timeout" >/dev/null 2>&1 || return 2
  output=$(fm_run_timed "$timeout" quota-axi --json 2>/dev/null </dev/null) || return 2
  printf '%s\n' "$output" | fm_quota_json_valid || return 2
  printf '%s\n' "$output"
}

cmd_condition() {
  local provider=$DEFAULT_PROVIDER scope=$DEFAULT_SCOPE threshold=$DEFAULT_RUNWAY_SECONDS
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --provider) [ -n "${2-}" ] || die_cond "--provider needs a value"; provider=$2; shift 2 ;;
      --scope) [ -n "${2-}" ] || die_cond "--scope needs a value"; scope=$2; shift 2 ;;
      --runway-seconds) positive_int "${2-}" || die_cond "--runway-seconds needs a positive integer"; threshold=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  provider_valid "$provider" || die_cond "invalid provider: $provider"
  scope_valid "$scope" || die_cond "invalid scope: $scope"
  local json verdict
  json=$(quota_json 20) || die_cond "quota-axi --json failed or is missing, incompatible, or invalid"
  # Exact scope only. The quota adapter's best-scope / any-exhausted_now
  # classifier is the wrong trigger: a Fable window at 0% must not fire this
  # watch while all_models still has runway.
  verdict=$(printf '%s\n' "$json" | jq -r --arg provider "$provider" --arg scope "$scope" --arg threshold "$threshold" '
    ([.providers[]? | select(.provider == $provider)] | first) as $p |
    if ($p // null) == null then "error"
    else
      ([($p.quotaSemantics.effectiveAvailability // [])[]? | select(.scope == $scope)] | first) as $row |
      if ($row // null) == null then "error"
      elif (($row.runway.status // "") == "exhausted_now") then "true"
      elif ($row.status != "known") then "false"
      elif (($row.runway.status // "") == "projected_exhaustion") then
        if (($row.runway.usableRunwaySeconds | type) != "number") then "error"
        elif ($row.runway.usableRunwaySeconds < ($threshold | tonumber)) then "true"
        else "false"
        end
      else "false"
      end
    end
  ' 2>/dev/null) || die_cond "could not classify Claude all_models runway"
  case "$verdict" in
    true) exit 0 ;;
    false) exit 1 ;;
    *) die_cond "could not classify Claude all_models runway" ;;
  esac
}

# --- pane driver --------------------------------------------------------------

driver() {
  if [ -n "${FM_BACKUP_HELM_DRIVER:-}" ]; then
    "$FM_BACKUP_HELM_DRIVER" "$@"
    return $?
  fi
  return 127
}

helm_target_exists() {
  if [ -n "${FM_BACKUP_HELM_DRIVER:-}" ]; then
    driver target-exists
    return $?
  fi
  fm_backend_target_exists "$HELM_BACKEND" "$HELM_TARGET"
}

helm_busy() {
  if [ -n "${FM_BACKUP_HELM_DRIVER:-}" ]; then
    driver busy
    return $?
  fi
  local native tail
  native=$(fm_backend_busy_state "$HELM_BACKEND" "$HELM_TARGET" 2>/dev/null || printf 'unknown')
  [ "$native" = busy ] && return 0
  tail=$(fm_backend_capture "$HELM_BACKEND" "$HELM_TARGET" 40 2>/dev/null) || return 0
  printf '%s' "$tail" | grep -v '^[[:space:]]*$' | tail -12 | fm_busy_lines_match claude
}

helm_composer() {
  if [ -n "${FM_BACKUP_HELM_DRIVER:-}" ]; then
    driver composer
    return $?
  fi
  fm_backend_composer_state "$HELM_BACKEND" "$HELM_TARGET" 2>/dev/null || printf 'unknown'
}

helm_send_slash() {
  local text=$1 verdict
  if [ -n "${FM_BACKUP_HELM_DRIVER:-}" ]; then
    driver send "$text"
    return $?
  fi
  verdict=$(fm_backend_send_text_submit "$HELM_BACKEND" "$HELM_TARGET" "$text" 4 0.8 0.8) || return 1
  [ "$verdict" = empty ]
}

helm_launch() {
  local cmd=$1
  if [ -n "${FM_BACKUP_HELM_DRIVER:-}" ]; then
    driver launch "$cmd"
    return $?
  fi
  case "$HELM_BACKEND" in
    tmux)
      fm_backend_source tmux || return 1
      fm_backend_tmux_send_literal "$HELM_TARGET" "$cmd" || return 1
      fm_backend_tmux_send_key "$HELM_TARGET" Enter
      ;;
    herdr)
      fm_backend_source herdr || return 1
      fm_backend_herdr_parse_target "$HELM_TARGET" || return 1
      fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane send-text "$FM_BACKEND_HERDR_PANE" "$cmd" >/dev/null 2>&1 || return 1
      fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane send-keys "$FM_BACKEND_HERDR_PANE" enter >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
}

wait_until() {  # <timeout> <poll> <fn>
  local timeout=$1 poll=$2
  local deadline=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$deadline" ]; do
    "$3" && return 0
    sleep "$poll"
  done
  return 1
}

helm_is_idle() {
  helm_busy && return 1
  return 0
}

lock_is_released() {
  local status
  if [ -n "${FM_BACKUP_HELM_DRIVER:-}" ]; then
    status=$(driver lock-status) || return 1
    [ "$status" = released ]
    return $?
  fi
  status=$("$SCRIPT_DIR/fm-lock.sh" status)
  case "$status" in
    'lock: free'|'lock: stale'*) return 0 ;;
    *) return 1 ;;
  esac
}

lock_is_held_live() {
  local status
  if [ -n "${FM_BACKUP_HELM_DRIVER:-}" ]; then
    status=$(driver lock-status) || return 1
    [ "$status" = held ]
    return $?
  fi
  status=$("$SCRIPT_DIR/fm-lock.sh" status)
  case "$status" in
    'lock: held by live harness pid '*) return 0 ;;
    *) return 1 ;;
  esac
}

build_launch_command() {
  local bin workspace home_q root_q bin_q
  bin=$(fm_cursor_resolve_binary) || return 1
  workspace=$HELM_WORKSPACE
  home_q=$(printf '%q' "$FM_HOME")
  root_q=$(printf '%q' "$workspace")
  bin_q=$(printf '%q' "$bin")
  printf 'cd -- %s && FM_HOME=%s exec env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u GEMINI_CLI -u CURSOR_INVOKED_AS -u FM_OMP_HARNESS %s --trust --yolo --model %s --workspace %s\n' \
    "$root_q" "$home_q" "$bin_q" "$HELM_MODEL" "$root_q"
}

# --- handover ---------------------------------------------------------------

cmd_handover() {
  HELM_BACKEND=
  HELM_TARGET=
  HELM_WORKSPACE=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --home) [ -n "${2-}" ] || die "--home needs a value"; FM_HOME=$2; shift 2 ;;
      --backend) [ -n "${2-}" ] || die "--backend needs a value"; HELM_BACKEND=$2; shift 2 ;;
      --target) [ -n "${2-}" ] || die "--target needs a value"; HELM_TARGET=$2; shift 2 ;;
      --workspace) [ -n "${2-}" ] || die "--workspace needs a value"; HELM_WORKSPACE=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  require_home
  backend_supported "$HELM_BACKEND" || die "handover supports only tmux or herdr, not '${HELM_BACKEND:-}'"
  [ -n "$HELM_TARGET" ] || die "handover needs --target"
  if [ -z "$HELM_WORKSPACE" ]; then
    HELM_WORKSPACE=$(default_workspace) || die "could not resolve a Cursor workspace with .cursor/hooks.json"
  fi
  HELM_WORKSPACE=$(abs_path "$HELM_WORKSPACE") || die "workspace is not a directory"
  [ -f "$HELM_WORKSPACE/.cursor/hooks.json" ] || die "workspace $HELM_WORKSPACE has no .cursor/hooks.json; Cursor project hooks would not load"
  case "$HELM_MODEL" in
    cursor-grok-4.6-high) ;;
    *) die "refusing model '$HELM_MODEL'; helm model is cursor-grok-4.6-high" ;;
  esac

  # shellcheck source=bin/fm-cursor-lib.sh
  . "$SCRIPT_DIR/fm-cursor-lib.sh"
  if [ -z "${FM_BACKUP_HELM_DRIVER:-}" ]; then
    # shellcheck source=bin/fm-backend.sh
    . "$SCRIPT_DIR/fm-backend.sh"
    fm_backend_source "$HELM_BACKEND" || die "could not load backend $HELM_BACKEND"
  fi

  if ! cmd_probe; then
    die "Cursor Grok probe failed; refusing to leave the Claude helm"
  fi
  helm_target_exists || die "helm target $HELM_TARGET is not a live $HELM_BACKEND pane"

  local idle_timeout stow_timeout lock_timeout poll launch
  idle_timeout=${FM_BACKUP_HELM_IDLE_TIMEOUT:-1200}
  stow_timeout=${FM_BACKUP_HELM_STOW_TIMEOUT:-1200}
  lock_timeout=${FM_BACKUP_HELM_LOCK_TIMEOUT:-180}
  poll=${FM_BACKUP_HELM_POLL:-2}
  positive_int "$idle_timeout" || die "FM_BACKUP_HELM_IDLE_TIMEOUT must be a positive integer"
  positive_int "$stow_timeout" || die "FM_BACKUP_HELM_STOW_TIMEOUT must be a positive integer"
  positive_int "$lock_timeout" || die "FM_BACKUP_HELM_LOCK_TIMEOUT must be a positive integer"
  positive_number "$poll" || die "FM_BACKUP_HELM_POLL must be a positive number"

  if lock_is_held_live; then
    printf 'backup-helm: waiting for idle Claude pane (mid-turn is waited out, never interrupted)\n'
    if ! wait_until "$idle_timeout" "$poll" helm_is_idle; then
      die "Claude is still mid-turn after ${idle_timeout}s; handover refused without /stow, /exit, or a lock change"
    fi
    case "$(helm_composer)" in
      empty) ;;
      *) die "Claude composer is not empty; handover refused so typed input is not mixed with /stow" ;;
    esac
    printf 'backup-helm: sending %s\n' "$STOW_COMMAND"
    helm_send_slash "$STOW_COMMAND" || die "could not submit $STOW_COMMAND to the Claude helm"
    if ! wait_until "$stow_timeout" "$poll" helm_is_idle; then
      die "$STOW_COMMAND is still running after ${stow_timeout}s; handover refused without /exit"
    fi
    printf 'backup-helm: sending %s\n' "$EXIT_COMMAND"
    helm_send_slash "$EXIT_COMMAND" || die "could not submit $EXIT_COMMAND to the Claude helm"
    printf 'backup-helm: waiting for session lock free or stale\n'
    if ! wait_until "$lock_timeout" "$poll" lock_is_released; then
      die "session lock is still held after ${lock_timeout}s; lock file left untouched"
    fi
  elif lock_is_released; then
    printf 'backup-helm: session lock already free or stale; skipping Claude /stow and /exit\n'
  else
    die "session lock is neither held by a live harness nor free or stale; handover refused without /stow, /exit, or a lock change"
  fi

  launch=$(build_launch_command) || die "Cursor Grok probe failed at launch"
  case "$launch" in
    *' -p '*|*' -p') die "refusing a headless cursor-agent -p launch" ;;
  esac
  case "$launch" in
    *' --trust '*|*' --trust') ;;
    *) die "launch command is missing --trust" ;;
  esac
  case "$launch" in
    *' --yolo '*) ;;
    *) die "launch command is missing --yolo" ;;
  esac
  printf 'backup-helm: launch-command: %s' "$launch"
  helm_launch "$launch" || die "could not submit the Cursor launch command"
  printf 'backup-helm: launched %s; Cursor stop-hook park owns the watcher\n' "$HELM_MODEL"
}

# --- arm / retire ------------------------------------------------------------

cmd_source_id() {
  "$SCRIPT_DIR/fm-procevent-when.sh" source-id "$WATCH_NAME"
}

cmd_retire() {
  require_home
  "$SCRIPT_DIR/fm-procevent-when.sh" retire "$WATCH_NAME"
}

cmd_arm() {
  local backend='' target='' workspace='' interval=60 stable=2 action_timeout=3600
  local provider=$DEFAULT_PROVIDER scope=$DEFAULT_SCOPE threshold=$DEFAULT_RUNWAY_SECONDS
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --home) [ -n "${2-}" ] || die "--home needs a value"; FM_HOME=$2; shift 2 ;;
      --backend) [ -n "${2-}" ] || die "--backend needs a value"; backend=$2; shift 2 ;;
      --target) [ -n "${2-}" ] || die "--target needs a value"; target=$2; shift 2 ;;
      --workspace) [ -n "${2-}" ] || die "--workspace needs a value"; workspace=$2; shift 2 ;;
      --interval) positive_number "${2-}" || die "--interval needs a positive number"; interval=$2; shift 2 ;;
      --stable) positive_int "${2-}" || die "--stable needs a positive integer"; stable=$2; shift 2 ;;
      --action-timeout) positive_int "${2-}" || die "--action-timeout needs a positive integer"; action_timeout=$2; shift 2 ;;
      --runway-seconds) positive_int "${2-}" || die "--runway-seconds needs a positive integer"; threshold=$2; shift 2 ;;
      --provider) [ -n "${2-}" ] || die "--provider needs a value"; provider=$2; shift 2 ;;
      --scope) [ -n "${2-}" ] || die "--scope needs a value"; scope=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  require_home
  provider_valid "$provider" || die "invalid provider: $provider"
  scope_valid "$scope" || die "invalid scope: $scope"
  backend_supported "${backend:-tmux}" || die "arm supports only tmux or herdr, not '$backend'"
  mkdir -p "$STATE" || die "cannot create $STATE"
  if [ -z "$workspace" ]; then
    workspace=$(default_workspace) || die "could not resolve a Cursor workspace with .cursor/hooks.json"
  fi
  workspace=$(abs_path "$workspace") || die "workspace is not a directory"
  [ -f "$workspace/.cursor/hooks.json" ] || die "workspace $workspace has no .cursor/hooks.json"

  if ! cmd_probe; then
    die "Cursor Grok probe failed; refusing to arm a handover that cannot launch"
  fi

  if [ -z "$target" ] || [ -z "$backend" ]; then
    # shellcheck source=bin/fm-supervisor-target-lib.sh
    . "$SCRIPT_DIR/fm-supervisor-target-lib.sh"
    if [ -z "$target" ]; then
      target=$(discover_supervisor_target) || die "could not discover the Claude helm pane; pass --target"
    fi
    if [ -z "$backend" ]; then
      backend=$(discover_supervisor_backend) || die "could not discover the Claude helm backend; pass --backend"
    fi
  fi
  backend_supported "$backend" || die "arm supports only tmux or herdr, not '$backend'"
  [ -n "$target" ] || die "arm needs --target"

  "$SCRIPT_DIR/fm-procevent-when.sh" arm "$WATCH_NAME" \
    --interval "$interval" \
    --stable "$stable" \
    --action-timeout "$action_timeout" \
    --condition "$SCRIPT_DIR/fm-backup-helm.sh" condition --provider "$provider" --scope "$scope" --runway-seconds "$threshold" \
    --action "$SCRIPT_DIR/fm-backup-helm.sh" handover --home "$FM_HOME" --backend "$backend" --target "$target" --workspace "$workspace" \
    || exit 1
  printf 'armed: when-%s\n' "$WATCH_NAME"
  printf 'provider: %s\n' "$provider"
  printf 'scope: %s\n' "$scope"
  printf 'runway-seconds: %s\n' "$threshold"
  printf 'backend: %s\n' "$backend"
  printf 'target: %s\n' "$target"
  printf 'workspace: %s\n' "$workspace"
  printf 'model: %s\n' "$HELM_MODEL"
}

case "${1-}" in
  arm) shift; cmd_arm "$@" ;;
  condition) shift; cmd_condition "$@" ;;
  probe) shift; cmd_probe "$@" ;;
  handover) shift; cmd_handover "$@" ;;
  retire) shift; cmd_retire "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
