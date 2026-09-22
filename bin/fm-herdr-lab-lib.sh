#!/usr/bin/env bash
# fm-herdr-lab-lib.sh - the Herdr lab state directory and the two durable
# records kept in it: lab-OWNER records, which mark a process tree as lab
# context, and tripwire BREACH markers, which outlive a suppressed exit status.
#
# Written by bin/fm-herdr-lab.sh, read by bin/backends/herdr.sh and
# bin/fm-test-run.sh. This file is the single owner of both record formats and
# of the state-directory path; no caller hand-composes either.
#
# No side effects on source. set -u / set -e safe.

# The lab state directory. FM_HERDR_LAB_STATE_DIR lets a suite point its labs at
# its own scratch root; the default is shared per UID so a lab provisioned from
# one shell is still visible to the guarded helper in another.
fm_herdr_lab_state_dir() {
  printf '%s' "${FM_HERDR_LAB_STATE_DIR:-${TMPDIR:-/tmp}/fm-herdr-lab-${UID}}"
}

fm_herdr_lab_tripwire_path() { # <session>
  printf '%s/%s.fleet-state.json' "$(fm_herdr_lab_state_dir)" "$1"
}

# --- process identity -------------------------------------------------------
#
# A pid alone is reusable, so every recorded process is bound to its start time
# the same way bin/fm-herdr-lab.sh binds its viewer processes.

fm_herdr_lab_process_start() { # <pid>
  LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

fm_herdr_lab_process_parent() { # <pid>
  LC_ALL=C ps -p "$1" -o ppid= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# Prints this process and its ancestors, nearest first, space separated. Bounded
# so a pathological or cyclic table cannot spin, and stopped before pid 1 so the
# walk never reaches processes that are ancestors of the whole login session.
fm_herdr_lab_ancestor_pids() {
  local pid=$$ chain=$$ depth=0 parent
  while [ "$depth" -lt 24 ]; do
    parent=$(fm_herdr_lab_process_parent "$pid")
    case "$parent" in
      ''|0|1) break ;;
      *[!0-9]*) break ;;
    esac
    chain="$chain $parent"
    pid=$parent
    depth=$((depth + 1))
  done
  printf '%s' "$chain"
}

# --- lab-owner records ------------------------------------------------------
#
# One record per provisioned lab session, naming the SHELL that asked for that
# lab. Only that shell is recorded, never its ancestors, so a sibling fleet
# operation running under the same terminal is never mistaken for lab work.

fm_herdr_lab_owner_path() { # <session>
  printf '%s/%s.owner' "$(fm_herdr_lab_state_dir)" "$1"
}

fm_herdr_lab_owner_claim() { # <session> <pid>
  local session=$1 pid=$2 start record tmp
  start=$(fm_herdr_lab_process_start "$pid")
  [ -n "$start" ] || return 1
  record=$(fm_herdr_lab_owner_path "$session")
  mkdir -p "$(fm_herdr_lab_state_dir)" || return 1
  tmp=$(mktemp "$(fm_herdr_lab_state_dir)/.owner.XXXXXX") || return 1
  chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
  if ! {
    printf 'version=1\n'
    printf 'session=%s\n' "$session"
    printf 'pid=%s\n' "$pid"
    printf 'start=%s\n' "$start"
  } > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$record" || { rm -f "$tmp"; return 1; }
}

fm_herdr_lab_owner_release() { # <session>
  rm -f "$(fm_herdr_lab_owner_path "$1")"
}

fm_herdr_lab_owner_field() { # <record> <key>
  local value
  value=$(sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1)
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

# fm_herdr_lab_owner_context: print the lab session this process is operating and
# return 0, or return 1 when no live lab record names this process or any of its
# ancestors. The glob test comes first so the overwhelmingly common case - no lab
# anywhere on this host - costs one directory expansion and no process reads.
fm_herdr_lab_owner_context() {
  local dir ancestors record pid start
  dir=$(fm_herdr_lab_state_dir)
  [ -d "$dir" ] || return 1
  set -- "$dir"/*.owner
  [ -e "$1" ] || return 1
  ancestors=$(fm_herdr_lab_ancestor_pids)
  for record in "$@"; do
    [ -f "$record" ] || continue
    pid=$(fm_herdr_lab_owner_field "$record" pid) || continue
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    case " $ancestors " in *" $pid "*) ;; *) continue ;; esac
    start=$(fm_herdr_lab_owner_field "$record" start) || continue
    [ "$(fm_herdr_lab_process_start "$pid")" = "$start" ] || continue
    fm_herdr_lab_owner_field "$record" session || continue
    return 0
  done
  return 1
}

# --- tripwire breach markers ------------------------------------------------
#
# A tripwire that reports only through its exit status can be discarded with
# `|| true`, which is exactly what let the 2026-09-21 near miss pass unnoticed.
# A breach therefore writes a durable marker that bin/fm-herdr-lab.sh refuses
# every later lab operation on and bin/fm-test-run.sh fails a whole suite run
# on, so silencing the return code no longer silences the finding.

fm_herdr_lab_breach_path() { # <session>
  printf '%s/%s.tripwire-breach' "$(fm_herdr_lab_state_dir)" "$1"
}

fm_herdr_lab_breach_record() { # <session> <before> <after>
  local session=$1 before=$2 after=$3 record
  record=$(fm_herdr_lab_breach_path "$session")
  mkdir -p "$(fm_herdr_lab_state_dir)" || return 1
  {
    printf 'version=1\n'
    printf 'session=%s\n' "$session"
    printf 'recorded_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"
    printf 'pid=%s\n' "$$"
    printf 'before=%s\n' "$before"
    printf 'after=%s\n' "$after"
  } > "$record" || return 1
  chmod 0600 "$record" 2>/dev/null || true
}

# Prints every breach marker path, newest-agnostic, and returns 0 when at least
# one exists.
fm_herdr_lab_breach_list() {
  local dir record found=1
  dir=$(fm_herdr_lab_state_dir)
  [ -d "$dir" ] || return 1
  set -- "$dir"/*.tripwire-breach
  [ -e "$1" ] || return 1
  for record in "$@"; do
    [ -f "$record" ] || continue
    printf '%s\n' "$record"
    found=0
  done
  return "$found"
}
