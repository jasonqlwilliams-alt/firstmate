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
lavish_session_listed_status() {  # <canonical-board-path>
  local listing
  listing=$(lavish-axi 2>/dev/null) || return 1
  printf '%s\n' "$listing" | awk -v path="$1" '
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    line ~ /^sessions(\[[0-9]+\]\{|:[[:space:]]*\[\])/ { listed = 1 }
    index(line, path ",") == 1 {
      rest = substr(line, length(path) + 2)
      split(rest, field, ",")
      status = field[1]
    }
    END {
      if (status != "") print status
      else if (listed) print "unlisted"
      else exit 1
    }
  '
}

report_closed_board() {  # <listed-status> <previous-status>
  local message
  case "$1:$2" in
    user-ended:*|*:user-ended)
      message="the user closed this board; pass --reopen to $(basename "$0") build to open it again"
      ;;
    ended:*|unlisted:opened|unlisted:ready|unlisted:open)
      message="the board closed during the build"
      ;;
    *) return 0 ;;
  esac
  printf 'session: closed\n%s\n' "$message"
  exit 0
}

board_session_open_before_arm() {
  local real listed
  real=$(board_realpath "$1") || return 1
  listed=$(lavish_session_listed_status "$real") || return 1
  report_closed_board "$listed" open
  [ "$listed" = open ]
}

# Establish the board session and PROVE it is live before anything arms a poll
# on it. The caller passes --reopen only when the user asked for the board
# again or something urgent needs them. Without that flag this helper never
# calls lavish-axi --reopen. A confirmed browser close on a plain attach or a
# closure observed during the build exits 0 without arming. Other non-open
# outcomes, including a refused explicit reopen, fail the build.
establish_board_session() {  # <board> [--reopen]
  local board=$1 real out listed status version
  BOARD_SESSION_REOPENED=0
  real=$(board_realpath "$board") || fail "cannot resolve the board path: $board"
  out=$(lavish-axi "$board") || fail "cannot establish the board Lavish session"
  printf '%s\n' "$out"
  listed=$(lavish_session_listed_status "$real") || listed=
  if [ "$listed" = open ]; then
    printf 'session: live\n'
    return 0
  fi
  if [ "$#" -eq 2 ]; then
    out=$(lavish-axi "$@") || fail "cannot reopen the ended board Lavish session"
    printf '%s\n' "$out"
    listed=$(lavish_session_listed_status "$real") || listed=
    if [ "$listed" = open ]; then
      BOARD_SESSION_REOPENED=1
      printf 'session: reopened\n'
      return 0
    fi
    status=$(lavish_status_field "$out")
    [ "$status" = user-ended ] || report_closed_board "$listed" "$status"
    version=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
    fail "the board Lavish session is not live after reopening it (lavish-axi ${version:-version-unknown} reported status ${status:-none}); refusing to arm a poll on an ended session"
  fi
  status=$(lavish_status_field "$out")
  report_closed_board "$listed" "$status"
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
