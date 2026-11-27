#!/usr/bin/env bash
# tests/fm-agy-composer-live-e2e.test.sh - the live agy composer guard
# (live-harness-optin family).
#
# agy's composer rule (bin/fm-composer-lib.sh "AGY COMPOSER") is built from
# vendor-rendered rows, so per .agents/skills/firstmate-coding-guidelines it
# must be proven against the REAL Antigravity CLI. This guard launches one
# bare agy in an isolated tmux server and, through the same guarded composer
# read the steering doorbell uses (fm_backend_guarded_composer_state with the
# recorded harness agy), requires:
#   - the idle composer to read `empty`;
#   - a notice too long for the one composer row to be refused by the fit
#     check (`unknown`), so the doorbell never types it;
#   - a short typed draft to read `pending` holding exactly that text;
#   - a draft long enough to wrap the composer row never to read `empty`, and
#     never to prove an exact text it does not hold, so the doorbell withholds
#     its Enter.
# It fails naming the agy version. Nothing is ever submitted to the model.
#
# Isolation, because agy writes into its home and dials out:
#   - agy runs with HOME (and every XDG base) pointed at a private copy holding
#     only its settings (trust narrowed to one scratch workspace, so no trust
#     dialog), installation id, onboarding records, and sign-in token; the
#     copy is deleted on exit
#     and the real home is never written;
#   - agy runs in its own network namespace with only loopback up, so it has no
#     network egress; the guard refuses to launch agy unless the namespace
#     proves that before exec;
#   - no keystroke reaches a screen this guard has not positively identified as
#     the agy composer: typing needs an `empty` verdict, and every erase or
#     Enter needs the framed composer row proven to hold the guard's own text;
#   - agy is stopped with `/exit`, sent only once the composer is proven to
#     hold exactly that command.
#
# Run explicitly with FM_AGY_COMPOSER_LIVE=1 (or FM_LIVE=1). Set
# FM_AGY_COMPOSER_LIVE_CAPTURE_DIR to keep each styled screen the guard read,
# with the host name, user name, and private paths redacted; that is how
# tests/fixtures/agy-composer/ was recorded. Refresh
# docs/verification/agy.md "Composer classification" from this guard's output
# after any agy upgrade.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate opt-in FM_AGY_COMPOSER_LIVE tmux agy unshare ip

SOCKET="fm-agy-live-$$"
SESSION="agylive"
WIN="$SESSION:agy"
WIDTH=80
CHECKED=0
FAILED=0
VERSION=version-unknown
REAL_HOME=$HOME
REAL_USER=$(id -un)
REAL_HOST=$(hostname 2>/dev/null || uname -n)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-agy-live.XXXXXX")
CAPTURE_DIR=${FM_AGY_COMPOSER_LIVE_CAPTURE_DIR:-}

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { printf 'not ok - agy (%s): %s\n' "$VERSION" "$1" >&2; pane_tail; cleanup; exit 1; }
pass() { printf 'ok - agy (%s): %s\n' "$VERSION" "$1"; }
bad() { FAILED=1; printf 'not ok - agy (%s): %s\n' "$VERSION" "$1" >&2; }

pane_tail() {
  printf '# agy pane tail:\n' >&2
  tmux -L "$SOCKET" capture-pane -p -t "$WIN" 2>/dev/null \
    | grep '[^[:space:]]' | tail -12 | sed 's/^/#   /' >&2 || true
}

# The library under test, driven against the private socket through a PATH
# shim so its bare `tmux` calls stay isolated from any live fleet.
SHIM_DIR="$WORK/shim"
mkdir -p "$SHIM_DIR"
REAL_TMUX=$(command -v tmux)
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"

# --- private home and scratch workspace -------------------------------------
PRIV_HOME="$WORK/home"
WORKSPACE="$WORK/workspace"
AGY_SRC="$REAL_HOME/.gemini/antigravity-cli"
AGY_DST="$PRIV_HOME/.gemini/antigravity-cli"
mkdir -p "$AGY_DST" "$WORKSPACE" "$PRIV_HOME/.config" "$PRIV_HOME/.cache" \
  "$PRIV_HOME/.local/share" "$PRIV_HOME/.local/state"
chmod 700 "$WORK"
[ -f "$AGY_SRC/settings.json" ] \
  || fail "no agy settings at ~/.gemini/antigravity-cli/settings.json to copy; sign in to agy first"
jq --arg ws "$WORKSPACE" '.trustedWorkspaces = [$ws]' "$AGY_SRC/settings.json" \
  > "$AGY_DST/settings.json" || fail "could not narrow the private settings copy"
# Without its onboarding records a fresh home opens agy's first-run colour
# scheme picker instead of the composer (observed live on 1.5.18).
mkdir -p "$AGY_DST/cache"
for f in installation_id antigravity-oauth-token jetski_state.pbtxt \
  cache/onboarding.json cache/nux_state.json; do
  [ ! -f "$AGY_SRC/$f" ] || cp -p "$AGY_SRC/$f" "$AGY_DST/$f"
done

# The launcher refuses to exec agy unless the namespace holds loopback alone
# and an outbound connect fails, and records the version from the same
# isolated process tree.
cat > "$WORK/launch.sh" <<'SH'
#!/usr/bin/env bash
set -u
ip link set lo up || { echo 'launch refused: loopback did not come up'; exec sleep 300; }
links=$(ip -o link show | awk -F': ' '{print $2}' | tr '\n' ' ')
if [ "$links" != 'lo ' ]; then
  echo "launch refused: namespace has interfaces beyond loopback: $links"; exec sleep 300
fi
exec unshare -U --map-user="$FM_AGY_UID" --map-group="$FM_AGY_GID" bash -c '
  if (exec 3<>/dev/tcp/1.1.1.1/443) 2>/dev/null; then
    echo "launch refused: outbound connect succeeded"; exec sleep 300
  fi
  agy --version > "$FM_AGY_VERSION_FILE" 2>&1 || true
  echo egress-blocked > "$FM_AGY_EGRESS_FILE"
  cd "$FM_AGY_WORKSPACE" && exec agy'
SH
chmod +x "$WORK/launch.sh"

# --- screen helpers -----------------------------------------------------------
capture_styled() { tmux -L "$SOCKET" capture-pane -e -p -t "$WIN" 2>/dev/null; }

save_capture() {  # <name>
  [ -n "$CAPTURE_DIR" ] || return 0
  mkdir -p "$CAPTURE_DIR"
  capture_styled | sed \
    -e "s#$WORK#<private>#g" -e "s#$REAL_HOME#<home>#g" \
    -e "s#$REAL_USER#<user>#g" -e "s#$REAL_HOST#<host>#g" > "$CAPTURE_DIR/$1.ansi"
  tmux -L "$SOCKET" display-message -p -t "$WIN" '#{cursor_x} #{cursor_y} #{pane_width}x#{pane_height}' \
    > "$CAPTURE_DIR/$1.cursor" 2>/dev/null || true
}

guarded() {  # <expected-pending> [fit-text]
  fm_backend_guarded_composer_state tmux "$WIN" '' "$1" agy '' "${2:-}"
}

# composer_holds <text>: positive identification of agy's framed composer
# holding the guard's own text. Reads the rows between the LAST two solid rules,
# requires the first to open with agy's `>` glyph, and compares the rows'
# content with every space removed to <text> with every space removed: equal
# proves the whole draft is in the frame however agy wrapped it. Prints the
# number of framed content rows.
composer_holds() {  # <text>
  capture_styled | fm_composer_strip_ansi | LC_ALL=C awk -v want="$1" '
    { sub(/\r$/, ""); row[NR] = $0; t = $0; gsub(/^[ \t]+|[ \t]+$/, "", t)
      if (t ~ /^(─)+$/ && length(t) >= 20) { open = close; close = NR } }
    END {
      if (!open || close - open < 2) exit 1
      first = row[open + 1]; sub(/^[ \t]+/, "", first)
      if (substr(first, 1, 2) != "> " && first != ">") exit 1
      got = substr(first, 2)
      for (i = open + 2; i < close; i++) got = got row[i]
      gsub(/[ \t]/, "", got); gsub(/[ \t]/, "", want)
      if (got != want) exit 1
      print close - open - 1
    }'
}

wait_for() {  # <polls> <command...>: retry every 0.5s until success
  local n=$1 i=0
  shift
  while [ "$i" -lt "$n" ]; do
    "$@" >/dev/null 2>&1 && return 0
    i=$((i + 1))
    sleep 0.5
  done
  return 1
}

verdict_is() {  # <want> <expected-pending> [fit-text]
  [ "$(guarded "$2" "${3:-}")" = "$1" ]
}

# --- launch -------------------------------------------------------------------
tmux -L "$SOCKET" new-session -d -s "$SESSION" -n agy -x "$WIDTH" -y 30 -c "$WORKSPACE" \
  -e HOME="$PRIV_HOME" -e XDG_CONFIG_HOME="$PRIV_HOME/.config" \
  -e XDG_CACHE_HOME="$PRIV_HOME/.cache" -e XDG_DATA_HOME="$PRIV_HOME/.local/share" \
  -e XDG_STATE_HOME="$PRIV_HOME/.local/state" \
  -e FM_AGY_UID="$(id -u)" -e FM_AGY_GID="$(id -g)" -e FM_AGY_WORKSPACE="$WORKSPACE" \
  -e FM_AGY_VERSION_FILE="$WORK/version" -e FM_AGY_EGRESS_FILE="$WORK/egress" \
  -- unshare -rn "$WORK/launch.sh" \
  || fail "could not start the isolated tmux server"
tmux -L "$SOCKET" set-option -t "$WIN" remain-on-exit on >/dev/null 2>&1 || true

wait_for 20 test -s "$WORK/egress" || fail "launcher never proved egress blocked; agy was not started"
VERSION=$(head -1 "$WORK/version" 2>/dev/null)
[ -n "$VERSION" ] || VERSION=version-unknown
printf '# agy %s launched with no network egress and a private home\n' "$VERSION"

# 1. Idle composer reads empty. No keystroke has been sent yet.
if ! wait_for "${FM_AGY_COMPOSER_LIVE_POLLS:-90}" verdict_is empty ''; then
  save_capture idle-unproven
  fail "idle composer never classified empty (last verdict: $(guarded ''))"
fi
save_capture idle
CHECKED=$((CHECKED + 1))
pass "idle composer classifies empty"

# 2. The fit check refuses a notice that would wrap the one composer row.
LONG='zz wrap probe never submitted alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec'
if [ "$(guarded '' "$LONG")" = unknown ]; then
  CHECKED=$((CHECKED + 1))
  pass "a notice too long for the composer row is refused before typing"
else
  bad "a ${#LONG}-byte notice on a ${WIDTH}-column pane passed the fit check"
fi

# 3. A short draft reads pending, holding exactly that text.
SHORT='zz probe'
tmux -L "$SOCKET" send-keys -t "$WIN" -l "$SHORT"
if wait_for 10 verdict_is pending "$SHORT"; then
  save_capture short-draft
  CHECKED=$((CHECKED + 1))
  pass "a short typed draft classifies pending with its exact text"
else
  save_capture short-draft-unproven
  bad "short draft never classified pending (last verdict: $(guarded "$SHORT"))"
fi
wait_for 10 composer_holds "$SHORT" || fail "short draft not positively identified; no further keys sent"

# 4. Extend it into a draft that wraps the composer row. The doorbell's Enter
# needs a pending verdict proving its own text; a wrapped draft must give it
# neither an empty verdict nor proof of a different text.
DRAFT="$SHORT $LONG"
tmux -L "$SOCKET" send-keys -t "$WIN" -l " $LONG"
if ! rows=$(wait_for 10 composer_holds "$DRAFT" && composer_holds "$DRAFT"); then
  save_capture wrapped-draft-unidentified
  fail "the wrapped draft was not positively identified in agy's frame; no further keys sent"
fi
save_capture wrapped-draft
printf '# wrapped draft (%s bytes) occupies %s composer row(s) at %s columns\n' "${#DRAFT}" "$rows" "$WIDTH"
[ "$rows" -gt 1 ] || bad "a ${#DRAFT}-byte draft did not wrap at $WIDTH columns; the wrap evidence is vacuous"
v_draft=$(guarded "$DRAFT")
v_other=$(guarded "$SHORT")
v_plain=$(guarded '')
printf '# wrapped verdicts: expecting own text=%s, expecting other text=%s, no expectation=%s\n' \
  "$v_draft" "$v_other" "$v_plain"
case "$v_plain:$v_other" in
  empty:*|*:empty) bad "a wrapped draft classified empty" ;;
  *:pending) bad "a wrapped draft proved a different text" ;;
  *)
    CHECKED=$((CHECKED + 1))
    pass "a wrapped draft never reads empty or proves a different text, so the doorbell withholds Enter"
    ;;
esac

# 5. Erase the guard's own draft (proven above), prove empty again, then stop
# agy with /exit once the composer is proven to hold exactly that.
tmux -L "$SOCKET" send-keys -t "$WIN" -N "${#DRAFT}" BSpace
wait_for 20 verdict_is empty '' || fail "composer did not return to empty after erasing the draft; not sending /exit"
tmux -L "$SOCKET" send-keys -t "$WIN" -l '/exit'
if ! wait_for 10 composer_holds '/exit'; then
  save_capture exit-unidentified
  fail "/exit was not positively identified in the composer; Enter withheld"
fi
save_capture exit-typed
tmux -L "$SOCKET" send-keys -t "$WIN" Enter
pane_dead() { [ "$(tmux -L "$SOCKET" display-message -p -t "$WIN" '#{pane_dead}' 2>/dev/null)" = 1 ]; }
if wait_for 30 pane_dead; then
  save_capture exited
  pass "agy exited cleanly on /exit"
else
  save_capture exit-pending
  bad "agy did not exit within 15s of /exit"
fi

[ "$FAILED" -eq 0 ] || fail "live agy composer guard observed failures above"
[ "$CHECKED" -gt 0 ] || fail "live agy composer guard verified nothing; refusing a vacuous pass"
pass "live agy composer guard verified $CHECKED surface(s)"
