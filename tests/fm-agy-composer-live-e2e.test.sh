#!/usr/bin/env bash
# tests/fm-agy-composer-live-e2e.test.sh - the live agy composer guard
# (live-harness-optin family).
#
# agy's composer rule (bin/fm-composer-lib.sh "AGY COMPOSER") is built from
# vendor-rendered rows, so per .agents/skills/firstmate-coding-guidelines it
# must be proven against the REAL Antigravity CLI. This guard launches one
# bare agy in an isolated tmux server and, through the same guarded composer
# classifier the steering doorbell uses (with the
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
#     token copy is removed after startup and the real home is never written;
#   - agy runs in its own network namespace with only loopback up, so it has no
#     network egress; the guard refuses to launch agy unless the namespace
#     proves that before exec;
#   - typing starts only after an `empty` verdict and the guard extends only its
#     own proven draft;
#   - the private tmux server is stopped on exit.
#
# Run with FM_AGY_COMPOSER_LIVE_OAUTH=1 and FM_AGY_COMPOSER_LIVE=1 (or FM_LIVE=1).
# Set FM_AGY_COMPOSER_LIVE_CAPTURE_DIR to keep each wrapped-draft pair in a new
# subdirectory, with banner rows blanked. Refresh
# docs/verification/agy.md "Composer classification" from this guard's output
# after any agy upgrade.
set -u

# shellcheck source=tests/lib.sh
FM_TEST_SKIP_ORPHAN_REAP=1 . "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1

CAPTURE_DIR=${FM_AGY_COMPOSER_LIVE_CAPTURE_DIR:-}
if [ "${FM_AGY_COMPOSER_LIVE_OAUTH:-}" != 1 ]; then
  printf '%s\n' 'skip: live: set FM_AGY_COMPOSER_LIVE_OAUTH=1 to authorize an isolated copy of the agy sign-in token'
  exit 0
fi
fm_live_gate opt-in FM_AGY_COMPOSER_LIVE tmux agy unshare ip jq install

REAL_TMUX=$(command -v tmux)
SOCKET="fm-agy-live-$$"
SESSION="agylive"
WIN="$SESSION:agy"
WIDTH=80
VERSION=version-unknown
fail() { printf 'not ok - agy (%s): %s\n' "$VERSION" "$1" >&2; exit 1; }
pass() { printf 'ok - agy (%s): %s\n' "$VERSION" "$1"; }

# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"

remove_guard_profile() {  # <profile> <socket>
  local profile=$1 socket=$2 token_dir workspace diagnostic lookup_status=0
  token_dir="$profile/home/.gemini/antigravity-cli"
  if [ "$(cd -P -- "$token_dir" 2>/dev/null && pwd -P)" = "$token_dir" ]; then
    rm -f -- "$token_dir/antigravity-oauth-token" 2>/dev/null || true
  fi
  if workspace=$("$REAL_TMUX" -L "$socket" display-message -p -t "=$SESSION:" '#{session_path}' 2>&1); then
    [ -n "$workspace" ] || return 1
    if [ "$workspace" = "$profile/workspace" ]; then
      diagnostic=$("$REAL_TMUX" -L "$socket" kill-server 2>&1) ||
        fm_tmux_no_server_error "$diagnostic" || return 1
    fi
  else
    fm_tmux_read_failure_status "$workspace" || lookup_status=$?
    [ "$lookup_status" -eq 1 ] || return 1
  fi
  rm -rf -- "$profile" 2>/dev/null
}

reap_abandoned_runs() {
  local marker prior owner identity
  for marker in "$AGY_TMP_BASE"/fm-agy-live.*/.fm-agy-owner "$AGY_TMP_BASE"/fm-agy-live.*/.fm-test-fixture; do
    prior=${marker%/*}
    [ -d "$prior" ] && [ ! -L "$prior" ] && [ -O "$prior" ] &&
      [ -f "$marker" ] && [ ! -L "$marker" ] && [ -O "$marker" ] || continue
    { IFS= read -r owner && IFS= read -r identity; } < "$marker" || continue
    [[ "$owner" =~ ^[1-9][0-9]*$ && -n "$identity" ]] || continue
    fm_test_owner_is_alive "$owner" "$identity" && continue
    if [ "${marker##*/}" = .fm-test-fixture ]; then
      [ ! -e "$prior/.fm-agy-owner" ] || continue
      mv -- "$marker" "$prior/.fm-agy-owner" 2>/dev/null || return 1
    fi
    remove_guard_profile "$prior" "fm-agy-live-$owner" || return 1
  done
}
AGY_TMP_BASE=$(cd -P -- "${TMPDIR:-/tmp}" && pwd -P) || fail "could not resolve the private scratch base"
reap_abandoned_runs || fail "could not remove an abandoned agy guard fixture"

WORK=$(mktemp -d "$AGY_TMP_BASE/fm-agy-live.XXXXXX" 2>/dev/null) && [ -n "$WORK" ] \
  || fail "could not allocate the private scratch root"
TOKEN_COPY="$WORK/home/.gemini/antigravity-cli/antigravity-oauth-token"

cleanup() {
  local status=$?
  if ! remove_guard_profile "$WORK" "$SOCKET"; then
    printf 'not ok - agy (%s): could not finish private fixture cleanup\n' "$VERSION" >&2
    [ "$status" -ne 0 ] || status=1
  fi
  fm_test_cleanup
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
trap 'exit 131' QUIT
printf '%s\n%s\n' "$$" "$FM_TEST_OWNER_IDENTITY" > "$WORK/.fm-agy-owner" \
  || fail "could not record private fixture ownership"

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
. "$ROOT/bin/fm-backend.sh"

# --- private home and scratch workspace -------------------------------------
PRIV_HOME="$WORK/home"
WORKSPACE="$WORK/workspace"
AGY_SRC="$HOME/.gemini/antigravity-cli"
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
for f in installation_id jetski_state.pbtxt \
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
ip link set lo up || exit 1
links=$(ip -o link show | awk -F': ' '{print $2}' | tr '\n' ' ')
[ "$links" = 'lo ' ] || exit 1
exec unshare -U --map-user="$FM_AGY_UID" --map-group="$FM_AGY_GID" bash -c '
  if (exec 3<>/dev/tcp/1.1.1.1/443) 2>/dev/null; then
    exit 1
  fi
  install -m 600 -- "$FM_AGY_OAUTH_SOURCE" "$FM_AGY_OAUTH_COPY" || exit 1
  agy --version 2>/dev/null > "$FM_AGY_VERSION_FILE" || true
  echo egress-blocked > "$FM_AGY_EGRESS_FILE"
  cd "$FM_AGY_WORKSPACE" && exec agy'
SH
chmod +x "$WORK/launch.sh" 2>/dev/null || fail "could not make the private launcher executable"

# --- screen helpers -----------------------------------------------------------
save_capture() {  # <styled-screen> <opening-rule-row> <cursor-geometry>
  [ -n "$CAPTURE_DIR" ] || return 0
  (
    mkdir -p -- "$CAPTURE_DIR" || exit 1
    staged=$(mktemp -d "$CAPTURE_DIR/.wrapped-draft.XXXXXX") || exit 1
    trap 'rm -rf -- "$staged"' EXIT
    LC_ALL=C awk -v opening_row="$2" 'NR < opening_row { print ""; next } { print }' \
      <<< "$1" > "$staged/wrapped-draft.ansi" &&
      printf '%s\n' "$3" > "$staged/wrapped-draft.cursor" &&
      mv -T -- "$staged" "$CAPTURE_DIR/${staged##*/.}" || exit 1
    trap - EXIT
  ) 2>/dev/null || fail "could not publish screen and cursor evidence for the wrapped capture"
}

guarded_snapshot() {  # <expected-pending> [fit-text]
  local verdict
  [ -n "$FM_COMPOSER_SNAPSHOT_SCREEN" ] || return 1
  verdict=$(fm_backend_guarded_composer_classify_snapshot tmux "$WIN" "$1" agy "${2:-}" 2>/dev/null) || return 1
  case "$verdict" in
    empty|pending|pending-unproven|unknown|update-picker) printf '%s' "$verdict" ;;
    *) return 1 ;;
  esac
}

# composer_frame <text>: positive identification of agy's framed composer
# holding the guard's own text. Reads the rows between the LAST two solid rules,
# requires the first to open with agy's `>` glyph, and compares the rows with
# <text>, allowing a separator at each wrap boundary. Prints the opening
# rule row, the number of content rows, and the visible text of the first row.
composer_frame() {  # <text> (styled screen on stdin)
  fm_composer_strip_ansi | LC_ALL=C awk -v want="$1" '
    { sub(/\r$/, ""); row[NR] = $0; t = $0; gsub(/^[ \t]+|[ \t]+$/, "", t)
      if (t ~ /^(─)+$/ && length(t) >= 20) { start = stop; stop = NR } }
    END {
      if (!start || stop - start < 2) exit 1
      for (i = start + 1; i < stop; i++) {
        text = row[i]
        sub(/^[ \t]+/, "", text)
        sub(/[ \t]+$/, "", text)
        if (i == start + 1) {
          if (!sub(/^> /, "", text)) exit 1
          first = text
        }
        if (text == "" || substr(want, 1, length(text)) != text) exit 1
        want = substr(want, length(text) + 1)
        if (i + 1 < stop) sub(/^ /, "", want)
      }
      if (want != "") exit 1
      print start, stop - start - 1
      print first
    }'
}

read_snapshot() {
  fm_tmux_composer_snapshot "$WIN" '' geometry && [ -n "$FM_COMPOSER_SNAPSHOT_SCREEN" ]
}

read_frame() {  # <text>
  read_snapshot || return 1
  frame=$(composer_frame "$1" <<< "$FM_COMPOSER_SNAPSHOT_SCREEN")
}

read_idle() {
  idle_verdict=
  read_snapshot || return 1
  idle_verdict=$(guarded_snapshot '') || idle_verdict=
  if [ -e "$TOKEN_COPY" ] && fm_composer_strip_ansi <<< "$FM_COMPOSER_SNAPSHOT_SCREEN" |
    LC_ALL=C awk '
      /Antigravity CLI [0-9]+\.[0-9]+\.[0-9]+/ { banner = NR }
      banner && NR == banner + 1 && /[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]+/ { signed_in = 1 }
      END { exit !signed_in }
    '; then
    rm -f -- "$TOKEN_COPY" 2>/dev/null
  fi
  [ "$idle_verdict" = empty ]
}

read_short_draft() {  # <text>
  read_frame "$1" && [[ "${frame#* }" == 1$'\n'* ]] && verdict_is pending "$1"
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
  local verdict
  verdict=$(guarded_snapshot "$2" "${3:-}") && [ "$verdict" = "$1" ]
}

# --- launch -------------------------------------------------------------------
"$REAL_TMUX" -L "$SOCKET" -f /dev/null new-session -d -s "$SESSION" -n agy -x "$WIDTH" -y 30 -c "$WORKSPACE" \
  -e HOME="$PRIV_HOME" -e XDG_CONFIG_HOME="$PRIV_HOME/.config" \
  -e XDG_CACHE_HOME="$PRIV_HOME/.cache" -e XDG_DATA_HOME="$PRIV_HOME/.local/share" \
  -e XDG_STATE_HOME="$PRIV_HOME/.local/state" \
  -e FM_AGY_UID="$(id -u)" -e FM_AGY_GID="$(id -g)" -e FM_AGY_WORKSPACE="$WORKSPACE" \
  -e FM_AGY_OAUTH_SOURCE="$AGY_SRC/antigravity-oauth-token" \
  -e FM_AGY_OAUTH_COPY="$TOKEN_COPY" \
  -e FM_AGY_VERSION_FILE="$WORK/version" -e FM_AGY_EGRESS_FILE="$WORK/egress" \
  -- unshare -rn "$WORK/launch.sh" 2>/dev/null \
  || fail "could not start the isolated tmux server"

wait_for 20 test -s "$WORK/egress" || fail "isolated launcher did not complete egress checks and OAuth setup"
VERSION=$(grep -m 1 -Ex '[0-9]+\.[0-9]+\.[0-9]+' "$WORK/version" 2>/dev/null) || VERSION=version-unknown
printf '# agy %s launched with no network egress and a private home\n' "$VERSION"

# 1. Idle composer reads empty. No keystroke has been sent yet.
if ! wait_for 90 read_idle; then
  fail "idle composer never classified empty (last verdict: ${idle_verdict:-unavailable})"
fi
rm -f -- "$TOKEN_COPY" 2>/dev/null || fail "could not remove the temporary agy sign-in token"
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
wait_for 10 read_short_draft "$SHORT" || fail "short draft was never proven and classified pending in one frame"
v_other=$(guarded_snapshot 'zz prose') || fail "could not read a valid verdict for the mismatched short draft"
case "$v_other" in
  empty|pending) fail "short draft classified empty or proved a different expectation" ;;
esac
pass "a short typed draft classifies pending with its exact text"

# 4. Extend it into a draft that wraps the composer row. The doorbell's Enter
# needs a pending verdict proving its own text; a wrapped draft must give it
# neither an empty verdict nor proof of a different text.
DRAFT="$SHORT $LONG"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$WIN" -l " $LONG" 2>/dev/null || fail "could not extend the short draft"
wait_for 10 read_frame "$DRAFT" || fail "the wrapped draft was never identified in agy's frame"
layout=${frame#* }
rows=${layout%%$'\n'*}
first_row=${layout#*$'\n'}
printf '# wrapped draft (%s bytes) occupies %s composer row(s) at %s columns\n' "${#DRAFT}" "$rows" "$WIDTH"
[ "$rows" -gt 1 ] || fail "a ${#DRAFT}-byte draft did not wrap on a ${WIDTH}-column pane"
v_first=$(guarded_snapshot "$first_row") || fail "could not read a valid verdict for the first wrapped row"
v_plain=$(guarded_snapshot '') || fail "could not read a valid wrapped verdict without an expectation"
printf '# wrapped verdicts (first row, no expectation) = %s, %s\n' "$v_first" "$v_plain"
save_capture "$FM_COMPOSER_SNAPSHOT_SCREEN" "${frame%% *}" "$FM_COMPOSER_SNAPSHOT_TMUX_GEOMETRY"
case "$v_first:$v_plain" in
  empty:*|*:empty) fail "a wrapped draft classified empty" ;;
  pending:*) fail "a wrapped draft proved the first row alone" ;;
esac
pass "a wrapped draft never reads empty or proves the first row alone"
