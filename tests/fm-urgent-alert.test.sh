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

assert_line() {  # <whole-line> <file> <msg>
  grep -qxF -- "$1" "$2" || fail "$3"
}

run_alert() {
  FM_HOME="$1" FM_CONFIG_OVERRIDE="$1/config" \
    FM_URGENT_ALERT_NOW="${FM_URGENT_ALERT_NOW:-2026-09-14T12:00:00}" \
    "$ALERT" --task-id sample-halt \
      --why "Work is stopped on a captain call." \
      --blocked "The sample halt task cannot proceed." \
      --ask "Pick the rollout window."
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
  assert_line "type: continuum-packet" "$out" "packet missing type"
  assert_line "schema: packet-router/v1" "$out" "packet missing schema"
  assert_line "kind: urgent-alert" "$out" "packet missing kind"
  assert_line "id: pkt-urgent-sample-halt" "$out" "packet missing id"
  assert_line "from: firstmate" "$out" "packet missing from"
  assert_line "role_target: spur" "$out" "packet missing role_target"
  assert_line "priority: high" "$out" "packet missing priority"
  assert_line "ask_of: spur" "$out" "packet missing ask_of"
  assert_line 'created_at_pt: "2026-09-14T12:00:00"' "$out" "packet missing created_at_pt"
  assert_line "ttl_hours: 6" "$out" "packet missing ttl_hours"
  assert_line 'dedupe_key: "fm:sample-halt"' "$out" "packet missing quoted dedupe_key"
  assert_line "source_class: H" "$out" "packet missing source_class"
  assert_line "URGENT-ALERT v1" "$out" "packet missing body banner"
  assert_line "dedupe_key: fm:sample-halt" "$out" "packet missing body dedupe_key"
  assert_line "source: firstmate / sample-halt" "$out" "packet missing source"
  assert_line "class: H" "$out" "packet missing body class"
  assert_line "why: Work is stopped on a captain call." "$out" "packet missing why"
  assert_line "blocked: The sample halt task cannot proceed." "$out" "packet missing blocked"
  assert_line "ask: Pick the rollout window." "$out" "packet missing ask"
  assert_line "action_hint: Answer the captain hold" "$out" "packet missing action_hint"
  assert_line "link:" "$out" "packet missing link"
  [ -z "$(tail -c 1 "$out")" ] || fail "packet does not end with a newline"
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

test_helper_noop_when_path_relative() {
  local home out rc
  home="$TMP_ROOT/helper-relative"
  mkdir -p "$home/config" "$home/router/inbox/new"
  printf '%s\n' "router/inbox/new" > "$home/config/packet-router-inbox"

  out=$(run_alert "$home" 2>"$home/alert.err")
  rc=$?
  expect_code 0 "$rc" "relative-path helper"
  [ -z "$out" ] || fail "relative-path helper printed: $out"
  [ ! -s "$home/alert.err" ] || fail "relative-path helper wrote stderr: $(cat "$home/alert.err")"
  [ "$(packet_count "$home/router/inbox/new")" = 0 ] || fail "relative-path helper wrote a packet"
  pass "helper treats a relative inbox path as not configured"
}

test_helper_reports_when_directory_missing() {
  local home out rc
  home="$TMP_ROOT/helper-missing-dir"
  mkdir -p "$home/config"
  printf '%s\n' "$home/router/inbox/new" > "$home/config/packet-router-inbox"

  out=$(run_alert "$home" 2>"$home/alert.err")
  rc=$?
  expect_code 0 "$rc" "missing-dir helper"
  [ -z "$out" ] || fail "missing-dir helper printed: $out"
  [ ! -e "$home/router/inbox/new" ] || fail "missing-dir helper created the inbox"
  [ "$(grep -c '^actionable: URGENT-ALERT for task sample-halt ' "$home/alert.err")" = 1 ] \
    || fail "missing-dir helper did not print one actionable line: $(cat "$home/alert.err")"
  [ "$(wc -l < "$home/alert.err")" -eq 1 ] \
    || fail "missing-dir helper printed extra stderr: $(cat "$home/alert.err")"
  pass "helper reports one actionable line when the configured inbox is missing"
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
  assert_line "URGENT-ALERT v1" "$inbox/pkt-urgent-sample-halt.md" \
    "hold --urgent-alert packet missing body banner"
  assert_line "dedupe_key: fm:sample-halt" "$inbox/pkt-urgent-sample-halt.md" \
    "hold --urgent-alert packet missing body dedupe_key"
  pass "hold --urgent-alert emits once"
}

test_hold_urgent_alert_on_routine_active_hold_emits() {
  local home inbox packet
  [ -n "$TASKS_AXI_BIN" ] || { pass "skip hold tests: tasks-axi not found"; return 0; }
  home=$(make_hold_home hold-escalate)
  inbox="$home/router/inbox/new"
  packet="$inbox/pkt-urgent-sample-halt.md"
  mkdir -p "$inbox"
  printf '%s\n' "$inbox" > "$home/config/packet-router-inbox"

  run_hold "$home" hold sample-halt --title "Halt progress call" \
    --reason "captain must pick the window" --repo sample >/dev/null \
    || fail "routine hold failed"
  [ "$(packet_count "$inbox")" = 0 ] || fail "routine hold wrote a packet"
  run_hold "$home" hold sample-halt --reason "work stopped until the captain picks" \
    --urgent-alert >/dev/null \
    || fail "escalating hold --urgent-alert failed"
  [ "$(packet_count "$inbox")" = 1 ] \
    || fail "escalating an active hold wrote $(packet_count "$inbox") packets"
  assert_line "why: work stopped until the captain picks" "$packet" \
    "escalated packet missing why"
  assert_line "blocked: Halt progress call" "$packet" \
    "escalated packet did not name the shown task title as blocked"
  assert_line "ask: work stopped until the captain picks" "$packet" \
    "escalated packet missing ask"

  rm -f -- "$packet"
  run_hold "$home" hold sample-halt --reason "work stopped until the captain picks" \
    --urgent-alert >/dev/null \
    || fail "retried hold --urgent-alert failed"
  [ "$(packet_count "$inbox")" = 1 ] \
    || fail "retried active hold wrote $(packet_count "$inbox") packets"
  assert_line "dedupe_key: fm:sample-halt" "$packet" \
    "retried packet did not keep the stable dedupe_key"
  pass "hold --urgent-alert emits on an already-active hold and on retry"
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
    --reason "captain must pick the window" --repo sample --urgent-alert 2>"$home/hold.err") \
    || fail "hold failed when the inbox was not writable"
  [ "$out" = sample-halt ] || fail "hold did not print the task id, got: $out"
  chmod u+w "$inbox"
  [ "$(packet_count "$inbox")" = 0 ] || fail "unwritable inbox still received a packet"
  [ "$(grep -c '^actionable: URGENT-ALERT for task sample-halt ' "$home/hold.err")" = 1 ] \
    || fail "unwritable inbox did not report one actionable line: $(cat "$home/hold.err")"
  pass "packet write failure reports one actionable line and does not fail hold"
}

test_helper_writes_packet_when_inbox_configured
test_helper_noop_when_config_absent
test_helper_noop_when_config_empty
test_helper_noop_when_path_relative
test_helper_reports_when_directory_missing
test_hold_without_flag_does_not_write
test_hold_urgent_alert_emits_once
test_hold_urgent_alert_on_routine_active_hold_emits
test_hold_until_does_not_emit
test_hold_write_failure_does_not_fail_hold
