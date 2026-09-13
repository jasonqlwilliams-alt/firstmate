#!/usr/bin/env bash
# Live driver: run the real bin/fm-bootstrap.sh (detect-only, isolated FM_HOME)
# against different installed no-mistakes versions, at the base commit and at
# the target commit, and print exactly what the captain would see.
# Usage: drive-bootstrap-floor.sh <worktree> <base-commit>
set -u
WT=$1
BASE=$2
TMP=$(mktemp -d /tmp/fm-nm-floor.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH \
  CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_SOCKET_PATH CMUX_TAB_ID CMUX_PANEL_ID 2>/dev/null || true

mkdir -p "$TMP/base"
git -C "$WT" archive "$BASE" | tar -x -C "$TMP/base"
REAL_NM=/home/jason/.no-mistakes/bin/no-mistakes

# Fake every OTHER required tool so only the no-mistakes line can vary.
make_toolchain() {  # <dir> <no-mistakes spec: real | absent | "version text">
  local dir=$1 spec=$2 fb
  fb="$dir/bin"
  mkdir -p "$fb"
  for t in tmux node chrome-devtools-axi; do printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/$t"; done
  printf '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && echo 0.1.46\nexit 0\n' > "$fb/lavish-axi"
  printf '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && echo 0.1.29\nexit 0\n' > "$fb/gh-axi"
  printf '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && echo 0.1.29\nexit 0\n' > "$fb/quota-axi"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/gh"
  printf '#!/usr/bin/env bash\nif [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then echo "Usage: treehouse get [--lease]"; fi\nexit 0\n' > "$fb/treehouse"
  cat > "$fb/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "--version ") echo 0.2.4 ;;
  "update --help") printf '%s\n' 'usage: tasks-axi update <id> [flags]' '  --archive-body' ;;
  "mv --help") echo 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>' ;;
esac
exit 0
SH
  case "$spec" in
    real) ln -s "$REAL_NM" "$fb/no-mistakes" ;;
    absent) ;;
    *) printf '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && printf "%%s\\n" %q\nexit 0\n' "$spec" > "$fb/no-mistakes" ;;
  esac
  chmod +x "$fb"/*
  printf '%s\n' "$fb"
}

run_case() {  # <root> <label> <spec>
  local root=$1 label=$2 spec=$3 d fb out nmver
  d=$(mktemp -d "$TMP/case.XXXXXX")
  mkdir -p "$d/home/config"
  printf 'manual\n' > "$d/home/config/backlog-backend"
  fb=$(make_toolchain "$d" "$spec")
  if [ -e "$fb/no-mistakes" ]; then nmver=$(PATH="$fb:/usr/bin:/bin" no-mistakes --version 2>&1 | head -n1); else nmver='(not installed)'; fi
  out=$(PATH="$fb:/usr/bin:/bin" FM_HOME="$d/home" FM_ROOT_OVERRIDE="$d/home" \
    FM_BOOTSTRAP_DETECT_ONLY=1 "$root/bin/fm-bootstrap.sh" 2>&1)
  printf '%-28s | installed: %-58s | bootstrap says: %s\n' "$label" "$nmver" "${out:-(silent - all good)}"
}

CASES=(
  "real daemon binary^real"
  "old floor 1.46.0^no-mistakes version v1.46.0 (fake)"
  "mid 1.60.0^no-mistakes version v1.60.0 (fake)"
  "just below 1.71.9^no-mistakes version v1.71.9 (fake)"
  "digit trap 1.7.20^no-mistakes version v1.7.20 (fake)"
  "exact floor 1.72.0^no-mistakes version v1.72.0 (fake)"
  "patch above 1.72.1^no-mistakes version v1.72.1 (fake)"
  "three-digit minor 1.100.0^no-mistakes version v1.100.0 (fake)"
  "next major 2.0.0^no-mistakes version v2.0.0 (fake)"
  "unparseable dev build^no-mistakes development build"
  "not installed^absent"
)

for side in "BASE $BASE:$TMP/base" "TARGET $(git -C "$WT" rev-parse --short HEAD):$WT"; do
  name=${side%%:*}; root=${side#*:}
  printf '\n=== %s  (NO_MISTAKES_MIN=%s) ===\n' "$name" "$(sed -n 's/^NO_MISTAKES_MIN=//p' "$root/bin/fm-bootstrap.sh")"
  for c in "${CASES[@]}"; do run_case "$root" "${c%%^*}" "${c#*^}"; done
done
