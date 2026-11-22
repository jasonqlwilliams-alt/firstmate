#!/usr/bin/env bash
# fm-timeout-lib.sh - the single owner of bounded command execution.
#
# Sourced, never executed. Provides one hard-bound runner so no caller has to
# re-derive the coreutils/BSD/perl selection, and so every bounded call in this
# repo agrees on what "the bound was hit" means.
#
#   fm_timeout_mechanism
#       Prints the mechanism fm_run_timed will use on this host: "timeout",
#       "gtimeout", "perl", or "bash". Set FM_TIMEOUT_MECHANISM_OVERRIDE=bash
#       to force the dependency-free fallback.
#
#   fm_run_timed [--kill] <seconds> <command> [args...]
#       Runs the command with a hard bound. Exit status is the command's own,
#       except 124, which means the bound was hit (GNU timeout's convention,
#       reproduced by the perl and bash fallbacks).
#       --kill uses KILL at the deadline when a timed-out operation cannot
#       safely continue during the normal TERM grace period.
#
# A non-positive bound is not a bound: `timeout 0` and the perl fallback's
# `alarm 0` both disable the deadline, so callers must reject 0 before calling.
#
# All four mechanisms terminate the whole process GROUP, not just the direct
# child, so a hung grandchild (a vendor CLI spawned by a wrapper script, a git
# fetch spawned by a sweep) cannot outlive the bound. GNU/BSD `timeout` does
# this by default because it does not run the command in the foreground process
# group. The Perl fallback sets up the group with setpgid before arming the
# alarm and signals it via a negative pid. The Bash fallback uses monitor
# mode to give the bounded child its own group before signaling it.
set -u

fm_timeout_mechanism() {
  if [ "${FM_TIMEOUT_MECHANISM_OVERRIDE:-}" = bash ]; then
    printf 'bash\n'
  elif command -v timeout >/dev/null 2>&1; then
    printf 'timeout\n'
  elif command -v gtimeout >/dev/null 2>&1; then
    printf 'gtimeout\n'
  elif command -v perl >/dev/null 2>&1; then
    printf 'perl\n'
  else
    printf 'bash\n'
  fi
}

fm_run_bash_timeout() {
  local seconds=$1 signal=$2 command_status deadline_status child_pid watchdog_pid command_rc recorded_rc monitor_was_on=0
  shift 2
  command_status=$(mktemp "${TMPDIR:-/tmp}/fm-bash-timeout-command.XXXXXX" 2>/dev/null) || return 124
  deadline_status="${command_status}.deadline"
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m
  (
    set +m
    "$@"
    command_rc=$?
    printf '%s\n' "$command_rc" > "$command_status"
    exit "$command_rc"
  ) &
  child_pid=$!
  (
    set +m
    sleep "$seconds"
    printf 'expired\n' > "$deadline_status"
    kill -s "$signal" -- "-$child_pid" 2>/dev/null || true
    if [ "$signal" = TERM ]; then
      sleep 0.2
      kill -KILL -- "-$child_pid" 2>/dev/null || true
    fi
    exit 124
  ) &
  watchdog_pid=$!
  [ "$monitor_was_on" -eq 1 ] || set +m

  if wait "$child_pid" 2>/dev/null; then
    command_rc=0
  else
    command_rc=$?
  fi
  if [ -s "$deadline_status" ]; then
    wait "$watchdog_pid" 2>/dev/null || true
    command_rc=124
  else
    kill -TERM -- "-$watchdog_pid" 2>/dev/null || kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    recorded_rc=$(cat "$command_status" 2>/dev/null || true)
    case "$recorded_rc" in ''|*[!0-9]*) ;; *) command_rc=$recorded_rc ;; esac
  fi
  rm -f "$command_status" "$deadline_status" 2>/dev/null || true
  return "$command_rc"
}

fm_run_external_timeout() {
  local runner=$1 seconds=$2 signal=$3 status_file runner_pid runner_rc command_rc
  local -a timeout_args
  shift 3
  timeout_args=(-k 1)
  [ "$signal" != KILL ] || timeout_args=(-s KILL)
  status_file=$(mktemp "${TMPDIR:-/tmp}/fm-timeout-status.XXXXXX" 2>/dev/null) || return 124
  # Run timeout asynchronously so its pid - also the process-group id created
  # by GNU/BSD timeout without --foreground - remains available for cleanup.
  # A shell wrapper can exit promptly on TERM while one of its descendants
  # ignores TERM; timeout then considers the command finished and does not send
  # its configured KILL. Explicitly reap that leftover group on a real timeout.
  # shellcheck disable=SC2016  # Expansion is deliberately deferred to the child shell.
  "$runner" "${timeout_args[@]}" "$seconds" bash -c '
    status_file=$1
    shift
    "$@"
    command_rc=$?
    printf "%s\n" "$command_rc" > "$status_file"
    exit "$command_rc"
  ' _ "$status_file" "$@" &
  runner_pid=$!
  if wait "$runner_pid"; then
    runner_rc=0
  else
    runner_rc=$?
  fi
  command_rc=$(cat "$status_file" 2>/dev/null || true)
  rm -f "$status_file" 2>/dev/null || true
  case "$command_rc" in
    ''|*[!0-9]*) ;;
    *) [ "$command_rc" -le 255 ] && return "$command_rc" ;;
  esac
  case "$runner_rc" in
    124|137)
      kill -KILL -- "-$runner_pid" 2>/dev/null || true
      return 124
      ;;
    *) return "$runner_rc" ;;
  esac
}

fm_monotonic_ms() {
  node -p 'String(process.hrtime.bigint() / 1000000n)'
}

fm_timeout_seconds() {  # <milliseconds>
  printf '%d.%03d' "$(( $1 / 1000 ))" "$(( $1 % 1000 ))"
}

fm_run_timed() {  # [--kill] <seconds> <command...>
  local seconds signal=TERM
  if [ "$1" = --kill ]; then
    signal=KILL
    shift
  fi
  seconds=$1
  shift
  case "$(fm_timeout_mechanism)" in
    timeout) fm_run_external_timeout timeout "$seconds" "$signal" "$@" ;;
    gtimeout) fm_run_external_timeout gtimeout "$seconds" "$signal" "$@" ;;
    perl)
      perl -MTime::HiRes=alarm -MPOSIX=setpgid -MErrno=EACCES,ESRCH -e '
        my ($timeout, $signal) = splice @ARGV, 0, 2;
        my $pid = fork;
        die "fork failed: $!" unless defined $pid;
        if (!$pid) {
          defined setpgid(0, 0) or die "child setpgid failed: $!";
          exec @ARGV or die "exec failed: $!";
        }
        defined setpgid($pid, $pid) or $! == EACCES or $! == ESRCH or die "parent setpgid failed: $!";
        local $SIG{ALRM} = sub {
          kill $signal, -$pid;
          if ($signal eq "TERM") {
            select undef, undef, undef, 0.2;
            kill "KILL", -$pid;
          }
          exit 124;
        };
        alarm $timeout;
        waitpid $pid, 0;
        exit($? >> 8);
      ' "$seconds" "$signal" "$@"
      ;;
    bash) fm_run_bash_timeout "$seconds" "$signal" "$@" ;;
    *) return 124 ;;
  esac
}
