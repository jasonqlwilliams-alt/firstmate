#!/usr/bin/env bash
# Shared session-lock ownership and legacy harness identification.
# bin/fm-lock.sh acquires and inspects a home's lock. Startup and hook readers
# share the binding verifier here. This file has no side effects on source.

# Cursor process identity is NOT expressible as a command-name pattern and is
# deliberately not added to the tables below: Cursor's installed names are
# cursor-agent and the far-too-generic legacy alias `agent`, and it runs as a
# bundled node script. bin/fm-cursor-lib.sh is the fleet's single owner of that
# decision, so this file delegates to it rather than widening the name match.
# shellcheck source=bin/fm-cursor-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-cursor-lib.sh"

# shellcheck source=bin/fm-session-lock-record-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-session-lock-record-lib.sh"

# Known harness command names; extend when a new adapter is verified. omp is
# anchored exactly like pi: its process name is the bare word `omp` (verified,
# omp 18.1.11), and a substring match would claim ompd or comp.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$|^omp$'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi omp)

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

# True when the process described by command name $1 and full argument string $2
# is a verified harness. Sets FM_HARNESS_IS_CLAUDE for the ancestry walk.
#
# Evidence, in order:
#   1. the basename of the reported command name, against FM_HARNESS_RE.
#   2. an exact harness component in that command path or in argv[0]. Both are
#      needed because the two platforms report different things: macOS reports
#      argv[0] in `ps -o comm=`, while procps on Linux reports the kernel exec
#      name and ignores argv[0] entirely, so a version-named Claude Code binary
#      is identified by its install path on macOS and by argv[0] on Linux.
#   3. a bare interpreter (node, python) running a harness script path.
#   4. Cursor's own structural identity, owned by bin/fm-cursor-lib.sh.
FM_HARNESS_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  FM_HARNESS_IS_CLAUDE=0
  base=$(basename -- "$comm")
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
        case "$args" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
        return 0
      fi
      ;;
  esac
  # Cursor: its own owner decides, from Cursor's name or versioned install tree
  # in the command path or argv[0]. Without this a Cursor primary can never
  # locate its own harness in the ancestry, so every session start refuses the
  # fleet lock as read-only and the park can never arm.
  fm_cursor_process_matches "$comm" "$args" "$argv0" && return 0
  return 1
}

# Walk the current process ancestry (up to 16 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
#
# The walk climbs freely until the first harness match, because the caller is
# normally an ordinary shell several levels below its session. After that first
# match it stops at the first non-harness ancestor, so it can never cross a gap
# into an unrelated harness further up the real process tree - for example the
# live session that launched a test as its own subprocess.
#
# For every harness except Claude the innermost match is the session, which is
# where e.g. Pi's shared signed-wrapper ancestry actually holds the lock: a
# "pi-signed" launcher can be the direct parent of the inner "pi" engine pid that
# owns the lock, and the wrapper pid above it is not that owner. Claude Code
# instead runs hooks several levels below the session inside its own nested
# worker chain (hook shell -> claude bg-spare -> claude bg-pty-host -> claude ->
# claude), with no non-harness process between them. Which pid in that run is the
# session cannot be read off the ancestry at all, so the whole contiguous run is
# reported and the callers below decide what they need from it.
fm_harness_ancestry_pids() {
  local pid=$$ comm args extending=0 printed=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  [ "$printed" -eq 1 ]
}

# Print the one pid that identifies this session when the session lock is being
# WRITTEN: the outermost pid of the contiguous run. That is the pid that lives as
# long as the session - a Claude worker several levels in is reaped when its hook
# returns, and a lock naming it would look stale moments later while the session
# is still running. Every non-Claude harness reports a single pid, so this is its
# innermost match unchanged.
fm_harness_ancestry_pid() {
  local pids pid outermost=''
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$pids
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args"
}

# Ownership requires the start-time check and a lock PID that names ANY
# harness ancestor of the current process. Check the whole chain because the
# lock owner sits at an unknown depth in a contiguous Claude run - it is the
# outermost pid when the hook fires inside the session's own nested worker chain,
# and an inner pid when a harness-named daemon parents the session. A missing
# lock, a malformed lock, a lock held by a harness outside this ancestry, or an
# ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids pid
  fm_session_lock_read "$state/.lock" || return 1
  if [ -n "$FM_SESSION_LOCK_GENERATION" ]; then
    fm_session_owner_context && fm_session_owner_matches_context
    return
  fi
  fm_session_owner_context_present && return 1
  lock_pid=$FM_SESSION_LOCK_PID
  case "$lock_pid" in ''|0|1|*[!0-9]*) return 1 ;; esac
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    if [ "$pid" = "$lock_pid" ]; then
      fm_session_lock_start_matches "$lock_pid" "$FM_SESSION_LOCK_START"
      return $?
    fi
  done <<EOF
$pids
EOF
  return 1
}

fm_session_lock_owner_alive() {  # <pid> <recorded-start>
  fm_session_lock_start_matches "$1" "$2" && fm_harness_pid_alive "$1"
}

fm_session_lock_write_start() {  # <lock-file> <pid> <start>
  local sidecar="$1.start" pid=$2 start=$3 tmp
  [ -n "$start" ] && [ ! -d "$sidecar" ] || return 1
  tmp=$(mktemp "${sidecar%/*}/.lock-write.XXXXXX" 2>/dev/null) || return 1
  if fm_session_lock_print_record "$pid" "$start" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$sidecar" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

fm_session_lock_write() {  # <lock-file> <pid> <start>
  local lock=$1 pid=$2 start=$3 tmp
  case "$pid" in ''|0|1|*[!0-9]*) return 1 ;; esac
  tmp=$(mktemp "${lock%/*}/.lock-write.XXXXXX" 2>/dev/null) || return 1
  if printf '%s\n' "$pid" > "$tmp" 2>/dev/null \
    && {
      if [ -n "$start" ]; then
        fm_session_lock_write_start "$lock" "$pid" "$start"
      else
        rm -f "$lock.start" 2>/dev/null
      fi
    } \
    && mv -f "$tmp" "$lock" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

fm_session_start_completion_matches() {  # <completion-file> <pid> <start>
  local file=$1 pid=$2 start=$3 completion expected
  file=$(fm_session_start_completion_path "$file" "${FM_SESSION_LOCK_GENERATION:-}")
  [ -n "$start" ] && [ -f "$file" ] && [ ! -L "$file" ] || return 1
  completion=$(cat "$file" 2>/dev/null) || return 1
  if [ -n "${FM_SESSION_LOCK_GENERATION:-}" ]; then
    [ "$FM_SESSION_LOCK_PID" = "$pid" ] && [ "$FM_SESSION_LOCK_START" = "$start" ] || return 1
    expected=$(fm_session_lock_receipt) || return 1
  else
    expected=$(fm_session_lock_print_record "$pid" "$start") || return 1
  fi
  [ "$completion" = "$expected" ]
}

# The environment carries the secret separately from the readable fingerprint.
# A nested launcher always scrubs all five fields before selecting its home.
fm_session_owner_clear() {
  unset FM_SESSION_OWNER_ID FM_SESSION_OWNER_HOME FM_SESSION_OWNER_PID \
    FM_SESSION_OWNER_START FM_SESSION_OWNER_KIND FM_BOOTSTRAP_NETWORK_LOCK_PID \
    FM_BOOTSTRAP_NETWORK_LOCK_GEN FM_BOOTSTRAP_NETWORK_WORKER_PID FM_BOOTSTRAP_NETWORK_WORKER_START \
    FM_TIMEOUT_STARTUP_SCOPE
}

fm_session_owner_bind() { # <pid> <launch|startup>
  fm_session_owner_clear
  FM_SESSION_OWNER_PID=$1 FM_SESSION_OWNER_KIND=$2
  FM_SESSION_OWNER_HOME=$(fm_session_owner_home) || return 1
  FM_SESSION_OWNER_START=$(fm_session_owner_token "$1") || return 1
  FM_SESSION_OWNER_ID=$(od -An -N32 -v -tx1 /dev/urandom | tr -d '[:space:]')
  [[ "$FM_SESSION_OWNER_ID" =~ ^[0-9a-f]{64}$ ]] || return 1
  export FM_SESSION_OWNER_ID FM_SESSION_OWNER_HOME FM_SESSION_OWNER_PID \
    FM_SESSION_OWNER_START FM_SESSION_OWNER_KIND
}

fm_session_owner_context_present() {
  [ -n "${FM_SESSION_OWNER_ID:-}${FM_SESSION_OWNER_HOME:-}${FM_SESSION_OWNER_PID:-}${FM_SESSION_OWNER_START:-}${FM_SESSION_OWNER_KIND:-}" ]
}

fm_session_owner_context() {
  fm_session_owner_enabled || return 1
  [[ "${FM_SESSION_OWNER_ID:-}" =~ ^[0-9a-f]{64}$ ]] || return 1
  [ -n "${FM_SESSION_OWNER_HOME:-}" ] && [ "$FM_SESSION_OWNER_HOME" = "$(fm_session_owner_home)" ] || return 1
  case "${FM_SESSION_OWNER_KIND:-}" in launch|startup|native) ;; *) return 1 ;; esac
  case "${FM_SESSION_OWNER_START:-}" in linux:*|darwin:*) ;; *) return 1 ;; esac
  fm_session_owner_liveness "${FM_SESSION_OWNER_PID:-}" "$FM_SESSION_OWNER_START" || return 1
  FM_SESSION_OWNER_FINGERPRINT=$(printf '%s\n%s\n' "$FM_SESSION_OWNER_HOME" "$FM_SESSION_OWNER_ID" | fm_session_owner_hash)
}

fm_session_owner_matches_context() {
  [ "$FM_SESSION_LOCK_PID" = "${FM_SESSION_OWNER_PID:-}" ] \
    && [ "$FM_SESSION_LOCK_START" = "${FM_SESSION_OWNER_START:-}" ] \
    && [ "$FM_SESSION_LOCK_KIND" = "${FM_SESSION_OWNER_KIND:-}" ] \
    && [ "$FM_SESSION_LOCK_FINGERPRINT" = "${FM_SESSION_OWNER_FINGERPRINT:-}" ]
}

fm_session_lock_receipt() {
  if [ -n "${FM_SESSION_LOCK_GENERATION:-}" ]; then
    printf '%s\nstart=%s\ngeneration=%s\n' "$FM_SESSION_LOCK_PID" "$FM_SESSION_LOCK_START" "$FM_SESSION_LOCK_GENERATION"
  else
    fm_session_lock_print_record "$FM_SESSION_LOCK_PID" "$FM_SESSION_LOCK_START"
  fi
}

# Hooks never claim startup-only ownership and only attempt reclamation on
# affirmative departure. The acquisition command rechecks under the mutex.
fm_session_hook_may_recover() {
  local state=$1 rc
  fm_session_lock_read "$state/.lock" || return 1
  if fm_session_owner_enabled || [ -n "$FM_SESSION_LOCK_GENERATION" ]; then
    [ "${FM_SESSION_OWNER_KIND:-}" != startup ] && fm_session_owner_context || return 1
    fm_session_owner_liveness "$FM_SESSION_LOCK_PID" "$FM_SESSION_LOCK_START"
    rc=$?
    [ "$rc" -eq 2 ]
  else
    ! fm_session_lock_owner_alive "$FM_SESSION_LOCK_PID" "$FM_SESSION_LOCK_START"
  fi
}

fm_session_hook_owns_lock() {
  fm_session_lock_owned_by_self "$1" && [ "$FM_SESSION_LOCK_KIND" != startup ]
}


fm_session_start_completion_path() {
  local file=$1 generation=$2
  printf '%s%s\n' "$file" "${generation:+.$generation}"
}
