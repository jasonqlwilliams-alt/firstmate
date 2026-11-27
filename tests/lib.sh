#!/usr/bin/env bash
# tests/lib.sh - shared primitives for firstmate behavior tests.
#
# Source this from a test file:
#   # shellcheck source=tests/lib.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# It provides the boilerplate every test file used to re-roll: ok/not-ok
# reporters, a self-cleaning temp root, fakebin/PATH-shim helpers, deterministic
# git identity and fixture builders, state/<id>.meta writers, and the common
# string/exit-code/file assertions. Shared fake-toolchain and spawn-world
# builders live in tests/fixtures.sh; wake-queue mocks in wake-helpers.sh;
# secondmate-lifecycle mocks in secondmate-helpers.sh. Suite-specific fakes
# that encode a single test's terminal or lifecycle assumptions still belong
# with the tests that own them.
#
# ROOT is exported as the firstmate repo root (this file lives in tests/), so a
# sourcing test can use "$ROOT/bin/..." without recomputing it.

# Idempotent guard: behavior-area helper files (secondmate-helpers.sh,
# wake-helpers.sh, fixtures.sh) source this library for ROOT/fail/pass, and the
# test that includes them may also source it directly. Re-sourcing must not wipe
# the registered-cleanup array or reset state.
if [ -n "${FM_TEST_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_LIB_SOURCED=1

# Pin the fixture umask. Firstmate's state-root and process-event contracts
# refuse group- or world-writable state directories, and a permissive ambient
# umask (e.g. 0002) makes every `mkdir state` fixture fail that contract before
# the behavior under test can even run. 022 is the conventional default this
# suite's fixtures were written against.
umask 022

# Fixture Git isolation for every suite that reaches this library; the helper's
# header owns the invariant and the layers it deliberately leaves in force.
# shellcheck source=tests/git-config-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/git-config-helpers.sh"

# Exempt firstmate's own test suite from the gate-lifecycle refusal
# (bin/fm-gate-refuse-lib.sh). The no-mistakes gate runs this suite FROM a gate
# worktree - the exact environment that guard refuses - so without this every
# test that drives the real fm-spawn/fm-send/fm-teardown would be refused during
# firstmate's own validation. A confused gate agent never sources this helper, so
# the boundary against the real hazard is unaffected. tests/fm-gate-refuse.test.sh
# strips this to verify real refusal.
export FM_GATE_REFUSE_BYPASS=1

# Clear the task-worker marker bin/fm-spawn.sh exports into ship and scout
# panes. This suite builds git-init fixture repositories whose primary checkout
# it runs a copied bin/fm-test-run.sh in, and that runner refuses the primary
# under the marker. A case that verifies the refusal sets FM_TASK_ID itself.
unset FM_TASK_ID

# Clear the tasks-axi env overrides. An operator shell exports TASKS_AXI_FILE
# (and may export TASKS_AXI_BACKEND) at its real home's backlog, and tasks-axi
# resolves that env AHEAD of the .tasks.toml a fixture copies, so a suite that
# seeds a temp home with bare `tasks-axi` would silently write the operator's
# live backlog instead - tests/fm-public-followup.test.sh did exactly that. Every
# fixture addresses its own data/backlog.md through its copied .tasks.toml, an
# explicit --file, or bin/fm-tasks-axi.sh; a case that verifies the wrapper
# against an ambient override sets TASKS_AXI_FILE itself.
unset TASKS_AXI_FILE TASKS_AXI_BACKEND

# Resolve the repo root from this library's own location. Consumed by sourcing
# test files, not by this library, so it reads as "unused" here.
# shellcheck disable=SC2034
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- reporters --------------------------------------------------------------

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

fm_test_lavish_toon_module() {
  if [ -n "${FM_TEST_LAVISH_CODEC_PATH:-}" ]; then
    printf '%s\n' "$FM_TEST_LAVISH_CODEC_PATH"
    return
  fi
  local lavish
  lavish=$(command -v lavish-axi) || return 1
  node --no-global-search-paths --experimental-import-meta-resolve --input-type=module - \
    "$ROOT/bin/fm-procevent-lavish-codec.mjs" "$lavish" <<'JS'
import { pathToFileURL } from 'node:url';
const { resolveInstalledToon } = await import(pathToFileURL(process.argv[2]).href);
console.log(resolveInstalledToon(process.argv[3]));
JS
}

fm_test_require_lavish_codec() {
  local codec
  if command -v node >/dev/null 2>&1 &&
     codec=$(fm_test_lavish_toon_module 2>/dev/null) && [ -f "$codec" ]; then
    return 0
  fi
  [ -z "${FM_TEST_LAVISH_CODEC_PATH:-}" ] || fail "cannot use the configured Lavish test codec"
  printf 'skip: %s requires Node.js and the Lavish TOON codec\n' "$1"
  return 1
}

fm_test_attach_lavish_codec() {
  local modules="$1/node_modules" codec
  codec=$(fm_test_lavish_toon_module) || return 1
  [ -f "$codec" ] || return 1
  mkdir -p "$modules/axi-sdk-js" "$modules/@toon-format/toon" &&
    printf '{"exports":"./index.mjs"}\n' > "$modules/axi-sdk-js/package.json" &&
    : > "$modules/axi-sdk-js/index.mjs" &&
    printf '{"exports":"./index.mjs"}\n' > "$modules/@toon-format/toon/package.json" &&
    ln -s "$codec" "$modules/@toon-format/toon/index.mjs"
}

fm_test_prepend_lavish_fixture() {
  [ -n "${FM_TEST_LAVISH_CODEC_PATH:-}" ] || return 0
  local fakebin
  fakebin=$(fm_fakebin "$1") && fm_fake_exit0 "$fakebin" lavish-axi &&
    fm_test_attach_lavish_codec "$fakebin" || return 1
  export PATH="$fakebin:$PATH"
}

# --- self-cleaning temp root ------------------------------------------------
#
# fm_test_tmproot <prefix> echoes a fresh temp dir and registers it for removal
# on ordinary or trapped exit. A test file that replaces the default EXIT trap
# must arrange for fm_test_cleanup to run so registered directories are still
# removed. For cleanup after SIGKILL, see detached fixture cleanup below.
#
# The call site is almost always `TMP_ROOT=$(fm_test_tmproot prefix)`, which
# forks a subshell to capture stdout. Anything that function does to the
# current shell's state - an array append, a trap - dies with that subshell
# and never reaches the real caller, so registration cannot go through
# in-process state. `$$` is the one thing bash keeps stable across that
# boundary (it always resolves to the invoking shell's PID, not the
# subshell's - see `man bash` on `$$`), so fm_test_tmproot records the
# directory in a `$$`-keyed registry file instead, and the trap that reaps
# that file is armed once, here, at source time - which always runs in the
# real caller, never a subshell.

FM_TEST_CLEANUP_DIRS=()

fm_test_stale_start_token() {
  local stale ticks
  case "$1" in
    proc:?*)
      ticks=${1#proc:}
      case "$ticks" in *[!0-9]*) return 1 ;; esac
      stale=proc:$((ticks > 1 ? ticks - 1 : ticks + 1))
      ;;
    lstart:?*) stale='lstart:Sat Jan  1 00:00:00 2000' ;;
    *) return 1 ;;
  esac
  [ "$stale" != "$1" ] || return 1
  printf '%s\n' "$stale"
}

# --- process-event runner reaping -------------------------------------------
#
# A process-event runner is detached into its own process group and reparents to
# init, so removing a fixture directory does not stop one: only sweeping the home
# that owns it does. Registration goes through a `$$`-keyed registry file for the
# same reason the temp roots do - a fixture home is almost always built inside a
# command substitution (`home=$(make_home x)`), and an array append there never
# reaches the caller, so a suite that tracked its homes in a shell array was
# silently tracking nothing and left every runner it started behind.
#
# The sweep is scoped to the exact home (and its claim root when the suite uses a
# private one). It never matches on a script or process name, which would reach
# into another home's live runners.

fm_test_track_procevent_home() {  # <home> [claim-root]
  [ -n "${1:-}" ] || return 1
  printf '%s\t%s\n' "$1" "${2-}" >> "$FM_TEST_PROCEVENT_REGISTRY"
}

fm_test_reap_procevent_homes() {
  local home claim_root seen=$'\n'
  [ -f "$FM_TEST_PROCEVENT_REGISTRY" ] || return 0
  while IFS=$'\t' read -r home claim_root; do
    [ -n "$home" ] || continue
    case "$seen" in *$'\n'"$home"$'\n'*) continue ;; esac
    seen+="$home"$'\n'
    [ -d "$home/state/procevent" ] || continue
    if [ -n "$claim_root" ]; then
      FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_PROCEVENT_CLAIM_ROOT="$claim_root" \
        "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
    else
      FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
        "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
    fi
  done < "$FM_TEST_PROCEVENT_REGISTRY"
  rm -f "$FM_TEST_PROCEVENT_REGISTRY"
}

# Ceiling on how long a fixture's blocking stub may keep polling. A stub that
# waits for a trigger file by re-running `sleep` is a high-frequency source of
# process spawns, and one that outlives its test - because the test was killed
# before any cleanup ran - is what turned leftover fixtures into a host-wide
# process storm. Every blocking stub this suite writes stops itself at this
# bound, so an escaped one is bounded in duration and cost on its own, before
# its owner's guard reaps it.
FM_TEST_STUB_MAX_BLOCK_SECONDS=${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}
export FM_TEST_STUB_MAX_BLOCK_SECONDS

fm_test_cleanup() {
  local d scratch status=0
  local -a dirs=("${FM_TEST_CLEANUP_DIRS[@]:-}")
  fm_test_reap_procevent_homes || status=1
  if [ -f "$FM_TEST_CLEANUP_REGISTRY" ]; then
    while IFS= read -r d; do
      case "$d" in
        treehouse-scratch$'\t'*)
          scratch=${d#*$'\t'}
          fm_test_treehouse_remove "$scratch" || status=1
          ;;
        '') ;;
        *) dirs+=("$d") ;;
      esac
    done < "$FM_TEST_CLEANUP_REGISTRY"
    rm -f "$FM_TEST_CLEANUP_REGISTRY" || status=1
  fi
  for d in "${dirs[@]}"; do
    [ -n "$d" ] || continue
    rm -rf -- "$d" || status=1
  done
  return "$status"
}

fm_test_track_treehouse_scratch() {
  printf 'treehouse-scratch\t%s\n' "$1" >> "$FM_TEST_CLEANUP_REGISTRY"
}

fm_test_cleanup_exit() {
  local status=$1
  shift
  "$@" || [ "$status" -ne 0 ] || status=1
  exit "$status"
}

fm_test_cleanup_after() {
  "$@" || true
  fm_test_cleanup
}

fm_test_track_task_tmps() {
  local fakebin=$1 real_mktemp
  real_mktemp=$(command -v mktemp) || return 1
  {
    printf '#!/usr/bin/env bash\nreal_mktemp=%q\nregistry=%q\n' "$real_mktemp" "$FM_TEST_CLEANUP_REGISTRY"
    cat <<'SH'
set -eu
path=$("$real_mktemp" "$@")
if [ "$#" -eq 2 ] && [ "$1" = -d ] && [[ "$2" =~ ^/tmp/fm-[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}\+XXXXXX$ ]]; then
  printf '%s\n' "$path" >> "$registry"
fi
printf '%s\n' "$path"
SH
  } > "$fakebin/mktemp"
  chmod +x "$fakebin/mktemp"
}

fm_test_tmproot() {
  local prefix=${1:-fm-test} root tmp_base
  tmp_base=${TMPDIR:-/tmp}
  tmp_base=${tmp_base%/}
  root=$(mktemp -d "$tmp_base/${prefix}.XXXXXX") || return 1
  root=$(cd -P -- "$root" && pwd -P) || return 1
  if ! printf '%s\n%s\n' "$$" "$FM_TEST_OWNER_IDENTITY" > "$root/.fm-test-fixture" ||
    ! printf '%s\n' "$root" >> "$FM_TEST_CLEANUP_REGISTRY"; then
    rm -rf "$root"
    return 1
  fi
  printf '%s\n' "$root"
}

# shellcheck source=tests/treehouse-test-helpers.sh
. "$ROOT/tests/treehouse-test-helpers.sh" || fail "cannot load Treehouse test setup"

if [ "${FM_TEST_FIXTURE_REAPER_CHILD:-0}" != 1 ]; then
  FM_TEST_CLEANUP_REGISTRY=$(mktemp "${FM_TEST_REGISTRY_DIR:-${TMPDIR:-/tmp}}/.fm-test-cleanup.$$.XXXXXX") || return 1
  FM_TEST_OWNER_IDENTITY=$(TZ=UTC0 fm_test_pid_identity "$$") || {
    rm -f "$FM_TEST_CLEANUP_REGISTRY"
    return 1
  }
  FM_TEST_PROCEVENT_REGISTRY=$(mktemp "${TMPDIR:-/tmp}/.fm-test-procevent.$$.XXXXXX") || return 1

  trap 'fm_test_cleanup_exit "$?" fm_test_cleanup' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  trap 'exit 131' QUIT

  FM_TEST_OWNED_TREEHOUSE=
  if [ -z "${FM_TEST_TREEHOUSE_DIR:-}" ] || [ ! -f "$FM_TEST_TREEHOUSE_DIR/.fm-test-treehouse" ]; then
    fm_test_treehouse_setup "$$" "$FM_TEST_OWNER_IDENTITY" || fail "cannot create a Treehouse test directory"
    FM_TEST_OWNED_TREEHOUSE=$FM_TEST_TREEHOUSE_DIR
    if ! fm_test_track_treehouse_scratch "$FM_TEST_TREEHOUSE_DIR"; then
      fm_test_treehouse_remove "$FM_TEST_TREEHOUSE_DIR"
      fail "cannot register the Treehouse test directory for cleanup"
    fi
  fi
fi

# --- detached fixture cleanup ----------------------------------------------
#
# Arm fm_test_arm_fixture_reaper before starting fixtures, then launch them
# through fm_test_start_fixture or fm_test_run_fixture. The launcher records
# the session and its anchor before executing the fixture so ownership survives
# reparenting and process-group changes within the session.
#
# The detached reaper signals groups from recorded sessions with live anchors
# using process IDs, group and session IDs, and process state. Keep the anchors
# until the fixture groups are gone so the reaper can still verify ownership.
# The reaper removes registered fixture roots after process cleanup succeeds.
# The EXIT trap waits for that cleanup. After SIGKILL the reaper detects the
# owner's exit and cleans up asynchronously.

fm_test_start_fixture() {
  local monitor_was_on=0
  case $- in *m*) monitor_was_on=1 ;; esac
  set +m
  # shellcheck disable=SC2016
  perl -MPOSIX=setsid -MFcntl=O_CREAT,O_EXCL,O_WRONLY -e '
    my $registry = shift;
    my $session = setsid();
    die "setsid: $!" unless defined($session) && $session > 1;
    pipe(my $registered, my $ready) or die "pipe: $!";
    my $anchor = fork();
    die "fork: $!" unless defined($anchor);
    if (!$anchor) {
      close $registered;
      setpgrp(0, 0) or die "setpgrp: $!";
      sysopen(my $record, "$registry/$session.$$", O_CREAT | O_EXCL | O_WRONLY, 0600)
        or die "record fixture session: $!";
      close $record;
      close STDIN;
      close STDOUT;
      close STDERR;
      print {$ready} "ready\n";
      close $ready;
      sleep;
      exit;
    }
    close $ready;
    exit 1 unless <$registered>;
    close $registered;
    exec { $ARGV[0] } @ARGV or die "exec $ARGV[0]: $!";
  ' "$FM_TEST_FIXTURE_SESSIONS" "$@" 3<&0 <&3 3<&- &
  FM_TEST_FIXTURE_PID=$!
  [ "$monitor_was_on" -eq 0 ] || set -m
  until compgen -G "$FM_TEST_FIXTURE_SESSIONS/$FM_TEST_FIXTURE_PID.*" >/dev/null; do
    if ! kill -0 "$FM_TEST_FIXTURE_PID" 2>/dev/null; then
      wait "$FM_TEST_FIXTURE_PID" 2>/dev/null || true
      return 1
    fi
    sleep 0.02
  done
}

fm_test_run_fixture() {
  fm_test_start_fixture "$@" || return 1
  wait "$FM_TEST_FIXTURE_PID"
}

fm_test_fixture_session_records() {
  local dir=$1 child record key
  if [ -d "$dir/sessions" ]; then
    mv "$dir/sessions" "$dir/closed-sessions" 2>/dev/null ||
      [ ! -d "$dir/sessions" ] || return 1
  fi
  for record in "$dir"/closed-sessions/*; do
    [ -f "$record" ] || continue
    key=${record##*/}
    printf 'session %s %s\n' "${key%.*}" "${key##*.}"
  done
  for child in "$dir"/children/*; do
    [ -d "$child" ] || continue
    fm_test_fixture_session_records "$child" || return 1
  done
}

fm_test_fixture_process_snapshot() {
  local rows
  case "$OSTYPE" in
    darwin*)
      rows=$(ps -ax -o pid= -o pgid= -o stat=) || return 1
      /usr/bin/ruby -e '
        STDIN.each_line do |row|
          pid, pgid, state = row.split
          next if pid.to_i <= 1 || state.start_with?("Z")
          begin
            puts [pid, pgid, Process.getsid(pid.to_i), state].join(" ")
          rescue Errno::ESRCH
          end
        end
      ' <<< "$rows"
      ;;
    *) ps -ax -o pid= -o pgid= -o sid= -o stat= ;;
  esac
}

fm_test_reap_fixture_processes() {
  local snapshot records groups kind pgid signal=TERM empty=0 round
  for ((round = 0; round < 20; round++)); do
    records=$(fm_test_fixture_session_records "$TMPDIR") || return 1
    snapshot=$(fm_test_fixture_process_snapshot) || return 1
    groups=$(awk '
      $1 == "session" { anchor[$2] = $3; next }
      $1 > 1 && $2 > 1 && $4 !~ /^Z/ && $3 in anchor {
        session[$2] = $3
        if ($1 == anchor[$3] && $2 == $1) owned[$3] = 1
      }
      END {
        for (pgid in session) {
          sid = session[pgid]
          if (sid in owned) print (pgid == anchor[sid] ? "anchor" : "fixture"), pgid
        }
      }
    ' <<< "$records"$'\n'"$snapshot") || return 1
    if [[ "$groups" == *fixture* ]]; then
      empty=0
    elif [ "$empty" -eq 0 ]; then
      empty=1
      sleep 0.2
      continue
    else
      [ -n "$groups" ] || return 0
      signal=KILL
    fi
    while read -r kind pgid; do
      if [ "$kind" = fixture ] || [ "$empty" -eq 1 ]; then
        kill -s "$signal" -- "-$pgid" 2>/dev/null || true
      fi
    done <<< "$groups"
    signal=KILL
    sleep 0.2
  done
  return 1
}

fm_test_owner_is_alive() {  # <pid> <identity>
  local state identity
  state=$(ps -p "$1" -o stat= 2>/dev/null) || return 1
  case "$state" in ''|Z*) return 1 ;; esac
  identity=$(TZ=UTC0 fm_test_pid_identity "$1" 2>/dev/null) || return 1
  [ "$identity" = "$2" ]
}

fm_test_cwd_sleeper_identity() {
  local pid=$1 command_name i
  for ((i=0; i<100; i++)); do
    command_name=$(ps -p "$pid" -o comm= 2>/dev/null) || return 1
    case "$command_name" in
      sleep|*/sleep) TZ=UTC0 fm_test_pid_identity "$pid"; return ;;
    esac
    sleep 0.05
  done
  return 1
}

fm_test_stop_sleeper() {
  local pid=$1 identity=$2
  if [ -n "$identity" ] && fm_test_owner_is_alive "$pid" "$identity"; then
    kill "$pid" 2>/dev/null || return 0
    wait "$pid" 2>/dev/null || true
  fi
}

fm_test_finish_fixture_reaper() {  # <exit status>
  local status=$1
  trap '' INT TERM HUP QUIT
  if ! rm -f -- "$FM_TEST_FIXTURE_REAPER_DIR/active" || ! wait "$FM_TEST_REAPER_PID"; then
    printf 'not ok - fixture reaper did not finish\n' >&2
    [ "$status" -ne 0 ] || status=1
  fi
  exit "$status"
}

fm_test_arm_fixture_reaper() {
  local monitor_was_on=0 owner_identity
  owner_identity=$(TZ=UTC0 fm_test_pid_identity "$$") || return 1
  FM_TEST_FIXTURE_REAPER_DIR=$1
  FM_TEST_FIXTURE_SESSIONS="$FM_TEST_FIXTURE_REAPER_DIR/sessions"
  mkdir "$FM_TEST_FIXTURE_SESSIONS" "$FM_TEST_FIXTURE_REAPER_DIR/children" || return 1
  : > "$FM_TEST_FIXTURE_REAPER_DIR/active" || return 1
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m
  # shellcheck disable=SC2016
  TMPDIR="$FM_TEST_FIXTURE_REAPER_DIR" FM_TEST_SKIP_ORPHAN_REAP=1 FM_TEST_FIXTURE_REAPER_CHILD=1 nohup bash -c '
    set -u
    FM_TEST_CLEANUP_REGISTRY=$4
    FM_TEST_PROCEVENT_REGISTRY=$5
    . "$1" || exit 1
    while [ -e "$TMPDIR/active" ] && fm_test_owner_is_alive "$2" "$3"; do
      sleep 0.2
    done
    fm_test_reap_fixture_processes || exit 1
    fm_test_cleanup || exit 1
    rm -rf -- "$TMPDIR"
  ' _ "$ROOT/tests/lib.sh" "$$" "$owner_identity" "$FM_TEST_CLEANUP_REGISTRY" \
    "$FM_TEST_PROCEVENT_REGISTRY" >/dev/null 2>&1 </dev/null &
  FM_TEST_REAPER_PID=$!
  [ "$monitor_was_on" -eq 1 ] || set +m
  trap 'fm_test_finish_fixture_reaper "$?"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  trap 'exit 131' QUIT
}

# A parent coordinator can reap once before it starts isolated child sections.
# Those children use their own EXIT cleanup and must not spend their bounded
# execution window repeating the same global stale-fixture scan.
if [ "${FM_TEST_SKIP_ORPHAN_REAP:-0}" != 1 ]; then
  fm_test_reap_orphans
  if [ ! "${TMPDIR:-/tmp}" -ef /tmp ]; then
    fm_test_reap_orphans /tmp fm-test-treehouse.
  fi
fi

# --- live-capability gate ---------------------------------------------------
#
# fm_live_gate <policy> <vars> [tool ...]
#
# The single gate every live-harness guard opens with, so "can this host run
# this guard for real, and should it?" is decided in one place instead of in
# two dozen hand-rolled env checks. It returns 0 when the guard should run, and
# otherwise ends the script with one runner-readable line:
#
#   skip: live: <tool> absent                 this host cannot run the guard
#   skip: live: disabled by <VAR>=0           an explicit local opt-out
#   skip: live: opt-in; set <VAR>=1 to run    a guard that spends model tokens
#
# <policy> is default-on for a guard that spends no model tokens, so it runs
# wherever its tools are installed - notably on the machine the product and its
# validation actually run on - and opt-in for a guard that submits prompts,
# which stays deliberate. <vars> is the guard's own control variable, or a
# comma-separated list when a guard has more than one entry point.
#
# Setting any of those variables to 1 (or FM_LIVE=1, for every guard at once)
# both turns the guard on and makes an absent tool a hard failure rather than a
# skip, which is how "run it after a harness upgrade" keeps proving the guard
# actually ran. Setting one to 0 (or FM_LIVE=0) turns it off; a guard's own
# variable wins over FM_LIVE.
#
# Sourcing this library also exports FM_GATE_REFUSE_BYPASS=1, which is what
# lets a live guard drive the real fm-spawn/fm-send/fm-teardown from inside a
# no-mistakes gate worktree instead of being refused by
# bin/fm-gate-refuse-lib.sh.

fm_live_gate() {
  local policy=$1 vars=$2
  shift 2
  local var value rest primary requested=0 disabled_by='' tool
  local -a var_list=()

  case "$policy" in
    default-on | opt-in) ;;
    *) fail "fm_live_gate: unknown policy '$policy' (expected default-on or opt-in)" ;;
  esac

  rest=$vars
  while [ -n "$rest" ]; do
    var=${rest%%,*}
    if [ "$var" = "$rest" ]; then
      rest=''
    else
      rest=${rest#*,}
    fi
    [ -n "$var" ] && var_list+=("$var")
  done
  [ "${#var_list[@]}" -gt 0 ] || fail "fm_live_gate: at least one control variable is required"
  primary=${var_list[0]}

  for var in "${var_list[@]}"; do
    value=${!var:-}
    case "$value" in
      1) requested=1 ;;
      0) [ -n "$disabled_by" ] || disabled_by=$var ;;
    esac
  done

  if [ "$requested" -eq 0 ]; then
    if [ -n "$disabled_by" ]; then
      printf 'skip: live: disabled by %s=0\n' "$disabled_by"
      exit 0
    fi
    case "${FM_LIVE:-}" in
      0)
        printf 'skip: live: disabled by FM_LIVE=0\n'
        exit 0
        ;;
      1) requested=1 ;;
      *)
        if [ "$policy" = opt-in ]; then
          printf 'skip: live: opt-in; set %s=1 to run\n' "$primary"
          exit 0
        fi
        ;;
    esac
  fi

  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 && continue
    if [ "$requested" -eq 1 ]; then
      printf 'not ok - %s was requested but %s is not installed\n' "$primary" "$tool" >&2
      exit 1
    fi
    printf 'skip: live: %s absent\n' "$tool"
    exit 0
  done

  return 0
}

# --- fakebin / PATH shims ---------------------------------------------------
#
# fm_fakebin <dir> creates <dir>/fakebin and echoes it; prepend it to PATH to
# shadow real tools with stubs. fm_fake_exit0 drops trivial exit-0 stubs for the
# named tools into a fakebin dir. fm_fake_crash_injector drops the shim a fake
# uses to crash the process under test deterministically. fm_fake_version_tool
# drops a stub for a tool whose installed version bootstrap gates, so a fixture
# cannot be reported as an unparseable build simply for answering `--version`
# with nothing.

fm_fakebin() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' "$fakebin"
}

fm_fake_tmux_window_ids() {  # <tmux args...>, reads ID and name pairs from stdin
  local id name target
  while [ "$#" -ge 2 ] && [ "$1" != -f ]; do shift; done
  [ "$#" -ge 2 ] || return 1
  case "$2" in
    '#{==:#{session_name}:#{window_name},'*'}')
      target=${2#'#{==:#{session_name}:#{window_name},'}
      target=${target%\}}
      ;;
    *) return 1 ;;
  esac
  while IFS=' ' read -r id name; do
    if [ "$name" = "$target" ]; then printf '%s\n' "$id"; fi
  done
}
export -f fm_fake_tmux_window_ids

fm_fake_tmux_new_window() {  # <inventory-file> <id> <new-window args...>
  local inventory=$1 id=$2 session name
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -t) session=${2%:}; session=${session#=}; shift ;;
      -n) name=$2; shift ;;
    esac
    shift
  done
  printf '%s %s:%s\n' "$id" "$session" "$name" >> "$inventory"
  printf '%s\n' "$id"
}
export -f fm_fake_tmux_new_window

fm_fake_exit0() {
  local fakebin=$1 tool
  shift
  for tool in "$@"; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
}

# fm_fake_crash_injector <fakebin>
# Drops an `fm-crash-inject <pid>` shim that a PATH fake calls to simulate a
# hard crash of the process under test. It SIGKILLs <pid> and then returns only
# once that process is observably gone, so the fake never resumes work while its
# victim could still be running. Sleeping a fixed interval instead makes the
# injection a wall-clock bet that a loaded host loses: the fake wakes up and
# completes the very operation the case needs left unfinished. Exits non-zero
# with a diagnostic if the target outlives the signal, so a broken injection
# fails loudly rather than silently changing what the case measures.
fm_fake_crash_injector() {
  local fakebin=$1
  cat > "$fakebin/fm-crash-inject" <<'SH'
#!/usr/bin/env bash
set -u
target=${1:?fm-crash-inject: <pid> required}
case "$target" in
  ''|*[!0-9]*)
    echo "fm-crash-inject: '$target' is not a pid" >&2
    exit 1
    ;;
esac
kill -KILL "$target" 2>/dev/null || true
waited=0
while [ "$waited" -lt 600 ]; do
  case "$(ps -o state= -p "$target" 2>/dev/null | tr -d '[:space:]')" in
    ''|Z*) exit 0 ;;
  esac
  waited=$((waited + 1))
  sleep 0.05
done
echo "fm-crash-inject: pid $target still running 30s after SIGKILL" >&2
exit 1
SH
  chmod +x "$fakebin/fm-crash-inject"
}

# fm_fake_version_tool <fakebin> <tool> <override-env-var> <default-version> [version-flag]
# The stub answers the version flag (default `--version`) with <override-env-var> when that variable is set
# and non-empty, and with <default-version> otherwise; every other invocation
# exits 0. A case that needs to drive a version floor exports the variable.
fm_fake_version_tool() {
  local fakebin=$1 tool=$2 override=$3 default=$4 version_flag=${5:---version}
  cat > "$fakebin/$tool" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = '$version_flag' ]; then
  printf '%s\n' "\${$override:-$default}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/$tool"
}

# --- portable file timestamps -----------------------------------------------

# fm_touch_epoch <epoch> <path> [path...]: set each path's modification time to
# an absolute epoch second on every supported host.
#
# There is no portable touch(1) flag that takes an epoch: `touch -d @<epoch>` is
# a GNU extension and BSD touch rejects it outright ("out of range or illegal
# time specification"), leaving the file at its current mtime. A test that wants
# a beacon aged 700 seconds then silently measures a brand-new one.
# `touch -t [[CC]YY]MMDDhhmm[.SS]` is POSIX and both accept it, so the only
# host-specific step left is turning the epoch into that stamp, and date(1)
# spells that two incompatible ways. Probe them in this order: GNU date rejects
# `-r <seconds>` (its -r takes a file), while BSD date rejects `-d` as an
# illegal option, so whichever runs is the one that understood the request.
# TZ is pinned to UTC for date and touch so repeated DST hours stay unambiguous.
fm_touch_epoch() {
  local epoch=$1 stamp
  shift
  stamp=$(TZ=UTC0 date -d "@$epoch" +%Y%m%d%H%M.%S 2>/dev/null) \
    || stamp=$(TZ=UTC0 date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null) \
    || fail "fm_touch_epoch: date(1) accepted neither -d @<epoch> nor -r <epoch>"
  TZ=UTC0 touch -t "$stamp" "$@" \
    || fail "fm_touch_epoch: touch -t $stamp failed for $*"
}

# --- deterministic git identity and fixtures --------------------------------

# fm_git_identity [name] [email]: export a fixed author/committer identity so
# fixture commits never depend on the host git config.
fm_git_identity() {
  export GIT_AUTHOR_NAME=${1:-fmtest} GIT_AUTHOR_EMAIL=${2:-fmtest@example.invalid}
  export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
}

# fm_git_init_commit <dir>: create a git repo at <dir> with a README and one
# commit. Uses an inline identity so it works whether or not fm_git_identity was
# called. The initial branch is pinned rather than inherited from
# init.defaultBranch, so a fixture that names main resolves the same on a
# developer machine and on a runner that still defaults to master.
fm_git_init_commit() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  printf '# %s\n' "$(basename "$dir")" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

# fm_git_add_origin <repo> <bare>: clone <repo> bare into <bare> and register it
# as <repo>'s origin via a file:// URL (so later clones resolve an absolute path).
fm_git_add_origin() {
  local repo=$1 remote=$2 remote_abs
  git clone --quiet --bare "$repo" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$repo" remote add origin "file://$remote_abs"
}

# fm_git_worktree <repo> <worktree> <branch>: initialize <repo> with one commit
# and a local bare origin, then add a worktree on a fresh branch.
fm_git_worktree() {
  local repo=$1 worktree=$2 branch=$3
  fm_git_init_commit "$repo"
  fm_git_add_origin "$repo" "$repo.origin.git"
  git -C "$repo" worktree add --quiet -b "$branch" "$worktree"
}

# --- state/<id>.meta writers ------------------------------------------------

# fm_write_meta <file> <key=val> ...: write the given key=val lines to a meta
# file (truncating any prior content).
fm_write_meta() {
  local file=$1 kv
  shift
  : > "$file"
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$file"
  done
}

# fm_write_secondmate_meta <file> <home> [window] [projects] [harness]: write the
# standard kind=secondmate meta block used across the secondmate suites. Window
# defaults to firstmate:fm-<id>, projects defaults to alpha, and harness defaults
# to echo to match the common case.
fm_write_secondmate_meta() {
  local file=$1 home=$2 id window projects=${4:-alpha} harness=${5:-echo}
  id=$(basename "$file" .meta)
  window=${3:-firstmate:fm-$id}
  fm_write_meta "$file" \
    "window=$window" \
    "endpoint_task_id=$id" \
    "worktree=$home" \
    "project=$home" \
    "harness=$harness" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "home=$home" \
    "projects=$projects"
}

# --- common assertions ------------------------------------------------------

# assert_equals <expected> <actual> <msg>
assert_equals() {
  [ "$1" = "$2" ] || fail "$3 (expected '$1', got '$2')"
}

# assert_not_equals <unexpected> <actual> <msg>
assert_not_equals() {
  [ "$1" != "$2" ] || fail "$3 (unexpectedly got '$1')"
}

# assert_contains <haystack> <needle> <msg>
assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3 (missing: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
  esac
}

# assert_not_contains <haystack> <needle> <msg>
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 (unexpected: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

# expect_code <expected> <actual> <label>
expect_code() {
  local expected=$1 actual=$2 label=$3
  [ "$actual" = "$expected" ] || fail "$label: expected exit $expected, got $actual"
}

# assert_grep <pattern> <file> <msg>: fixed-string grep must match in <file>.
# `--` guards patterns that begin with '-' (e.g. backlog/registry lines).
assert_grep() {
  grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_no_grep <pattern> <file> <msg>: fixed-string grep must NOT match.
assert_no_grep() {
  ! grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_absent <path> <msg>: path must not exist.
assert_absent() {
  [ ! -e "$1" ] || fail "$2"
}

# assert_present <path> <msg>: path must exist.
assert_present() {
  [ -e "$1" ] || fail "$2"
}

# fm_test_base_path_sans <base_path> <tool...>: returns the path to a single
# curated directory that resolves every tool <base_path> would have resolved,
# except the named ones. Some hosts have real system binaries (node, orca,
# ...) sitting in BASE_PATH; a fixture that simulates a tool as missing by
# omitting it from fakebin still falls through to that host binary via
# BASE_PATH, silently defeating the simulation. Dropping whole directories
# out of BASE_PATH is not a safe fix: on a usr-merged host /bin, /sbin, and
# /usr/sbin are symlinks that collapse to the same directory as /usr/bin, so
# dropping any one of them because it resolves the excluded tool drops every
# other tool a test still needs (git, awk, sed, ...) too. Building a curated
# directory instead hides only the named tool(s). Use only at the specific
# assertions that simulate a tool as absent - every other case keeps using
# bare BASE_PATH.
fm_test_base_path_sans() {
  local base_path=$1 dir src entry name tool skip
  shift
  local tools=("$@")
  dir=$(fm_test_tmproot fm-base-path-sans) || return 1
  local dirs
  IFS=: read -ra dirs <<< "$base_path"
  for src in "${dirs[@]}"; do
    [ -d "$src" ] || continue
    for entry in "$src"/*; do
      [ -e "$entry" ] || [ -L "$entry" ] || continue
      name=${entry##*/}
      [ -e "$dir/$name" ] && continue
      skip=0
      for tool in "${tools[@]}"; do
        if [ "$name" = "$tool" ]; then
          skip=1
          break
        fi
      done
      [ "$skip" -eq 1 ] && continue
      ln -s "$entry" "$dir/$name" 2>/dev/null || true
    done
  done
  printf '%s\n' "$dir"
}
