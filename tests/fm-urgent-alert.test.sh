#!/usr/bin/env bash
# Behavior tests for bin/fm-urgent-alert.sh and hold --urgent-alert.
# Drive both executables; never assert implementation-source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ALERT="$ROOT/bin/fm-urgent-alert.sh"
HOLD="$ROOT/bin/fm-captain-hold.sh"
TMP_ROOT=$(fm_test_tmproot fm-urgent-alert)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

packet_count() {  # <inbox>
  local inbox=$1 f count=0
  for f in "$inbox"/pkt-urgent-*.md; do
    [ -e "$f" ] || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

run_alert() {
  FM_HOME="$1" FM_CONFIG_OVERRIDE="$1/config" \
    FM_URGENT_ALERT_NOW="${FM_URGENT_ALERT_NOW:-2026-09-14T12:00:00}" \
    "$ALERT" --task-id sample-halt \
      --why "Work is stopped on a captain call." \
      --blocked "The sample halt task cannot proceed." \
      --ask "Pick the rollout window." \
      --action-hint "Answer the captain hold" \
      --link "https://example.invalid/halt"
}

make_hold_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

run_hold() {
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_URGENT_ALERT_NOW=2026-09-14T12:00:00 \
    "$HOLD" "$@"
}

test_helper_writes_packet_when_inbox_configured() {
  local home inbox out rc
  home="$TMP_ROOT/helper-write"
  inbox="$home/router/inbox/new"
  mkdir -p "$home/config" "$inbox"
  printf '%s\n' "$inbox" > "$home/config/packet-router-inbox"

  out=$(run_alert "$home")
  rc=$?
  expect_code 0 "$rc" "configured helper write"
  [ "$out" = "$inbox/pkt-urgent-sample-halt.md" ] \
    || fail "helper did not print the packet path, got: $out"
  [ "$(packet_count "$inbox")" = 1 ] || fail "configured helper wrote $(packet_count "$inbox") packets"
  assert_grep "type: continuum-packet" "$out" "packet missing type"
  assert_grep "schema: packet-router/v1" "$out" "packet missing schema"
  assert_grep "kind: urgent-alert" "$out" "packet missing kind"
  assert_grep "id: pkt-urgent-sample-halt" "$out" "packet missing id"
  assert_grep "from: firstmate" "$out" "packet missing from"
  assert_grep "role_target: spur" "$out" "packet missing role_target"
  assert_grep "priority: high" "$out" "packet missing priority"
  assert_grep "ask_of: spur" "$out" "packet missing ask_of"
  assert_grep 'created_at_pt: "2026-09-14T12:00:00"' "$out" "packet missing created_at_pt"
  assert_grep "ttl_hours: 6" "$out" "packet missing ttl_hours"
  assert_grep 'dedupe_key: "fm:sample-halt"' "$out" "packet missing quoted dedupe_key"
  assert_grep "source_class: H" "$out" "packet missing source_class"
  assert_grep "URGENT-ALERT v1" "$out" "packet missing body banner"
  assert_grep "dedupe_key: fm:sample-halt" "$out" "packet missing body dedupe_key"
  assert_grep "source: firstmate / sample-halt" "$out" "packet missing source"
  assert_grep "class: H" "$out" "packet missing class"
  assert_grep "why: Work is stopped on a captain call." "$out" "packet missing why"
  assert_grep "blocked: The sample halt task cannot proceed." "$out" "packet missing blocked"
  assert_grep "ask: Pick the rollout window." "$out" "packet missing ask"
  assert_grep "action_hint: Answer the captain hold" "$out" "packet missing action_hint"
  assert_grep "link: https://example.invalid/halt" "$out" "packet missing link"
  pass "helper writes a packet when an inbox is configured"
}

test_helper_noop_when_config_absent() {
  local home inbox out rc
  home="$TMP_ROOT/helper-absent"
  inbox="$home/router/inbox/new"
  mkdir -p "$home/config" "$inbox"

  out=$(run_alert "$home")
  rc=$?
  expect_code 0 "$rc" "absent-config helper"
  [ -z "$out" ] || fail "absent-config helper printed: $out"
  [ "$(packet_count "$inbox")" = 0 ] || fail "absent-config helper wrote a packet"
  pass "helper no-ops when config is absent"
}

test_helper_noop_when_config_empty() {
  local home inbox out rc
  home="$TMP_ROOT/helper-empty"
  inbox="$home/router/inbox/new"
  mkdir -p "$home/config" "$inbox"
  printf '\n# comment only\n\n' > "$home/config/packet-router-inbox"

  out=$(run_alert "$home")
  rc=$?
  expect_code 0 "$rc" "empty-config helper"
  [ -z "$out" ] || fail "empty-config helper printed: $out"
  [ "$(packet_count "$inbox")" = 0 ] || fail "empty-config helper wrote a packet"
  pass "helper no-ops when config is empty"
}

test_helper_noop_when_directory_missing() {
  local home out rc
  home="$TMP_ROOT/helper-missing-dir"
  mkdir -p "$home/config"
  printf '%s\n' "$home/router/inbox/new" > "$home/config/packet-router-inbox"

  out=$(run_alert "$home")
  rc=$?
  expect_code 0 "$rc" "missing-dir helper"
  [ -z "$out" ] || fail "missing-dir helper printed: $out"
  [ ! -e "$home/router/inbox/new" ] || fail "missing-dir helper created the inbox"
  pass "helper no-ops when the inbox directory is missing"
}

test_hold_without_flag_does_not_write() {
  local home inbox
  [ -n "$TASKS_AXI_BIN" ] || { pass "skip hold tests: tasks-axi not found"; return 0; }
  home=$(make_hold_home hold-no-flag)
  inbox="$home/router/inbox/new"
  mkdir -p "$inbox"
  printf '%s\n' "$inbox" > "$home/config/packet-router-inbox"

  run_hold "$home" hold sample-halt --title "Halt progress call" \
    --reason "captain must pick the window" --repo sample >/dev/null \
    || fail "hold without --urgent-alert failed"
  [ "$(packet_count "$inbox")" = 0 ] \
    || fail "hold without --urgent-alert wrote a packet"
  pass "hold without --urgent-alert does not write"
}

test_hold_urgent_alert_emits_once() {
  local home inbox
  [ -n "$TASKS_AXI_BIN" ] || { pass "skip hold tests: tasks-axi not found"; return 0; }
  home=$(make_hold_home hold-once)
  inbox="$home/router/inbox/new"
  mkdir -p "$inbox"
  printf '%s\n' "$inbox" > "$home/config/packet-router-inbox"

  run_hold "$home" hold sample-halt --title "Halt progress call" \
    --reason "captain must pick the window" --repo sample --urgent-alert >/dev/null \
    || fail "hold --urgent-alert failed"
  [ "$(packet_count "$inbox")" = 1 ] \
    || fail "hold --urgent-alert wrote $(packet_count "$inbox") packets"
  assert_grep "URGENT-ALERT v1" "$inbox/pkt-urgent-sample-halt.md" \
    "hold --urgent-alert packet missing body banner"
  assert_grep "dedupe_key: fm:sample-halt" "$inbox/pkt-urgent-sample-halt.md" \
    "hold --urgent-alert packet missing body dedupe_key"
  pass "hold --urgent-alert emits once"
}

test_hold_repeat_active_does_not_emit_again() {
  local home inbox
  [ -n "$TASKS_AXI_BIN" ] || { pass "skip hold tests: tasks-axi not found"; return 0; }
  home=$(make_hold_home hold-repeat)
  inbox="$home/router/inbox/new"
  mkdir -p "$inbox"
  printf '%s\n' "$inbox" > "$home/config/packet-router-inbox"

  run_hold "$home" hold sample-halt --title "Halt progress call" \
    --reason "captain must pick the window" --repo sample --urgent-alert >/dev/null \
    || fail "first hold --urgent-alert failed"
  run_hold "$home" hold sample-halt --reason "captain must pick the window" \
    --urgent-alert >/dev/null \
    || fail "repeat hold --urgent-alert failed"
  [ "$(packet_count "$inbox")" = 1 ] \
    || fail "repeat active hold wrote $(packet_count "$inbox") packets"
  pass "repeating an active hold does not emit again"
}

test_hold_until_does_not_emit() {
  local home inbox
  [ -n "$TASKS_AXI_BIN" ] || { pass "skip hold tests: tasks-axi not found"; return 0; }
  home=$(make_hold_home hold-until)
  inbox="$home/router/inbox/new"
  mkdir -p "$inbox"
  printf '%s\n' "$inbox" > "$home/config/packet-router-inbox"

  run_hold "$home" hold sample-halt --title "Halt progress call" \
    --reason "captain deferred revisit later" --repo sample \
    --until 2026-10-01 --urgent-alert >/dev/null \
    || fail "hold --until --urgent-alert failed"
  [ "$(packet_count "$inbox")" = 0 ] \
    || fail "hold --until wrote a packet"
  pass "--until does not emit"
}

test_hold_write_failure_does_not_fail_hold() {
  local home inbox out
  [ -n "$TASKS_AXI_BIN" ] || { pass "skip hold tests: tasks-axi not found"; return 0; }
  home=$(make_hold_home hold-unwritable)
  inbox="$home/router/inbox/new"
  mkdir -p "$inbox"
  printf '%s\n' "$inbox" > "$home/config/packet-router-inbox"
  chmod a-w "$inbox"

  out=$(run_hold "$home" hold sample-halt --title "Halt progress call" \
    --reason "captain must pick the window" --repo sample --urgent-alert) \
    || fail "hold failed when the inbox was not writable"
  [ "$out" = sample-halt ] || fail "hold did not print the task id, got: $out"
  chmod u+w "$inbox"
  [ "$(packet_count "$inbox")" = 0 ] || fail "unwritable inbox still received a packet"
  pass "packet write failure does not fail hold"
}

test_helper_writes_packet_when_inbox_configured
test_helper_noop_when_config_absent
test_helper_noop_when_config_empty
test_helper_noop_when_directory_missing
test_hold_without_flag_does_not_write
test_hold_urgent_alert_emits_once
test_hold_repeat_active_does_not_emit_again
test_hold_until_does_not_emit
test_hold_write_failure_does_not_fail_hold
