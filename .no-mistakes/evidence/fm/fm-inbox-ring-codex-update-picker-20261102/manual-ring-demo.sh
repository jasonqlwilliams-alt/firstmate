#!/usr/bin/env bash
set -euo pipefail
unset NO_MISTAKES_GATE
export FM_GATE_REFUSE_BYPASS=1
root=/home/jason/.no-mistakes/worktrees/e95238b70e4e/01M6DMYNE6YGKGM5Q18X606594
evidence=/home/jason/.no-mistakes/evidence/01M6DMYNE6YGKGM5Q18X606594
lab="$evidence/manual-ring"
rm -rf "$lab"
socket="fm-ring-evidence-$$"
mkdir -p "$lab/bin" "$lab/shim" "$lab/home/state"
: > "$lab/picker.keys"
: > "$lab/empty.keys"
tmux_bin=$(command -v tmux)
bash_bin=$(command -v bash)
printf '#!/usr/bin/env bash\nexec "%s" -L "%s" "$@"\n' "$tmux_bin" "$socket" > "$lab/shim/tmux"
chmod +x "$lab/shim/tmux"
ln -sf "$bash_bin" "$lab/bin/codex"
cat > "$lab/screen-stub.sh" <<'STUB'
mode=$1 log=$2 buf=
old=$(stty -g 2>/dev/null || true)
stty -echo -icanon min 1 time 0 2>/dev/null || true
trap '[ -z "$old" ] || stty "$old" 2>/dev/null' EXIT
draw() {
  printf '\033[2J\033[H'
  if [ "$mode" = picker ]; then
    printf '%s\r\n' '  Update available · 0.162.1 → 0.999.0' \
      '  Release notes: https://github.com/openai/codex/releases/latest' '' \
      '› 1. Update now (runs `npm install -g @openai/codex`)' '  2. Skip' \
      '  3. Skip until next version' '' '  enter continue · esc skip'
  else
    printf '%s\r\n' '>_ Codex-shaped test stub' ''
    if [ -z "$buf" ]; then
      printf '› \033[2mAsk Codex to do anything\033[0m\r\n\r\n  \033[2m100%% context left\033[0m\033[3;3H'
    else
      shown=$buf
      [ "$mode" != missing-space ] || shown=${buf/instruction waiting/instructionwaiting}
      printf '› %s\r\n\r\n  \033[2m100%% context left\033[0m\033[3;%dH' "$shown" "$((3 + ${#shown}))"
    fi
  fi
}
draw
while IFS= read -r -n 1 ch; do
  if [ -z "$ch" ]; then
    printf 'ENTER\n' >> "$log"
    printf 'SUBMIT %s\n' "$buf" >> "$log"
    if [[ $buf =~ list\ \'([^\']+)\'/\*\.msg ]]; then
      for f in "${BASH_REMATCH[1]}"/*.msg; do
        [ ! -e "$f" ] || mv "$f" "${BASH_REMATCH[1]}/handled/"
      done
    fi
    buf=
  else
    printf 'KEY\n' >> "$log"
    [ "$mode" != empty ] || buf="$buf$ch"
  fi
  draw
done
STUB
cleanup() { "$tmux_bin" -L "$socket" kill-server >/dev/null 2>&1 || true; }
trap cleanup EXIT
"$tmux_bin" -L "$socket" new-session -d -s ring -x 240 -y 40
"$tmux_bin" -L "$socket" new-window -d -t ring: -n picker -- "$lab/bin/codex" "$lab/screen-stub.sh" picker "$lab/picker.keys"
for i in $(seq 1 50); do
  "$tmux_bin" -L "$socket" capture-pane -p -t ring:picker | rg -q 'esc skip' && break
  sleep 0.1
done
"$tmux_bin" -L "$socket" capture-pane -p -t ring:picker > "$lab/picker-screen.txt"
printf 'window=ring:picker\nbackend=tmux\nkind=ship\nharness=codex\n' > "$lab/home/state/p1.meta"
printf '%s\n' 'PICKER SCREEN (private tmux pane; Codex process is a bash symlink):'
cat "$lab/picker-screen.txt"
printf '%s\n' 'PICKER SEND:'
PATH="$lab/shim:$PATH" FM_HOME="$lab/home" "$root/bin/fm-send.sh" p1 'please continue' 2>&1
printf 'terminal keys received: %s\n' "$(wc -l < "$lab/picker.keys" 2>/dev/null || printf 0)"
printf 'unhandled record: %s\n' "$(test -f "$lab/home/state/p1.inbox/001.msg" && printf present || printf absent)"
"$tmux_bin" -L "$socket" new-window -d -t ring: -n empty -- "$lab/bin/codex" "$lab/screen-stub.sh" empty "$lab/empty.keys"
for i in $(seq 1 50); do
  "$tmux_bin" -L "$socket" capture-pane -p -t ring:empty | rg -q 'context left' && break
  sleep 0.1
done
printf 'window=ring:empty\nbackend=tmux\nkind=ship\nharness=codex\n' > "$lab/home/state/e1.meta"
printf '%s\n' 'EMPTY COMPOSER SEND:'
PATH="$lab/shim:$PATH" FM_HOME="$lab/home" "$root/bin/fm-send.sh" e1 'please continue' 2>&1
for i in $(seq 1 50); do
  test ! -e "$lab/home/state/e1.inbox/001.msg" && break
  sleep 0.1
done
printf 'Enter count: %s\n' "$(rg -c '^ENTER$' "$lab/empty.keys" || printf 0)"
rg '^SUBMIT ' "$lab/empty.keys"
printf 'handled record: %s\n' "$(test -f "$lab/home/state/e1.inbox/handled/001.msg" && printf present || printf absent)"

"$tmux_bin" -L "$socket" new-window -d -t ring: -n missing -- "$lab/bin/codex" "$lab/screen-stub.sh" missing-space "$lab/missing.keys"
for i in $(seq 1 50); do
  "$tmux_bin" -L "$socket" capture-pane -p -t ring:missing | rg -q 'context left' && break
  sleep 0.1
done
printf 'window=ring:missing\nbackend=tmux\nkind=ship\nharness=codex\n' > "$lab/home/state/m1.meta"
printf '%s\n' 'MISSING INTERIOR SPACE AFTER TYPING:'
PATH="$lab/shim:$PATH" FM_HOME="$lab/home" "$root/bin/fm-send.sh" m1 'please continue' 2>&1
printf 'typed key count: %s\n' "$(rg -c '^KEY$' "$lab/missing.keys" || printf 0)"
printf 'Enter count: %s\n' "$(rg -c '^ENTER$' "$lab/missing.keys" || printf 0)"
printf 'unhandled record: %s\n' "$(test -f "$lab/home/state/m1.inbox/001.msg" && printf present || printf absent)"
