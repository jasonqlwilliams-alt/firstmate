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
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

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


# --- Companion detail page and canvas export ---------------------------------

DETAIL_HARNESS="$ROOT/tests/assets/bearings-detail-harness.py"

# Build the board from a full payload file, with an optional config directory,
# and print the build output.
build_payload() {  # <home> <payload.json> [config-dir]
  local home=$1 data=$2 config=${3:-$1/config}
  mkdir -p "$config"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$data" 2>"$home/build.err" || fail "the board did not build: $(cat "$home/build.err")"
}

detail_of() {  # <home>
  python3 -I "$DETAIL_HARNESS" detail "$1/.lavish/bearings-detail.html" \
    || fail "the detail page could not be read"
}

# One payload carrying every kind of Charted Next and Recently Landed row the
# detail page must spell out, with the new detail fields set and omitted.
write_detail_payload() {  # <home>
  mkdir -p "$1/config"
  mkdir -p "$1/data/blocked row"
  printf 'A recorded report\n' > "$1/data/blocked row/\"&? report.md"
  jq -n '{
    schema:"fm-bearings-board.v1", home:"detail-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:[],
    underway:[{id:"live-work", repo:"sample", name:"Rewire the ledger", state:"working", doing:"tests", kind:"ship"}],
    charted:[
      {id:"blocked-row", repo:"sample", title:"Ship the second step",
       reason:"blocked-by live-work,first-step: needs the ledger", dispatchable:false,
       filed:"2026-08-20", waits_since:"2026-08-21", owner:"(main)",
       blockers:[{id:"live-work", title:null}, {id:"first-step", title:"Land the first step"}, {id:"gone-work"}],
       pr_url:"https://github.com/example/sample/pull/12", report:"data/blocked row/\"&? report.md"},
      {id:"ready-row", repo:"sample", title:"Ready queued work", reason:"", dispatchable:true,
       filed:"2026-08-24", owner:"mate-one"},
      {id:"warn-row", repo:null, title:"Main inventory integrity", reason:"main inventory",
       dispatchable:false, kind:"warning", filed:null}
    ],
    charted_more:2,
    landed:[
      {id:"landed-one", repo:"sample", what:"Shipped the board links", owner:"(main)",
       pr_url:"https://github.com/example/sample/pull/9", filed:"2026-08-10", landed_on:"2026-08-25",
       report:null},
      {id:"landed-two", repo:"sample", what:"Finished the ledger scout", owner:"mate-one",
       report:"https://example.com/reports/ledger"}
    ]}' > "$1/payload.json"
}

test_the_detail_page_spells_out_every_charted_and_landed_row() {
  local home out d
  home=$(make_home detail-page)
  write_detail_payload "$home"
  out=$(build_payload "$home" "$home/payload.json")
  assert_contains "$out" "detail: $home/.lavish/bearings-detail.html" "the build did not report the detail page"
  d=$(detail_of "$home")
  printf '%s' "$d" | jq -e --arg home "$home" '
    def fieldset: [.fields | keys[]] | sort
      == (["blockers","filed","owner","pr","report","since","waits-on","what"] | sort);
    .scripts == 0
    and (.sections.charted.items | map(.title)
      == ["Ready queued work", "Ship the second step", "Main inventory integrity"])
    and (.sections.landed.items | map(.title) == ["Shipped the board links", "Finished the ledger scout"])
    and ([.sections.charted.items[], .sections.landed.items[]] | all(fieldset))
    and (.sections.charted.items[1] | .anchor == "charted-blocked-row" and .badge == "waiting"
      and (.fields.what.text | test("Ship the second step")) and (.fields.what.text | test("sample"))
      and .fields["waits-on"].text == "Other work finishing first: needs the ledger"
      and .fields.since.label == "Waiting since" and .fields.since.text == "2026-08-21"
      and .fields.owner.text == "(main)"
      and .fields.blockers.text == "live-work Land the first step first-step gone-work"
      and .fields.report.text == ($home + "/data/blocked row/\"&? report.md")
      and .fields.report.links == [{href:("file://" + $home + "/data/blocked%20row/%22%26%3F%20report.md"),
                                   text:($home + "/data/blocked row/\"&? report.md")}]
      and .fields.pr.links == [{href:"https://github.com/example/sample/pull/12", text:"https://github.com/example/sample/pull/12"}]
      and .fields.filed.text == "2026-08-20")
    and (.sections.charted.items[0] | .badge == "ready"
      and .fields["waits-on"].text == "Nothing, it is ready to start"
      and .fields.since.text == "2026-08-24" and .fields.owner.text == "mate-one"
      and .fields.blockers.text == "None" and .fields.report.text == "Not recorded"
      and .fields.pr.text == "None recorded")
    and (.sections.charted.items[2] | .badge == "needs repair"
      and (.fields["waits-on"].text | test("records need repair"))
      and .fields.filed.text == "Not recorded" and .fields.owner.text == "Not recorded")
    and (.sections.charted.more | length == 1 and (.[0] | test("\\+2 more queued items were left out")))
    and (.sections.landed.items[0] | .badge == "landed" and .anchor == "landed-0"
      and .fields["waits-on"].text == "Nothing, it landed"
      and .fields.since.label == "Landed on" and .fields.since.text == "2026-08-25"
      and .fields.owner.text == "(main)" and .fields.filed.text == "2026-08-10"
      and .fields.pr.links[0].href == "https://github.com/example/sample/pull/9")
    and (.sections.landed.items[1] | .fields.since.text == "Not recorded"
      and .fields.report.links == [{href:"https://example.com/reports/ledger", text:"https://example.com/reports/ledger"}]
      and .fields.pr.text == "None recorded")
  ' >/dev/null || fail "the detail page did not spell out every row and field: $d"
  pass "the detail page shows every Charted Next and Recently Landed row with all eight facts"
}

test_the_detail_page_is_regenerated_on_every_build_and_states_empty_sections() {
  local home d
  home=$(make_home detail-rebuild)
  write_detail_payload "$home"
  build_payload "$home" "$home/payload.json" >/dev/null
  jq '.charted = [] | .charted_more = 0 | .landed = []' "$home/payload.json" > "$home/empty.json"
  build_payload "$home" "$home/empty.json" >/dev/null
  d=$(detail_of "$home")
  printf '%s' "$d" | jq -e '
    (.sections.charted.items | length) == 0 and (.sections.landed.items | length) == 0
      and .sections.charted.empty == "Nothing is queued."
      and .sections.landed.empty == "No recent completions are in the current baseline."
  ' >/dev/null || fail "a rebuild left stale rows or no empty state on the detail page: $d"
  jq '.charted = [{id:"warn-only", repo:null, title:"Main inventory integrity",
       reason:"main inventory", dispatchable:false, kind:"warning", filed:null}]
     | .charted_more = 0 | .landed = []' "$home/payload.json" > "$home/warn-only.json"
  build_payload "$home" "$home/warn-only.json" >/dev/null
  d=$(detail_of "$home")
  printf '%s' "$d" | jq -e '
    .sections.charted.empty == "Nothing is queued."
      and (.sections.charted.items | length) == 1
      and .sections.charted.items[0].badge == "needs repair"
  ' >/dev/null || fail "a warning-only detail page dropped its empty-queue notice or warning row: $d"
  jq 'del(.charted[0].blockers) | .charted = [.charted[0]]' "$home/payload.json" > "$home/no-blockers.json"
  build_payload "$home" "$home/no-blockers.json" >/dev/null
  d=$(detail_of "$home")
  printf '%s' "$d" | jq -e '
    .sections.charted.items[0].fields.blockers.text == "None"
  ' >/dev/null || fail "omitted blockers were inferred from reason prose: $d"
  pass "every build regenerates the detail page, including empty sections"
}

test_the_board_links_to_the_detail_page_from_its_nav_and_both_headers() {
  local home links
  home=$(make_home detail-links)
  write_detail_payload "$home"
  build_payload "$home" "$home/payload.json" >/dev/null
  links=$(python3 -I "$DETAIL_HARNESS" links "$home/.lavish/bearings-board.html") \
    || fail "the board links could not be read"
  printf '%s' "$links" | jq -e '
    [.[] | select(.href != null and (.href | startswith("bearings-detail.html")))] as $d
    | ($d | map({context, href}) | sort_by(.context))
        == ([{context:"nav", href:"bearings-detail.html"},
             {context:"Charted Next", href:"bearings-detail.html#charted"},
             {context:"Recently Landed", href:"bearings-detail.html#landed"}] | sort_by(.context))
      and ($d | all(.target == "_blank" and (.rel | test("noopener")) and .lavish_action == true))
  ' >/dev/null || fail "the board does not link the detail page from its nav and both headers: $links"
  # Relative links resolve to the sibling the build just wrote, from a file or
  # from the Lavish artifact route that serves the board directory.
  [ -f "$home/.lavish/bearings-detail.html" ] || fail "the linked detail page is not beside the board"
  python3 -I "$DETAIL_HARNESS" detail "$home/.lavish/bearings-detail.html" \
    | jq -e '.sections | has("charted") and has("landed")' >/dev/null \
    || fail "the linked anchors do not exist on the detail page"
  pass "the board nav and both section headers open the detail page and its section anchors"
}

test_hostile_titles_are_escaped_on_the_detail_page() {
  local home page d hostile='</script><script>alert(1)</script><img src=x onerror=alert(2)> & "quoted"'
  home=$(make_home detail-escape)
  write_detail_payload "$home"
  jq --arg h "$hostile" '
    .charted[0].title = $h | .charted[0].reason = $h
    | .charted[0].blockers[1].title = $h | .charted[0].owner = $h
    | .charted[0].report = $h | .landed[0].what = $h' "$home/payload.json" > "$home/hostile.json"
  build_payload "$home" "$home/hostile.json" >/dev/null
  page="$home/.lavish/bearings-detail.html"
  d=$(detail_of "$home")
  printf '%s' "$d" | jq -e --arg h "$hostile" '
    .scripts == 0
      and (.sections.charted.items | any(.title == $h and (.fields.blockers.text | contains($h))
        and .fields.owner.text == $h and (.fields["waits-on"].text | contains($h))))
      and (.sections.landed.items[0].title == $h)
      and ([.sections[].items[].fields[].links[]] | all(.href | startswith("https://") or startswith("file:///")))
  ' >/dev/null || fail "hostile text did not survive as inert text on the detail page: $d"
  if grep -qF '<img src=x' "$page" || grep -qiF '<script' "$page"; then
    fail "hostile markup reached the detail page unescaped"
  fi
  pass "hostile titles, notes, and paths render as inert text on the detail page"
}

test_remote_reports_are_plain_text_on_the_detail_page() {
  local home d remote_path='data/remote/<script>& report.md'
  home=$(make_home remote-reports)
  write_detail_payload "$home"
  jq --arg path "$remote_path" '
    .charted[0].report = $path | .charted[0].report_remote = true
    | .landed[0].report = $path | .landed[0].report_remote = true
  ' "$home/payload.json" > "$home/remote.json"
  build_payload "$home" "$home/remote.json" >/dev/null
  d=$(detail_of "$home")
  printf '%s' "$d" | jq -e --arg path "$remote_path" '
    .scripts == 0
      and (.sections.charted.items[1].fields.report
        | .text == ($path + " On remote host") and .links == [])
      and (.sections.landed.items[0].fields.report
        | .text == ($path + " On remote host") and .links == [])
  ' >/dev/null || fail "remote reports became local links or lost their host note: $d"
  pass "remote reports show their paths without local file links"
}

test_the_canvas_export_is_off_when_unconfigured() {
  local home out canvas_dir
  home=$(make_home canvas-off)
  write_detail_payload "$home"
  canvas_dir="$home/canvases"
  mkdir -p "$canvas_dir"
  out=$(build_payload "$home" "$home/payload.json")
  assert_contains "$out" "canvas: off" "an unconfigured build did not report the export off"
  : > "$home/config/bearings-canvas-dir"
  out=$(build_payload "$home" "$home/payload.json")
  assert_contains "$out" "canvas: off" "an empty config did not keep the export off"
  printf '%s/missing\n' "$home" > "$home/config/bearings-canvas-dir"
  out=$(build_payload "$home" "$home/payload.json")
  assert_contains "$out" "canvas: off (configured directory does not exist" "a missing directory did not keep the export off"
  [ ! -e "$home/missing" ] || fail "the export created the missing configured directory"
  [ -z "$(find "$canvas_dir" "$home/.lavish" -name '*.canvas.tsx' -print)" ] \
    || fail "an off export still wrote a canvas"
  pass "the canvas export writes nothing when its directory is unset, empty, or missing"
}

test_the_canvas_export_writes_exactly_one_file_in_its_directory() {
  # shellcheck disable=SC2016
  local home out dir after file hostile='</script>`${alert(1)}` {"x"} <b>bold</b> [spoof](javascript:alert(1))'
  home=$(make_home canvas-on)
  write_detail_payload "$home"
  jq --arg h "$hostile" '.charted[0].title = $h | .landed[0].what = $h' "$home/payload.json" > "$home/hostile.json"
  mkdir -p "$home/canvases"
  dir=$(cd "$home/canvases" && pwd -P)
  printf '# canvas export\n%s\n' "$dir" > "$home/config/bearings-canvas-dir"
  out=$(build_payload "$home" "$home/hostile.json")
  file="$dir/bearings-detail.canvas.tsx"
  assert_contains "$out" "canvas: $file" "the build did not report the canvas it wrote"
  [ "$(find "$dir" -mindepth 1 | wc -l | tr -d ' ')" = 1 ] || fail "the export did not write exactly one file: $(ls -A "$dir")"
  after=$(find "$home" -name '*.tsx' ! -path "$home/canvases/*" -print)
  [ -z "$after" ] || fail "the export wrote outside its directory: $after"
  # The embedded data is the same detail model the page renders, as one JSON
  # literal with angle brackets escaped, so hostile text stays inert data.
  node -e '
    const src = require("fs").readFileSync(process.argv[1], "utf8");
    const m = src.match(/const DETAIL: Detail =\n([\s\S]*?)\n;\n/);
    if (!m) { console.error("no data literal"); process.exit(1); }
    if (/[<>]/.test(m[1])) { console.error("unescaped angle bracket in JSON literal"); process.exit(1); }
    const d = JSON.parse(m[1]);
    const h = process.argv[2];
    const ok = d.charted.some((i) => i.title === h) && d.landed[0].title === h
      && d.charted.length === 3 && d.landed.length === 2;
    process.exit(ok ? 0 : 1);
  ' "$file" "$hostile" || fail "the canvas does not carry the detail rows as inert data"
  out=$(build_payload "$home" "$home/payload.json")
  [ "$(find "$dir" -mindepth 1 | wc -l | tr -d ' ')" = 1 ] || fail "a rebuild left extra files in the canvas directory"
  pass "a configured export writes exactly one canvas file, inside its directory, with inert data"
}

test_the_canvas_export_never_follows_a_planted_link_out_of_its_directory() {
  local home out dir outside outside_dir
  home=$(make_home canvas-link)
  write_detail_payload "$home"
  dir="$home/canvases"; outside="$home/outside.tsx"; outside_dir="$home/outside-dir"
  mkdir -p "$dir" "$outside_dir"
  printf 'keep\n' > "$outside"
  ln -s "$outside" "$dir/bearings-detail.canvas.tsx"
  printf '%s\n' "$dir" > "$home/config/bearings-canvas-dir"
  out=$(build_payload "$home" "$home/payload.json")
  [ "$(cat "$outside")" = keep ] || fail "the export wrote through a planted link"
  assert_contains "$(cat "$home/build.err")" "canvas-export-failed" "the refused export was not reported"
  [ -f "$home/.lavish/bearings-board.html" ] || fail "a refused canvas export stopped the board"

  ln -s "$outside_dir" "$home/canvases-symlink"
  printf '%s\n' "$home/canvases-symlink" > "$home/config/bearings-canvas-dir"
  out=$(build_payload "$home" "$home/payload.json")
  [ -z "$(ls -A "$outside_dir")" ] || fail "the export followed a symlinked canvas directory"
  assert_contains "$(cat "$home/build.err")" "configured directory is a symlink" "the symlinked directory refusal was not reported"
  pass "the canvas export refuses a planted link rather than writing outside its directory"
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
test_the_detail_page_spells_out_every_charted_and_landed_row
test_the_detail_page_is_regenerated_on_every_build_and_states_empty_sections
test_the_board_links_to_the_detail_page_from_its_nav_and_both_headers
test_hostile_titles_are_escaped_on_the_detail_page
test_remote_reports_are_plain_text_on_the_detail_page
test_the_canvas_export_is_off_when_unconfigured
test_the_canvas_export_writes_exactly_one_file_in_its_directory
test_the_canvas_export_never_follows_a_planted_link_out_of_its_directory
