#!/usr/bin/env bash
# Tests for bin/fm-update.sh: fast-forward-only self-update of a running
# firstmate repo and every registered secondmate home.
#
# The guarantees under test mirror fm-fleet-sync.sh and prime directive #3:
#   - The running firstmate repo (on its default branch) fast-forwards from
#     origin; a leased secondmate home (detached HEAD on the default branch)
#     fast-forwards the same way.
#   - FAST-FORWARD ONLY: a dirty, diverged, offline, or wrong-branch target is
#     skipped and reported, never forced or stashed, so unlanded work survives.
#   - The update is a single-parent fast-forward (never a merge commit) and a
#     fast-forward of one worktree never disturbs another worktree's checkout
#     or the shared default branch.
#   - The caller-action summary is correct: reread-firstmate flips to yes only
#     when the instruction surface (AGENTS.md / bin / .agents/skills) changed, and
#     the two secondmate action sets are disjoint and correctly gated -
#     restart-secondmates carries EVERY live mate this pass left on origin's tip
#     whose recorded runtime can prove a restart, INCLUDING one that was already
#     there and one whose advance touched no instruction surface, because a
#     restart is also what re-resolves launch-time harness wiring; a live mate
#     whose runtime cannot prove a restart falls to nudge-secondmates; and a mate
#     whose home was skipped or whose endpoint is stopped gets no action at all.
#   - Secondmate homes resolve from both state/<id>.meta and the
#     data/secondmates.md registry, deduped, and the firstmate repo is never
#     re-processed as one of its own secondmates.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPDATE="$ROOT/bin/fm-update.sh"

# Deterministic, isolated git identity for fixture commits.
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-update-tests)

# Build a fresh world: a bare origin seeded with one commit, a firstmate repo
# clone checked out on main, and a home dir with state/ and data/. Echoes the
# world dir. Files seeded: AGENTS.md, README.md, bin/tool.sh, and an internal skill note.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data" "$w/fakebin" "$w/fake"
  : > "$w/fake/windows"
  cat > "$w/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  # The exact-window reads ask for ids alongside names.
  list-windows)
    case "$*" in
      *window_id*) awk '{ print "@" NR " " $0 }' "$FM_FAKE_DIR/windows" ;;
      *) cat "$FM_FAKE_DIR/windows" ;;
    esac ;;
  display-message)
    target=
    for arg in "$@"; do
      case "$arg" in
        main:fm-*) target=$arg ;;
        # Exact-window reads arrive by window id; map it back to the name.
        @*) target=main:$(sed -n "${arg#@}p" "$FM_FAKE_DIR/windows") ;;
      esac
    done
    case "${*: -1}" in
      *pane_current_command*)
        id=${target##*fm-}
        if [ -e "$FM_FAKE_DIR/dead-$id" ]; then printf 'zsh\n'; else printf 'claude\n'; fi
        ;;
      *) printf '\n' ;;
    esac
    ;;
esac
SH
  chmod +x "$w/fakebin/tmux"
  # Fresh watcher beacon keeps fm-guard quiet.
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null

  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'r1\n' > "$w/seed/README.md"
  mkdir -p "$w/seed/bin" "$w/seed/.agents/skills"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$w/seed/bin/fm-remote-secondmate-control.sh"
  chmod +x "$w/seed/bin/fm-remote-secondmate-control.sh"
  printf 's1\n' > "$w/seed/.agents/skills/note.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main

  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true

  printf '%s\n' "$w"
}

# Add a secondmate home as a DETACHED worktree of the firstmate repo (matching
# how treehouse leases a secondmate home), plus its state meta. Args: world id.
# The recorded runtime matters to the action split, so it is part of the fixture:
# harness defaults to a control-verified adapter on the default (tmux) backend,
# which is what makes a restart provable. Pass a backend to model one that cannot
# prove an agent stopped.
add_sm() {
  local w=$1 id=$2 harness=${3:-claude} backend=${4:-}
  git -C "$w/main" worktree add -q --detach "$w/$id" main
  {
    printf 'window=main:fm-%s\n' "$id"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s/%s\n' "$w" "$id"
    printf 'project=%s/%s\n' "$w" "$id"
    printf 'kind=secondmate\n'
    printf 'harness=%s\n' "$harness"
    [ -z "$backend" ] || printf 'backend=%s\n' "$backend"
    printf 'home=%s/%s\n' "$w" "$id"
  } > "$w/home/state/$id.meta"
  printf 'fm-%s\n' "$id" >> "$w/fake/windows"
  printf '%s\n' "$id" > "$w/$id/.fm-secondmate-home"
}

# Advance origin by one commit. mode=instr changes the whole instruction surface
# (AGENTS.md, bin, .agents/skills) plus README; mode=bin changes only bin/, which
# a running agent re-executes rather than holding; mode=readme changes only README.
bump_origin() {
  local w=$1 mode=$2
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'r-%s\n' "$mode" >> "$w/seed/README.md"
  if [ "$mode" = instr ]; then
    printf 'v2\n' > "$w/seed/AGENTS.md"
    printf 'echo b\n' > "$w/seed/bin/tool.sh"
    printf 's2\n' > "$w/seed/.agents/skills/note.md"
  fi
  if [ "$mode" = bin ]; then
    printf 'echo b-%s\n' "$RANDOM" > "$w/seed/bin/tool.sh"
  fi
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "bump-$mode"
  git -C "$w/seed" push -q origin main
}

run_update() {
  local w=$1
  PATH="$w/fakebin:$PATH" FM_FAKE_DIR="$w/fake" \
    FM_SSH_BIN="${FM_TEST_SSH_BIN:-ssh}" \
    FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>/dev/null
}

# --- T1: main + secondmate behind, instruction change; FF, not a merge ------
# Combines the former T1 (fast-forward + reread + nudge signalling) and T2
# (the advance is a single-parent fast-forward, never a merge commit) into one
# world so both contracts are proven against the same update run.
test_updates_main_and_secondmate() {
  local w out
  w=$(new_world t1)
  add_sm "$w" sm1
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "secondmate fast-forwarded"
  assert_contains "$out" "reread-firstmate: yes" "instruction change triggers reread"
  assert_contains "$out" "restart-secondmates: fm-sm1" "a changed AGENTS.md must move the secondmate into the restart set"
  assert_contains "$out" "nudge-secondmates: none" "a restarted secondmate must not also be nudged"

  # Fast-forward landed: HEAD == origin/main on both targets.
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/main" rev-parse origin/main)" ] \
    || fail "firstmate HEAD not at origin/main"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$(git -C "$w/sm1" rev-parse origin/main)" ] \
    || fail "secondmate HEAD not at origin/main"
  # Firstmate stays on its default branch; secondmate stays detached.
  [ "$(git -C "$w/main" symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
    || fail "firstmate left its default branch"
  git -C "$w/sm1" symbolic-ref -q HEAD >/dev/null \
    && fail "secondmate worktree is no longer detached"
  # A fast-forwarded tip has exactly one parent; a merge commit would have two.
  [ "$(git -C "$w/main" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "firstmate tip is not a single-parent fast-forward"
  [ "$(git -C "$w/sm1" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "secondmate tip is not a single-parent fast-forward"
  pass "T1 main + secondmate fast-forward (single-parent), reread + restart signalled"
}

# --- T3: README-only change does not trigger a reread ----------------------
test_reread_gate_is_instruction_only() {
  local w out
  w=$(new_world t3)
  add_sm "$w" sm1
  bump_origin "$w" readme

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate still advanced"
  assert_contains "$out" "reread-firstmate: no" "non-instruction change skips reread"
  # The running firstmate reads nothing new, but the mate's agent still holds its
  # launch-time wiring from before the pass, which only a restart re-resolves.
  assert_contains "$out" "restart-secondmates: fm-sm1" \
    "a live mate on the new tip must restart even when no instruction file moved"
  assert_contains "$out" "nudge-secondmates: none" "a restarted secondmate must not also be nudged"
  pass "T3 a non-instruction advance still restarts the live secondmate"
}

# --- T3b: a bin/-only advance restarts too ---------------------------------
# Helpers under bin/ do reload themselves on the next call, but the mate's agent
# still froze its launch-time harness wiring before this pass, so the restart is
# not redundant and the old bin/-only carve-out no longer applies.
test_bin_only_advance_restarts() {
  local w out
  w=$(new_world t3b)
  add_sm "$w" sm1
  bump_origin "$w" bin

  out=$(run_update "$w")

  assert_contains "$out" "reread-firstmate: yes" "a bin/ change is still an instruction-surface advance"
  assert_contains "$out" "restart-secondmates: fm-sm1" "a bin/-only advance must still restart the live mate"
  assert_contains "$out" "nudge-secondmates: none" "a restarted secondmate must not also be nudged"
  pass "T3b a bin/-only advance restarts the secondmate"
}

# --- T3c: an unverifiable runtime receives the fallback nudge ----------------
test_unprovable_runtime_gets_fallback_nudge() {
  local w out
  w=$(new_world t3c)
  # zellij has no recovery-grade agent-state classifier, so no restart there can
  # ever prove the old agent stopped and the replacement came up.
  add_sm "$w" sm1 claude zellij
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "restart-secondmates: none" "an unprovable runtime must stay out of the restart set"
  assert_contains "$out" "nudge-secondmates: fm-sm1" "an unverifiable runtime must retain the fallback re-read nudge"
  pass "T3c an unverifiable secondmate receives the fallback nudge"
}

# --- T3d: an already-stopped mate is left to startup recovery ---------------
test_dead_secondmate_gets_no_action() {
  local w out
  w=$(new_world t3d)
  add_sm "$w" sm1
  : > "$w/fake/dead-sm1"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: updated " "the stopped mate's safe checkout still advances"
  assert_contains "$out" "restart-secondmates: none" "a stopped mate must not be sent to restart"
  assert_contains "$out" "nudge-secondmates: none" "a stopped mate must not receive a queued nudge"
  pass "T3d an already-stopped secondmate is left to startup recovery"
}

# --- T3e: a legacy remote advance still restarts ---------------------------
# The host's instr= suffix is reporting detail; the parent no longer routes on it,
# so an older host that cannot report a diff can no longer suppress the restart.
test_legacy_remote_advance_restarts() {
  local w out fake_ssh
  w=$(new_world t3e)
  fake_ssh="$w/fakebin/fake-ssh"
  cat > "$fake_ssh" <<'SH'
#!/usr/bin/env bash
set -u
cat > /dev/null
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
shift 2
argv_b64=$4
decode() { printf '%s' "$1" | base64 --decode 2>/dev/null || printf '%s' "$1" | base64 -D; }
rargs=()
while IFS= read -r -d '' a; do rargs+=("$a"); done < <(decode "$argv_b64")
case "${rargs[1]:-}" in
  update) printf 'synced: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' ;;
  state) printf 'alive\n' ;;
  *) exit 91 ;;
esac
SH
  chmod +x "$fake_ssh"
  cat > "$w/home/state/sm1.meta" <<EOF
window=remote:sm1
endpoint_task_id=sm1
worktree=/srv/sm1
project=/srv/sm1
harness=claude
kind=secondmate
home=/srv/sm1
remote_host=remote-mac
remote_backend=herdr
EOF
  printf -- '- sm1 - remote domain (host: remote-mac; root: /srv/fm; home: /srv/sm1; scope: things; projects: p; added 2026-09-03)\n' \
    > "$w/home/data/secondmates.md"

  out=$(FM_TEST_SSH_BIN="$fake_ssh" run_update "$w")

  assert_contains "$out" "remote secondmate sm1: updated on remote-mac" \
    "the legacy remote advance was not accepted"
  assert_contains "$out" "restart-secondmates: fm-sm1" \
    "a live remote mate on the new tip must restart even when the host reports no instruction diff"
  assert_contains "$out" "nudge-secondmates: none" \
    "a restarted remote mate must not also be steered"
  pass "T3e a legacy remote advance still restarts the live remote mate"
}

test_current_updater_warns_about_prebinding_workers() {
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found for pre-binding Herdr worker warnings"; return; }
  local w id state out real_git warnings original_records checkout
  w=$(new_world prebinding)
  real_git=$(command -v git)
  add_sm "$w" sm1
  mkdir -p "$w/sm1/state"
  # The seed predates the real ignore rules. Keep fixture state untracked.
  printf '/state/\n' >> "$(git -C "$w/main" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
  for id in main-live home-live missing unreadable unusable bound remote secondmate kindless ambiguous-kind; do
    state="$w/home/state"
    [ "$id" != home-live ] || state="$w/sm1/state"
    fm_write_meta "$state/$id.meta" "window=update-herdr:w1:p-$id" \
      "backend=herdr" "harness=claude" "worktree=$w/seed" "project=$w/seed" \
      "herdr_session=update-herdr" "herdr_workspace_id=w1" "herdr_tab_id=w1:t1" "herdr_pane_id=w1:p-$id"
    case "$id" in
      home-live) printf 'kind=scout\n' ;;
      secondmate) printf 'kind=secondmate\n' ;;
      kindless) ;;
      ambiguous-kind) printf 'kind=ship\nkind=scout\n' ;;
      *) printf 'kind=ship\n' ;;
    esac >> "$state/$id.meta"
    [ "$id" = main-live ] || printf 'endpoint_task_id=%s\n' "$id" >> "$state/$id.meta"
  done
  printf 'herdr_pane_id=w1:p-ambiguous\n' >> "$w/home/state/unusable.meta"
  printf 'herdr_terminal_id=term-bound\n' >> "$w/home/state/bound.meta"
  printf 'remote_host=another-host\n' >> "$w/home/state/remote.meta"
  original_records=$(cksum "$w/home/state/"*.meta "$w/sm1/state/home-live.meta")
  cat > "$w/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
case "$*" in
  'pane get w1:p-main-live --session update-herdr'|'pane get w1:p-home-live --session update-herdr')
    printf '%s\n' "$3" >> "$FM_FAKE_DIR/herdr-calls"
    if [ "${FM_TEST_PROBE_CHECKOUT_CHANGES:-0}" = 1 ]; then
      case "$3" in
        w1:p-main-live) "$FM_TEST_REAL_GIT" -C "$FM_ROOT_OVERRIDE" checkout -qb probe-branch ;;
        w1:p-home-live) printf 'edit during Herdr probe\n' >> "${FM_ROOT_OVERRIDE%/*}/sm1/AGENTS.md" ;;
      esac
    fi
    if [ "${FM_TEST_PROBE_ADVANCE_REFS:-0}" = 1 ]; then
      case "$3" in
        w1:p-main-live)
          "$FM_TEST_REAL_GIT" -C "${FM_ROOT_OVERRIDE%/*}/seed" push -q origin main
          "$FM_TEST_REAL_GIT" -C "$FM_ROOT_OVERRIDE" fetch -q origin
          ;;
        w1:p-home-live)
          "$FM_TEST_REAL_GIT" -C "${FM_ROOT_OVERRIDE%/*}/sm1" merge -q --ff-only origin/main
          ;;
      esac
    fi
    printf '{"result":{"pane":{"pane_id":"%s","foreground_cwd":"/unrelated","agent":null}}}\n' "$3"
    ;;
  'pane get w1:p-missing --session update-herdr')
    printf '%s\n' "$3" >> "$FM_FAKE_DIR/herdr-calls"
    printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2; exit 1 ;;
  'pane get w1:p-unreadable --session update-herdr')
    printf '%s\n' "$3" >> "$FM_FAKE_DIR/herdr-calls"
    printf '%s\n' '{"error":{"code":"server_not_running"}}' >&2; exit 1 ;;
  *) printf 'unexpected:%s\n' "$*" >> "$FM_FAKE_DIR/herdr-calls"; exit 92 ;;
esac
SH
  cat > "$w/fakebin/git" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${FM_REMOTE_JOB_ACTIVE:-}" != 1 ] &&
  [ "${1:-}" = -C ] && [ "${3:-}" = merge ] && [ "${4:-}" = --ff-only ]; then
  case "${2##*/}" in
    main) label=firstmate; id=main-live ;;
    sm1) label="secondmate sm1"; id=home-live ;;
    *) exit 92 ;;
  esac
  grep -Fq "warning: $label: pre-binding Herdr worker record $id points to existing pane update-herdr:w1:p-$id. Pane ownership still needs verification." "$FM_FAKE_DIR/update.stderr" ||
    { printf 'warning was absent at the fast-forward for %s\n' "$label" >&2; exit 93; }
fi
exec "$FM_TEST_REAL_GIT" "$@"
SH
  chmod +x "$w/fakebin/herdr" "$w/fakebin/git"
  local -a update_env=(env "PATH=$w/fakebin:$PATH" "FM_FAKE_DIR=$w/fake"
    "FM_TEST_REAL_GIT=$real_git" "FM_ROOT_OVERRIDE=$w/main")
  bump_origin "$w" readme
  out=$("${update_env[@]}" FM_HOME="$w/home" "$UPDATE" 2> "$w/fake/update.stderr")
  warnings=$(cat "$w/fake/update.stderr")
  assert_contains "$warnings" "warning: firstmate: pre-binding Herdr worker record main-live points to existing pane update-herdr:w1:p-main-live" "primary warning missing"
  assert_contains "$warnings" "warning: secondmate sm1: pre-binding Herdr worker record home-live points to existing pane update-herdr:w1:p-home-live" "secondmate warning missing"
  assert_not_contains "$warnings" " missing" "a missing pane produced a worker warning"
  assert_not_contains "$warnings" " unreadable" "an inconclusive pane query produced a worker warning"
  assert_not_contains "$warnings" " unusable" "ambiguous pane metadata produced a worker warning"
  assert_contains "$warnings" "manual recovery procedure in docs/herdr-backend.md" "warning omitted the recovery procedure"
  assert_contains "$out" "firstmate: updated " "warning blocked primary update"
  assert_contains "$out" "secondmate sm1: updated " "warning blocked secondmate update"
  [ "$(cat "$w/fake/herdr-calls")" = $'w1:p-main-live\nw1:p-missing\nw1:p-unreadable\nw1:p-home-live' ] ||
    fail "update did not use read-only Herdr probes before advancing each checkout"
  [ "$(cksum "$w/home/state/"*.meta "$w/sm1/state/home-live.meta")" = "$original_records" ] ||
    fail "update warning changed the worker records"
  pass "Pre-binding Herdr warnings precede both local fast-forwards and leave records intact"

  add_sm "$w" sm2
  mkdir -p "$w/main/state" "$w/sm2/state"
  mv "$w/home/state/sm2.meta" "$w/main/state/sm2.meta"
  cp "$w/home/state/main-live.meta" "$w/main/state/main-live.meta"
  cp "$w/sm1/state/home-live.meta" "$w/sm2/state/home-live.meta"
  : > "$w/fake/herdr-calls"
  bump_origin "$w" readme
  local remote_tip
  remote_tip=$(git -C "$w/seed" rev-parse HEAD)
  out=$("${update_env[@]}" FM_HOME="$w/sm1" FM_REMOTE_JOB_ACTIVE=1 \
    "$ROOT/bin/fm-remote-secondmate-control.sh" update sm1 2>&1)
  [ "$out" = "synced: $remote_tip instr=" ] || fail "remote update changed its success response: $out"
  [ ! -s "$w/fake/herdr-calls" ] || fail "remote update probed pre-binding Herdr workers"
  for checkout in main sm1 sm2; do
    [ "$(git -C "$w/$checkout" rev-parse HEAD)" = "$remote_tip" ] || fail "remote update missed $checkout"
  done
  pass "Remote update advances its homes without probing Herdr or changing the verdict"

  bump_origin "$w" readme
  printf 'instructions published during probe\n' >> "$w/seed/AGENTS.md"
  git -C "$w/seed" commit -qam 'refresh instructions'
  local expected_tip
  expected_tip=$(git -C "$w/seed" rev-parse HEAD)
  out=$("${update_env[@]}" FM_HOME="$w/home" FM_TEST_PROBE_ADVANCE_REFS=1 \
    "$UPDATE" 2> "$w/fake/update.stderr")
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$expected_tip" ] || fail "primary missed the newly fetched target"
  assert_contains "$out" "(instructions changed: AGENTS.md)" "update reported the instruction diff from the old target"
  assert_contains "$out" "reread-firstmate: yes" "the newly fetched instructions were not queued for re-read"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$expected_tip" ] || fail "concurrent secondmate advance did not reach the target"
  assert_contains "$out" "secondmate sm1: already current" "a concurrent fast-forward was reported as a new update"
  assert_contains "$out" "restart-secondmates: fm-sm1" "the already-current secondmate was not queued for restart"
  pass "The updater uses the commits visible after the Herdr probe"

  local main_before home_before
  main_before=$(git -C "$w/main" rev-parse HEAD)
  home_before=$(git -C "$w/sm1" rev-parse HEAD)
  bump_origin "$w" readme
  out=$("${update_env[@]}" FM_HOME="$w/home" FM_TEST_PROBE_CHECKOUT_CHANGES=1 \
    "$UPDATE" 2> "$w/fake/update.stderr")
  assert_contains "$out" "firstmate: skipped: on probe-branch, expected main" "branch change during the probe was missed"
  assert_contains "$out" "secondmate sm1: skipped: dirty working tree" "edit during the probe was missed"
  assert_contains "$out" "restart-secondmates: none" "a skipped home was queued for restart"
  assert_contains "$out" "nudge-secondmates: none" "a skipped home was queued for a nudge"
  [ "$(git -C "$w/main" rev-parse probe-branch)" = "$main_before" ] || fail "the new branch advanced"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$home_before" ] || fail "the newly dirty checkout advanced"
  assert_contains "$(cat "$w/sm1/AGENTS.md")" "edit during Herdr probe" "the new edit was lost"
  pass "The updater skips checkouts that change branches or become dirty during the Herdr probe"
}

# --- T4: dirty secondmate is skipped, its edit preserved -------------------
test_dirty_secondmate_skipped() {
  local w out
  w=$(new_world t4)
  add_sm "$w" sm1
  bump_origin "$w" instr
  printf 'uncommitted local edit\n' >> "$w/sm1/AGENTS.md"

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: dirty working tree" "dirty home skipped"
  assert_not_contains "$out" "fm-sm1" "skipped secondmate is not nudged"
  grep -q 'uncommitted local edit' "$w/sm1/AGENTS.md" \
    || fail "dirty edit was discarded"
  pass "T4 dirty secondmate skipped, local edit preserved"
}

# --- T5: diverged secondmate is skipped, its commit preserved --------------
test_diverged_secondmate_skipped() {
  local w out before
  w=$(new_world t5)
  add_sm "$w" sm1
  # Local commit on the secondmate's detached HEAD makes it diverge from origin.
  printf 'fork work\n' > "$w/sm1/AGENTS.md"
  git -C "$w/sm1" add -A
  git -C "$w/sm1" commit -qm local-work
  before=$(git -C "$w/sm1" rev-parse HEAD)
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: diverged from origin/main" "diverged home skipped"
  assert_not_contains "$out" "fm-sm1" "diverged secondmate is not nudged"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$before" ] \
    || fail "diverged secondmate HEAD moved (unlanded work at risk)"
  pass "T5 diverged secondmate skipped, local commit preserved"
}

# --- T6: the git side is idempotent; the restart set is not -----------------
# This is the SSHHIP case: that mate's home was already at the target commit, so
# the old classifier skipped it entirely and its agent kept running the launch-time
# wiring it started with. An already-current live mate must still be restarted.
test_already_current_secondmate_still_restarts() {
  local w out restart_line
  w=$(new_world t6)
  add_sm "$w" sm1
  bump_origin "$w" instr
  run_update "$w" >/dev/null   # first run advances both

  out=$(run_update "$w")       # second run: nothing left to fast-forward

  assert_contains "$out" "firstmate: already current" "firstmate already current"
  assert_contains "$out" "secondmate sm1: already current" "secondmate already current"
  assert_contains "$out" "reread-firstmate: no" "no reread when nothing changed"
  restart_line=$(printf '%s\n' "$out" | grep '^restart-secondmates:')
  assert_contains "$restart_line" "fm-sm1" \
    "an already-current live secondmate must still be in the restart set"
  assert_contains "$out" "nudge-secondmates: none" "a restarted secondmate must not also be nudged"
  pass "T6 an already-current live secondmate is still restarted"
}

# --- T6b: an already-current mate that cannot be restarted stays honest -----
# Unconditional restart must not become an unconditional CLAIM of one.
test_already_current_unprovable_mate_is_nudged() {
  local w out restart_line nudge_line
  w=$(new_world t6b)
  add_sm "$w" sm1 claude zellij
  bump_origin "$w" instr
  run_update "$w" >/dev/null   # first run advances both

  out=$(run_update "$w")       # second run: the home is already on the tip

  assert_contains "$out" "secondmate sm1: already current" "the mate must need no advance"
  restart_line=$(printf '%s\n' "$out" | grep '^restart-secondmates:')
  nudge_line=$(printf '%s\n' "$out" | grep '^nudge-secondmates:')
  assert_not_contains "$restart_line" "sm1" "an unprovable runtime must stay out of the restart set"
  assert_contains "$nudge_line" "fm-sm1" "an unprovable runtime must keep the honest re-read steer"
  pass "T6b an already-current mate with an unprovable runtime is steered, not claimed as reloaded"
}

# --- T7: registry backstop + dedup + self-exclusion, one world -------------
# One world carries every secondmate-resolution edge at once:
#   reg1 - registered in secondmates.md only, NO live meta (registry backstop);
#   sm1  - present in BOTH meta and the registry (must be processed exactly once);
#   selfish - a bogus registry line pointing the firstmate repo at itself.
# Asserts: reg1 advances but is NOT nudged (no live metadata); sm1 advances,
# is processed once, and IS nudged; the firstmate repo is never re-processed.
test_registry_backstop_dedup_and_self_exclusion() {
  local w out count
  w=$(new_world t7)
  add_sm "$w" sm1
  git -C "$w/main" worktree add -q --detach "$w/reg1" main
  printf 'reg1\n' > "$w/reg1/.fm-secondmate-home"
  {
    printf -- '- reg1 - domain supervisor (home: %s/reg1; scope: things; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- sm1 - dup (home: %s/sm1; scope: x; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- selfish - self (home: %s/main; scope: x; projects: p; added 2026-06-23)\n' "$w"
  } > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate reg1: updated " "registry-only secondmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "meta+registry secondmate fast-forwarded"
  count=$(printf '%s\n' "$out" | grep -c '^secondmate sm1:' || true)
  [ "$count" -eq 1 ] || fail "secondmate sm1 processed $count times, expected 1 (dedup across meta+registry)"
  assert_not_contains "$out" "secondmate selfish" "firstmate repo re-processed as its own secondmate"
  # sm1 has live metadata, so it is nudged; reg1 has none, so it is not. Pin the
  # nudge line exactly and confirm reg1 is absent from it (not from the whole
  # output, where 'secondmate reg1: updated' legitimately appears).
  local nudge_line
  nudge_line=$(printf '%s\n' "$out" | grep '^nudge-secondmates:')
  local restart_line
  restart_line=$(printf '%s\n' "$out" | grep '^restart-secondmates:')
  assert_contains "$restart_line" "fm-sm1" "live-meta secondmate is restarted"
  assert_not_contains "$restart_line" "reg1" "registry-only secondmate without live metadata gets no action"
  assert_not_contains "$nudge_line" "sm1" "a restarted secondmate must not also be nudged"
  assert_not_contains "$nudge_line" "reg1" "registry-only secondmate without live metadata is not nudged"
  pass "T7 registry backstop resolves, dedups meta+registry, excludes the firstmate repo"
}

# --- T9: firstmate repo on a feature branch is skipped ---------------------
test_firstmate_wrong_branch_skipped() {
  local w out before
  w=$(new_world t9)
  bump_origin "$w" instr
  # Simulate firstmate mid-shipping its own change: not on the default branch.
  git -C "$w/main" checkout -q -b feature/wip
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: on feature/wip, expected main" "off-default firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "skipped firstmate HEAD moved"
  pass "T9 firstmate off its default branch is skipped, not forced"
}

test_firstmate_detached_head_skipped() {
  local w out before
  w=$(new_world t10)
  bump_origin "$w" instr
  git -C "$w/main" checkout -q --detach HEAD
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: detached HEAD, expected main" "detached firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when detached firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "detached firstmate HEAD moved"
  pass "T10 firstmate detached HEAD is skipped"
}

test_unsafe_secondmate_home_skipped_before_git_update() {
  local w out bad before
  w=$(new_world t11)
  bad="$w/home/projects/bad"
  mkdir -p "$w/home/projects"
  git clone -q "$w/origin.git" "$bad"
  printf 'bad\n' > "$bad/.fm-secondmate-home"
  before=$(git -C "$bad" rev-parse HEAD)
  printf -- '- bad - bad home (home: %s; scope: x; projects: p; added 2026-06-23)\n' \
    "$bad" > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate bad: skipped: unsafe home: secondmate home cannot be inside the active firstmate home" \
    "unsafe project-like home skipped"
  assert_contains "$out" "nudge-secondmates: none" "unsafe home is not nudged"
  [ "$(git -C "$bad" rev-parse HEAD)" = "$before" ] \
    || fail "unsafe secondmate home HEAD moved"
  pass "T11 unsafe secondmate home is not fast-forwarded"
}

test_updates_main_and_secondmate
test_reread_gate_is_instruction_only
test_bin_only_advance_restarts
test_unprovable_runtime_gets_fallback_nudge
test_dead_secondmate_gets_no_action
test_legacy_remote_advance_restarts
test_current_updater_warns_about_prebinding_workers
test_dirty_secondmate_skipped
test_diverged_secondmate_skipped
test_already_current_secondmate_still_restarts
test_already_current_unprovable_mate_is_nudged
test_registry_backstop_dedup_and_self_exclusion
test_firstmate_wrong_branch_skipped
test_firstmate_detached_head_skipped
test_unsafe_secondmate_home_skipped_before_git_update

echo "# all fm-update tests passed"
