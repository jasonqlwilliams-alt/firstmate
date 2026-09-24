#!/usr/bin/env bash
# Automatic Claude-runway backup helm.
#
# Arms a firstmate-owned condition->action watch that hands the helm to the
# configured successor primary when Claude's all_models usableRunwaySeconds
# drops under 12 hours. The trigger reads that exact all_models row; a sibling
# Claude window at 0% (for example Fable) must not satisfy it. Do not revive a
# retired percent-threshold quota watch for this handover.
#
# Usage:
#   fm-backup-helm.sh arm [options]
#   fm-backup-helm.sh condition [options]
#   fm-backup-helm.sh probe [--harness <h> [--model <m>] [--effort <e>]]
#   fm-backup-helm.sh handover --harness <h> --backend <tmux|herdr> --target <target> [options]
#   fm-backup-helm.sh retire
#   fm-backup-helm.sh source-id
#
# Successor: config/backup-helm-successor (FM_CONFIG_OVERRIDE honored), in the
# same shape as config/secondmate-harness: the first non-empty, non-comment
# line is "<harness> [<model>] [<effort>]", whitespace-separated. There is no
# default successor: an absent file, a file with no such line, or a "default"
# harness token is refused by name. Eligible harnesses are the verified
# primaries other than Claude: codex, pi, pi-signed, omp, opencode, grok, and
# cursor. An absent or "default" model or effort passes no flag, so the
# harness uses its own default, except cursor, which requires an explicit model
# other than auto. An effort the harness has no flag for is refused rather than
# dropped: codex low|medium|high|xhigh, grok low|medium|high, pi, pi-signed,
# and omp low|medium|high|xhigh|max, opencode and cursor none.
#
# arm        Read and validate the successor, probe that it answers, freeze
#            the live Claude pane, and register when-watch
#            "backup-helm-claude-runway" through fm-procevent-when.sh with the
#            successor frozen into the handover argv. FM_HOME must be explicit.
#            Run this from the live Claude helm pane, or pass --backend and
#            --target. Does not start the handover. Re-arm after changing the
#            successor file; an armed watch keeps the successor it was armed with.
# condition  One quota-axi evaluation for the when adapter: exit 0 when Claude
#            all_models runway is exhausted_now or usableRunwaySeconds is below
#            the threshold, 1 when the condition is cleanly false, 2 on error.
#            Unknown quota is false, not an error, so the watch keeps polling.
# probe      One bounded headless request to the successor, which must answer
#            a one-time nonce question correctly. A model catalog or login
#            check is not enough: a billing block or usage limit still lists
#            models. Runs outside any git checkout with stdin closed and the
#            firstmate home variables cleared, so no project hook can take a
#            session lock. Prints one probe= line whose status is ok,
#            unavailable, no-answer, timeout, or refused, with a sanitized
#            one-line detail on failure. Exit 0 only for ok. With no --harness
#            it probes the configured successor and needs FM_HOME.
# handover   The when-watch action. Probes the frozen successor again and fails
#            closed before touching Claude when it does not answer. Then waits
#            for an idle Claude pane, sends /stow, sends /exit, waits for the
#            session lock to read free or stale, and launches the successor
#            interactively in that pane with its session-start instruction as
#            the first message. Never deletes state/.lock, never restarts
#            Herdr, and never launches a headless successor. A mid-turn Claude
#            is waited out; the action fails closed rather than interrupting if
#            the idle bound expires.
# retire     Retire the when-watch. Idempotent.
# source-id  Print the canonical when-watch source id.
#
# Arm options, before any frozen handover flags:
#   --backend <tmux|herdr>   freeze this backend instead of discovering it
#   --target <target>         freeze this pane instead of discovering it
#   --workspace <abs>         firstmate checkout the successor starts in
#                            (default FM_HOME, else this code root, whichever
#                            carries the successor's primary integration)
#   --interval <secs>          when-watch poll cadence (default 60)
#   --stable <n>              consecutive true polls to fire (default 2)
#   --action-timeout <secs>  bound on handover (default 3600)
#   --runway-seconds <n>      trigger threshold (default 43200)
#   --provider <id>          quota-axi provider (default claude)
#   --scope <scope>          quota-axi scope (default all_models)
#
# Handover options:
#   --home <abs>              operational home (otherwise FM_HOME is required)
#   --harness <h>             successor harness; required, never defaulted
#   --model <m>               successor model, when one was configured
#   --effort <e>              successor effort, when one was configured
#   --backend <tmux|herdr>   required unless frozen by arm
#   --target <target>         required unless frozen by arm
#   --workspace <abs>        successor checkout
#
# Workspace: must be a firstmate checkout (AGENTS.md and bin/fm-session-start.sh)
# carrying the successor's tracked primary integration: .codex/hooks.json,
# .pi/extensions/fm-primary-turnend-guard.ts, .omp/extensions/fm-primary-turnend-guard.ts,
# .opencode/plugins/, .grok/hooks/, or .cursor/hooks.json.
#
# Environment:
#   FM_HOME                      required for arm, handover, retire, and a configured probe
#   FM_BACKUP_HELM_PROBE_TIMEOUT  seconds bounding one probe request (default 120)
#   FM_BACKUP_HELM_PROBE_DIR     probe working directory (default
#                                ${TMPDIR:-/tmp}/fm-backup-helm-probe-<uid>); must be
#                                owned by this user and outside any git checkout
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
SUCCESSOR_FILE=backup-helm-successor
SUCCESSOR_HARNESSES='codex pi pi-signed omp opencode grok cursor'
PROBE_ENV_UNSET=(-u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u GEMINI_CLI -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u FM_OMP_HARNESS -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE)
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

# --- successor --------------------------------------------------------------

successor_config_path() {
  printf '%s/%s\n' "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" "$SUCCESSOR_FILE"
}

# Print the first non-empty, non-comment line of the successor file, trimmed.
successor_config_line() {
  local file=$1 line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in
      '#'*) continue ;;
    esac
    printf '%s\n' "$line"
    return 0
  done < "$file"
}

# Set SUCCESSOR_HARNESS, SUCCESSOR_MODEL, and SUCCESSOR_EFFORT from the
# configured successor file, or die naming why there is no successor.
read_successor_config() {
  local file line
  file=$(successor_config_path)
  local fix="write one line '<harness> [<model>] [<effort>]' naming one of: $SUCCESSOR_HARNESSES"
  [ -e "$file" ] || die "no backup helm successor is configured: $file is absent, and there is no default successor; $fix"
  [ -f "$file" ] && [ -r "$file" ] || die "backup helm successor file $file is not a readable regular file"
  line=$(successor_config_line "$file")
  [ -n "$line" ] || die "no backup helm successor is configured: $file has no successor line, and there is no default successor; $fix"
  # shellcheck disable=SC2086  # deliberate word-splitting: tokenizing the line into fields
  set -- $line
  [ "$#" -le 3 ] || die "backup helm successor line in $file has more than three fields: '$line'; $fix"
  [ "$1" != default ] || die "no backup helm successor is configured: $file names 'default', and there is no default successor; $fix"
  SUCCESSOR_HARNESS=$1
  SUCCESSOR_MODEL=${2:-}
  SUCCESSOR_EFFORT=${3:-}
  [ "$SUCCESSOR_MODEL" != default ] || SUCCESSOR_MODEL=
  [ "$SUCCESSOR_EFFORT" != default ] || SUCCESSOR_EFFORT=
}

successor_effort_levels() {  # <harness>
  case "$1" in
    codex) printf '%s\n' 'low medium high xhigh' ;;
    grok) printf '%s\n' 'low medium high' ;;
    pi|pi-signed|omp) printf '%s\n' 'low medium high xhigh max' ;;
    *) printf '\n' ;;
  esac
}

# Refuse a successor that cannot take the helm, naming the reason. Validates
# the SUCCESSOR_* variables.
validate_successor() {
  local harness=$SUCCESSOR_HARNESS model=$SUCCESSOR_MODEL effort=$SUCCESSOR_EFFORT levels
  case "$harness" in
    claude) die "claude cannot be the backup helm successor: the handover exists because Claude's runway is running out" ;;
  esac
  case " $SUCCESSOR_HARNESSES " in
    *" $harness "*) ;;
    *) die "'$harness' is not an eligible backup helm successor; eligible verified primary harnesses: $SUCCESSOR_HARNESSES" ;;
  esac
  case "$model" in
    -*|*[[:space:]]*) die "invalid backup helm successor model: '$model'" ;;
  esac
  case "$effort" in
    -*|*[[:space:]]*) die "invalid backup helm successor effort: '$effort'" ;;
  esac
  if [ "$harness" = cursor ]; then
    case "$model" in
      ''|auto) die "a cursor successor needs an explicit model other than auto, or Cursor would pick one itself" ;;
    esac
  fi
  if [ -n "$effort" ]; then
    levels=$(successor_effort_levels "$harness")
    [ -n "$levels" ] || die "$harness has no effort flag; remove effort '$effort' from the backup helm successor"
    case " $levels " in
      *" $effort "*) ;;
      *) die "$harness does not accept effort '$effort'; supported: $levels" ;;
    esac
  fi
}

successor_describe() {
  printf 'harness=%s model=%s effort=%s' "$SUCCESSOR_HARNESS" "${SUCCESSOR_MODEL:-default}" "${SUCCESSOR_EFFORT:-default}"
}

successor_bin() {
  local name
  case "$SUCCESSOR_HARNESS" in
    cursor)
      # shellcheck source=bin/fm-cursor-lib.sh
      . "$SCRIPT_DIR/fm-cursor-lib.sh"
      fm_cursor_resolve_binary 2>/dev/null
      return $?
      ;;
    *) name=$SUCCESSOR_HARNESS ;;
  esac
  command -v "$name" 2>/dev/null
}

# Set SUCCESSOR_FLAGS to the harness's model and effort flags.
successor_flags() {
  SUCCESSOR_FLAGS=()
  [ -z "$SUCCESSOR_MODEL" ] || SUCCESSOR_FLAGS+=(--model "$SUCCESSOR_MODEL")
  [ -n "$SUCCESSOR_EFFORT" ] || return 0
  case "$SUCCESSOR_HARNESS" in
    codex) SUCCESSOR_FLAGS+=(-c "model_reasoning_effort=\"$SUCCESSOR_EFFORT\"") ;;
    grok) SUCCESSOR_FLAGS+=(--reasoning-effort "$SUCCESSOR_EFFORT") ;;
    pi|pi-signed|omp) SUCCESSOR_FLAGS+=(--thinking "$SUCCESSOR_EFFORT") ;;
  esac
}

# The tracked primary integration the successor needs in its checkout.
successor_marker() {
  case "$SUCCESSOR_HARNESS" in
    codex) printf '%s\n' .codex/hooks.json ;;
    pi|pi-signed) printf '%s\n' .pi/extensions/fm-primary-turnend-guard.ts ;;
    omp) printf '%s\n' .omp/extensions/fm-primary-turnend-guard.ts ;;
    opencode) printf '%s\n' .opencode/plugins ;;
    grok) printf '%s\n' .grok/hooks ;;
    cursor) printf '%s\n' .cursor/hooks.json ;;
  esac
}

workspace_fits() {  # <dir>
  local dir=$1 marker
  marker=$(successor_marker)
  [ -f "$dir/AGENTS.md" ] && [ -f "$dir/bin/fm-session-start.sh" ] && [ -e "$dir/$marker" ]
}

default_workspace() {
  if workspace_fits "$FM_HOME"; then
    printf '%s\n' "$FM_HOME"
    return 0
  fi
  if workspace_fits "$FM_ROOT"; then
    printf '%s\n' "$FM_ROOT"
    return 0
  fi
  return 1
}

# Resolve and validate a workspace for the successor into the named variable.
resolve_workspace() {  # <input> <result-var>
  local input=$1 result
  if [ -z "$input" ]; then
    input=$(default_workspace) || die "could not resolve a firstmate checkout carrying $(successor_marker) for $SUCCESSOR_HARNESS; pass --workspace"
  fi
  result=$(abs_path "$input") || die "workspace is not a directory"
  workspace_fits "$result" || die "workspace $result is not a firstmate checkout carrying $(successor_marker); $SUCCESSOR_HARNESS would start without its primary integration"
  printf -v "$2" '%s' "$result"
}

# --- probe -------------------------------------------------------------------

probe_dir() {
  local dir=${FM_BACKUP_HELM_PROBE_DIR:-${TMPDIR:-/tmp}/fm-backup-helm-probe-$(id -u)}
  [ ! -L "$dir" ] || return 1
  if [ ! -d "$dir" ]; then
    mkdir -m 700 "$dir" 2>/dev/null || return 1
  fi
  [ -d "$dir" ] && [ -O "$dir" ] || return 1
  # A harness started inside a checkout loads that project's hooks; inside a
  # firstmate checkout they would run session start and take its lock.
  if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 1
  fi
  printf '%s\n' "$dir"
}

probe_line() {  # <status> [detail]
  local detail=${2:-}
  printf 'probe=backup-helm-successor %s status=%s' "$(successor_describe)" "$1"
  [ -z "$detail" ] || printf ' detail=%s' "$detail"
  printf '\n'
}

# Last non-empty output line, printable characters only, bounded.
probe_detail() {  # <file>
  local line
  line=$(grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -1 | LC_ALL=C tr -cd '[:print:]' | cut -c1-240)
  printf '%s' "${line:-no output}"
}

# One headless request that the successor must answer correctly. The expected
# answer never appears verbatim in the prompt, so an echoed prompt or an error
# banner cannot pass.
probe_successor() {
  local bin dir out rc timeout nonce expected prompt
  local -a argv
  bin=$(successor_bin) || {
    probe_line unavailable "$SUCCESSOR_HARNESS executable not found"
    return 1
  }
  dir=$(probe_dir) || {
    probe_line refused "probe directory is not a private directory outside every git checkout"
    return 1
  }
  timeout=${FM_BACKUP_HELM_PROBE_TIMEOUT:-120}
  positive_int "$timeout" || timeout=120
  nonce="$((RANDOM % 9000 + 1000))$((RANDOM % 9000 + 1000))"
  expected="FMHELMOK$nonce"
  prompt="Concatenate the two strings FMHELM and OK$nonce with nothing between them. Reply with only the result."
  successor_flags
  case "$SUCCESSOR_HARNESS" in
    codex) argv=("$bin" exec --skip-git-repo-check --ephemeral "${SUCCESSOR_FLAGS[@]}" "$prompt") ;;
    pi|pi-signed) argv=("$bin" -p --no-session --no-extensions --no-context-files --no-approve "${SUCCESSOR_FLAGS[@]}" "$prompt") ;;
    omp) argv=(env OMP_SKIP_SETUP=1 "$bin" -p "${SUCCESSOR_FLAGS[@]}" "$prompt") ;;
    opencode) argv=("$bin" run "${SUCCESSOR_FLAGS[@]}" "$prompt") ;;
    grok) argv=("$bin" "${SUCCESSOR_FLAGS[@]}" -p "$prompt") ;;
    cursor) argv=("$bin" -p --trust "${SUCCESSOR_FLAGS[@]}" "$prompt") ;;
    *) probe_line refused "no probe for $SUCCESSOR_HARNESS"; return 1 ;;
  esac
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$SCRIPT_DIR/fm-timeout-lib.sh"
  out=$(mktemp "${TMPDIR:-/tmp}/fm-backup-helm-probe-out.XXXXXX") || {
    probe_line refused "could not create a probe output file"
    return 1
  }
  (cd "$dir" && fm_run_timed "$timeout" env "${PROBE_ENV_UNSET[@]}" "${argv[@]}" </dev/null >"$out" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ] && grep -qF "$expected" "$out"; then
    rm -f "$out"
    probe_line ok
    return 0
  fi
  if [ "$rc" -eq 124 ]; then
    probe_line timeout "no answer within ${timeout}s"
  else
    probe_line no-answer "$(probe_detail "$out")"
  fi
  rm -f "$out"
  return 1
}

cmd_probe() {
  SUCCESSOR_HARNESS='' SUCCESSOR_MODEL='' SUCCESSOR_EFFORT=''
  local explicit=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --harness) [ -n "${2-}" ] || die "--harness needs a value"; SUCCESSOR_HARNESS=$2; explicit=1; shift 2 ;;
      --model) [ -n "${2-}" ] || die "--model needs a value"; SUCCESSOR_MODEL=$2; shift 2 ;;
      --effort) [ -n "${2-}" ] || die "--effort needs a value"; SUCCESSOR_EFFORT=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  if [ "$explicit" -eq 0 ]; then
    [ -z "$SUCCESSOR_MODEL$SUCCESSOR_EFFORT" ] || die "--model and --effort need --harness"
    require_home
    read_successor_config
  fi
  validate_successor
  probe_successor
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

# The interactive primary launch for the successor, typed into the frozen pane.
# Its first message is the session-start instruction, so the successor takes
# the helm and arms supervision without waiting for a captain message.
build_launch_command() {
  local bin prompt env_extra='' pre='' post='' flags='' word
  bin=$(successor_bin) || return 1
  # shellcheck source=bin/fm-operational-input.sh
  . "$SCRIPT_DIR/fm-operational-input.sh"
  fm_operational_input_encode session-start \
    "Run \`bin/fm-session-start.sh\` now, exactly once, before executing any other instructions." \
    prompt || return 1
  successor_flags
  for word in "${SUCCESSOR_FLAGS[@]}"; do
    flags+=" $(printf '%q' "$word")"
  done
  case "$SUCCESSOR_HARNESS" in
    codex) pre=' --dangerously-bypass-approvals-and-sandbox' ;;
    pi) pre=' --approve' ;;
    pi-signed) env_extra=' FM_PI_HARNESS=pi-signed'; pre=' --approve' ;;
    omp) env_extra=' FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1'; pre=" --auto-approve --cwd $(printf '%q' "$HELM_WORKSPACE")" ;;
    opencode) env_extra=" OPENCODE_CONFIG_CONTENT=$(printf '%q' '{"permission":{"*":"allow"}}')"; post=' --prompt' ;;
    grok) pre=' --trust --always-approve' ;;
    cursor) pre=' --trust --yolo'; post=" --workspace $(printf '%q' "$HELM_WORKSPACE")" ;;
    *) return 1 ;;
  esac
  printf 'cd -- %q && FM_HOME=%q exec env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u GEMINI_CLI -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u FM_OMP_HARNESS%s %q%s%s%s %q\n' \
    "$HELM_WORKSPACE" "$FM_HOME" "$env_extra" "$bin" "$pre" "$flags" "$post" "$prompt"
}

# --- handover ---------------------------------------------------------------

cmd_handover() {
  HELM_BACKEND=
  HELM_TARGET=
  HELM_WORKSPACE=
  SUCCESSOR_HARNESS='' SUCCESSOR_MODEL='' SUCCESSOR_EFFORT=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --home) [ -n "${2-}" ] || die "--home needs a value"; FM_HOME=$2; shift 2 ;;
      --harness) [ -n "${2-}" ] || die "--harness needs a value"; SUCCESSOR_HARNESS=$2; shift 2 ;;
      --model) [ -n "${2-}" ] || die "--model needs a value"; SUCCESSOR_MODEL=$2; shift 2 ;;
      --effort) [ -n "${2-}" ] || die "--effort needs a value"; SUCCESSOR_EFFORT=$2; shift 2 ;;
      --backend) [ -n "${2-}" ] || die "--backend needs a value"; HELM_BACKEND=$2; shift 2 ;;
      --target) [ -n "${2-}" ] || die "--target needs a value"; HELM_TARGET=$2; shift 2 ;;
      --workspace) [ -n "${2-}" ] || die "--workspace needs a value"; HELM_WORKSPACE=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  require_home
  [ -n "$SUCCESSOR_HARNESS" ] || die "handover needs --harness; there is no default successor"
  validate_successor
  backend_supported "$HELM_BACKEND" || die "handover supports only tmux or herdr, not '${HELM_BACKEND:-}'"
  [ -n "$HELM_TARGET" ] || die "handover needs --target"
  resolve_workspace "$HELM_WORKSPACE" HELM_WORKSPACE

  if [ -z "${FM_BACKUP_HELM_DRIVER:-}" ]; then
    # shellcheck source=bin/fm-backend.sh
    . "$SCRIPT_DIR/fm-backend.sh"
    fm_backend_source "$HELM_BACKEND" || die "could not load backend $HELM_BACKEND"
  fi

  if ! probe_successor; then
    die "successor $SUCCESSOR_HARNESS did not answer its probe; refusing to leave the Claude helm"
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

  launch=$(build_launch_command) || die "could not build the $SUCCESSOR_HARNESS launch command; its executable is no longer resolvable"
  printf 'backup-helm: launch-command: %s\n' "$launch"
  helm_launch "$launch" || die "could not submit the $SUCCESSOR_HARNESS launch command"
  printf 'backup-helm: launched %s; its session start takes the helm and arms supervision\n' "$(successor_describe)"
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
  read_successor_config
  validate_successor
  resolve_workspace "$workspace" workspace

  if ! probe_successor; then
    die "successor $SUCCESSOR_HARNESS did not answer its probe; refusing to arm a handover that cannot launch"
  fi
  local -a successor_argv=(--harness "$SUCCESSOR_HARNESS")
  [ -z "$SUCCESSOR_MODEL" ] || successor_argv+=(--model "$SUCCESSOR_MODEL")
  [ -z "$SUCCESSOR_EFFORT" ] || successor_argv+=(--effort "$SUCCESSOR_EFFORT")

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
    --action "$SCRIPT_DIR/fm-backup-helm.sh" handover --home "$FM_HOME" "${successor_argv[@]}" --backend "$backend" --target "$target" --workspace "$workspace" \
    || exit 1
  printf 'armed: when-%s\n' "$WATCH_NAME"
  printf 'provider: %s\n' "$provider"
  printf 'scope: %s\n' "$scope"
  printf 'runway-seconds: %s\n' "$threshold"
  printf 'backend: %s\n' "$backend"
  printf 'target: %s\n' "$target"
  printf 'workspace: %s\n' "$workspace"
  printf 'successor: %s\n' "$SUCCESSOR_HARNESS"
  printf 'model: %s\n' "${SUCCESSOR_MODEL:-default}"
  printf 'effort: %s\n' "${SUCCESSOR_EFFORT:-default}"
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
