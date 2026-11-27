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
#   - the fit check to accept a short notice and refuse one too long for the
#     composer row;
#   - a short typed draft to read `pending` holding exactly that text;
#   - a draft long enough to wrap the composer row never to read `empty`, and
#     never to prove the first row alone as an exact match.
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
#   - typing starts only after an `empty` verdict and the guard extends only its
#     own proven draft;
#   - the private tmux server is stopped on exit.
#
# Run explicitly with FM_AGY_COMPOSER_LIVE=1 (or FM_LIVE=1). Set
# FM_AGY_COMPOSER_LIVE_CAPTURE_DIR to keep each styled screen the guard read,
# with the account address, host name, user name, and private paths redacted;
# that is how tests/fixtures/agy-composer/ was recorded. Refresh
# docs/verification/agy.md "Composer classification" from this guard's output
# after any agy upgrade.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CAPTURE_DIR=${FM_AGY_COMPOSER_LIVE_CAPTURE_DIR:-}
fm_live_gate opt-in FM_AGY_COMPOSER_LIVE tmux agy unshare ip jq ${CAPTURE_DIR:+perl}

REAL_TMUX=$(command -v tmux)
SOCKET="fm-agy-live-$$"
SESSION="agylive"
WIN="$SESSION:agy"
WIDTH=80
VERSION=version-unknown
fail() { printf 'not ok - agy (%s): %s\n' "$VERSION" "$1" >&2; exit 1; }
pass() { printf 'ok - agy (%s): %s\n' "$VERSION" "$1"; }

REAL_HOME=$HOME
REAL_USER=$(id -un)
REAL_HOST=$(hostname 2>/dev/null || uname -n)
WORK=$(fm_test_tmproot fm-agy-live 2>/dev/null) && [ -n "$WORK" ] \
  || fail "could not allocate the private scratch root"

cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
trap 'exit 131' QUIT

# The library under test, driven against the private socket through a PATH
# shim so its bare `tmux` calls stay isolated from any live fleet.
SHIM_DIR="$WORK/shim"
mkdir -p "$SHIM_DIR" 2>/dev/null || fail "could not create the private tmux shim directory"
cat 2>/dev/null > "$SHIM_DIR/tmux" <<SH || fail "could not write the private tmux shim"
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux" 2>/dev/null || fail "could not make the private tmux shim executable"
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
  "$PRIV_HOME/.local/share" "$PRIV_HOME/.local/state" 2>/dev/null \
  || fail "could not create the private home and workspace"
[ -f "$AGY_SRC/settings.json" ] \
  || fail "no agy settings at ~/.gemini/antigravity-cli/settings.json to copy; sign in to agy first"
jq --arg ws "$WORKSPACE" '.trustedWorkspaces = [$ws]' "$AGY_SRC/settings.json" 2>/dev/null \
  > "$AGY_DST/settings.json" || fail "could not narrow the private settings copy"
# Without its onboarding records a fresh home opens agy's first-run colour
# scheme picker instead of the composer (observed live on 1.5.18).
mkdir -p "$AGY_DST/cache" 2>/dev/null || fail "could not create the private cache"
for f in installation_id antigravity-oauth-token jetski_state.pbtxt \
  cache/onboarding.json cache/nux_state.json; do
  [ ! -f "$AGY_SRC/$f" ] || cp -p "$AGY_SRC/$f" "$AGY_DST/$f" 2>/dev/null \
    || fail "could not copy a private agy record"
done

# The launcher refuses to exec agy unless the namespace holds loopback alone
# and an outbound connect fails, and records the version from the same
# isolated process tree.
cat 2>/dev/null > "$WORK/launch.sh" <<'SH' || fail "could not write the private launcher"
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
  agy --version 2>/dev/null > "$FM_AGY_VERSION_FILE" || true
  echo egress-blocked > "$FM_AGY_EGRESS_FILE"
  cd "$FM_AGY_WORKSPACE" && exec agy'
SH
chmod +x "$WORK/launch.sh" 2>/dev/null || fail "could not make the private launcher executable"

# --- screen helpers -----------------------------------------------------------
capture_styled() { "$REAL_TMUX" -L "$SOCKET" capture-pane -e -p -t "$WIN" 2>/dev/null; }

save_capture() {  # <name>
  [ -n "$CAPTURE_DIR" ] || return 0
  local screen cursor
  screen=$(capture_styled) && [ -n "$screen" ] \
    || fail "could not read a nonempty screen for capture $1"
  cursor=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$WIN" \
    '#{cursor_x} #{cursor_y} #{pane_width}x#{pane_height}' 2>/dev/null) \
    && [[ "$cursor" =~ ^[0-9]+\ [0-9]+\ [0-9]+x[0-9]+$ ]] \
    || fail "could not read cursor geometry for capture $1"
  {
    mkdir -p -- "$CAPTURE_DIR" &&
      perl -pe '
        BEGIN {
          ($work, $home, $user, $host) = splice @ARGV;
          %redact = ($work => "<private>", $home => "<home>", $user => "<user>", $host => "<host>");
          $literal = join "|", map { quotemeta } sort { length($b) <=> length($a) } grep { length } keys %redact;
        }
        s{
          \e\[[0-?]*[ -/]*[@-~](*SKIP)(*F)
          | [[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]+
          | ($literal)
        }{defined $1 ? $redact{$1} : "<email>"}gex;
      ' -- "$WORK" "$REAL_HOME" "$REAL_USER" "$REAL_HOST" <<< "$screen" > "$CAPTURE_DIR/$1.ansi" &&
      printf '%s\n' "$cursor" > "$CAPTURE_DIR/$1.cursor"
  } 2>/dev/null || fail "could not write screen and cursor evidence for capture $1"
}

guarded() {  # <expected-pending> [fit-text]
  fm_backend_guarded_composer_state tmux "$WIN" '' "$1" agy '' "${2:-}" 2>/dev/null
}

# composer_holds <text>: positive identification of agy's framed composer
# holding the guard's own text. Reads the rows between the LAST two solid rules,
# requires the first to open with agy's `>` glyph, and compares the rows'
# content with every space removed to <text> with every space removed: equal
# proves the whole draft is in the frame however agy wrapped it. Prints the
# number of framed content rows and the visible text of the first row.
composer_holds() {  # <text>
  capture_styled | fm_composer_strip_ansi | LC_ALL=C awk -v want="$1" '
    { sub(/\r$/, ""); row[NR] = $0; t = $0; gsub(/^[ \t]+|[ \t]+$/, "", t)
      if (t ~ /^(─)+$/ && length(t) >= 20) { start = stop; stop = NR } }
    END {
      if (!start || stop - start < 2) exit 1
      first = row[start + 1]; sub(/^[ \t]+/, "", first)
      if (!sub(/^> /, "", first)) exit 1
      sub(/[ \t]+$/, "", first)
      got = first
      for (i = start + 2; i < stop; i++) got = got row[i]
      gsub(/[ \t]/, "", got); gsub(/[ \t]/, "", want)
      if (got != want) exit 1
      print stop - start - 1
      print first
    }'
}

wait_for() {  # <polls> <command...>: retry every 0.5s until success
  local n=$1 i=0
  shift
  while [ "$i" -lt "$n" ]; do
    "$@" 2>/dev/null && return 0
    i=$((i + 1))
    sleep 0.5
  done
  return 1
}

verdict_is() {  # <want> <expected-pending> [fit-text]
  [ "$(guarded "$2" "${3:-}")" = "$1" ]
}

# --- launch -------------------------------------------------------------------
"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n agy -x "$WIDTH" -y 30 -c "$WORKSPACE" \
  -e HOME="$PRIV_HOME" -e XDG_CONFIG_HOME="$PRIV_HOME/.config" \
  -e XDG_CACHE_HOME="$PRIV_HOME/.cache" -e XDG_DATA_HOME="$PRIV_HOME/.local/share" \
  -e XDG_STATE_HOME="$PRIV_HOME/.local/state" \
  -e FM_AGY_UID="$(id -u)" -e FM_AGY_GID="$(id -g)" -e FM_AGY_WORKSPACE="$WORKSPACE" \
  -e FM_AGY_VERSION_FILE="$WORK/version" -e FM_AGY_EGRESS_FILE="$WORK/egress" \
  -- unshare -rn "$WORK/launch.sh" 2>/dev/null \
  || fail "could not start the isolated tmux server"

wait_for 20 test -s "$WORK/egress" || fail "launcher never proved egress blocked; agy was not started"
VERSION=$(grep -m 1 -Ex '[0-9]+\.[0-9]+\.[0-9]+' "$WORK/version" 2>/dev/null) || VERSION=version-unknown
printf '# agy %s launched with no network egress and a private home\n' "$VERSION"

# 1. Idle composer reads empty. No keystroke has been sent yet.
if ! wait_for 90 verdict_is empty ''; then
  save_capture idle-unproven
  fail "idle composer never classified empty (last verdict: $(guarded ''))"
fi
save_capture idle
pass "idle composer classifies empty"

# 2. Check fit on both sides of the composer width before typing.
SHORT='zz probe'
LONG='zz wrap probe never submitted alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec'
verdict_is unknown '' "$LONG" \
  || fail "the fit check did not refuse a ${#LONG}-byte notice on a ${WIDTH}-column pane"
verdict_is empty '' "$SHORT" \
  || fail "the fit check did not accept a ${#SHORT}-byte notice on a ${WIDTH}-column pane"
pass "the fit check refuses the long notice and accepts the short notice"

# 3. A short draft reads pending, holding exactly that text.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$WIN" -l "$SHORT" 2>/dev/null || fail "could not type the short draft"
if ! wait_for 10 verdict_is pending "$SHORT"; then
  save_capture short-draft-unproven
  fail "short draft never classified pending (last verdict: $(guarded "$SHORT"))"
fi
save_capture short-draft
wait_for 10 composer_holds "$SHORT" >/dev/null || fail "short draft was never identified in agy's frame"
pass "a short typed draft classifies pending with its exact text"

# 4. Extend it into a draft that wraps the composer row. The doorbell's Enter
# needs a pending verdict proving its own text; a wrapped draft must give it
# neither an empty verdict nor proof of a different text.
DRAFT="$SHORT $LONG"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$WIN" -l " $LONG" 2>/dev/null || fail "could not extend the short draft"
if ! frame=$(wait_for 10 composer_holds "$DRAFT"); then
  save_capture wrapped-draft-unidentified
  fail "the wrapped draft was never identified in agy's frame"
fi
save_capture wrapped-draft
rows=${frame%%$'\n'*}
first_row=${frame#*$'\n'}
printf '# wrapped draft (%s bytes) occupies %s composer row(s) at %s columns\n' "${#DRAFT}" "$rows" "$WIDTH"
[ "$rows" -gt 1 ] && [[ -n "$first_row" && "$DRAFT" = "$first_row"* && "$first_row" != "$DRAFT" ]] \
  || fail "a ${#DRAFT}-byte draft on a ${WIDTH}-column pane did not produce a distinct first row and continuation"
v_draft=$(guarded "$DRAFT")
v_first=$(guarded "$first_row")
v_plain=$(guarded '')
printf '# wrapped verdicts (full draft, first row, no expectation) = %s, %s, %s\n' \
  "$v_draft" "$v_first" "$v_plain"
case "$v_draft:$v_first:$v_plain" in
  empty:*|*:empty:*|*:empty) fail "a wrapped draft classified empty" ;;
  *:pending:*) fail "a wrapped draft proved the first row alone" ;;
esac
pass "a wrapped draft never reads empty or proves the first row alone"
