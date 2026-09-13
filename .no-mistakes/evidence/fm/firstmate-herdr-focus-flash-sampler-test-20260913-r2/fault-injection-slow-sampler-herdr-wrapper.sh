#!/usr/bin/env bash
# Fault injection for the Part C sampler only: while Part C's operation marker
# exists, delay the sampler's `workspace list` read by FM_INJECT_DELAY seconds.
# Production close calls (which carry FM_FLASH_CALL_LOG) are never delayed.
active=
for f in "${TMPDIR:-/tmp}"/fm-herdr-focus-flash-e2e.*/operation-c.active; do
  [ -e "$f" ] && active=1
done
kind=test
[ -n "${FM_FLASH_CALL_LOG:-}" ] && kind=production
if [ -n "$active" ] && [ "$kind" = test ] && [ "${1:-}" = workspace ] && [ "${2:-}" = list ]; then
  printf '%s delayed %ss: %s\n' "$(date +%T.%N | cut -c1-12)" "$FM_INJECT_DELAY" "$*" >> "$FM_INJECT_LOG"
  sleep "$FM_INJECT_DELAY"
elif [ -n "$active" ]; then
  printf '%s %s call: %s\n' "$(date +%T.%N | cut -c1-12)" "$kind" "$*" >> "$FM_INJECT_LOG"
fi
exec "$FM_REAL_HERDR" "$@"
