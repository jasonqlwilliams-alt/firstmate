#!/usr/bin/env bash
# Live end-to-end probe over real OpenSSH: `fm-on.sh <id> fm-remote-doctor.sh --fix` on Linux.
#
# Usage: live-doctor-fix.sh <commit> <label> <evidence-dir>
#
# What is real: bin/fm-on.sh, bin/fm-remote-entrypoint.sh, bin/fm-remote-doctor.sh,
# bin/backends/herdr.sh, the Linux remote job worker, and the installed herdr
# 0.9.0 binary (a real, long-lived `herdr server`).
# Transport: a real OpenSSH 10 client talks to a real, throwaway, non-root sshd
# on 127.0.0.1. FM_SSH_BIN only adds `-F <temp ssh_config>` (port, key, known
# hosts); fm-on.sh's own ssh flags are passed through unchanged. sshd runs in a
# user+mount namespace with a temp dir bind-mounted over /home/jason, so the
# entrypoint's `cd ~` and every --fix write land in the sandbox, never in the
# real home. tasks-axi, treehouse, and a harness CLI are stubs, because they are
# incidental required-tool checks.
set -u
SHA=$1
LABEL=$2
EVID=$3
WORKTREE=${WORKTREE:?}
BUDGET=${BUDGET:-60}
HOST_HERDR=${HOST_HERDR:-/home/jason/.local/bin/herdr}
ACCOUNT_USER=$(id -un)
ACCOUNT_HOME_PATH=$(getent passwd "$(id -u)" | cut -d: -f6)

W=$(mktemp -d "/tmp/fm-sshd-$LABEL.XXXXXX")
mkdir -p "$W/herdr-bin"
cp "$HOST_HERDR" "$W/herdr-bin/herdr"
REAL_HERDR="$W/herdr-bin/herdr"
ROOT="$W/root"
ACCOUNT="$W/remote-account"
REMOTE_FM_HOME="$W/remote-fmhome"
LOCAL_HOME="$W/local-home"
FAKEBIN="$W/fakebin"
LOG="$EVID/$LABEL.transcript.txt"
mkdir -p "$ROOT" "$ACCOUNT/.local/bin" "$REMOTE_FM_HOME" "$LOCAL_HOME/data" "$FAKEBIN" "$EVID"
: > "$LOG"
note() { printf '%s\n' "$*" | tee -a "$LOG"; }

git -C "$WORKTREE" archive "$SHA" | tar -x -C "$ROOT"
git -C "$ROOT" init -q
git -C "$ROOT" add -A
git -C "$ROOT" -c user.name=probe -c user.email=probe@example.invalid commit -qm "snapshot $SHA"

ln -s "$ROOT/bin/fm-remote-entrypoint.sh" "$ACCOUNT/.local/bin/fm-remote-entrypoint.sh"
cat > "$ACCOUNT/.local/bin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  --version:*) printf '0.2.4\n' ;;
  update:--help) printf '%s\n' --archive-body ;;
  mv:--help) printf '%s\n' 'usage: tasks-axi mv <id> [<id>...]' ;;
esac
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$ACCOUNT/.local/bin/treehouse"
printf '#!/usr/bin/env bash\nexit 0\n' > "$ACCOUNT/.local/bin/claude"
chmod +x "$ACCOUNT/.local/bin/tasks-axi" "$ACCOUNT/.local/bin/treehouse" "$ACCOUNT/.local/bin/claude"
ln -s "$W/herdr-bin/herdr" "$ACCOUNT/.local/bin/herdr"

printf -- '- linuxbox - Linux live probe (host: linuxbox; root: %s; home: %s; scope: live probe; projects: none; added 2026-09-14)\n' \
  "$ROOT" "$REMOTE_FM_HOME" > "$LOCAL_HOME/data/secondmates.md"

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
ssh-keygen -q -t ed25519 -N '' -f "$W/hostkey"
ssh-keygen -q -t ed25519 -N '' -f "$W/clientkey"
cp "$W/clientkey.pub" "$W/authorized_keys"
mkdir -p "$ACCOUNT/.ssh"
printf 'PATH=%s/.local/bin:/usr/bin:/bin\n' "$ACCOUNT_HOME_PATH" > "$ACCOUNT/.ssh/environment"
cat > "$W/sshd_config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $W/hostkey
PidFile $W/sshd.pid
AuthorizedKeysFile $W/authorized_keys
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitUserEnvironment PATH
AllowUsers $ACCOUNT_USER
ForceCommand $W/login-shell.sh
EOF
# Stands in for the login shell sshd runs the command through. Run 2 flips a
# flag so it keeps plain (not close-on-exec) copies of the channel on fds 7/8.
cat > "$W/login-shell.sh" <<EOF
#!/bin/bash
[ -e '$W/extra-fds.flag' ] && exec 7>&1 8>&2
exec /bin/bash -c "\$SSH_ORIGINAL_COMMAND"
EOF
chmod +x "$W/login-shell.sh"
printf '[127.0.0.1]:%s %s\n' "$PORT" "$(cut -d' ' -f1,2 "$W/hostkey.pub")" > "$W/known_hosts"
cat > "$W/ssh_config" <<EOF
Host linuxbox
  HostName 127.0.0.1
  Port $PORT
  User $ACCOUNT_USER
  IdentityFile $W/clientkey
  IdentitiesOnly yes
  IdentityAgent none
  UserKnownHostsFile $W/known_hosts
  GlobalKnownHostsFile /dev/null
  StrictHostKeyChecking yes
  BatchMode yes
EOF
cat > "$FAKEBIN/ssh-with-sandbox-config" <<EOF
#!/usr/bin/env bash
exec /usr/bin/ssh -F '$W/ssh_config' "\$@"
EOF
chmod +x "$FAKEBIN/ssh-with-sandbox-config"
unshare -Urm /bin/bash -c '
  mount --bind "$1" "$2" || exit 1
  exec unshare -U --map-user="$3" --map-group="$4" /usr/bin/sshd -D -e -f "$5"
' sshd-sandbox "$ACCOUNT" "$ACCOUNT_HOME_PATH" "$(id -u)" "$(id -g)" "$W/sshd_config" > "$W/sshd.log" 2>&1 < /dev/null &
SSHD_PID=$!
for _ in $(seq 1 50); do
  python3 -c 'import socket,sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 0.2)' "$PORT" 2>/dev/null && break
  sleep 0.1
done

cat > "$W/wait_eof.py" <<'PY'
import os, select, sys, time
path, timeout, start = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
fd = os.open(path, os.O_RDONLY)
end = start + timeout
while True:
    remaining = end - time.time()
    if remaining <= 0:
        print("EOF_AT=none", file=sys.stderr); sys.exit(124)
    ready, _, _ = select.select([fd], [], [], remaining)
    if not ready:
        print("EOF_AT=none", file=sys.stderr); sys.exit(124)
    chunk = os.read(fd, 65536)
    if not chunk:
        print("EOF_AT=%.2f" % (time.time() - start), file=sys.stderr); sys.exit(0)
    sys.stdout.buffer.write(chunk); sys.stdout.flush()
PY

sandbox_pids() {
  local p
  for p in /proc/[0-9]*; do
    { tr '\0' '\n' < "$p/environ"; } 2>/dev/null | grep -qF "$ROOT/bin" && printf '%s\n' "${p#/proc/}"
  done
}

describe_pids() {
  local p
  for p in $(sandbox_pids); do
    local pp
    pp=$(awk '/^PPid:/ {print $2}' "/proc/$p/status" 2>/dev/null)
    printf '  pid=%s ppid=%s (%s) cmd=%s\n' "$p" "$pp" "$({ tr '\0' ' ' < "/proc/$pp/cmdline"; } 2>/dev/null | cut -c1-60)" "$({ tr '\0' ' ' < "/proc/$p/cmdline"; } 2>/dev/null)"
    ls -l "/proc/$p/fd" 2>/dev/null | awk 'NR>1 && /pipe:|fake-ssh-chan/ {print "    fd " $9 " -> " $11}'
  done
}

# run_fix <run-label> [extra-fds]
run_fix() {
  local run=$1 extra=${2:-0} start r1 r2 p r1rc r2rc exit_at="" now
  rm -f "$W/cap.out" "$W/cap.err" "$W/extra-fds.flag"
  [ "$extra" = 1 ] && : > "$W/extra-fds.flag"
  mkfifo "$W/cap.out" "$W/cap.err"
  start=$(date +%s.%N)
  python3 "$W/wait_eof.py" "$W/cap.out" "$BUDGET" "$start" > "$W/$run.stdout" 2> "$W/$run.eof-out" & r1=$!
  python3 "$W/wait_eof.py" "$W/cap.err" "$BUDGET" "$start" > "$W/$run.stderr" 2> "$W/$run.eof-err" & r2=$!
  ( exec env PATH="/usr/bin:/bin" HOME="$LOCAL_HOME" FM_HOME="$LOCAL_HOME" \
      FM_SSH_BIN="$FAKEBIN/ssh-with-sandbox-config" \
      "$ROOT/bin/fm-on.sh" linuxbox fm-remote-doctor.sh --fix ) > "$W/cap.out" 2> "$W/cap.err" &
  p=$!
  while kill -0 "$p" 2>/dev/null; do
    now=$(date +%s.%N)
    if awk -v s="$start" -v n="$now" -v b="$BUDGET" 'BEGIN{exit !(n-s>=b)}'; then break; fi
    sleep 0.1
  done
  if kill -0 "$p" 2>/dev/null; then
    exit_at="still running at ${BUDGET}s"
    note "[$run] processes holding the capture at the ${BUDGET}s budget:"
    describe_pids | tee -a "$LOG"
    kill "$p" 2>/dev/null
  else
    wait "$p"; exit_at="exited rc=$? after $(awk -v s="$start" -v n="$(date +%s.%N)" 'BEGIN{printf "%.2f", n-s}')s"
  fi
  wait "$r1"; r1rc=$?
  wait "$r2"; r2rc=$?
  note "[$run] remote login shell holds extra plain fds 7/8 on the channel: $extra"
  note "[$run] fm-on.sh -> real ssh: $exit_at"
  note "[$run] stdout capture: $(cat "$W/$run.eof-out") (reader rc=$r1rc)"
  note "[$run] stderr capture: $(cat "$W/$run.eof-err") (reader rc=$r2rc)"
  note "[$run] --- remote stdout ---"
  grep -E '^(mode|platform|entrypoint|fix |check (herdr|herdr-server|remote-job|entrypoint-link)|ok:|error:)' "$W/$run.stdout" | tee -a "$LOG" >/dev/null
  cat "$W/$run.stdout" >> "$W/$run.full"
  note "[$run] --- remote stderr ---"
  tee -a "$LOG" < "$W/$run.stderr" >/dev/null
}

herdr_status() {
  env -i PATH=/usr/bin:/bin HOME="$ACCOUNT" "$REAL_HERDR" --session fm-remote status --json 2>/dev/null \
    | jq -c '{running: .server.running, socket: .server.socket}'
}

note "== $LABEL: commit $SHA =="
note "sandbox: $W"
note "herdr: $("$REAL_HERDR" --version)"
note "host: $(uname -sr)"
note "ssh: $(/usr/bin/ssh -V 2>&1); sshd pid $SSHD_PID on 127.0.0.1:$PORT"

note ""
note "## run 1: clean account, --fix must start the worker and the real herdr server"
run_fix run1 0
note "herdr fm-remote status after run1: $(herdr_status)"
note "sandbox processes after run1:"
describe_pids | tee -a "$LOG"

note ""
note "## stop only the herdr server; the worker keeps running"
env -i PATH=/usr/bin:/bin HOME="$ACCOUNT" "$REAL_HERDR" --session fm-remote server stop >> "$LOG" 2>&1 || true
for _ in $(seq 1 50); do [ "$(herdr_status | jq -r .running)" = false ] && break; sleep 0.1; done
for p in $(sandbox_pids); do
  case "$({ tr '\0' ' ' < "/proc/$p/cmdline"; } 2>/dev/null)" in *herdr*server*) kill "$p" 2>/dev/null ;; esac
done
sleep 0.5
note "herdr fm-remote status after stop: $(herdr_status)"

note ""
note "## run 2: adversarial - the remote shell holds plain fds 7/8 on the ssh channel; --fix restarts only the herdr server"
run_fix run2 1
note "herdr fm-remote status after run2: $(herdr_status)"
note "sandbox processes after run2:"
describe_pids | tee -a "$LOG"

note ""
note "## cleanup"
for sig in TERM KILL; do
  for p in $(sandbox_pids); do kill "-$sig" "$p" 2>/dev/null; done
  sleep 1
done
kill "$(cat "$W/sshd.pid" 2>/dev/null)" "$SSHD_PID" 2>/dev/null; wait "$SSHD_PID" 2>/dev/null
note "remaining sandbox processes: $(sandbox_pids | wc -l)"
cp "$W/sshd.log" "$EVID/$LABEL.sshd.log" 2>/dev/null
cp "$W/run1.full" "$EVID/$LABEL.run1.remote-stdout.txt" 2>/dev/null
cp "$W/run2.full" "$EVID/$LABEL.run2.remote-stdout.txt" 2>/dev/null
rm -rf "$W"
