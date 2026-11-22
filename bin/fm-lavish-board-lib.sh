#!/usr/bin/env bash
# Shared Lavish board session and listener proof.
# Usage: source this library after defining SCRIPT_DIR and fail().
# No action on source; establish_board_session and the source-owner helpers
# preserve the serve-first contract owned by bin/fm-bearings-board.sh.

# --- Lavish session liveness -------------------------------------------------
# Verified against lavish-axi 0.1.61. `lavish-axi <file>` EXITS 0 even when it
# refuses to reopen a session the captain ended from the browser, reporting
# `status: user-ended` and the same session id, so an exit-code check alone
# cannot tell a live board from a dead one. The establish status is an initial
# signal only; the server's fresh session listing must also show the canonical
# board open before the build may bind or arm its source.

board_realpath() {  # <board>
  perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$1" 2>/dev/null
}

lavish_status_field() {  # <lavish-axi output>
  printf '%s\n' "$1" | sed -n 's/^[[:space:]]*status:[[:space:]]*//p' | head -1 | tr -d '"'
}

# The Lavish listing, keyed on the canonical artifact path. Rows are
# `<file>,<status>,"<url>",<pending>`, and only a live session is listed `open`.
lavish_session_listed_open() {  # <canonical-board-path>
  local listing
  [ -n "$1" ] || return 1
  listing=$(lavish-axi 2>/dev/null) || return 1
  printf '%s\n' "$listing" | awk -v path="$1" '
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    index(line, path ",") == 1 {
      rest = substr(line, length(path) + 2)
      split(rest, field, ",")
      if (field[1] == "open") { found = 1 }
    }
    END { exit found ? 0 : 1 }
  '
}

# Establish the board session and PROVE it is live before anything arms a poll
# on it. The caller passes --reopen only when the user asked for the board
# again or something urgent needs them. Without that flag this helper never
# calls lavish-axi --reopen. A plain attach reporting user-ended exits 0 without
# arming. Other non-open outcomes fail the build.
establish_board_session() {  # <board> [--reopen]
  local board=$1 real out status version
  BOARD_SESSION_REOPENED=0
  real=$(board_realpath "$board") || fail "cannot resolve the board path: $board"
  out=$(lavish-axi "$board") || fail "cannot establish the board Lavish session"
  printf '%s\n' "$out"
  status=$(lavish_status_field "$out")
  if [ "$#" -eq 1 ] && [ "$status" = user-ended ]; then
    printf 'session: closed\n'
    printf 'the user closed this board; pass --reopen to %s build to open it again\n' "$(basename "$0")"
    exit 0
  fi
  if lavish_session_listed_open "$real"; then
    printf 'session: live\n'
    return 0
  fi
  if [ "$#" -eq 2 ]; then
    out=$(lavish-axi "$@") || fail "cannot reopen the ended board Lavish session"
    printf '%s\n' "$out"
    if lavish_session_listed_open "$real"; then
      BOARD_SESSION_REOPENED=1
      printf 'session: reopened\n'
      return 0
    fi
    status=$(lavish_status_field "$out")
    version=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
    fail "the board Lavish session is not live after reopening it (lavish-axi ${version:-version-unknown} reported status ${status:-none}); refusing to arm a poll on an ended session"
  fi
  version=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
  fail "the board Lavish session is not live (lavish-axi ${version:-version-unknown} reported status ${status:-none}); refusing to arm a poll on an ended session"
}

# The OWNER column bin/fm-procevent.sh already publishes: live, none,
# orphaned, or uncertain. Empty means the source is not registered at all.
source_owner() {  # <source-id>
  "$SCRIPT_DIR/fm-procevent.sh" list 2>/dev/null \
    | awk -v id="$1" 'NR > 1 && $1 == id { print $3 }'
}

# A replacement listener is started detached, so it claims the source shortly
# after reconcile returns. Wait for that claim rather than reporting the race.
await_source_owner() {  # <source-id>
  local owner i=0
  while [ "$i" -lt 50 ]; do
    owner=$(source_owner "$1")
    [ "$owner" != live ] || { printf '%s\n' "$owner"; return 0; }
    sleep 0.1
    i=$((i + 1))
  done
  printf '%s\n' "${owner:-none}"
}
