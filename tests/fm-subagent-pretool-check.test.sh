#!/usr/bin/env bash
# Behavior tests for the primary-session delegation-shape guard: the tracked
# hook registration, shared settings boundary, and PreToolUse classifier.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-subagent-pretool-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-subagent-pretool-tests)
PRIMARY="$TMP_ROOT/primary"
STATE="$PRIMARY/state"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"
CODEX_PRIMARY="$TMP_ROOT/codex-primary"

mkdir -p "$PRIMARY/bin" "$STATE"
printf '# fixture\n' > "$PRIMARY/AGENTS.md"
git -C "$PRIMARY" init -q

BRIEF_ONLY_ROUTE='first classify the work under the AGENTS.md intake contract, then use bin/fm-brief.sh followed by bin/fm-spawn.sh for dispatched work'
SCOUT_ROUTE='first classify the work under the AGENTS.md intake contract: work already classified as a scout goes to bin/fm-scout.sh "<question>" [project], while authorized ship work and its bounded research go to bin/fm-brief.sh then bin/fm-spawn.sh'

# Every delegation, scheduling, worktree, and task-tracking tool Claude Code
# 2.1.217 offered a primary session in the observed baseline.
# This inventory is shape-classification coverage for the shipped guard and the
# recommended local Claude deny-list hardening list, but tracked settings must
# not ship that Claude-only permissions layer.
DELEGATION_TOOLS='Task Agent Workflow RemoteTrigger Monitor ScheduleWakeup SendMessage EnterWorktree ExitWorktree CronCreate CronDelete CronList TaskCreate TaskGet TaskList TaskUpdate TaskStop TaskOutput'

# Tools that must stay available: denying these would break ordinary work.
PRESERVED_TOOLS='Bash Edit Read Write Skill ToolSearch WebFetch WebSearch NotebookEdit ReportFindings DesignSync PushNotification'

# Session-local todo-list tools. They match a delegation stem but create no
# runnable work, so the guard's plan-only exclusion must allow them.
PLAN_ONLY_TOOLS='TaskCreate TaskUpdate'

# Names the plan-only exclusion must NOT release. Five of them contain a
# plan-only name as a substring and would be let through by a substring rather
# than exact-name match; bare Task is what a shortened entry of "task" would
# release. Together they make the exact-name contract testable instead of
# assumed.
PLAN_ONLY_NEAR_MISSES='TaskCreateAgent TaskCreateWorktree TaskUpdateAgent RemoteTaskCreate Task TaskCreator'

CODEX_OBSERVE_ONLY_TOOLS='collaborationlist_agents collaborationwait_agent collaborationinterrupt_agent list_agents wait_agent interrupt_agent multi_agent_v1wait_agent multi_agent_v1close_agent'

CODEX_OBSERVE_NEAR_MISSES='collaborationlist_agents_spawn collaborationwait_agent_task collaborationinterrupt_agent_worktree'

run_tool() {
  local tool=$1 rc=0
  shift
  : > "$OUT"
  : > "$ERR"
  env FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" "$@" \
    "$CHECK" --claude --tool "$tool" > "$OUT" 2> "$ERR" || rc=$?
  return "$rc"
}

expect_allow() {
  local label=$1 tool=$2 rc=0
  shift 2
  run_tool "$tool" "$@" || rc=$?
  [ "$rc" -eq 0 ] || fail "$label ($tool) must allow, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "$label ($tool) allow wrote stdout: $(cat "$OUT")"
  [ ! -s "$ERR" ] || fail "$label ($tool) allow wrote stderr: $(cat "$ERR")"
}

expect_deny() {
  local label=$1 tool=$2 rc=0
  run_tool "$tool" || rc=$?
  [ "$rc" -eq 2 ] || fail "$label ($tool) must deny with exit 2, got $rc"
  [ ! -s "$OUT" ] || fail "$label ($tool) deny wrote stdout: $(cat "$OUT")"
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny"' "$ERR" >/dev/null 2>&1 \
    || fail "$label ($tool) deny omitted Claude's permission decision: $(cat "$ERR")"
  jq -e --arg tool "$tool" '.systemMessage | startswith("[subagent-dispatch]") and contains("blocked tool: " + $tool)' "$ERR" >/dev/null 2>&1 \
    || fail "$label ($tool) deny message lost its code or tool name: $(jq -r '.systemMessage' "$ERR")"
}

run_codex_pretool_hooks() {
  local dir=$1 tool=$2 submitted_command=${3:-} hook_bash_env=${4:-} payload command hook_rc=0 overall_rc=0 matched=0
  payload=$(jq -nc --arg tool "$tool" --arg command "$submitted_command" \
    '{hook_event_name:"PreToolUse",tool_name:$tool,tool_input:{command:$command}}') \
    || fail "could not build Codex PreToolUse fixture payload"
  : > "$OUT"
  : > "$ERR"
  while IFS= read -r command; do
    [ -n "$command" ] || continue
    matched=$((matched + 1))
    hook_rc=0
    if [ -n "$hook_bash_env" ]; then
      printf '%s' "$payload" | (cd "$dir" && env BASH_ENV="$hook_bash_env" bash -c "$command") >> "$OUT" 2>> "$ERR" || hook_rc=$?
    else
      printf '%s' "$payload" | (cd "$dir" && bash -c "$command") >> "$OUT" 2>> "$ERR" || hook_rc=$?
    fi
    case "$hook_rc" in
      0) ;;
      2) overall_rc=2 ;;
      *) fail "Codex PreToolUse hook for $tool failed with unexpected exit $hook_rc: $(cat "$ERR")" ;;
    esac
  done < <(jq -r --arg tool "$tool" '
    .hooks.PreToolUse[]
    | select((.matcher // ".*") as $matcher | ($tool | test($matcher)))
    | .hooks[].command
  ' "$dir/.codex/hooks.json")
  [ "$matched" -gt 0 ] || fail "Codex PreToolUse matcher reached no hook for $tool"
  return "$overall_rc"
}

setup_codex_hook_fixture() {
  mkdir -p "$CODEX_PRIMARY/bin" "$CODEX_PRIMARY/state" "$CODEX_PRIMARY/.codex"
  cp "$ROOT/AGENTS.md" "$CODEX_PRIMARY/AGENTS.md"
  cp "$ROOT/.codex/hooks.json" "$CODEX_PRIMARY/.codex/hooks.json"
  cp "$ROOT/bin/fm-subagent-pretool-check.sh" \
    "$ROOT/bin/fm-primary-scope-lib.sh" \
    "$ROOT/bin/fm-arm-pretool-check.sh" \
    "$ROOT/bin/fm-cd-pretool-check.sh" \
    "$ROOT/bin/fm-arm-command-policy.mjs" \
    "$ROOT/bin/fm-cd-command-policy.mjs" \
    "$CODEX_PRIMARY/bin/"
  git -C "$CODEX_PRIMARY" init -q
  git -C "$CODEX_PRIMARY" config user.name fixture
  git -C "$CODEX_PRIMARY" config user.email fixture@example.test
  git -C "$CODEX_PRIMARY" add AGENTS.md .codex bin
  git -C "$CODEX_PRIMARY" commit -qm fixture
}

# ---------------------------------------------------------------------------
# Delegation-shape PreToolUse guard.
# ---------------------------------------------------------------------------

test_guard_denies_every_currently_known_delegation_tool() {
  local tool
  for tool in $DELEGATION_TOOLS; do
    case "$tool" in
      TaskOutput|TaskStop|TaskGet|TaskList|CronList) continue ;;
      TaskCreate|TaskUpdate) continue ;;
    esac
    expect_deny "known delegation tool" "$tool"
  done
  pass "the guard independently denies every work-creating delegation tool by shape"
}

test_guard_denies_hypothetical_future_tools() {
  # A fixed deny list is fail-open against tools that do not exist yet.
  # None of these names is on any list.
  local tool
  for tool in SubagentCreate SpawnWorker DelegateTask AgentPool WorkflowRun \
              ScheduleJob CronSchedule CreateWorktree DispatchAgent TaskHandoff \
              RemoteExec BackgroundAgent; do
    expect_deny "future delegation tool" "$tool"
  done
  pass "the guard denies delegation-shaped tools that no deny list knows about yet"
}

test_guard_allows_ordinary_and_observe_only_tools() {
  local tool
  for tool in $PRESERVED_TOOLS; do
    expect_allow "ordinary tool" "$tool"
  done
  # Observing or stopping work that already exists is not creating unaccounted
  # work, and blocking it would strand a runaway task with no way to end it.
  for tool in TaskOutput TaskStop TaskGet TaskList CronList BashOutput KillShell; do
    expect_allow "observe-or-stop tool" "$tool"
  done
  pass "the guard leaves ordinary tools and observe-or-stop operations alone"
}

test_guard_allows_session_local_todo_tools() {
  # These write, so they are not observe-or-stop, but what they write is the
  # harness's session-local todo list: no executor, no agent, no worktree, no
  # schedule, nothing that outlives the session. Denying them stops the primary
  # tracking its own plan and grants no delegation power in exchange.
  local tool
  for tool in $PLAN_ONLY_TOOLS; do
    expect_allow "session-local todo tool" "$tool"
  done
  pass "the guard leaves the session-local todo list alone"
}

test_plan_only_exclusion_is_exact_name() {
  # The plan-only exclusion must never widen by substring or by a shorter stem.
  # Every name here would be released by such a widening and must stay denied.
  local tool
  for tool in $PLAN_ONLY_NEAR_MISSES; do
    expect_deny "plan-only near miss" "$tool"
  done
  pass "the plan-only exclusion releases exactly two names and nothing that merely contains them"
}

test_guard_never_classifies_mcp_tools() {
  # An MCP server names its own tools; a task or agent noun there is common and
  # has nothing to do with fleet dispatch.
  local tool
  for tool in mcp__linear__list_issues mcp__tracker__create_task \
              mcp__acme__spawn_agent mcp__slack__slack_send_message; do
    expect_allow "MCP tool" "$tool"
  done
  pass "MCP tool names are never classified as harness delegation"
}

test_deny_message_defers_to_intake_classification() {
  local actual
  printf '#!/usr/bin/env bash\n' > "$PRIMARY/bin/fm-scout.sh"
  run_tool Agent && fail "scout-present case must still deny"
  actual=$(jq -r '.systemMessage' "$ERR")
  case "$actual" in
    *"$SCOUT_ROUTE"*) ;;
    *) fail "deny must reserve bin/fm-scout.sh for classified scout work: $actual" ;;
  esac
  case "$actual" in
    *'investigation or diagnosis goes to bin/fm-scout.sh'*) fail "deny must not classify all investigation or diagnosis as scout work: $actual" ;;
  esac
  rm -f "$PRIMARY/bin/fm-scout.sh"
  run_tool Agent && fail "scout-absent case must still deny"
  actual=$(jq -r '.systemMessage' "$ERR")
  case "$actual" in
    *"$BRIEF_ONLY_ROUTE"*) ;;
    *) fail "deny must degrade to brief-then-spawn when fm-scout.sh is absent: $actual" ;;
  esac
  pass "deny defers to intake classification and degrades gracefully without fm-scout.sh"
}

test_escape_hatch_allows_deliberate_use() {
  local rc value
  expect_allow "escape hatch set" Agent FM_ALLOW_SUBAGENT=1
  expect_deny "escape hatch unset" Agent
  for value in '' 0 yes true 11; do
    rc=0
    run_tool Agent "FM_ALLOW_SUBAGENT=$value" || rc=$?
    [ "$rc" -eq 2 ] || fail "FM_ALLOW_SUBAGENT='$value' must not release the guard, got exit $rc"
  done
  pass "the single documented escape hatch releases the guard only on the exact opt-in value"
}

test_task_worktree_and_non_firstmate_repo_are_inert() {
  local child="$TMP_ROOT/child" plain="$TMP_ROOT/plain" rc=0
  git -C "$PRIMARY" config user.name fixture
  git -C "$PRIMARY" config user.email fixture@example.test
  git -C "$PRIMARY" add AGENTS.md
  git -C "$PRIMARY" commit -qm fixture
  git -C "$PRIMARY" worktree add -q -b fixture-child "$child"
  mkdir -p "$child/bin" "$child/state"
  printf '# fixture\n' > "$child/AGENTS.md"
  : > "$OUT"
  : > "$ERR"
  FM_ROOT_OVERRIDE="$child" FM_HOME="$child" FM_STATE_OVERRIDE="$child/state" \
    "$CHECK" --claude --tool Agent > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "a crewmate task worktree must be out of scope, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "task-worktree no-op wrote stdout: $(cat "$OUT")"
  [ ! -s "$ERR" ] || fail "task-worktree no-op wrote stderr: $(cat "$ERR")"

  mkdir -p "$plain/bin"
  git -C "$plain" init -q
  rc=0
  FM_ROOT_OVERRIDE="$plain" FM_HOME="$plain" FM_STATE_OVERRIDE="$plain/state" \
    "$CHECK" --claude --tool Agent > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "a non-firstmate repo must be out of scope, got exit $rc"
  pass "the guard is inert in a crewmate task worktree and in a non-firstmate repo"
}

test_secondmate_home_is_in_scope() {
  local second="$TMP_ROOT/second" rc=0
  git -C "$PRIMARY" worktree add -q -b fixture-second "$second"
  mkdir -p "$second/bin" "$second/state"
  printf '# fixture\n' > "$second/AGENTS.md"
  printf 'sm-fixture\n' > "$second/.fm-secondmate-home"
  FM_ROOT_OVERRIDE="$second" FM_HOME="$second" FM_STATE_OVERRIDE="$second/state" \
    "$CHECK" --claude --tool Agent > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "a marked secondmate home operates a fleet and must be guarded, got exit $rc"
  pass "a marked secondmate home is guarded even though it is a linked worktree"
}

test_stdin_transports_and_output_shapes() {
  local rc=0
  : > "$OUT"; : > "$ERR"
  printf '%s' '{"tool_name":"Agent","tool_input":{"prompt":"go"}}' \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "Claude-shaped stdin must deny, got exit $rc"
  [ ! -s "$OUT" ] || fail "Claude deny wrote stdout, which makes Claude ignore the deny: $(cat "$OUT")"

  rc=0
  : > "$OUT"; : > "$ERR"
  printf '%s' '{"toolName":"Agent"}' \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "Grok-shaped stdin must deny, got exit $rc"
  jq -e '.decision == "deny" and (.reason | startswith("[subagent-dispatch]"))' "$OUT" >/dev/null 2>&1 \
    || fail "default deny mode must write a Grok decision object on stdout: $(cat "$OUT")"

  rc=0
  : > "$OUT"; : > "$ERR"
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "Bash through stdin must allow, got exit $rc"
  [ ! -s "$OUT" ] && [ ! -s "$ERR" ] || fail "stdin allow wrote output"
  pass "both stdin transports classify correctly and Claude's deny keeps stdout empty"
}

test_malformed_transport_fails_open() {
  local rc payload
  for payload in '{not-json' '' '{}' '{"tool_name":null}'; do
    rc=0
    : > "$OUT"; : > "$ERR"
    printf '%s' "$payload" \
      | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
        "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
    [ "$rc" -eq 0 ] || fail "malformed transport must fail open, payload '$payload' gave exit $rc"
    [ ! -s "$OUT" ] || fail "fail-open path wrote stdout for payload '$payload'"
  done
  pass "malformed, empty, and tool-name-less payloads fail open rather than blocking every tool call"
}

test_node_stdin_transport_does_not_require_jq() {
  local fakebin="$TMP_ROOT/no-jq-bin" tool tool_bin rc=0
  mkdir -p "$fakebin"
  for tool in bash cat node tr dirname git sed; do
    tool_bin=$(command -v "$tool") || fail "test needs $tool for the jq-free stdin path"
    ln -sf "$tool_bin" "$fakebin/$tool"
  done
  : > "$OUT"; : > "$ERR"
  printf '%s' '{"tool_name":"Agent"}' \
    | env PATH="$fakebin" FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "Node stdin transport must deny without jq, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "jq-free Node stdin deny wrote stdout: $(cat "$OUT")"
  jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$ERR" >/dev/null 2>&1 \
    || fail "jq-free Node stdin deny lost its permission decision: $(cat "$ERR")"
  pass "the Node stdin transport denies delegation without jq"
}

test_codex_real_hook_surface_routes_delegation_and_preserves_scope() {
  local tool child="$TMP_ROOT/codex-child" no_jq_env="$TMP_ROOT/no-jq.bash" no_jq_loaded="$TMP_ROOT/no-jq.loaded" no_jq_called="$TMP_ROOT/no-jq.called" rc=0
  setup_codex_hook_fixture

  for tool in collaborationspawn_agent spawn_agent multi_agent_v1spawn_agent; do
    rc=0
    run_codex_pretool_hooks "$CODEX_PRIMARY" "$tool" || rc=$?
    [ "$rc" -eq 2 ] || fail "Codex primary hook surface must deny $tool, got exit $rc"
    jq -e --arg tool "$tool" \
      '.hookSpecificOutput.permissionDecision == "deny" and (.systemMessage | contains("blocked tool: " + $tool))' \
      "$ERR" >/dev/null 2>&1 \
      || fail "Codex primary deny for $tool lost the route-to-FirstMate decision: $(cat "$ERR")"
  done

  cat > "$no_jq_env" <<'SH'
printf 'loaded\n' >> "${FM_TEST_NO_JQ_LOADED:?}"
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = jq ]; then
    return 1
  fi
  builtin command "$@"
}
jq() {
  printf 'called\n' >> "${FM_TEST_NO_JQ_CALLED:?}"
  return 127
}
SH
  export FM_TEST_NO_JQ_LOADED="$no_jq_loaded" FM_TEST_NO_JQ_CALLED="$no_jq_called"
  rc=0
  run_codex_pretool_hooks "$CODEX_PRIMARY" collaborationspawn_agent '' "$no_jq_env" || rc=$?
  unset FM_TEST_NO_JQ_LOADED FM_TEST_NO_JQ_CALLED
  [ -s "$no_jq_loaded" ] || fail "jq-free Codex hook fixture did not load its dependency mask"
  [ ! -e "$no_jq_called" ] || fail "jq-free Codex delegation hook still invoked jq"
  [ "$rc" -eq 2 ] || fail "Codex delegation hook must deny without jq, got exit $rc: $(cat "$ERR")"
  jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$ERR" >/dev/null 2>&1 \
    || fail "jq-free Codex hook deny lost its permission decision: $(cat "$ERR")"

  for tool in $CODEX_OBSERVE_ONLY_TOOLS; do
    rc=0
    run_codex_pretool_hooks "$CODEX_PRIMARY" "$tool" || rc=$?
    [ "$rc" -eq 0 ] || fail "Codex observe-or-stop control $tool must remain allowed, got exit $rc: $(cat "$ERR")"
    [ ! -s "$OUT" ] && [ ! -s "$ERR" ] || fail "Codex observe-or-stop control $tool wrote output"
  done

  for tool in $CODEX_OBSERVE_NEAR_MISSES; do
    rc=0
    run_codex_pretool_hooks "$CODEX_PRIMARY" "$tool" || rc=$?
    [ "$rc" -eq 2 ] || fail "Codex observe-or-stop near miss $tool must remain denied, got exit $rc"
  done

  git -C "$CODEX_PRIMARY" worktree add -q -b fixture-codex-child "$child"
  mkdir -p "$child/state"
  rc=0
  run_codex_pretool_hooks "$child" collaborationspawn_agent || rc=$?
  [ "$rc" -eq 0 ] || fail "Codex delegation must remain allowed in a linked worker worktree, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] && [ ! -s "$ERR" ] || fail "linked worker Codex hook allow wrote output"

  rc=0
  run_codex_pretool_hooks "$CODEX_PRIMARY" Bash 'printf safe' || rc=$?
  [ "$rc" -eq 0 ] || fail "safe Bash must remain allowed through all matching Codex hooks, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] && [ ! -s "$ERR" ] || fail "safe Bash through Codex hooks wrote output"
  pass "the real Codex hook surface denies delegation while preserving exact observe-or-stop controls"
}

test_guard_denies_every_currently_known_delegation_tool
test_guard_denies_hypothetical_future_tools
test_guard_allows_ordinary_and_observe_only_tools
test_guard_allows_session_local_todo_tools
test_plan_only_exclusion_is_exact_name
test_guard_never_classifies_mcp_tools
test_deny_message_defers_to_intake_classification
test_escape_hatch_allows_deliberate_use
test_task_worktree_and_non_firstmate_repo_are_inert
test_secondmate_home_is_in_scope
test_stdin_transports_and_output_shapes
test_malformed_transport_fails_open
test_node_stdin_transport_does_not_require_jq
test_codex_real_hook_surface_routes_delegation_and_preserves_scope
