#!/usr/bin/env bash
# Lineup's public build/apply interfaces with fixture catalogs and stubbed
# Lavish/propagation/restart endpoints. Never launches a real harness or browser.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-lineup-board)
FIXTURE="$TMP_ROOT/repo"
mkdir -p "$FIXTURE" "$TMP_ROOT/home/config" "$TMP_ROOT/home/state"
cp -R "$ROOT/bin" "$FIXTURE/bin"
mkdir -p "$FIXTURE/.agents/skills/lineup"
cp -R "$ROOT/.agents/skills/lineup/assets" "$FIXTURE/.agents/skills/lineup/assets"
export FM_HOME="$TMP_ROOT/home" FM_ROOT_OVERRIDE="$FIXTURE"
export FM_CONFIG_OVERRIDE="$FM_HOME/config" FM_STATE_OVERRIDE="$FM_HOME/state" FM_DATA_OVERRIDE="$FM_HOME/data"
export CALL_LOG="$TMP_ROOT/calls"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
export PATH="$FAKEBIN:$PATH"
BOARD="$FIXTURE/bin/fm-lineup-board.sh"
# Keep the real Lavish adapter (including canonical identity and arm argv).
# Stub only the generic runner so no detached listener can escape the suite.
cat > "$FIXTURE/bin/fm-procevent.sh" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$CALL_LOG"
case "$1" in
  register)
    [ -s "$FM_HOME/open" ] || exit 1
    printf '%s\n' "$3" > "$FM_HOME/source"
    ;;
  list)
    printf 'ID ADAPTER OWNER\n'
    if [ -f "$FM_HOME/source" ]; then printf '%s lavish live\n' "$(cat "$FM_HOME/source")"; fi
    ;;
  retire) rm -f "$FM_HOME/source" ;;
  reconcile) exit 0 ;;
esac
SH
cat > "$FAKEBIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  '')
    printf 'sessions[1]{file,status,url,pending_prompts}:\n'
    if [ -s "$FM_HOME/open" ]; then printf '  %s,open,"http://127.0.0.1/session/fixture",0\n' "$(cat "$FM_HOME/open")"; fi
    ;;
  --version) echo fixture ;;
  poll) echo 'ERROR: tests must not poll'; exit 99 ;;
  *)
    printf 'serve %s\n' "$*" >> "$CALL_LOG"
    if [ -e "$FM_HOME/refuse" ] || { [ -e "$FM_HOME/ended" ] && [ "${2:-}" != --reopen ]; }; then
      rm -f "$FM_HOME/open"
      printf 'status: user-ended\n'
    else
      printf '%s\n' "$1" > "$FM_HOME/open"
      rm -f "$FM_HOME/ended"
      printf 'status: opened\nurl: "http://127.0.0.1/session/fixture"\n'
    fi
    ;;
esac
SH
for pair in fm-config-push.sh:propagate fm-secondmate-restart.sh:restart; do
  name=${pair%:*} action=${pair#*:}
  # shellcheck disable=SC2016 # fixture expands these at execution time
  printf '#!/usr/bin/env bash\nprintf '\''%s %%s\\n'\'' "$*" >> "$CALL_LOG"\n' "$action" > "$FIXTURE/bin/$name"
done
for cli in agy cursor-agent claude codex pi; do
  # shellcheck disable=SC2016 # fixture expands CALL_LOG at execution time
  printf '#!/usr/bin/env bash\necho harness-launched >> "$CALL_LOG"\nexit 99\n' > "$FAKEBIN/$cli"
done
chmod +x "$FIXTURE/bin/fm-procevent.sh" "$FIXTURE/bin/fm-config-push.sh" "$FIXTURE/bin/fm-secondmate-restart.sh" "$FAKEBIN/"*

jq -n '{schema:"fm-lineup-board.v1",generated:"2026-01-01T00:00:00Z",quotas:[],rows:
  (["helm","backup_helm","secondmates","default"] | map({id:.,label:.,kind:.,current:[],
    suggested:[{harness:"codex",model:"fixture-model",effort:"high"}],
    options:[{harness:"codex",model:"fixture-model",effort:"high"}],reason:"Fixture catalog, quota unknown"}))
  + [{id:"tier.fixture",label:"Fixture tier",kind:"rule",rule_index:0,when:"Fixture tasks",current:[],
    suggested:[{harness:"agy",model:"gemini-fixture"}],options:[{harness:"agy",model:"gemini-fixture"},{harness:"cursor",model:"cursor-grok-fixture"}],reason:"Fixture option"}]}' > "$TMP_ROOT/board.json"
jq -n '{schema:"fm-lineup-apply.v1",instructions:"",dispatch:{rules:[{when:"Fixture tasks",why:"Retained provenance",use:{harness:"agy",model:"gemini-fixture"}}],default:{harness:"cursor",model:"cursor-grok-fixture"}},roles:{helm:{harness:"codex",model:"fixture-model",effort:"high"},backup_helm:{harness:"codex"},secondmates:{harness:"pi"}}}' > "$TMP_ROOT/apply.json"
refuse() {
  if "$BOARD" "$1" "$TMP_ROOT/bad.json" > "$TMP_ROOT/out" 2>&1; then fail "accepted invalid $2"; fi
  pass "refuses $2"
}
# JSON streams cannot masquerade as one valid board or configuration object.
for mode in build apply; do
  case "$mode" in build) file=board ;; apply) file=apply ;; esac
  cat "$TMP_ROOT/$file.json" "$TMP_ROOT/$file.json" > "$TMP_ROOT/bad.json"
  refuse "$mode" 'multiple JSON documents'
done
# Invalid offered tuples and primary roles are refused before serving the board.
for bad in agy cursor primary; do
  case "$bad" in
    agy) filter='.rows[-1].options += [{harness:"agy",model:"not-gemini"}]' ;;
    cursor) filter='.rows[-1].options += [{harness:"cursor",model:"not-allowlisted"}]' ;;
    primary) filter='.rows[0].options += [{harness:"agy",model:"gemini-fixture"}]' ;;
  esac
  jq "$filter" "$TMP_ROOT/board.json" > "$TMP_ROOT/bad.json"
  refuse build "offered $bad fence violation"
done
for filter in \
  '.rows[1].options += [{harness:"claude"}]' \
  '.rows[1].options += [{harness:"codex",effort:"max"}]' \
  '.rows[-1].options += [{harness:"opencode",effort:"high"}]' \
  '.rows[-1].options += [{harness:"kimi",effort:"low"}]'; do
  jq "$filter" "$TMP_ROOT/board.json" > "$TMP_ROOT/bad.json"
  refuse build 'unsupported successor or effort option'
done
[ ! -e "$FM_HOME/.lavish/model-lineup.html" ] || fail 'refused build published board'
# Every resolved role and profile, including later array candidates, is checked.
for filter in \
  '.dispatch.rules[0].use={harness:"agy",model:"wrong"}' \
  '.dispatch.default={harness:"cursor",model:"auto"}' \
  '.roles.helm={harness:"agy",model:"gemini-fixture"}' \
  '.roles.backup_helm={harness:"gemini"}' \
  '.roles.backup_helm={harness:"claude"}' \
  '.roles.backup_helm={harness:"codex",effort:"max"}' \
  '.roles.secondmates={harness:"muse"}' \
  '.roles.helm={harness:"kimi"}' \
  '.roles.secondmates={harness:"kimi",effort:"high"}' \
  '.dispatch.default={harness:"opencode",effort:"high"}' \
  '.roles.helm={harness:"pi",model:"fixture",effort:"ultra"}' \
  '.fallback_arrays=true | .dispatch.default=[.dispatch.default,{harness:"cursor",model:"wrong"}]'; do
  jq "$filter" "$TMP_ROOT/apply.json" > "$TMP_ROOT/bad.json"
  refuse apply 'resolved fence violation'
done
[ -z "$(ls -A "$FM_HOME/config")" ] || fail 'refusal touched config'
pass 'no config writes after refused apply'
# Changed allowlists are read at apply time, never remembered from the board.
printf 'cursor-allowed-*\n' > "$FM_HOME/config/cursor-model-allowlist"
cp "$TMP_ROOT/apply.json" "$TMP_ROOT/bad.json"
refuse apply 'changed Cursor allowlist'
rm "$FM_HOME/config/cursor-model-allowlist"
# Every provider option is validated, including an omitted AGY model.
jq '.rows[-1].options += [{harness:"agy"}]' "$TMP_ROOT/board.json" > "$TMP_ROOT/bad.json"
refuse build 'implicit AGY default'
# Instructions cannot be treated as already resolved without an explanation.
jq '.instructions="Use a different model"' "$TMP_ROOT/apply.json" > "$TMP_ROOT/bad.json"
refuse apply 'unresolved typed instructions'
# A real adapter arm occurs only after the stub Lavish listing proves open.
: > "$CALL_LOG"
jq '.rows[-1].reason="</script><script>bad()</script> & unicode ✓"' "$TMP_ROOT/board.json" > "$TMP_ROOT/injection.json"
"$BOARD" build "$TMP_ROOT/injection.json" > "$TMP_ROOT/build.out"
page=$("$BOARD" path)
sed -n '/<script id="lineup-data" type="application\/json">/,/<\/script>/p' "$page" | sed '1d;$d' > "$TMP_ROOT/extracted.json"
jq -e '.rows[-1].reason == "</script><script>bad()</script> & unicode ✓" and .benchmarks == []' "$TMP_ROOT/extracted.json" >/dev/null || fail 'JSON injection round trip failed'
if grep -q '<' "$TMP_ROOT/extracted.json"; then fail 'unescaped HTML in payload'; fi
sid=$("$FIXTURE/bin/fm-procevent-lavish.sh" source-id "$page")
grep -qF "register lavish $sid -- $FIXTURE/bin/fm-procevent-lavish.sh poll $page" "$CALL_LOG" || fail 'did not arm through adapter'
pass 'safe JSON injection and canonical Lavish wake arming'
jq '.rows[2].options += [{harness:"kimi",model:"kimi-fixture"}]' "$TMP_ROOT/board.json" > "$TMP_ROOT/kimi-board.json"
"$BOARD" build "$TMP_ROOT/kimi-board.json" > "$TMP_ROOT/build.out"
pass 'Kimi secondmate option is offered'
# An ended session must reopen; a session that stays ended never arms.
: > "$FM_HOME/ended"
"$BOARD" build "$TMP_ROOT/board.json" > "$TMP_ROOT/build.out"
grep -q 'session: reopened' "$TMP_ROOT/build.out" || fail 'did not reopen'
: > "$FM_HOME/refuse"
: > "$CALL_LOG"
if "$BOARD" build "$TMP_ROOT/board.json" > "$TMP_ROOT/out" 2>&1; then fail 'accepted dead session'; fi
if grep -q '^register ' "$CALL_LOG"; then fail 'armed ended session'; fi
rm "$FM_HOME/refuse"
pass 'serve-first reopen and refusal to arm an ended session'
# Cache evidence is private, validated, and injected; absent evidence stays empty.
printf '{"entries":[{"harness":"agy","model":"gemini-fixture","task":"tier.fixture","benchmark":"Fixture only","score":12.5,"source":"https://example.org/fixture","as_of":"2026-01-01"}]}\n' > "$FM_HOME/config/model-benchmarks.json"
"$BOARD" build "$TMP_ROOT/board.json" > "$TMP_ROOT/build.out"
node "$ROOT/tests/assets/lineup-board-harness.mjs" "$page" > "$TMP_ROOT/render.json"
jq -e '.scores | contains("Fixture only: 12.5") and contains("no public score")' "$TMP_ROOT/render.json" >/dev/null || fail 'benchmark rendering incorrect'
jq -e '.defaultRestart == false and .defaultFallback == false and .sent == 1 and .answer.instructions == "Typed override\nwith every character ✓" and .answer.rows[0].picks[0].harness == "codex"' "$TMP_ROOT/render.json" >/dev/null || fail 'submission defaults or typed instructions lost'
pass 'rendered benchmark evidence, missing scores, defaults, and full typed submission'
# Exercise the real adapter presentation, not only the browser's queued data.
node - "$TMP_ROOT/render.json" > "$TMP_ROOT/result" <<'JS'
const fs=require("fs"), c=JSON.parse(fs.readFileSync(process.argv[2],"utf8")).capture;
console.log('session:\n  status: feedback\n  session_ended: false\nprompts[1]{uid,prompt,selector,tag,text}:');
console.log('  '+[JSON.stringify("1"),JSON.stringify(c.prompt),JSON.stringify("form"),c.tag,JSON.stringify(c.text)].join(","));
JS
"$FIXTURE/bin/fm-procevent-lavish.sh" read "$TMP_ROOT/result" > "$TMP_ROOT/presented"
node - "$TMP_ROOT/presented" "$TMP_ROOT/render.json" <<'JS'
const fs=require("fs"),assert=require("assert");
const lines=fs.readFileSync(process.argv[2],"utf8").split("\n");
const row=lines.find(line=>line.startsWith('| {"schema":"fm-lineup-answer.v1"'));
assert(row,"Adapter read hid the lineup submission");
assert.deepStrictEqual(JSON.parse(row.slice(2)),JSON.parse(fs.readFileSync(process.argv[3],"utf8")).answer);
JS
pass 'real adapter read preserves all selected tuples and typed instructions'

# Successful apply preserves provenance and never restarts by default.
: > "$CALL_LOG"
"$BOARD" apply "$TMP_ROOT/apply.json" > "$TMP_ROOT/apply.out"
grep -q '^propagate ' "$CALL_LOG" || fail 'did not propagate'
if grep -q '^restart ' "$CALL_LOG"; then fail 'restarted by default'; fi
jq -e '.rules[0].when=="Fixture tasks" and .rules[0].why=="Retained provenance"' "$FM_HOME/config/crew-dispatch.json" >/dev/null || fail 'lost provenance'
grep -q '^helm-handover: NOT applied; running helm unchanged. Use the primary launch procedure with ' "$TMP_ROOT/apply.out" || fail 'missing explicit helm handover notice'
pass 'apply propagates, preserves provenance, and leaves restart off'
jq '.roles.secondmates={harness:"kimi",model:"kimi-fixture"}' "$TMP_ROOT/apply.json" > "$TMP_ROOT/kimi-apply.json"
"$BOARD" apply "$TMP_ROOT/kimi-apply.json" > "$TMP_ROOT/apply.out"
[ "$(cat "$FM_HOME/config/secondmate-harness")" = 'kimi kimi-fixture' ] || fail 'Kimi secondmate selection was not published'
pass 'Kimi remains selectable for secondmates'
cp "$FM_HOME/config/crew-dispatch.json" "$TMP_ROOT/before-dispatch"
cp "$FM_HOME/config/secondmate-harness" "$TMP_ROOT/before-secondmates"
cp "$FM_HOME/config/backup-helm-successor" "$TMP_ROOT/before-backup"
jq '.dispatch.rules[0].why="Lost provenance"' "$TMP_ROOT/apply.json" > "$TMP_ROOT/bad.json"
refuse apply 'rewritten provenance'
for pair in crew-dispatch.json:dispatch secondmate-harness:secondmates backup-helm-successor:backup; do
  cmp "$FM_HOME/config/${pair%:*}" "$TMP_ROOT/before-${pair#*:}" || fail 'partial write after refusal'
done
pass 'refused update preserves every prior file byte for byte'
# A publication failure after the first rename rolls all three files back.
export MV_REAL
MV_REAL=$(command -v mv)
cat > "$FAKEBIN/mv" <<'SH'
#!/usr/bin/env bash
set -eu
target=''
source=''
for arg in "$@"; do
  target=$arg
  case "$arg" in */.lineup.*/secondmate-harness) source=$arg ;; esac
done
if [ -n "$source" ] && [ "$target" = "$FM_HOME/config/secondmate-harness" ] && [ ! -e "$FM_HOME/mv-failed" ]; then
  : > "$FM_HOME/mv-failed"
  exit 1
fi
exec "$MV_REAL" "$@"
SH
chmod +x "$FAKEBIN/mv"
jq '.roles.secondmates={harness:"codex"} | .dispatch.default={harness:"codex"}' "$TMP_ROOT/apply.json" > "$TMP_ROOT/bad.json"
refuse apply 'interrupted multi-file publication'
for pair in crew-dispatch.json:dispatch secondmate-harness:secondmates backup-helm-successor:backup; do
  cmp "$FM_HOME/config/${pair%:*}" "$TMP_ROOT/before-${pair#*:}" || fail 'rollback did not restore prior bytes'
done
rm "$FAKEBIN/mv"
pass 'publication failure rolls back every file'
# Refusals still leave all pre-existing config intact for a bad late tuple.
jq '.dispatch.default={harness:"cursor",model:"invalid"}' "$TMP_ROOT/apply.json" > "$TMP_ROOT/bad.json"
refuse apply 'late tuple with existing configuration'
for pair in crew-dispatch.json:dispatch secondmate-harness:secondmates backup-helm-successor:backup; do
  cmp "$FM_HOME/config/${pair%:*}" "$TMP_ROOT/before-${pair#*:}" || fail 'refusal changed prior bytes'
done
# Explicit ordered fallbacks and explicit restart use the resolved list only.
jq '.fallback_arrays=true | .restart_secondmates=true | .restart_ids=["fixture-mate"] | .dispatch.default=[.dispatch.default,{harness:"codex",model:"fixture-model"}] | .instructions="Keep the chosen defaults" | .resolution="Instructions preserve the selected defaults"' "$TMP_ROOT/apply.json" > "$TMP_ROOT/explicit.json"
"$BOARD" apply "$TMP_ROOT/explicit.json" > "$TMP_ROOT/apply.out"
jq -e '.default | type=="array" and length==2' "$FM_HOME/config/crew-dispatch.json" >/dev/null || fail 'fallback array lost'
grep -q '^restart fixture-mate$' "$CALL_LOG" || fail 'explicit restart not called'
if grep -q harness-launched "$CALL_LOG"; then fail 'test launched a harness'; fi
pass 'explicit ordered fallbacks and restart are honored without launching harnesses'
