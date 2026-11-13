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
#include <stdlib.h>
static void render(const char *path, const char *mode) {
  FILE *f = fopen(path, "r"); char line[4096];
  if (!f) exit(2);
  while (fgets(line, sizeof(line), f)) {
    if (!strcmp(mode, "unknown-choice") && strstr(line, "Press Enter to continue")) fputs("4. Unidentified action\r\n", stdout);
    if (!strcmp(mode, "legacy-two-choice") && strstr(line, "Sign in with Device Code")) continue;
    if (!strcmp(mode, "legacy-two-choice") && strstr(line, "3. Provide your own API key")) {
      fputs("  2. Provide your own API key\r\n", stdout); continue;
    }
    if ((strstr(mode, "no-brand") || !strcmp(mode, "no-context")) && strstr(line, "Welcome to Codex")) continue;
    if ((strstr(mode, "no-explanation") || !strcmp(mode, "no-context")) &&
        (strstr(line, "Sign in with ChatGPT to use Codex as part") || strstr(line, "Choose how you want to use Codex"))) continue;
    for (char *p=line; *p; p++) { if (*p=='\n') fputs("\r\n", stdout); else putchar(*p); }
  }
  fclose(f);
}
int main(int argc, char **argv) {
  if (argc == 2 && !strcmp(argv[1], "--version")) { puts("codex-cli fixture"); return 0; }
  const char *pid_path = argc > 1 ? argv[1] : getenv("FM_SIGNIN_GUARD_PID");
  const char *keys_path = argc > 2 ? argv[2] : getenv("FM_SIGNIN_GUARD_KEYS");
  const char *mode = argc > 3 ? argv[3] : getenv("FM_SIGNIN_GUARD_MODE");
  if (!mode) mode = "current";
  const char *screen = argc > 4 ? argv[4] : getenv("FM_SIGNIN_GUARD_SCREEN");
  if (!pid_path || !keys_path || !screen) return 2;
  struct termios t;
  if (tcgetattr(0, &t) == 0) { t.c_lflag &= ~(ICANON | ECHO); tcsetattr(0, TCSANOW, &t); }
  printf("\033[2J\033[H");
  if (!strcmp(mode, "unknown")) printf("Welcome to Codex\r\nUnidentified setup dialog\r\n");
  else if (!strcmp(mode, "update")) {
    printf("Update available · 0.162.1 → 0.999.0\r\n› 1. Update now (runs `npm install -g @openai/codex`)\r\n2. Skip\r\n3. Skip until next version\r\nenter continue · esc skip\r\n");
  } else if (!strcmp(mode, "missing-choice")) {
    printf("Welcome to Codex\r\nSign in with ChatGPT to use Codex as part of your paid plan\r\n1. Sign in with ChatGPT\r\nPress Enter to continue\r\n");
  } else {
    render(screen, mode);
    if (!strcmp(mode, "history") || !strcmp(mode, "history-footer")) printf("\r\n> Unidentified next screen\r\n");
    if (!strcmp(mode, "history-footer")) printf("Press Enter to continue\r\n");
  }
  fflush(stdout);
  FILE *f = fopen(pid_path, "w"); if (!f) return 2;
  fprintf(f, "%d\n", getpid()); fclose(f);
  if (!strcmp(mode, "crash")) return 2;
  char c;
  while (read(0, &c, 1) == 1) { f = fopen(keys_path, "a"); if (!f) return 2; fputc(c, f); fclose(f); }
  return 0;
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
  printf '%q %q %q %q %q; exec /bin/bash --noprofile --norc' \
    "$TMP_ROOT/bin/$1" "$TMP_ROOT/$2" "$TMP_ROOT/$3" "$4" "$5"
}
"$TMUX_BIN" -f /dev/null -L "$SOCKET" new-session -d -s fixture -n sentinel \
  -c "$TMP_ROOT/worktree" /bin/bash --noprofile --norc -c \
  "$(stub_command codex sentinel-pid sentinel-keys legacy "$ROOT/tests/fixtures/codex-signin-legacy.screen")" || fail 'tmux fixture failed'
"$TMUX_BIN" -f /dev/null -L "$SOCKET" set-option -g automatic-rename off
"$TMUX_BIN" -f /dev/null -L "$SOCKET" set-option -g allow-rename off
for mode in legacy legacy-two-choice current legacy-no-brand current-no-brand legacy-no-explanation current-no-explanation no-context unknown unknown-choice update history history-footer missing-choice wrong-process; do
  target=fixture:fm-signin
  binary=codex
  fixture="$ROOT/tests/fixtures/codex-signin-legacy.screen"
  case "$mode" in current*|no-context) fixture="$ROOT/tests/fixtures/codex-signin-0.167.2.screen" ;; esac
  expected_stop=0
  case "$mode" in legacy|legacy-two-choice|current|*-no-brand|*-no-explanation) expected_stop=1 ;; esac
  if [ "$mode" = wrong-process ]; then
    cp "$TMP_ROOT/bin/codex" "$TMP_ROOT/bin/claude"
    binary=claude
  fi
  "$TMUX_BIN" -f /dev/null -L "$SOCKET" new-window -d -t fixture -n fm-signin \
    -c "$TMP_ROOT/worktree" /bin/bash --noprofile --norc -c \
    "$(stub_command "$binary" pid keys "$mode" "$fixture")" || fail 'tmux fixture failed'
  i=0
  while [ ! -s "$TMP_ROOT/pid" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
  [ -s "$TMP_ROOT/pid" ] || fail 'stub never rendered its screen'
  pid=$(cat "$TMP_ROOT/pid")
  case "$mode" in
    legacy-two-choice|*-no-brand|*-no-explanation|no-context)
      i=0; observed=''
      while [ "$i" -lt 100 ]; do
        observed=$("$TMUX_BIN" -f /dev/null -L "$SOCKET" capture-pane -p -t "$target")
        case "$observed" in *'Press Enter to continue'*|*'Press enter to continue'*) break ;; esac
        sleep 0.1; i=$((i+1))
      done
      if [ "$mode" = legacy-two-choice ]; then
        assert_contains "$observed" '2. Provide your own API key' 'two-choice fixture did not render its API alternative'
        assert_not_contains "$observed" 'Sign in with Device Code' 'two-choice fixture retained its device alternative'
      else
        assert_contains "$observed" 'Sign in with Device Code' 'signal-blinding fixture did not render its choices'
      fi
      case "$mode" in
        *-no-brand|no-context) assert_not_contains "$observed" 'Welcome to Codex' 'brand signal was not actually blinded' ;;
        *) assert_contains "$observed" 'Welcome to Codex' 'independent brand signal was lost' ;;
      esac
      explanation='Sign in with ChatGPT to use Codex as part of your paid plan'
      case "$mode" in current*|no-context) explanation='Choose how you want to use Codex.' ;; esac
      case "$mode" in
        *-no-explanation|no-context) assert_not_contains "$observed" "$explanation" 'explanation signal was not actually blinded' ;;
        *) assert_contains "$observed" "$explanation" 'independent explanation signal was lost' ;;
      esac
      ;;
  esac
  fm_write_meta "$TMP_ROOT/home/state/signin.meta" 'backend=tmux' "window=$target" 'endpoint_task_id=signin' 'harness=codex' 'kind=ship' "worktree=$TMP_ROOT/worktree" "project=$TMP_ROOT/project" 'mode=no-mistakes'
  rc=0
  out=$(PATH="$TMP_ROOT/bin:$ORIGINAL_PATH" FM_HOME="$TMP_ROOT/home" FM_CONTROL_POLL=0.1 FM_CONTROL_EXIT_WAIT=3 "$ROOT/bin/fm-control.sh" signin exit 2>&1) || rc=$?
  printf '%s exit=%s: %s\n' "$mode" "$rc" "$out"
  [ ! -s "$TMP_ROOT/keys" ] || fail 'control sent keys to sign-in'
  if [ "$expected_stop" -eq 1 ]; then
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
pass 'captured legacy/current sign-in screens and independent signals stop without keys; uncertain screens remain protected'

# Exercise the live guard itself with a compiled stand-in. No installed vendor
# CLI is reached, including if its opt-in policy regresses.
GUARD="$ROOT/tests/fm-codex-signin-live-e2e.test.sh"
mkdir -p "$TMP_ROOT/guard-bin" "$TMP_ROOT/guard-user"
cp "$TMP_ROOT/bin/codex" "$TMP_ROOT/guard-bin/codex"
guard_out=$(env -u FM_LIVE -u FM_CODEX_SIGNIN_LIVE \
  PATH="$TMP_ROOT/guard-bin:$ORIGINAL_PATH" HOME="$TMP_ROOT/guard-user" \
  FM_SIGNIN_GUARD_PID="$TMP_ROOT/guard-default.pid" \
  "$ROOT/bin/fm-test-run.sh" "$GUARD") || fail 'default live guard did not skip'
assert_contains "$guard_out" 'skip: live: opt-in' 'live guard became default-on'
[ ! -e "$TMP_ROOT/guard-default.pid" ] || fail 'default guard launched its stand-in'
for guard_mode in legacy current update crash; do
  fixture="$ROOT/tests/fixtures/codex-signin-legacy.screen"
  [ "$guard_mode" != current ] || fixture="$ROOT/tests/fixtures/codex-signin-0.167.2.screen"
  rc=0
  guard_out=$(PATH="$TMP_ROOT/guard-bin:$ORIGINAL_PATH" HOME="$TMP_ROOT/guard-user" \
    FM_CODEX_SIGNIN_LIVE=1 FM_LIVE=0 FM_SIGNIN_GUARD_MODE="$guard_mode" \
    FM_SIGNIN_GUARD_SCREEN="$fixture" FM_SIGNIN_GUARD_PID="$TMP_ROOT/guard-$guard_mode.pid" \
    FM_SIGNIN_GUARD_KEYS="$TMP_ROOT/guard-$guard_mode.keys" \
    FM_CODEX_SIGNIN_CAPTURE="$TMP_ROOT/guard-$guard_mode.screen" \
    "$ROOT/bin/fm-test-run.sh" "$GUARD" 2>&1) || rc=$?
  printf '%s guard exit=%s\n%s\n' "$guard_mode" "$rc" "$guard_out"
  [ ! -s "$TMP_ROOT/guard-$guard_mode.keys" ] || fail 'live guard sent input to stand-in'
  [ -s "$TMP_ROOT/guard-$guard_mode.screen" ] || fail 'live guard omitted requested capture'
  if [ "$guard_mode" = update ]; then
    [ "$rc" -ne 0 ] || fail 'live guard accepted update picker'
    assert_contains "$guard_out" 'first screen is not a recognized sign-in chooser' 'update picker failure was not explicit'
  elif [ "$guard_mode" = crash ]; then
    [ "$rc" -ne 0 ] || fail 'live guard accepted a crashed stand-in'
    assert_contains "$guard_out" 'exact native PID could not be verified' 'crashed startup was not explicit'
    assert_not_contains "$guard_out" 'endpoint retained' 'dead startup leaked its private server'
  else
    [ "$rc" -eq 0 ] || fail 'live guard failed a recognized sign-in stand-in'
    assert_contains "$guard_out" 'private processes gone and global mtimes unchanged' 'guard omitted cleanup verification'
  fi
  guard_pid=$(cat "$TMP_ROOT/guard-$guard_mode.pid")
  ! kill -0 "$guard_pid" 2>/dev/null || fail 'live guard left its stand-in running'
done
pass 'live guard stays opt-in and proves no-input stop, refusal and cleanup with stand-ins'
