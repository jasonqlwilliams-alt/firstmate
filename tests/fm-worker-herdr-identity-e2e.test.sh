#!/usr/bin/env bash
# Real named Herdr lab, inert agents. Recreate the session to recycle the exact
# pane ids, then exercise recorded liveness, local actions and host-side remote
# actions against the resulting foreign terminals.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
fm_live_gate default-on FM_WORKER_HERDR_IDENTITY_E2E herdr jq

TMP_ROOT=$(fm_test_tmproot fm-worker-herdr-identity)
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name worker-endpoint-recycled-herdr-pane-20261114)
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
lab status --json | jq -r '"Herdr worker identity lab version: \(.client.version)"'

export FM_HOME="$TMP_ROOT/local" FM_LAB_CALLS="$TMP_ROOT/lab-calls"
REMOTE_HOME="$TMP_ROOT/remote"
mkdir -p "$FM_HOME/state" "$REMOTE_HOME"/{bin,state/parent-route} "$TMP_ROOT"/{fakebin,project,worktree,other,personal}
touch "$REMOTE_HOME/AGENTS.md" "$FM_HOME/state/.last-watcher-beat"
printf '%s\n' remote-owner > "$REMOTE_HOME/.fm-secondmate-home"
printf '%s\n' 'unlanded fixture' > "$TMP_ROOT/worktree/sentinel"
: > "$FM_LAB_CALLS"
# Even when testing host-side fm-remote routing, only the guarded named session
# receives traffic. Every terminal action is logged before forwarding.
cat > "$TMP_ROOT/fakebin/herdr" <<'WRAPPER'
#!/usr/bin/env bash
set -eu
args=("$@")
last=$(("${#args[@]}" - 1))
flag=$((last - 1))
[ "$flag" -ge 1 ] && [ "${args[$flag]}" = --session ] || exit 91
case "${args[$last]}" in
  "$HERDR_LAB_SESSION") ;;
  fm-remote) [ "${FM_LAB_REMOTE_ALIAS:-}" = 1 ] || exit 91 ;;
  *) exit 91 ;;
esac
unset 'args[last]' 'args[flag]'
printf '%s\n' "${args[*]}" >> "$FM_LAB_CALLS"
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "${args[@]}"
WRAPPER
chmod +x "$TMP_ROOT/fakebin/herdr"
export PATH="$TMP_ROOT/fakebin:$HERDR_ORIGINAL_PATH"
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr

make_worker() {  # <label> <creation-cwd> -> <workspace> <tab> <pane> <terminal>
  local label=$1 cwd=$2 ws created
  created=$(lab workspace create --cwd "$cwd" --label "$label" --no-focus) || return 1
  ws=$(jq -er '.result.workspace.workspace_id' <<< "$created") || return 1
  created=$(fm_backend_herdr_create_task "$HERDR_LAB_SESSION:$ws" "fm-$label" "$cwd" '' worker) || return 1
  printf '%s %s\n' "$ws" "$created"
}

bind_worker() {
  fm_write_meta "$FM_HOME/state/$1.meta" "window=$HERDR_LAB_SESSION:$4" "endpoint_task_id=$1" \
    "kind=$6" 'backend=herdr' "herdr_session=$HERDR_LAB_SESSION" "herdr_workspace_id=$2" \
    "herdr_tab_id=$3" "herdr_pane_id=$4" "herdr_terminal_id=$5" \
    "worktree=$TMP_ROOT/worktree" "project=$TMP_ROOT/project" 'harness=codex'
}

start_stub() {  # <pane> <terminal> <foreground-cwd> <label>
  local pane=$1 terminal=$2 cwd=$3 label=$4 command i
  lab pane get "$pane" | jq -e --arg id "$pane" --arg terminal "$terminal" \
    '.result.pane | .pane_id == $id and .terminal_id == $terminal' >/dev/null
  printf -v command 'cd -- %q && printf "stub %s\\n" && sleep 600' "$cwd" "$label"
  lab pane run "$pane" "$command" >/dev/null
  for ((i=0; i<50; i++)); do
    if lab pane process-info --pane "$pane" | jq -e --arg cwd "$cwd" \
      '.result.process_info.foreground_processes | any(.name == "sleep" and .cwd == $cwd)' >/dev/null; then
      lab pane report-agent "$pane" --source codex --agent codex --state idle >/dev/null
      return 0
    fi
    sleep 0.1
  done
  fail "inert stub in $pane did not enter $cwd"
}

for role in worker secondmate personal; do
  IFS=' ' read -r ws tab pane terminal <<< "$(make_worker "$role" "$TMP_ROOT/project")"
  [ -n "$terminal" ] || fail "missing terminal for original $role"
  kind=ship
  [ "$role" != personal ] || kind=scout
  bind_worker "$role" "$ws" "$tab" "$pane" "$terminal" "$kind"
done

# Reprovision the same name from scratch. Numeric pane ids really are reused
# here, with distinct terminals, while every original task record stays put.
env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"
env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
for role in worker secondmate personal; do
  case "$role" in
    worker) cwd="$TMP_ROOT/project" ;;  # Same creation cwd and labels too.
    secondmate) cwd="$REMOTE_HOME" ;;
    personal) cwd="$TMP_ROOT/personal" ;;
  esac
  IFS=' ' read -r ws tab pane terminal <<< "$(make_worker "$role" "$cwd")"
  [ -n "$terminal" ] || fail "missing terminal for foreign $role"
  meta="$FM_HOME/state/$role.meta"
  [ "$(fm_meta_get "$meta" herdr_pane_id)" = "$pane" ] || fail "lab did not recycle the $role pane id"
  [ "$(fm_meta_get "$meta" herdr_terminal_id)" != "$terminal" ] || fail "lab did not change terminal identity"
  start_stub "$pane" "$terminal" "$cwd" "$role"
  target="$HERDR_LAB_SESSION:$pane"
  [ "$(FM_STATE_OVERRIDE="$TMP_ROOT/no-records" fm_backend_agent_state herdr "$target")" = alive ] \
    || fail "foreign $role must be a live agent in the unbound view"

  : > "$FM_LAB_CALLS"
  cp "$meta" "$TMP_ROOT/record"
  [ "$(fm_backend_agent_state herdr "$target")" = missing ] || fail "$role was accepted as the recorded worker"
  for action in peek key text; do
    case "$action" in
      peek) args=(fm-peek.sh "$role" 20) ;;
      key) args=(fm-send.sh "$role" --key Escape) ;;
      text) args=(fm-send.sh "$role" /identity-test) ;;
    esac
    if out=$(FM_ROOT_OVERRIDE="$FM_HOME" "$ROOT/bin/${args[0]}" "${args[@]:1}" 2>&1); then
      fail "$role unexpectedly allowed $action"
    fi
    assert_contains "$out" 'endpoint identity mismatch' "$role $action should explain its refusal"
  done
  out=$(FM_ROOT_OVERRIDE="$FM_HOME" "$ROOT/bin/fm-send.sh" "$role" 'durable fixture steer' 2>&1)
  assert_contains "$out" 'endpoint identity mismatch' "$role inbox notification should explain its refusal"
  fm_backend_kill herdr "$target" >/dev/null 2>&1 || true
  if rg -q '^pane (read|send-keys|send-text|run|close) ' "$FM_LAB_CALLS"; then
    fail "recorded access reached foreign $role: $(cat "$FM_LAB_CALLS")"
  fi
  [ "$(FM_STATE_OVERRIDE="$TMP_ROOT/no-records" fm_backend_agent_state herdr "$target")" = alive ] \
    || fail "foreign $role was harmed by recovery"
  cmp -s "$meta" "$TMP_ROOT/record" || fail "record changed for $role"
  [ "$(cat "$TMP_ROOT/worktree/sentinel")" = 'unlanded fixture' ] || fail "the worktree changed"
  if [ "$role" = worker ]; then
    if out=$(fm_backend_herdr_create_task "$HERDR_LAB_SESSION:$ws" fm-worker "$TMP_ROOT/worktree" '' worker 2>&1); then
      fail "a fresh spawn accepted a same-label foreign terminal"
    fi
    assert_contains "$out" 'endpoint identity mismatch' 'fresh spawn should explain the conflicting terminal'
    IFS=' ' read -r _ replacement new_terminal <<< "$(
      fm_backend_herdr_create_task "$HERDR_LAB_SESSION:$ws" fm-worker "$TMP_ROOT/worktree" '' worker "$pane"
    )"
    [ -n "$new_terminal" ] && [ "$replacement" != "$pane" ] && [ "$new_terminal" != "$terminal" ] \
      || fail "recovery did not create a separate terminal"
    lab pane get "$pane" | jq -e --arg terminal "$terminal" '.result.pane.terminal_id == $terminal' >/dev/null \
      || fail "creating a same-label replacement removed its foreign predecessor"
  fi
done
pass 'recycled worker, secondmate and personal panes are missing to recorded workers and untouched by terminal actions'

IFS=' ' read -r ws tab pane terminal <<< "$(make_worker healthy "$TMP_ROOT/project")"
bind_worker healthy "$ws" "$tab" "$pane" "$terminal" scout
initial_cwd=$(lab pane get "$pane" | jq -er '.result.pane.cwd')
[ "$initial_cwd" = "$TMP_ROOT/project" ] || fail "healthy fixture did not start at the project"
start_stub "$pane" "$terminal" "$TMP_ROOT/worktree" healthy
info=$(lab pane get "$pane")
jq -e --arg moved "$TMP_ROOT/worktree" --arg terminal "$terminal" \
  '.result.pane | .terminal_id == $terminal and .foreground_cwd == $moved' <<< "$info" >/dev/null \
  || fail "healthy fixture did not diverge from its creation cwd: $info"
[ "$(fm_backend_agent_state herdr "$HERDR_LAB_SESSION:$pane")" = alive ] || fail "real worker lost its route after changing cwd"
out=$(FM_ROOT_OVERRIDE="$FM_HOME" "$ROOT/bin/fm-peek.sh" healthy 20 2>"$TMP_ROOT/peek.err") \
  || fail "matching worker capture failed after cwd change: $(cat "$TMP_ROOT/peek.err")"
assert_contains "$out" 'stub healthy' 'matching capture should include the inert stub output'
out=$(FM_ROOT_OVERRIDE="$FM_HOME" "$ROOT/bin/fm-send.sh" healthy --key Escape 2>&1) \
  || fail "matching worker key failed after cwd change: $out"
pass 'matching worker liveness and actions survive a changed foreground cwd'

# The host-side invocation keeps its real route policy, with only the fake
# client's trailing fm-remote argument mapped onto this test's guarded lab.
route="$REMOTE_HOME/state/parent-route/remote-owner.meta"
fm_write_meta "$route" "window=fm-remote:$pane" 'endpoint_task_id=remote-owner' \
  'kind=secondmate' 'backend=herdr' 'herdr_session=fm-remote' "herdr_workspace_id=$ws" \
  "herdr_tab_id=$tab" "herdr_pane_id=$pane" "worktree=$REMOTE_HOME" "project=$REMOTE_HOME" 'harness=codex'
remote() {
  FM_LAB_REMOTE_ALIAS=1 FM_HOME="$REMOTE_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-remote-secondmate-control.sh" "$@"
}
: > "$FM_LAB_CALLS"
[ "$(remote state remote-owner --bound-home)" = missing ] || fail 'foreign remote route passed liveness'
if out=$(remote capture remote-owner 20 2>&1); then fail 'remote capture succeeded on a foreign pane'; fi
assert_contains "$out" 'endpoint identity mismatch' 'remote capture refused for the wrong reason'
if out=$(remote key remote-owner Escape 2>&1); then fail 'remote key succeeded on a foreign pane'; fi
assert_contains "$out" 'endpoint identity mismatch' 'remote key refused for the wrong reason'
out=$(remote send remote-owner 'remote fixture steer' 2>&1)
assert_contains "$out" 'not confirmed in its recorded home' 'remote send rang a foreign endpoint'
if rg -q '^pane (read|send-keys|send-text|run|close) ' "$FM_LAB_CALLS"; then
  fail "host-side control reached the foreign pane: $(cat "$FM_LAB_CALLS")"
fi
pass 'host-side remote capture, key and send refuse the recycled endpoint by home identity'

IFS=' ' read -r remote_ws remote_tab remote_pane remote_terminal <<< "$(make_worker remote-owner "$REMOTE_HOME")"
start_stub "$remote_pane" "$remote_terminal" "$REMOTE_HOME" remote-owner
fm_write_meta "$route" "window=fm-remote:$remote_pane" 'endpoint_task_id=remote-owner' \
  'kind=secondmate' 'backend=herdr' 'herdr_session=fm-remote' "herdr_workspace_id=$remote_ws" \
  "herdr_tab_id=$remote_tab" "herdr_pane_id=$remote_pane" "worktree=$REMOTE_HOME" "project=$REMOTE_HOME" 'harness=codex'
out=$(remote capture remote-owner 20) || fail 'matching remote endpoint did not allow capture'
assert_contains "$out" 'stub remote-owner' 'matching remote capture returned another pane'
remote key remote-owner Escape || fail 'matching remote endpoint did not allow a key'

# A normal stop/start restores layout ids with a new terminal. That restored
# shell cannot borrow the worker's old binding, either.
env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null
env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
restored=$(lab pane get "$pane" | jq -er '.result.pane.terminal_id')
[ "$restored" != "$terminal" ] || fail 'restored layout did not change its terminal id'
[ "$(fm_backend_agent_state herdr "$HERDR_LAB_SESSION:$pane")" = missing ] \
  || fail 'restored layout borrowed the previous worker terminal binding'
pass 'a restored layout keeps pane ids but changes the worker terminal identity'
