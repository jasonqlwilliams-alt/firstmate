#!/usr/bin/env bash
# bin/backends/tmux.sh - the tmux session-provider adapter.
#
# The reference backend, sourced only through bin/fm-backend.sh's fm_backend_source.
# See docs/tmux-backend.md for the operator contract.
#
# fm-spawn.sh owns worktree acquisition and uses this adapter for pane input
# and working-directory reads.
#
# The verified composer/busy-detection and verify-and-retry-submit primitives
# already live in bin/fm-tmux-lib.sh, shared with the away-mode daemon
# (bin/fm-supervise-daemon.sh); this adapter sources that file and re-exports
# its submit core under the backend's naming convention rather than
# duplicating it, so the two consumers cannot drift apart.
# shellcheck source=bin/fm-tmux-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-agent-process-lib.sh"

# fm_backend_tmux_resolve_bare_selector: the live-window-listing fallback for a
# selector that is neither an explicit target nor a task selector routed
# through meta - an ad hoc window name with no recorded task. Mirrors the
# `tmux list-windows -a ... | grep` pipeline that used to live inline in
# fm-send.sh's and fm-peek.sh's own (until now duplicated) resolve().
fm_backend_tmux_resolve_bare_selector() {  # <name>
  local name=$1
  tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -m1 ":$name\$" \
    || { echo "error: no window named $name" >&2; return 1; }
}

# Bounded plain-text capture of the recorded worker pane.
fm_backend_tmux_capture() {  # <target> <lines> [explicit]
  local target
  if target=$(fm_tmux_exact_target "$1" "${3:-}"); then
    fm_tmux_pane_command "$target" capture-pane -p -S -"$2"
  else
    case $? in
      1) echo "error: tmux window $1 not found" >&2 ;;
      *) echo "error: could not resolve tmux window $1" >&2 ;;
    esac
    return 1
  fi
}

fm_backend_tmux_target_exists() {  # <target> [explicit]
  local target diagnostic
  target=$(fm_tmux_exact_target "$@") || return $?
  if [ "${2:-}" = explicit ]; then
    diagnostic=$(fm_tmux_pane_command "$target" capture-pane -p -S 0 -E 0 2>&1 >/dev/null) && return 0
  else
    diagnostic=$(fm_tmux_pane_command "$target" list-panes -F '#{pane_id}' 2>&1 >/dev/null) && return 0
  fi
  fm_tmux_read_failure_status "$diagnostic"
}

fm_backend_tmux_send_key() {  # <target> <key> [explicit]
  local target
  target=$(fm_tmux_exact_target "$1" "${3:-}") || return $?
  if [[ ! $target =~ $FM_TMUX_PANE_PATTERN ]]; then
    fm_backend_tmux_target_exists "$target" "${3:-}" || return $?
  fi
  fm_tmux_pane_command "$target" send-keys "$2"
}

fm_backend_tmux_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle> [explicit]
  fm_tmux_submit_core "$@"
}

fm_backend_tmux_launch_session() {
  local session=firstmate
  if [ -n "${TMUX:-}" ]; then
    session=$(tmux display-message -p '#S') || return 1
    [ -n "$session" ] || return 1
  fi
  printf '%s\n' "$session"
}

# fm_backend_tmux_container_ensure: reuse the current tmux session when
# firstmate itself runs inside tmux, else ensure a dedicated detached
# "firstmate" session exists. Return the binding that spawn must use for
# the duplicate check and placement, including when new-session created it.
fm_backend_tmux_container_ensure() {  # <session-name> [session-binding]
  local session=$1 binding=${2:-}
  fm_backend_required_tool_available tmux tmux || {
    if [ "$?" -eq 2 ]; then
      echo "error: could not verify list-windows -f support on the tmux server. See docs/tmux-backend.md#setup." >&2
    else
      echo "error: spawning with tmux requires a tmux client version $FM_BACKEND_TMUX_MIN_VERSION or later" >&2
    fi
    return 1
  }
  if [ -z "$binding" ]; then
    if binding=$(fm_tmux_exact_session "$session"); then
      :
    elif [ "$?" -eq 1 ] && [ -z "${TMUX:-}" ] && [ "$session" = firstmate ]; then
      binding=$(tmux new-session -dP -F "$FM_TMUX_SESSION_FORMAT" -s firstmate) || return 1
    else
      return 1
    fi
  fi
  [[ $binding =~ $FM_TMUX_SESSION_PATTERN ]] || return 1
  printf '%s\n' "$binding"
}

# Refuse a duplicate in the destination session and place the window at the
# next free index (including with a non-default base-index). Return the pane
# binding from new-window itself so a restarted server cannot supply a new
# pane for the spawn commands. Pin the name before the shell changes cwd.
fm_backend_tmux_create_task() {  # <session-name> <window-name> <proj-abs> <session-binding>
  local session=$1 name=$2 cwd=$3 binding=${4:-} duplicate created literal
  literal=$(fm_tmux_format_literal "$name")
  duplicate=$(fm_tmux_session_command "$binding" list-windows : \
    -f "#{==:#{window_name},$literal}" -F '#{window_id}') || return 1
  if [ -n "$duplicate" ]; then
    echo "error: window $session:$name already exists" >&2
    return 1
  fi
  created=$(fm_tmux_session_command "$binding" new-window : -dP -F "$FM_TMUX_PANE_FORMAT" -n "$name" -c "$cwd") || return 1
  [[ $created =~ $FM_TMUX_PANE_PATTERN ]] || return 1
  # A shell startup hook can rename the window before allow-rename is pinned.
  if ! fm_tmux_pane_command "$created" set-window-option automatic-rename off ||
     ! fm_tmux_pane_command "$created" set-window-option allow-rename off ||
     ! fm_tmux_pane_command "$created" rename-window -- "$name"; then
    fm_backend_tmux_kill "$created" || true
    return 1
  fi
  printf '%s\n' "$created"
}

# fm_backend_tmux_current_path: used by spawn to discover the worktree from
# the recorded window. Unresolved windows yield no path.
fm_backend_tmux_current_path() {  # <target>
  local target
  target=$(fm_tmux_exact_target "$1") || return 1
  fm_tmux_pane_command "$target" display-message -p '#{pane_current_path}' 2>/dev/null
}

# Send a fixed spawn command and one named Enter in the same tmux command.
fm_backend_tmux_send_text_line() {  # <target> <text>
  local target
  target=$(fm_tmux_exact_target "$1") || return $?
  fm_tmux_pane_command "$target" send-keys "$2" Enter
}

fm_backend_tmux_send_literal() {  # <target> <text>
  local target
  target=$(fm_tmux_exact_target "$1") || return $?
  fm_tmux_pane_command "$target" send-keys -l "$2"
}

# fm_backend_tmux_kill: remove one recorded or bound task window, best-effort.
# Empty, omitted, and malformed targets return nonzero before invoking tmux so
# tmux can never interpret an empty target as the caller's current window.
fm_backend_tmux_kill() {  # <recorded-or-bound-target>
  local target=${1:-}
  case "$target" in *:*) ;; *) return 1 ;; esac
  if target=$(fm_tmux_exact_target "$target"); then
    fm_tmux_pane_command "$target" kill-window 2>/dev/null || true
  else
    [ "$?" -eq 1 ]
  fi
}

# fm_backend_tmux_current_command: <target>'s live foreground process name -
# tmux's own `#{pane_current_command}`, already resolved from the pty's
# foreground process group (verified empirically with real tmux 3.6a: a
# harness invoked interactively stays the reported command even while it
# shells out to subcommands that do not take over the pty - e.g. `bash -c
# "sleep 30"` alone reports "sleep" because bash execs directly into it, but
# a persisting parent script running `sleep` as a child reports the PARENT's
# own name throughout; the value reverts to the shell's own name only once
# the foreground command actually exits). Empty on any tmux error.
fm_backend_tmux_current_command() {  # <target>
  local target
  target=$(fm_tmux_exact_target "$1") || return 1
  fm_tmux_pane_command "$target" display-message -p '#{pane_current_command}' 2>/dev/null
}

# The process-name classifier every liveness signal below feeds
# (fm_agent_process_classify_name) is owned by bin/fm-agent-process-lib.sh,
# shared with the Herdr adapter so both backends mean the same thing by
# `agent`, `shell`, and `other`.

# fm_backend_tmux_foreground_comms: the kernel-side names of every process in
# <target>'s pane tty foreground process group, one full value per line.
# Empty on any failure.
#
# This is the foreground-process-group half of the liveness probe, and it exists
# because `#{pane_current_command}` and `ps -o comm=` expose different name
# fields whose roles vary by platform. On macOS the tmux field can carry a
# harness-rewritten title (Claude Code 2.1.220 reports `2.1.220`) while `comm`
# retains executable identity; the portable Linux regression observes the
# reverse for its version-named executable. Reading both `comm` and argv[0]
# preserves an identifying install path without making either platform's field
# assignment load-bearing.
#
# Scoping to the foreground process group rather than to the pane's descendants
# is what keeps the probe honest in the other direction: a harness-named process
# left running in the background of an otherwise idle pane is deliberately NOT
# reported, so a genuinely agent-free pane still classifies `dead`. It also
# reports every member of a multi-process launcher (the Pi Launcher path runs a
# `pi-signed` wrapper and a `pi` engine in one group), so no launcher needs its
# own special case here.
#
# Like every pane read here it targets exactly the recorded window through
# fm_tmux_exact_target (bin/fm-tmux-lib.sh): tmux would otherwise answer an
# absent name from a prefix-named neighbour or the client's active window and
# describe some other pane entirely.
fm_backend_tmux_foreground_comms() {  # <target>
  local target tty pid pgid tpgid comm
  target=$(fm_tmux_exact_target "$1") || return 0
  tty=$(fm_tmux_pane_command "$target" display-message -p '#{pane_tty}' 2>/dev/null) || return 0
  [ -n "$tty" ] || return 0
  LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
    | while read -r pid pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        printf '%s\n' "$comm"
      done
}

# The foreground group's full command lines. Needed because a node-bundle
# harness carries its identity in argv[1] rather than in its command name or
# argv[0]; bin/fm-gemini-lib.sh owns what counts as evidence inside one.
fm_backend_tmux_foreground_args() {  # <target>
  local target tty pid pgid tpgid comm args
  target=$(fm_tmux_exact_target "$1") || return 0
  tty=$(fm_tmux_pane_command "$target" display-message -p '#{pane_tty}' 2>/dev/null) || return 0
  [ -n "$tty" ] || return 0
  LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
    | while read -r pid pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) || continue
        [ -n "$args" ] && printf '%s\n' "$args"
      done
}

fm_backend_tmux_foreground_pids() {  # <target>
  local target tty pid pgid tpgid comm
  target=$(fm_tmux_exact_target "$1") || return 0
  tty=$(fm_tmux_pane_command "$target" display-message -p '#{pane_tty}' 2>/dev/null) || return 0
  [ -n "$tty" ] || return 0
  LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
    | while read -r pid pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        printf '%s\n' "$pid"
      done
}

# The foreground process-group leader: pid == pgid == tpgid. Children that
# share the group (npx, uv, MCP servers) have pid != pgid and must not supply
# the pane PATH used for relaunch executable resolution.
fm_backend_tmux_foreground_leader_pid() {  # <target>
  local target tty pid pgid tpgid comm
  target=$(fm_tmux_exact_target "$1") || return 1
  tty=$(fm_tmux_pane_command "$target" display-message -p '#{pane_tty}' 2>/dev/null) || return 1
  [ -n "$tty" ] || return 1
  while read -r pid pgid tpgid comm; do
    [ -n "$comm" ] || continue
    [ "$pgid" = "$tpgid" ] || continue
    [ "$pid" = "$pgid" ] || continue
    printf '%s\n' "$pid"
    return 0
  done <<EOF
$(LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null)
EOF
  return 1
}

fm_backend_tmux_foreground_argv0s() {  # <target>
  local target tty pid pgid tpgid comm args argv0
  target=$(fm_tmux_exact_target "$1") || return 0
  tty=$(fm_tmux_pane_command "$target" display-message -p '#{pane_tty}' 2>/dev/null) || return 0
  [ -n "$tty" ] || return 0
  LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
    | while read -r pid pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) || continue
        args=${args#"${args%%[![:space:]]*}"}
        argv0=${args%%[[:space:]]*}
        [ -n "$argv0" ] && printf '%s\n' "$argv0"
      done
}

# See docs/tmux-backend.md "Agent liveness probe" for the empirical basis.
# Check the exact recorded session and window because implicit tmux target
# resolution can select a different window when the recorded one is absent;
# fm_tmux_exact_target (bin/fm-tmux-lib.sh) owns that exact lookup.
# An omitted window or a definitive missing-session/server response is
# `missing`. Other inventory failures are `unreadable`.
fm_backend_tmux_endpoint_state() {  # <target>
  local target=$1 resolve_status
  [[ $target = *:* ]] || { printf 'unreadable'; return 0; }
  if fm_backend_tmux_target_exists "$target"; then
    resolve_status=0
  else
    resolve_status=$?
  fi
  case "$resolve_status" in
    0) printf 'present' ;;
    1) printf 'missing' ;;
    *) printf 'unreadable' ;;
  esac
}

# fm_backend_tmux_agent_state: recovery-grade harness-agent state for one
# recorded target. See bin/fm-backend.sh's fm_backend_agent_state for the
# shared state vocabulary and docs/tmux-backend.md "Agent liveness probe" for
# its relationship to presence. Use the fm_tmux_exact_target verdict before
# reading process names so an unresolved endpoint cannot license a duplicate.
#
# The verdict combines two independent name sources rather than trusting either
# alone. Either source naming a verified harness is enough for `alive`, because
# a false `dead` is the one outcome that can launch a duplicate agent onto a
# live worktree, while the foreground process group - when it is readable - is
# authoritative for the negative verdicts, since it is the only source that can
# distinguish a truly idle pane from a rewritten process title.
fm_backend_tmux_agent_state() {  # <target>
  local target=$1 comm resolved resolve_status
  local foreground argv0s name pid fg_seen=0 fg_shell=0 fg_other=0
  [[ $target = *:* ]] || { printf 'unreadable'; return 0; }
  if resolved=$(fm_tmux_exact_target "$target"); then
    resolve_status=0
  else
    resolve_status=$?
  fi
  case "$resolve_status" in
    0) target=$resolved ;;
    1) printf 'missing'; return 0 ;;
    *) printf 'unreadable'; return 0 ;;
  esac

  foreground=$(fm_backend_tmux_foreground_comms "$target")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    fg_seen=1
    case "$(fm_agent_process_classify_name "$name")" in
      agent) printf 'alive'; return 0 ;;
      shell) fg_shell=1 ;;
      *) fg_other=1 ;;
    esac
  done <<EOF
$foreground
EOF

  argv0s=$(fm_backend_tmux_foreground_argv0s "$target")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ "$(fm_agent_process_classify_name '' "$name")" = agent ]; then
      printf 'alive'
      return 0
    fi
  done <<EOF
$argv0s
EOF

  # Preserve argv boundaries where the platform exposes them. This is needed
  # when the Gemini script path contains whitespace, which flattened ps output
  # cannot represent unambiguously.
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    if fm_gemini_pid_is_gemini "$pid"; then
      printf 'alive'
      return 0
    fi
  done <<EOF
$(fm_backend_tmux_foreground_pids "$target")
EOF

  # Fall back to flattened arguments on platforms without /proc. Positive
  # evidence only - a bare interpreter still reaches the negative verdicts.
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if fm_gemini_args_are_gemini "$name"; then
      printf 'alive'
      return 0
    fi
  done <<EOF
$(fm_backend_tmux_foreground_args "$target")
EOF

  if ! comm=$(fm_tmux_pane_command "$target" display-message -p '#{pane_current_command}' 2>&1); then
    fm_tmux_read_failure_status "$comm" || resolve_status=$?
    if [ "$resolve_status" -eq 1 ]; then
      printf 'missing'
    else
      printf 'unreadable'
    fi
    return 0
  fi
  if [ "$(fm_agent_process_classify_name "$comm")" = agent ]; then
    printf 'alive'
    return 0
  fi

  # A readable foreground process group settles the negative verdicts: only a
  # group that is nothing but shells is confidently agent-free.
  if [ "$fg_seen" -eq 1 ]; then
    if [ "$fg_other" -eq 0 ] && [ "$fg_shell" -eq 1 ]; then
      printf 'dead'
    else
      printf 'ambiguous'
    fi
    return 0
  fi

  case "$comm" in
    '') printf 'unreadable'; return 0 ;;
  esac
  case "$(fm_agent_process_classify_name "$comm")" in
    shell) printf 'dead' ;;
    *) printf 'ambiguous' ;;
  esac
}

# Backward-compatible three-state view for callers that only need a yes/no
# agent verdict. The detailed state contract is owned by fm_backend_agent_state.
fm_backend_tmux_agent_alive() {  # <target>
  case "$(fm_backend_tmux_agent_state "$1")" in
    alive) printf 'alive' ;;
    dead|missing) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}
