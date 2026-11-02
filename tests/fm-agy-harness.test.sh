#!/usr/bin/env bash
# tests/fm-agy-harness.test.sh - the portable regression for the agy
# (Antigravity CLI) crewmate/scout adapter: detection, tmux liveness
# classification, the control-plane tables, busy-source trust, the spawn launch
# line and its per-task hook wiring, the workspace-trust pre-registration, the
# effort cap, pre-launch model validation, and the secondmate refusal.
#
# agy's identity, launch, and lifecycle checks are HARNESS-DEPENDENT: their
# verdicts come from what the vendor emits (a process name, an environment
# marker, a hook contract, an effort vocabulary). This suite pins the LOGIC with
# real processes and a fake agy binary so CI enforces it with no agy installed;
# the live evidence behind each pinned fact is recorded in
# docs/verification/agy.md and refreshed against a real agy. Neither replaces
# the other.
#
# The load-bearing contracts:
#   1. The anchored process name `agy` is ancestry evidence; magyar and agyd
#      never identify.
#   2. ANTIGRAVITY_AGENT=1 is a PRECEDENCE override that needs a real agy
#      ancestor: it beats an inherited CLAUDECODE and an inherited GEMINI_CLI
#      under agy, and is inert when it leaks from the Antigravity desktop app or
#      IDE into a terminal whose ancestry holds no agy.
#   3. Every agy launch clears foreign markers, auto-approves, and names BOTH
#      the worktree and the firstmate-owned hook root as --add-dir workspaces,
#      because a single --add-dir replaces the workspace set.
#   4. The turn-end and busy hooks land under state/, never in the worktree.
#   5. The worktree is pre-registered in agy's own trustedWorkspaces store, so a
#      worker never meets the trust dialog firstmate cannot answer.
#   6. Effort caps: low/medium/high pass through, xhigh and max become high, and
#      the requested value is still recorded verbatim in task metadata.
#   7. A model absent from `agy models` refuses the spawn; an unreadable listing
#      establishes nothing and passes through.
#   8. agy is crewmate/scout only and is refused for a secondmate.
#   9. agy runs Gemini models only: a non-gemini model, no model, or a raw agy
#      launch command refuses every ship, scout, and relaunch before any launch
#      side effect, and the secondmate refusal keeps its own message.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry. A suite run
# from inside Cursor, Claude, Pi, Grok, or agy itself inherits those markers,
# which would outrank the fake ancestry the detection cases set up. Drop the
# ambient markers so the asserted verdict does not depend on which harness
# launched the suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  ATLASSIAN_AGENT_TYPE ROVODEV_CLI GEMINI_CLI ANTIGRAVITY_AGENT FM_OMP_HARNESS

HARNESS="$ROOT/bin/fm-harness.sh"
TRUST="$ROOT/bin/fm-agy-trust.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-harness)

# A process whose kernel-recorded identity is the bare name `agy`: a SYMLINK to
# the system shell, never a copy (a copied platform binary fails macOS code
# signing). macOS reports the symlink name through `ps -o comm=`, which is the
# exact signal under test. `magyar` and `agyd` are the decoys that prove the
# match is anchored rather than a substring. Every `-c` body below ends in a
# no-op so bash does not exec-optimize the single command away and replace the
# named process.
make_named_shells() {  # <dir> -> echoes <bindir>
  local dir=$1 name
  mkdir -p "$dir"
  for name in agy magyar agyd; do
    ln -sf /bin/bash "$dir/$name"
  done
  printf '%s' "$dir"
}

# --- 1. Detection ------------------------------------------------------------

test_detection_anchored_name_and_marker_precedence() {
  local bin out decoy
  bin=$(make_named_shells "$TMP_ROOT/named")
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$("$bin/agy" -c '"$1"; :' _ "$HARNESS")
  [ "$out" = agy ] || fail "a process named agy must detect as agy, got '$out'"
  for decoy in magyar agyd; do
    # shellcheck disable=SC2016 # the quoted body expands inside the named shell
    out=$("$bin/$decoy" -c '"$1"; :' _ "$HARNESS")
    [ "$out" != agy ] || fail "'$decoy' merely contains agy and must not detect as agy"
  done
  pass "fm-harness: agy detects by its anchored name, and magyar/agyd stay out"
}

test_detection_marker_needs_real_ancestry() {
  local bin out
  bin=$(make_named_shells "$TMP_ROOT/named-marker")
  # agy scrubs nothing it inherits, so a real agy worker launched from a claude
  # or gemini session carries that session's marker too. Its own marker must win
  # there.
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env CLAUDECODE=1 ANTIGRAVITY_AGENT=1 "$bin/agy" -c '"$1"; :' _ "$HARNESS")
  [ "$out" = agy ] || fail "ANTIGRAVITY_AGENT under an agy ancestor must outrank an inherited CLAUDECODE, got '$out'"
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env GEMINI_CLI=1 ANTIGRAVITY_AGENT=1 "$bin/agy" -c '"$1"; :' _ "$HARNESS")
  [ "$out" = agy ] || fail "ANTIGRAVITY_AGENT under an agy ancestor must outrank an inherited GEMINI_CLI, got '$out'"
  # The marker name belongs to the Antigravity desktop app and IDE as well as
  # the CLI. A terminal opened inside that app can export it with no agy CLI
  # anywhere, and that must NOT relabel whatever harness actually runs there.
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env CLAUDECODE=1 ANTIGRAVITY_AGENT=1 bash -c '"$1"; :' _ "$HARNESS")
  [ "$out" = claude ] || fail "a leaked ANTIGRAVITY_AGENT without an agy ancestor must not relabel a claude worker, got '$out'"
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env GEMINI_CLI=1 ANTIGRAVITY_AGENT=1 bash -c '"$1"; :' _ "$HARNESS")
  [ "$out" = gemini ] || fail "a leaked ANTIGRAVITY_AGENT without an agy ancestor must not relabel a gemini worker, got '$out'"
  pass "fm-harness: the agy marker is a precedence override that needs real agy ancestry"
}

test_tmux_liveness_classification() {
  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source tmux || fail "fm_backend_source tmux failed"
  [ "$(fm_agent_process_classify_name agy)" = agent ] || fail "tmux liveness must classify agy as an agent"
  [ "$(fm_agent_process_classify_name /home/u/.local/bin/agy)" = agent ] || fail "tmux liveness must classify an agy path as an agent"
  [ "$(fm_agent_process_classify_name magyar)" != agent ] || fail "tmux liveness must not classify magyar as an agent"
  [ "$(fm_agent_process_classify_name agyd)" != agent ] || fail "tmux liveness must not classify agyd as an agent"
  pass "tmux liveness: agy is anchored, decoys stay out"
}

# --- 2. Control plane and busy trust -----------------------------------------

test_control_tables() {
  fm_control_harness_supported agy || fail "agy must be a supported control-plane harness"
  [ "$(fm_control_harness_family agy)" = agy ] || fail "agy must resolve to its own adapter family"
  ! fm_control_harness_family agyd >/dev/null 2>&1 || fail "agyd must not be guessed into the agy family"
  fm_control_harness_supports_kind agy ship || fail "agy must be verified for a ship task"
  fm_control_harness_supports_kind agy scout || fail "agy must be verified for a scout task"
  ! fm_control_harness_supports_kind agy secondmate || fail "agy must be refused for a secondmate"
  [ "$(fm_control_interrupt_key agy)" = Escape ] || fail "agy interrupts on Escape"
  [ "$(fm_control_interrupt_repeat agy)" = 1 ] || fail "agy interrupts on a single press"
  [ -z "$(fm_control_interrupt_clear_key agy)" ] || fail "agy leaves its composer empty and needs no clear key"
  [ "$(fm_control_interrupt_ack_source agy)" = none ] || fail "agy has no recorded cancellation acknowledgement"
  [ "$(fm_control_exit_command agy)" = /exit ] || fail "agy exits with /exit"
  pass "fm-control-lib: the agy lifecycle table matches the verified mechanics"
}

test_wiring_paths_and_busy_source_trust() {
  local paths
  paths=$(fm_control_harness_wiring_paths agy /wt /state task1)
  [ "$paths" = "/state/task1.agy-hooks/.agents/hooks.json" ] \
    || fail "agy wiring must retire exactly its state-resident hooks file, got '$paths'"
  case "$paths" in
    /wt/*) fail "agy must leave no wiring inside the worktree" ;;
  esac
  fm_busy_source_trusted agy agy-hook || fail "agy must trust its own hook source"
  ! fm_busy_source_trusted agy claude-hook || fail "agy must not trust another adapter's writer"
  ! fm_busy_source_trusted claude agy-hook || fail "the agy writer must not classify a claude task"
  fm_busy_source_trusted agy fm-spawn || fail "agy must accept the firstmate-owned spawn seed"
  pass "fm-busy-lib and fm-control-lib: agy's hook source is trusted only for agy, and its wiring stays out of the worktree"
}

# --- 3. Launch ---------------------------------------------------------------

# A fake agy that answers `models` with a catalog in the vendor's
# tab-separated "<id><TAB><label>" shape, listing Anthropic and OpenAI ids
# beside the Gemini ones exactly as the real account catalog does and exits 0 for everything else (the
# launch itself is only recorded by the fake tmux).
make_fake_agy() {  # <fakebin>
  cat > "$1/agy" <<'SH'
#!/usr/bin/env bash
case "$1" in
  models)
    printf 'gemini-4-argon-high\tGemini 4 Argon (High)\n'
    printf 'gemini-3.8-flash-high\tGemini 3.8 Flash (High)\n'
    printf 'gemini-4+preview\tGemini 4 Preview\n'
    printf 'claude-opus-5-5\tClaude Opus 5.5\n'
    printf 'gpt-6-sol\tGPT 6 Sol\n'
    ;;
esac
exit 0
SH
  chmod +x "$1/agy"
}

# A fake agy whose `models` call fails, standing in for an unauthenticated or
# offline account. An unreadable listing establishes nothing and must not
# refuse a launch.
make_fake_agy_no_listing() {  # <fakebin>
  cat > "$1/agy" <<'SH'
#!/usr/bin/env bash
case "$1" in
  models) echo "Error: not signed in" >&2; exit 1 ;;
esac
exit 0
SH
  chmod +x "$1/agy"
}

make_spawn_case() {  # <name> <id> [no-listing]
  local name=$1 id=$2 listing=${3:-} case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  if [ "$listing" = no-listing ]; then
    make_fake_agy_no_listing "$fakebin"
  else
    make_fake_agy "$fakebin"
  fi
  fm_test_spawn_home "$home" agy
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  : > "$case_dir/launch.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$case_dir/launch.log"
}

read_case_record() {
  # shellcheck disable=SC2034 # CASE_DIR is part of the shared record shape
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_scout_spawn() {  # <home> <wt> <fakebin> <launch-log> <spawn-args...>
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  FM_FAKE_LAUNCH_LOG="$launchlog" fm_test_run_spawn "$home" "$wt" "$fakebin" "$@" --scout
}

run_ship_spawn() {  # <home> <wt> <fakebin> <launch-log> <spawn-args...>
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  FM_FAKE_LAUNCH_LOG="$launchlog" fm_test_run_spawn "$home" "$wt" "$fakebin" "$@" --mode direct-PR --yolo off
}

test_spawn_launch_line_hooks_and_trust() {
  local rec id=agy-launch-q1 out status launch state hooks trust
  rec=$(make_spawn_case launch "$id")
  read_case_record "$rec"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness agy --model gemini-4-argon-high --effort medium)
  status=$?
  expect_code 0 "$status" "agy scout spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=agy" "spawn did not report the agy harness"
  state="$HOME_DIR/state"
  assert_grep "harness=agy" "$state/$id.meta" "meta missing harness=agy"
  assert_grep "model=gemini-4-argon-high" "$state/$id.meta" "meta missing the pinned model"
  assert_grep "effort=medium" "$state/$id.meta" "meta missing the pinned effort"

  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS '$FAKEBIN_DIR/agy'" \
    "agy launch did not clear every foreign marker at its launch boundary"
  assert_contains "$launch" "--dangerously-skip-permissions --add-dir '$WT_DIR' --add-dir '$state/$id.agy-hooks'" \
    "agy launch did not auto-approve and name BOTH the worktree and the hook root as workspaces"
  assert_contains "$launch" "--model 'gemini-4-argon-high' --effort 'medium' -i " \
    "agy launch did not pass the model, the effort, and the interactive prompt flag"
  assert_contains "$launch" "encode launch-brief < '$HOME_DIR/data/$id/launch-brief.md'" \
    "agy launch lost the canonical typed launch-brief envelope"

  # The hooks land under state/, never in the worktree, whose own .agents/
  # belongs to the project.
  hooks="$state/$id.agy-hooks/.agents/hooks.json"
  assert_present "$hooks" "agy spawn did not write its per-task hooks file"
  assert_absent "$WT_DIR/.agents/hooks.json" "agy spawn must not write hooks into the worktree"
  assert_grep '"PreInvocation"' "$hooks" "agy hooks missing the busy-opening PreInvocation handler"
  assert_grep '"Stop"' "$hooks" "agy hooks missing the turn-closing Stop handler"
  assert_grep 'fm-busy-event.sh' "$hooks" "agy hooks do not write the semantic busy record"
  assert_grep "$state/$id.turn-ended" "$hooks" "agy Stop hook does not touch the turn-end notification"
  [ "$(fm_busy_classify tmux fake:w agy "$id" "$state")" = "busy fm-spawn" ] \
    || fail "agy spawn must seed the busy-state contract"

  # The worktree is pre-registered in agy's own trust store under the sandbox
  # HOME, so the worker never meets the dialog.
  trust="$HOME_DIR/user-home/.gemini/antigravity-cli/settings.json"
  assert_present "$trust" "agy spawn did not create agy's own settings store"
  assert_grep "$WT_DIR" "$trust" "agy spawn did not pre-register the worktree as a trusted workspace"
  pass "fm-spawn: the agy launch line clears markers, carries both workspaces, wires state-resident hooks, and pre-registers trust"
}

# The agy launch template carries no task-kind branch, unlike codex's notify=
# wiring or omp's -e. Assert that directly rather than assuming it: a crewmate
# and a scout must produce the SAME launch shape and the same state-resident
# hook wiring, so verifying one kind live verifies both.
test_ship_and_scout_launch_shapes_match() {
  local rec ship_launch scout_launch ship_state scout_state
  rec=$(make_spawn_case kind-ship agy-kind-ship-q7)
  read_case_record "$rec"
  ship_state="$HOME_DIR/state"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" agy-kind-ship-q7 "$PROJ_DIR" --harness agy --model gemini-3.8-flash-high)
  expect_code 0 "$?" "an agy ship spawn should succeed: $out"
  assert_present "$ship_state/agy-kind-ship-q7.agy-hooks/.agents/hooks.json" "an agy crewmate must get the same hook wiring as a scout"
  ship_launch=$(cat "$LAUNCH_LOG")

  rec=$(make_spawn_case kind-scout agy-kind-scout-q8)
  read_case_record "$rec"
  scout_state="$HOME_DIR/state"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" agy-kind-scout-q8 "$PROJ_DIR" --harness agy --model gemini-3.8-flash-high)
  expect_code 0 "$?" "an agy scout spawn should succeed: $out"
  assert_present "$scout_state/agy-kind-scout-q8.agy-hooks/.agents/hooks.json" "an agy scout must get the same hook wiring as a crewmate"
  scout_launch=$(cat "$LAUNCH_LOG")

  # Compare the shapes with the per-task paths and ids normalized away, so the
  # assertion is about the launch SHAPE rather than the two tasks' own names.
  ship_launch=${ship_launch//agy-kind-ship-q7/TASK}
  scout_launch=${scout_launch//agy-kind-scout-q8/TASK}
  ship_launch=${ship_launch//kind-ship/CASE}
  scout_launch=${scout_launch//kind-scout/CASE}
  [ "$ship_launch" = "$scout_launch" ] \
    || fail "the agy crewmate and scout launch shapes must be identical:
ship:  $ship_launch
scout: $scout_launch"
  pass "fm-spawn: the agy crewmate and scout launch shapes are identical, so one live launch verifies both"
}

test_spawn_effort_is_capped_not_dropped() {
  local rec id out status launch
  for id in agy-effort-xhigh-q2 agy-effort-max-q3; do
    rec=$(make_spawn_case "effort-$id" "$id")
    read_case_record "$rec"
    case "$id" in
      *xhigh*) out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness agy --model gemini-4-argon-high --effort xhigh) ;;
      *) out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness agy --model gemini-4-argon-high --effort max) ;;
    esac
    status=$?
    expect_code 0 "$status" "an above-range effort must still launch: $out"
    launch=$(cat "$LAUNCH_LOG")
    assert_contains "$launch" "--effort 'high'" "an above-range effort must be capped onto agy's highest level, not dropped"
    case "$id" in
      *xhigh*) assert_grep "effort=xhigh" "$HOME_DIR/state/$id.meta" "the requested effort must still be recorded verbatim" ;;
      *) assert_grep "effort=max" "$HOME_DIR/state/$id.meta" "the requested effort must still be recorded verbatim" ;;
    esac
  done

  rec=$(make_spawn_case effort-low agy-effort-low-q4)
  read_case_record "$rec"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" agy-effort-low-q4 "$PROJ_DIR" --harness agy --model gemini-4-argon-high --effort low)
  expect_code 0 "$?" "a supported effort must launch: $out"
  assert_contains "$(cat "$LAUNCH_LOG")" "--effort 'low'" "a supported effort must pass through unchanged"
  pass "fm-spawn: agy caps xhigh and max onto high while recording the requested effort verbatim"
}

test_spawn_model_validation() {
  local rec id out status
  rec=$(make_spawn_case model-refused agy-model-refused-q5)
  read_case_record "$rec"
  id=agy-model-refused-q5
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness agy --model gemini-not-a-real-model)
  status=$?
  expect_code 1 "$status" "a model the account cannot see must refuse rather than launch a pane that dies"
  assert_contains "$out" "is not listed by 'agy models' for this account" "refusal did not name the listing evidence"
  assert_contains "$out" "choose a listed gemini-* id" "refusal did not ask for a listed gemini-* id"
  assert_not_contains "$out" "omit --model" "refusal must not advise omitting --model"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must publish no record"

  rec=$(make_spawn_case model-unreadable agy-model-unreadable-q6 no-listing)
  read_case_record "$rec"
  id=agy-model-unreadable-q6
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness agy --model gemini-some-private-model)
  status=$?
  expect_code 0 "$status" "an unreadable listing establishes nothing and must not refuse: $out"
  assert_contains "$(cat "$LAUNCH_LOG")" "--model 'gemini-some-private-model'" "the unvalidated model did not reach the launch line"
  pass "fm-spawn: an unlisted agy model refuses, while an unreadable listing passes through"
}

# --- 3b. Gemini-only model guard ----------------------------------------------

# A refused agy spawn must leave nothing behind: no launch reached the pane, no
# task record, no per-task hook root, and no trust registration.
assert_no_agy_launch_side_effect() {  # <home> <id> <launch-log> <label>
  local home=$1 id=$2 launchlog=$3 label=$4
  [ ! -s "$launchlog" ] || fail "$label: a refused agy spawn must send no launch: $(cat "$launchlog")"
  assert_absent "$home/state/$id.meta" "$label: a refused agy spawn must publish no record"
  assert_absent "$home/state/$id.agy-hooks" "$label: a refused agy spawn must write no hook root"
  assert_absent "$home/user-home/.gemini/antigravity-cli/settings.json" \
    "$label: a refused agy spawn must not pre-register workspace trust"
}

assert_gemini_only_refusal() {  # <output> <label> [rejected-model]
  local out=$1 label=$2 model=${3:-}
  assert_contains "$out" "agy runs Gemini models only" "$label: the refusal did not state the Gemini-only rule"
  assert_contains "$out" "use the claude harness for Anthropic models or the codex harness for OpenAI models" \
    "$label: the refusal did not point at each vendor's own harness"
  if [ -n "$model" ]; then
    assert_contains "$out" "refusing model '$model'" "$label: the refusal did not name the rejected model"
  else
    assert_contains "$out" "none was given" "$label: the refusal did not say no model was given"
  fi
}

# Every ship and scout spawn refuses an Anthropic id, an OpenAI id, an omitted
# model, and the explicit `default`, even though the account catalog lists the
# Anthropic and OpenAI ids, and an empty model never reaches a launch either.
test_spawn_refuses_non_gemini_models() {
  local kind model n=0 id rec out status label
  for kind in ship scout; do
    for model in claude-opus-5-5 gpt-6-sol @none default @empty; do
      n=$((n + 1))
      id="agy-guard-$kind-$n"
      label="$kind spawn with model ${model}"
      rec=$(make_spawn_case "guard-$kind-$n" "$id")
      read_case_record "$rec"
      local -a model_args=()
      case "$model" in
        @none) ;;
        @empty) model_args=(--model '') ;;
        *) model_args=(--model "$model") ;;
      esac
      if [ "$kind" = ship ]; then
        out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness agy "${model_args[@]+"${model_args[@]}"}")
      else
        out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness agy "${model_args[@]+"${model_args[@]}"}")
      fi
      status=$?
      expect_code 1 "$status" "$label must refuse: $out"
      case "$model" in
        @none|default) assert_gemini_only_refusal "$out" "$label" ;;
        @empty) assert_contains "$out" "--model requires a non-empty value" "$label: an empty model must refuse" ;;
        *) assert_gemini_only_refusal "$out" "$label" "$model" ;;
      esac
      assert_no_agy_launch_side_effect "$HOME_DIR" "$id" "$LAUNCH_LOG" "$label"
    done
  done

  # The rule does not depend on the account catalog: with no readable listing
  # an Anthropic id is still refused.
  rec=$(make_spawn_case guard-no-listing agy-guard-no-listing no-listing)
  read_case_record "$rec"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" agy-guard-no-listing "$PROJ_DIR" --harness agy --model claude-opus-5-5)
  expect_code 1 "$?" "an Anthropic id must refuse even with no readable catalog: $out"
  assert_gemini_only_refusal "$out" "no-listing scout" claude-opus-5-5
  assert_no_agy_launch_side_effect "$HOME_DIR" agy-guard-no-listing "$LAUNCH_LOG" "no-listing scout"
  pass "fm-spawn: every agy ship and scout spawn refuses Anthropic, OpenAI, omitted, and default models before any launch side effect"
}

test_spawn_allows_gemini_models() {
  local kind model n=0 id rec out status
  for kind in ship scout; do
    for model in gemini-4-argon-high gemini-3.8-flash-high gemini-4+preview; do
      n=$((n + 1))
      id="agy-allow-$kind-$n"
      rec=$(make_spawn_case "allow-$kind-$n" "$id")
      read_case_record "$rec"
      if [ "$kind" = ship ]; then
        out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness agy --model "$model")
      else
        out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness agy --model "$model")
      fi
      status=$?
      expect_code 0 "$status" "an agy $kind spawn on $model must launch: $out"
      assert_contains "$(cat "$LAUNCH_LOG")" "--model '$model' " "the $kind launch did not carry $model"
      assert_grep "model=$model" "$HOME_DIR/state/$id.meta" "the $kind record did not keep $model"
    done
  done
  pass "fm-spawn: agy ship and scout spawns launch on explicit gemini-* models"
}

# A raw launch command naming agy carries its model inside an opaque string,
# so it is refused in favor of the canonical adapter whatever model it names.
test_raw_agy_launch_is_refused() {
  local raw n=0 id rec out
  for raw in "agy --model gemini-4-argon-high" "agy --model claude-opus-5-5" \
    "env agy --model claude-opus-5-5" "sh -c 'agy --model gpt-6-sol'" \
    "'/opt/vendor/agy' --model claude-opus-5-5" "nice \"agy\" --model gpt-6-sol"; do
    n=$((n + 1))
    id="agy-raw-$n"
    rec=$(make_spawn_case "raw-$n" "$id")
    read_case_record "$rec"
    out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" "$raw")
    expect_code 1 "$?" "a raw agy launch must refuse: $out"
    assert_contains "$out" "agy runs Gemini models only and must launch through the canonical adapter" \
      "the raw agy refusal did not point at the canonical adapter"
    assert_no_agy_launch_side_effect "$HOME_DIR" "$id" "$LAUNCH_LOG" "raw agy launch '$raw'"
  done
  rec=$(make_spawn_case raw-non-agy agy-raw-non-agy)
  read_case_record "$rec"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" agy-raw-non-agy "$PROJ_DIR" "env custom-agent --flag")
  expect_code 0 "$?" "a raw non-agy launch must remain allowed: $out"
  assert_contains "$(cat "$LAUNCH_LOG")" "env custom-agent --flag" "the raw non-agy launch was not passed to the backend"
  pass "fm-spawn: a raw agy launch command is refused in favor of the canonical Gemini-only adapter"
}

test_secondmate_is_refused() {
  local world home fakebin out status
  world="$TMP_ROOT/secondmate"
  home="$world/sm"
  mkdir -p "$world/home/state" "$world/home/data" "$world/home/config" "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'sm\n' > "$home/.fm-secondmate-home"
  printf 'charter\n' > "$home/data/charter.md"
  fakebin=$(make_spawn_fakebin "$world/fake" claude)
  make_fake_agy "$fakebin"
  local model
  # The Gemini-only model guard must not displace this refusal, whatever model
  # the secondmate request names.
  for model in @none claude-opus-5-5 gemini-4-argon-high; do
    local -a model_args=()
    [ "$model" = @none ] || model_args=(--model "$model")
    out=$(PATH="$fakebin:$PATH" TMUX='fake,1,0' FM_BACKEND=tmux \
      FM_ROOT_OVERRIDE='' FM_HOME="$world/home" HOME="$world/user-home" \
      FM_STATE_OVERRIDE="$world/home/state" FM_DATA_OVERRIDE="$world/home/data" \
      FM_CONFIG_OVERRIDE="$world/home/config" FM_SPAWN_NO_GUARD=1 \
      "$ROOT/bin/fm-spawn.sh" sm-agy "$home" agy "${model_args[@]+"${model_args[@]}"}" --secondmate 2>&1)
    status=$?
    expect_code 1 "$status" "an agy secondmate with model $model must be refused: $out"
    assert_contains "$out" "agy is a verified crewmate/scout adapter only" "the refusal for model $model did not name agy's verified scope"
    assert_not_contains "$out" "agy runs Gemini models only" "the secondmate refusal for model $model was displaced by the model guard"
    assert_absent "$world/home/state/sm-agy.meta" "a refused agy secondmate must publish no record"
  done
  pass "fm-spawn: an agy secondmate is refused because it has no primary supervision protocol, ahead of the model guard"
}

# --- 4. Trust pre-registration scope -----------------------------------------

test_trust_scope_refusals_and_idempotence() {
  local world proj wt home out status store
  world="$TMP_ROOT/trust"
  proj="$world/project"
  wt="$world/wt"
  home="$world/user-home"
  mkdir -p "$home"
  fm_git_worktree "$proj" "$wt" wt-trust
  store="$home/.gemini/antigravity-cli/settings.json"

  out=$(HOME="$home" "$TRUST" "$wt" "$proj" 2>&1)
  expect_code 0 "$?" "a fresh task worktree must be trusted: $out"
  assert_present "$store" "the trust store was not created"
  assert_grep "$wt" "$store" "the worktree was not recorded as trusted"

  # A repeat registration must not grow the operator's list with duplicates.
  out=$(HOME="$home" "$TRUST" "$wt" "$proj" 2>&1)
  expect_code 0 "$?" "repeat registration must succeed: $out"
  [ "$(grep -c -- "$wt" "$store")" = 1 ] || fail "repeat registration must be idempotent, not append a duplicate"

  # Unrelated keys and pre-existing entries survive the rewrite.
  printf '%s\n' '{"enableTelemetry": false, "trustedWorkspaces": ["/already/here"]}' > "$store"
  out=$(HOME="$home" "$TRUST" "$wt" "$proj" 2>&1)
  expect_code 0 "$?" "registration into an existing store must succeed: $out"
  assert_grep '"enableTelemetry"' "$store" "an unrelated key was lost"
  assert_grep '/already/here' "$store" "an existing trusted workspace was lost"
  assert_grep "$wt" "$store" "the worktree was not added alongside the existing entry"

  # The primary checkout is not a task worktree and must be refused.
  out=$(HOME="$home" "$TRUST" "$proj" "$proj" 2>&1)
  status=$?
  expect_code 1 "$status" "the primary checkout must be refused"
  assert_contains "$out" "is a primary checkout" "the refusal did not name the structural reason"

  # A worktree of an unrelated repository must be refused.
  local other other_wt
  other="$world/other"
  other_wt="$world/other-wt"
  fm_git_worktree "$other" "$other_wt" wt-other
  out=$(HOME="$home" "$TRUST" "$other_wt" "$proj" 2>&1)
  status=$?
  expect_code 1 "$status" "a worktree of an unrelated repo must be refused"
  assert_contains "$out" "is not a worktree of project" "the refusal did not name the mismatched project"

  # A plain directory is refused, and the home directory is refused by name.
  mkdir -p "$world/plain"
  out=$(HOME="$home" "$TRUST" "$world/plain" "$proj" 2>&1)
  expect_code 1 "$?" "a plain directory must be refused"
  out=$(HOME="$home" "$TRUST" "$home" "$proj" 2>&1)
  status=$?
  expect_code 1 "$status" "the home directory must be refused"
  assert_contains "$out" "is the home directory" "the refusal did not name the home directory"

  # An exported CDPATH must not be able to redirect the relative `.git` operand
  # the primary-checkout refusal depends on.
  out=$(HOME="$home" CDPATH="$world" "$TRUST" "$proj" "$proj" 2>&1)
  expect_code 1 "$?" "an exported CDPATH must not defeat the primary-checkout refusal"
  # Inherited git environment overrides must not either.
  out=$(HOME="$home" GIT_DIR="$wt/.git" GIT_WORK_TREE="$wt" "$TRUST" "$proj" "$proj" 2>&1)
  expect_code 1 "$?" "inherited git overrides must not defeat the primary-checkout refusal"
  pass "fm-agy-trust.sh: the structural scope test holds and registration is idempotent"
}

test_cross_clone_pool_slot_provenance_and_refusals() {
  local world upstream clone_a clone_b home_a home_b pool slot manual_wt user_home store out
  world="$TMP_ROOT/cross-clone"
  upstream="$world/upstream.git"
  home_a="$world/home-a"
  home_b="$world/home-b"
  clone_a="$home_a/projects/repo"
  clone_b="$home_b/projects/repo"
  pool="$world/pool"
  slot="$pool/1/repo"
  manual_wt="$world/manual-wt"
  user_home="$world/user-home"
  store="$user_home/.gemini/antigravity-cli/settings.json"
  mkdir -p "$home_a/projects" "$home_a/state" "$home_b/projects" "$home_b/state" "$pool/1" "$user_home"

  git init --bare -b main -q "$upstream"
  git clone -q "$upstream" "$clone_a"
  git -C "$clone_a" -c user.name=test -c user.email=test@example.invalid commit --allow-empty -qm init
  git -C "$clone_a" push -q -u origin main
  git clone -q "$upstream" "$clone_b"
  git -C "$clone_a" worktree add -q --detach "$slot" HEAD
  git -C "$clone_a" worktree add -q --detach "$manual_wt" HEAD

  # 1. Idle unleased & unclaimed cross-clone slot in pool must be refused.
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$slot" > "$pool/treehouse-state.json"
  out=$(FM_HOME="$home_b" HOME="$user_home" "$TRUST" "$slot" "$clone_b" 2>&1)
  expect_code 1 "$?" "an idle unleased cross-clone slot must be refused: $out"
  assert_contains "$out" "is not a worktree of project" "idle cross-clone refusal did not name project mismatch"

  # 2. Active Treehouse lease without a same-home claim is refused.
  printf '{"worktrees":[{"name":"1","path":"%s","owner_pid":%s}]}\n' "$slot" "$$" > "$pool/treehouse-state.json"
  out=$(FM_HOME="$home_b" HOME="$user_home" "$TRUST" "$slot" "$clone_b" 2>&1)
  expect_code 1 "$?" "an unclaimed leased cross-clone pool slot must be refused: $out"
  [ ! -e "$store" ] || fail "unclaimed leased cross-clone pool slot was trusted"

  # 3. Same-home .fm-slot-owner claim after process lease exit is accepted.
  rm -f "$store"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$slot" > "$pool/treehouse-state.json"
  printf 'task=task-b\nhome=%s\n' "$home_b" > "$pool/1/.fm-slot-owner"
  out=$(FM_HOME="$home_b" HOME="$user_home" "$TRUST" "$slot" "$clone_b" 2>&1)
  expect_code 0 "$?" "a same-home claimed cross-clone pool slot must be trusted: $out"
  assert_grep "$slot" "$store" "claimed cross-clone pool slot was not trusted"

  # 4. Foreign-home .fm-slot-owner claim is refused even when leased.
  rm -f "$store"
  printf '{"worktrees":[{"name":"1","path":"%s","owner_pid":%s}]}\n' "$slot" "$$" > "$pool/treehouse-state.json"
  printf 'task=task-a\nhome=%s\n' "$home_a" > "$pool/1/.fm-slot-owner"
  out=$(FM_HOME="$home_b" HOME="$user_home" "$TRUST" "$slot" "$clone_b" 2>&1)
  expect_code 1 "$?" "a foreign-home claimed cross-clone slot must be refused: $out"

  # 5. Unpooled manual linked worktree of Clone A is refused for Clone B.
  out=$(FM_HOME="$home_b" HOME="$user_home" "$TRUST" "$manual_wt" "$clone_b" 2>&1)
  expect_code 1 "$?" "an unpooled manual worktree of another clone must be refused: $out"

  pass "fm-agy-trust.sh: accepts same-home claimed cross-clone pool slots and refuses unclaimed, foreign-claimed, or unpooled cross-clone worktrees"
}

test_detection_anchored_name_and_marker_precedence
test_detection_marker_needs_real_ancestry
test_tmux_liveness_classification
test_control_tables
test_wiring_paths_and_busy_source_trust
test_spawn_launch_line_hooks_and_trust
test_ship_and_scout_launch_shapes_match
test_spawn_effort_is_capped_not_dropped
test_spawn_model_validation
test_spawn_refuses_non_gemini_models
test_spawn_allows_gemini_models
test_raw_agy_launch_is_refused
test_secondmate_is_refused
test_trust_scope_refusals_and_idempotence
test_cross_clone_pool_slot_provenance_and_refusals
