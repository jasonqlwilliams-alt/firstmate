# shellcheck shell=bash

fm_workset_scan_due() {  # <store-directory> <workset-directory>
  local store=$1 workset=$2 checked stamp
  checked="$workset/.legacy-checked"
  [ ! -L "$workset" ] && [ ! -L "$workset/.ready-v1" ] \
    && [ ! -L "$checked" ] || return 2
  (umask 077; mkdir -p "$workset") || return 2
  [ ! -e "$checked" ] || [ -f "$checked" ] || return 2
  if [ -f "$workset/.ready-v1" ] && [ -f "$checked" ] \
    && [ ! "$store" -nt "$checked" ]; then
    return 1
  fi
  # Snapshot the directory before scanning. A writer arriving during the scan
  # must still make the next check due, and an interrupted scan must not look
  # completed merely because its checkpoint was published early.
  stamp=$(umask 077; mktemp "$workset/.legacy-scan.XXXXXX") || return 2
  if ! touch -r "$store" "$stamp"; then
    rm -f -- "$stamp"
    return 2
  fi
  FM_WORKSET_SCAN_STAMP=$stamp
  return 0
}

fm_workset_scan_complete() {  # <workset-directory>
  local stamp=${FM_WORKSET_SCAN_STAMP:-}
  [ -n "$stamp" ] && [ -f "$stamp" ] || return 1
  mv -f -- "$stamp" "$1/.legacy-checked" || return 1
  FM_WORKSET_SCAN_STAMP=
}

fm_workset_scan_abort() {
  [ -z "${FM_WORKSET_SCAN_STAMP:-}" ] || rm -f -- "$FM_WORKSET_SCAN_STAMP"
  FM_WORKSET_SCAN_STAMP=
}
