#!/usr/bin/env bash
# Behavior tests for bin/fm-system-state-card.sh.
# Drive the generator; never assert implementation-source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CARD="$ROOT/bin/fm-system-state-card.sh"
TMP_ROOT=$(fm_test_tmproot fm-system-state-card)
fm_git_identity fmtest fmtest@example.invalid
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$home"
}

make_git_repo() {  # <dir> <message>
  local dir=$1 msg=$2
  mkdir -p "$dir"
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m "$msg"
}

make_fake_curl() {
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
url="" write_code=0
while [ $# -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    -w)
      case "$2" in
        *http_code*) write_code=1 ;;
      esac
      shift 2
      ;;
    --connect-timeout|--max-time|-m) shift 2 ;;
    -s|-S) shift ;;
    http://*|https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  */health)
    if [ "$write_code" -eq 1 ]; then
      printf '200'
    else
      printf '%s' '{"status":"ok","revision":"abc123def","environment":"production","backgroundJobs":{"globalHold":false},"jobs_count":4,"urgentCaptainAlertsEnabled":true}'
    fi
    ;;
  *tent*)
    [ "$write_code" -eq 1 ] && printf '200' || true
    ;;
  *:5173*)
    [ "$write_code" -eq 1 ] && printf '200' || true
    ;;
  *)
    [ "$write_code" -eq 1 ] && printf '000' || true
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/curl"
}

header_field() {  # <key> <file>
  awk -F': ' -v k="$1" '$0 ~ "^" k ":" { print $2; exit }' "$2"
}

run_card() {
  local home=$1
  shift
  FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    FM_SYSTEM_STATE_NOW=2026-09-18T22:00:00Z \
    FM_SYSTEM_STATE_HOST=testhost \
    FM_SYSTEM_STATE_S_ROOT="$home/s-root" \
    FM_SYSTEM_STATE_VAULT_ROOT="$home/vault" \
    FM_SYSTEM_STATE_PACKET_ROUTER_ROOT="$home/packet-router" \
    FM_SYSTEM_STATE_RAKAZO_GIT="$home/projects/rakazo" \
    FM_SYSTEM_STATE_CONTINUUM_MAIN_GIT="$home/projects/continuum-main" \
    FM_SYSTEM_STATE_CONTINUUM_UI_GIT="$home/projects/continuum-ui" \
    FM_SYSTEM_STATE_NORTHSTAR_PATH="$home/vault/01_Charter/Northstar.md" \
    FM_SYSTEM_STATE_CONTINUUM_HEALTH_URL=http://127.0.0.1:9/health \
    FM_SYSTEM_STATE_TENT_URL=http://127.0.0.1:9/tent \
    FM_SYSTEM_STATE_RAKAZO_HEALTH_URL=http://127.0.0.1:9/health \
    FM_SYSTEM_STATE_RAKAZO_UI_URL=http://127.0.0.1:9/ui \
    FM_SYSTEM_STATE_CURL_MAX_TIME=1 \
    "$@"
}

test_pointer_absent() {
  local home out
  home=$(make_home pointer-absent)
  out=$(run_card "$home" "$CARD" --pointer)
  assert_contains "$out" "status=absent" "absent card pointer must say absent"
  assert_contains "$out" "do not browse Atlas" "pointer must steer agents off Atlas"
  pass "pointer reports absent when data/system-state.md is missing"
}

test_generate_writes_header_and_sections() {
  local home out card lines
  home=$(make_home generate-basic)
  mkdir -p "$home/s-root/ui-dist/assets" "$home/vault" "$home/packet-router/registry"
  printf 'index-TESTBUNDLE.js\n' > "$home/s-root/ui-dist/assets/index-TESTBUNDLE.js"
  make_git_repo "$home/s-root" "s head"
  make_git_repo "$home/vault" "vault commit"
  make_git_repo "$home/projects/rakazo" "rakazo head"
  make_git_repo "$home/projects/continuum-main" "continuum main merged (#103)"
  make_git_repo "$home/projects/continuum-ui" "ui bundle"
  printf '%s\n' '{"default":{"harness":"cursor","model":"cursor-grok-4.6-high"}}' \
    > "$home/config/crew-dispatch.json"
  printf '%s\n' 'cursor cursor-grok-4.6-high' > "$home/config/secondmate-harness"
  printf '%s\n' '# Shared' '' '## Provider routing (current)' '- Crew: Cursor Grok only.' \
    > "$home/data/captain-shared.md"
  printf '%s\n' '## Queued' '- [ ] freeze-hold - wait (hold-kind: captain) (hold: Codex until Friday)' \
    > "$home/data/backlog.md"
  printf '%s\n' '# seats' '| role | hand | fallback |' '| eleusis | rakazo-eleusis | grokbot |' \
    > "$home/packet-router/registry/SEATS.md"
  printf '%s\n' 'LOCK line 2026-09-18' > "$home/packet-router/wake-log.md"

  fakebin=$(fm_fakebin "$home")
  make_fake_curl "$fakebin"
  out=$(PATH="$fakebin:$BASE_PATH" run_card "$home" "$CARD" --no-inherit --no-packet)
  expect_code 0 $? "generate should exit 0"
  [ "$out" = "$home/data/system-state.md" ] || fail "generate should print the card path, got: $out"
  card="$home/data/system-state.md"
  assert_present "$card" "card was not written"
  lines=$(wc -l < "$card" | tr -d ' ')
  [ "$lines" -le 80 ] || fail "card exceeded 80 lines ($lines)"
  [ "$(header_field version "$card")" = "2026-09-18T22:00:00Z" ] \
    || fail "version header mismatch"
  [ "$(header_field ttl "$card")" = "60m" ] || fail "ttl header mismatch"
  assert_grep "generator: bin/fm-system-state-card.sh host=testhost" "$card" "missing generator host"
  assert_grep "sha256: " "$card" "missing sha256"
  assert_grep "## Live revisions" "$card" "missing live revisions"
  assert_grep "revision=abc123def" "$card" "health revision not copied from probe"
  assert_grep "index-TESTBUNDLE.js" "$card" "ui bundle not listed"
  assert_grep "## Runtime flags" "$card" "missing runtime flags"
  assert_grep "globalHold: false" "$card" "globalHold not copied from probe"
  assert_grep "tent_http: 200" "$card" "tent probe missing"
  assert_grep "## Routing and model rules" "$card" "missing routing section"
  assert_grep 'cursor-grok-4.6-high' "$card" "crew-dispatch text was not copied"
  assert_grep "Crew: Cursor Grok only." "$card" "provider routing was paraphrased or dropped"
  assert_grep "## Active holds and freezes" "$card" "missing holds"
  assert_grep "freeze-hold" "$card" "captain hold was not listed"
  assert_grep "## Where each SoT lives" "$card" "missing SoT map"
  assert_grep "secrets: 1Password" "$card" "SoT map missing secrets row"
  assert_grep "## Recent changes (7d)" "$card" "missing recent changes"
  assert_grep "## Do-not-browse" "$card" "missing do-not-browse"
  assert_grep "do not walk C:\\continuum-system" "$card" "do-not-browse missing vault stop"
  pass "generate writes a bounded card with scout section order and copied routing"
}

test_pointer_fresh_and_stale() {
  local home out
  home=$(make_home pointer-ttl)
  mkdir -p "$home/data"
  cat > "$home/data/system-state.md" <<'EOF'
# SYSTEM_STATE
version: 2026-09-18T20:00:00Z
generated_at: 2026-09-18T20:00:00Z
ttl: 60m
generator: bin/fm-system-state-card.sh host=testhost
sha256: abcdef

## Do-not-browse
stop
EOF
  out=$(FM_SYSTEM_STATE_TTL_SECS=3600 run_card "$home" "$CARD" --pointer)
  assert_contains "$out" "status=stale" "a card older than TTL must be stale"
  assert_contains "$out" "sha256=abcdef" "pointer must include sha256"
  cat > "$home/data/system-state.md" <<'EOF'
# SYSTEM_STATE
version: 2099-01-01T00:00:00Z
generated_at: 2099-01-01T00:00:00Z
ttl: 60m
generator: bin/fm-system-state-card.sh host=testhost
sha256: fedcba

## Do-not-browse
stop
EOF
  out=$(run_card "$home" "$CARD" --pointer)
  assert_contains "$out" "status=fresh" "a future generated_at must count as fresh"
  pass "pointer reports stale vs fresh from generated_at and TTL"
}

test_packet_and_inherit() {
  local home inbox mate packet card_copy
  home=$(make_home publish)
  inbox="$home/router/inbox/new"
  mate="$TMP_ROOT/sm-home"
  mkdir -p "$inbox" "$mate/data" "$home/s-root" "$home/vault" "$home/packet-router"
  printf '%s\n' "$inbox" > "$home/config/packet-router-inbox"
  printf '%s\n' "- sm-x - Own x. (home: $mate; scope: x; projects: alpha; added 2026-09-13)" \
    > "$home/data/secondmates.md"
  printf '%s\n' "- sm-remote - Own r. (host: dellserve-fm; root: /tmp/root; home: /tmp/missing-sm; scope: r; projects: gnhf; added 2026-09-14)" \
    >> "$home/data/secondmates.md"
  fakebin=$(fm_fakebin "$home")
  make_fake_curl "$fakebin"
  PATH="$fakebin:$BASE_PATH" run_card "$home" "$CARD" --rakazo-pointer >/dev/null
  packet=$(find "$inbox" -name 'pkt-system-state-*.md' | head -1)
  [ -n "$packet" ] || fail "configured inbox did not receive a SYSTEM_STATE packet"
  assert_grep "role_target: eleusis" "$packet" "packet must target eleusis"
  assert_grep "SYSTEM_STATE.md" "$packet" "packet must name the Evidence C: target"
  assert_grep "named C: target" "$packet" "packet must declare the named C: write"
  assert_grep "# SYSTEM_STATE" "$packet" "packet must carry the card body"
  assert_grep "Locked patch path" "$packet" "--rakazo-pointer must ask for Atlas/Eleusis pointer"
  assert_grep "bots.instructions" "$packet" "rakazo pointer must name instructions"
  card_copy="$mate/data/system-state.md"
  assert_present "$card_copy" "local secondmate home did not inherit the card"
  assert_grep "sha256: " "$card_copy" "inherited card missing identity"
  [ ! -f /tmp/missing-sm/data/system-state.md ] \
    || fail "remote/missing secondmate home should not be created"
  pass "Eleusis packet and local secondmate inherit publish the same card"
}

test_no_packet_without_inbox() {
  local home
  home=$(make_home no-inbox)
  mkdir -p "$home/s-root" "$home/vault" "$home/packet-router"
  fakebin=$(fm_fakebin "$home")
  make_fake_curl "$fakebin"
  PATH="$fakebin:$BASE_PATH" run_card "$home" "$CARD" --no-inherit --rakazo-pointer >/dev/null
  assert_present "$home/data/system-state.md" "card still writes without an inbox"
  pass "unconfigured Packet Router inbox is a silent no-op"
}

test_stdout_no_write() {
  local home out
  home=$(make_home stdout)
  mkdir -p "$home/s-root" "$home/vault" "$home/packet-router"
  fakebin=$(fm_fakebin "$home")
  make_fake_curl "$fakebin"
  out=$(PATH="$fakebin:$BASE_PATH" run_card "$home" "$CARD" --stdout --no-write --no-inherit --no-packet)
  [ ! -f "$home/data/system-state.md" ] || fail "--no-write must not create the card"
  assert_contains "$out" "# SYSTEM_STATE" "--stdout must print the card"
  assert_contains "$out" "## Do-not-browse" "--stdout card must include do-not-browse"
  pass "--stdout --no-write prints a card without touching data/"
}

test_pointer_cannot_combine() {
  local home rc
  home=$(make_home pointer-combo)
  run_card "$home" "$CARD" --pointer --stdout >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "--pointer with generate flags must be usage"
  pass "--pointer refuses generate flags"
}

test_do_not_browse_survives_long_routing() {
  local home card lines i repo
  home=$(make_home huge-routing)
  mkdir -p "$home/s-root" "$home/vault" "$home/packet-router" \
    "$home/projects/rakazo" "$home/projects/continuum-main" "$home/projects/continuum-ui"
  awk 'BEGIN { print "{"; for (i = 1; i <= 40; i++) printf "  \"k%s\": %s,\n", i, i; print "  \"z\": 0\n}" }' \
    > "$home/config/crew-dispatch.json"
  {
    printf '%s\n' '# Shared' '' '## Provider routing (current)'
    i=1
    while [ "$i" -le 20 ]; do
      printf '%s\n' "- routing line $i copied verbatim for overflow coverage"
      i=$((i + 1))
    done
  } > "$home/data/captain-shared.md"
  {
    printf '%s\n' '## Queued'
    i=1
    while [ "$i" -le 12 ]; do
      printf '%s\n' "- [ ] hold-$i - wait (hold-kind: captain) (hold: freeze $i)"
      i=$((i + 1))
    done
  } > "$home/data/backlog.md"
  for repo in "$home/s-root" "$home/vault" "$home/projects/rakazo" \
    "$home/projects/continuum-main" "$home/projects/continuum-ui"; do
    make_git_repo "$repo" "init $repo"
    i=1
    while [ "$i" -le 5 ]; do
      git -C "$repo" commit -q --allow-empty -m "recent change $i"
      i=$((i + 1))
    done
  done
  fakebin=$(fm_fakebin "$home")
  make_fake_curl "$fakebin"
  PATH="$fakebin:$BASE_PATH" run_card "$home" "$CARD" --no-inherit --no-packet >/dev/null
  card="$home/data/system-state.md"
  lines=$(wc -l < "$card" | tr -d ' ')
  [ "$lines" -le 80 ] || fail "oversized routing produced $lines-line card"
  assert_grep "## Do-not-browse" "$card" "do-not-browse was truncated away"
  assert_grep "do not walk C:\\continuum-system" "$card" "do-not-browse body was lost"
  pass "do-not-browse survives when earlier sections would overflow the line cap"
}

test_pointer_absent
test_generate_writes_header_and_sections
test_pointer_fresh_and_stale
test_packet_and_inherit
test_no_packet_without_inbox
test_stdout_no_write
test_pointer_cannot_combine
test_do_not_browse_survives_long_routing

echo "# fm-system-state-card.test.sh: all assertions passed"
