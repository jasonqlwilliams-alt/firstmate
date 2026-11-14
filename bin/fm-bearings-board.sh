#!/usr/bin/env bash
# fm-bearings-board.sh - build and arm the /bearings lavish fleet board.
#
# The board is the captain-facing interactive surface of /bearings lavish: the
# shipped template (.agents/skills/bearings/assets/board-template.html) plus one
# injected fm-bearings-board.v1 JSON payload. This script owns the mechanics so
# the invoking agent's per-run work stays "compose the JSON, run build" - the
# agent never authors board UI at invocation time.
#
# Usage:
#   fm-bearings-board.sh build <data.json>
#   fm-bearings-board.sh path
#
# build      Validate the payload, drop the Captain's Call cards whose subject
#            already landed, give every surviving decision card the standard
#            reconcile choice, and inject the result into a fresh copy of the
#            shipped template at the stable board path. From those same
#            reconciled payload bytes, render the static sibling detail page
#            ($FM_HOME/.lavish/bearings-detail.html) for Charted Next and
#            Recently Landed, and - when config/bearings-canvas-dir names an
#            existing absolute directory - export the same detail model as one
#            self-contained Cursor Canvas file (bearings-detail.canvas.tsx)
#            inside that directory. Establish the Lavish
#            session on that board and PROVE it is live BEFORE binding and
#            arming its answer source, so a registered poll can never race a
#            session that does not exist or attach to one that has ended.
#            Bind to the keyed-answer intake (bin/fm-captain-hold.sh) ALWAYS
#            precedes arm, so the board can never produce an answer that has
#            nowhere to go (captain-hold-lifecycle's ordering rule, enforced
#            here rather than left to agent memory). Output starts with
#            `board: <path>`, `detail: <path>`, and `canvas: <path> | off ...`,
#            then includes lavish-axi's session output and the remaining status:
#              session: live | reopened
#              served: <path>
#              bound: <source-id>
#              armed: <source-id>            (first registration)
#              already-armed: <source-id>    (registration already present)
#              listening: <owner>            (only when a replacement was needed)
#            Every dropped card is named on stderr as a `dropped-landed-card:`
#            line, so a rebuild states what it removed instead of quietly
#            shrinking Captain's Call.
# path       Print the stable board path for this home.
#
# A LIVE SESSION IS PROVED, NEVER ASSUMED. `lavish-axi <file>` exits 0 even
# when it refuses to reopen a session the captain ended from the browser,
# reporting `status: user-ended` with the same session id, so exit status alone
# cannot tell a live board from a dead one. build requires the server's fresh
# session listing to show the canonical board open and refuses rather than
# arming an ended session. After a reopen it retires the pre-reopen source
# generation through the guarded adapter path, arms a fresh registration, and
# accepts only the replacement listener as live. A registered board with no
# live owner also gets a replacement before build returns, because
# `already-armed` is not the same fact as `listening`.
#
# CAPTAIN'S CALL HYGIENE. A decision card is dropped when its work item, PR, or
# structured artifact/version subject appears among the payload's own landed
# rows, or when `bin/fm-captain-hold.sh open` reports the task is no longer an
# open captain call. A newer published version also supersedes a version card.
# A task whose state cannot be established is kept, because a call wrongly
# hidden is worse than a card wrongly shown. Cleanup is therefore a normal
# rebuild effect rather than a committed migration or direct state mutation.
#
# THE RECONCILE CHOICE. Every decision card carries the standard `reconcile`
# option, injected here so the guarantee does not depend on the composer's
# memory, and the payload validator reserves that value across every card type.
# The validator's reservation scope must equal the adapter's reconcile
# classification scope, which is all card types because the captured payload
# carries no card type. Its meaning, and the reason it can never reach the
# keyed-answer intake as a blind close, are owned by
# docs/captain-hold-lifecycle.md.
#
# Validation is fail-closed: the payload must be valid JSON with
# schema=fm-bearings-board.v1 and every renderer-consumed field must satisfy
# the fm-bearings-board.v1 types and item invariants below. Every fleet row and
# Captain's Call item explicitly carries `repo`; the composer fills it from the
# snapshot and task records wherever known, and uses null or an empty string
# only as the deliberate genuinely-no-repo marker. In that exceptional case
# the template may display the routing id. Anything else refuses before the
# existing board is touched.
#
# Every Underway row likewise carries a non-empty `name`: the durable task name
# when known, otherwise its durable identifier.
# A Charted Next row MAY carry `filed`, the durable filed date (YYYY-MM-DD, or
# that date with a UTC timestamp) the template orders the section by, newest
# first; a row with no comparable date keeps its payload order after every dated
# row. Anything else in that field refuses rather than sorting on garbage.
# For the companion detail page and optional canvas export, a Charted Next row
# MAY also carry `waits_since` (same date/timestamp rule as `filed`), `owner`
# (nullable string), `blockers` (nullable array of `{id, title?}` objects with
# non-empty `id` and nullable string `title`), `report` (nullable string path or
# URL), and `pr_url` (nullable https URL). A Recently Landed row MAY likewise
# carry `filed`, `landed_on` (same date/timestamp rule), and `report` beside its
# optional `pr_url` and `subject`.
#
# The board path is stable - $FM_HOME/.lavish/bearings-board.html - so a
# re-invocation rebuilds the same file in place, which keeps the same Lavish
# session URL and the same canonical process-event source id. Its companion
# detail page lives beside it at $FM_HOME/.lavish/bearings-detail.html so
# relative links from the board resolve identically over file:// and through the
# Lavish session's sibling asset route. Injection escapes
# every `<` in the compact JSON as the \u003c string escape, so a payload string
# containing "</script>" can never terminate the data block early.
#
# Optional Cursor Canvas export is controlled by local, gitignored
# config/bearings-canvas-dir (docs/configuration.md "Bearings detail canvas
# export"): when unset, empty, relative, or naming a missing directory, the
# export is off and writes nothing; when it names an existing non-symlink
# absolute directory, build atomically writes bearings-detail.canvas.tsx inside
# that directory only and never fails the board build if the export is refused.
#
# FM_BEARINGS_BOARD_TEMPLATE overrides the shipped template path (tests only).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

TEMPLATE="${FM_BEARINGS_BOARD_TEMPLATE:-$SCRIPT_DIR/../.agents/skills/bearings/assets/board-template.html}"
PLACEHOLDER='__FM_BEARINGS_BOARD_DATA__'
BOARD_SCHEMA=fm-bearings-board.v1
# The detail page and canvas templates ship beside the board template.
DETAIL_TEMPLATE="${TEMPLATE%/*}/detail-template.html"
DETAIL_PLACEHOLDER='__FM_BEARINGS_DETAIL_BODY__'
DETAIL_NAME=bearings-detail.html
CANVAS_TEMPLATE="${TEMPLATE%/*}/detail-canvas-template.tsx"
CANVAS_PLACEHOLDER='__FM_BEARINGS_DETAIL_MODEL__'
CANVAS_NAME=bearings-detail.canvas.tsx
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-bearings-board: %s\n' "$*" >&2
  exit 1
}

board_path() { printf '%s/.lavish/bearings-board.html\n' "$FM_HOME"; }

validate_payload() {  # <data.json>
  jq -e --arg schema "$BOARD_SCHEMA" '
    def nonempty_string: type == "string" and length > 0;
    def slug($max): type == "string" and test("^[A-Za-z0-9._-]{1," + ($max | tostring) + "}$");
    def repo_marker: has("repo") and (.repo == null or (.repo | type == "string"));
    def name_marker: has("name") and (.name | nonempty_string);
    def valid_filed:
      . as $filed
      | type == "string"
      and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)?$")
      and (if test("T")
        then try ((fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == $filed) catch false
        else try (((. + "T00:00:00Z") | fromdateiso8601 | strftime("%Y-%m-%d")) == $filed) catch false
        end);
    def optional_date($name):
      (has($name) | not) or (.[$name] == null) or (.[$name] | valid_filed);
    def optional_filed: optional_date("filed");
    def optional_nullable_string($name):
      (has($name) | not) or (.[$name] == null) or (.[$name] | type == "string");
    def optional_blockers:
      (has("blockers") | not) or (.blockers == null)
      or (.blockers | type == "array"
        and all(.[]; type == "object" and (.id | nonempty_string)
          and ((has("title") | not) or (.title == null) or (.title | type == "string"))));
    def optional_string($name): (has($name) | not) or (.[$name] | type == "string");
    def optional_https_url($name):
      (has($name) | not)
      or (.[$name] == null)
      or (.[$name]
        | type == "string"
          and test("^https://[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?(?:[/?#][^[:space:]]*)?$"));
    def version: type == "string" and test("^(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})$");
    def optional_subject:
      (has("subject") | not)
      or (.subject
        | type == "object"
          and (keys | sort) == ["artifact", "version"]
          and (.artifact | slug(128))
          and (.version | version));
    def call_item:
      type == "object"
      and (.key | slug(128))
      and (.type == "decision" or .type == "merge" or .type == "credential")
      and repo_marker
      and (.title | nonempty_string)
      and (.options | type == "array")
      and ((.options | length) > 0 or .allow_freeform == true)
      and ([.options[]
        | type == "object"
          and (.value | slug(128))
          and (.label | nonempty_string)
          and optional_string("hint")] | all)
      and (optional_string("about"))
      and (optional_string("decide"))
      and (optional_string("detail"))
      and (optional_https_url("pr_url"))
      and optional_subject
      and (if has("subject") then .type == "decision" else true end)
      and (optional_string("freeform_hint"))
      and ((has("close") | not) or (.close == "done" or .close == "release"))
      and ((has("allow_freeform") | not) or (.allow_freeform | type == "boolean"))
      and ((has("recommend_value") | not)
        or ((.recommend_value | slug(128))
          and (.recommend_value as $recommend
            | ([.options[].value] | index($recommend) != null))))
      and ([.options[].value] | index("reconcile") == null)
      and (if .type == "merge" then (.risk | nonempty_string) else true end);
    def underway_item:
      type == "object" and repo_marker and name_marker and (.id | nonempty_string)
      and (.state | nonempty_string) and (.doing | nonempty_string) and (.kind | nonempty_string);
    def landed_item:
      type == "object" and repo_marker and (.id | nonempty_string)
      and (.what | nonempty_string) and (.owner | nonempty_string)
      and optional_https_url("pr_url")
      and optional_subject
      and optional_filed
      and optional_date("landed_on")
      and optional_nullable_string("report");
    def charted_item:
      type == "object" and repo_marker and (.id | slug(128))
      and (.title | nonempty_string) and (.reason | type == "string")
      and (.dispatchable | type == "boolean")
      and ((has("kind") | not) or (.kind == "queued" or .kind == "warning"))
      and optional_filed
      and optional_date("waits_since")
      and optional_nullable_string("owner")
      and optional_blockers
      and optional_nullable_string("report")
      and optional_https_url("pr_url")
      and (if .kind == "warning" then .dispatchable == false else true end);
    type == "object"
    and (.schema == $schema)
    and (.home | nonempty_string)
    and (.generated | nonempty_string)
    and (.prs_live | type == "boolean")
    and (.captains_call | type == "array")
    and (.underway | type == "array")
    and (.landed | type == "array")
    and (.charted | type == "array")
    and ((has("charted_more") | not)
      or ((.charted_more | type == "number") and (.charted_more >= 0) and (.charted_more | floor == .)))
    and ((has("charted_warning_more") | not)
      or ((.charted_warning_more | type == "number") and (.charted_warning_more >= 0) and (.charted_warning_more | floor == .)))
    and ([.captains_call[] | call_item] | all)
    and ([.underway[] | underway_item] | all)
    and ([.landed[] | landed_item] | all)
    and ([.charted[] | charted_item] | all)
  ' "$1" >/dev/null
}

# shellcheck source=bin/fm-lavish-board-lib.sh
. "$SCRIPT_DIR/fm-lavish-board-lib.sh"

# --- Captain's Call hygiene ---------------------------------------------------
# A held decision whose subject already shipped is not a live call, so it is
# dropped here instead of being carded again. All checks use exact structured
# identities; unknown subject state keeps the card.

decision_card_is_stale() {  # <task-id> <landed-0-or-1>
  local task=$1 landed=$2 rc=0
  if [ "$landed" = 1 ]; then
    printf 'structured subject already landed\n'
    return 0
  fi
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$task" --distinguish-absent >/dev/null 2>&1 || rc=$?
  # 1 is a definite "no longer an open captain call". 2 is "cannot tell", 3 is
  # absent from this backlog, and a call wrongly hidden is worse than a card
  # wrongly shown, so both uncertain and absent cards stay.
  if [ "$rc" -eq 1 ]; then
    printf 'no longer an open captain call\n'
    return 0
  fi
  return 1
}

# Drop every stale decision card, then give every surviving decision card the
# standard reconcile choice. Injecting it here is what makes "every decision
# card offers reconcile" a property of the board rather than of the composer's
# memory; the validator prevents duplicate decision options.
effective_payload() {  # <data.json> <dest.json>
  local data=$1 dest=$2 landed_keys key reason drop='' tmp landed=0
  landed_keys=$(jq -c '
    def version_parts: split(".") | map(tonumber);
    . as $payload
    | [$payload.captains_call[]
      | select(.type == "decision")
      | . as $card
      | select(
          ($payload.landed | any(.id == $card.key))
          or (($card.pr_url? != null) and ($payload.landed | any(.pr_url? == $card.pr_url)))
          or (($card.subject? != null) and ($payload.landed | any(
            (.subject? != null)
            and (.subject.artifact == $card.subject.artifact)
            and ((.subject.version | version_parts) >= ($card.subject.version | version_parts)))))
        )
      | .key]
  ' "$data") || return 1
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    landed=0
    if jq -e --arg key "$key" 'index($key) != null' <<< "$landed_keys" >/dev/null; then
      landed=1
    fi
    reason=$(decision_card_is_stale "$key" "$landed") || continue
    printf 'dropped-landed-card: %s (%s)\n' "$key" "$reason" >&2
    drop=$drop$key$'\n'
  done < <(jq -r '.captains_call[]? | select(.type == "decision") | .key' "$data")
  tmp=$(printf '%s' "$drop" | jq -R -s 'split("\n") | map(select(length > 0))') || return 1
  jq --argjson dropped "$tmp" '
    .captains_call = [
      .captains_call[]
      | . as $card
      | select($card.type != "decision" or (($dropped | index($card.key)) == null))
      | if .type == "decision"
        then .options += [{
          value: "reconcile",
          label: "Reconcile",
          hint: "Re-check the latest state, then close this with evidence or keep it open with a note"
        }]
        else . end
    ]' "$data" > "$dest" || return 1
}

# --- Companion detail page and canvas export ---------------------------------
# Both render one normalized detail model, derived here from the same effective
# payload the board carries, so the page, the canvas, and the board can never
# disagree about a row. Every title, note, and path stays text: the page escapes
# it with @html, and the canvas embeds the model as a JSON literal that its
# component renders only as React text children.

# The detail model: every Charted Next row in board order (queued work newest
# filed first, then repair notices) and every Recently Landed row in payload
# order, each with the same eight facts.
detail_model() {  # <effective.json> <home-dir>
  jq --arg home_dir "$2" '
    def isowarn: .kind == "warning";
    def board_order:
      to_entries
      | ([.[] | select((.value.filed | type) == "string" and (.value.filed | length) > 0)]
          | sort_by([.value.filed, -.key]) | reverse)
        + [.[] | select(((.value.filed | type) == "string" and (.value.filed | length) > 0) | not)]
      | map(.value);
    def nz: if . == null or . == "" then null else . end;
    def cap($re): (capture($re) // null);
    def valid_day:
      type == "string"
      and (try (((. + "T00:00:00Z") | fromdateiso8601 | strftime("%Y-%m-%d")) == .) catch false);
    def unique_anchors($prefix):
      reduce .[] as $item
        ({seen: {}, out: []};
         ($prefix + $item.id) as $base
         | ((.seen[$base] // 0) + 1) as $n
         | .seen[$base] = $n
         | .out += [$item + {anchor: (if $n == 1 then $base else ($base + "-" + ($n | tostring)) end)}])
      | .out;
    def report_fields:
      (.report | nz) as $r
      | {report: $r,
         report_url: (if $r != null and ($r | test("^(https?://|file://)[^[:space:]]+$")) then $r else null end),
         report_path: (if $r == null or ($r | test("^(https?://|file://)")) then null
                       elif ($r | startswith("/")) then $r
                       else ($home_dir + "/" + $r) end)};
    def row_status_and_waits:
      (.reason // "" | tostring | gsub("^\\s+|\\s+$"; "")) as $r
      | ($r | cap("^(?:[Bb][Ll][Oo][Cc][Kk][Ee][Dd](?:[- ][Bb][Yy]|\\s+[Oo][Nn]))\\s+(?<list>.+?)(?:\\s*:\\s+(?<rest>.*))?$")) as $b
      | ($r | cap("^[Uu][Nn][Tt][Ii][Ll]\\s+(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})(?:T[0-9:.]+Z?)?(?:\\s*:\\s+(?<rest>.*))?$")) as $u
      | ($r | cap("^[Hh][Ee][Ll][Dd]\\s+(?<n>[0-9]+)d\\b(?:\\s*:\\s+(?<rest>.*))?$")) as $h
      | if isowarn then
          {status: "needs repair",
           waits_on: ("Nothing to start: a notice that the fleet records need repair"
             + (if $r != "" then " (" + $r + ")" else "" end))}
        elif $b != null then
          {status: "waiting",
           waits_on: ("Other work finishing first" + (if ($b.rest // "") != "" then ": " + $b.rest else "" end))}
        elif $u != null and ($u.d | valid_day) then
          {status: "waiting",
           waits_on: ("A date you set: " + $u.d + (if ($u.rest // "") != "" then " - " + $u.rest else "" end))}
        elif $h != null then
          {status: "waiting",
           waits_on: ("Your answer, held " + $h.n + (if $h.n == "1" then " day" else " days" end)
             + (if ($h.rest // "") != "" then " - " + $h.rest else "" end))}
        elif .dispatchable then
          {status: "ready",
           waits_on: ("Nothing, it is ready to start"
             + (if $r != "" and (($r | test("^[Rr][Ee][Aa][Dd][Yy] [Tt][Oo] [Ss][Tt][Aa][Rr][Tt]\\b[^;:]*$")) | not)
                then " (" + $r + ")" else "" end))}
        elif $r == "" then
          {status: "waiting", waits_on: "No reason recorded"}
        else
          {status: "waiting", waits_on: $r}
        end;
    . as $p
    | {schema: "fm-bearings-detail.v1",
       home: $p.home,
       generated: $p.generated,
       charted_more: ($p.charted_more // 0),
       charted_warning_more: ($p.charted_warning_more // 0),
       charted: (
         [ (($p.charted | map(select(isowarn | not)) | board_order)
             + ($p.charted | map(select(isowarn)) | board_order))[]
           | row_status_and_waits as $sw
           | {section: "charted",
              id, repo: (.repo | nz), title,
              status: $sw.status,
              waits_on: $sw.waits_on,
              since_label: "Waiting since",
              since: (.waits_since // .filed | nz),
              owner: (.owner | nz),
              blockers: [(.blockers // [])[] | {id, title: (.title | nz)}],
              pr_url: (.pr_url | nz),
              filed: (.filed | nz)} + report_fields ]
         | unique_anchors("charted-")),
       landed: [
         $p.landed | to_entries[] | .key as $i | .value
         | {section: "landed",
            anchor: ("landed-" + ($i | tostring)),
            id, repo: (.repo | nz), title: .what,
            status: "landed",
            waits_on: "Nothing, it landed",
            since_label: "Landed on",
            since: (.landed_on | nz),
            owner: (.owner | nz),
            blockers: [],
            pr_url: (.pr_url | nz),
            filed: (.filed | nz)} + report_fields ]}
  ' "$1"
}

# Render the detail page body from the model. Every string is @html-escaped;
# the only attribute values are fixed anchors and validated https URLs.
render_detail_body() {  # <model.json>
  jq -r '
    def e: tostring | @html;
    def or_text($none): if . == null then "<span class=\"dt-none\">" + $none + "</span>" else e end;
    def link: "<a href=\"" + e + "\" target=\"_blank\" rel=\"noopener\">" + e + "</a>";
    def field($key; $label; $value):
      "<div class=\"dt-field\" data-field=\"" + $key + "\"><dt>" + $label + "</dt><dd>" + $value + "</dd></div>";
    def tone: {"ready": "online", "waiting": "warn", "needs repair": "danger", "landed": "online"}[.] // "warn";
    def blockers_html:
      if (.blockers | length) == 0 then "<span class=\"dt-none\">None</span>"
      else "<ul class=\"dt-blockers\">"
        + ([.blockers[] | "<li><span class=\"dt-blocker__title\">"
            + ((.title // .id) | e)
            + "</span>" + (if .title == null then "" else " <code class=\"dt-id\">" + (.id | e) + "</code>" end) + "</li> "] | join(""))
        + "</ul>" end;
    def file_href: "file://" + (split("/") | map(@uri) | join("/"));
    def report_html:
      if .report_url != null then (.report_url | link)
      elif .report_path != null then
        "<a class=\"dt-path\" href=\"" + (.report_path | file_href | e)
        + "\" target=\"_blank\" rel=\"noopener\">" + (.report_path | e) + "</a>"
      else "<span class=\"dt-none\">Not recorded</span>" end;
    def item:
      "<article class=\"dt-item\" id=\"" + (.anchor | e) + "\" data-section=\"" + .section + "\">"
      + "<header class=\"dt-item__head\"><h3 class=\"dt-item__title\">" + (.title | e) + "</h3>"
      + "<span class=\"fm-badge fm-badge--" + (.status | tone) + "\">" + (.status | e) + "</span></header>"
      + "<dl class=\"dt-fields\">"
      + field("what"; "What it is"; (.title | e) + (if .repo then " <span class=\"dt-repo\">" + (.repo | e) + "</span>" else "" end))
      + field("waits-on"; "Waits on"; .waits_on | e)
      + field("since"; .since_label; .since | or_text("Not recorded"))
      + field("owner"; "Owner"; .owner | or_text("Not recorded"))
      + field("blockers"; "Blockers"; blockers_html)
      + field("report"; "Report"; report_html)
      + field("pr"; "PR"; if .pr_url != null then (.pr_url | link) else "<span class=\"dt-none\">None recorded</span>" end)
      + field("filed"; "Filed"; .filed | or_text("Not recorded"))
      + "</dl></article>";
    def more($n; $what):
      if $n > 0 then "<p class=\"dt-more\">+" + ($n | tostring) + " more " + $what
        + (if $n == 1 then " was" else " were" end) + " left out when this board was built.</p>" else "" end;
    . as $m
    | "<header class=\"dt-nav\"><div class=\"dt-nav__inner\"><span class=\"dt-brand\">bearings</span>"
      + "<span class=\"dt-nav__title\">Charted Next and Recently Landed in detail</span>"
      + "<nav class=\"dt-nav__links\"><a href=\"#charted\">Charted Next</a><a href=\"#landed\">Recently Landed</a></nav>"
      + "</div></header>"
      + "<main class=\"dt-main\">"
      + "<p class=\"dt-intro\">Every Charted Next and Recently Landed row on the bearings board, with what each waits on, since when, who owns it, and its links. Rebuilt with the board at <span class=\"dt-mono\">" + ($m.generated | e) + "</span>.</p>"
      + "<section class=\"dt-section\" id=\"charted\"><h2 class=\"dt-section__title\">Charted Next</h2>"
      + (if ([ $m.charted[] | select(.status != "needs repair") ] | length) == 0 and $m.charted_more == 0
         then "<p class=\"dt-empty\">Nothing is queued.</p>" else "" end)
      + ([$m.charted[] | item] | join(""))
      + more($m.charted_more; "queued " + (if $m.charted_more == 1 then "item" else "items" end))
      + more($m.charted_warning_more; "repair " + (if $m.charted_warning_more == 1 then "warning" else "warnings" end))
      + "</section>"
      + "<section class=\"dt-section\" id=\"landed\"><h2 class=\"dt-section__title\">Recently Landed</h2>"
      + (if ($m.landed | length) == 0 then "<p class=\"dt-empty\">No recent completions are in the current baseline.</p>" else ([$m.landed[] | item] | join("")) end)
      + "</section></main>"
  ' "$1"
}

# Inject <content-file> in place of the one <placeholder> line of <template>
# into a fresh private file beside <dest>, then publish it atomically.
publish_from_template() {  # <template> <placeholder> <content-file> <dest>
  local template=$1 placeholder=$2 content=$3 dest=$4 tmp
  [ -f "$template" ] && [ ! -L "$template" ] || { printf 'template is missing: %s\n' "$template" >&2; return 1; }
  [ "$(grep -cxF "$placeholder" "$template")" -eq 1 ] \
    || { printf 'template does not carry exactly one slot: %s\n' "$template" >&2; return 1; }
  tmp=$(umask 077; mktemp "${dest%/*}/.detail.XXXXXX") || return 1
  if ! FM_SLOT_FILE="$content" FM_PLACEHOLDER="$placeholder" perl -pe '
        BEGIN { local $/; open(my $fh, "<", $ENV{FM_SLOT_FILE}) or die; $slot = <$fh>; chomp $slot; }
        if ($_ eq "$ENV{FM_PLACEHOLDER}\n") { $_ = "$slot\n"; }' "$template" > "$tmp" \
     || grep -qxF "$placeholder" "$tmp" \
     || ! chmod 0600 "$tmp" \
     || ! perl -e 'rename($ARGV[0], $ARGV[1]) or exit 1' "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# The optional canvas directory: the first non-comment, non-blank line of
# config/bearings-canvas-dir. Prints nothing when the export is off.
canvas_dir() {
  local file="$CONFIG_DIR/bearings-canvas-dir" line
  [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    case "$line" in \#*) continue ;; esac
    printf '%s' "$line"
    return 0
  done < "$file"
}

# Export the detail model as one self-contained Cursor Canvas file in the
# configured directory, or report why it was skipped. Never fails the build:
# the canvas is an optional mirror and the board is already published.
export_canvas() {  # <model.json>
  local model=$1 dir clean_dir real dest literal
  dir=$(canvas_dir)
  if [ -z "$dir" ]; then
    printf 'canvas: off\n'
    return 0
  fi
  case "$dir" in
    /*) ;;
    *) printf 'canvas: off (config/bearings-canvas-dir is not an absolute path)\n'; return 0 ;;
  esac
  clean_dir=${dir%/}
  [ -n "$clean_dir" ] || clean_dir=/
  if [ -L "$clean_dir" ]; then
    printf 'canvas-export-failed: configured directory is a symlink: %s\n' "$dir" >&2
    return 0
  fi
  if [ ! -d "$clean_dir" ]; then
    printf 'canvas: off (configured directory does not exist: %s)\n' "$dir"
    return 0
  fi
  real=$(board_realpath "$clean_dir") || { printf 'canvas-export-failed: cannot resolve %s\n' "$dir" >&2; return 0; }
  dest="$real/$CANVAS_NAME"
  if [ -L "$dest" ] || { [ -e "$dest" ] && [ ! -f "$dest" ]; }; then
    printf 'canvas-export-failed: %s is not a regular file; refusing to replace it\n' "$dest" >&2
    return 0
  fi
  literal=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-canvas.XXXXXX") \
    || { printf 'canvas-export-failed: cannot stage the canvas data\n' >&2; return 0; }
  # A JSON literal is a valid TypeScript expression. Angle brackets and
  # U+2028/2029 are escaped so no parser reads markup or line breaks in strings.
  if ! jq '.' "$model" \
    | perl -CS -pe 's/</\\u003c/g; s/>/\\u003e/g; s/\x{2028}/\\u2028/g; s/\x{2029}/\\u2029/g' > "$literal"; then
    rm -f -- "$literal"
    printf 'canvas-export-failed: cannot encode the canvas data\n' >&2
    return 0
  fi
  if ! publish_from_template "$CANVAS_TEMPLATE" "$CANVAS_PLACEHOLDER" "$literal" "$dest"; then
    rm -f -- "$literal"
    printf 'canvas-export-failed: cannot write %s\n' "$dest" >&2
    return 0
  fi
  rm -f -- "$literal"
  printf 'canvas: %s\n' "$dest"
}

publish_detail() {  # <effective.json> <board>
  local effective=$1 board=$2 model body dest
  dest="${board%/*}/$DETAIL_NAME"
  model=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-detail.XXXXXX") || fail "cannot stage the detail model"
  body=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-detail-body.XXXXXX") \
    || { rm -f -- "$model"; fail "cannot stage the detail page"; }
  if ! detail_model "$effective" "$FM_HOME" > "$model" || ! render_detail_body "$model" > "$body"; then
    rm -f -- "$model" "$body"
    fail "cannot render the detail page"
  fi
  if ! publish_from_template "$DETAIL_TEMPLATE" "$DETAIL_PLACEHOLDER" "$body" "$dest"; then
    rm -f -- "$model" "$body"
    fail "cannot publish the detail page"
  fi
  rm -f -- "$body"
  printf 'detail: %s\n' "$dest"
  export_canvas "$model"
  rm -f -- "$model"
}

command_build() {
  local data=${1-} board json tmp sid extracted effective owner version pre_reopen_owner
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -f "$data" ] || fail "board data does not exist: $data"
  jq empty "$data" 2>/dev/null || fail "board data is not valid JSON: $data"
  validate_payload "$data" || fail "board data does not satisfy $BOARD_SCHEMA: $data"
  [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || fail "board template is missing: $TEMPLATE"
  [ "$(grep -cxF "$PLACEHOLDER" "$TEMPLATE")" -eq 1 ] \
    || fail "board template does not carry exactly one data slot: $TEMPLATE"

  effective=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-payload.XXXXXX") \
    || fail "cannot stage the board payload"
  if ! effective_payload "$data" "$effective"; then
    rm -f -- "$effective"
    fail "cannot reconcile the board payload against landed work"
  fi
  # The staged payload outlives the board publish: the detail page and the
  # canvas export render from these same bytes.
  BUILD_STAGED=$effective
  trap 'rm -f -- "$BUILD_STAGED"' EXIT
  json=$(jq -c . "$effective") || fail "cannot compact the board data"
  # `<` never appears in JSON syntax outside strings, so escaping every
  # occurrence keeps the payload valid JSON while making </script> inert.
  json=${json//</\\u003c}

  board=$(board_path)
  (umask 077; mkdir -p "${board%/*}") || fail "cannot create ${board%/*}"
  tmp=$(umask 077; mktemp "${board%/*}/.board.XXXXXX") || fail "cannot stage the board"
  if ! BOARD_JSON="$json" perl -pe "s/^\\Q$PLACEHOLDER\\E\$/\$ENV{BOARD_JSON}/" "$TEMPLATE" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot inject the board data"
  fi
  if grep -qxF "$PLACEHOLDER" "$tmp"; then
    rm -f -- "$tmp"
    fail "the board data slot survived injection"
  fi
  # Round-trip the injected payload back out of the built page, so a board that
  # would fail to parse in the browser fails here instead.
  extracted=$(sed -n '/<script id="bearings-data" type="application\/json">/,/<\/script>/p' "$tmp" \
    | sed '1d;$d')
  if ! printf '%s\n' "$extracted" | jq -e --arg schema "$BOARD_SCHEMA" '.schema == $schema' >/dev/null 2>&1; then
    rm -f -- "$tmp"
    fail "the built board does not carry a readable $BOARD_SCHEMA payload"
  fi
  if ! { chmod 0600 "$tmp" && mv -f -- "$tmp" "$board"; }; then
    rm -f -- "$tmp"
    fail "cannot publish the board"
  fi
  printf 'board: %s\n' "$board"
  publish_detail "$effective" "$board"
  rm -f -- "$effective"
  trap - EXIT

  command -v lavish-axi >/dev/null 2>&1 || fail "lavish-axi is not installed"
  sid=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$board") \
    || fail "cannot derive the board source id"
  pre_reopen_owner=$(source_owner "$sid")
  establish_board_session "$board"
  if [ "$BOARD_SESSION_REOPENED" = 1 ]; then
    "$SCRIPT_DIR/fm-procevent-lavish.sh" retire "$board" >/dev/null \
      || fail "cannot retire the pre-reopen source generation (observed owner: ${pre_reopen_owner:-none})"
  fi
  if ! lavish_session_listed_open "$(board_realpath "$board")"; then
    version=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
    fail "the board Lavish session is not listed open immediately before arming (lavish-axi ${version:-version-unknown}); refusing to arm a poll on observed state not-open"
  fi
  printf 'served: %s\n' "$board"

  "$SCRIPT_DIR/fm-captain-hold.sh" bind "$sid" >/dev/null \
    || fail "cannot bind the board source to the keyed-answer intake"
  printf 'bound: %s\n' "$sid"

  owner=$(source_owner "$sid")
  if [ "$BOARD_SESSION_REOPENED" = 1 ]; then
    "$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$board" >/dev/null \
      || fail "cannot arm a fresh board source after reopening"
    printf 'armed: %s\n' "$sid"
    owner=$(source_owner "$sid")
  elif [ -n "$owner" ]; then
    printf 'already-armed: %s\n' "$sid"
  else
    "$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$board" >/dev/null \
      || fail "cannot arm the board as a process-event source"
    printf 'armed: %s\n' "$sid"
    owner=$(source_owner "$sid")
  fi
  # Registered is not listening. A board whose source has no live owner gets a
  # replacement started now rather than at the next supervision cycle, which is
  # what keeps a rebuilt board from sitting silent behind `already-armed`.
  if [ "$owner" != live ]; then
    "$SCRIPT_DIR/fm-procevent.sh" reconcile >/dev/null 2>&1 || true
    owner=$(await_source_owner "$sid")
    if [ "$owner" != live ]; then
      fail "source $sid is not listening after reconcile (observed owner: ${owner:-none})"
    fi
    printf 'listening: live\n'
  fi
}

case "${1-}" in
  build) shift; command_build "$@" ;;
  path) board_path ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
