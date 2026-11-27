#!/usr/bin/env bash

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
