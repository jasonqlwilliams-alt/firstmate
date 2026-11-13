# shellcheck shell=bash

fm_workset_scan_due() {  # <store-directory> <workset-directory>
  local store=$1 workset=$2 checked
  checked="$workset/.legacy-checked"
  [ ! -L "$workset" ] && [ ! -L "$workset/.ready-v1" ] \
    && [ ! -L "$checked" ] || return 2
  (umask 077; mkdir -p "$workset") || return 2
  [ ! -e "$checked" ] || [ -f "$checked" ] || return 2
  if [ -f "$workset/.ready-v1" ] && [ -f "$checked" ] \
    && [ ! "$store" -nt "$checked" ]; then
    return 1
  fi
  (umask 077; touch "$checked") || return 2
  return 0
}
