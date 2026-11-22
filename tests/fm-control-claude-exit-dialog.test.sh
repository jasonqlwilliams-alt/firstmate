#!/usr/bin/env bash
# Claude's background-tasks exit confirmation must never receive a key.
# Lifecycle exit and the second-mate restart run against a compiled Claude
# stand-in on an isolated tmux server and against a stubbed styled Herdr
# transport; the steering doorbell runs against the same Herdr stub. Every
# write the stand-ins receive is logged, so a stray Enter or typed line fails
# the case. No vendor harness is launched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v cc >/dev/null || { echo 'skip: cc not found'; exit 0; }
command -v tmux >/dev/null || { echo 'skip: tmux not found'; exit 0; }
command -v jq >/dev/null || { echo 'skip: jq not found'; exit 0; }
command -v node >/dev/null || { echo 'skip: node not found'; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-claude-exit-dialog)
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/home/state" "$TMP_ROOT/home/data" "$TMP_ROOT/home/config"
printf 'claude\n' > "$TMP_ROOT/home/config/secondmate-harness"
fm_git_worktree "$TMP_ROOT/project" "$TMP_ROOT/worktree" fixture-task
printf 'exitdialog\n' > "$TMP_ROOT/worktree/.fm-secondmate-home"
mkdir -p "$TMP_ROOT/worktree/state"

# The real fm-send delivers the request, then the stand-in mate reads and
# acknowledges the inbox record. The replacement stub never launches an agent.
control_bin="$TMP_ROOT/control/bin"
mkdir -p "$control_bin"
for entry in "$ROOT/bin/"*; do
  case "${entry##*/}" in
    fm-send.sh|fm-spawn.sh) ;;
    *) ln -s "$entry" "$control_bin/${entry##*/}" ;;
  esac
done
cat > "$control_bin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
set -eu
"$FM_ROOT_OVERRIDE/bin/fm-send.sh" "$@"
if [ -n "${FM_PENDING_REPLY_EXISTING_CORR:-}" ]; then
  . "$FM_ROOT_OVERRIDE/bin/fm-task-inbox-lib.sh"
  inbox="$FM_STATE_OVERRIDE/$1.inbox"
  request=$(fm_task_inbox_body "$inbox/001.msg")
  [[ "$request" =~ corr=([0-9a-f]{16}) ]] || exit 1
  corr=${BASH_REMATCH[1]}
  mv "$inbox/001.msg" "$inbox/handled/001.msg"
  "$FM_ROOT_OVERRIDE/bin/fm-status-append.sh" "$FM_STATE_OVERRIDE/$1.status" \
    "done [corr=$corr]: open work written down"
fi
SH
cat > "$control_bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
: > "$FM_CONTROL_RELAUNCH_PREPARE/ready"
while [ ! -f "$FM_CONTROL_RELAUNCH_PREPARE/continue" ]; do sleep 0.05; done
exit 1
SH
chmod +x "$control_bin/fm-send.sh" "$control_bin/fm-spawn.sh"
ORIGINAL_PATH=$PATH
TMUX_BIN=$(command -v tmux)
SOCKET="fm-claude-exit-$$"
FIXTURE="$ROOT/tests/fixtures/claude-exit/background-tasks.screen"
cleanup() {
  local rc=$?
  trap - EXIT
  "$TMUX_BIN" -f /dev/null -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

{
  head -n 1 "$FIXTURE"
  for ((task=1; task<=24; task++)); do printf '   · Bash(timer %s) · running\n' "$task"; done
  tail -n +2 "$FIXTURE"
} > "$TMP_ROOT/long.screen"
{
  printf 'Update now (runs npm install)\nSkip until next version\nesc skip\n\n'
  cat "$FIXTURE"
} > "$TMP_ROOT/picker-history.screen"

# The stand-in draws a bare Claude composer and echoes typed input. A submitted
# /exit exits (mode plain) or draws the fixture dialog with a per-mode
# mutation; mode initial-dialog starts on the dialog. On the dialog an Enter
# confirms the selected choice and exits, like the vendor dialog. Doorbell
# lines (they start with ':') are not logged, so the log holds lifecycle input.
cat > "$TMP_ROOT/stub.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>
static const char *mode;
static void out(const char *s) { for (; *s; s++) { if (*s == '\n') fputs("\r\n", stdout); else putchar(*s); } }
static void composer(const char *typed) {
  printf("\033[2J\033[H");
  out("Claude stand-in transcript\n\n");
  out("\xe2\x9d\xaf ");
  out(typed);
  fflush(stdout);
}
static void dialog(const char *path) {
  FILE *f = fopen(path, "r"); char line[4096];
  if (!f) exit(2);
  printf("\033[2J\033[H");
  while (fgets(line, sizeof(line), f)) {
    if (!strcmp(mode, "no-heading") && strstr(line, "will stop when you exit")) continue;
    if (!strcmp(mode, "changed-heading") && strstr(line, "will stop when you exit")) {
      out(" The following unrelated processes will stop when you exit\n"); continue;
    }
    if (!strcmp(mode, "no-list") && strstr(line, "Bash(")) continue;
    if (!strcmp(mode, "no-stay") && strstr(line, "3. Stay")) continue;
    if (!strcmp(mode, "selection-on-2")) {
      if (strstr(line, "1. Exit and stop tasks")) { out("   1. Exit and stop tasks\n"); continue; }
      if (strstr(line, "2. Move to background and exit")) { out(" \xe2\x9d\xaf 2. Move to background and exit\n"); continue; }
    }
    if (!strcmp(mode, "relabeled") && strstr(line, "2. Move to background and exit")) { out("   2. Keep tasks running and exit\n"); continue; }
    out(line);
    if (!strcmp(mode, "extra-choice") && strstr(line, "3. Stay")) out("   4. Unidentified action\n");
  }
  fclose(f);
  if (!strcmp(mode, "history")) out("\n\xe2\x9d\xaf ");
  if (!strcmp(mode, "history-plain")) out("\nPress Enter to continue\n");
  fflush(stdout);
}
int main(int argc, char **argv) {
  if (argc == 2 && !strcmp(argv[1], "--version")) { puts("claude fixture"); return 0; }
  if (argc < 5) return 2;
  const char *pid_path = argv[1], *keys_path = argv[2], *screen = argv[4];
  mode = argv[3];
  struct termios t;
  if (tcgetattr(0, &t) == 0) { t.c_lflag &= ~(ICANON | ECHO); t.c_iflag &= ~ICRNL; tcsetattr(0, TCSANOW, &t); }
  char buf[256] = ""; size_t n = 0; int in_dialog = 0; char c;
  if (!strcmp(mode, "initial-dialog")) { in_dialog = 1; dialog(screen); } else composer(buf);
  FILE *f = fopen(pid_path, "w"); if (!f) return 2;
  fprintf(f, "%d\n", getpid()); fclose(f);
  while (read(0, &c, 1) == 1) {
    if (in_dialog || (n == 0 && c != ':') || (n > 0 && buf[0] != ':')) {
      f = fopen(keys_path, "a"); if (!f) return 2; fputc(c, f); fclose(f);
    }
    if (in_dialog) {
      if (c == '\r') return 0;
      if (c == 27) { in_dialog = 0; n = 0; buf[0] = 0; composer(buf); }
      continue;
    }
    if (c == '\r') {
      if (!strcmp(buf, "/exit")) {
        if (!strcmp(mode, "plain")) return 0;
        in_dialog = 1; dialog(screen); continue;
      }
      n = 0; buf[0] = 0; composer(buf); continue;
    }
    if (n + 1 < sizeof(buf)) { buf[n++] = c; buf[n] = 0; }
    composer(buf);
  }
  return 0;
}
C
cc -o "$TMP_ROOT/bin/claude" "$TMP_ROOT/stub.c" || fail 'could not compile the Claude stand-in'
cat > "$TMP_ROOT/bin/tmux" <<EOF
#!/usr/bin/env bash
exec "$TMUX_BIN" -f /dev/null -L "$SOCKET" "\$@"
EOF
chmod +x "$TMP_ROOT/bin/tmux"
stub_command() {  # <mode>
  local mode=$1 screen=$FIXTURE
  case "$mode" in
    picker-history) screen="$TMP_ROOT/picker-history.screen" ;;
    restart-initial) mode=initial-dialog; screen="$TMP_ROOT/long.screen" ;;
  esac
  printf '%q %q %q %q %q; exec /bin/bash --noprofile --norc' \
    "$TMP_ROOT/bin/claude" "$TMP_ROOT/pid" "$TMP_ROOT/keys" "$mode" "$screen"
}
"$TMUX_BIN" -f /dev/null -L "$SOCKET" new-session -d -s fixture -n sentinel -x 100 -y 40 \
  -c "$TMP_ROOT/worktree" /bin/bash --noprofile --norc || fail 'tmux fixture failed'
"$TMUX_BIN" -f /dev/null -L "$SOCKET" set-option -g automatic-rename off
"$TMUX_BIN" -f /dev/null -L "$SOCKET" set-option -g allow-rename off

run_fixture() {
  local command=$1
  shift
  PATH="$TMP_ROOT/bin:$ORIGINAL_PATH" FM_HOME="$TMP_ROOT/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CONTROL_POLL=0.1 FM_CONTROL_EXIT_WAIT=2 FM_SECONDMATE_PERSIST_POLL=1 FM_SECONDMATE_PERSIST_WAIT=5 \
    "$control_bin/$command" "$@"
}

for mode in restart-initial restart exit plain initial-dialog picker-history \
    no-heading changed-heading no-list no-stay selection-on-2 relabeled extra-choice history history-plain; do
  target=fixture:fm-exitdialog
  "$TMUX_BIN" -f /dev/null -L "$SOCKET" new-window -d -t fixture -n fm-exitdialog \
    -c "$TMP_ROOT/worktree" /bin/bash --noprofile --norc -c "$(stub_command "$mode")" \
    || fail 'tmux fixture failed'
  i=0
  while [ ! -s "$TMP_ROOT/pid" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
  [ -s "$TMP_ROOT/pid" ] || fail 'stand-in never rendered its screen'
  pid=$(cat "$TMP_ROOT/pid")
  fm_write_meta "$TMP_ROOT/home/state/exitdialog.meta" 'backend=tmux' "window=$target" \
    'endpoint_task_id=exitdialog' 'harness=claude' 'kind=secondmate' \
    "worktree=$TMP_ROOT/worktree" "project=$TMP_ROOT/project"
  : > "$TMP_ROOT/keys"
  rc=0
  if [[ "$mode" = restart* ]]; then
    out=$(run_fixture fm-secondmate-restart.sh exitdialog 2>&1) || rc=$?
  else
    out=$(run_fixture fm-control.sh exitdialog exit 2>&1) || rc=$?
  fi
  printf '%s exit=%s: %s\n' "$mode" "$rc" "$out"
  keys=$(od -An -c "$TMP_ROOT/keys" | tr -s ' ' | sed 's/^ //')
  screen=$("$TMUX_BIN" -f /dev/null -L "$SOCKET" capture-pane -p -t "$target" 2>/dev/null || true)
  case "$mode" in
    plain)
      [ "$rc" -eq 0 ] || fail "a plain exit failed: $out"
      [ "$keys" = '/ e x i t \r' ] || fail "a plain exit sent other keys: $keys"
      ! kill -0 "$pid" 2>/dev/null || fail 'stand-in survived a plain exit'
      ;;
    restart*|exit|initial-dialog|picker-history)
      [ "$rc" -ne 0 ] || fail "$mode reported success with the dialog open"
      assert_contains "$out" 'background-tasks exit confirmation' "$mode did not name the open dialog"
      assert_contains "$screen" '❯ 1. Exit and stop tasks' "$mode did not leave the dialog open"
      expected='/ e x i t \r'
      case "$mode" in initial-dialog|restart-initial) expected='' ;; esac
      [ "$keys" = "$expected" ] || fail "$mode expected '$expected', received '$keys'"
      kill -0 "$pid" 2>/dev/null || fail "$mode stopped the agent"
      if [ "$mode" = picker-history ]; then
        assert_contains "$screen" 'esc skip' 'tmux did not retain the earlier picker text'
      fi
      if [[ "$mode" = restart* ]]; then
        expect_code 3 "$rc" 'the restart should report the mate unreached'
        assert_contains "$out" 'unreached: exitdialog:' 'the restart did not report the mate unreached'
      fi
      if [ "$mode" = restart-initial ]; then
        assert_contains "$screen" 'Bash(timer 24)' 'tmux did not show the long dialog'
        assert_absent "$TMP_ROOT/home/state/exitdialog.inbox" 'the restart queued a steer into the already-open dialog'
      elif [ "$mode" = restart ]; then
        delivered="$TMP_ROOT/home/state/exitdialog.inbox/handled/001.msg"
        assert_present "$delivered" 'the stand-in mate did not handle the durable save request'
        assert_contains "$(sed '1,/^--$/d' "$delivered")" 'stop every background shell task you started' \
          'the save request did not ask the mate to stop its background tasks'
      fi
      kill -TERM "$pid"
      ;;
    *)
      # Prove each blinded element was really blinded on screen, so a near-miss
      # case cannot pass vacuously against the full dialog.
      case "$mode" in
        no-heading) assert_not_contains "$screen" 'will stop when you exit' 'heading was not blinded' ;;
        changed-heading) assert_contains "$screen" 'The following unrelated processes will stop when you exit' 'heading was not changed' ;;
        no-list) assert_not_contains "$screen" 'Bash(' 'task listing was not blinded' ;;
        no-stay) assert_not_contains "$screen" '3. Stay' 'third choice was not blinded' ;;
        selection-on-2) assert_contains "$screen" '❯ 2. Move to background and exit' 'selection did not move' ;;
        relabeled) assert_not_contains "$screen" 'Move to background and exit' 'second choice was not relabeled' ;;
        extra-choice) assert_contains "$screen" '4. Unidentified action' 'extra choice was not drawn' ;;
        history) assert_contains "$screen" '3. Stay' 'history case lost the dialog' ;;
        history-plain) assert_contains "$screen" 'Press Enter to continue' 'later prompt was not drawn' ;;
      esac
      [ "$rc" -ne 0 ] || fail "$mode unexpectedly reported a stopped agent"
      assert_contains "$out" 'did not stop within' "$mode was recognized as the exact dialog"
      [ "$keys" = '/ e x i t \r' ] || fail "$mode received keys after the exit command: $keys"
      kill -0 "$pid" 2>/dev/null || fail "$mode stand-in was stopped"
      kill -TERM "$pid"
      ;;
  esac
  "$TMUX_BIN" -f /dev/null -L "$SOCKET" has-session -t fixture || fail 'exit removed the terminal session'
  "$TMUX_BIN" -f /dev/null -L "$SOCKET" kill-window -t "$target"
  rm -f "$TMP_ROOT/pid" "$TMP_ROOT/keys" "$TMP_ROOT/home/state/exitdialog.meta"
done
pass 'tmux exit and restart leave the exact dialog untouched and report it; near misses stay unrecognized'

# A styled Herdr transport, where the selected `❯ 1.` row is bold like typed
# composer text. Every send is logged before the stub decides its effect.
cat > "$TMP_ROOT/bin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
phase=$(cat "$FM_DIALOG_CASE/phase")
case "$1 $2" in
  'status --json')
    printf '%s\n' '{"client":{"protocol":20,"version":"fixture"},"server":{"running":true,"protocol":20,"version":"fixture"}}'
    ;;
  'pane get')
    jq -cn --arg cwd "$FM_DIALOG_HOME" '{result:{pane:{pane_id:"p1",terminal_id:"term-claude",cwd:$cwd}}}'
    ;;
  'agent get')
    case "$phase" in
      stopped)
        if [ "$FM_DIALOG_MODE" = single-stop ]; then
          printf 'stop-unreadable\n' > "$FM_DIALOG_CASE/phase"
        fi
        printf '%s\n' '{"error":{"code":"agent_not_found"}}'
        ;;
      stop-unreadable) exit 1 ;;
      *) printf '%s\n' '{"result":{"agent":{"agent_status":"idle"}}}' ;;
    esac
    ;;
  'pane process-info')
    case "$phase:$FM_DIALOG_MODE" in
      stopped:*) printf '%s\n' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"p1","shell_pid":12345,"foreground_processes":[]}}}' ;;
      dialog:dialog-unreadable) exit 1 ;;
      *) printf '%s\n' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"p1","shell_pid":12345,"foreground_processes":[{"pid":23456,"name":"claude","argv":["claude"],"cmdline":"claude"}]}}}' ;;
    esac
    ;;
  'pane read')
    styled=0
    case " $* " in *' --format ansi '*) styled=1 ;; esac
    case "$phase" in
      dialog)
        [ "$FM_DIALOG_MODE:$styled" != doorbell-after-long:1 ] || exit 1
        while IFS= read -r line; do
          case "$styled:$line" in
            1:*❯*) printf '\033[1m%s\033[0m\n' "$line" ;;
            *) printf '%s\n' "$line" ;;
          esac
        done < "$FM_DIALOG_FIXTURE"
        ;;
      typed|retry) printf 'Claude\n\033[1m❯ /exit\033[0m\n' ;;
      stopped) printf '$ \n' ;;
      *) printf 'Claude\n❯ \n' ;;
    esac
    ;;
  'pane send-text')
    printf '%s\n' "$4" >> "$FM_DIALOG_CASE/input"
    case "$FM_DIALOG_MODE:$4" in
      doorbell-after*:*) printf 'dialog\n' > "$FM_DIALOG_CASE/phase" ;;
      *:/exit) printf 'typed\n' > "$FM_DIALOG_CASE/phase" ;;
    esac
    ;;
  'pane send-keys')
    printf '%s\n' "$4" >> "$FM_DIALOG_CASE/input"
    [ "$4" = enter ] || exit 0
    case "$phase:$FM_DIALOG_MODE" in
      typed:retry) printf 'retry\n' ;;
      typed:retry-failure) printf 'retry\n'; exit 1 ;;
      typed:single-stop) printf 'stopped\n' ;;
      typed:*) printf 'dialog\n' ;;
      composer:*) printf 'composer\n' ;;
      *) printf 'stopped\n' ;;
    esac > "$FM_DIALOG_CASE/phase"
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$TMP_ROOT/bin/herdr"
meta="$TMP_ROOT/home/state/exitdialog.meta"
fm_write_meta "$meta" 'backend=herdr' 'window=fixture:p1' 'endpoint_task_id=exitdialog' \
  'harness=claude' 'kind=secondmate' "worktree=$TMP_ROOT/worktree" "project=$TMP_ROOT/project" \
  'herdr_session=fixture' 'herdr_workspace_id=w1' 'herdr_tab_id=t1' 'herdr_pane_id=p1' 'herdr_terminal_id=term-claude'
export FM_DIALOG_HOME="$TMP_ROOT/worktree"
for mode in dialog long-dialog picker-history dialog-unreadable retry retry-failure single-stop doorbell-before doorbell-after \
    doorbell-after-long doorbell-before-picker; do
  export FM_DIALOG_MODE="$mode" FM_DIALOG_CASE="$TMP_ROOT/herdr-$mode"
  case "$mode" in
    long-dialog|doorbell-after-long) export FM_DIALOG_FIXTURE="$TMP_ROOT/long.screen" ;;
    picker-history|doorbell-before-picker) export FM_DIALOG_FIXTURE="$TMP_ROOT/picker-history.screen" ;;
    *) export FM_DIALOG_FIXTURE="$FIXTURE" ;;
  esac
  mkdir "$FM_DIALOG_CASE"
  printf 'composer\n' > "$FM_DIALOG_CASE/phase"
  : > "$FM_DIALOG_CASE/input"
  rc=0
  case "$mode" in
    doorbell-*)
      case "$mode" in doorbell-before*) printf 'dialog\n' > "$FM_DIALOG_CASE/phase" ;; esac
      rec="$FM_DIALOG_CASE/001.msg"
      printf 'schema=fm-task-inbox.v1\n--\nreview the open records\n' > "$rec"
      PATH="$TMP_ROOT/bin:$ORIGINAL_PATH" FM_BACKEND_HERDR_ENDPOINT_META="$meta" \
        bash -c '. "$1"; fm_task_inbox_ring herdr fixture:p1 "$2" fm-exitdialog claude-latest' \
        _ "$ROOT/bin/fm-task-inbox-lib.sh" "$rec" || rc=$?
      if [[ "$mode" = doorbell-before* ]]; then
        expect_code 1 "$rc" 'the dialog should prevent typing the doorbell'
        [ ! -s "$FM_DIALOG_CASE/input" ] || fail "the doorbell wrote into the dialog: $(cat "$FM_DIALOG_CASE/input")"
      else
        expect_code 5 "$rc" 'the dialog should prevent submitting the doorbell'
        assert_contains "$(cat "$FM_DIALOG_CASE/input")" 'Firstmate instruction waiting' 'the composer did not receive the doorbell text'
        [ "$(wc -l < "$FM_DIALOG_CASE/input")" -eq 1 ] || fail "the doorbell wrote to the dialog after typing: $(cat "$FM_DIALOG_CASE/input")"
      fi
      continue
      ;;
  esac
  out=$(run_fixture fm-control.sh exitdialog exit 2>&1) || rc=$?
  printf 'herdr %s exit=%s: %s\n' "$mode" "$rc" "$out"
  input=$(cat "$FM_DIALOG_CASE/input")
  case "$mode" in
    dialog|long-dialog|picker-history|dialog-unreadable)
      [ "$rc" -ne 0 ] || fail 'the styled Herdr dialog reported a stopped agent'
      assert_contains "$out" 'background-tasks exit confirmation' 'the styled Herdr dialog was not recognized'
      [ "$input" = $'/exit\nenter' ] || fail "the styled Herdr dialog received another key: $input"
      [ "$(cat "$FM_DIALOG_CASE/phase")" = dialog ] || fail 'the dialog did not stay open'
      if [ "$mode" = dialog-unreadable ]; then
        assert_contains "$out" 'agent-state=unreadable' 'the dialog refusal lost the observed liveness'
      fi
      ;;
    retry|retry-failure)
      expect_code 0 "$rc" 'Herdr should retry a swallowed Enter while the composer still holds /exit'
      [ "$input" = $'/exit\nenter\nenter' ] || fail "the proven pending command should be submitted once more: $input"
      ;;
    single-stop)
      expect_code 0 "$rc" 'one verified stop should complete exit'
      [ "$(cat "$FM_DIALOG_CASE/phase")" = stop-unreadable ] || fail 'the one stop sample was not consumed'
      [ "$input" = $'/exit\nenter' ] || fail "the ordinary stop sent unexpected input: $input"
      ;;
  esac
done
pass 'styled Herdr exit retries only a proven pending command, and exit and doorbell send no key to the dialog'

cat > "$TMP_ROOT/bin/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -eu
while [ "$1" = -o ]; do shift 2; done
shift 3
decode() { printf '%s' "$1" | base64 --decode 2>/dev/null || printf '%s' "$1" | base64 -D; }
args=()
while IFS= read -r -d '' arg; do args+=("$arg"); done < <(decode "$4")
printf '%s\n' "${args[*]}" >> "$FM_DIALOG_CASE/remote"
FM_HOME="$FM_DIALOG_HOME" "$FM_ROOT_OVERRIDE/bin/${args[0]}" "${args[@]:1}"
SH
chmod +x "$TMP_ROOT/bin/fake-ssh"
export FM_DIALOG_MODE=remote-restart FM_DIALOG_CASE="$TMP_ROOT/remote-restart" FM_DIALOG_FIXTURE="$TMP_ROOT/long.screen"
mkdir "$FM_DIALOG_CASE" "$FM_DIALOG_HOME/bin" "$FM_DIALOG_HOME/state/parent-route"
: > "$FM_DIALOG_HOME/AGENTS.md"
printf 'dialog\n' > "$FM_DIALOG_CASE/phase"
fm_write_meta "$FM_DIALOG_HOME/state/parent-route/exitdialog.meta" 'backend=herdr' 'window=fm-remote:p1' \
  'endpoint_task_id=exitdialog' 'harness=claude' 'kind=secondmate' "worktree=$FM_DIALOG_HOME" "project=$FM_DIALOG_HOME" \
  'herdr_session=fm-remote' 'herdr_workspace_id=w1' 'herdr_tab_id=t1' 'herdr_pane_id=p1' 'herdr_terminal_id=term-claude'
fm_write_meta "$meta" 'window=remote:exitdialog' 'endpoint_task_id=exitdialog' 'harness=claude' \
  'kind=secondmate' 'remote_host=fixture-host' 'remote_backend=herdr' "worktree=$FM_DIALOG_HOME" "project=$FM_DIALOG_HOME"
printf -- '- exitdialog - fixture (host: fixture-host; root: %s; home: %s; scope: test; projects: fixture; added 2026-09-03)\n' \
  "$ROOT" "$FM_DIALOG_HOME" > "$TMP_ROOT/home/data/secondmates.md"
rc=0
out=$(FM_SSH_BIN="$TMP_ROOT/bin/fake-ssh" run_fixture fm-secondmate-restart.sh exitdialog 2>&1) || rc=$?
expect_code 3 "$rc" "the remote restart should report the mate unreached: $out"
assert_contains "$out" 'unreached: exitdialog: Claude is showing its background-tasks exit confirmation' \
  'the remote restart did not name the open dialog'
assert_absent "$FM_DIALOG_HOME/state/parent-route/exitdialog.inbox" 'remote restart queued a steer into the already-open dialog'
assert_absent "$FM_DIALOG_CASE/input" 'remote restart sent terminal input into the dialog'
pass 'remote restart observes the already-open dialog on its bound host and reports the mate unreached'

cat > "$TMP_ROOT/bin/viewport-stub" <<'SH'
#!/usr/bin/env bash
set -eu
case "${0##*/}:$1" in
  cmux:list-panes) printf '%s\n' '{"panes":[{"surface_ids":["surface"]}]}' ;;
  cmux:read-screen) jq -n --rawfile screen "$FM_DIALOG_FIXTURE" '{text: $screen}' ;;
  zellij:list-sessions) printf 'fixture\n' ;;
  zellij:--session)
    case "$4" in
      list-panes) printf '%s\n' '[{"id":1,"is_plugin":false}]' ;;
      dump-screen)
        case "$FM_DIALOG_MODE: $* " in zellij-plain:*' --ansi '*) exit 1 ;; esac
        cat "$FM_DIALOG_FIXTURE"
        ;;
      paste|send-keys) printf '%s\n' "$4" >> "$FM_DIALOG_CASE/input" ;;
      *) exit 1 ;;
    esac
    ;;
  orca:terminal)
    case "$2" in
      read)
        if [ "$5" = --screen ]; then
          jq -n --rawfile screen "$FM_DIALOG_FIXTURE" '{result:{terminal:{source:"screen",tail:($screen|split("\n"))}}}'
        else
          tail -n "$6" "$FM_DIALOG_FIXTURE" | jq -Rs '{result:{terminal:{source:"stream",tail:split("\n")}}}'
        fi
        ;;
      send) printf '%s\n' "$2" >> "$FM_DIALOG_CASE/input"; printf '%s\n' '{"ok":true}' ;;
      *) exit 1 ;;
    esac
    ;;
  cmux:send|cmux:send-key) printf '%s\n' "$1" >> "$FM_DIALOG_CASE/input" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$TMP_ROOT/bin/viewport-stub"
for backend in cmux zellij orca; do ln -s viewport-stub "$TMP_ROOT/bin/$backend"; done
for mode in cmux zellij zellij-plain orca; do
  export FM_DIALOG_MODE="$mode" FM_DIALOG_CASE="$TMP_ROOT/capture-$mode"
  mkdir "$FM_DIALOG_CASE"
  case "$mode" in
    cmux) backend=cmux; target=workspace:surface ;;
    zellij*) backend=zellij; target=fixture:1 ;;
    orca) backend=orca; target=term-claude ;;
  esac
  rec="$FM_DIALOG_CASE/001.msg"
  printf 'schema=fm-task-inbox.v1\n--\nreview the open records\n' > "$rec"
  rc=0
  PATH="$TMP_ROOT/bin:$ORIGINAL_PATH" bash -c '. "$1"; fm_task_inbox_ring "$2" "$3" "$4" "" claude' \
    _ "$ROOT/bin/fm-task-inbox-lib.sh" "$backend" "$target" "$rec" || rc=$?
  expect_code 1 "$rc" "$mode should block the doorbell on a dialog with 26 task rows"
  assert_absent "$FM_DIALOG_CASE/input" "$mode sent terminal input to the long dialog"
done
pass 'cmux, styled and plain Zellij, and Orca refuse doorbell input into a long Claude dialog'
