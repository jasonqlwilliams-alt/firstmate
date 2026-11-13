#!/usr/bin/env bash
# Opt-in only, despite spending no model tokens: a stray key at Codex's update
# picker has broken a global installation. Never make this guard default-on.
# Run with FM_CODEX_SIGNIN_LIVE=1 or FM_LIVE=1 through bin/fm-test-run.sh.
# Uses an empty CODEX_HOME, a throwaway cwd and a private tmux socket. Every
# pane-input command is blocked. An unexpected screen fails and is stopped by
# exact verified PID only. FM_CODEX_SIGNIN_CAPTURE optionally saves private text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_CODEX_SIGNIN_LIVE codex tmux python3 git

GLOBAL_USER_HOME=$HOME
TMUX_BIN=$(command -v tmux)
CODEX_BIN=$(command -v codex)
TMP_ROOT=$(fm_test_tmproot fm-codex-signin-live)
SOCKET="$TMP_ROOT/tmux.sock"
TARGET=signin:fm-signin-live
NATIVE_PID=''
NATIVE_IDENTITY=''
SERVER_PID=''
STARTED=0
VERSION=unknown
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/codex" "$TMP_ROOT/user" \
  "$TMP_ROOT/home/state" "$TMP_ROOT/home/data" "$TMP_ROOT/home/config"
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_ROOT_OVERRIDE
export FM_HOME="$TMP_ROOT/home" STATE="$TMP_ROOT/home/state"

global_mtimes() {
  python3 - "$GLOBAL_USER_HOME" <<'PY'
import json, pathlib, sys
home = pathlib.Path(sys.argv[1]) / ".codex"
result = {}
for name in ("config.toml", "auth.json"):
    try:
        result[name] = (home / name).stat().st_mtime_ns
    except FileNotFoundError:
        result[name] = None
print(json.dumps(result, sort_keys=True))
PY
}

codex_version() {
  HOME="$TMP_ROOT/user" CODEX_HOME="$TMP_ROOT/codex" "$CODEX_BIN" --version
}

signal_verified_native() {
  local identity
  [ -n "$NATIVE_PID" ] || return 1
  kill -0 "$NATIVE_PID" 2>/dev/null || return 0
  identity=$(LC_ALL=C ps -p "$NATIVE_PID" -o lstart= -o comm= 2>/dev/null) || return 1
  [ "$identity" = "$NATIVE_IDENTITY" ] || return 1
  kill -TERM "$NATIVE_PID"
}

cleanup() {
  local rc=$? i=0 endpoint_state
  trap - EXIT
  if [ -n "$NATIVE_PID" ]; then
    signal_verified_native || {
      printf 'not ok - %s: native process identity changed; refusing cleanup signal\n' "$VERSION" >&2
      exit 1
    }
    while kill -0 "$NATIVE_PID" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
    if kill -0 "$NATIVE_PID" 2>/dev/null; then
      printf 'not ok - %s: native process remains; private endpoint retained\n' "$VERSION" >&2
      exit 1
    fi
  fi
  if [ "$STARTED" -eq 1 ]; then
    i=0; endpoint_state=unknown
    while [ "$i" -lt 20 ]; do
      endpoint_state=$(fm_backend_agent_state tmux "$TARGET")
      case "$endpoint_state" in dead|missing) break ;; esac
      sleep 0.1; i=$((i+1))
    done
    case "$endpoint_state" in
      dead|missing) ;;
      *) printf 'not ok - %s: endpoint identity is %s; private endpoint retained for inspection\n' "$VERSION" "$endpoint_state" >&2; exit 1 ;;
    esac
  fi
  "$TMUX_BIN" -S "$SOCKET" kill-server 2>/dev/null || true
  i=0
  while [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    printf 'not ok - %s: private tmux server remains\n' "$VERSION" >&2
    rc=1
  fi
  if [ -s "$TMP_ROOT/input-attempts" ]; then
    printf 'not ok - %s: lifecycle attempted pane input (blocked)\n' "$VERSION" >&2
    rc=1
  fi
  codex_version > "$TMP_ROOT/version-after" || rc=1
  global_mtimes > "$TMP_ROOT/mtimes-after" || rc=1
  if ! cmp -s "$TMP_ROOT/mtimes-before" "$TMP_ROOT/mtimes-after"; then
    printf 'not ok - %s: global Codex config/auth mtimes changed during guard\n' "$VERSION" >&2
    rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    printf 'ok - %s sign-in stopped without input; private processes gone and global mtimes unchanged\n' "$VERSION"
  fi
  fm_test_cleanup
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

global_mtimes > "$TMP_ROOT/mtimes-before" || exit 1
VERSION=$(codex_version) || fail 'Codex --version failed before guard'
cat > "$TMP_ROOT/bin/tmux" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  display-message|capture-pane|list-panes|list-windows|list-sessions|has-session|show-options|show-window-options|show-environment|list-clients|-V)
    exec "$TMUX_BIN" -S "$SOCKET" "\$@" ;;
  *) printf '%s\n' "\${1:-unknown}" >> "$TMP_ROOT/input-attempts"; exit 96 ;;
esac
EOF
chmod +x "$TMP_ROOT/bin/tmux"
export PATH="$TMP_ROOT/bin:$PATH"
fm_git_init_commit "$TMP_ROOT/work"
cat > "$TMP_ROOT/launch" <<EOF
#!/usr/bin/env bash
env -u OPENAI_API_KEY -u CODEX_API_KEY -u AZURE_OPENAI_API_KEY -u CODEX_THREAD_ID -u CODEX_SESSION_ID \
  HOME="$TMP_ROOT/user" CODEX_HOME="$TMP_ROOT/codex" \
  XDG_CONFIG_HOME="$TMP_ROOT/user/.config" XDG_STATE_HOME="$TMP_ROOT/user/.state" XDG_CACHE_HOME="$TMP_ROOT/user/.cache" \
  "$CODEX_BIN"
exec /bin/bash --noprofile --norc
EOF
chmod +x "$TMP_ROOT/launch"
# Establish server ownership and disable title changes before the CLI starts.
"$TMUX_BIN" -S "$SOCKET" -f /dev/null new-session -d -s signin -n anchor \
  -x 120 -y 40 -c "$TMP_ROOT/work" /bin/bash --noprofile --norc \
  || fail "$VERSION: private tmux server failed"
SERVER_PID=$("$TMUX_BIN" -S "$SOCKET" display-message -p -t signin:anchor '#{pid}') \
  || fail "$VERSION: private server PID unavailable"
case "$SERVER_PID" in ''|*[!0-9]*|0|1) fail "$VERSION: invalid private server PID" ;; esac
"$TMUX_BIN" -S "$SOCKET" set-option -g automatic-rename off
"$TMUX_BIN" -S "$SOCKET" set-option -g allow-rename off
fm_write_meta "$TMP_ROOT/home/state/signin-live.meta" 'backend=tmux' "window=$TARGET" \
  'endpoint_task_id=signin-live' 'harness=codex' 'kind=ship' \
  "worktree=$TMP_ROOT/work" "project=$TMP_ROOT/work" 'mode=no-mistakes'

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"
STARTED=1
"$TMUX_BIN" -S "$SOCKET" new-window -d -t signin -n fm-signin-live \
  -c "$TMP_ROOT/work" /bin/bash --noprofile --norc "$TMP_ROOT/launch" \
  || fail "$VERSION: private Codex window failed"
i=0; previous=''; screen=''
while [ "$i" -lt 100 ]; do
  screen=$("$TMUX_BIN" -S "$SOCKET" capture-pane -p -t "$TARGET") || fail "$VERSION: capture failed"
  case "$screen" in
    *[![:space:]]*) [ "$screen" != "$previous" ] || break ;;
  esac
  previous=$screen
  sleep 0.2; i=$((i+1))
done
if [ -n "${FM_CODEX_SIGNIN_CAPTURE:-}" ]; then
  printf '%s\n' "$screen" > "$FM_CODEX_SIGNIN_CAPTURE" || fail "$VERSION: private capture write failed"
fi
NATIVE_PID=$(fm_backend_codex_agent_pid tmux "$TARGET") || fail "$VERSION: exact native PID could not be verified"
NATIVE_IDENTITY=$(LC_ALL=C ps -p "$NATIVE_PID" -o lstart= -o comm=) || fail "$VERSION: native birth identity unavailable"
fm_composer_codex_signin_screen "$screen" \
  || fail "$VERSION: first screen is not a recognized sign-in chooser; no input sent"
FM_CONTROL_POLL=0.1 FM_CONTROL_EXIT_WAIT=5 "$ROOT/bin/fm-control.sh" signin-live exit \
  > "$TMP_ROOT/control.out" 2>&1 || fail "$VERSION: sign-in exit refused: $(cat "$TMP_ROOT/control.out")"
assert_contains "$(cat "$TMP_ROOT/control.out")" 'stopped-sign-in' "$VERSION: sign-in stop unconfirmed"
! kill -0 "$NATIVE_PID" 2>/dev/null || fail "$VERSION: native process survived successful exit"
