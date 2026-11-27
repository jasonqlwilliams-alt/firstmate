#!/usr/bin/env bash
# tests/fm-tmux-exact-target.test.sh - verify recorded pane targeting for
# capture, presence, input, and spawn. Raw tmux targets can select a prefix
# neighbour, parse a dotted window name as a pane, or treat a session name
# as an ID. A saved binding must also reject removed links and recycled IDs.
#
# This suite uses a private tmux socket and disposable home with no harness
# or credentials.
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
. "$ROOT/bin/fm-backend.sh"
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
  FM_HOME="$LAB/home" FM_ROOT_OVERRIDE="$LAB/home" FM_STATE_OVERRIDE="$LAB/home/state" "$ROOT/bin/fm-peek.sh" "$@"
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

# A window name carrying a dot is read exactly rather than parsed as a pane.
new_window fmla fm-dot.0 DOTTED-MARKER
new_window fmla fm-dot DECOY-MARKER
dotted_inventory=$(tmux list-windows -t fmla -F '#{window_name} #{window_id}') \
  || fail "could not list the dotted worker and its decoy"
dotted_window=$(awk '$1 == "fm-dot.0" {print $2}' <<< "$dotted_inventory")
decoy_window=$(awk '$1 == "fm-dot" {print $2}' <<< "$dotted_inventory")
[ -n "$dotted_window" ] && [ -n "$decoy_window" ] && [ "$dotted_window" != "$decoy_window" ] \
  || fail "could not identify two distinct windows for the dotted target"
wait_for_marker "$dotted_window" DOTTED-MARKER
wait_for_marker "$decoy_window" DECOY-MARKER
tmux capture-pane -p -t fmla:fm-dot.0 | grep -Fq DECOY-MARKER \
  || fail "precondition: native tmux capture must select the undotted decoy"
fm_backend_capture tmux fmla:fm-dot.0 40 | grep -Fq DOTTED-MARKER \
  || fail "a dotted worker window name must capture its own screen"
pass "dotted window name reads exactly beside a live decoy"

# Real input consumers make a wrong send observable, independently of the
# adapter's return status or capture targeting.
# shellcheck disable=SC2016 # The pane shell expands its own marker and input.
input_loop='stty -echo || exit 1; printf "%s\n" "$1"; while IFS= read -r line; do printf "received: %s\n" "$line"; done'
input_window() {  # <session-id> <name> <marker>
  tmux new-window -dP -F '#{pane_id}' -t "$1:" -n "$2" -c "$LAB/wt" -- \
    sh -c "$input_loop" sh "$3"
}
fmla_id=$(tmux display-message -p -t fmla: '#{session_id}')
input_pane=$(input_window "$fmla_id" fm-input.0 INPUT-WORKER) || fail "could not create dotted input window"
input_decoy=$(input_window "$fmla_id" fm-input INPUT-DECOY) || fail "could not create decoy input window"
wait_for_marker "$input_pane" INPUT-WORKER
wait_for_marker "$input_decoy" INPUT-DECOY
tmux send-keys -t fmla:fm-input.0 precondition Enter || fail "raw key send failed"
wait_for_marker "$input_decoy" 'received: precondition'
fm_backend_send_literal tmux fmla:fm-input.0 'literal-write' || fail "literal send to dotted worker failed"
fm_backend_send_key tmux fmla:fm-input.0 Enter || fail "key send to dotted worker failed"
wait_for_marker "$input_pane" 'received: literal-write'
tmux capture-pane -p -t "$input_decoy" | grep -q 'literal-write' \
  && fail "the pane-0 decoy received the dotted worker's input"
pass "literal text and Enter reach the exact dotted worker"

first_line="-- # literal \"' \$(unexpanded) \\ ;"
second_line='   # indented line'
payload="$first_line"$'\n'"$second_line"
if ! fm_backend_send_literal tmux fmla:fm-input.0 "$payload" ||
   ! fm_backend_send_key tmux fmla:fm-input.0 Enter; then
  fail "could not send literal tmux punctuation"
fi
wait_for_marker "$input_pane" 'received: -- # literal'
wait_for_marker "$input_pane" 'received:    # indented line'
screen=$(tmux capture-pane -p -t "$input_pane")
grep -Fxq -- "received: $first_line" <<< "$screen" &&
  grep -Fxq -- "received: $second_line" <<< "$screen" \
  || fail "the nested tmux command changed the literal payload: $screen"
pass "tmux preserves punctuation and indentation in multiline input"

printf 'window=fmla:fm-input.0\n' > "$LAB/home/state/input.meta"
fm_backend_send_literal tmux fmla:fm-input.0 'recorded-key' || fail "could not prepare the recorded key fixture"
FM_GATE_REFUSE_BYPASS=1 FM_HOME="$LAB/home" FM_ROOT_OVERRIDE="$LAB/home" FM_STATE_OVERRIDE="$LAB/home/state" \
  "$ROOT/bin/fm-send.sh" input --key Enter || fail "fm-send rejected the recorded key target"
wait_for_marker "$input_pane" 'received: recorded-key'
pass "fm-send uses the recorded dotted name for named keys"

original_pane=$(fm_tmux_exact_target fmla:fm-input.0) || fail "could not bind the original active pane"
second_pane=$(tmux split-window -dP -F '#{pane_id}' -t "$input_pane" -- \
  sh -c "printf '%s\n' SECOND-PANE; exec '$SLEEP_BIN' 600") || fail "could not create a split pane"
tmux select-pane -t "$second_pane" || fail "could not change the active pane"
if ! fm_backend_send_literal tmux "$original_pane" 'binding-kept' ||
   ! fm_backend_send_key tmux "$original_pane" Enter; then
  fail "the original pane binding did not deliver"
fi
wait_for_marker "$input_pane" 'received: binding-kept'
tmux capture-pane -p -t "$second_pane" | grep -q 'binding-kept' && fail "the active split pane received the original pane's input"
tmux select-pane -t "$input_pane" || fail "could not restore the active pane"
pass "changing the active pane cannot retarget an existing binding"

input_window_id=$(tmux display-message -p -t "$input_pane" '#{window_id}')
tmux move-window -s "$fmla_id:$input_window_id" -t "$fmla_id:87" \
  || fail "could not change the bound window's index"
fm_backend_send_literal tmux "$original_pane" 'window-index-changed' &&
  fm_backend_send_key tmux "$original_pane" Enter || fail "window renumbering invalidated the binding"
wait_for_marker "$input_pane" 'received: window-index-changed'
pane_index=$(tmux display-message -p -t "$input_pane" '#{pane_index}')
tmux set-window-option -t "$input_pane" pane-base-index 7 || fail "could not change the pane base index"
[ "$(tmux display-message -p -t "$input_pane" '#{pane_index}')" != "$pane_index" ] \
  || fail "precondition: the bound pane index must change"
fm_backend_send_literal tmux "$original_pane" 'pane-index-changed' &&
  fm_backend_send_key tmux "$original_pane" Enter || fail "pane renumbering invalidated the binding"
wait_for_marker "$input_pane" 'received: pane-index-changed'
pass "a pane binding survives changes to window and pane indices"

prefix_pane=$(input_window "$fmla_id" fm-prefix2 INPUT-PREFIX-NEIGHBOUR) || fail "could not create prefix neighbour"
wait_for_marker "$prefix_pane" INPUT-PREFIX-NEIGHBOUR
fm_backend_send_literal tmux fmla:fm-prefix 'missing-worker-write' >/dev/null 2>&1 \
  && fail "literal text send accepted a missing worker beside a prefix neighbour"
tmux capture-pane -p -t "$prefix_pane" | grep -q 'missing-worker-write' \
  && fail "the neighbour received input for a missing worker"
pass "a missing worker receives no input through its prefix neighbour"

shadow_name=$fmla_id
shadow_id=$(tmux new-session -dP -F '#{session_id}' -s "$shadow_name" -n base -c "$LAB/base") \
  || fail "could not create a session literally named $shadow_name"
shadow_pane=$(input_window "$shadow_id" fm-session-id INPUT-LITERAL-SESSION) || fail "could not create literal-session worker"
id_decoy=$(input_window "$fmla_id" fm-session-id INPUT-ID-DECOY) || fail "could not create ID-session decoy"
wait_for_marker "$shadow_pane" INPUT-LITERAL-SESSION
wait_for_marker "$id_decoy" INPUT-ID-DECOY
tmux capture-pane -p -t "$shadow_name:fm-session-id" | grep -q INPUT-ID-DECOY \
  || fail "precondition: native tmux must interpret the literal session name as an ID"
fm_backend_capture tmux "$shadow_name:fm-session-id" 40 | grep -q INPUT-LITERAL-SESSION \
  || fail "the recorded session name must win over the matching session ID"
if ! fm_backend_send_literal tmux "$shadow_name:fm-session-id" 'session-write' ||
   ! fm_backend_send_key tmux "$shadow_name:fm-session-id" Enter; then
  fail "could not send to literal session name"
fi
wait_for_marker "$shadow_pane" 'received: session-write'
session_binding=$(fm_tmux_exact_session "$shadow_name") || fail "could not bind the literal session"
created=$(fm_backend_tmux_create_task "$shadow_name" fm-placement "$worker_cwd" "$session_binding") \
  || fail "could not create a worker in the ID-shaped session name"
[ "$(tmux list-windows -t "$shadow_id:" -f '#{==:#{window_name},fm-placement}' -F '#{session_id}')" = "$shadow_id" ] \
  || fail "spawn placed $created outside the literal session"
tmux set-environment -t "$fmla_id" META_API_KEY decoy
tmux set-environment -t "$shadow_id" META_API_KEY destination
[ "$(fm_tmux_session_command "$session_binding" show-environment '' META_API_KEY)" = 'META_API_KEY=destination' ] \
  || fail "the environment lookup must read the literal session, not the session ID it resembles"
fm_backend_kill tmux "$shadow_name:fm-session-id" || fail "could not close the recorded literal-session worker"
if tmux display-message -p -t "$shadow_id:fm-session-id" '#{pane_id}' | grep -Fxq "$shadow_pane"; then
  fail "recorded cleanup left the worker in the literal session running"
fi
wait_for_marker "$id_decoy" INPUT-ID-DECOY
pass "reads, writes, spawn, and cleanup honor literal ID-shaped session names"

linked_index=$(tmux display-message -p -t "$input_pane" '#{window_index}')
tmux link-window -s "$fmla_id:$linked_index" -t "$shadow_id:99" || fail "could not link worker into another session"
linked_binding=$(fm_tmux_exact_target fmla:fm-input.0) || fail "could not bind the recorded linked pane"
fm_backend_target_exists tmux "$linked_binding" || fail "linked pane should be present before unlink"
tmux unlink-window -t "$fmla_id:$linked_index" || fail "could not unlink worker from its recorded session"
wait_for_marker "$input_pane" INPUT-WORKER
fm_backend_target_exists tmux "$linked_binding" && fail "the old link still proved presence"
fm_backend_capture tmux "$linked_binding" 40 2>/dev/null && fail "the old link still returned a screen"
fm_backend_send_literal tmux "$linked_binding" 'unlinked-write' 2>/dev/null && fail "the old link still accepted text"
fm_backend_send_key tmux "$linked_binding" Enter 2>/dev/null && fail "the old link still accepted Enter"
fm_backend_kill tmux "$linked_binding" || fail "stale link cleanup must remain best-effort"
wait_for_marker "$input_pane" INPUT-WORKER
tmux capture-pane -p -t "$input_pane" | grep -q 'unlinked-write' \
  && fail "the surviving link received the removed link's text"
pass "a bound worker becomes unavailable when its recorded session link is removed"

tmux new-session -d -s firstmate-lab -n fm-detached -c "$LAB/neighbour" \
  || fail "could not create the prefix-named session"
detached_name=$(fm_backend_tmux_launch_session) || fail "could not resolve the detached session name"
[ "$detached_name" = firstmate ] || fail "unexpected detached session $detached_name"
fm_backend_tmux_container_ensure 'other-detached;' && fail "detached spawn created an arbitrary session"
detached_session=$(fm_backend_tmux_container_ensure "$detached_name") || fail "could not ensure the detached session"
detached_window=$(fm_backend_tmux_create_task "$detached_name" fm-detached "$worker_cwd" "$detached_session") \
  || fail "a matching window in the prefix-named session must not block creation"
[ "$(fm_tmux_pane_command "$detached_window" display-message -p '#{session_name}')" = firstmate ] \
  || fail "the detached worker must belong to the literal firstmate session"
[ "$(fm_backend_tmux_container_ensure "$detached_name")" = "$detached_session" ] \
  || fail "the literal firstmate session should be reusable"
fm_backend_kill tmux "$detached_window" \
  || fail "bound spawn cleanup failed"
fm_backend_target_exists tmux "$detached_name:fm-detached" \
  && fail "bound spawn cleanup did not close its own window"
fm_backend_target_exists tmux firstmate-lab:fm-detached \
  || fail "bound spawn cleanup closed the neighboring window"
pass "detached spawn creates and reuses the literal firstmate session"

# Restart the private server twice so both its old and replacement windows
# have the same names, indices and pane/window IDs.
restart_server() {  # <marker>
  local attempt=0
  tmux kill-server || fail "could not stop the private tmux server"
  while tmux list-sessions >/dev/null 2>&1; do
    [ "$attempt" -lt 100 ] || fail "the old private server did not stop"
    sleep 0.05
    attempt=$((attempt + 1))
  done
  tmux -f /dev/null new-session -d -s reuse -n fm-reuse -c "$LAB/wt" -- \
    sh -c "$input_loop" sh "$1" \
    || fail "could not start the replacement private tmux server"
  wait_for_marker reuse:fm-reuse "$1"
}
restart_server BEFORE-RESTART
before=$(fm_tmux_exact_target reuse:fm-reuse) || fail "could not bind the original server's pane"
before_session=$(fm_tmux_exact_session reuse) || fail "could not bind the original server's session"
restart_server AFTER-RESTART
after=$(fm_tmux_exact_target reuse:fm-reuse) || fail "could not bind the replacement server's pane"
[ "$before" != "$after" ] && [ "${before#*:*:*:}" = "${after#*:*:*:}" ] \
  || fail "precondition: the replacement server must reuse the window and pane identities"
fm_backend_target_exists tmux "$before" && fail "a binding from the stopped server still proved presence"
fm_backend_send_literal tmux "$before" 'stale-server-write' 2>/dev/null \
  && fail "a binding from the stopped server still accepted text"
fm_backend_send_key tmux "$before" Enter 2>/dev/null \
  && fail "a binding from the stopped server still accepted Enter"
fm_backend_tmux_create_task reuse fm-stale-placement "$worker_cwd" "$before_session" 2>/dev/null \
  && fail "a stopped server's session binding permitted new placement on its replacement"
fm_backend_kill tmux "$before" || fail "stale spawn cleanup must remain best-effort"
wait_for_marker reuse:fm-reuse AFTER-RESTART
if ! fm_backend_send_literal tmux "$after" replacement-write ||
   ! fm_backend_send_key tmux "$after" Enter; then
  fail "the fresh binding could not write to the replacement server"
fi
wait_for_marker reuse:fm-reuse 'received: replacement-write'
tmux capture-pane -p -t reuse:fm-reuse | grep -q 'stale-server-write' \
  && fail "the replacement server received the stopped server's text"
pass "a restarted tmux server cannot inherit a stale pane binding"
