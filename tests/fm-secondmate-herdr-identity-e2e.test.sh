#!/usr/bin/env bash
# Real Herdr, fake agents: secondmate recovery must reject recycled pane ids
# and recover several homes in one bootstrap pass without task-set contention.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
fm_live_gate default-on FM_SECONDMATE_HERDR_IDENTITY_E2E herdr jq

TMP_ROOT=$(fm_test_tmproot fm-secondmate-herdr-identity)
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name secondmate-liveness-recycled-herdr-pane-20261114)
HERDR_ORIGINAL_PATH=$PATH
export HERDR_LAB_HELPER HERDR_LAB_SESSION HERDR_ORIGINAL_PATH
cleanup() {
  local rc=$?
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || rc=1
  fm_test_cleanup
  exit "$rc"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
lab status --json | jq -r '"Herdr secondmate identity lab version: \(.client.version)"'

FAKEBIN="$TMP_ROOT/fakebin"
PRIMARY="$TMP_ROOT/primary"
mkdir -p "$FAKEBIN" "$PRIMARY"/{state,data,config,projects}
export FM_LAB_CALLS="$TMP_ROOT/calls" FM_LAB_ROOT="$TMP_ROOT"
: > "$FM_LAB_CALLS"
printf 'codex\n' > "$PRIMARY/config/secondmate-harness"
printf 'herdr\n' > "$PRIMARY/config/backend"

# All production Herdr calls go through the mandated helper. Inputs are stubbed
# screens: no harness command or doorbell can execute, even if spawn regresses.
# Delay tab creation while real fm-spawn holds its task-set lock so contention
# is deterministic rather than depending on scheduler speed.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
args=("$@")
n=${#args[@]}
if [ "$n" -ge 2 ] && [ "${args[$((n-2))]}" = --session ]; then
  [ "${args[$((n-1))]}" = "$HERDR_LAB_SESSION" ] || exit 91
  unset 'args[n-1]' 'args[n-2]'
fi
set -- "${args[@]}"
printf '%s\n' "$*" >> "$FM_LAB_CALLS"
if [ "$1 $2" = 'pane process-info' ] && [ "${3:-}" = --pane ] \
  && [ "${4:-}" = "${FM_LAB_UNREADABLE_PANE:-}" ]; then exit 94; fi
case "$1 $2" in
  'pane send-text'|'pane send-keys') exit 0 ;;
  'tab create')
    if [ -n "${FM_LAB_FAIL_LABEL:-}" ]; then
      for arg in "$@"; do [ "$arg" != "$FM_LAB_FAIL_LABEL" ] || exit 93; done
    fi
    sleep 1 ;;
esac
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
cat > "$FAKEBIN/codex" <<'SH'
#!/usr/bin/env bash
echo 'fake-codex: must never launch' >&2
exit 92
SH
for tool in gh no-mistakes tasks-axi; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/$tool"
done
chmod +x "$FAKEBIN"/*

make_home() {
  local id=$1 home="$TMP_ROOT/$1"
  mkdir -p "$home"/{bin,state,data,config,projects}
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf '# Fixture\n' > "$home/AGENTS.md"
  printf 'fixture charter\n' > "$home/data/charter.md"
}
record() { # <id> <pane> <workspace>
  cat > "$PRIMARY/state/$1.meta" <<EOF
kind=secondmate
harness=codex
backend=herdr
window=$HERDR_LAB_SESSION:$2
herdr_session=$HERDR_LAB_SESSION
herdr_pane_id=$2
herdr_workspace_id=$3
home=$TMP_ROOT/$1
EOF
}
make_agent() { # <cwd> <label>; return pane<TAB>workspace
  local out pane ws cwd=$1
  out=$(lab workspace create --cwd "$cwd" --label "$2" --no-focus)
  pane=$(printf '%s' "$out" | jq -er '.result.root_pane.pane_id')
  ws=$(printf '%s' "$out" | jq -er '.result.workspace.workspace_id')
  # Prove this is our just-created screen before typing anything into it.
  lab pane get "$pane" | jq -e --arg cwd "$cwd" --arg ws "$ws" \
    '.result.pane | .cwd == $cwd and .workspace_id == $ws' >/dev/null
  lab pane send-text "$pane" 'sleep 600' >/dev/null
  lab pane send-keys "$pane" enter >/dev/null
  lab pane report-agent "$pane" --source fm-identity-test --agent fake-agent --state idle >/dev/null
  printf '%s\t%s\n' "$pane" "$ws"
}
probe() { # <pane> [<home>]
  PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" bash -c '
    . "$1/bin/fm-backend.sh"
    if [ -n "$4" ]; then
      fm_backend_agent_state herdr "$2:$3" "$4"
    else
      fm_backend_agent_state herdr "$2:$3"
    fi
  ' _ "$ROOT" "$HERDR_LAB_SESSION" "$1" "${2:-}"
}
sweep() {
  env PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" FM_HOME="$PRIMARY" FM_ROOT_OVERRIDE="$ROOT" \
    FM_BACKEND=herdr HERDR_SESSION="$HERDR_LAB_SESSION" FM_BOOTSTRAP_NETWORK=only \
    FM_BOOTSTRAP_VERBOSE_FACTS=1 FM_SKIP_SECONDMATE_INHERIT=1 \
    "$ROOT/bin/fm-bootstrap.sh" > "$TMP_ROOT/sweep.out" 2>&1
}

for id in owner collision-sm collision-primary unreadable unbound absent-a absent-b absent-c failure-a failure-z; do make_home "$id"; done
for id in owner collision-sm collision-primary absent-a absent-b absent-c failure-a failure-z; do
  printf -- '- %s - fixture (home: %s; scope: fixture; projects: none; added 2026-11-14)\n' \
    "$id" "$TMP_ROOT/$id" >> "$PRIMARY/data/secondmates.md"
done
IFS=$'\t' read -r OWNER_PANE OWNER_WS < <(make_agent "$TMP_ROOT/owner" 2ndmate-owner)
IFS=$'\t' read -r PRIMARY_PANE PRIMARY_WS < <(make_agent "$PRIMARY" firstmate)
sleep 0.2
[ "$(probe "$OWNER_PANE")" = alive ] || fail 'fake agent must reproduce an alive recovery verdict'
[ "$(probe "$PRIMARY_PANE")" = alive ] || fail 'non-secondmate fake agent must read alive'
record owner "$OWNER_PANE" "$OWNER_WS"
record collision-sm "$OWNER_PANE" "$OWNER_WS"
record collision-primary "$PRIMARY_PANE" "$PRIMARY_WS"
sed "s|^home=$TMP_ROOT/collision-sm$|worktree=$TMP_ROOT/collision-sm|" \
  "$PRIMARY/state/collision-sm.meta" > "$TMP_ROOT/collision-sm.meta"
mv "$TMP_ROOT/collision-sm.meta" "$PRIMARY/state/collision-sm.meta"
sed '/^home=/d' "$PRIMARY/state/collision-primary.meta" > "$TMP_ROOT/collision-primary.meta"
mv "$TMP_ROOT/collision-primary.meta" "$PRIMARY/state/collision-primary.meta"
record unreadable "$OWNER_PANE" "$OWNER_WS"
record unbound "$OWNER_PANE" "$OWNER_WS"
sed '/^home=/d' "$PRIMARY/state/unbound.meta" > "$TMP_ROOT/unbound.meta"
mv "$TMP_ROOT/unbound.meta" "$PRIMARY/state/unbound.meta"
mv "$TMP_ROOT/unreadable" "$TMP_ROOT/unreadable-unavailable"
export FM_LAB_UNREADABLE_PANE=$PRIMARY_PANE
[ "$(probe "$PRIMARY_PANE")" = unreadable ] || fail 'process-info failure did not make the agent probe unreadable'
[ "$(probe "$PRIMARY_PANE" "$TMP_ROOT/collision-primary")" = missing ] || fail 'foreign pane with unreadable process info was not missing'
sweep
unset FM_LAB_UNREADABLE_PANE
identity_failed=0
for id in collision-sm collision-primary; do
  pane=$(sed -n 's/^herdr_pane_id=//p' "$PRIMARY/state/$id.meta")
  case "$pane" in "$OWNER_PANE"|"$PRIMARY_PANE") identity_failed=1 ;; esac
done
if [ "$identity_failed" = 1 ]; then
  printf 'not ok - bootstrap retained recycled routes for wrong-home secondmates\n'
  cat "$TMP_ROOT/sweep.out"
else
  pass 'bootstrap replaces both another secondmate and a non-secondmate recycled route'
fi
# The unrelated agents must survive, and the matching home must keep its route.
[ "$(probe "$OWNER_PANE")" = alive ] || fail 'recovery killed the other secondmate'
[ "$(probe "$PRIMARY_PANE")" = alive ] || fail 'recovery killed the primary-shaped agent'
[ "$(sed -n 's/^herdr_pane_id=//p' "$PRIMARY/state/owner.meta")" = "$OWNER_PANE" ] || fail 'matching owner was respawned'
[ "$(sed -n 's/^herdr_pane_id=//p' "$PRIMARY/state/unreadable.meta")" = "$OWNER_PANE" ] || fail 'unreadable home identity must preserve its route'
[ "$(sed -n 's/^herdr_pane_id=//p' "$PRIMARY/state/unbound.meta")" = "$OWNER_PANE" ] || fail 'unresolvable home must preserve its route'
assert_contains "$(cat "$TMP_ROOT/sweep.out")" 'secondmate unreadable: skipped: endpoint probe unreadable' 'unreadable identity was not reported'
assert_contains "$(cat "$TMP_ROOT/sweep.out")" 'secondmate unbound: skipped: endpoint probe unreadable' 'unresolvable home was not reported'
rm "$PRIMARY/state/unreadable.meta" "$PRIMARY/state/unbound.meta"

# Start a separate batch of confidently absent endpoints; real fm-spawn must
# publish all three routes during this single sweep. Remove only fixture metas
# from the first case, whose replacement screens deliberately never ran agents.
rm "$PRIMARY/state/collision-sm.meta" "$PRIMARY/state/collision-primary.meta"
for id in absent-a absent-b absent-c; do record "$id" "missing-$id" nowhere; done
sweep
lock_failed=0
for id in absent-a absent-b absent-c; do
  pane=$(sed -n 's/^herdr_pane_id=//p' "$PRIMARY/state/$id.meta")
  [ "$pane" != "missing-$id" ] || lock_failed=1
done
if [ "$lock_failed" = 1 ]; then
  printf 'not ok - one bootstrap sweep failed to publish every absent secondmate\n'
  cat "$TMP_ROOT/sweep.out"
else
  pass 'one bootstrap sweep recovers every missing secondmate without lock contention'
fi
for id in absent-a absent-b absent-c; do
  if [ "$lock_failed" = 0 ]; then
    pane=$(sed -n 's/^herdr_pane_id=//p' "$PRIMARY/state/$id.meta")
    lab pane get "$pane" | jq -e --arg cwd "$TMP_ROOT/$id" '.result.pane.cwd == $cwd' >/dev/null \
      || fail 'replacement route did not bind to its own home'
  fi
  rm "$PRIMARY/state/$id.meta"
done

# A failed spawn must release the sweep mutex so later siblings still recover.
record failure-a missing-failure-a nowhere
record failure-z missing-failure-z nowhere
export FM_LAB_FAIL_LABEL=fm-failure-a
sweep
unset FM_LAB_FAIL_LABEL
assert_contains "$(cat "$TMP_ROOT/sweep.out")" 'secondmate failure-a: respawn failed' 'injected spawn failure was not reported'
[ "$(sed -n 's/^herdr_pane_id=//p' "$PRIMARY/state/failure-z.meta")" != missing-failure-z ] || fail 'failed spawn stranded the following recovery'
pass 'failed recovery releases the sweep lock for the next secondmate'
[ "$identity_failed" = 0 ] && [ "$lock_failed" = 0 ]
