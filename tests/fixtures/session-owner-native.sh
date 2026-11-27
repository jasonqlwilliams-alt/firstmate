# Shared test setup for the Pi and omp fake extension adapters. The test scripts
# provide the family-specific module dependencies and disposable directories.
exercise_native_owner() {
  local family=$1 repo=$2 home=$3 file out
  mkdir -p "$home/config" "$home/state"
  printf 'launch-v1\n' > "$home/config/session-lock-owner"
  git init -q "$repo" || return 1
  : > "$repo/AGENTS.md"
  for file in fm-lock.sh fm-session-owner-publish.mjs fm-session-lock-lib.sh     fm-session-lock-record-lib.sh fm-cursor-lib.sh fm-wake-lib.sh fm-sessionstart-run.sh     fm-gate-refuse-lib.sh fm-primary-scope-lib.sh fm-hook-host-lib.sh fm-operational-input.sh     fm-sessionstart-nudge.sh; do
    [ -f "$repo/bin/$file" ] || ln -s "$ROOT/bin/$file" "$repo/bin/$file"
  done
  cat > "$repo/bin/fm-session-start.sh" <<'SH'
#!/bin/bash
printf 'fixture digest %s\n' "$*"
SH
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/bin/bash
printf 'watcher: started pid=%s (beacon 0s) recovery-generation=fixture\n' "$$"
sleep 30
SH
  printf '#!/bin/bash\nexit 0\n' > "$repo/bin/fm-turnend-guard.sh"
  chmod +x "$repo/bin/fm-session-start.sh" "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-turnend-guard.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state"     node "$ROOT/tests/fixtures/session-owner-native.mjs" "$family" "$repo" 2>&1)     || fail "$family engine generation fixture failed: $out"
  pass "$family native engine verifies its generation for startup receipts, nested engines and watcher markers"
}
