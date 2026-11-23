#!/usr/bin/env bash
# tests/fm-session-lock-ancestry.test.sh - session-lock harness identity
# (bin/fm-session-lock-lib.sh).
#
# Two layers. The unit cases drive the library's own functions behind a
# deterministic fake ps, so both platforms' reporting semantics are covered from
# either host: macOS reports argv[0] in `ps -o comm=`, while procps on Linux
# reports the kernel exec name and ignores argv[0] entirely. The end-to-end cases
# run the REAL Stop auto-arm inside real process trees whose shapes differ only
# in how the per-session process is named and what its parent is. Those trees are
# orphaned before the hook fires, so the ancestry walk terminates inside the
# fixture and can never escape into the session running this suite.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME and $$ expand inside the fixture child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-ancestry)
fm_git_identity fmtest fmtest@example.invalid

LIB="$ROOT/bin/fm-session-lock-lib.sh"

# Claude Code's native installer names the per-session executable by its version,
# so the harness identity has to survive a basename that says nothing.
CLAUDE_VERSION_DIR="$TMP_ROOT/claude-install/share/claude/versions"
mkdir -p "$CLAUDE_VERSION_DIR"
ln -s /bin/bash "$CLAUDE_VERSION_DIR/2.1.220"
VERSIONED_CLAUDE="$CLAUDE_VERSION_DIR/2.1.220"

FAKEBIN=$(fm_fakebin "$TMP_ROOT/harness-bin")
ln -s /bin/bash "$FAKEBIN/claude"
NAMED_CLAUDE="$FAKEBIN/claude"

# --- unit layer: identity behind a deterministic process table ---------------

# Run one library expression with <fakebin> shadowing ps. kill is stubbed so
# liveness questions are decided by the process table alone.
lib_eval() {  # <fakebin> <expression>
  local fakebin=$1 expr=$2
  PATH="$fakebin:$PATH" bash -c "
    . \"\$0\"
    kill() { return 0; }
    $expr
  " "$LIB"
}

test_version_named_session_is_identified_on_both_platforms() {
  local dir fakebin shape got
  dir="$TMP_ROOT/version-named"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_CLAUDE_SHAPE:-linux}" in
  700:comm=:linux) printf '%s\n' '2.1.220' ;;
  700:args=:linux) printf '%s\n' '/opt/claude/versions/2.1.220 --resume' ;;
  700:comm=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220' ;;
  700:args=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220 --resume' ;;
  700:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-claude-stop-autoarm.sh' ;;
  *:ppid=:*) printf '%s\n' 700 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '700\n' > "$dir/state/.lock"

  for shape in linux macos; do
    got=$(FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
      || fail "$shape: the version-named session was not found in the ancestry at all"
    [ "$got" = 700 ] || fail "$shape: ancestry resolved '$got', expected the version-named session pid 700"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 700' \
      || fail "$shape: a live version-named session was not recognized as a harness"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
      || fail "$shape: the session holding the lock did not recognize itself as the owner"
  done
  pass "session-lock: a version-named Claude Code session is identified from its install path and argv[0]"
}

test_ordinary_paths_are_never_harness_processes() {
  local dir fakebin shape
  dir="$TMP_ROOT/ordinary-paths"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_PATH_SHAPE:-hookdir}" in
  810:comm=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh' ;;
  810:args=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh --quiet' ;;
  810:comm=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner' ;;
  810:args=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner --once' ;;
  810:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-watch-arm.sh' ;;
  *:ppid=:*) printf '%s\n' 810 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '810\n' > "$dir/state/.lock"

  # Identity may be read from an executable path, but only from whole path
  # components: anything merely living under ~/.claude, and any component that
  # merely starts with a harness name, must stay outside the harness identity.
  for shape in hookdir piprefix; do
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid'; then
      fail "$shape: an ordinary script path was treated as a harness process"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 810'; then
      fail "$shape: an ordinary script path passed the harness-liveness predicate"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
      fail "$shape: an ordinary script path claimed the home's session lock"
    fi
  done
  pass "session-lock: ordinary script paths under a harness directory are not harness processes"
}

test_harness_beyond_a_gap_never_owns_the_lock() {
  local dir fakebin got
  dir="$TMP_ROOT/gap"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  900:comm=) printf '%s\n' claude ;;
  900:args=) printf '%s\n' 'claude' ;;
  900:ppid=) printf '%s\n' 910 ;;
  910:comm=) printf '%s\n' bash ;;
  910:args=) printf '%s\n' 'bash tests/run.sh' ;;
  910:ppid=) printf '%s\n' 920 ;;
  920:comm=) printf '%s\n' claude ;;
  920:args=) printf '%s\n' 'claude' ;;
  920:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 900 ;;
esac
SH
  chmod +x "$fakebin/ps"

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') || fail "the contiguous harness run was not resolved"
  [ "$got" = 900 ] || fail "ancestry crossed a non-harness gap, resolved '$got' instead of 900"
  printf '920\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "an unrelated harness beyond a non-harness gap was accepted as this session's lock owner"
  fi
  printf '900\n' > "$dir/state/.lock"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the contiguous harness run did not recognize its own lock"
  pass "session-lock: ownership stops at the first non-harness gap above the contiguous run"
}

test_competing_version_named_session_is_seen_as_live() {
  local dir fakebin
  dir="$TMP_ROOT/competing"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  600:comm=) printf '%s\n' '2.1.220' ;;
  600:args=) printf '%s\n' '/opt/claude/versions/2.1.220' ;;
  600:ppid=) printf '%s\n' 1 ;;
  650:comm=) printf '%s\n' claude ;;
  650:args=) printf '%s\n' claude ;;
  650:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 650 ;;
esac
SH
  chmod +x "$fakebin/ps"
  # pid 600 is a different live session that holds the lock; this process
  # descends from 650 instead. Treating 600 as dead would let this session
  # reclaim a live competitor's home.
  printf '600\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a lock held outside this ancestry was claimed as this session's own"
  fi
  lib_eval "$fakebin" 'fm_harness_pid_alive 600' \
    || fail "a live competing version-named session was classified as a dead lock owner"
  pass "session-lock: a live version-named session holding the lock is not mistaken for a stale owner"
}

# --- end-to-end layer: the real Stop auto-arm in real process trees ----------

install_autoarm_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-claude-stop-autoarm.sh"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$dir/bin/fm-timeout-lib.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$ROOT/bin/fm-session-lock-record-lib.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-cursor-lib.sh" "$dir/bin/fm-cursor-lib.sh"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/fm-hook-host-lib.sh"
  cp "$ROOT/bin/fm-lock.sh" "$dir/bin/fm-lock.sh"
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-lock.sh"
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

# A primary home with one task in flight, so the hook's scope and supervision-need
# gates both pass and only identity decides the outcome.
make_primary_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/state/task.meta"
  install_autoarm_scripts "$dir"
  # The process that fires the hook records its own pid as the session lock
  # owner, exactly as a real session does at session start.
  cat > "$dir/session.sh" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FIXTURE_ORPHAN_HERE:-0}" = 1 ]; then
  i=0
  while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
    sleep 0.05
    i=$((i + 1))
  done
fi
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
"$FM_HOME/bin/fm-claude-stop-autoarm.sh" </dev/null > "$FM_HOME/state/hook.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/hook.rc"
SH
  cat > "$dir/daemon.sh" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$$" > "$FM_HOME/state/daemon-pid"
"$FM_SESSION_BIN" "$FM_HOME/session.sh"
exit 0
SH
  chmod +x "$dir/session.sh" "$dir/daemon.sh"
}

# Start the fixture tree detached from this suite's own process tree: the
# launcher exits immediately, so the tree is reparented to init and the ancestry
# walk terminates inside the fixture. Returns once the hook has recorded its exit
# code.
run_fixture_tree() {  # <dir> <session-bin> [<daemon-bin>]
  local dir=$1 session_bin=$2 daemon_bin=${3:-} i
  if [ -n "$daemon_bin" ]; then
    FM_HOME="$dir" FM_SESSION_BIN="$session_bin" FM_FIXTURE_ORPHAN_HERE=0 \
      bash -c '"$0" "$1" &' "$daemon_bin" "$dir/daemon.sh"
  else
    FM_HOME="$dir" FM_FIXTURE_ORPHAN_HERE=1 \
      bash -c '"$0" "$1" &' "$session_bin" "$dir/session.sh"
  fi
  i=0
  while [ "$i" -lt 400 ] && [ ! -s "$dir/state/hook.rc" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/state/hook.rc" ] || fail "the fixture hook never finished"
}

hook_rc() {
  tr -d '[:space:]' < "$1/state/hook.rc"
}

epoch_outcome() {
  sed -n 's/^.*outcome=\([a-z][a-z]*\) .*$/\1/p' "$1/state/.claude-autoarm-epoch" 2>/dev/null || true
}

test_e2e_version_named_session_claims_the_home() {
  local dir
  dir="$TMP_ROOT/e2e-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named session"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "no claim was recorded, got: $(epoch_outcome "$dir")"
  pass "session-lock e2e: a version-named session claims the home and arms supervision"
}

test_e2e_daemon_parented_session_claims_the_home() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-parented"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$NAMED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  [ -n "$session_pid" ] && [ "$session_pid" != "$daemon_pid" ] \
    || fail "fixture did not produce a distinct daemon and session: session=$session_pid daemon=$daemon_pid"
  lock_after=$(cat "$dir/state/.lock")
  expect_code 2 "$(hook_rc "$dir")" "a session parented by a harness-named daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a daemon-parented session"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  pass "session-lock e2e: a session parented by a harness-named daemon claims the home and arms supervision"
}

test_e2e_daemon_parented_version_named_session_keeps_its_lock() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  lock_after=$(cat "$dir/state/.lock")
  [ "$lock_after" != "$daemon_pid" ] \
    || fail "the live session's lock was reclaimed as stale and rewritten to the shared daemon pid $daemon_pid"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session under a daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named daemon-parented session"
  pass "session-lock e2e: a version-named session under a harness-named daemon keeps its own lock"
}

# --- owner record: start-time liveness and atomic publication ----------------
# These cases run the REAL bin/fm-lock.sh under a harness-named copy of bash, so
# the ancestry walk stops at that fixture process and never reaches this suite.

CODEX_FIXTURE="$FAKEBIN/codex"
ln -s /bin/bash "$CODEX_FIXTURE"

lock_home() {  # <name>
  local dir="$TMP_ROOT/owner-record/$1"
  mkdir -p "$dir/state"
  printf '%s' "$dir"
}

# Run fm-lock.sh with a harness-named parent; the trailing command keeps bash
# from exec-replacing the fixture process with the script.
fixture_start_time() {
  local pid=$1 start
  if [ -r "/proc/$pid/stat" ]; then
    awk '{print "proc:" $22}' "/proc/$pid/stat"
  else
    start=$(TZ=UTC0 LC_ALL=C /bin/ps -p "$pid" -o lstart=) || return 1
    printf 'lstart:%s\n' "$(printf '%s' "$start" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  fi
}
export -f fixture_start_time

lock_as_harness() {  # <home> [args...]
  local home=$1
  shift
  FM_HOME="$home" "$CODEX_FIXTURE" -c '
    printf "%s\n" "$$" > "$FM_HOME/harness-pid"
    fixture_start_time "$$" > "$FM_HOME/harness-start"
    "$0" "$@"; rc=$?; exit "$rc"
  ' "$ROOT/bin/fm-lock.sh" "$@"
}

start_live_harness() {  # sets LIVE_HARNESS_PID
  "$CODEX_FIXTURE" -c 'sleep 120; exit 0' </dev/null >/dev/null 2>&1 &
  LIVE_HARNESS_PID=$!
  OWNER_RECORD_PIDS="${OWNER_RECORD_PIDS:-} $LIVE_HARNESS_PID"
}

cleanup_owner_record() {
  local pid
  for pid in ${OWNER_RECORD_PIDS:-}; do
    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
  done
}
trap 'cleanup_owner_record; fm_test_cleanup' EXIT

test_acquire_records_pid_and_start_time() {
  local home pid start out
  home=$(lock_home record)
  out=$(lock_as_harness "$home" 2>&1) || fail "a harness caller could not take a free lock: $out"
  pid=$(cat "$home/harness-pid")
  start=$(cat "$home/harness-start")
  cmp -s "$home/state/.lock" <(printf '%s\n' "$pid") || fail "the PID lock changed format"
  cmp -s "$home/state/.lock.start" <(printf '%s\nstart=%s\n' "$pid" "$start") \
    || fail "the sidecar did not record the fixture's PID and start time"
  if ls "$home/state"/.lock-write.* >/dev/null 2>&1; then fail "a temporary owner record was left behind"; fi
  pass "session lock: acquisition publishes one PID line and a separate start-time record"
}

test_reused_pid_with_other_start_time_is_not_an_owner() {
  local home out status
  home=$(lock_home reused)
  start_live_harness
  # The recorded owner exited and the kernel gave its pid to an unrelated live
  # harness-named process: same pid, different start time.
  printf '%s\n' "$LIVE_HARNESS_PID" > "$home/state/.lock"
  printf '%s\nstart=proc:1\n' "$LIVE_HARNESS_PID" > "$home/state/.lock.start"
  status=$(FM_HOME="$home" "$ROOT/bin/fm-lock.sh" status)
  case "$status" in "lock: stale"*) ;; *) fail "a reused pid still reads as the live owner: $status" ;; esac
  out=$(lock_as_harness "$home" 2>&1) || fail "a reused owner pid kept the home refused: $out"
  [ "$(cat "$home/state/.lock")" != "$LIVE_HARNESS_PID" ] || fail "the lock still names the unrelated process"
  pass "session lock: a reused pid with a different start time no longer holds the lock"
}

test_live_owner_with_matching_start_time_keeps_the_lock() {
  local home start out
  home=$(lock_home live)
  start_live_harness
  start=$(fixture_start_time "$LIVE_HARNESS_PID") || fail "no start time for a live process"
  printf '%s\n' "$LIVE_HARNESS_PID" > "$home/state/.lock"
  printf '%s\nstart=%s\n' "$LIVE_HARNESS_PID" "$start" > "$home/state/.lock.start"
  if out=$(lock_as_harness "$home" 2>&1); then fail "a second session took a live owner's lock: $out"; fi
  cmp -s "$home/state/.lock" <(printf '%s\n' "$LIVE_HARNESS_PID") || fail "the live owner lost its lock"
  cmp -s "$home/state/.lock.start" <(printf '%s\nstart=%s\n' "$LIVE_HARNESS_PID" "$start") \
    || fail "a refused acquisition changed the live owner's start sidecar"
  pass "session lock: a live owner whose start time matches keeps its lock"
}

test_legacy_pid_only_record_keeps_pid_only_liveness() {
  local home out dead mismatched_pid
  home=$(lock_home legacy-live)
  start_live_harness
  printf '%s\n' "$LIVE_HARNESS_PID" > "$home/state/.lock"
  if out=$(lock_as_harness "$home" 2>&1); then fail "a legacy record naming a live harness was taken over: $out"; fi
  mismatched_pid=$((LIVE_HARNESS_PID + 1))
  printf '%s\nstart=proc:1\n' "$mismatched_pid" > "$home/state/.lock.start"
  if out=$(lock_as_harness "$home" 2>&1); then fail "an unrelated sidecar displaced the live owner: $out"; fi
  cmp -s "$home/state/.lock" <(printf '%s\n' "$LIVE_HARNESS_PID") || fail "the legacy owner lost its lock"
  cmp -s "$home/state/.lock.start" <(printf '%s\nstart=proc:1\n' "$mismatched_pid") \
    || fail "a refused acquisition changed the unrelated sidecar"
  home=$(lock_home legacy-dead)
  "$CODEX_FIXTURE" -c 'exit 0' &
  dead=$!
  wait "$dead"
  printf '%s\n' "$dead" > "$home/state/.lock"
  out=$(lock_as_harness "$home" 2>&1) || fail "a legacy record naming a dead pid was not recovered: $out"
  cmp -s "$home/state/.lock.start" <(printf '%s\nstart=%s\n' "$(cat "$home/harness-pid")" "$(cat "$home/harness-start")") \
    || fail "legacy takeover did not publish the new owner's start sidecar"
  pass "session lock: a live legacy PID is honored with a missing or unrelated sidecar"
}

test_legacy_upgrade_during_own_sweep() {
  local home out
  home=$(lock_home legacy-upgrade)
  out=$(FM_HOME="$home" "$CODEX_FIXTURE" -ec '
    state="$FM_HOME/state"
    printf "%s\n" "$$" > "$state/.lock"
    ln "$state/.lock" "$state/lock-before"
    printf "%s\n" "$$" > "$FM_HOME/harness-pid"
    fixture_start_time "$$" > "$FM_HOME/harness-start"
    mkdir "$state/.lock.acquire"
    printf "%s\n" "$$" > "$state/.lock.acquire/pid"
    printf "pid=%s\n" "$$" > "$state/.startup-network.status"
    "$0"
    [ ! -e "$state/.lock.start" ] && [ "$state/.lock" -ef "$state/lock-before" ] || exit 1
    rm "$state/.lock.acquire/pid"
    rmdir "$state/.lock.acquire"
    "$0"; rc=$?; exit "$rc"
  ' "$ROOT/bin/fm-lock.sh" 2>&1) || fail "legacy renewal or upgrade failed: $out"
  [ "$home/state/.lock" -ef "$home/state/lock-before" ] || fail "upgrading the sidecar rewrote the owner file"
  cmp -s "$home/state/.lock" <(printf '%s\n' "$(cat "$home/harness-pid")") || fail "upgrading the legacy claim changed the owner"
  cmp -s "$home/state/.lock.start" <(printf '%s\nstart=%s\n' "$(cat "$home/harness-pid")" "$(cat "$home/harness-start")") \
    || fail "a known start time did not upgrade the legacy claim"
  pass "session lock: legacy renewal skips a held sweep and later adds a sidecar without rewriting the PID"
}

test_readers_see_only_complete_owner_lines() {
  local home fakebin old_owner new_owner observed writer_pid i
  home=$(lock_home atomic)
  fakebin=$(fm_fakebin "$home/publication")
  lock_as_harness "$home" >/dev/null 2>&1 || fail "seed acquisition failed"
  old_owner=$(cat "$home/harness-pid")
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
[ "${@: -1}" = "$FM_HOME/state/.lock" ] || exec /bin/mv "$@"
: > "$FM_HOME/publishing"
for ((i = 0; i < 500; i++)); do
  if [ -e "$FM_HOME/reader-sampled" ]; then exec /bin/mv "$@"; fi
  sleep 0.01
done
exit 1
SH
  chmod +x "$fakebin/mv"
  PATH="$fakebin:$PATH" lock_as_harness "$home" >/dev/null 2>&1 &
  writer_pid=$!
  for ((i = 0; i < 500; i++)); do
    [ ! -e "$home/publishing" ] || break
    sleep 0.01
  done
  [ -e "$home/publishing" ] || fail "the replacement owner never reached publication"
  new_owner=$(cat "$home/harness-pid")
  [ "$old_owner" != "$new_owner" ] || fail "the replacement fixture reused the first fixture's PID"
  cmp -s "$home/state/.lock" <(printf '%s\n' "$old_owner") || fail "the pending rename changed the previous PID line"
  cmp -s "$home/state/.lock.start" <(printf '%s\nstart=%s\n' "$new_owner" "$(cat "$home/harness-start")") \
    || fail "the replacement sidecar was not published before the owner rename"
  : > "$home/reader-sampled"
  for ((i = 0; i < 500; i++)); do
    observed=$(cat "$home/state/.lock")
    case "$observed" in
      "$new_owner") break ;;
      "$old_owner") sleep 0.01 ;;
      *) fail "a reader saw an invalid owner line during publication: '$observed'" ;;
    esac
  done
  wait "$writer_pid" || fail "replacement acquisition failed"
  [ "$observed" = "$new_owner" ] || fail "the reader never saw the replacement owner"
  pass "session lock: a reader across publication sees only complete fixture PIDs"
}

test_failed_start_lookup_preserves_only_legacy_liveness() {
  local home proc status out
  home=$(lock_home no-start)
  proc="$home/proc"
  start_live_harness
  mkdir -p "$proc/$LIVE_HARNESS_PID"
  printf 'unreadable start-time fixture\n' > "$proc/$LIVE_HARNESS_PID/stat"
  printf '%s\n' "$LIVE_HARNESS_PID" > "$home/state/.lock"
  printf '%s\nstart=%s\n' "$LIVE_HARNESS_PID" "$(fixture_start_time "$LIVE_HARNESS_PID")" > "$home/state/.lock.start"
  status=$(FM_PROC_ROOT_OVERRIDE="$proc" FM_HOME="$home" "$ROOT/bin/fm-lock.sh" status)
  case "$status" in "lock: stale"*) ;; *) fail "a versioned record survived a failed start lookup: $status" ;; esac
  rm "$home/state/.lock.start"
  status=$(FM_PROC_ROOT_OVERRIDE="$proc" FM_HOME="$home" "$ROOT/bin/fm-lock.sh" status)
  [ "$status" = "lock: held by live harness pid $LIVE_HARNESS_PID" ] || fail "legacy liveness changed: $status"
  rm "$home/state/.lock"
  out=$(FM_HOME="$home" FM_PROC_ROOT_OVERRIDE="$proc" "$CODEX_FIXTURE" -ec '
    mkdir -p "$FM_PROC_ROOT_OVERRIDE/$$"
    printf "malformed\n" > "$FM_PROC_ROOT_OVERRIDE/$$/stat"
    printf "%s\n" "$$" > "$FM_HOME/harness-pid"
    "$0" || exit 1
    mkdir "$FM_HOME/state/.lock.acquire"
    printf "%s\n" "$$" > "$FM_HOME/state/.lock.acquire/pid"
    printf "pid=%s\n" "$$" > "$FM_HOME/state/.startup-network.status"
    "$0"; rc=$?; exit "$rc"
  ' "$ROOT/bin/fm-lock.sh" 2>&1) || fail "legacy acquisition or renewal during a sweep failed: $out"
  [ "$(cat "$home/state/.lock")" = "$(cat "$home/harness-pid")" ] || fail "failed acquisition lookup did not publish a PID-only record"
  assert_absent "$home/state/.lock.start" "a failed lookup published a start sidecar"
  [ -d "$home/state/.lock.acquire" ] || fail "the legacy owner disturbed the running sweep's claim"
  pass "session lock: a failed lookup permits legacy acquisition and renewal during a sweep"
}

test_failed_renewal_preserves_recorded_start_time() {
  local home out pid start
  home=$(lock_home renewal-no-start)
  out=$(FM_HOME="$home" "$CODEX_FIXTURE" -ec '
    state="$FM_HOME/state"
    printf "%s\n" "$$" > "$FM_HOME/harness-pid"
    fixture_start_time "$$" > "$FM_HOME/harness-start"
    "$0"
    mkdir -p "$FM_HOME/proc/$$"
    printf "malformed\n" > "$FM_HOME/proc/$$/stat"
    if FM_PROC_ROOT_OVERRIDE="$FM_HOME/proc" "$0"; then
      exit 1
    fi
    "$0" status
  ' "$ROOT/bin/fm-lock.sh" 2>&1) || fail "an unverified renewal succeeded or the fixture failed: $out"
  pid=$(cat "$home/harness-pid")
  start=$(cat "$home/harness-start")
  assert_contains "$out" "cannot verify session lock owner's start time" "renewal did not refuse the failed lookup"
  assert_contains "$out" "lock: held by live harness pid $pid" "a restored lookup did not recognize the existing owner"
  cmp -s "$home/state/.lock" <(printf '%s\n' "$pid") || fail "a failed renewal changed the owner PID"
  cmp -s "$home/state/.lock.start" <(printf '%s\nstart=%s\n' "$pid" "$start") \
    || fail "a failed renewal changed the recorded start time"
  pass "session lock: a failed renewal preserves its existing start record"
}

test_ps_start_time_matches_across_timezones() {
  local home proc start status
  home=$(lock_home ps-timezones)
  proc="$home/proc"
  mkdir "$proc"
  start_live_harness
  start=$(TZ=UTC0 LC_ALL=C /bin/ps -p "$LIVE_HARNESS_PID" -o lstart= | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -n "$start" ] || fail "ps did not report the fixture's UTC start time"
  printf '%s\n' "$LIVE_HARNESS_PID" > "$home/state/.lock"
  printf '%s\nstart=lstart:%s\n' "$LIVE_HARNESS_PID" "$start" > "$home/state/.lock.start"
  status=$(TZ=PST8 FM_PROC_ROOT_OVERRIDE="$proc" FM_HOME="$home" "$ROOT/bin/fm-lock.sh" status)
  [ "$status" = "lock: held by live harness pid $LIVE_HARNESS_PID" ] || fail "the ps fallback varied by timezone: $status"
  pass "session lock: ps start times match across reader timezones"
}

test_malformed_records_are_not_owned() {
  local dir status start extra
  dir="$TMP_ROOT/owner-record/malformed"
  mkdir -p "$dir/state"
  printf 'not-a-pid\nstart=proc:1\n' > "$dir/state/.lock"
  if bash -c '. "$0"; fm_session_lock_owned_by_self "$1"' "$LIB" "$dir/state"; then
    fail "a non-numeric owner line was treated as owned"
  fi
  status=$(FM_HOME="$dir" "$ROOT/bin/fm-lock.sh" status)
  case "$status" in "lock: stale"*) ;; *) fail "a non-numeric owner line was treated as a live owner: $status" ;; esac
  : > "$dir/state/.lock"
  status=$(FM_HOME="$dir" "$ROOT/bin/fm-lock.sh" status)
  case "$status" in "lock: stale"*) ;; *) fail "an empty owner record was treated as a live owner: $status" ;; esac
  start_live_harness
  start=$(fixture_start_time "$LIVE_HARNESS_PID") || fail "no start time for a live process"
  printf '%s\n' "$LIVE_HARNESS_PID" > "$dir/state/.lock"
  for extra in '' 'started=proc:123' 'start=' "start=$start"$'\nextra'; do
    printf '%s\n%s\n' "$LIVE_HARNESS_PID" "$extra" > "$dir/state/.lock.start"
    status=$(FM_HOME="$dir" "$ROOT/bin/fm-lock.sh" status)
    case "$status" in "lock: stale"*) ;; *) fail "a malformed owner record with a live PID was treated as live: $status" ;; esac
  done
  lock_as_harness "$dir" >/dev/null || fail "a malformed owner record blocked takeover"
  pass "session lock: malformed or empty owner records are never owned"
}

test_version_named_session_is_identified_on_both_platforms
test_ordinary_paths_are_never_harness_processes
test_harness_beyond_a_gap_never_owns_the_lock
test_competing_version_named_session_is_seen_as_live
test_e2e_version_named_session_claims_the_home
test_e2e_daemon_parented_session_claims_the_home
test_e2e_daemon_parented_version_named_session_keeps_its_lock
test_acquire_records_pid_and_start_time
test_reused_pid_with_other_start_time_is_not_an_owner
test_live_owner_with_matching_start_time_keeps_the_lock
test_legacy_pid_only_record_keeps_pid_only_liveness
test_legacy_upgrade_during_own_sweep
test_readers_see_only_complete_owner_lines
test_failed_start_lookup_preserves_only_legacy_liveness
test_failed_renewal_preserves_recorded_start_time
test_ps_start_time_matches_across_timezones
test_malformed_records_are_not_owned
