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

write_cursor() {  # <list-models body>
  local body=$1
  cat > "$FAKEBIN/cursor-agent" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "--help" ]; then
  printf 'Start the Cursor Agent\\n'
  exit 0
fi
if [ "\${1:-}" = "--list-models" ]; then
  printf '%s\\n' '$body'
  exit 0
fi
printf 'unexpected argv\\n' >&2
exit 1
SH
  chmod +x "$FAKEBIN/cursor-agent"
}

new_home() {
  mkdir -p "$1/state" "$1/.cursor"
  printf '{}\n' > "$1/.cursor/hooks.json"
  fm_test_track_procevent_home "$1"
}

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

write_cursor 'cursor-grok-4.6-high - Grok 4.6 High'

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
out=$(helm probe) || fail "probe must succeed when the catalog names cursor-grok-4.6-high"
assert_contains "$out" "status=ok" "probe ok line"
assert_contains "$out" "model=cursor-grok-4.6-high" "probe names the helm model"
write_cursor 'composer-2 - Composer'
set +e
helm probe >/dev/null 2>"$TMP_ROOT/probe.err"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "probe must fail closed when cursor-grok-4.6-high is absent"
write_cursor 'cursor-grok-4.6-high - Grok 4.6 High'
pass "probe fails closed without cursor-grok-4.6-high"

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
  helm handover --backend tmux --target firstmate:0 --workspace "$H" \
  >"$TMP_ROOT/midturn.out" 2>"$TMP_ROOT/midturn.err"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "a mid-turn Claude must fail closed"
assert_grep "mid-turn" "$TMP_ROOT/midturn.err" "mid-turn refusal names the wait"
[ ! -s "$SEND_LOG" ] || fail "mid-turn refusal must not send /stow or /exit"
[ ! -s "$LAUNCH_LOG" ] || fail "mid-turn refusal must not launch Cursor"
assert_present "$H/state/.lock" "mid-turn refusal must leave the session lock file"
assert_equals "$(cat "$H/state/.lock")" "999999" "mid-turn refusal must not rewrite the lock"
pass "mid-turn Claude is waited out and never interrupted"

write_cursor 'composer-2 - Composer'
: >"$SEND_LOG"
set +e
FM_HOME="$H" FM_BACKUP_HELM_DRIVER="$FAKEBIN/busy-driver" \
  helm handover --backend tmux --target firstmate:0 --workspace "$H" \
  >/dev/null 2>"$TMP_ROOT/probe-fail.err"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "handover must fail closed when the Cursor Grok probe fails"
[ ! -s "$SEND_LOG" ] || fail "a failed probe must not send into the Claude pane"
write_cursor 'cursor-grok-4.6-high - Grok 4.6 High'
pass "failed Cursor Grok probe refuses the handover before any pane send"

set +e
FM_HOME="$H" helm handover --backend zellij --target zellij:0 --workspace "$H" \
  >/dev/null 2>"$TMP_ROOT/zellij.err"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "zellij handover must be refused"
assert_grep "tmux or herdr" "$TMP_ROOT/zellij.err" "unsupported backend is named"
pass "unsupported backends are refused"

set +e
unset FM_HOME
helm handover --backend tmux --target firstmate:0 --workspace "$H" \
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
    helm handover --backend tmux --target firstmate:0 --workspace "$H"
) || fail "idle handover must succeed"
assert_contains "$out" "/stow" "handover sends /stow"
assert_contains "$out" "/exit" "handover sends /exit"
assert_contains "$out" "launch-command:" "handover prints the launch command"
assert_contains "$out" "--trust" "launch includes --trust"
assert_contains "$out" "--yolo" "launch includes --yolo"
assert_contains "$out" "--workspace" "launch includes --workspace"
assert_contains "$out" "cursor-grok-4.6-high" "launch pins cursor-grok-4.6-high"
assert_contains "$out" "env -u CLAUDECODE" "launch clears foreign Claude markers"
assert_not_contains "$out" " -p " "launch must not use headless -p"
send=$(cat "$SEND_LOG")
assert_contains "$send" "/stow" "driver recorded /stow"
assert_contains "$send" "/exit" "driver recorded /exit"
launch=$(cat "$LAUNCH_LOG")
assert_contains "$launch" "--trust" "driver launch includes --trust"
assert_contains "$launch" "--yolo" "driver launch includes --yolo"
assert_contains "$launch" "cursor-grok-4.6-high" "driver launch pins the helm model"
assert_not_contains "$launch" " -p " "driver launch must not be headless"
assert_present "$H/state/.lock" "successful handover must not delete the lock file"
pass "idle handover stows, exits, and launches Cursor Grok 4.6 high"

printf 'released\n' > "$LOCK_STATE"
: >"$SEND_LOG"
: >"$LAUNCH_LOG"
out=$(
  FM_HOME="$H" FM_BACKUP_HELM_DRIVER="$FAKEBIN/idle-driver" \
    helm handover --backend tmux --target firstmate:0 --workspace "$H"
) || fail "handover with an already-released lock must still launch"
assert_contains "$out" "skipping Claude /stow and /exit" "released lock skips Claude slash commands"
assert_not_contains "$(cat "$SEND_LOG")" "/stow" "released lock must not send /stow"
assert_not_contains "$(cat "$SEND_LOG")" "/exit" "released lock must not send /exit"
assert_contains "$(cat "$LAUNCH_LOG")" "cursor-grok-4.6-high" "released lock still launches Cursor Grok"
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
  helm handover --backend tmux --target firstmate:0 --workspace "$H" \
  >/dev/null 2>"$TMP_ROOT/unknown-lock.err"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "an unreadable lock status must fail closed"
assert_grep "neither held" "$TMP_ROOT/unknown-lock.err" "unreadable lock is refused"
[ ! -s "$SEND_LOG" ] || fail "unreadable lock must not send /stow or /exit"
[ ! -s "$LAUNCH_LOG" ] || fail "unreadable lock must not launch Cursor"
pass "unreadable lock status refuses the handover"

# --- arm / retire -----------------------------------------------------------
HARM="$TMP_ROOT/h-arm"
new_home "$HARM"
out=$(
  FM_HOME="$HARM" helm arm --backend tmux --target firstmate:0 --workspace "$HARM" \
    --interval 60 --stable 2 --action-timeout 3600
) || fail "arm must succeed against a probed Cursor catalog"
assert_contains "$out" "armed: when-backup-helm-claude-runway" "arm reports the source id"
assert_contains "$out" "runway-seconds: 43200" "arm records the 12-hour trigger"
assert_contains "$out" "model: cursor-grok-4.6-high" "arm records the helm model"
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

write_cursor 'composer-2 - Composer'
HFAIL="$TMP_ROOT/h-arm-fail"
new_home "$HFAIL"
set +e
FM_HOME="$HFAIL" helm arm --backend tmux --target firstmate:0 --workspace "$HFAIL" \
  >/dev/null 2>"$TMP_ROOT/arm-probe.err"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "arm must fail closed when the Cursor Grok probe fails"
assert_absent "$HFAIL/state/when/when-backup-helm-claude-runway.spec" "a failed arm must not leave a watch"
pass "arm fails closed when Cursor Grok is missing from the catalog"
