#!/usr/bin/env bash

fm_test_pid_identity() {
  local pid=$1
  FM_STATE_OVERRIDE="${TMPDIR:-/tmp}" bash -c \
    '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$pid"
}

fm_test_treehouse_remove() {
  local dir=${1:-}
  [ -n "$dir" ] && [ -e "$dir" ] || return 0
  if [ ! -f "$dir/.fm-test-treehouse" ] || [ -L "$dir" ]; then
    printf 'refusing to remove %s: not a Treehouse test directory\n' "$dir" >&2
    return 1
  fi
  find "$dir" -type d ! -perm -0700 -exec chmod u+rwx {} + 2>/dev/null || true
  rm -rf -- "$dir"
}

fm_test_treehouse_setup() {
  local parent live dir binary=${FM_TEST_TREEHOUSE_BIN:-}
  parent=$(cd -P /tmp && pwd -P) || return 1
  live=$(cd -P "${HOME:?}/.treehouse" 2>/dev/null && pwd -P) || live=
  if { [ -n "$live" ] && [[ "$parent/" = "${live%/}/"* ]]; } ||
    (unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_CEILING_DIRECTORIES
     GIT_DISCOVERY_ACROSS_FILESYSTEM=1 git -C "$parent" rev-parse --git-dir >/dev/null 2>&1); then
    printf 'Treehouse test directory needs a temporary parent outside Git and the live pool\n' >&2
    return 1
  fi
  dir=$(umask 077; mktemp -d "${parent%/}/fm-test-treehouse.XXXXXX") || return 1
  if ! touch "$dir/.fm-test-treehouse" || ! mkdir "$dir/pool"; then
    rm -rf -- "$dir"
    return 1
  fi
  if [ "$#" -ne 0 ] && ! printf '%s\n%s\n' "$1" "$2" > "$dir/.fm-test-fixture"; then
    fm_test_treehouse_remove "$dir"
    return 1
  fi
  if [ -n "$binary" ] || binary=$(type -P treehouse); then
    if ! binary=$(cd -P -- "$(dirname "$binary")" && printf '%s/%s\n' "$PWD" "${binary##*/}") ||
      ! mkdir "$dir/bin" ||
      ! {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' "export TREEHOUSE_NO_UPDATE_CHECK=1 TREEHOUSE_WORKTREE_PATH='{pool}/{slot}/{repo}'"
        printf 'exec %q --root %q "$@"\n' "$binary" "$dir/pool"
      } > "$dir/bin/treehouse" || ! chmod +x "$dir/bin/treehouse"; then
      fm_test_treehouse_remove "$dir"
      return 1
    fi
    export FM_TEST_TREEHOUSE_BIN="$binary"
    export PATH="$dir/bin:$PATH"
  fi
  export FM_TEST_TREEHOUSE_DIR="$dir" TREEHOUSE_ROOT="$dir/pool"
}

# fm_test_reap_orphans: best-effort sweep for fixture roots left behind by a
# prior run that was killed hard enough to skip the traps above (e.g. a
# SIGKILL timeout). Only removes directories carrying the .fm-test-fixture
# marker written at allocation, so it never touches unrelated fm-* tmp dirs
# from real (non-test) firstmate commands. The marker identifies the owning
# shell across PID reuse, so the same live owner always wins over the age
# fallback for dead or unowned roots.
FM_TEST_ORPHAN_MAX_AGE_SECONDS=${FM_TEST_ORPHAN_MAX_AGE_SECONDS:-3600}

fm_test_reap_orphans() {
  local marker dir mtime now owner_pid owner_identity current_identity
  now=$(date +%s)
  for marker in "${1:-${TMPDIR:-/tmp}}"/"${2:-fm-}"*/.fm-test-fixture; do
    dir=${marker%/*}
    [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ] || continue
    [ -f "$marker" ] && [ ! -L "$marker" ] && [ -O "$marker" ] || continue
    mtime=$(stat -c %Y "$marker" 2>/dev/null || stat -f %m "$marker" 2>/dev/null) || continue
    [ $((now - mtime)) -ge "$FM_TEST_ORPHAN_MAX_AGE_SECONDS" ] || continue
    owner_pid=$(sed -n '1p' "$marker" 2>/dev/null) || owner_pid=
    owner_identity=$(sed -n '2,$p' "$marker" 2>/dev/null) || owner_identity=
    case "$owner_pid" in
      '' | *[!0-9]*) ;;
      *)
        current_identity=$(fm_test_pid_identity "$owner_pid" 2>/dev/null) || current_identity=
        if [ -n "$owner_identity" ] && [ "$current_identity" = "$owner_identity" ]; then
          continue
        fi
        ;;
    esac
    find "$dir" -type d -exec chmod u+rwx {} + 2>/dev/null || true
    rm -rf "$dir"
  done
}
