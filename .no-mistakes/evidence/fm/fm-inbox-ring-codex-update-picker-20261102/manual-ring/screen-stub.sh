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
