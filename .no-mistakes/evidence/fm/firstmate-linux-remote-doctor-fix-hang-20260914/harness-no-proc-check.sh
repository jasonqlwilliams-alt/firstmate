#!/usr/bin/env bash
# Hosts without /proc/self/fd (macOS) must keep inherited descriptors as before:
# the close helper is a no-op there. Simulated on Linux by hiding /proc in a
# mount namespace, then calling the real fm_backend_herdr_server_ensure with a
# long-lived fake herdr server while the caller holds a plain fd 7.
set -u
WORKTREE=$1; OUT=$2
d=$(mktemp -d /tmp/fm-noproc.XXXXXX); mkdir -p "$d/fakebin" "$d/emptyproc"
cat > "$d/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  status) if [ -e "$MARK" ]; then echo '{"server":{"running":true}}'; else echo '{"server":{"running":false}}'; fi ;;
  server) echo $$ > "$PIDF"; : > "$MARK"; while [ ! -e "$STOP" ]; do sleep 0.05; done ;;
esac
SH
chmod +x "$d/fakebin/herdr"
run_case() { # <label> <hide-proc 0|1>
  local label=$1 hide=$2 pid fds
  rm -f "$d/mark" "$d/stop" "$d/pid"
  MARK="$d/mark" STOP="$d/stop" PIDF="$d/pid" PATH="$d/fakebin:/usr/bin:/bin" \
  unshare -Urm /bin/bash -c '
    [ "$2" = 1 ] && mount -t tmpfs none /proc
    [ -d /proc/self/fd ] && echo "  /proc/self/fd present" || echo "  /proc/self/fd absent"
    . "$1/bin/backends/herdr.sh"
    exec 7> "$3/fd7-target"
    fm_backend_herdr_server_ensure probe >/dev/null 2>&1; echo "  server_ensure rc=$?"
  ' probe "$WORKTREE" "$hide" "$d"
  pid=$(cat "$d/pid")
  fds=$(ls -l /proc/"$pid"/fd | awk 'NR>1 {print $9 "->" $11}' | tr '\n' ' ')
  echo "  server pid $pid fds: $fds"
  : > "$d/stop"; sleep 0.3
}
{
  echo "== Linux with /proc: helper closes inherited fd 7 =="; run_case with-proc 0
  echo "== /proc hidden (macOS-like): helper leaves fd 7 alone =="; run_case no-proc 1
} | tee "$OUT"
rm -rf "$d"
