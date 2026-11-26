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
# disposable home and needs no harness or credentials.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
SLEEP_BIN=$(command -v sleep) || { echo "skip: sleep not found"; exit 0; }

REAL_TMUX=$(command -v tmux)
SOCKET="fm-exact-target-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-exact-target.XXXXXX") || exit 1
SESSION=fmlab

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT

# A `tmux` shim on PATH so every bare `tmux` call reaches the private socket
# and never touches the host's real sessions.
mkdir -p "$LAB/shim" "$LAB/home/state" "$LAB/wt" "$LAB/base" "$LAB/neighbour"
worker_cwd=$(cd "$LAB/wt" && pwd -P) || fail "could not resolve the worker launch directory"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
export PATH
unset TMUX TMUX_PANE

# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-inbox-lib.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

"$REAL_TMUX" -L "$SOCKET" -f /dev/null new-session -d -s "$SESSION" -n base -c "$LAB/base" \
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

peek_lab() {
  FM_HOME="$LAB/home" FM_STATE_OVERRIDE="$LAB/home/state" "$ROOT/bin/fm-peek.sh" "$@"
}

split_pane=$(tmux split-window -d -P -F '#{pane_id}' -t "$SESSION:0" -c "$LAB/base" -- \
  sh -c "printf '%s\\n' SPLIT-PANE-MARKER; exec '$SLEEP_BIN' 600") \
  || fail "could not create the explicit split pane"
split_index=$(tmux display-message -p -t "$split_pane" '#{pane_index}')
explicit="$SESSION:0.$split_index"
wait_for_marker "$split_pane" SPLIT-PANE-MARKER
peek_lab "$explicit" 40 | grep -q SPLIT-PANE-MARKER \
  || fail "fm-peek should read the explicitly selected split pane"
fm_backend_target_exists tmux "$explicit" '' explicit \
  || fail "a live explicit split pane should pass the presence probe"
fm_backend_capture tmux "$split_index" 40 '' explicit | grep -q SPLIT-PANE-MARKER \
  || fail "the bare index must select the live split pane"
fm_backend_target_exists tmux "$split_index" '' explicit \
  || fail "the presence probe should accept the bare pane index"
if fm_backend_target_exists tmux "$SESSION:0.99" '' explicit; then
  fail "the presence probe must reject a missing split pane in a live window"
else
  [ "$?" -eq 1 ] || fail "a missing pane should report absence"
fi
pass "explicit tmux pane syntax works for capture and presence"

new_window "$SESSION" fm-mate MATE-ONE-MARKER
# shellcheck disable=SC2016 # The child shell expands its own positional parameters.
tmux new-window -d -t "$SESSION:" -n fm-mate2 -c "$LAB/neighbour" -- \
  sh -c 'printf "%s\n%s" "$1" "$2"; exec "$3" 600' sh NEIGHBOUR-TWO-MARKER '❯ visible draft' "$SLEEP_BIN" \
  || fail "could not create the neighbouring window with a draft"
wait_for_marker "=$SESSION:=fm-mate" MATE-ONE-MARKER
wait_for_marker "=$SESSION:=fm-mate2" NEIGHBOUR-TWO-MARKER

# Positive control: while the worker is open every read sees its own screen.
fm_backend_capture tmux "$SESSION:fm-mate" 40 | grep -q MATE-ONE-MARKER \
  || fail "an open worker window must capture its own screen"
fm_backend_target_exists tmux "$SESSION:fm-mate" \
  || fail "an open worker window must read as present"
[ "$(fm_backend_tmux_current_path "$SESSION:fm-mate")" = "$worker_cwd" ] \
  || fail "an open worker window must report its cwd"
mate_pane=$(tmux display-message -p -t "=$SESSION:=fm-mate" '#{pane_id}')
mate_window=$(tmux display-message -p -t "$mate_pane" '#{window_id}')
mate_index=$(tmux display-message -p -t "$mate_pane" '#{window_index}')
if ! fm_backend_target_exists tmux "$mate_pane" || ! fm_backend_target_exists tmux "$mate_window"; then
  fail "an open worker must read as present by pane and window ID"
fi
pass "open worker window reads its own screen"

"$REAL_TMUX" -L "$SOCKET" kill-window -t "=$SESSION:=fm-mate" \
  || fail "could not close the worker window"

# The masking condition: tmux itself still resolves the closed name by prefix.
"$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION:fm-mate" 2>/dev/null \
  | grep -q NEIGHBOUR-TWO-MARKER \
  || fail "precondition: a raw by-name read of the closed window must reach the prefix-named neighbour"
pass "precondition: raw tmux resolves the closed name to the surviving neighbour"

export FM_TMUX_EXPLICIT_TARGET="$SESSION:fm-mate"
out=$(fm_backend_capture tmux "$SESSION:fm-mate" 40 2>/dev/null) \
  && fail "capture of a closed worker window must fail, got: $out"
case "$out" in *NEIGHBOUR-TWO-MARKER*) fail "capture of a closed worker returned the neighbour's screen" ;; esac
pass "capture: closed worker window reads as missing, not the neighbour's screen"

for closed_target in "$SESSION:fm-mate" "$mate_pane" "$mate_window"; do
  rc=0
  fm_backend_target_exists tmux "$closed_target" || rc=$?
  [ "$rc" -eq 1 ] || fail "closed worker target $closed_target should report absence, got status $rc"
done
rc=0
fm_backend_target_exists tmux "$SESSION:$mate_index" '' explicit || rc=$?
[ "$rc" -eq 1 ] || fail "closed worker index $mate_index should report absence, got status $rc"
[ -z "$(fm_backend_tmux_current_path "$SESSION:fm-mate")" ] \
  || fail "a closed worker must not report its neighbour's cwd"
pass "liveness: closed worker window reads as missing"

state=$(fm_backend_agent_state tmux "$SESSION:fm-mate")
[ "$state" = missing ] || fail "agent state of a closed worker must be missing, got $state"
pass "agent state: closed worker window is missing"

[ "$(fm_backend_composer_state tmux "$SESSION:fm-mate2")" = pending ] \
  || fail "the surviving neighbour's visible draft must classify as pending"
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
unset FM_TMUX_EXPLICIT_TARGET

# End to end through fm-peek with a recorded task in a disposable home.
printf 'window=%s:fm-mate\n' "$SESSION" > "$LAB/home/state/mate.meta"
out=$(peek_lab mate 40 2>&1) \
  && fail "fm-peek of a closed recorded worker must fail, got: $out"
case "$out" in
  *NEIGHBOUR-TWO-MARKER*) fail "fm-peek of a closed recorded worker showed the neighbour's screen" ;;
  *"window $SESSION:fm-mate not found"*) ;;
  *) fail "fm-peek did not report the closed recorded window missing: $out" ;;
esac
pass "fm-peek: closed recorded worker reads as missing"

test_multiline_decoy() {
  local target="$SESSION:fm-multiline-worker" name window stored_name raw_inventory out
  name=$'fm-multiline-decoy\n'"$target"
  if ! window=$(tmux new-window -dP -F '#{window_id}' -t "$SESSION:" -n "$name" -c "$LAB/neighbour" -- \
    sh -c "printf '%s\n' MULTILINE-DECOY-MARKER; exec '$SLEEP_BIN' 600" 2>&1); then
    case "$window" in
      *'invalid window name:'*) printf 'skip: tmux rejects multiline window names\n'; return 0 ;;
      *) fail "could not create the multiline decoy window: $window" ;;
    esac
  fi
  stored_name=$(tmux display-message -p -t "$window" '#{window_name}') \
    || fail "could not read the decoy name by its window ID"
  if [ "$stored_name" != "$name" ]; then
    printf 'skip: tmux does not preserve literal newlines in window names\n'
    return 0
  fi
  raw_inventory=$(tmux list-windows -t "=$SESSION:" -F '#{session_name}:#{window_name}') \
    || fail "could not read the raw multiline window inventory"
  grep -Fxq -- "$target" <<< "$raw_inventory" \
    || fail "raw tmux inventory did not expose the misleading worker line"
  wait_for_marker "$window" MULTILINE-DECOY-MARKER
  printf 'window=%s\n' "$target" > "$LAB/home/state/multiline-worker.meta"
  if out=$(peek_lab multiline-worker 40 2>&1); then
    fail "fm-peek read the multiline decoy as the recorded worker: $out"
  fi
  case "$out" in
    *MULTILINE-DECOY-MARKER*) fail "fm-peek returned the decoy screen" ;;
    *"window $target not found"*) ;;
    *) fail "fm-peek did not report the recorded worker missing: $out" ;;
  esac
  pass "fm-peek leaves the worker missing beside a multiline decoy"
}
test_multiline_decoy

# The surviving neighbour is still read exactly as itself.
fm_backend_capture tmux "$SESSION:fm-mate2" 40 | grep -q NEIGHBOUR-TWO-MARKER \
  || fail "the surviving neighbour must still capture its own screen"
pass "surviving neighbour still reads its own screen"

tmux link-window -s "$SESSION:fm-mate2" -t "$SESSION:99" \
  || fail "could not link the surviving window to a second index"
fm_backend_capture tmux "$SESSION:fm-mate2" 40 | grep -q NEIGHBOUR-TWO-MARKER \
  || fail "two links to the same window must still capture its screen"
fm_backend_target_exists tmux "$SESSION:fm-mate2" \
  || fail "two links to the same live window must still prove presence"
pass "repeated links to one window resolve to that window"

new_window "$SESSION" fm-duplicate FIRST-DUPLICATE
new_window "$SESSION" fm-duplicate SECOND-DUPLICATE
[ "$(fm_backend_agent_state tmux "$SESSION:fm-duplicate")" = unreadable ] \
  || fail "two identically named windows must leave agent state unreadable"
if fm_backend_target_exists tmux "$SESSION:fm-duplicate"; then
  fail "two identically named windows must not establish presence"
else
  [ "$?" -eq 2 ] || fail "duplicate windows must report unreadable presence"
fi
pass "duplicate worker names leave the endpoint unresolved"

new_window "$SESSION" %worker2 PERCENT-NEIGHBOUR
fm_backend_capture tmux "$SESSION:%worker" 40 >/dev/null 2>&1 \
  && fail "a missing percent-prefixed window name must not capture its neighbour"
pass "a qualified percent-prefixed name reads exactly"

new_window "$SESSION" fm-café ACCENTED-WINDOW-MARKER
accented_pane=$(tmux display-message -p -t "=$SESSION:=fm-café" '#{pane_id}')
wait_for_marker "$accented_pane" ACCENTED-WINDOW-MARKER
LC_ALL=C fm_backend_capture tmux "$SESSION:fm-café" 40 | grep -q ACCENTED-WINDOW-MARKER \
  || fail "an accented window name must remain readable from a C locale"
LC_ALL=C fm_backend_target_exists tmux "$SESSION:fm-caf_" \
  && fail "an accented window name must not establish presence under its ASCII replacement"
"$REAL_TMUX" -L "$SOCKET" new-session -d -s équipe -n fm-mate -c "$LAB/wt" \
  || fail "could not create the accented session"
LC_ALL=C fm_backend_target_exists tmux 'équipe:fm-mate' \
  || fail "an accented session name must remain readable from a C locale"
pass "inventory preserves non-ASCII names from a C locale"

literal_name='fm-#[bold],#{window_id}'
new_window "$SESSION" 'fm-#{a:35}[bold],#{a:35}{window_id}' LITERAL-WINDOW-MARKER
wait_for_marker "=$SESSION:=$literal_name" LITERAL-WINDOW-MARKER
fm_backend_capture tmux "$SESSION:$literal_name" 40 | grep -q LITERAL-WINDOW-MARKER \
  || fail "tmux format punctuation in a window name must remain literal"
pass "inventory matches format punctuation in window names literally"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s 'semicolon\;' -n fm-mate -c "$LAB/wt" -- \
  sh -c "printf '%s\n' SEMICOLON-SESSION-MARKER; exec '$SLEEP_BIN' 600" \
  || fail "could not create a session with a terminal semicolon"
wait_for_marker '=semicolon;:=fm-mate' SEMICOLON-SESSION-MARKER
fm_backend_capture tmux 'semicolon;:fm-mate' 40 | grep -q SEMICOLON-SESSION-MARKER \
  || fail "a recorded session with a terminal semicolon must remain readable"
pass "inventory reads a session with a terminal semicolon"

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

new_draft_window() {  # <name> <marker> -> prints window ID
  tmux new-window -dP -F '#{window_id}' -t fmla: -n "$1" -c "$LAB/wt" -- \
    awk -v marker="$2" '
      BEGIN { print marker; printf "❯ "; fflush() }
      { print "SUBMITTED " $0; printf "❯ "; fflush() }
    '
}

dotted_target=fmla:fm-dot.0
dotted_window=$(new_draft_window fm-dot.0 DOTTED-MARKER) || fail "could not create the dotted worker"
draft_window=$(new_draft_window fm-dot DRAFT-MARKER) || fail "could not create the worker with a draft"
wait_for_marker "$dotted_window" DOTTED-MARKER
wait_for_marker "$draft_window" DRAFT-MARKER
tmux send-keys -t "$draft_window" -l 'neighbour draft' || fail "could not type the neighbouring draft"
wait_for_marker "$draft_window" 'neighbour draft'
tmux capture-pane -p -t "$dotted_target" | grep -Fq 'neighbour draft' \
  || fail "precondition: a raw dotted target must select the neighbour's pane zero"
fm_backend_capture tmux "$dotted_target" 40 | grep -Fq DOTTED-MARKER \
  || fail "a recorded dotted target must capture its own screen"
[ "$(fm_backend_composer_state tmux "$dotted_target")" = empty ] \
  || fail "the dotted worker's composer must start empty"
[ "$(fm_backend_composer_state tmux fmla:fm-dot)" = pending ] \
  || fail "the neighbouring worker must have a pending draft"
draft_before=$(tmux capture-pane -p -t "$draft_window") || fail "could not capture the pending draft"

steer_record=$(fm_task_inbox_write "$LAB/home/state" dot.0 'dotted worker steer') \
  || fail "could not write the dotted worker's steer"
fm_task_inbox_ring tmux "$dotted_target" "$steer_record" fm-dot.0 pi \
  || fail "could not ring the dotted worker's inbox"
wait_for_marker "$dotted_window" 'SUBMITTED : Firstmate instruction waiting:'
[ "$(tmux capture-pane -p -t "$draft_window")" = "$draft_before" ] \
  || fail "the inbox ring changed the neighbouring draft"
pass "dotted worker receives and submits its doorbell without changing the neighbouring draft"

fm_backend_tmux_send_text_line "$dotted_target" LINE-REGRESSION || fail "could not send a line to the dotted worker"
wait_for_marker "$dotted_window" 'SUBMITTED LINE-REGRESSION'
[ "$(fm_backend_send_text_submit tmux "$dotted_target" TYPED-REGRESSION 1 0.05 0.05)" = empty ] \
  || fail "verified submit did not confirm delivery to the dotted worker"
wait_for_marker "$dotted_window" 'SUBMITTED TYPED-REGRESSION'
[ "$(tmux capture-pane -p -t "$draft_window")" = "$draft_before" ] \
  || fail "line or verified submit changed the neighbouring draft"
pass "dotted worker receives line and verified submit input without changing the neighbouring draft"

tmux new-session -d -s firstmate-lab -n fm-detached -c "$LAB/neighbour" \
  || fail "could not create the prefix-named session"
detached_session=$(fm_backend_tmux_container_ensure) || fail "could not ensure the detached session"
[ "$detached_session" = firstmate ] || fail "unexpected detached session $detached_session"
detached_window=$(fm_backend_tmux_create_task "$detached_session" fm-detached "$worker_cwd") \
  || fail "a matching window in the prefix-named session must not block creation"
[ "$(tmux display-message -p -t "$detached_window" '#{session_name}')" = firstmate ] \
  || fail "the detached worker must belong to the literal firstmate session"
[ "$(fm_backend_tmux_container_ensure)" = firstmate ] \
  || fail "the literal firstmate session should be reusable"
pass "detached spawn creates and reuses the literal firstmate session"
