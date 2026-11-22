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
attempt_record= output_dir=
trap '[ -z "$attempt_record" ] || rm -f -- "$attempt_record"; [ -z "$output_dir" ] || rm -rf -- "$output_dir"' EXIT
if [ -n "$checkpoint_session" ]; then
  rm -f -- "$RETURN_RECORD" || exit 1
  attempt_record=$(mktemp "$RETURN_RECORD.XXXXXX") || exit 1
  exec 3>"$attempt_record" || exit 1
  mv -f -- "$attempt_record" "$RETURN_RECORD" || exit 1
  attempt_record=
fi

case "$SECONDS_ARG" in
  ''|*[!0-9]*) echo "error: --seconds must be a positive integer" >&2; exit 2 ;;
  0) echo "error: --seconds must be greater than zero" >&2; exit 2 ;;
esac

output_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-watch-checkpoint.XXXXXX") || exit 1
OUT="$output_dir/out"
ERR="$output_dir/err"
export FM_WATCH_CHECKPOINT_CLOSE="$output_dir/close"

run_with_perl_timeout() {
  perl -e '
    my $seconds = shift;
    my $pid = fork;
    die "fork failed\n" unless defined $pid;
    if (!$pid) {
      setpgrp(0, 0);
      exec @ARGV;
      die "exec failed: $!\n";
    }
    local $SIG{ALRM} = sub {
      kill "TERM", -$pid;
      my $grace = $ENV{FM_SIGNAL_GRACE} || 5;
      local $SIG{ALRM} = sub {
        kill "KILL", -$pid;
        waitpid $pid, 0;
        exit 124;
      };
      alarm $grace;
      waitpid $pid, 0;
      exit 124;
    };
    alarm $seconds;
    waitpid $pid, 0;
    alarm 0;
    exit($? >> 8);
  ' "$SECONDS_ARG" "$SCRIPT_DIR/fm-watch.sh"
}

{
  if command -v timeout >/dev/null 2>&1; then
    timeout "$SECONDS_ARG" "$SCRIPT_DIR/fm-watch.sh"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$SECONDS_ARG" "$SCRIPT_DIR/fm-watch.sh"
  else
    run_with_perl_timeout
  fi
} 3>&- >"$OUT" 2>"$ERR"
RC=$?
close=$(cat "$FM_WATCH_CHECKPOINT_CLOSE" 2>/dev/null || true)

record_clean_return() {
  [ -z "$checkpoint_session" ] || printf '%s %s\n' "$close" "$checkpoint_session" >&3
}

if grep -E '^watcher: already running' "$OUT" "$ERR" >/dev/null 2>&1; then
  [ ! -s "$OUT" ] || cat "$OUT"
  [ ! -s "$ERR" ] || cat "$ERR" >&2
  echo "checkpoint: watcher is already running outside this foreground checkpoint" >&2
  exit 1
fi

if [ "$close" = quiet ] && [ "$RC" -eq 124 ]; then
  record_clean_return || exit 1
  printf 'checkpoint: no actionable wake within %ss\n' "$SECONDS_ARG"
  exit 124
fi

[ ! -s "$OUT" ] || cat "$OUT"
[ ! -s "$ERR" ] || cat "$ERR" >&2
if [ "$close" = wake ] && { [ "$RC" -eq 0 ] || [ "$RC" -eq 124 ]; }; then
  record_clean_return || exit 1
  exit 0
fi
if [ "$RC" -eq 0 ] || [ "$RC" -eq 124 ]; then
  echo "watcher: FAILED - checkpoint did not confirm a clean close" >&2
  exit 1
fi
exit "$RC"
