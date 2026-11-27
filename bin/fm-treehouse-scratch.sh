#!/usr/bin/env bash
# fm-treehouse-scratch.sh - disposable Treehouse roots for tests and
# reproductions, so they never create pool folders under the real root.
#
# Usage:
#   fm-treehouse-scratch.sh run [--] <command> [args...]
#   fm-treehouse-scratch.sh --help
#
# Treehouse places every pool it creates under its root, which TREEHOUSE_ROOT
# overrides (only an explicit --root outranks it). A fixture repository or a
# reproduction that runs `treehouse get`, `status`, `return`, or `lease`
# against the default root leaves a pool folder there that nothing ever
# removes. `run` executes <command> with TREEHOUSE_ROOT pointed at a fresh
# private directory under ${TMPDIR:-/tmp}, then removes that directory and
# exits with the command's status. A caller already running under a scratch
# root this helper created keeps it, so nested use shares one root and only
# its creator removes it.
#
# The root reaches only processes started under it. A reproduction that types
# commands into a terminal server started elsewhere must start that server
# under `run` too, or pass TREEHOUSE_ROOT to it explicitly. Removing the root
# removes every pool slot inside it; a linked worktree's administrative entry in
# the backing repository is left for `git worktree prune`, which this helper
# never runs, because the backing repository may not be disposable.
#
# Sourcing this file defines the functions below and changes nothing.
# bin/fm-test-run.sh gives every suite it runs its own scratch root, and
# tests/lib.sh and tests/herdr-test-safety.sh enter one for a suite run on its
# own. A directory is treated as a scratch root only when it carries the marker
# file this helper writes, so removal can never reach the real root or any
# directory a caller merely named.

FM_TREEHOUSE_SCRATCH_MARKER=.fm-treehouse-scratch

# Create a scratch root under <parent> (default ${TMPDIR:-/tmp}) and print its
# physical path.
fm_treehouse_scratch_create() {  # [<parent>]
  local parent=${1:-${TMPDIR:-/tmp}} root
  parent=${parent%/}
  [ -n "$parent" ] || parent=/
  root=$(umask 077; mktemp -d "$parent/fm-treehouse-root.XXXXXX") || return 1
  root=$(CDPATH='' cd -P -- "$root" && pwd -P) || return 1
  printf 'fm-treehouse-scratch-v1\n' > "$root/$FM_TREEHOUSE_SCRATCH_MARKER" || {
    rm -rf -- "$root"
    return 1
  }
  printf '%s\n' "$root"
}

# True when <path> is a directory this helper created.
fm_treehouse_scratch_owned() {  # <path>
  local root=${1-}
  [ -n "$root" ] && [ -d "$root" ] && [ ! -L "$root" ] || return 1
  [ -f "$root/$FM_TREEHOUSE_SCRATCH_MARKER" ] && [ ! -L "$root/$FM_TREEHOUSE_SCRATCH_MARKER" ]
}

# True when this process already runs under a scratch root: TREEHOUSE_ROOT is
# the one recorded in FM_TREEHOUSE_SCRATCH_ROOT and that directory is owned.
fm_treehouse_scratch_active() {
  [ -n "${TREEHOUSE_ROOT:-}" ] && [ "${TREEHOUSE_ROOT:-}" = "${FM_TREEHOUSE_SCRATCH_ROOT:-}" ] \
    && fm_treehouse_scratch_owned "$TREEHOUSE_ROOT"
}

# Make sure this shell and its children use a scratch root. An active one is
# kept; anything else, including an inherited real TREEHOUSE_ROOT, is replaced.
# Sets FM_TREEHOUSE_SCRATCH_CREATED to the root this call created, or to empty
# when it kept an active one; the creator owns removal.
fm_treehouse_scratch_enter() {  # [<parent>]
  local root
  FM_TREEHOUSE_SCRATCH_CREATED=
  fm_treehouse_scratch_active && return 0
  root=$(fm_treehouse_scratch_create "$@") || return 1
  TREEHOUSE_ROOT=$root
  FM_TREEHOUSE_SCRATCH_ROOT=$root
  export TREEHOUSE_ROOT FM_TREEHOUSE_SCRATCH_ROOT
  FM_TREEHOUSE_SCRATCH_CREATED=$root
}

# Remove a scratch root. Refuses anything not carrying the marker.
fm_treehouse_scratch_remove() {  # <path>
  local root=${1-}
  [ -n "$root" ] || return 0
  [ -e "$root" ] || [ -L "$root" ] || return 0
  fm_treehouse_scratch_owned "$root" || {
    printf 'fm-treehouse-scratch: refusing to remove %s: not a scratch root\n' "$root" >&2
    return 1
  }
  # Worktree checkouts can carry read-only files; make them removable first.
  chmod -R u+w -- "$root" 2>/dev/null || true
  rm -rf -- "$root"
}

fm_treehouse_scratch_usage() {
  cat <<'EOF'
Usage:
  fm-treehouse-scratch.sh run [--] <command> [args...]
                                  run <command> with TREEHOUSE_ROOT set to a
                                  fresh disposable directory, then remove it
  fm-treehouse-scratch.sh --help  print this help
EOF
}

fm_treehouse_scratch_main() {
  local rc created
  case "${1:-}" in
    -h|--help) fm_treehouse_scratch_usage; return 0 ;;
    run) shift ;;
    *) fm_treehouse_scratch_usage >&2; return 2 ;;
  esac
  [ "${1:-}" != -- ] || shift
  [ "$#" -gt 0 ] || { fm_treehouse_scratch_usage >&2; return 2; }
  fm_treehouse_scratch_enter "${TMPDIR:-/tmp}" || {
    echo 'fm-treehouse-scratch: could not create a scratch Treehouse root' >&2
    return 1
  }
  created=$FM_TREEHOUSE_SCRATCH_CREATED
  if [ -n "$created" ]; then
    # shellcheck disable=SC2064 # bind this run's root now.
    trap "fm_treehouse_scratch_remove $(printf '%q' "$created"); exit 129" HUP
    # shellcheck disable=SC2064
    trap "fm_treehouse_scratch_remove $(printf '%q' "$created"); exit 130" INT
    # shellcheck disable=SC2064
    trap "fm_treehouse_scratch_remove $(printf '%q' "$created"); exit 143" TERM
  fi
  rc=0
  "$@" || rc=$?
  trap - HUP INT TERM
  if [ -n "$created" ]; then
    fm_treehouse_scratch_remove "$created" || [ "$rc" -ne 0 ] || rc=1
  fi
  return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  fm_treehouse_scratch_main "$@"
  exit $?
fi
