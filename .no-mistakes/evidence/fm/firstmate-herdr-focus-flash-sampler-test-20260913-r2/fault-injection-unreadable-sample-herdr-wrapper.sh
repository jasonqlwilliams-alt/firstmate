#!/usr/bin/env bash
# Fault injection for the Part C sampler only: while Part C's operation marker
# exists, make the sampler's SECOND `workspace list` read fail, so the sampler
# records one UNREADABLE sample. Production close calls are never touched.
active=
for f in "${TMPDIR:-/tmp}"/fm-herdr-focus-flash-e2e.*/operation-c.active; do
  [ -e "$f" ] && active=1
done
if [ -n "$active" ] && [ -z "${FM_FLASH_CALL_LOG:-}" ] && [ "${1:-}" = workspace ] && [ "${2:-}" = list ]; then
  n=$(( $(cat "$FM_INJECT_COUNT" 2>/dev/null || echo 0) + 1 ))
  printf '%s\n' "$n" > "$FM_INJECT_COUNT"
  if [ "$n" -eq 2 ]; then
    printf '%s sampler read #%s forced to fail: %s\n' "$(date +%T.%N | cut -c1-12)" "$n" "$*" >> "$FM_INJECT_LOG"
    exit 1
  fi
  printf '%s sampler read #%s ok\n' "$(date +%T.%N | cut -c1-12)" "$n" >> "$FM_INJECT_LOG"
fi
exec "$FM_REAL_HERDR" "$@"
