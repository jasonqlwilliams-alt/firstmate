#!/usr/bin/env bash
# Stop a sign-in stub through the real lifecycle executable and isolated terminals.
# No vendor harness is launched; an unrelated process, update picker, retained
# sign-in history, incomplete screen and wrong native identity remain protected.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v cc >/dev/null || { echo 'skip: cc not found'; exit 0; }
command -v tmux >/dev/null || { echo 'skip: tmux not found'; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-codex-signin)
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/home/state" "$TMP_ROOT/home/data" "$TMP_ROOT/home/config"
fm_git_worktree "$TMP_ROOT/project" "$TMP_ROOT/worktree" fixture-task
ORIGINAL_PATH=$PATH
TMUX_BIN=$(command -v tmux)
SOCKET="fm-signin-$$"
cleanup() {
  local rc=$?
  trap - EXIT
  "$TMUX_BIN" -f /dev/null -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT
cat > "$TMP_ROOT/stub.c" <<'C'
#include <stdio.h>
#include <unistd.h>
#include <termios.h>
#include <string.h>
int main(int argc, char **argv) {
  struct termios t;
  if (tcgetattr(0, &t) == 0) { t.c_lflag &= ~(ICANON | ECHO); tcsetattr(0, TCSANOW, &t); }
  printf("\033[2J\033[HWelcome to Codex\r\n\r\nSign in with ChatGPT to use Codex as part of your paid plan\r\n\r\n");
  if (argc > 3 && !strcmp(argv[3], "unknown")) { printf("Unidentified setup dialog\r\n"); }
  else if (argc > 3 && !strcmp(argv[3], "update")) {
    printf("Update available · 0.162.1 → 0.999.0\r\n› 1. Update now (runs `npm install -g @openai/codex`)\r\n2. Skip\r\n3. Skip until next version\r\nenter continue · esc skip\r\n");
  } else {
  printf("  1. Sign in with ChatGPT\r\n  2. Sign in with Device Code\r\n  3. Provide your own API key\r\n\r\nPress Enter to continue\r\n");
  if (argc > 3 && !strcmp(argv[3], "history")) printf("\r\n> Unidentified next screen\r\n");
  if (argc > 3 && !strcmp(argv[3], "missing-choice")) printf("\033[2J\033[HWelcome to Codex\r\nSign in with ChatGPT to use Codex as part of your paid plan\r\n1. Sign in with ChatGPT\r\nPress Enter to continue\r\n");
  }
  fflush(stdout);
  FILE *f = fopen(argv[1], "w"); fprintf(f, "%d\n", getpid()); fclose(f);
  char c;
  while (read(0, &c, 1) == 1) { f = fopen(argv[2], "a"); fputc(c, f); fclose(f); }
  return argc == 0;
}
C
cc -o "$TMP_ROOT/bin/codex" "$TMP_ROOT/stub.c" || fail 'could not compile sign-in stub'
cat > "$TMP_ROOT/bin/tmux" <<EOF
#!/usr/bin/env bash
exec "$TMUX_BIN" -f /dev/null -L "$SOCKET" "\$@"
EOF
chmod +x "$TMP_ROOT/bin/tmux"
# Launch only the compiled stub as a direct terminal child. A clean shell
# remains after it exits; host shell profiles and startup-key timing are absent.
stub_command() {
  printf '%q %q %q %q; exec /bin/bash --noprofile --norc' \
    "$TMP_ROOT/bin/$1" "$TMP_ROOT/$2" "$TMP_ROOT/$3" "$4"
}
"$TMUX_BIN" -f /dev/null -L "$SOCKET" new-session -d -s fixture -n sentinel \
  -c "$TMP_ROOT/worktree" /bin/bash --noprofile --norc -c \
  "$(stub_command codex sentinel-pid sentinel-keys signin)" || fail 'tmux fixture failed'
"$TMUX_BIN" -f /dev/null -L "$SOCKET" set-option -g automatic-rename off
"$TMUX_BIN" -f /dev/null -L "$SOCKET" set-option -g allow-rename off
for mode in signin unknown update history missing-choice wrong-process; do
  target=fixture:fm-signin
  binary=codex
  if [ "$mode" = wrong-process ]; then
    cp "$TMP_ROOT/bin/codex" "$TMP_ROOT/bin/claude"
    binary=claude
  fi
  "$TMUX_BIN" -f /dev/null -L "$SOCKET" new-window -d -t fixture -n fm-signin \
    -c "$TMP_ROOT/worktree" /bin/bash --noprofile --norc -c \
    "$(stub_command "$binary" pid keys "$mode")" || fail 'tmux fixture failed'
  i=0
  while [ ! -s "$TMP_ROOT/pid" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
  [ -s "$TMP_ROOT/pid" ] || fail 'stub never rendered its screen'
  pid=$(cat "$TMP_ROOT/pid")
  fm_write_meta "$TMP_ROOT/home/state/signin.meta" 'backend=tmux' "window=$target" 'endpoint_task_id=signin' 'harness=codex' 'kind=ship' "worktree=$TMP_ROOT/worktree" "project=$TMP_ROOT/project" 'mode=no-mistakes'
  rc=0
  out=$(PATH="$TMP_ROOT/bin:$ORIGINAL_PATH" FM_HOME="$TMP_ROOT/home" FM_CONTROL_POLL=0.1 FM_CONTROL_EXIT_WAIT=3 "$ROOT/bin/fm-control.sh" signin exit 2>&1) || rc=$?
  printf '%s exit=%s: %s\n' "$mode" "$rc" "$out"
  [ ! -s "$TMP_ROOT/keys" ] || fail 'control sent keys to sign-in'
  if [ "$mode" = signin ]; then
    [ "$rc" -eq 0 ] || fail 'sign-in exit failed'
    assert_contains "$out" 'stopped-sign-in signin' 'exit did not report signal stop'
    ! kill -0 "$pid" 2>/dev/null || fail 'sign-in process survived'
    out=$(PATH="$TMP_ROOT/bin:$ORIGINAL_PATH" FM_HOME="$TMP_ROOT/home" "$ROOT/bin/fm-control.sh" signin exit) || fail 'second exit was not idempotent'
    assert_contains "$out" 'already-stopped' 'second exit did not recognize a stopped agent'
  else
    [ "$rc" -ne 0 ] || fail "$mode unexpectedly accepted sign-in exit"
    kill -0 "$pid" || fail "$mode process was stopped despite refusal"
    kill -TERM "$pid"
  fi
  "$TMUX_BIN" -f /dev/null -L "$SOCKET" has-session -t fixture || fail 'exit removed the endpoint'
  kill -0 "$(cat "$TMP_ROOT/sentinel-pid")" || fail 'control stopped the unrelated Codex process'
  "$TMUX_BIN" -f /dev/null -L "$SOCKET" kill-window -t "$target"
  rm -f "$TMP_ROOT/pid" "$TMP_ROOT/keys"
done
pass 'sign-in control sent no keys and preserved terminal endpoints'
