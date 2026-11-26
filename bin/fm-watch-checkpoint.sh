#!/usr/bin/env bash
# Run one bounded foreground watcher checkpoint for harnesses that should not
# rely on background-task completion to wake the model.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RETURN_RECORD="$STATE/.last-checkpoint-return"
SECONDS_ARG=${FM_CODEX_WATCH_CHECKPOINT:-180}

# shellcheck source=bin/fm-wake-lib.sh
FM_WAKE_NO_MKDIR=1 . "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  cat <<'EOF'
Usage: fm-watch-checkpoint.sh [--seconds <n>]

Run bin/fm-watch.sh in the foreground for a bounded checkpoint.
On an actionable watcher wake, pass through the watcher output and exit 0.
On a quiet checkpoint, print "checkpoint: no actionable wake within <n>s" and exit 124.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --seconds)
      [ "$#" -gt 1 ] || { echo "error: --seconds requires a value" >&2; exit 2; }
      SECONDS_ARG=$2
      shift 2
      ;;
    --seconds=*)
      SECONDS_ARG=${1#--seconds=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

checkpoint_session=$(fm_codex_checkpoint_session "$STATE") || checkpoint_session=
attempt_record='' output_dir=''
trap '[ -z "$attempt_record" ] || rm -f -- "$attempt_record"; [ -z "$output_dir" ] || rm -rf -- "$output_dir"' EXIT
if [ -n "$checkpoint_session" ]; then
  if { rm -f -- "$RETURN_RECORD" \
    && attempt_record=$(mktemp "$RETURN_RECORD.XXXXXX") \
    && exec 3>"$attempt_record" \
    && mv -f -- "$attempt_record" "$RETURN_RECORD"; } 2>/dev/null; then
    attempt_record=
  else
    checkpoint_session=
  fi
fi

case "$SECONDS_ARG" in
  ''|*[!0-9]*) echo "error: --seconds must be a positive integer" >&2; exit 2 ;;
  0) echo "error: --seconds must be greater than zero" >&2; exit 2 ;;
esac

output_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-watch-checkpoint.XXXXXX") || exit 1
OUT="$output_dir/out"
ERR="$output_dir/err"
export FM_WATCH_CHECKPOINT_CLOSE=''
if [ -n "$checkpoint_session" ]; then
  FM_WATCH_CHECKPOINT_CLOSE="$output_dir/close"
fi

run_with_coreutils_timeout() {
  # shellcheck disable=SC2016
  "$1" -k 5 "$SECONDS_ARG" bash -c '
    trap ":" TERM
    "$1"
    status=$?
    if [ "$status" -eq 137 ]; then
      : > "$2"
    fi
    exit "$status"
  ' _ "$SCRIPT_DIR/fm-watch.sh" "$output_dir/watcher-killed"
}

run_with_perl_timeout() {
  local kill_after=${FM_SIGNAL_GRACE:-5}
  case "$kill_after" in
    *[!0-9]*) kill_after=5 ;;
    *[1-9]*) ;;
    *) kill_after=5 ;;
  esac
  perl -e '
    my $seconds = shift;
    my $grace = shift;
    my $pid = fork;
    die "fork failed\n" unless defined $pid;
    if (!$pid) {
      setpgrp(0, 0);
      exec @ARGV;
      die "exec failed: $!\n";
    }
    # Unwind the first alarm handler before starting the second timed wait.
    # Perl defers another ALRM while its handler is active.
    sub wait_with_deadline {
      my ($child, $limit) = @_;
      my $deadline = "checkpoint wait expired\n";
      local $SIG{ALRM} = sub { die $deadline };
      my $status = eval {
        alarm $limit;
        waitpid $child, 0;
        my $child_status = $?;
        alarm 0;
        $child_status;
      };
      die $@ if $@ ne "" && $@ ne $deadline;
      return $status;
    }
    my $status = wait_with_deadline($pid, $seconds);
    exit($status >> 8) if defined $status;
    kill "TERM", -$pid;
    exit 124 if defined wait_with_deadline($pid, $grace);
    kill "KILL", -$pid;
    waitpid $pid, 0;
    exit 137;
  ' "$SECONDS_ARG" "$kill_after" "$SCRIPT_DIR/fm-watch.sh"
}

{
  if command -v timeout >/dev/null 2>&1; then
    run_with_coreutils_timeout timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    run_with_coreutils_timeout gtimeout
  else
    run_with_perl_timeout
  fi
} 3>&- >"$OUT" 2>"$ERR"
RC=$?
close=''
if [ "$RC" -eq 137 ] && [ ! -e "$output_dir/watcher-killed" ]; then
  RC=124
elif [ -n "$FM_WATCH_CHECKPOINT_CLOSE" ]; then
  close=$(cat "$FM_WATCH_CHECKPOINT_CLOSE" 2>/dev/null || true)
fi

record_clean_return() {
  printf '%s %s\n' "$close" "$checkpoint_session" 2>/dev/null >&3 || true
}

# Exit codes and output keep the checkpoint contract above; a confirmed clean
# close from the watcher only decides whether the return record is written.
if grep -E '^(signal:|stale:|check:|heartbeat($|:))' "$OUT" >/dev/null 2>&1; then
  cat "$OUT" || exit 1
  [ ! -s "$ERR" ] || cat "$ERR" >&2 || exit 1
  if [ "$close" = wake ]; then
    record_clean_return
  fi
  exit 0
fi

if grep -E '^watcher: already running' "$OUT" "$ERR" >/dev/null 2>&1; then
  [ ! -s "$OUT" ] || cat "$OUT" || exit 1
  [ ! -s "$ERR" ] || cat "$ERR" >&2 || exit 1
  echo "checkpoint: watcher is already running outside this foreground checkpoint" >&2
  exit 1
fi

if [ "$RC" -eq 124 ]; then
  printf 'checkpoint: no actionable wake within %ss\n' "$SECONDS_ARG" || exit 1
  grep -Fx 'watcher: active capture cleanup failed during shutdown' "$ERR" >&2 || true
  if [ "$close" = quiet ]; then
    record_clean_return
  fi
  exit 124
fi

[ ! -s "$OUT" ] || cat "$OUT" || exit 1
[ ! -s "$ERR" ] || cat "$ERR" >&2 || exit 1
exit "$RC"
