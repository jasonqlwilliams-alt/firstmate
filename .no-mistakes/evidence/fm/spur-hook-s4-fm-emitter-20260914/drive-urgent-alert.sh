#!/usr/bin/env bash
# Live driver for slice 4 (hold --urgent-alert -> Packet Router URGENT-ALERT).
# Drives the real bin/fm-captain-hold.sh with the real tasks-axi in throwaway
# homes. Only tmux/treehouse/no-mistakes/gh are shimmed so nothing touches the
# operator's live sessions. Never writes to the real Packet Router inbox.
set -u

WT=${WT:?worktree path}
BASE_TREE=${BASE_TREE:?base commit tree path}
WIN_TMP=${WIN_TMP:?windows drvfs temp dir}
EV=${EV:?evidence dir}
export YAML_PKG=${YAML_PKG:?yaml package dir}
T=$(mktemp -d /tmp/fm-ua-live.XXXXXX)
NOW_UTC=2026-09-14T20:00:00Z

say() { printf '%s\n' "$*"; }
section() { printf '\n## %s\n\n' "$*"; }

make_home() {  # <name>
  local home="$T/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/fakebin"
  cp "$WT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  for t in tmux treehouse no-mistakes gh gh-axi; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$home/fakebin/$t"; chmod +x "$home/fakebin/$t"
  done
  printf '%s\n' "$home"
}

# run <tree> <home> <label> args... ; prints a transcript block
run() {
  local tree=$1 home=$2 label=$3 rc
  shift 3
  say '```console'
  say "\$ [$label] bin/fm-captain-hold.sh $*"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CAPTAIN_HOLD_NOW="$NOW_UTC" FM_URGENT_ALERT_NOW=2026-09-14T13:00:00 \
    "$tree/bin/fm-captain-hold.sh" "$@" >"$home/last.out" 2>"$home/last.err"
  rc=$?
  say "exit=$rc"
  say "stdout:"; sed 's/^/  /' "$home/last.out"
  say "stderr:"; sed 's/^/  /' "$home/last.err"
  say '```'
  LAST_RC=$rc
}

show_task() {  # <home> <id>
  say '```console'
  say "\$ tasks-axi show $2"
  (cd "$home" && tasks-axi show "$2" --file "$1/data/backlog.md" 2>&1) | grep -E '^(  )?(id|title|state|held|hold_kind|hold_reason|until|hold_until):' | sed 's/^/  /'
  say '```'
}

list_inbox() {  # <inbox>
  say '```console'
  say "\$ ls -A $1"
  ls -A "$1" 2>&1 | sed 's/^/  /'
  say '```'
}

show_packet() {  # <file>
  say '```text'
  cat "$1"
  say '```'
}

check() {  # <desc> <cmd...>
  if "${@:2}"; then say "- PASS: $1"; else say "- FAIL: $1"; FAILS=$((FAILS+1)); fi
}

count_packets() { find "$1" -name 'pkt-urgent-*' 2>/dev/null | wc -l | tr -d ' '; }
FAILS=0

say "# Live transcript: hold --urgent-alert"
say ""
say "- worktree: $WT (target a373d16)"
say "- base tree: $BASE_TREE (base 5a4944e)"
say "- tasks-axi: $(tasks-axi --version)"
say "- inbox filesystem for S1/S5: DrvFs (Windows C:) under $WIN_TMP, same filesystem type as the live C:\\Continuum\\_PacketRouter\\inbox\\new"

# ---------------------------------------------------------------- S1
section "S1 - configured home: hold --urgent-alert on a live halt writes one URGENT-ALERT packet"
home=$(make_home s1); inbox=$(mktemp -d "$WIN_TMP/fm-ua-inbox.XXXXXX")/inbox/new; mkdir -p "$inbox"
printf '# Packet Router inbox\n%s\n' "$inbox" > "$home/config/packet-router-inbox"
say "config/packet-router-inbox:"; say '```text'; cat "$home/config/packet-router-inbox"; say '```'
run "$WT" "$home" target hold rollout-window --title "Ship the billing rollout" \
  --reason "Work is stopped until the captain picks the rollout window" --repo sample --urgent-alert
check "hold exits 0" [ "$LAST_RC" = 0 ]
check "stdout is only the task id" [ "$(cat "$home/last.out")" = rollout-window ]
check "stderr is empty" [ ! -s "$home/last.err" ]
show_task "$home" rollout-window
list_inbox "$inbox"
check "exactly one packet in inbox/new" [ "$(count_packets "$inbox")" = 1 ]
check "no leftover temp file in inbox/new" [ "$(ls -A "$inbox" | wc -l | tr -d ' ')" = 1 ]
pkt="$inbox/pkt-urgent-rollout-window.md"
show_packet "$pkt"
cp "$pkt" "$EV/packet-s1-rollout-window.md"
say "Semantic parse of the packet against the Packet Router HOWTO URGENT-ALERT v1 contract:"
say '```console'
node "$EV/parse-packet.cjs" "$pkt" '{"front_matter":{"type":"continuum-packet","schema":"packet-router/v1","kind":"urgent-alert","id":"pkt-urgent-rollout-window","from":"firstmate","role_target":"spur","priority":"high","ask_of":"spur","created_at_pt":"2026-09-14T13:00:00","ttl_hours":6,"dedupe_key":"fm:rollout-window","source_class":"H"},"body":{"dedupe_key":"fm:rollout-window","source":"firstmate / rollout-window","class":"H","why":"Work is stopped until the captain picks the rollout window","blocked":"Ship the billing rollout","ask":"Work is stopped until the captain picks the rollout window","action_hint":"Answer the captain hold","link":""}}' 2>&1
prc=$?
say '```'
check "S1 packet parses and matches the contract" [ "$prc" = 0 ]
S1_INBOX_ROOT=${inbox%/inbox/new}

# ---------------------------------------------------------------- S1b
section "S1b - preferred path: hold an existing work item without --title; blocked names that item"
home=$(make_home s1b); inbox="$home/router/inbox/new"; mkdir -p "$inbox"
printf '%s\n' "$inbox" > "$home/config/packet-router-inbox"
say '```console'
say "\$ tasks-axi add deploy-gate \"Deploy the payments service\" --repo sample"
(cd "$home" && tasks-axi add deploy-gate "Deploy the payments service" --repo sample --file "$home/data/backlog.md" >/dev/null 2>&1; echo "exit=$?")
say '```'
run "$WT" "$home" target hold deploy-gate --reason "Deploy halted: only the captain holds the prod credential" --urgent-alert
check "hold exits 0" [ "$LAST_RC" = 0 ]
show_packet "$inbox/pkt-urgent-deploy-gate.md"
check "blocked is the task title, not the reason" grep -qxF "blocked: Deploy the payments service" "$inbox/pkt-urgent-deploy-gate.md"

# ---------------------------------------------------------------- S2
section "S2 - home with NO Packet Router inbox: hold --urgent-alert is unaffected (same output and backlog as base commit)"
home_t=$(make_home s2-target-flag); home_n=$(make_home s2-target-noflag); home_b=$(make_home s2-base-noflag)
run "$WT" "$home_t" "target, flag" hold sample-halt --title "Halt progress call" --reason "captain must pick the window" --repo sample --urgent-alert
rc_t=$LAST_RC; cp "$home_t/last.out" "$T/s2t.out"; cp "$home_t/last.err" "$T/s2t.err"
run "$WT" "$home_n" "target, no flag" hold sample-halt --title "Halt progress call" --reason "captain must pick the window" --repo sample
rc_n=$LAST_RC
run "$BASE_TREE" "$home_b" "BASE 5a4944e, no flag" hold sample-halt --title "Halt progress call" --reason "captain must pick the window" --repo sample
rc_b=$LAST_RC
check "all three exit 0" [ "$rc_t$rc_n$rc_b" = 000 ]
check "stdout identical to base" cmp -s "$T/s2t.out" "$home_b/last.out"
check "stderr identical to base (empty)" cmp -s "$T/s2t.err" "$home_b/last.err"
check "backlog.md identical: target+flag vs base" cmp -s "$home_t/data/backlog.md" "$home_b/data/backlog.md"
check "backlog.md identical: target no flag vs base" cmp -s "$home_n/data/backlog.md" "$home_b/data/backlog.md"
check "no pkt-urgent file anywhere under the three S2 homes" [ "$(( $(count_packets "$home_t") + $(count_packets "$home_n") + $(count_packets "$home_b") ))" = 0 ]
say "backlog.md after target hold --urgent-alert (unconfigured home):"
say '```text'; cat "$home_t/data/backlog.md"; say '```'

# ---------------------------------------------------------------- S3
section "S3 - routine hold without the flag, and resolving the call, never write a packet"
home=$(make_home s3); inbox="$home/router/inbox/new"; mkdir -p "$inbox"
printf '%s\n' "$inbox" > "$home/config/packet-router-inbox"
run "$WT" "$home" target hold merge-ready --title "PR 42 is merge-ready" --reason "Merge-ready: captain may merge when convenient" --repo sample
check "routine hold exits 0" [ "$LAST_RC" = 0 ]
printf 'Merge it.\n' > "$home/decision.txt"
run "$WT" "$home" target answer merge-ready --decision-file "$home/decision.txt" --release
check "answer --release exits 0" [ "$LAST_RC" = 0 ]
list_inbox "$inbox"
check "zero packets after routine hold + answer" [ "$(count_packets "$inbox")" = 0 ]

# ---------------------------------------------------------------- S4
section "S4 - --until deferral with --urgent-alert does not write a packet"
home=$(make_home s4); inbox="$home/router/inbox/new"; mkdir -p "$inbox"
printf '%s\n' "$inbox" > "$home/config/packet-router-inbox"
run "$WT" "$home" target hold revisit-later --title "Revisit vendor choice" --reason "Captain deferred: revisit next month" --repo sample --until 2026-10-01 --urgent-alert
check "deferral hold exits 0" [ "$LAST_RC" = 0 ]
show_task "$home" revisit-later
list_inbox "$inbox"
check "zero packets for --until" [ "$(count_packets "$inbox")" = 0 ]

# ---------------------------------------------------------------- S5
section "S5 - escalate an already-active routine hold, then retry: emits each time, same dedupe_key, one file"
home=$(make_home s5); inbox=$(mktemp -d "$WIN_TMP/fm-ua-inbox.XXXXXX")/inbox/new; mkdir -p "$inbox"
printf '%s\n' "$inbox" > "$home/config/packet-router-inbox"
run "$WT" "$home" target hold schema-call --title "Pick the schema migration path" --reason "Captain to choose A or B" --repo sample
check "routine hold wrote nothing" [ "$(count_packets "$inbox")" = 0 ]
run "$WT" "$home" target hold schema-call --reason "Work stopped: migration cannot start until the captain picks A or B" --urgent-alert
check "escalation exits 0" [ "$LAST_RC" = 0 ]
check "escalation wrote one packet" [ "$(count_packets "$inbox")" = 1 ]
show_packet "$inbox/pkt-urgent-schema-call.md"
say "Simulate the Packet Router watcher claiming the first packet (move it out of inbox/new), then retry the same hold:"
mkdir -p "${inbox%/new}/claimed"; mv "$inbox/pkt-urgent-schema-call.md" "${inbox%/new}/claimed/"
run "$WT" "$home" target hold schema-call --reason "Work stopped: migration cannot start until the captain picks A or B" --urgent-alert
check "retry exits 0" [ "$LAST_RC" = 0 ]
check "retry wrote one new packet" [ "$(count_packets "$inbox")" = 1 ]
check "retry keeps dedupe_key fm:schema-call" grep -qxF 'dedupe_key: "fm:schema-call"' "$inbox/pkt-urgent-schema-call.md"
say "Retry again without the watcher claiming (file still in inbox/new):"
run "$WT" "$home" target hold schema-call --reason "Work stopped: migration cannot start until the captain picks A or B" --urgent-alert
check "second retry exits 0" [ "$LAST_RC" = 0 ]
list_inbox "$inbox"
check "still exactly one file in inbox/new (atomic replace, no temp leftovers)" [ "$(ls -A "$inbox" | wc -l | tr -d ' ')" = 1 ]
S5_INBOX_ROOT=${inbox%/inbox/new}

# ---------------------------------------------------------------- S6
section "S6 - adversarial: a refused hold with --urgent-alert never pages"
home=$(make_home s6); inbox="$home/router/inbox/new"; mkdir -p "$inbox"
printf '%s\n' "$inbox" > "$home/config/packet-router-inbox"
run "$WT" "$home" target hold paren-call --title "Paren call" --reason "Pick (A) or (B)" --repo sample --urgent-alert
check "parenthesised reason refused (nonzero)" [ "$LAST_RC" != 0 ]
run "$WT" "$home" target hold no-title-call --reason "Work stopped" --urgent-alert
check "new task without --title refused (nonzero)" [ "$LAST_RC" != 0 ]
run "$WT" "$home" target hold closed-call --title "Closed call" --reason "Captain to pick" --repo sample
printf 'Done.\n' > "$home/decision.txt"
run "$WT" "$home" target answer closed-call --decision-file "$home/decision.txt"
run "$WT" "$home" target hold closed-call --reason "Work stopped again" --urgent-alert
check "hold on a closed task refused (nonzero)" [ "$LAST_RC" != 0 ]
run "$WT" "$home" target hold 'bad/id' --title "x" --reason "Work stopped" --repo sample --urgent-alert
check "unsafe task id refused (nonzero)" [ "$LAST_RC" != 0 ]
list_inbox "$inbox"
check "zero packets after every refused hold" [ "$(count_packets "$inbox")" = 0 ]

# ---------------------------------------------------------------- S7
section "S7 - configured but broken inbox: hold still succeeds and prints one actionable: line"
for mode in missing-dir is-a-file read-only; do
  home=$(make_home "s7-$mode"); inbox="$home/router/inbox/new"
  case "$mode" in
    missing-dir) : ;;
    is-a-file) mkdir -p "${inbox%/new}"; printf 'x\n' > "$inbox" ;;
    read-only) mkdir -p "$inbox"; chmod a-w "$inbox" ;;
  esac
  printf '%s\n' "$inbox" > "$home/config/packet-router-inbox"
  say "Inbox condition: $mode"
  run "$WT" "$home" target hold "halt-$mode" --title "Halt $mode" --reason "Work stopped on a captain call" --repo sample --urgent-alert
  check "$mode: hold exits 0" [ "$LAST_RC" = 0 ]
  check "$mode: stdout is only the task id" [ "$(cat "$home/last.out")" = "halt-$mode" ]
  check "$mode: stderr is exactly one actionable: line" [ "$(wc -l < "$home/last.err" | tr -d ' ')" = 1 ]
  check "$mode: that line starts with actionable: URGENT-ALERT" grep -q '^actionable: URGENT-ALERT for task halt-' "$home/last.err"
  check "$mode: task is still captain-held" bash -c "cd '$home' && tasks-axi show halt-$mode --file '$home/data/backlog.md' | grep -q 'hold_kind: captain'"
  [ "$mode" = read-only ] && chmod u+w "$inbox"
  check "$mode: no packet written" [ "$(count_packets "$home/router")" = 0 ]
done

# ---------------------------------------------------------------- S8
section "S8 - adversarial config values that are not an absolute path are a silent no-op"
i=0
for value in 'router/inbox/new' '~/router/inbox/new' 'C:\Continuum\_PacketRouter\inbox\new' '   # only a comment'; do
  i=$((i+1)); home=$(make_home "s8-$i"); mkdir -p "$home/router/inbox/new"
  printf '%s\n' "$value" > "$home/config/packet-router-inbox"
  say "config/packet-router-inbox = \`$value\`"
  run "$WT" "$home" target hold "halt-$i" --title "Halt $i" --reason "Work stopped on a captain call" --repo sample --urgent-alert
  check "value $i: exit 0, stdout id, empty stderr" [ "$LAST_RC:$(cat "$home/last.out"):$(cat "$home/last.err")" = "0:halt-$i:" ]
  check "value $i: no packet anywhere" [ "$(count_packets "$home")" = 0 ]
done

# ---------------------------------------------------------------- S9
section "S9 - adversarial text: YAML-hostile reason and title do not break the packet envelope"
home=$(make_home s9); inbox="$home/router/inbox/new"; mkdir -p "$inbox"
printf '%s\n' "$inbox" > "$home/config/packet-router-inbox"
TITLE='Fix "prod" at C:\data\new: tabs #hash --- Café ✓'
REASON='Halted: key: value "quoted" \back\slash #not-a-comment --- & *star'
run "$WT" "$home" target hold hostile.text_1 --title "$TITLE" --reason "$REASON" --repo sample --urgent-alert
check "hold exits 0" [ "$LAST_RC" = 0 ]
show_packet "$inbox/pkt-urgent-hostile.text_1.md"
want=$(TITLE="$TITLE" REASON="$REASON" node -e 'const e=process.env; console.log(JSON.stringify({front_matter:{kind:"urgent-alert",role_target:"spur",id:"pkt-urgent-hostile.text_1",dedupe_key:"fm:hostile.text_1",source_class:"H",ttl_hours:6},body:{dedupe_key:"fm:hostile.text_1",source:"firstmate / hostile.text_1",class:"H",why:e.REASON,blocked:e.TITLE,ask:e.REASON,action_hint:"Answer the captain hold",link:""}}))')
say '```console'
node "$EV/parse-packet.cjs" "$inbox/pkt-urgent-hostile.text_1.md" "$want" 2>&1
prc=$?
say '```'
check "hostile text carried verbatim and envelope still parses" [ "$prc" = 0 ]

section "Result"
say "FAILS=$FAILS"
rm -rf "$S1_INBOX_ROOT" "$S5_INBOX_ROOT"
chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"
