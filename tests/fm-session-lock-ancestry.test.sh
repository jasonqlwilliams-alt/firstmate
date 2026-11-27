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
  while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" = "$FM_FIXTURE_LAUNCH_PARENT" ]; do
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
while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" = "$FM_FIXTURE_LAUNCH_PARENT" ]; do
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
# launcher exits immediately, so the tree is reparented to the OS reaper. Returns once the hook has recorded its exit
# code.
run_fixture_tree() {  # <dir> <session-bin> [<daemon-bin>]
  local dir=$1 session_bin=$2 daemon_bin=${3:-} i
  if [ -n "$daemon_bin" ]; then
    FM_HOME="$dir" FM_SESSION_BIN="$session_bin" FM_FIXTURE_ORPHAN_HERE=0 \
      bash -c 'export FM_FIXTURE_LAUNCH_PARENT=$$; "$0" "$1" &' "$daemon_bin" "$dir/daemon.sh"
  else
    FM_HOME="$dir" FM_FIXTURE_ORPHAN_HERE=1 \
      bash -c 'export FM_FIXTURE_LAUNCH_PARENT=$$; "$0" "$1" &' "$session_bin" "$dir/session.sh"
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
  local home out status start stale replacement_pid replacement_start
  home=$(lock_home reused)
  start_live_harness
  start=$(fixture_start_time "$LIVE_HARNESS_PID") || fail "no start time for the live fixture"
  stale=$(fm_test_stale_start_token "$start") || fail "no different start time in the fixture's format"
  # The recorded owner exited and the kernel gave its pid to an unrelated live
  # harness-named process: same pid, different start time.
  printf '%s\n' "$LIVE_HARNESS_PID" > "$home/state/.lock"
  printf '%s\nstart=%s\n' "$LIVE_HARNESS_PID" "$stale" > "$home/state/.lock.start"
  status=$(FM_HOME="$home" "$ROOT/bin/fm-lock.sh" status)
  case "$status" in "lock: stale"*) ;; *) fail "a reused pid still reads as the live owner: $status" ;; esac
  out=$(lock_as_harness "$home" 2>&1) || fail "a reused owner pid kept the home refused: $out"
  replacement_pid=$(cat "$home/harness-pid")
  replacement_start=$(cat "$home/harness-start")
  cmp -s "$home/state/.lock" <(printf '%s\n' "$replacement_pid") || fail "takeover did not publish the replacement PID"
  cmp -s "$home/state/.lock.start" <(printf '%s\nstart=%s\n' "$replacement_pid" "$replacement_start") \
    || fail "takeover did not publish the replacement start time"
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
  if [ -e "$FM_HOME/reader-sampled" ]; then
    /bin/mv "$@" || exit $?
    cat "$FM_HOME/state/.lock" > "$FM_HOME/owner-after-rename"
    exit $?
  fi
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
  cmp -s "$home/owner-after-rename" <(printf '%s\n' "$new_owner") \
    || fail "the owner file did not contain the replacement PID at the rename boundary"
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

launch_owner_home() {
  local home
  home=$(lock_home "$1")
  mkdir -p "$home/config"
  printf 'launch-v1\n' > "$home/config/session-lock-owner"
  printf '%s\n' "$home"
}

owner_fixture_wait() {
  local file=$1 i
  for i in $(seq 1 300); do
    [ ! -e "$file" ] || return 0
    sleep 0.05
  done
  fail "timed out waiting for launch fixture: $file"
}

test_launch_binding_survives_exec_and_detachment() {
  local home generation
  home=$(launch_owner_home launch-detach)
  mkdir -p "$home/no-ps"
  printf '#!/bin/sh\nexit 1\n' > "$home/no-ps/ps"
  chmod +x "$home/no-ps/ps"
  cat > "$home/driver" <<'SH'
#!/bin/bash
set -eu
. "$FM_BIN/fm-session-lock-lib.sh"
/bin/ps -o pid=,ppid=,sid=,comm= -p "$$" > "$FM_HOME/ancestry"
if fm_harness_ancestry_pid > "$FM_HOME/unexpected-ancestry"; then exit 1; fi
"$FM_BIN/fm-lock.sh" > "$FM_HOME/acquire"
"$FM_BIN/fm-lock.sh" verify > "$FM_HOME/before"
exec /bin/bash "$FM_HOME/after-exec"
SH
  cat > "$home/after-exec" <<'SH'
set -eu
"$FM_BIN/fm-lock.sh" verify > "$FM_HOME/after"
PATH="$FM_HOME/no-ps:$PATH" setsid -f /bin/bash -c '
  "$FM_BIN/fm-lock.sh" verify > "$FM_HOME/detached"
  echo "$?" > "$FM_HOME/detached-status"
'
for _ in $(seq 1 200); do
  if [ -s "$FM_HOME/detached-status" ]; then : > "$FM_HOME/result"; exit 0; fi
  sleep 0.05
done
SH
  chmod +x "$home/driver"
  FM_BIN="$ROOT/bin" FM_HOME="$home" setsid -f "$ROOT/bin/fm-session-launch.sh" -- "$home/driver"     </dev/null >"$home/exec.log" 2>&1 || fail "detached launch failed"
  owner_fixture_wait "$home/result"
  awk '$1 == $3 && $2 != $1 && $4 !~ /(claude|codex)/ {ok=1} END {exit !ok}' "$home/ancestry"     || fail "T1 fixture did not detach from harness ancestry"
  [ ! -s "$home/unexpected-ancestry" ] || fail "detached fixture found a harness"
  [ "$(cat "$home/detached-status")" = 0 ] || fail "detached caller with denied ps lost the lock"
  generation=$(cat "$home/before")
  [[ "$generation" =~ ^[0-9a-f]{64}$ ]] || fail "the launch did not publish a versioned generation"
  cmp -s "$home/before" "$home/after" || fail "exec changed the owner generation"
  cmp -s "$home/before" "$home/detached" || fail "detached verification changed the owner generation"
  local verdict attempt
  for attempt in $(seq 1 100); do
    verdict=$(FM_HOME="$home" "$ROOT/bin/fm-lock.sh" status)
    case "$verdict" in 'lock: stale'*) break ;; esac
    sleep 0.05
  done
  assert_contains "$verdict" "lock: stale" "exited launch remains live"
  pass "session lock: a true detached launch retains one generation across exec and detached tools with denied ps"
}

test_independent_launches_cannot_share_an_owner() {
  local home neighbor owner output owner_pid challenger launch="$ROOT/bin/fm-session-launch.sh"
  home=$(launch_owner_home competing-launches)
  neighbor=$(launch_owner_home second-home)
  FM_HOME="$home" FM_BIN="$ROOT/bin" FM_NEIGHBOR="$neighbor" "$launch" -- /bin/bash -ec '
    /bin/ps -o pid=,ppid=,sid= -p "$$" > "$FM_HOME/a.ps"
    "$FM_BIN/fm-lock.sh"
    "$FM_BIN/fm-lock.sh" verify > "$FM_HOME/a.generation"
    if FM_HOME="$FM_NEIGHBOR" "$FM_BIN/fm-lock.sh"; then exit 4; fi
    FM_HOME="$FM_NEIGHBOR" "$FM_BIN/fm-session-launch.sh" -- /bin/bash -ec '\''
      [ "$FM_SESSION_OWNER_HOME" = "$FM_HOME" ]
      "$FM_BIN/fm-lock.sh"
    '\''
    : > "$FM_HOME/owner-ready"
    while [ ! -e "$FM_HOME/owner-exit" ]; do sleep 0.05; done
    "$FM_BIN/fm-lock.sh" verify > "$FM_HOME/renewed"
  ' > "$home/a.out" 2>&1 &
  owner=$!
  OWNER_RECORD_PIDS="${OWNER_RECORD_PIDS:-} $owner"
  owner_fixture_wait "$home/owner-ready"
  printf '100\t1\tcheck\tfixture\tqueued\n' > "$home/state/.wake-queue"
  if FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" > "$home/unbound.out" 2>&1; then
    fail "an unbound caller could present the live owner's wake"
  fi
  assert_grep 'session launch no longer owns this home' "$home/unbound.out" "unbound wake drain did not hit the ownership fence"
  assert_absent "$home/state/.watch.lock" "unbound drain touched the watcher"
  FM_HOME="$home" FM_BIN="$ROOT/bin" "$launch" -- "$CODEX_FIXTURE" -c '
    /bin/ps -o pid=,ppid=,sid= -p "$$" > "$FM_HOME/b.ps"
    "$FM_BIN/fm-lock.sh"; rc=$?
    exit "$rc"
  ' > "$home/b.out" 2>&1 &
  challenger=$!
  if wait "$challenger"; then fail "two independent sibling launches acquired one home"; fi
  output=$(cat "$home/b.out")
  assert_contains "$output" "another live firstmate session holds the lock" "known name replaced a live launch"
  [ "$(awk '{print $2, $3}' "$home/a.ps")" = "$(awk '{print $2, $3}' "$home/b.ps")" ]     || fail "competitors did not share a live parent and SID"
  owner_pid=$(awk '{print $1}' "$home/a.ps")
  kill -STOP "$owner_pid" || fail "could not stop the disposable owner"
  assert_contains "$(FM_HOME="$home" "$ROOT/bin/fm-lock.sh" status)" "held by live launch" "a stopped owner was treated as stale"
  kill -CONT "$owner_pid" || fail "could not resume the disposable owner"
  if FM_HOME="$home" FM_BIN="$ROOT/bin" "$CODEX_FIXTURE" -c '"$FM_BIN/fm-lock.sh"; exit $?'; then
    fail "a transient harness name supplied launch authority"
  fi
  : > "$home/owner-exit"
  wait "$owner" || fail "owner fixture failed: $(cat "$home/a.out")"
  cmp -s "$home/a.generation" "$home/renewed" || fail "renewal changed the generation"
  FM_HOME="$home" FM_BIN="$ROOT/bin" "$launch" -- "$CODEX_FIXTURE" -ec '
    "$FM_BIN/fm-lock.sh"
    : > "$FM_HOME/known-ready"
    while [ ! -e "$FM_HOME/known-exit" ]; do sleep 0.05; done
  ' > "$home/known.out" 2>&1 &
  owner=$!
  OWNER_RECORD_PIDS="${OWNER_RECORD_PIDS:-} $owner"
  owner_fixture_wait "$home/known-ready"
  output=$(FM_HOME="$home" "$launch" -- "$ROOT/bin/fm-lock.sh" 2>&1) \
    && fail "an unnamed launch replaced a known-harness owner"
  assert_contains "$output" "another live firstmate session holds the lock" "known-harness ownership was not protected"
  : > "$home/known-exit"
  wait "$owner" || fail "known-harness owner fixture failed"
  output=$(FM_HOME="$home" "$launch" -- "$ROOT/bin/fm-lock.sh") || fail "acquisition failed after owner exit"
  assert_contains "$output" "lock acquired: launch pid" "a fresh launch did not acquire the stale lock"
  pass "session lock: sibling launches contend, stopped owners stay live and a nested home gets a fresh binding"
}

if command -v node >/dev/null 2>&1 && [ "$(uname -s)" = Linux ]; then
  test_launch_binding_survives_exec_and_detachment
  test_independent_launches_cannot_share_an_owner
fi

test_unreadable_lifetime_does_not_allow_takeover() {
  local home proc owner verdict output
  home=$(launch_owner_home unreadable-lifetime)
  proc="$home/proc"
  mkdir -p "$proc/sys/kernel/random"
  ln -s /proc/sys/kernel/random/boot_id "$proc/sys/kernel/random/boot_id"
  FM_HOME="$home" FM_BIN="$ROOT/bin" FM_SUPERVISION_ACTOR=main "$ROOT/bin/fm-session-launch.sh" -- /bin/bash -ec '
    "$FM_BIN/fm-lock.sh"
    "$FM_BIN/fm-lease.sh" claim fixture
    cp "$FM_HOME/state/.lease-fixture" "$FM_HOME/lease-original"
    mkdir "$FM_HOME/lease-bin"
    cat > "$FM_HOME/lease-bin/cat" <<'\''SH'\''
#!/bin/bash
case "${1:-}" in
  "$FM_HOME/state/.lock.owner.$FM_SESSION_OWNER_PID")
    if [ -e "$FM_HOME/lease-first-proof" ]; then exit 1; fi
    : > "$FM_HOME/lease-first-proof"
    ;;
esac
exec /bin/cat "$@"
SH
    chmod +x "$FM_HOME/lease-bin/cat"
    rc=0
    PATH="$FM_HOME/lease-bin:$PATH" FM_SUPERVISION_ACTOR=branch "$FM_BIN/fm-lease.sh" claim fixture || rc=$?
    [ "$rc" -eq 6 ]
    cmp -s "$FM_HOME/lease-original" "$FM_HOME/state/.lease-fixture"
    : > "$FM_HOME/owner-ready"
    while [ ! -e "$FM_HOME/owner-exit" ]; do sleep 0.05; done
  ' > "$home/owner.out" 2>&1 &
  owner=$!
  OWNER_RECORD_PIDS="${OWNER_RECORD_PIDS:-} $owner"
  owner_fixture_wait "$home/owner-ready"
  verdict=$(FM_HOME="$home" FM_PROC_ROOT_OVERRIDE="$proc" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$verdict" "lock: uncertain" "an unavailable live start token was reported stale"
  verdict=$(FM_HOME="$home" FM_PROC_ROOT_OVERRIDE="$proc" FM_SUPERVISION_ACTOR=main "$ROOT/bin/fm-lease.sh" check fixture)
  assert_contains "$verdict" "uncertain" "a lease with uncheckable liveness was reported stale"
  output=$(FM_HOME="$home" FM_BIN="$ROOT/bin" "$ROOT/bin/fm-session-launch.sh" -- /bin/bash -ec '
    mkdir -p "$FM_HOME/proc/$$"
    ln -s "/proc/$$/stat" "$FM_HOME/proc/$$/stat"
    FM_PROC_ROOT_OVERRIDE="$FM_HOME/proc" "$FM_BIN/fm-lock.sh"
  ' 2>&1) && fail "liveness uncertainty allowed a takeover"
  assert_contains "$output" "cannot verify liveness of recorded session owner" "the rejected contender did not reach the owner liveness probe"
  [ -f "$home/state/.lease-fixture" ] || fail "the active lease was removed"
  : > "$home/owner-exit"
  wait "$owner" || fail "disposable lease owner failed"
  pass "session lock: an unreadable live process remains occupied and preserves its lease"
}

install_publication_interrupter() {
  cat > "$1" <<'JS'
const fs = require("node:fs");
const path = require("node:path");
const originalRename = fs.renameSync;
fs.renameSync = (from, to) => {
  const phase = process.env.FM_TEST_RENAME_PHASE;
  const name = path.basename(to);
  const ownProof = ".lock.owner." + process.env.FM_SESSION_OWNER_PID;
  const oldProof = ".lock.owner." + process.env.FM_TEST_OLD_PID;
  if (!phase || !process.argv[1]?.endsWith("fm-session-owner-publish.mjs") ||
      !(phase === name || (phase === "new-proof" && name === ownProof) ||
        (phase === "legacy-proof" && name === oldProof))) {
    return originalRename(from, to);
  }
  if (process.env.FM_TEST_INTERRUPTION === "after") originalRename(from, to);
  fs.writeFileSync(process.env.FM_HOME + "/paused-publisher", String(process.pid) + "\n");
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 20_000);
  if (process.env.FM_TEST_INTERRUPTION === "before") originalRename(from, to);
};
require("node:module").syncBuiltinESMExports();
JS
}

test_interrupted_publication_leaves_a_recoverable_record() {
  local home phase timing attempt publisher old out competitor
  for timing in before after; do
    for phase in legacy-proof .lock.owner-format new-proof .lock; do
      home=$(launch_owner_home "crash-${timing}-${phase}")
      # Seed actual legacy ownership with an ended lifetime. Keep that PID
      # as the commit pointer until the publisher renames the new PID line.
      lock_as_harness_without_gate() { # <fixture home>
        mv "$1/config/session-lock-owner" "$1/gate"
        lock_as_harness "$1" >/dev/null || return 1
        mv "$1/gate" "$1/config/session-lock-owner"
      }
      lock_as_harness_without_gate "$home" || fail "could not establish a legacy record for crash test"
      old=$(cat "$home/state/.lock")
      install_publication_interrupter "$home/pause.cjs"
      FM_HOME="$home" FM_BIN="$ROOT/bin" FM_TEST_OLD_PID="$old" \
        FM_TEST_RENAME_PHASE="$phase" FM_TEST_INTERRUPTION="$timing" \
        NODE_OPTIONS="--require=\"$home/pause.cjs\"" "$ROOT/bin/fm-session-launch.sh" -- /bin/bash -c '
          "$FM_BIN/fm-lock.sh" && exit 4
          : > "$FM_HOME/interrupted"
          while [ ! -e "$FM_HOME/resume-driver" ]; do sleep 0.05; done
          "$FM_BIN/fm-lock.sh" verify
        ' > "$home/attempt.out" 2>&1 &
      attempt=$!
      OWNER_RECORD_PIDS="${OWNER_RECORD_PIDS:-} $attempt"
      owner_fixture_wait "$home/paused-publisher"
      publisher=$(cat "$home/paused-publisher")
      out=$(FM_HOME="$home" "$ROOT/bin/fm-lock.sh" status)
      case "$out" in 'lock: stale'*|'lock: held by live launch'*) ;; *) fail "torn status during $timing $phase: $out" ;; esac
      competitor=
      if [ "$phase:$timing" != .lock:after ]; then
        FM_HOME="$home" FM_BIN="$ROOT/bin" "$ROOT/bin/fm-session-launch.sh" -- /bin/bash -ec \
          '"$FM_BIN/fm-lock.sh"; : > "$FM_HOME/competitor-admitted"' \
          > "$home/competitor.out" 2>&1 &
        competitor=$!
        OWNER_RECORD_PIDS="${OWNER_RECORD_PIDS:-} $competitor"
        sleep 0.2
        [ ! -e "$home/competitor-admitted" ] || fail "an entrant bypassed the publication mutex"
      elif FM_HOME="$home" "$ROOT/bin/fm-session-launch.sh" -- "$ROOT/bin/fm-lock.sh"; then
        fail "another launch entered while the committed owner was live"
      fi
      if [ -n "$competitor" ]; then
        cmp -s "$home/state/.lock" <(printf '%s\n' "$old") || fail "publication exposed a partial PID line"
      fi
      kill -KILL "$publisher" || fail "could not stop disposable publisher at $timing $phase"
      owner_fixture_wait "$home/interrupted"
      if [ "$phase:$timing" = .lock:after ]; then
        cmp -s "$home/state/.lock" <(printf '%s\n' "$attempt") || fail "committed PID is torn"
        assert_contains "$(FM_HOME="$home" "$ROOT/bin/fm-lock.sh" status)" "held by live launch" "the committed owner disappeared"
        if FM_HOME="$home" "$ROOT/bin/fm-session-launch.sh" -- "$ROOT/bin/fm-lock.sh"; then fail "another launch entered after commit"; fi
        : > "$home/resume-driver"
        wait "$attempt" || fail "interrupted publisher's committed session could not renew"
      else
        wait "$competitor" || fail "interrupted replacement was not recoverable: $(cat "$home/competitor.out")"
        : > "$home/resume-driver"
        if wait "$attempt"; then fail "uncommitted launch obtained authority after takeover"; fi
      fi
    done
  done
  pass "session lock: a killed publisher at each different-PID commit boundary leaves one recoverable owner"
}

test_same_pid_reuse_commits_at_the_proof() {
  local home timing publisher attempt pid out
  for timing in before after; do
    home=$(launch_owner_home "same-pid-$timing")
    install_publication_interrupter "$home/pause.cjs"
    FM_HOME="$home" FM_BIN="$ROOT/bin" FM_TEST_INTERRUPTION="$timing" "$ROOT/bin/fm-session-launch.sh" -- /bin/bash -ec '
      "$FM_BIN/fm-lock.sh"
      proof="$FM_HOME/state/.lock.owner.$$"
      awk -F "\t" '\''BEGIN {OFS="\t"} {sub(/:[0-9]+$/, ":0", $3); print}'\'' "$proof" > "$proof.fixture"
      mv "$proof.fixture" "$proof"
      export FM_TEST_RENAME_PHASE=new-proof NODE_OPTIONS="--require=\"$FM_HOME/pause.cjs\""
      if "$FM_BIN/fm-lock.sh"; then exit 4; fi
      : > "$FM_HOME/interrupted"
      while [ ! -e "$FM_HOME/resume-driver" ]; do sleep 0.05; done
      unset FM_TEST_RENAME_PHASE NODE_OPTIONS
      "$FM_BIN/fm-lock.sh"
      "$FM_BIN/fm-lock.sh" verify
    ' > "$home/attempt.out" 2>&1 &
    attempt=$!
    OWNER_RECORD_PIDS="${OWNER_RECORD_PIDS:-} $attempt"
    owner_fixture_wait "$home/paused-publisher"
    publisher=$(cat "$home/paused-publisher")
    pid=$(cat "$home/state/.lock")
    [ "$attempt" = "$pid" ] || fail "same-PID fixture changed the PID line"
    out=$(FM_HOME="$home" "$ROOT/bin/fm-lock.sh" status)
    if [ "$timing" = before ]; then
      assert_contains "$out" "lock: stale" "the fixture start mismatch was not proof of PID reuse"
    else
      assert_contains "$out" "held by live launch" "an atomically replaced same-PID proof was not visible"
    fi
    kill -KILL "$publisher" || fail "could not stop disposable same-PID publisher"
    owner_fixture_wait "$home/interrupted"
    : > "$home/resume-driver"
    wait "$attempt" || fail "the current launch could not resume same-PID recovery: $(cat "$home/attempt.out")"
  done
  pass "session lock: same-PID takeover commits at the proof rename and survives an interrupted publisher"
}

test_reused_publication_claimant_does_not_block_acquisition() {
  local home claim boot
  home=$(launch_owner_home reused-publication-claimant)
  claim="$home/state/.lock.acquire"
  mkdir "$claim"
  boot=$(cat /proc/sys/kernel/random/boot_id)
  printf '%s\n' "$$" > "$claim/pid"
  printf 'linux:%s:0\n' "$boot" > "$claim/start"
  FM_HOME="$home" timeout 5 "$ROOT/bin/fm-session-launch.sh" -- "$ROOT/bin/fm-lock.sh" \
    || fail "a different lifetime at the claimant PID blocked publication"
  assert_absent "$claim" "publisher left its acquisition claim behind"
  pass "session lock: PID reuse cannot pin the publication mutex"
}

test_paused_legacy_writer_cannot_cross_cutover() {
  local home fakebin legacy active
  home=$(lock_home paused-legacy-cutover)
  fakebin=$(fm_fakebin "$home/publication")
  mkdir -p "$home/config"
  cat > "$fakebin/ps" <<'SH'
#!/bin/bash
if [ -e "$FM_HOME/hold-legacy" ] && [ "$*" = "-o comm= -p $FM_TEST_LEGACY_PID" ]; then
  : > "$FM_HOME/legacy-in-flight"
  while [ -e "$FM_HOME/hold-legacy" ]; do sleep 0.05; done
fi
exec /bin/ps "$@"
SH
  chmod +x "$fakebin/ps"
  : > "$home/hold-legacy"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_FIXTURE_LOCK="$ROOT/bin/fm-lock.sh" "$CODEX_FIXTURE" -c '
    export FM_TEST_LEGACY_PID=$$
    "$FM_FIXTURE_LOCK"; exit $?
  ' > "$home/legacy-log" 2>&1 &
  legacy=$!
  OWNER_RECORD_PIDS="${OWNER_RECORD_PIDS:-} $legacy"
  owner_fixture_wait "$home/legacy-in-flight"
  printf 'launch-v1\n' > "$home/config/session-lock-owner"
  FM_HOME="$home" FM_FIXTURE_LOCK="$ROOT/bin/fm-lock.sh" "$ROOT/bin/fm-session-launch.sh" -- /bin/bash -ec '
    "$FM_FIXTURE_LOCK"
    "$FM_FIXTURE_LOCK" verify > "$FM_HOME/active-generation"
    while [ ! -e "$FM_HOME/owner-exit" ]; do sleep 0.05; done
    test "$(cat "$FM_HOME/active-generation")" = "$("$FM_FIXTURE_LOCK" verify)"
  ' > "$home/active-log" 2>&1 &
  active=$!
  OWNER_RECORD_PIDS="${OWNER_RECORD_PIDS:-} $active"
  owner_fixture_wait "$home/active-generation"
  rm "$home/hold-legacy"
  if wait "$legacy"; then fail 'in-flight legacy writer acquired after versioned cutover'; fi
  : > "$home/owner-exit"
  wait "$active" || fail 'in-flight legacy writer damaged the live versioned record'
  pass 'session lock: a legacy writer paused before cutover cannot replace a versioned owner'
}

if command -v node >/dev/null 2>&1 && [ "$(uname -s)" = Linux ]; then
  test_unreadable_lifetime_does_not_allow_takeover
  test_interrupted_publication_leaves_a_recoverable_record
  test_same_pid_reuse_commits_at_the_proof
  test_reused_publication_claimant_does_not_block_acquisition
  test_paused_legacy_writer_cannot_cross_cutover
fi

test_dead_launch_cannot_authorize_its_detached_child() {
  local home owner
  home=$(launch_owner_home orphaned-tool)
  cat > "$home/executor" <<'SH'
#!/bin/bash
set -eu
: > "$FM_HOME/executor-present"
for _ in $(seq 1 300); do [ ! -e "$FM_HOME/run-executor" ] || break; sleep 0.05; done
rc=0
"$FM_BIN/fm-watch-arm.sh" > "$FM_HOME/tool-output" 2>&1 || rc=$?
printf '%s\n' "$rc" > "$FM_HOME/tool-status"
SH
  chmod +x "$home/executor"
  FM_HOME="$home" FM_BIN="$ROOT/bin" "$ROOT/bin/fm-session-launch.sh" -- /bin/bash -ec '
    "$FM_BIN/fm-lock.sh"
    setsid -f "$FM_HOME/executor" </dev/null >/dev/null 2>&1
    while :; do sleep 0.05; done
  ' > "$home/owner.out" 2>&1 &
  owner=$!
  OWNER_RECORD_PIDS="${OWNER_RECORD_PIDS:-} $owner"
  owner_fixture_wait "$home/executor-present"
  kill -KILL "$owner" || fail "could not kill the disposable launch anchor"
  wait "$owner" 2>/dev/null || true
  FM_HOME="$home" "$ROOT/bin/fm-session-launch.sh" -- "$ROOT/bin/fm-lock.sh" || fail "SIGKILL did not release the dead launch"
  : > "$home/run-executor"
  owner_fixture_wait "$home/tool-status"
  [ "$(cat "$home/tool-status")" -ne 0 ] || fail "detached child mutated after losing its launch anchor"
  assert_grep "session launch no longer owns this home" "$home/tool-output" "detached child did not hit the ownership fence"
  pass "session lock: a reparented executor loses mutation authority on anchor SIGKILL"
}

if command -v node >/dev/null 2>&1 && [ "$(uname -s)" = Linux ]; then
  test_dead_launch_cannot_authorize_its_detached_child
fi

test_daemon_adapter_binds_the_continuing_process() {
  local home wrapper
  home=$(launch_owner_home daemon-adapter)
  cat > "$home/engine.mjs" <<'JS'
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { writeFileSync } from "node:fs";
const lock = process.env.FM_BIN + "/fm-lock.sh";
const call = (...args) => spawnSync(lock, args, { encoding: "utf8" });
assert.notEqual(process.env.FM_SESSION_OWNER_PID, String(process.pid));
assert.notEqual(call("verify").status, 0, "the foreground wrapper has exited");
const initial = process.env.FM_SESSION_OWNER_ID;
const result = call("bind-engine", String(process.pid));
assert.equal(result.status, 0, result.stderr);
const fields = ["HOME", "PID", "START", "ID", "KIND"];
result.stdout.trimEnd().split("\n").forEach((value, i) => {
  process.env["FM_SESSION_OWNER_" + fields[i]] = value;
});
assert.equal(process.env.FM_SESSION_OWNER_KIND, "native");
assert.notEqual(process.env.FM_SESSION_OWNER_ID, initial);
const acquired = call();
assert.equal(acquired.status, 0, acquired.stderr);
const verified = call("verify", String(process.pid));
assert.equal(verified.status, 0, verified.stderr);
writeFileSync(process.env.FM_HOME + "/native-generation", verified.stdout);
JS
  FM_HOME="$home" FM_BIN="$ROOT/bin" "$ROOT/bin/fm-session-launch.sh" -- /bin/bash -ec '
    "$FM_BIN/fm-lock.sh"
    "$FM_BIN/fm-lock.sh" verify > "$FM_HOME/wrapper-generation"
    setsid -f /bin/bash -c '\''
      for _ in $(seq 1 300); do [ ! -e "$FM_HOME/parent-exited" ] || break; sleep 0.05; done
      exec node "$FM_HOME/engine.mjs"
    '\'' </dev/null > "$FM_HOME/engine.out" 2>&1
  ' > "$home/wrapper.out" 2>&1 &
  wrapper=$!
  wait "$wrapper" || fail "foreground wrapper fixture failed"
  : > "$home/parent-exited"
  owner_fixture_wait "$home/native-generation"
  if cmp -s "$home/wrapper-generation" "$home/native-generation"; then
    fail "the daemonizing adapter inherited its finished wrapper generation"
  fi
  pass "session lock: a daemonizing adapter binds the continuing engine on its ready callback"
}

if command -v node >/dev/null 2>&1 && [ "$(uname -s)" = Linux ]; then
  test_daemon_adapter_binds_the_continuing_process
fi
