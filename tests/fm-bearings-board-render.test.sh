#!/usr/bin/env bash
# Behavior tests for the shipped bearings board renderer
# (.agents/skills/bearings/assets/board-template.html), exercised through a real
# `fm-bearings-board.sh build` and then executed under the minimal DOM shim in
# tests/assets/board-render-harness.mjs. The assertions are on what the page
# renders - row badges, the explanation a badge opens, the stat strip, the
# empty state - never on the template's source text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-bearings-board.sh"
HARNESS="$ROOT/tests/assets/board-render-harness.mjs"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board-render)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  # A build starts a listener for the board it publishes. Registered with
  # tests/lib.sh, not with a shell array: make_home runs inside a command
  # substitution, where an array append never reaches the caller.
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  mkdir -p "$home/state" "$home/data"
  fakebin=$(fm_fakebin "$home")
  # The build proves the board session is live before it arms anything, so the
  # stub reports the opened shape the real lavish-axi emits. This suite is about
  # what the template renders, not about session liveness, which
  # tests/fm-bearings-board.test.sh owns.
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  --version) printf '0.1.61\n' ;;
  '')
    printf 'sessions[1]{file,status,url,pending_prompts}:\n'
    [ ! -s "$FM_HOME/lavish-open" ] \
      || printf '  %s,open,"http://127.0.0.1/session/render",0\n' "$(cat "$FM_HOME/lavish-open")"
    ;;
  poll)
    # Bounded, so a listener that escapes its test stops on its own.
    while [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 1; done
    exit 75
    ;;
  *)
    real=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
    printf '%s\n' "$real" > "$FM_HOME/lavish-open"
    printf 'session:\n  status: opened\n'
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/lavish-axi"
  printf '%s\n' "$home"
}

# Build the board from <underway-json> plus <charted-json> and return what the
# renderer produced.
render_board() {  # <home> <underway-json> <charted-json> [charted_more] [charted_warning_more] [landed-json]
  local home=$1 underway=$2 charted=$3 more=${4:-0} warning_more=${5:-0} landed=${6:-'[]'} data="$1/payload.json"
  jq -n --argjson underway "$underway" --argjson charted "$charted" --argjson landed "$landed" \
    --argjson more "$more" --argjson warning_more "$warning_more" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:[], underway:$underway, landed:$landed,
    charted:$charted, charted_more:$more, charted_warning_more:$warning_more}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  node "$HARNESS" "$home/.lavish/bearings-board.html" \
    || fail "the built board could not be rendered"
}

# Build the board from <charted-json> alone and return what the renderer produced.
render() {  # <home> <charted-json> [charted_more] [charted_warning_more]
  render_board "$1" '[]' "$2" "${3:-0}" "${4:-0}"
}

charted_next_count() {  # <render-json>
  printf '%s' "$1" | jq -r '.stats[] | select(.label == "charted next") | .n'
}

test_a_warning_row_reads_as_a_repair_not_as_queued_work() {
  local home out
  home=$(make_home warning-badge)
  out=$(render "$home" '[
    {"id":"real-queued","repo":"sample","title":"Queued work","reason":"blocked on the cutover","dispatchable":false},
    {"id":"main-inventory","repo":"sample","title":"Main inventory integrity","reason":"main inventory","dispatchable":false,"kind":"warning"}
  ]')
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the board rendered its fail-closed error instead of the fleet: $out"
  printf '%s' "$out" | jq -e '
    (.charted | length) == 2
      and (.charted[0] | .title == "Queued work"
        and [.badges[] | .text] == ["waiting"] and .pickable == false)
      and (.charted[1] | .title == "Main inventory integrity"
        and [.badges[] | .text] == ["needs repair"]
        and [.badges[] | .tone] == ["danger"]
        and .pickable == false
        and (.detail | test("not work, and there is nothing here to start"))
        and (.detail | test("ready|start it|dispatch"; "i") | not))
  ' >/dev/null || fail "a warning row did not read differently from queued work: $out"
  pass "a warning row badges needs repair and explains itself as a notice, not startable work"
}

test_warnings_are_excluded_from_the_charted_next_count() {
  local home out
  home=$(make_home warning-count)
  out=$(render "$home" '[
    {"id":"queued-one","repo":"sample","title":"One","reason":"gated","dispatchable":true},
    {"id":"warn-one","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"},
    {"id":"warn-two","repo":"sample","title":"Inventory mismatch","reason":"main inventory","dispatchable":false,"kind":"warning"}
  ]')
  [ "$(charted_next_count "$out")" = 1 ] \
    || fail "the charted next tally counted alarms as queued work: $out"
  printf '%s' "$out" | jq -e '(.charted | length) == 3' >/dev/null \
    || fail "excluding warnings from the count also dropped their rows: $out"
  pass "the charted next count counts queued work only, and still renders warnings"
}

test_a_board_of_only_warnings_still_reports_nothing_queued() {
  local home out
  home=$(make_home warning-only)
  out=$(render "$home" '[
    {"id":"warn-only","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"}
  ]')
  [ "$(charted_next_count "$out")" = 0 ] \
    || fail "a warning-only board claimed queued work: $out"
  printf '%s' "$out" | jq -e '
    (.empty | length) == 1 and (.empty[0] | test("Nothing is queued"))
      and (.charted | length) == 1
  ' >/dev/null || fail "a warning-only board hid the warning or the empty state: $out"
  pass "a warning-only board reports nothing queued and still shows the warning"
}

test_omitted_warnings_never_count_as_more_queued() {
  local home out
  home=$(make_home warning-more)
  out=$(render "$home" '[
    {"id":"warn-visible","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"}
  ]' 0 1)
  [ "$(charted_next_count "$out")" = 0 ] \
    || fail "an omitted warning was counted as queued work: $out"
  printf '%s' "$out" | jq -e '
    (.empty | length) == 1 and (.empty[0] | test("Nothing is queued"))
      and (.more == ["+1 more repair warning was left out when this board was built"])
      and ([.more[] | select(test("more queued"))] | length) == 0
  ' >/dev/null || fail "an omitted warning was labeled as more queued: $out"
  pass "omitted warnings remain separate from omitted queued work"
}

test_an_omitted_kind_keeps_the_existing_queued_rendering() {
  local home out
  home=$(make_home default-kind)
  out=$(render "$home" '[
    {"id":"with-reason","repo":"sample","title":"With reason","reason":"blocked on prep","dispatchable":true},
    {"id":"no-reason","repo":"sample","title":"No reason","reason":"","dispatchable":true}
  ]' 2)
  [ "$(charted_next_count "$out")" = 4 ] \
    || fail "an omitted kind changed the charted next tally: $out"
  printf '%s' "$out" | jq -e '
    ([.charted[0].badges[] | .text] == ["waiting"])
      and ([.charted[1].badges[] | .text] == ["ready"])
      and ([.charted[] | .pickable] == [true, true])
  ' >/dev/null || fail "an omitted kind changed how queued work reads: $out"
  pass "an omitted kind renders as queued work, waiting or ready by its reason"
}

test_an_underway_row_leads_with_the_task_name_and_keeps_its_run_status() {
  local home out
  home=$(make_home underway-name)
  out=$(render_board "$home" '[
    {"id":"fm-board-name-r1","repo":"firstmate","name":"Show task names on the board",
     "state":"working","kind":"ship","doing":"no-mistakes: review round 2"}
  ]' '[]')
  printf '%s' "$out" | jq -e '
    (.underway | length) == 1
      and (.underway[0]
        | .title == "Show task names on the board"
          and (.sub | test("no-mistakes: review round 2"))
          and (.sub | test("ship")) and (.sub | test("firstmate"))
          and [.badges[] | .text] == ["working"])
  ' >/dev/null || fail "an underway row did not lead with the task name: $out"
  pass "an underway row leads with the task name and still reports its run status"
}

test_an_underway_identifier_label_is_not_replaced_by_run_status() {
  local home out
  home=$(make_home underway-identifier)
  out=$(render_board "$home" '[
    {"id":"mate/child-1","repo":null,"name":"mate/child-1",
     "state":"working","kind":"secondmate","doing":"fixing the failing check"}
  ]' '[]')
  printf '%s' "$out" | jq -e '
    (.underway | length) == 1
      and (.underway[0]
        | .title == "mate/child-1"
          and (.sub | startswith("fixing the failing check · "))
          and (.title != "fixing the failing check"))
  ' >/dev/null || fail "an identifier-labelled underway row rendered as status-only: $out"
  pass "an underway identifier label is not replaced by run status"
}

test_charted_next_reads_newest_filed_first() {
  local home out
  home=$(make_home charted-order)
  out=$(render_board "$home" '[]' '[
    {"id":"oldest","repo":"sample","title":"Filed in June","reason":"queued","dispatchable":true,"filed":"2026-06-01"},
    {"id":"newest","repo":"sample","title":"Filed in August","reason":"queued","dispatchable":true,"filed":"2026-08-14T09:30:00Z"},
    {"id":"middle","repo":"sample","title":"Filed in July","reason":"queued","dispatchable":true,"filed":"2026-07-22"}
  ]')
  printf '%s' "$out" | jq -e '
    [.charted[] | .title] == ["Filed in August", "Filed in July", "Filed in June"]
  ' >/dev/null || fail "charted next was not ordered newest filed first: $out"
  pass "charted next renders the most recently filed work first"
}

test_charted_rows_without_a_filed_date_follow_the_dated_rows_in_payload_order() {
  local home out
  home=$(make_home charted-undated)
  out=$(render_board "$home" '[]' '[
    {"id":"undated-first","repo":"sample","title":"Undated one","reason":"queued","dispatchable":true},
    {"id":"dated","repo":"sample","title":"Dated","reason":"queued","dispatchable":true,"filed":"2026-07-22"},
    {"id":"undated-second","repo":"sample","title":"Undated two","reason":"queued","dispatchable":true,"filed":null}
  ]')
  printf '%s' "$out" | jq -e '
    [.charted[] | .title] == ["Dated", "Undated one", "Undated two"]
  ' >/dev/null || fail "undated charted rows did not keep a stable trailing order: $out"
  pass "charted rows with no filed date follow the dated rows in payload order"
}

test_every_charted_badge_opens_its_row() {
  local home out
  home=$(make_home badge-opens)
  out=$(render "$home" '[
    {"id":"ready-one","repo":"sample","title":"Ready","reason":"ready to start when you want it","dispatchable":true},
    {"id":"gated-one","repo":"sample","title":"Gated","reason":"until 2026-09-02","dispatchable":false},
    {"id":"warn-one","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"}
  ]')
  printf '%s' "$out" | jq -e '
    (.charted | length) == 3
      and all(.charted[]; (.badges | length) == 1 and .badges[0].expands
        and .detailHidden and .opens and (.detail | length) > 0)
  ' >/dev/null || fail "a charted badge was not a control that opens its explanation: $out"
  pass "every charted badge is a control that opens a closed explanation"
}

test_ready_work_says_ready_rather_than_waiting() {
  local home out
  home=$(make_home ready-badge)
  out=$(render "$home" '[
    {"id":"ready-one","repo":"sample","title":"Ready work","reason":"ready to start when you want it","dispatchable":true}
  ]')
  printf '%s' "$out" | jq -e '
    .charted[0] | [.badges[] | .text] == ["ready"] and .pickable
      and (.sub | startswith("ready to start"))
      and (.detail | test("Nothing is holding this back"))
  ' >/dev/null || fail "work with nothing holding it was not shown as ready: $out"
  pass "work with nothing holding it reads ready, not waiting"
}

test_a_date_the_captain_set_is_explained_as_their_date() {
  local home out
  home=$(make_home dated-why)
  out=$(render "$home" '[
    {"id":"takeout-export-20260819","repo":null,"title":"Request the mail export",
     "reason":"until 2026-09-02: Captain chose later on the export","dispatchable":false,"filed":"2026-08-19"}
  ]')
  printf '%s' "$out" | jq -e '
    .charted[0] | [.badges[] | .text] == ["waiting"]
      and (.sub == "until 2 Sep, a date you set")
      and (.detail | test("Waiting on a date you set: Wednesday 2 September \\(in 7 days\\)"))
      and (.detail | test("Nothing is needed from you before that"))
      and (.detail | test("why Captain chose later on the export"))
      and (.detail | test("filed Wednesday 19 August \\(7 days ago\\)"))
  ' >/dev/null || fail "a captain-set date was not explained in plain words: $out"
  pass "a dated hold says it waits on a date the captain set, and when"
}

test_a_long_held_answer_says_it_waits_on_the_captain() {
  local home out
  home=$(make_home aged-why)
  out=$(render "$home" '[
    {"id":"keep-export-20260801","repo":"sample","title":"Keep the old export",
     "reason":"held 12d: whether to keep the old export","dispatchable":false}
  ]')
  printf '%s' "$out" | jq -e '
    .charted[0] | (.detail | test("Waiting on your answer"))
      and (.detail | test("12 days"))
      and (.detail | test("about whether to keep the old export"))
  ' >/dev/null || fail "a long-held captain answer did not say it waits on the captain: $out"
  pass "an aged hold says it is waiting on the captain's own answer"
}

test_a_blocked_row_names_the_blocking_work_in_words_never_by_id() {
  local home out
  home=$(make_home blocked-why)
  out=$(render_board "$home" '[
    {"id":"catalog-dedupe-20260810","repo":"sample","name":"Deduplicate the catalog",
     "state":"working","kind":"ship","doing":"implementing"}
  ]' '[
    {"id":"search-courier-20260815","repo":"sample","title":"Catalog search courier",
     "reason":"blocked-by catalog-dedupe-20260810","dispatchable":false},
    {"id":"reply-path-20260816","repo":"sample","title":"Inbound reply path",
     "reason":"blocked on session-token-20260812: needs the token work first","dispatchable":false},
    {"id":"export-cleanup-20260817","repo":"sample","title":"Export cleanup",
     "reason":"blocked-by schema-freeze-20260805,search-courier-20260815 +2 more","dispatchable":false}
  ]' 0 0 '[
    {"id":"schema-freeze-20260805","repo":"sample","what":"Freeze the export schema","owner":"firstmate"}
  ]')
  printf '%s' "$out" | jq -e '
    ([.charted[] | .title] == ["Catalog search courier", "Inbound reply path", "Export cleanup"])
      and (.charted[0] | (.detail | test("Waiting on other work to finish first"))
        and (.detail | test("once \u201cDeduplicate the catalog\u201d \\(underway now\\) is done"))
        and (.sub | startswith("waiting for \u201cDeduplicate the catalog\u201d")))
      and (.charted[1] | (.detail | test("once \u201csession token\u201d is done"))
        and (.detail | test("why needs the token work first")))
      and (.charted[2] | (.detail | test("\u201cFreeze the export schema\u201d \\(recently landed\\)"))
        and (.detail | test("\u201cCatalog search courier\u201d \\(still queued\\)"))
        and (.detail | test("and 2 other pieces of work are done")))
      and ([.charted[] | .detail, .sub] | all(test("[a-z]-2026[0-9]{4}") | not))
  ' >/dev/null || fail "a blocked row did not name its blocking work in plain words: $out"
  pass "a blocked row names the work it waits on by title or in words, never by id"
}

test_overflow_queued_rows_are_revealed_in_place() {
  local home out rows
  home=$(make_home overflow)
  rows=$(jq -n '[range(1; 12) | {id:("queued-\(.)"), repo:"sample", title:("Queued \(.)"),
    reason:"ready to start when you want it", dispatchable:true,
    filed:("2026-08-" + (if . < 10 then "0\(.)" else "\(.)" end))}]
    + [{id:"warn-one", repo:"sample", title:"Home unreadable",
        reason:"current home state unavailable", dispatchable:false, kind:"warning"}]')
  out=$(render "$home" "$rows")
  printf '%s' "$out" | jq -e '
    (.charted | length) == 12
      and ([.charted[] | select(.collapsed | not) | .title]
        == ["Queued 11", "Queued 10", "Queued 9", "Queued 8", "Queued 7", "Queued 6",
            "Queued 5", "Queued 4", "Home unreadable"])
      and ([.charted[] | select(.collapsed) | .title] == ["Queued 3", "Queued 2", "Queued 1"])
      and (.reveal == [{"text":"Show 3 more queued","after":"Show fewer"}])
      and ([.revealed[] | select(.collapsed)] | length) == 0
      and (.more == [])
  ' >/dev/null || fail "overflow queued work was not revealed in place: $out"
  [ "$(charted_next_count "$out")" = 11 ] \
    || fail "collapsing overflow changed the charted next tally: $out"
  pass "overflow queued work collapses behind one control that reveals it in place, and warnings never collapse"
}

test_an_underway_row_leads_with_the_task_name_and_keeps_its_run_status
test_an_underway_identifier_label_is_not_replaced_by_run_status
test_charted_next_reads_newest_filed_first
test_charted_rows_without_a_filed_date_follow_the_dated_rows_in_payload_order
test_a_warning_row_reads_as_a_repair_not_as_queued_work
test_warnings_are_excluded_from_the_charted_next_count
test_a_board_of_only_warnings_still_reports_nothing_queued
test_omitted_warnings_never_count_as_more_queued
test_an_omitted_kind_keeps_the_existing_queued_rendering
test_every_charted_badge_opens_its_row
test_ready_work_says_ready_rather_than_waiting
test_a_date_the_captain_set_is_explained_as_their_date
test_a_long_held_answer_says_it_waits_on_the_captain
test_a_blocked_row_names_the_blocking_work_in_words_never_by_id
test_overflow_queued_rows_are_revealed_in_place
