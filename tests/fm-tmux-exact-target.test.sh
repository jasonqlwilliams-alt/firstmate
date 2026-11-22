#!/usr/bin/env bash
# tests/fm-tmux-exact-target.test.sh - portable regression for exact window
# targeting on tmux reads of a recorded worker window (bin/fm-tmux-lib.sh
# fm_tmux_exact_target, used by bin/backends/tmux.sh).
#
# The defect: tmux resolves a session or window name that is not an exact match
# by prefix, so after a worker window `fm-mate` closed while `fm-mate2` still
# existed, reads of the closed worker returned the neighbour's screen and the
# closed worker looked alive. Every case first proves the masking condition is
# present (a raw by-name read still lands on the neighbour), so the assertions
# cannot pass vacuously.
#
# It runs REAL processes in a REAL tmux server on a private socket (`-L`) in a
# disposable home, needs no harness or credentials, and sends no keys.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
SLEEP_BIN=$(command -v sleep) || { echo "skip: sleep not found"; exit 0; }

REAL_TMUX=$(command -v tmux)
SOCKET="fm-exact-target-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-exact-target.XXXXXX")
SESSION=fmlab

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT

# A `tmux` shim on PATH so every bare `tmux` call reaches the private socket
# and never touches the host's real sessions.
mkdir -p "$LAB/shim" "$LAB/home/state" "$LAB/wt"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
export PATH
unset TMUX TMUX_PANE

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n base -c "$LAB/wt" \
  || fail "could not start the private tmux server"

# Each window prints a marker then idles, run directly as the window command so
# no case depends on interactive shell readiness.
new_window() {  # <session> <name> <marker>
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$1:" -n "$2" -c "$LAB/wt" -- \
    sh -c "printf '%s\\n' '$3'; exec '$SLEEP_BIN' 600" \
    || fail "could not create window $1:$2"
}

wait_for_marker() {  # <raw-target> <marker>
  local i=0
  while [ "$i" -lt 100 ]; do
    "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$1" 2>/dev/null | grep -q "$2" && return 0
    sleep 0.05
    i=$((i + 1))
  done
  fail "window $1 never showed $2"
}

new_window "$SESSION" fm-mate MATE-ONE-MARKER
new_window "$SESSION" fm-mate2 NEIGHBOUR-TWO-MARKER
wait_for_marker "=$SESSION:=fm-mate" MATE-ONE-MARKER
wait_for_marker "=$SESSION:=fm-mate2" NEIGHBOUR-TWO-MARKER

# Positive control: while the worker is open every read sees its own screen.
fm_backend_capture tmux "$SESSION:fm-mate" 40 | grep -q MATE-ONE-MARKER \
  || fail "an open worker window must capture its own screen"
fm_backend_target_exists tmux "$SESSION:fm-mate" \
  || fail "an open worker window must read as present"
pass "open worker window reads its own screen"

"$REAL_TMUX" -L "$SOCKET" kill-window -t "=$SESSION:=fm-mate" \
  || fail "could not close the worker window"

# The masking condition: tmux itself still resolves the closed name by prefix.
"$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION:fm-mate" 2>/dev/null \
  | grep -q NEIGHBOUR-TWO-MARKER \
  || fail "precondition: a raw by-name read of the closed window must reach the prefix-named neighbour"
pass "precondition: raw tmux resolves the closed name to the surviving neighbour"

out=$(fm_backend_capture tmux "$SESSION:fm-mate" 40 2>/dev/null) \
  && fail "capture of a closed worker window must fail, got: $out"
case "$out" in *NEIGHBOUR-TWO-MARKER*) fail "capture of a closed worker returned the neighbour's screen" ;; esac
pass "capture: closed worker window reads as missing, not the neighbour's screen"

fm_backend_target_exists tmux "$SESSION:fm-mate" \
  && fail "a closed worker window must not read as present"
pass "liveness: closed worker window reads as missing"

state=$(fm_backend_agent_state tmux "$SESSION:fm-mate")
[ "$state" = missing ] || fail "agent state of a closed worker must be missing, got $state"
pass "agent state: closed worker window is missing"

fm_backend_composer_snapshot tmux "$SESSION:fm-mate" \
  && fail "composer snapshot of a closed worker window must fail"
[ "$(fm_backend_composer_state tmux "$SESSION:fm-mate")" = unknown ] \
  || fail "composer state of a closed worker window must be unknown"
[ "$(fm_pane_busy_state "$SESSION:fm-mate")" = unknown ] \
  || fail "busy read of a closed worker window must be unknown"
[ -z "$(fm_backend_tmux_current_command "$SESSION:fm-mate")" ] \
  || fail "current command of a closed worker window must be empty"
[ -z "$(fm_backend_tmux_foreground_comms "$SESSION:fm-mate")" ] \
  || fail "foreground process read of a closed worker window must be empty"
pass "composer, busy, and process reads: closed worker window reads nothing"

# End to end through fm-peek with a recorded task in a disposable home.
printf 'window=%s:fm-mate\n' "$SESSION" > "$LAB/home/state/mate.meta"
out=$(FM_HOME="$LAB/home" "$ROOT/bin/fm-peek.sh" mate 40 2>&1) \
  && fail "fm-peek of a closed recorded worker must fail, got: $out"
case "$out" in *NEIGHBOUR-TWO-MARKER*) fail "fm-peek of a closed recorded worker showed the neighbour's screen" ;; esac
pass "fm-peek: closed recorded worker reads as missing"

# The surviving neighbour is still read exactly as itself.
fm_backend_capture tmux "$SESSION:fm-mate2" 40 | grep -q NEIGHBOUR-TWO-MARKER \
  || fail "the surviving neighbour must still capture its own screen"
pass "surviving neighbour still reads its own screen"

# Session names are matched exactly too: a closed recorded session must not
# resolve to a prefix-named surviving session.
"$REAL_TMUX" -L "$SOCKET" new-session -d -s "${SESSION}2" -n fm-mate -c "$LAB/wt" -- \
  sh -c "printf '%s\\n' OTHER-SESSION-MARKER; exec '$SLEEP_BIN' 600" \
  || fail "could not create the prefix-named session"
"$REAL_TMUX" -L "$SOCKET" new-session -d -s fmla -n fm-solo -c "$LAB/wt" \
  || fail "could not create the short session"
wait_for_marker "=${SESSION}2:=fm-mate" OTHER-SESSION-MARKER
"$REAL_TMUX" -L "$SOCKET" kill-session -t "=$SESSION" || fail "could not close the recorded session"
"$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION:fm-mate" 2>/dev/null \
  | grep -q OTHER-SESSION-MARKER \
  || fail "precondition: a raw by-name read of the closed session must reach the prefix-named session"
fm_backend_capture tmux "$SESSION:fm-mate" 40 >/dev/null 2>&1 \
  && fail "capture in a closed recorded session must fail"
[ "$(fm_backend_agent_state tmux "$SESSION:fm-mate")" = missing ] \
  || fail "agent state in a closed recorded session must be missing"
pass "closed recorded session reads as missing despite a prefix-named session"

# A window name carrying a dot is read exactly rather than parsed as a pane.
new_window fmla fm-dot.task DOTTED-MARKER
i=0
until fm_backend_capture tmux "fmla:fm-dot.task" 40 2>/dev/null | grep -q DOTTED-MARKER; do
  i=$((i + 1))
  [ "$i" -lt 100 ] || fail "a dotted worker window name must capture its own screen"
  sleep 0.05
done
pass "dotted window name reads exactly"
