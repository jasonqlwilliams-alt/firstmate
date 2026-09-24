#!/usr/bin/env bash
# Behavior tests for bin/fm-backup-helm.sh.
#
# Drives the public commands with a fake quota-axi, a fake cursor-agent catalog,
# and a pane driver. Nothing here asserts implementation-source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BIN="$ROOT/bin/fm-backup-helm.sh"
TMP_ROOT=$(fm_test_tmproot fm-backup-helm)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

helm() {
  PATH="$FAKEBIN:$PATH" "$BIN" "$@"
}

write_quota() {  # <json-file>
  cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then
  printf 'quota-axi 0.1.29\\n'
  exit 0
fi
cat '$1'
SH
  chmod +x "$FAKEBIN/quota-axi"
}

# Fake successor CLI. Mode file selects: answer, invoice (billing refusal),
# wrong (exit 0 with the wrong answer), hang (outlives the probe bound).
# Every headless call records its cwd, FM_HOME, and argv.
PROBE_LOG="$TMP_ROOT/probe.log"
write_successor() {  # <name> <help-line>
  cat > "$FAKEBIN/$1" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "--help" ]; then
  printf '%s\\n' '$2'
  exit 0
fi
printf 'cwd=%s fm_home=%s argv=%s\\n' "\$PWD" "\${FM_HOME:-unset}" "\$*" >> '$PROBE_LOG'
prompt=\${!#}
mode=\$(cat '$TMP_ROOT/mode-$1' 2>/dev/null || printf answer)
case "\$mode" in
  invoice) printf 'ActionRequiredError: You have an unpaid invoice\\n' >&2; exit 1 ;;
  wrong) printf 'FMHELM OK\\n'; exit 0 ;;
  hang) sleep 5; exit 0 ;;
esac
suffix=\$(printf '%s\\n' "\$prompt" | sed -n 's/.*FMHELM and \\(OK[0-9]*\\).*/\\1/p')
printf 'FMHELM%s\\n' "\$suffix"
SH
  chmod +x "$FAKEBIN/$1"
}
set_mode() { printf '%s\n' "$2" > "$TMP_ROOT/mode-$1"; }

new_home() {
  mkdir -p "$1/state" "$1/config" "$1/bin" "$1/.cursor" "$1/.pi/extensions"
  printf '{}\n' > "$1/.cursor/hooks.json"
  : > "$1/AGENTS.md"
  : > "$1/bin/fm-session-start.sh"
  : > "$1/.pi/extensions/fm-primary-turnend-guard.ts"
  fm_test_track_procevent_home "$1"
}

successor() { printf '%s\n' "$2" > "$1/config/backup-helm-successor"; }

quota_true="$TMP_ROOT/quota-true.json"
quota_false="$TMP_ROOT/quota-false.json"
quota_exhausted="$TMP_ROOT/quota-exhausted.json"
quota_unknown="$TMP_ROOT/quota-unknown.json"
quota_missing="$TMP_ROOT/quota-missing.json"
quota_fable_exhausted_all_models_healthy="$TMP_ROOT/quota-fable-healthy.json"
quota_fable_exhausted_all_models_short="$TMP_ROOT/quota-fable-short.json"
quota_at_threshold="$TMP_ROOT/quota-at-threshold.json"
cat > "$quota_true" <<'EOF'
{"schemaVersion":5,"providers":[{"provider":"claude","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":8,"runway":{"status":"projected_exhaustion","usableRunwaySeconds":40000}}]}}]}
EOF
cat > "$quota_false" <<'EOF'
{"schemaVersion":5,"providers":[{"provider":"claude","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":20,"runway":{"status":"projected_exhaustion","usableRunwaySeconds":50000}}]}}]}
EOF
cat > "$quota_exhausted" <<'EOF'
{"schemaVersion":5,"providers":[{"provider":"claude","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now","usableRunwaySeconds":0}}]}}]}
EOF
cat > "$quota_unknown" <<'EOF'
{"schemaVersion":5,"providers":[{"provider":"claude","quotaSemantics":{"status":"unknown","effectiveAvailability":[{"scope":"all_models","status":"unknown","runway":{"status":"unknown"}}]}}]}
EOF
cat > "$quota_missing" <<'EOF'
{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":50,"runway":{"status":"through_reset"}}]}}]}
EOF
cat > "$quota_fable_exhausted_all_models_healthy" <<'EOF'
{"schemaVersion":5,"providers":[{"provider":"claude","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":23,"runway":{"status":"projected_exhaustion","usableRunwaySeconds":100000}},{"scope":"model:claude-fable","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now","usableRunwaySeconds":0}}]}}]}
EOF
cat > "$quota_fable_exhausted_all_models_short" <<'EOF'
{"schemaVersion":5,"providers":[{"provider":"claude","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":23,"runway":{"status":"projected_exhaustion","usableRunwaySeconds":40000}},{"scope":"model:claude-fable","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now","usableRunwaySeconds":0}}]}}]}
EOF
cat > "$quota_at_threshold" <<'EOF'
{"schemaVersion":5,"providers":[{"provider":"claude","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":10,"runway":{"status":"projected_exhaustion","usableRunwaySeconds":43200}}]}}]}
EOF

write_successor pi 'pi - coding agent'
write_successor cursor-agent 'Start the Cursor Agent'
export FM_BACKUP_HELM_PROBE_DIR="$TMP_ROOT/probe-dir"

# --- condition --------------------------------------------------------------
write_quota "$quota_true"
set +e
helm condition
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "projected usableRunwaySeconds under 43200 must be true, got $rc"
write_quota "$quota_false"
set +e
helm condition
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "usableRunwaySeconds at 50000 must be a clean false, got $rc"
write_quota "$quota_exhausted"
set +e
helm condition
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "all_models exhausted_now must be true, got $rc"
write_quota "$quota_unknown"
set +e
helm condition
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "unknown Claude quota must stay false so the watch keeps polling, got $rc"
write_quota "$quota_missing"
set +e
helm condition >/dev/null 2>"$TMP_ROOT/missing.err"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "a snapshot with no Claude provider must error, got $rc"
write_quota "$quota_at_threshold"
set +e
helm condition
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "usableRunwaySeconds equal to 43200 must be a clean false, got $rc"
write_quota "$quota_fable_exhausted_all_models_healthy"
set +e
helm condition
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "a Fable window at 0% must not fire while all_models runway is above 12 hours, got $rc"
write_quota "$quota_fable_exhausted_all_models_short"
set +e
helm condition
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "all_models usableRunwaySeconds under 43200 must fire even when a sibling Fable window is also exhausted, got $rc"
pass "condition classifies Claude all_models runway"

# --- probe ------------------------------------------------------------------
: > "$PROBE_LOG"
out=$(FM_HOME=/should/not/leak helm probe --harness pi --model m1 --effort high) || fail "probe must succeed when the successor answers"
assert_contains "$out" "status=ok" "probe ok line"
assert_contains "$out" "harness=pi model=m1 effort=high" "probe names the successor"
probe_call=$(cat "$PROBE_LOG")
assert_contains "$probe_call" "cwd=$FM_BACKUP_HELM_PROBE_DIR " "probe runs in the private probe directory"
assert_contains "$probe_call" "fm_home=unset" "probe clears FM_HOME so no hook can reach a home"
assert_contains "$probe_call" "-p " "probe is a headless request"
assert_contains "$probe_call" "--model m1" "probe asks the configured model"
assert_contains "$probe_call" "--thinking high" "probe carries the configured effort"
set_mode pi invoice
set +e
out=$(helm probe --harness pi)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "probe must fail when the provider refuses the request"
assert_contains "$out" "status=no-answer" "billing refusal is no-answer"
assert_contains "$out" "unpaid invoice" "probe surfaces the provider's reason"
set_mode pi wrong
set +e
out=$(helm probe --harness pi)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "a wrong answer must not pass the probe"
assert_contains "$out" "status=no-answer" "wrong answer is no-answer"
set_mode pi hang
set +e
out=$(FM_BACKUP_HELM_PROBE_TIMEOUT=1 helm probe --harness pi)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "a hung successor must not pass the probe"
assert_contains "$out" "status=timeout" "hung successor is a timeout"
set_mode pi answer
set +e
out=$(helm probe --harness omp)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "a missing successor executable must fail the probe"
assert_contains "$out" "status=unavailable" "missing executable is unavailable"
GITDIR="$TMP_ROOT/inside-git"
mkdir -p "$GITDIR"
git -C "$GITDIR" init -q
set +e
out=$(FM_BACKUP_HELM_PROBE_DIR="$GITDIR/probe" helm probe --harness pi)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "a probe directory inside a git checkout must be refused"
assert_contains "$out" "status=refused" "probe inside a checkout is refused"
pass "probe demands a correct answer and reports why a successor does not answer"

# --- handover fail-closed paths ---------------------------------------------
H="$TMP_ROOT/h-handover"
new_home "$H"
printf '999999\n' > "$H/state/.lock"
SEND_LOG="$TMP_ROOT/send.log"
LAUNCH_LOG="$TMP_ROOT/launch.log"
: >"$SEND_LOG"
: >"$LAUNCH_LOG"

cat > "$FAKEBIN/busy-driver" <<SH
#!/usr/bin/env bash
case "\$1" in
  target-exists) exit 0 ;;
  lock-status) printf 'held\\n'; exit 0 ;;
  busy) exit 0 ;;
  composer) printf 'empty\\n'; exit 0 ;;
  send) printf '%s\\n' "\$2" >> '$SEND_LOG'; exit 0 ;;
  launch) printf '%s\\n' "\$2" >> '$LAUNCH_LOG'; exit 0 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/busy-driver"

set +e
FM_HOME="$H" FM_BACKUP_HELM_DRIVER="$FAKEBIN/busy-driver" \
  FM_BACKUP_HELM_IDLE_TIMEOUT=1 FM_BACKUP_HELM_POLL=0.1 \
  helm handover --harness pi --backend tmux --target firstmate:0 --workspace "$H" \
  >"$TMP_ROOT/midturn.out" 2>"$TMP_ROOT/midturn.err"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "a mid-turn Claude must fail closed"
assert_grep "mid-turn" "$TMP_ROOT/midturn.err" "mid-turn refusal names the wait"
[ ! -s "$SEND_LOG" ] || fail "mid-turn refusal must not send /stow or /exit"
[ ! -s "$LAUNCH_LOG" ] || fail "mid-turn refusal must not launch the successor"
assert_present "$H/state/.lock" "mid-turn refusal must leave the session lock file"
assert_equals "$(cat "$H/state/.lock")" "999999" "mid-turn refusal must not rewrite the lock"
pass "mid-turn Claude is waited out and never interrupted"

set_mode pi invoice
: >"$SEND_LOG"
set +e
FM_HOME="$H" FM_BACKUP_HELM_DRIVER="$FAKEBIN/busy-driver" \
  helm handover --harness pi --backend tmux --target firstmate:0 --workspace "$H" \
  >"$TMP_ROOT/probe-fail.out" 2>"$TMP_ROOT/probe-fail.err"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "handover must fail closed when the successor does not answer"
assert_grep "did not answer" "$TMP_ROOT/probe-fail.err" "handover names the dead successor"
assert_grep "unpaid invoice" "$TMP_ROOT/probe-fail.out" "handover records the provider's reason"
[ ! -s "$SEND_LOG" ] || fail "a failed probe must not send into the Claude pane"
set_mode pi answer
pass "a successor that does not answer refuses the handover before any pane send"

set +e
FM_HOME="$H" FM_BACKUP_HELM_DRIVER="$FAKEBIN/busy-driver" \
  helm handover --backend tmux --target firstmate:0 --workspace "$H" \
  >/dev/null 2>"$TMP_ROOT/no-harness.err"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "handover without --harness must be refused"
assert_grep "no default successor" "$TMP_ROOT/no-harness.err" "missing successor is named"
[ ! -s "$SEND_LOG" ] || fail "a handover without a successor must not send into the Claude pane"
pass "handover never defaults a successor"

set +e
FM_HOME="$H" helm handover --harness pi --backend zellij --target zellij:0 --workspace "$H" \
  >/dev/null 2>"$TMP_ROOT/zellij.err"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "zellij handover must be refused"
assert_grep "tmux or herdr" "$TMP_ROOT/zellij.err" "unsupported backend is named"
pass "unsupported backends are refused"

set +e
unset FM_HOME
helm handover --harness pi --backend tmux --target firstmate:0 --workspace "$H" \
  >/dev/null 2>"$TMP_ROOT/nohome.err"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "handover without FM_HOME must be refused"
assert_grep "FM_HOME is not set" "$TMP_ROOT/nohome.err" "missing home is named"
pass "handover requires an explicit FM_HOME"

# --- handover happy path ----------------------------------------------------
LOCK_STATE="$TMP_ROOT/lock-state"
printf 'held\n' > "$LOCK_STATE"
cat > "$FAKEBIN/idle-driver" <<SH
#!/usr/bin/env bash
case "\$1" in
  target-exists) exit 0 ;;
  lock-status) cat '$LOCK_STATE'; exit 0 ;;
  busy) exit 1 ;;
  composer) printf 'empty\\n'; exit 0 ;;
  send)
    printf '%s\\n' "\$2" >> '$SEND_LOG'
    if [ "\$2" = /exit ]; then printf 'released\\n' > '$LOCK_STATE'; fi
    exit 0
    ;;
  launch) printf '%s\\n' "\$2" >> '$LAUNCH_LOG'; exit 0 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/idle-driver"
: >"$SEND_LOG"
: >"$LAUNCH_LOG"
printf '999999\n' > "$H/state/.lock"
out=$(
  FM_HOME="$H" FM_BACKUP_HELM_DRIVER="$FAKEBIN/idle-driver" \
    FM_BACKUP_HELM_IDLE_TIMEOUT=2 FM_BACKUP_HELM_STOW_TIMEOUT=2 \
    FM_BACKUP_HELM_LOCK_TIMEOUT=2 FM_BACKUP_HELM_POLL=0.1 \
    helm handover --harness pi --backend tmux --target firstmate:0 --workspace "$H"
) || fail "idle handover must succeed"
assert_contains "$out" "/stow" "handover sends /stow"
assert_contains "$out" "/exit" "handover sends /exit"
assert_contains "$out" "launch-command:" "handover prints the launch command"
assert_contains "$out" "env -u CLAUDECODE" "launch clears foreign Claude markers"
send=$(cat "$SEND_LOG")
assert_contains "$send" "/stow" "driver recorded /stow"
assert_contains "$send" "/exit" "driver recorded /exit"
launch=$(cat "$LAUNCH_LOG")
assert_contains "$launch" "$FAKEBIN/pi --approve" "driver launch starts interactive pi trusting the checkout"
assert_contains "$launch" "FM_HOME=$H" "driver launch binds the home"
assert_not_contains "$launch" " -p " "driver launch must not be headless"
assert_present "$H/state/.lock" "successful handover must not delete the lock file"
# The launch line is what the pane shell runs: prove it starts the successor
# in the checkout with the home bound and the instruction as one argument.
: > "$PROBE_LOG"
PATH="$FAKEBIN:$PATH" bash -c "$launch" >/dev/null 2>&1 || true
assert_contains "$(cat "$PROBE_LOG")" "cwd=$H fm_home=$H argv=--approve" "launch line starts pi in the checkout"
assert_contains "$(cat "$PROBE_LOG")" "FIRSTMATE_OP: v1 session-start: Run \`bin/fm-session-start.sh\` now" "launch opens with the session-start instruction"
pass "idle handover stows, exits, and launches the configured successor"

: >"$SEND_LOG"
: >"$LAUNCH_LOG"
printf 'released\n' > "$LOCK_STATE"
out=$(
  FM_HOME="$H" FM_BACKUP_HELM_DRIVER="$FAKEBIN/idle-driver" \
    helm handover --harness cursor --model cursor-grok-4.6-high --backend tmux --target firstmate:0 --workspace "$H"
) || fail "a cursor successor handover must succeed when Cursor answers"
launch=$(cat "$LAUNCH_LOG")
assert_contains "$launch" "--trust --yolo --model cursor-grok-4.6-high --workspace $H" "cursor launch keeps its proven primary flags"
assert_not_contains "$launch" " -p " "cursor launch must not be headless"
pass "a cursor successor keeps the proven interactive Cursor primary shape"

printf 'released\n' > "$LOCK_STATE"
: >"$SEND_LOG"
: >"$LAUNCH_LOG"
out=$(
  FM_HOME="$H" FM_BACKUP_HELM_DRIVER="$FAKEBIN/idle-driver" \
    helm handover --harness pi --backend tmux --target firstmate:0 --workspace "$H"
) || fail "handover with an already-released lock must still launch"
assert_contains "$out" "skipping Claude /stow and /exit" "released lock skips Claude slash commands"
assert_not_contains "$(cat "$SEND_LOG")" "/stow" "released lock must not send /stow"
assert_not_contains "$(cat "$SEND_LOG")" "/exit" "released lock must not send /exit"
assert_contains "$(cat "$LAUNCH_LOG")" "--approve" "released lock still launches the successor"
pass "already-released lock skips /stow and /exit then launches"

cat > "$FAKEBIN/unknown-lock-driver" <<SH
#!/usr/bin/env bash
case "\$1" in
  target-exists) exit 0 ;;
  lock-status) printf 'mystery\\n'; exit 0 ;;
  busy) exit 1 ;;
  composer) printf 'empty\\n'; exit 0 ;;
  send) printf '%s\\n' "\$2" >> '$SEND_LOG'; exit 0 ;;
  launch) printf '%s\\n' "\$2" >> '$LAUNCH_LOG'; exit 0 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/unknown-lock-driver"
: >"$SEND_LOG"
: >"$LAUNCH_LOG"
set +e
FM_HOME="$H" FM_BACKUP_HELM_DRIVER="$FAKEBIN/unknown-lock-driver" \
  helm handover --harness pi --backend tmux --target firstmate:0 --workspace "$H" \
  >/dev/null 2>"$TMP_ROOT/unknown-lock.err"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "an unreadable lock status must fail closed"
assert_grep "neither held" "$TMP_ROOT/unknown-lock.err" "unreadable lock is refused"
[ ! -s "$SEND_LOG" ] || fail "unreadable lock must not send /stow or /exit"
[ ! -s "$LAUNCH_LOG" ] || fail "unreadable lock must not launch the successor"
pass "unreadable lock status refuses the handover"

# --- arm / retire -----------------------------------------------------------
arm_refused() {  # <home> <expected-stderr> <label>
  local rc
  set +e
  FM_HOME="$1" helm arm --backend tmux --target firstmate:0 --workspace "$1" \
    >"$TMP_ROOT/arm-refused.out" 2>"$TMP_ROOT/arm-refused.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$3: arm must be refused"
  assert_grep "$2" "$TMP_ROOT/arm-refused.err" "$3: refusal names the reason"
  assert_absent "$1/state/when/when-backup-helm-claude-runway.spec" "$3: a refused arm must not leave a watch"
}

HNONE="$TMP_ROOT/h-arm-none"
new_home "$HNONE"
: > "$PROBE_LOG"
arm_refused "$HNONE" "no backup helm successor is configured" "absent successor file"
successor "$HNONE" '# comment only'
arm_refused "$HNONE" "no backup helm successor is configured" "comment-only successor file"
successor "$HNONE" 'default'
arm_refused "$HNONE" "no default successor" "default successor"
[ ! -s "$PROBE_LOG" ] || fail "an unset successor must never be probed or guessed"
successor "$HNONE" 'claude'
arm_refused "$HNONE" "claude cannot be the backup helm successor" "claude successor"
successor "$HNONE" 'agy'
arm_refused "$HNONE" "not an eligible backup helm successor" "agy successor"
successor "$HNONE" 'cursor'
arm_refused "$HNONE" "explicit model other than auto" "cursor without a model"
successor "$HNONE" 'cursor auto'
arm_refused "$HNONE" "explicit model other than auto" "cursor auto"
successor "$HNONE" 'codex gpt max'
arm_refused "$HNONE" "does not accept effort 'max'" "unsupported effort"
successor "$HNONE" 'cursor cursor-grok-4.6-high high'
arm_refused "$HNONE" "has no effort flag" "effort on a harness without one"
successor "$HNONE" 'omp'
arm_refused "$HNONE" "carrying .omp/extensions" "checkout without the successor's primary integration"
successor "$HNONE" 'pi m1 high extra'
arm_refused "$HNONE" "more than three fields" "extra successor fields"
pass "arm refuses an unset, default, ineligible, or malformed successor by name"

HARM="$TMP_ROOT/h-arm"
new_home "$HARM"
successor "$HARM" '# backup helm successor
pi m1 high'
out=$(
  FM_HOME="$HARM" helm arm --backend tmux --target firstmate:0 --workspace "$HARM" \
    --interval 60 --stable 2 --action-timeout 3600
) || fail "arm must succeed when the configured successor answers"
assert_contains "$out" "status=ok" "arm reports the successful probe"
assert_contains "$out" "armed: when-backup-helm-claude-runway" "arm reports the source id"
assert_contains "$out" "runway-seconds: 43200" "arm records the 12-hour trigger"
assert_contains "$out" "successor: pi" "arm records the successor harness"
assert_contains "$out" "model: m1" "arm records the successor model"
assert_contains "$out" "effort: high" "arm records the successor effort"
assert_present "$HARM/state/when/when-backup-helm-claude-runway.spec" "arm writes the when spec"
sid=$(FM_HOME="$HARM" helm source-id)
assert_contains "$sid" "when-backup-helm-claude-runway" "source-id matches the watch"
set +e
FM_HOME="$HARM" helm arm --backend tmux --target firstmate:0 --workspace "$HARM" \
  >/dev/null 2>"$TMP_ROOT/dup.err"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "duplicate arm must be refused"
out=$(FM_HOME="$HARM" helm retire) || fail "retire must succeed"
assert_contains "$out" "retired: when-backup-helm-claude-runway" "retire reports the source"
assert_absent "$HARM/state/when/when-backup-helm-claude-runway.spec" "retire removes the spec"
out=$(FM_HOME="$HARM" helm retire) || fail "retire must be idempotent"
pass "arm registers the when-watch and retire cleans it up"

HFAIL="$TMP_ROOT/h-arm-fail"
new_home "$HFAIL"
successor "$HFAIL" 'cursor cursor-grok-4.6-high'
set_mode cursor-agent invoice
arm_refused "$HFAIL" "did not answer its probe" "unpaid Cursor successor"
assert_grep "unpaid invoice" "$TMP_ROOT/arm-refused.out" "arm reports the provider's reason"
set_mode cursor-agent answer
successor "$HFAIL" 'pi-signed'
arm_refused "$HFAIL" "did not answer its probe" "uninstalled successor"
assert_grep "status=unavailable" "$TMP_ROOT/arm-refused.out" "arm reports the missing executable"
pass "arm refuses a configured successor that does not answer"
