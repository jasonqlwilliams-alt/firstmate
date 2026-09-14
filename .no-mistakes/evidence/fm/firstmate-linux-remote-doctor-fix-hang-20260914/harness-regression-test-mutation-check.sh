#!/usr/bin/env bash
# Runs only the two herdr tests this change touches against the fixed code and
# against deliberately broken copies of bin/backends/herdr.sh, each in a temp
# snapshot of the repo. A regression test must pass on the fix and fail on
# every break of the behavior it claims to guard.
set -u
WORKTREE=${WORKTREE:?}
HEAD_SHA=$1
BASE_SHA=$2
OUT=$3
TESTS=(test_server_ensure_releases_caller_capture_pipes test_cli_scopes_the_selected_client_to_its_session)
: > "$OUT"

variant() { # <label> <python-mutation-or-empty> [base]
  local label=$1 mutation=$2 from=${3:-head} d t rc start secs
  d=$(mktemp -d "/tmp/fm-mut-$label.XXXXXX")
  git -C "$WORKTREE" archive "$HEAD_SHA" | tar -x -C "$d"
  if [ "$from" = base ]; then
    git -C "$WORKTREE" show "$BASE_SHA:bin/backends/herdr.sh" > "$d/bin/backends/herdr.sh"
  fi
  if [ -n "$mutation" ]; then
    python3 - "$d/bin/backends/herdr.sh" "$mutation" <<'PY' || { echo "mutation did not apply: $label" >> "$OUT"; return; }
import sys
path, which = sys.argv[1], sys.argv[2]
s = open(path).read()
edits = {
  "no-fd-close": ('  [ -d /proc/self/fd ] || return 0\n', '  return 0\n'),
  "no-exec-waiting-parent": ('    HERDR_SESSION="$session" exec "$client_bin" "$@" --session "$session"\n',
                             '    HERDR_SESSION="$session" "$client_bin" "$@" --session "$session"\n    return $?\n'),
  "server-ignores-selected-client": ('    HERDR_SESSION="$session" exec "$client_bin" "$@" --session "$session"\n',
                                     '    HERDR_SESSION="$session" exec herdr "$@" --session "$session"\n'),
  "server-always-uses-other-sessions-client": ('    HERDR_SESSION="$session" exec "$client_bin" "$@" --session "$session"\n',
                                     '    HERDR_SESSION="$session" exec "$(fm_backend_herdr_bin)" "$@" --session "$session"\n'),
}
old, new = edits[which]
if s.count(old) != 1:
    sys.exit(1)
open(path, "w").write(s.replace(old, new))
PY
  fi
  printf '\n== variant: %s ==\n' "$label" >> "$OUT"
  for t in "${TESTS[@]}"; do
    { sed -n '1,5270p' "$d/tests/fm-backend-herdr.test.sh"; printf '%s\n' "$t"; } > "$d/tests/focused-$t.test.sh"
    start=$(date +%s.%N)
    bash "$d/tests/focused-$t.test.sh" > "$d/$t.log" 2>&1
    rc=$?
    secs=$(awk -v s="$start" -v n="$(date +%s.%N)" 'BEGIN{printf "%.1f", n-s}')
    printf '%s: rc=%s (%ss)\n' "$t" "$rc" "$secs" >> "$OUT"
    sed 's/^/    /' "$d/$t.log" >> "$OUT"
  done
  rm -rf "$d"
}

variant fixed-head ""
variant pre-fix-base-herdr-sh "" base
variant no-fd-close no-fd-close
variant no-exec-waiting-parent no-exec-waiting-parent
variant server-ignores-selected-client server-ignores-selected-client
variant server-always-uses-other-sessions-client server-always-uses-other-sessions-client
cat "$OUT"
