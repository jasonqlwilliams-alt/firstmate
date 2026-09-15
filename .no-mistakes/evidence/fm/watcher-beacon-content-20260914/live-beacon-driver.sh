#!/usr/bin/env bash
# Live driver for the watcher beacon content change.
# Usage: live-beacon-driver.sh <repo-checkout> <target-rev> <base-rev> <intermediate-rev>
# Every scenario runs the real bin/ scripts from a git-archived copy of a
# revision, inside an isolated temp home with a scrubbed environment (fake tmux
# on PATH, no multiplexer or harness markers), so no real home or pane is touched.
set -u
REPO=$1 TARGET=$2 BASE=$3 MID=$4
TMPR=$(mktemp -d "${TMPDIR:-/tmp}/fm-beacon-live.XXXXXX")
PASSES=0 FAILS=0
STARTED_ARMS=""

cleanup() {
  local p
  for p in $(pgrep -f "$TMPR/" 2>/dev/null); do kill -CONT "$p" 2>/dev/null; kill -TERM "$p" 2>/dev/null; done
  sleep 1
  for p in $(pgrep -f "$TMPR/" 2>/dev/null); do kill -KILL "$p" 2>/dev/null; done
  rm -rf "$TMPR"
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
ok() { PASSES=$((PASSES + 1)); say "  PASS: $*"; }
bad() { FAILS=$((FAILS + 1)); say "  FAIL: $*"; }
check() { local msg=$1; shift; if "$@"; then ok "$msg"; else bad "$msg"; fi; }

mkhome() { # <name> <rev> -> prints home dir
  local d="$TMPR/$1" rev=$2
  mkdir -p "$d/home" "$d/fakebin" "$d/fakehome"
  git -C "$REPO" archive "$rev" | tar -x -C "$d/home"
  mkdir -p "$d/home/state"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/fakebin/tmux"
  chmod +x "$d/fakebin/tmux"
  git -C "$d/home" init -q
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid \
    git -C "$d/home" commit -q --allow-empty -m init
  printf '%s\n' "$d"
}

fmenv() { # <case-dir> cmd...
  local d=$1; shift
  env -i HOME="$d/fakehome" PATH="$d/fakebin:/usr/local/bin:/usr/bin:/bin" LANG=C.UTF-8 \
    FM_HOME="$d/home" FM_WEDGE_ALARM_EXEC=/bin/true "$@"
}

arm() { # <case-dir> <poll> -> starts the real arm in background, waits for its status line
  local d=$1 poll=$2 i
  fmenv "$d" FM_POLL="$poll" FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$d/home/bin/fm-watch-arm.sh" > "$d/arm.out" 2>&1 &
  i=0
  while [ "$i" -lt 200 ]; do
    grep -q '^watcher:' "$d/arm.out" 2>/dev/null && break
    sleep 0.1; i=$((i + 1))
  done
  say "  arm output: $(grep '^watcher:' "$d/arm.out" | head -1)"
}

beat_line() { # <case-dir>
  local b="$1/home/state/.last-watcher-beat" now m
  now=$(date +%s); m=$(stat -c %Y "$b" 2>/dev/null || echo 0)
  printf 'size=%s bytes, mtime age=%ss, content=%s' "$(stat -c %s "$b" 2>/dev/null || echo missing)" \
    "$((now - m))" "$(cat "$b" 2>/dev/null | tr -d '\n')"
}
beat_size() { stat -c %s "$1/home/state/.last-watcher-beat" 2>/dev/null || echo -1; }
beat_age() { echo $(( $(date +%s) - $(stat -c %Y "$1/home/state/.last-watcher-beat" 2>/dev/null || echo 0) )); }
lock_pid() { cat "$1/home/state/.watch.lock/pid" 2>/dev/null; }

guard() { # <case-dir> -> runs the real fm-guard.sh (strict persistent-watcher model), prints stderr
  local d=$1
  mkdir -p "$TMPR/nongit-root"
  fmenv "$d" FM_SUPERVISION_MODEL=persistent FM_ROOT_OVERRIDE="$TMPR/nongit-root" FM_GUARD_GRACE=300 \
    "$d/home/bin/fm-guard.sh" 2>&1 >/dev/null
}
turnend() { # <case-dir> -> runs the real turn-end hook, prints output, returns hook status
  local d=$1
  printf '{"stop_hook_active":false}' | fmenv "$d" FM_SUPERVISION_MODEL=persistent "$d/home/bin/fm-turnend-guard.sh" 2>&1
}
suplib() { # <case-dir> -> FM_SUP_WATCHER_FRESH from the real supervision lib
  local d=$1
  fmenv "$d" bash -c '. "$1"; fm_supervision_status "$2" 300; printf "%s" "$FM_SUP_WATCHER_FRESH"' _ \
    "$d/home/bin/fm-supervision-lib.sh" "$d/home/state"
}
healthy() { # <case-dir> -> status of the real PID-strict fm_watcher_healthy
  local d=$1
  fmenv "$d" bash -c '. "$1"; fm_watcher_healthy "$2" "$3" 300 "$4"' _ \
    "$d/home/bin/fm-wake-lib.sh" "$d/home/state" "$d/home/bin/fm-watch.sh" "$d/home"
}
unhealthy() { ! healthy "$1"; }

# Size-based outside observer: tight stat loop counting zero-byte and missing reads.
SAMPLER="$TMPR/size-observer.py"
cat > "$SAMPLER" <<'PY'
import os, sys, time
path, seconds = sys.argv[1], float(sys.argv[2])
samples = zero = missing = 0
contents = set()
end = time.monotonic() + seconds
while time.monotonic() < end:
    for _ in range(2000):
        try:
            st = os.stat(path)
        except FileNotFoundError:
            missing += 1
        else:
            if st.st_size == 0:
                zero += 1
        samples += 1
    try:
        with open(path) as fh:
            contents.add(fh.read())
    except FileNotFoundError:
        pass
print(f"samples={samples} zero_byte_reads={zero} missing_reads={missing} distinct_contents_seen={len(contents)}")
PY

say "=== S0 BUG REPRODUCTION (base revision): a live watcher leaves a zero-byte beacon ==="
B=$(mkhome base "$BASE")
printf 'project=x\n' > "$B/home/state/task.meta"
arm "$B" 1
sleep 3
say "  base beacon: $(beat_line "$B")"
check "base watcher alive (lock pid live)" kill -0 "$(lock_pid "$B")"
check "base beacon is zero bytes (the reported DOWN trigger reproduces)" [ "$(beat_size "$B")" -eq 0 ]
say "  size-based observer on base (5s): $(python3 "$SAMPLER" "$B/home/state/.last-watcher-beat" 5)"
kill "$(lock_pid "$B")" 2>/dev/null; sleep 1

say ""
say "=== S1 arm a watcher: poll leaves a non-empty beacon with fresh mtime ==="
H=$(mkhome target "$TARGET")
printf 'project=x\n' > "$H/home/state/task.meta"
arm "$H" 1
WP=$(lock_pid "$H")
check "arm reported 'watcher: started pid=$WP (beacon fresh)'" grep -qF "watcher: started pid=$WP (beacon fresh)" "$H/arm.out"
sleep 2
say "  beacon: $(beat_line "$H")"
check "beacon is non-empty" [ "$(beat_size "$H")" -gt 0 ]
check "beacon mtime is fresh (<= 2s)" [ "$(beat_age "$H")" -le 2 ]
check "content is '<UTC ISO time> pid=<live watcher pid>'" \
  grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z pid=$WP\$" "$H/home/state/.last-watcher-beat"
cts=$(date -u -d "$(cut -d' ' -f1 "$H/home/state/.last-watcher-beat")" +%s)
check "content timestamp matches file mtime within 1s" [ $(( $(stat -c %Y "$H/home/state/.last-watcher-beat") - cts )) -le 1 ]

say ""
say "=== S2 later polls keep refreshing mtime and content; no temp files pile up ==="
first=$(cat "$H/home/state/.last-watcher-beat"); m1=$(stat -c %Y "$H/home/state/.last-watcher-beat")
sleep 4
second=$(cat "$H/home/state/.last-watcher-beat"); m2=$(stat -c %Y "$H/home/state/.last-watcher-beat")
say "  first : $first"
say "  second: $second"
check "content advanced across polls" [ "$first" != "$second" ]
check "mtime advanced across polls" [ "$m2" -gt "$m1" ]
leftover=$(find "$H/home/state" -maxdepth 1 -name '.last-watcher-beat.*' | wc -l)
say "  temp beacon files left in state/: $leftover"
check "no .last-watcher-beat.* temp files left after ~6 polls" [ "$leftover" -eq 0 ]

say ""
say "=== S3 existing mtime-based readers accept the non-empty fresh beacon (task in flight) ==="
g=$(guard "$H")
check "fm-guard.sh prints no WATCHER DOWN banner" [ -z "$(printf '%s' "$g" | grep 'WATCHER DOWN')" ]
[ -z "$g" ] && say "  fm-guard.sh stderr: (silent)" || say "  fm-guard.sh stderr: $g"
t=$(turnend "$H"); ts=$?
say "  fm-turnend-guard.sh exit=$ts output=${t:-(none)}"
check "fm-turnend-guard.sh lets the turn end (exit 0)" [ "$ts" -eq 0 ]
check "fm_watcher_healthy accepts it" healthy "$H"
check "fm_supervision_status FM_SUP_WATCHER_FRESH=true" [ "$(suplib "$H")" = true ]
dup=$(fmenv "$H" FM_POLL=1 "$H/home/bin/fm-watch.sh" 2>&1); ds=$?
say "  second fm-watch.sh start: exit=$ds output=$dup"
check "second watcher start sees a live healthy singleton" [ "$dup" = "watcher: already running pid $WP" ]
fmenv "$H" FM_POLL=1 FM_ARM_ATTACH_POLL=0.5 "$H/home/bin/fm-watch-arm.sh" > "$H/arm2.out" 2>&1 &
a2=$!
for i in $(seq 1 60); do grep -q '^watcher:' "$H/arm2.out" 2>/dev/null && break; sleep 0.1; done
say "  re-arm output: $(grep '^watcher:' "$H/arm2.out" | head -1)"
check "re-arm attaches to the live watcher" grep -qE "^watcher: attached pid=$WP \(beacon [0-9]+s\)" "$H/arm2.out"
kill "$a2" 2>/dev/null; wait "$a2" 2>/dev/null

say ""
say "=== S4 ADVERSARIAL: non-empty but stale beacon (watcher frozen) still reads DOWN ==="
kill -STOP "$WP"
touch -m -d '2000-01-01' "$H/home/state/.last-watcher-beat"
say "  beacon after freeze + backdate: $(beat_line "$H")"
check "beacon still non-empty while stale" [ "$(beat_size "$H")" -gt 0 ]
g=$(guard "$H")
say "  fm-guard.sh banner lines: $(printf '%s\n' "$g" | grep -E 'WATCHER DOWN|last beat' | tr '\n' '|')"
check "fm-guard.sh raises WATCHER DOWN despite non-empty content" [ -n "$(printf '%s' "$g" | grep 'WATCHER DOWN')" ]
t=$(turnend "$H"); ts=$?
say "  fm-turnend-guard.sh exit=$ts output=$(printf '%s' "$t" | head -1)"
check "fm-turnend-guard.sh blocks the turn (exit 2)" [ "$ts" -eq 2 ]
check "fm_watcher_healthy rejects it" unhealthy "$H"
check "fm_supervision_status FM_SUP_WATCHER_FRESH=false" [ "$(suplib "$H")" = false ]
dup=$(fmenv "$H" FM_POLL=1 "$H/home/bin/fm-watch.sh" 2>&1); ds=$?
say "  second fm-watch.sh start: exit=$ds output=$dup"
check "second watcher start refuses: live pid but stale heartbeat" \
  bash -c '[ "$1" -ne 0 ] && case "$2" in *"lock held by live pid $3 but heartbeat is stale"*) true ;; *) false ;; esac' _ "$ds" "$dup" "$WP"
kill -CONT "$WP"
sleep 3
say "  beacon after resume: $(beat_line "$H")"
check "resumed watcher refreshes mtime" [ "$(beat_age "$H")" -le 2 ]
g=$(guard "$H")
check "fm-guard.sh goes quiet again after recovery" [ -z "$(printf '%s' "$g" | grep 'WATCHER DOWN')" ]
t=$(turnend "$H"); ts=$?
check "fm-turnend-guard.sh allows the turn again (exit 0)" [ "$ts" -eq 0 ]

say ""
say "=== S5 ADVERSARIAL: size-based observer hammers a fast-polling watcher's beacon ==="
F=$(mkhome fast "$TARGET")
arm "$F" 0.05
sleep 1
say "  target (rename-into-place) 20s: $(r=$(python3 "$SAMPLER" "$F/home/state/.last-watcher-beat" 20); echo "$r" > "$F/sampler.out"; echo "$r")"
check "target: zero zero-byte reads" grep -q 'zero_byte_reads=0 ' "$F/sampler.out"
check "target: zero missing-file reads" grep -q 'missing_reads=0 ' "$F/sampler.out"
check "target watcher still alive after hammer" kill -0 "$(lock_pid "$F")"
leftover=$(find "$F/home/state" -maxdepth 1 -name '.last-watcher-beat.*' | wc -l)
say "  temp beacon files left after ~400 fast polls: $leftover (a rename in flight can show 1)"
check "no temp file pile-up under fast polling (<= 1 in flight)" [ "$leftover" -le 1 ]
kill "$(lock_pid "$F")" 2>/dev/null; sleep 1
M=$(mkhome mid "$MID")
arm "$M" 0.05
sleep 1
say "  control: intermediate truncate-then-write revision 20s: $(r=$(python3 "$SAMPLER" "$M/home/state/.last-watcher-beat" 20); echo "$r" > "$M/sampler.out"; echo "$r")"
check "control: the observer does catch a truncate-then-write gap (sampler is sensitive)" \
  bash -c '! grep -q "zero_byte_reads=0 " "$1"' _ "$M/sampler.out"
kill "$(lock_pid "$M")" 2>/dev/null; sleep 1

say ""
say "=== S6 ADVERSARIAL: rename or temp-file creation fails; fallback keeps mtime fresh and content intact ==="
for mode in mv mktemp; do
  R=$(mkhome "fallback-$mode" "$TARGET")
  real=$(command -v "$mode")
  cat > "$R/fakebin/$mode" <<SH
#!/usr/bin/env bash
case "\$*" in
  *.last-watcher-beat*) printf '%s\n' "\$*" >> "$R/shim-refusals.log"; echo "$mode shim: refused beacon operation" >&2; exit 1 ;;
esac
exec "$real" "\$@"
SH
  chmod +x "$R/fakebin/$mode"
  printf 'seeded line from an earlier watcher pid=1\n' > "$R/home/state/.last-watcher-beat"
  touch -m -d '2000-01-01' "$R/home/state/.last-watcher-beat"
  printf 'project=x\n' > "$R/home/state/task.meta"
  say "  [$mode fails] before arm: $(beat_line "$R")"
  arm "$R" 0.5
  sleep 3
  say "  [$mode fails] after ~6 polls: $(beat_line "$R")"
  say "  [$mode fails] shim refusals logged: $(wc -l < "$R/shim-refusals.log" 2>/dev/null || echo 0)"
  check "[$mode fails] shim was really hit" [ -s "$R/shim-refusals.log" ]
  check "[$mode fails] arm still confirms 'started ... (beacon fresh)'" grep -qE '^watcher: started pid=[0-9]+ \(beacon fresh\)' "$R/arm.out"
  check "[$mode fails] beacon mtime fresh via touch fallback" [ "$(beat_age "$R")" -le 2 ]
  check "[$mode fails] beacon content kept (never emptied)" grep -qx 'seeded line from an earlier watcher pid=1' "$R/home/state/.last-watcher-beat"
  leftover=$(find "$R/home/state" -maxdepth 1 -name '.last-watcher-beat.*' | wc -l)
  check "[$mode fails] failed temp files are removed (found $leftover)" [ "$leftover" -eq 0 ]
  check "[$mode fails] fm_watcher_healthy accepts the live watcher" healthy "$R"
  kill "$(lock_pid "$R")" 2>/dev/null; sleep 1
done

say ""
say "RESULT: $PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
