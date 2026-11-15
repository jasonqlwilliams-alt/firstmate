#!/usr/bin/env bash
# Implementation of fm-primary-start.sh. Its header owns the public contract.
# No lifecycle operation runs on source. In particular, ready must not ensure
# a server, acquire a lock, write a receipt, or invoke session-start/bootstrap.

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-launch-policy-lib.sh
. "$SCRIPT_DIR/fm-launch-policy-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
fm_backend_source herdr
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

PRIMARY_PANE='' PRIMARY_TAB='' PRIMARY_FOUND_WORKSPACE=
PRIMARY_OWNER='' PRIMARY_LOCK=
PRIMARY_LABEL=$(fm_backend_herdr_workspace_label)

primary_validate_home() {
  case "$FM_HOME" in *$'\n'*|*$'\r'*|*$'\t'*) primary_die "home contains a record separator" ;; esac
  [ ! -e "$FM_HOME/.fm-secondmate-home" ] && [ ! -L "$FM_HOME/.fm-secondmate-home" ] \
    || primary_die "secondmate homes cannot be started as primary"
  fm_primary_scope_matches "$FM_HOME" "$STATE" || primary_die "home is not a primary checkout with an existing state directory"
  [ ! -L "$STATE" ] && [ -r "$STATE" ] || primary_die "state directory is unavailable or unsafe"
  [ -x "$FM_HOME/bin/fm-session-start.sh" ] && [ -x "$FM_HOME/bin/fm-startup-network.sh" ] \
    || primary_die "primary startup owners are missing"
  primary_hooks_present || primary_die "tracked Claude SessionStart, Stop auto-arm and turn-end hooks are required"
}

primary_hooks_present() {
  [ -f "$FM_HOME/.claude/settings.json" ] || return 1
  jq -e '
    def hook($event; $part): any(.hooks[$event][]?.hooks[]?; (.command // "" | contains($part)));
    hook("SessionStart"; "bin/fm-sessionstart-run.sh")
    and hook("Stop"; "bin/fm-turnend-guard.sh --claude")
    and any(.hooks.Stop[]?.hooks[]?;
      (.command // "" | contains("bin/fm-claude-stop-autoarm.sh")) and .asyncRewake == true)
  ' "$FM_HOME/.claude/settings.json" >/dev/null 2>&1
}

primary_cli() { fm_backend_herdr_cli "$PRIMARY_SESSION" "$@"; }

primary_server_state() {
  local out
  out=$(primary_cli status --json) || primary_die "cannot read the selected Herdr session"
  printf '%s' "$out" | jq -e '.error == null and (.client.protocol | type == "number")' >/dev/null \
    || primary_die "unreadable Herdr status"
  [ "$(printf '%s' "$out" | jq -r '.client.protocol')" -ge "$FM_BACKEND_HERDR_MIN_PROTOCOL" ] \
    || primary_die "Herdr protocol is below the supported floor"
  case "$(printf '%s' "$out" | jq -r '.server.running')" in
    false) PRIMARY_SERVER=stopped ;;
    true)
      printf '%s' "$out" | jq -e '
        .server.compatible == true or
        (.server.compatible == null and .client.protocol == .server.protocol)
      ' >/dev/null || primary_die "selected Herdr server is incompatible; it was left running"
      PRIMARY_SERVER=running
      ;;
    *) primary_die "Herdr server state is unknown" ;;
  esac
}

primary_read_lock() {
  local comm args
  PRIMARY_OWNER='' PRIMARY_LOCK=free
  if [ -e "$STATE/.lock" ] || [ -L "$STATE/.lock" ]; then
    [ -f "$STATE/.lock" ] && [ ! -L "$STATE/.lock" ] && [ -r "$STATE/.lock" ] \
      || primary_die "session lock is unreadable or unsafe"
    PRIMARY_OWNER=$(cat "$STATE/.lock") || primary_die "cannot read session lock"
    case "$PRIMARY_OWNER" in ''|*[!0-9]*|0|1) primary_die "malformed session lock" ;; esac
    PRIMARY_LOCK=stale
    if kill -0 "$PRIMARY_OWNER" 2>/dev/null; then
      comm=$(ps -p "$PRIMARY_OWNER" -o comm=) || primary_die "live lock owner cannot be inspected"
      args=$(ps -p "$PRIMARY_OWNER" -o args=) || primary_die "live lock owner arguments are unreadable"
      if fm_harness_process_matches "$comm" "$args"; then PRIMARY_LOCK=live; fi
    fi
  fi
}

primary_pane_home_matches() {  # <pane JSON> <expected-home>
  local cwd actual expected
  cwd=$(printf '%s' "$1" | jq -er '.cwd | select(type == "string" and startswith("/"))') || return 1
  actual=$(cd -- "$cwd" 2>/dev/null && pwd -P) || return 1
  expected=$(cd -- "$2" 2>/dev/null && pwd -P) || return 1
  [ "$actual" = "$expected" ]
}

primary_receipt_matches_pane() {
  local id=$1 ws=$2 receipt="$STATE/.primary-start" terminal info
  [ -f "$receipt" ] && [ ! -L "$receipt" ] && [ -r "$receipt" ] || return 1
  case "$(fm_meta_get "$receipt" phase)" in detecting|launched) ;; *) return 1 ;; esac
  [ "$(fm_meta_get "$receipt" home)" = "$FM_HOME" ] \
    && [ "$(fm_meta_get "$receipt" session)" = "$PRIMARY_SESSION" ] \
    && [ "$(fm_meta_get "$receipt" workspace)" = "$ws" ] \
    && [ "$(fm_meta_get "$receipt" pane)" = "$id" ] || return 1
  terminal=$(fm_meta_get "$receipt" terminal)
  [ -n "$terminal" ] || return 1
  info=$(primary_cli pane get "$id") || return 1
  printf '%s' "$info" | jq -e --arg id "$id" --arg ws "$ws" --arg terminal "$terminal" '
    .error == null and .result.pane.pane_id == $id
    and .result.pane.workspace_id == $ws
    and .result.pane.terminal_id == $terminal
  ' >/dev/null || return 1
  primary_pane_home_matches "$(printf '%s' "$info" | jq -c '.result.pane')" "$FM_HOME"
}

primary_discover() {
  local panes workspaces row id ws state agent home_spaces='' labels
  PRIMARY_PANE='' PRIMARY_TAB='' PRIMARY_FOUND_WORKSPACE=
  panes=$(primary_cli pane list) || primary_die "pane inventory is unreadable"
  workspaces=$(primary_cli workspace list) || primary_die "workspace inventory is unreadable"
  printf '%s' "$panes" | jq -e '.error == null and (.result.panes | type == "array")' >/dev/null \
    || primary_die "malformed pane inventory"
  printf '%s' "$workspaces" | jq -e '.error == null and (.result.workspaces | type == "array")' >/dev/null \
    || primary_die "malformed workspace inventory"
  while IFS= read -r row; do
    primary_pane_home_matches "$row" "$FM_HOME" || continue
    id=$(printf '%s' "$row" | jq -er '.pane_id') || primary_die "home pane lacks an id"
    ws=$(printf '%s' "$row" | jq -er '.workspace_id') || primary_die "home pane lacks a workspace"
    printf '%s' "$workspaces" | jq -e --arg ws "$ws" '[.result.workspaces[] | select(.workspace_id == $ws)] | length == 1' >/dev/null \
      || primary_die "home pane workspace is ambiguous"
    case " $home_spaces " in *" $ws "*) ;; *) home_spaces="${home_spaces:+$home_spaces }$ws" ;; esac
    state=$(fm_backend_herdr_pane_agent_state "$PRIMARY_SESSION" "$id")
    case "$state" in
      no-agent|stale-agent) ;;
      live)
        agent=$(primary_cli agent get "$id") || primary_die "cannot inspect home agent $id"
        [ "$(printf '%s' "$agent" | jq -r '.result.agent.agent')" = claude ] || continue
        if ! primary_owner_in_pane "$id" && ! primary_receipt_matches_pane "$id" "$ws"; then
          continue
        fi
        [ -z "$PRIMARY_PANE" ] || primary_die "multiple live primary candidates; no agent was changed"
        PRIMARY_PANE=$id PRIMARY_FOUND_WORKSPACE=$ws
        PRIMARY_TAB=$(printf '%s' "$row" | jq -er '.tab_id') || primary_die "primary tab is unreadable"
        ;;
      *) primary_die "home pane $id has ambiguous agent state" ;;
    esac
  done <<EOF
$(printf '%s' "$panes" | jq -c '.result.panes[]')
EOF
  if [ -n "$PRIMARY_PANE" ]; then
    [ -z "$PRIMARY_WORKSPACE" ] || [ "$PRIMARY_WORKSPACE" = "$PRIMARY_FOUND_WORKSPACE" ] \
      || primary_die "primary is outside the requested workspace"
    return 0
  fi
  case "$home_spaces" in *' '*) primary_die "several primary-home workspaces exist; refusing to guess" ;; esac
  PRIMARY_FOUND_WORKSPACE=$home_spaces
  labels=$(printf '%s' "$workspaces" | jq -r --arg label "$PRIMARY_LABEL" \
    '.result.workspaces[] | select((.label // "" | ascii_downcase) == ($label | ascii_downcase)) | .workspace_id')
  if [ -n "$labels" ] && [ "$labels" != "$PRIMARY_FOUND_WORKSPACE" ]; then
    primary_die "primary workspace label is duplicated or belongs to an unproven home"
  fi
}

primary_owner_in_pane() {
  local candidate=$1 info shell pid parent n=0 comm args
  [ "$PRIMARY_LOCK" = live ] && [ -n "$candidate" ] || return 1
  comm=$(ps -p "$PRIMARY_OWNER" -o comm= 2>/dev/null) || return 1
  args=$(ps -p "$PRIMARY_OWNER" -o args= 2>/dev/null) || return 1
  fm_harness_process_matches "$comm" "$args" && [ "$FM_HARNESS_IS_CLAUDE" = 1 ] || return 1
  info=$(primary_cli pane process-info --pane "$candidate") || return 1
  shell=$(printf '%s' "$info" | jq -er --arg p "$candidate" '
    select(.result.process_info.pane_id == $p) | .result.process_info.shell_pid | select(type == "number" and . > 1)
  ') || return 1
  pid=$PRIMARY_OWNER
  while [ "$n" -lt 64 ]; do
    [ "$pid" = "$shell" ] && return 0
    parent=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ') || return 1
    case "$parent" in ''|*[!0-9]*|0|1) return 1 ;; esac
    [ "$parent" != "$pid" ] || return 1
    pid=$parent n=$((n + 1))
  done
  return 1
}

primary_mates_ready() {
  local registry="$FM_HOME/data/secondmates.md" line id meta expected host target backend route verdict seen='' endpoint
  local meta_ids='' registry_ids='' found homes='' home_key session mate_pane info harness
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    [ "$(fm_meta_get "$meta" kind)" = secondmate ] || continue
    id=${meta##*/}; id=${id%.meta}
    meta_ids="${meta_ids:+$meta_ids }$id"
  done
  if [ ! -e "$registry" ] && [ ! -L "$registry" ]; then
    [ -z "$meta_ids" ] && return 0
    printf 'recovery_reason=secondmate registry is absent\n'; return 1
  fi
  [ -f "$registry" ] && [ ! -L "$registry" ] && [ -r "$registry" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || { printf 'recovery_reason=malformed secondmate registry\n'; return 1; }
    id=$SECONDMATE_REGISTRY_ID
    case " $registry_ids " in *" $id "*) printf 'recovery_reason=duplicate secondmate %s\n' "$id"; return 1 ;; esac
    registry_ids="${registry_ids:+$registry_ids }$id"
  done < "$registry"
  for id in $meta_ids; do
    case " $registry_ids " in *" $id "*) ;; *) printf 'recovery_reason=unregistered secondmate %s\n' "$id"; return 1 ;; esac
  done
  for id in $registry_ids; do
    meta="$STATE/$id.meta"
    secondmate_registry_line_for_id "$registry" "$id" || return 1
    expected=$SECONDMATE_REGISTRY_HOME host=$SECONDMATE_REGISTRY_HOST
    if [ ! -f "$meta" ] || [ -L "$meta" ] || [ "$(fm_meta_get "$meta" kind)" != secondmate ]; then
      printf 'recovery_reason=secondmate %s has no valid route metadata\n' "$id"; return 1
    fi
    backend=$(fm_backend_of_meta "$meta") target=$(fm_backend_target_of_meta "$meta")
    harness=$(fm_backend_meta_exact_value "$meta" harness) || return 1
    case "$expected" in /*) ;; *) return 1 ;; esac
    if [ -z "$host" ]; then
      expected=$(cd -- "$expected" 2>/dev/null && pwd -P) || return 1
    fi
    home_key="$host:$expected"
    case "$homes" in *"|$home_key|"*) printf 'recovery_reason=duplicate secondmate home\n'; return 1 ;; esac
    homes="$homes|$home_key|"
    endpoint="$host:$backend:$target"
    case "$seen" in *"|$endpoint|"*) printf 'recovery_reason=duplicate endpoint for %s\n' "$id"; return 1 ;; esac
    seen="$seen|$endpoint|"
    [ -n "$target" ] && [ "$(fm_meta_get "$meta" remote_host)" = "$host" ] || return 1
    if [ -n "$host" ]; then
      if ! verdict=$(fm_run_timed 15 "$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh state "$id" --bound-home 2>/dev/null); then
        printf 'recovery_reason=remote secondmate %s home-bound state check is unavailable; recovery unverified\n' "$id"; return 1
      fi
      [ "$verdict" = alive ] || { printf 'recovery_reason=remote secondmate %s is %s\n' "$id" "$verdict"; return 1; }
      route=$(fm_run_timed 15 "$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh route "$id" 2>/dev/null) || return 1
      found=$(printf '%s\n' "$route" | sed -n 's/^target=//p')
      [ "$found" = "$target" ] && [ "$backend" = herdr ] \
        && [ "$(printf '%s\n' "$route" | sed -n 's/^backend=//p')" = "$backend" ] \
        && [ "$(printf '%s\n' "$route" | sed -n 's/^harness=//p')" = "$harness" ] || return 1
    else
      if ! declare -F fm_backend_herdr_pane_home_state >/dev/null; then
        printf 'recovery_reason=home-bound secondmate recovery support is not installed; recovery unverified\n'; return 1
      fi
      [ "$backend" = herdr ] || { printf 'recovery_reason=secondmate %s has an unsupported recovery backend\n' "$id"; return 1; }
      session=$(fm_backend_meta_exact_value "$meta" herdr_session) || return 1
      mate_pane=$(fm_backend_meta_exact_value "$meta" herdr_pane_id) || return 1
      [ "$target" = "$session:$mate_pane" ] || return 1
      info=$(fm_backend_herdr_cli "$session" pane get "$mate_pane") || return 1
      printf '%s' "$info" | jq -e --arg pane "$mate_pane" \
        --arg ws "$(fm_backend_meta_exact_value "$meta" herdr_workspace_id)" \
        --arg tab "$(fm_backend_meta_exact_value "$meta" herdr_tab_id)" '
        .error == null and .result.pane.pane_id == $pane
        and .result.pane.workspace_id == $ws and .result.pane.tab_id == $tab
      ' >/dev/null || return 1
      found=$(fm_meta_get "$meta" home)
      [ -n "$found" ] || found=$(fm_meta_get "$meta" worktree)
      found=$(cd -- "$found" 2>/dev/null && pwd -P) || return 1
      expected=$(cd -- "$expected" 2>/dev/null && pwd -P) || return 1
      [ "$found" = "$expected" ] && [ "$expected" != "$FM_HOME" ] || return 1
      [ "$(fm_backend_herdr_pane_home_state "${target%%:*}" "${target#*:}" "$expected")" = match ] || return 1
      verdict=$(fm_backend_agent_state herdr "$target" "$expected")
      [ "$verdict" = alive ] || { printf 'recovery_reason=secondmate %s is %s\n' "$id" "$verdict"; return 1; }
      [ "$(fm_meta_get "$meta" herdr_workspace_id)" != "$PRIMARY_FOUND_WORKSPACE" ] || return 1
    fi
  done
}

primary_report() {
  local detected=false initialized=false recovered=false supervised=false completion before
  primary_read_lock
  primary_server_state
  if [ "$PRIMARY_SERVER" = running ]; then primary_discover; fi
  [ -z "$PRIMARY_PANE" ] || detected=true
  before=$PRIMARY_OWNER
  if primary_owner_in_pane "$PRIMARY_PANE"; then
    completion=$(cat "$STATE/.session-start-complete" 2>/dev/null || true)
    if [ ! -L "$STATE/.session-start-complete" ] && [ "$completion" = "$PRIMARY_OWNER" ] \
      && FM_WAKE_NO_MKDIR=1 "$FM_HOME/bin/fm-startup-network.sh" owner "$PRIMARY_OWNER"; then
      initialized=true
      if FM_WAKE_NO_MKDIR=1 "$FM_HOME/bin/fm-startup-network.sh" ready "$PRIMARY_OWNER"; then
        if primary_mates_ready; then recovered=true; else printf 'recovery_reason=one or more secondmate bindings remain unverified\n'; fi
      else
        printf 'recovery_reason=current locked startup generation is incomplete\n'
      fi
    fi
  elif [ "$PRIMARY_LOCK" = live ]; then
    primary_die "session lock belongs to a different or unproven primary"
  fi
  if [ "$initialized" = true ]; then
    if ! fm_supervision_needed "$STATE" || fm_watcher_healthy "$STATE" "$FM_HOME/bin/fm-watch.sh" "$(fm_poll_derived_grace)" "$FM_HOME"; then
      supervised=true
    fi
  else
    printf 'initialization_reason=current primary has not completed native session-start\n'
  fi
  primary_read_lock
  [ "$before" = "$PRIMARY_OWNER" ] || { initialized=false; recovered=false; supervised=false; }
  printf 'agent_detected=%s\nprimary_initialized=%s\nrecovery_ready=%s\nsupervision_healthy=%s\n' \
    "$detected" "$initialized" "$recovered" "$supervised"
  printf 'home=%s\nsession=%s\nworkspace=%s\ntab=%s\npane=%s\n' "$FM_HOME" "$PRIMARY_SESSION" "$PRIMARY_FOUND_WORKSPACE" "$PRIMARY_TAB" "$PRIMARY_PANE"
  [ "$initialized" = true ] && [ "$recovered" = true ]
}

primary_record() {  # <phase> [terminal-id]
  local tmp
  tmp=$(umask 077; mktemp "$STATE/.primary-start.XXXXXX") || primary_die "cannot publish launch receipt"
  if ! {
    printf 'phase=%s\nhome=%s\nsession=%s\nworkspace=%s\npane=%s\nterminal=%s\n' \
      "$1" "$FM_HOME" "$PRIMARY_SESSION" "$PRIMARY_FOUND_WORKSPACE" "$PRIMARY_PANE" "${2:-}"
  } > "$tmp"; then primary_die "cannot write launch receipt"; fi
  mv -f -- "$tmp" "$STATE/.primary-start" || primary_die "cannot publish launch receipt"
}

primary_start() {
  local out pane terminal command prompt flag name old_terminal old_pane receipt="$STATE/.primary-start" deadline launch_pane shell_pid
  primary_read_lock
  primary_server_state
  if [ "$PRIMARY_SERVER" = stopped ]; then
    [ "$PRIMARY_LOCK" != live ] || primary_die "a live primary holds the lock; server was left stopped"
    fm_backend_herdr_server_ensure "$PRIMARY_SESSION" || primary_die "selected server could not be started"
    primary_server_state
  fi
  primary_discover
  if [ -n "$PRIMARY_PANE" ]; then
    if [ "$PRIMARY_LOCK" = live ]; then primary_owner_in_pane "$PRIMARY_PANE" || primary_die "another primary holds the session lock"; fi
    primary_report || true
    return 0
  fi
  [ "$PRIMARY_LOCK" != live ] || primary_die "another live harness holds the session lock"
  if [ -e "$receipt" ] || [ -L "$receipt" ]; then
    [ -f "$receipt" ] && [ ! -L "$receipt" ] || primary_die "unsafe launch receipt"
    [ "$(fm_meta_get "$receipt" home)" = "$FM_HOME" ] && [ "$(fm_meta_get "$receipt" session)" = "$PRIMARY_SESSION" ] \
      || primary_die "launch receipt belongs to another home/session"
    case "$(fm_meta_get "$receipt" phase)" in
      creating) primary_die "prior create outcome is unknown; inspect the retained launch receipt" ;;
      prepared)
        old_pane=$(fm_meta_get "$receipt" pane) old_terminal=$(fm_meta_get "$receipt" terminal)
        out=$(primary_cli pane get "$old_pane") || primary_die "prior launch outcome is unknown"
        terminal=$(printf '%s' "$out" | jq -er '.result.pane.terminal_id') || primary_die "prior launch identity is unreadable"
        [ -n "$old_terminal" ] && [ "$terminal" != "$old_terminal" ] \
          || primary_die "prior launch may still be queued; no duplicate was submitted"
        ;;
      detecting) primary_die "prior launch may still be queued; no duplicate was submitted" ;;
      launched) ;;
      *) primary_die "malformed launch receipt" ;;
    esac
  fi
  primary_record creating
  if [ -n "$PRIMARY_FOUND_WORKSPACE" ]; then
    out=$(primary_cli tab create --workspace "$PRIMARY_FOUND_WORKSPACE" --label helm --cwd "$FM_HOME" --no-focus) \
      || primary_die "tab creation outcome is unknown; receipt retained"
  else
    out=$(primary_cli workspace create --cwd "$FM_HOME" --label "$PRIMARY_LABEL" --no-focus) \
      || primary_die "workspace creation outcome is unknown; receipt retained"
  fi
  PRIMARY_PANE=$(printf '%s' "$out" | jq -er '.result.root_pane.pane_id') || primary_die "created pane response is incomplete"
  PRIMARY_FOUND_WORKSPACE=$(printf '%s' "$out" | jq -er '.result.root_pane.workspace_id') || primary_die "created workspace response is incomplete"
  pane=$(primary_cli pane get "$PRIMARY_PANE") || primary_die "created pane cannot be revalidated"
  pane=$(printf '%s' "$pane" | jq -ec '.result.pane') || primary_die "created pane is unreadable"
  primary_pane_home_matches "$pane" "$FM_HOME" || primary_die "created pane belongs to another home"
  [ "$(printf '%s' "$pane" | jq -r '.workspace_id')" = "$PRIMARY_FOUND_WORKSPACE" ] || primary_die "created pane moved unexpectedly"
  terminal=$(printf '%s' "$pane" | jq -er '.terminal_id') || primary_die "created terminal identity is unreadable"
  shell_pid=$(fm_backend_herdr_pane_idle_shell_pid "$PRIMARY_SESSION" "$PRIMARY_PANE") \
    || primary_die "created pane is not a proven idle shell"
  primary_read_lock
  [ "$PRIMARY_LOCK" != live ] || primary_die "a primary took the lock during creation; no launch was submitted"
  primary_record prepared "$terminal"
  prompt='Take the primary role in this home. Read the native session-start digest; run bin/fm-session-start.sh exactly once only if it was not delivered. Defer auxiliary tabs and relabeling. Finish current-generation secondmate recovery through the existing owners, then check bin/fm-primary-start.sh ready with this exact home, backend herdr, harness claude, session and workspace. Only after recovery_ready=true run any private layout with those exact IDs. Follow the emitted Claude supervision protocol; Stop owns watcher arming. Read docs/primary-recovery.md for the recovery sequence.'
  prompt="$prompt Session=$PRIMARY_SESSION Workspace=$PRIMARY_FOUND_WORKSPACE Home=$FM_HOME"
  printf -v command 'cd -- %q && exec env' "$FM_HOME"
  for name in "${FM_LAUNCH_CLEAR_NAMES[@]}" FM_ROOT FM_BACKEND FM_TASK_ID FM_OMP_HARNESS ANTIGRAVITY_AGENT GEMINI_CLI GEMINI_CLI_SYSTEM_SETTINGS_PATH GROK_HOOK_EVENT; do
    printf -v command '%s -u %q' "$command" "$name"
  done
  printf -v command '%s %q %q %q %q' "$command" "FM_HOME=$FM_HOME" 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false' 'CLAUDE_CODE_SEND_FEEDBACK=0' "$PRIMARY_CLAUDE"
  for flag in $CLAUDE_PERM_FLAG; do printf -v command '%s %q' "$command" "$flag"; done
  printf -v command '%s --settings %q %q' "$command" '{"feedbackDrafts":"off","attribution":{"commit":"","pr":"","sessionUrl":false}}' "$prompt"
  launch_pane=$PRIMARY_PANE
  out=$(primary_cli pane get "$launch_pane") || primary_die "launch pane became unreadable"
  [ "$(printf '%s' "$out" | jq -r '.result.pane.terminal_id')" = "$terminal" ] \
    && primary_pane_home_matches "$(printf '%s' "$out" | jq -c '.result.pane')" "$FM_HOME" \
    && [ "$(fm_backend_herdr_pane_idle_shell_pid "$PRIMARY_SESSION" "$launch_pane")" = "$shell_pid" ] \
    || primary_die "launch pane identity changed; no command was submitted"
  primary_read_lock
  [ "$PRIMARY_LOCK" != live ] || primary_die "another primary took the lock; no command was submitted"
  primary_cli pane run "$PRIMARY_PANE" "$command" >/dev/null || primary_die "launch outcome is unknown; receipt retained, no retry"
  primary_record detecting "$terminal"
  deadline=$(( $(date +%s) + 30 ))
  while :; do
    primary_discover
    if [ -n "$PRIMARY_PANE" ]; then
      [ "$PRIMARY_PANE" = "$launch_pane" ] || primary_die "another primary appeared; submitted launch remains uncertain"
      primary_record launched "$terminal"
      primary_cli agent rename "$PRIMARY_PANE" helm >/dev/null \
        || primary_die "primary was detected but naming failed; inspect it before retrying"
      primary_report || true
      return 0
    fi
    [ "$(date +%s)" -lt "$deadline" ] || primary_die "primary detection timed out; inspect the prepared receipt and pane, do not resend"
    sleep 0.2
  done
}
