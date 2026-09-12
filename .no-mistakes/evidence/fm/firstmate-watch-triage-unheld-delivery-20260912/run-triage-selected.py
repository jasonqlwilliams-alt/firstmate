#!/usr/bin/env python3
"""Execute selected existing behavioral tests, preserving real watcher output."""
import os, pathlib, re, subprocess, sys
root = pathlib.Path(sys.argv[1]).resolve()
evidence = pathlib.Path(sys.argv[2]).resolve()
label = sys.argv[3]
selectors = sys.argv[4:]
source = root / "tests/fm-watch-triage.test.sh"
# Load unchanged definitions, stopping before the suite's unconditional invocation list.
lines = source.read_text().splitlines(keepends=True)
stop = next(i for i, line in enumerate(lines) if re.fullmatch(r"test_[a-z0-9_]+\n", line))
body = "".join(lines[:stop])
body = body.replace('"$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"', '"' + str(root / 'tests/wake-helpers.sh') + '"', 1)
body += r'''
# Slow only the test terminal seam; production source remains unchanged.
if [ -n "${FM_EVIDENCE_CAPTURE_DELAY:-}" ]; then
  eval "$(declare -f make_case | sed '1s/make_case/make_case_original/')"
  make_case() {
    local dir
    dir=$(make_case_original "$1") || return 1
    mv "$dir/fakebin/tmux" "$dir/fakebin/tmux-original"
    cat > "$dir/fakebin/tmux" <<'DELAY'
#!/usr/bin/env bash
if [ "${1:-}" = capture-pane ]; then sleep "${FM_EVIDENCE_CAPTURE_DELAY:?}"; fi
exec "$(dirname "$0")/tmux-original" "$@"
DELAY
    chmod +x "$dir/fakebin/tmux"
    printf '%s\n' "$dir"
  }
  printf 'Controlled terminal capture delay: %ss per capture\n' "$FM_EVIDENCE_CAPTURE_DELAY"
fi
# Negative control: execute a real watcher that correctly absorbs a repeated hold.
test_evidence_surface_rejects_absorption() {
  local dir state out capture rc cycles
  dir=$(make_hold_home expected-absorption 'done: PR https://example.invalid/pull/1 checks green' hold) || fail 'cannot build held fixture'
  state="$dir/state"; out="$dir/watch.out"; capture="$dir/pane.txt"
  hold_watch_surface "$dir" "$out" "$capture" 'idle, initial sight' || fail 'initial held sight did not surface'
  ack_stopped_cycle "$state" || fail 'could not acknowledge first held sight'
  hold_watch_surface "$dir" "$out" "$capture" 'idle, repeated sight'
  rc=$?
  [ "$rc" -eq 1 ] || fail "surface helper accepted real absorption: exit=$rc"
  [ "$(hold_stale_wakes "$state")" -eq 0 ] || fail 'absorbed repeat unexpectedly queued a wake'
  kill -0 "$HOLD_WATCH_PID" 2>/dev/null && fail 'surface helper leaked watcher after rejecting absorption'
  printf 'Expected rejection: surface helper exit=%s after bounded polls; queue empty; child reaped.\n' "$rc"
  pass 'surface wait tolerates slow alarms but rejects a watcher that keeps absorbing'
}
# Preserve the public queue contract before the existing acknowledgement removes it.
eval "$(declare -f ack_stopped_cycle | sed '1s/ack_stopped_cycle/ack_stopped_cycle_original/')"
ack_stopped_cycle() {
  printf '\nQUEUED NOTIFICATION BEFORE ACK (%s):\n' "${1%/state}"
  cat "$1/.wake-queue"
  ack_stopped_cycle_original "$@"
}
capture_evidence() {
  local rc=$? d f
  for d in "$TMP_ROOT"/*; do
    [ -d "$d" ] || continue
    printf '\nCASE %s\n' "${d##*/}"
    for f in watch.out state/.wake-queue state/.watch-triage.log data/backlog.md; do
      if [ -f "$d/$f" ]; then
        printf '\n--- %s ---\n' "$f"
        cat "$d/$f"
      fi
    done
  done
  [ -z "${HOLD_WATCH_PID:-}" ] || reap "$HOLD_WATCH_PID"
  fm_test_cleanup
  exit "$rc"
}
trap capture_evidence EXIT
'''
for selector in selectors:
    if not re.fullmatch(r'test_[a-z0-9_]+', selector):
        raise SystemExit('invalid selector')
    body += selector + "\n"
env = os.environ.copy()
env['FM_TEST_SKIP_ORPHAN_REAP'] = '1'
log = evidence / (label + '.log')
with log.open('w') as output:
    result = subprocess.run(['bash'], input=body, text=True, cwd=root, env=env, stdout=output, stderr=subprocess.STDOUT)
print(f'{label}: exit={result.returncode}; transcript={log}', flush=True)
print(log.read_text(), end='')
raise SystemExit(result.returncode)
