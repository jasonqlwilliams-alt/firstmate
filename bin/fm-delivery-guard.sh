#!/usr/bin/env bash
# Install and enforce the repository delivery boundary.
#
# Usage:
#   fm-delivery-guard.sh validate
#   fm-delivery-guard.sh arm <project> <repository-path>
#   fm-delivery-guard.sh arm-refuse <project> <repository-path>
#   fm-delivery-guard.sh arm-all
#   fm-delivery-guard.sh check-push <repository-path> <remote-name> <effective-url>
#   fm-delivery-guard.sh check-pr <repository-path> <target-url-or-host/owner/repo>
#   fm-delivery-guard.sh pr-target <repository-path>
#
# arm stores only the project key and Firstmate code/home locations in local Git
# config, then installs one shared pre-push hook for the repository and all its
# worktrees.  It never adds, removes, renames, or rewrites a remote.  If another
# hooksPath is already configured, the managed hook chains its executable
# pre-push hook after this refusal guard.
#
# check-push is the pre-push hook's authority.  A direct remote must resolve to
# the explicit forkPushUrl.  The no-mistakes proxy is checked one level deeper:
# no-mistakes status exposes its effective fork branch destination and upstream
# PR destination, and BOTH must equal the configured fork repository before the
# local proxy receives any objects.  Every allowed path resolves the current
# gh-axi account immediately before transmission and names its targets first.
#
# check-pr is used by the spawned gh/gh-axi command shims.  pr-target prints the
# explicit OWNER/REPO for a caller to place in GH_REPO; its target announcement
# goes to stderr so command substitution receives only the selector.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

# shellcheck source=bin/fm-repository-policy-lib.sh
. "$SCRIPT_DIR/fm-repository-policy-lib.sh"

usage() { sed -n '2,30{s/^# \{0,1\}//;p;}' "$0" >&2; exit 2; }
die() { printf 'REFUSED: %s\n' "$1" >&2; exit 1; }

repository_top() { git -C "$1" rev-parse --show-toplevel 2>/dev/null; }
repository_common_dir() {
  local repo=$1 common
  common=$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) printf '%s\n' "$common" ;;
    *) (cd "$repo" && cd "$common" 2>/dev/null && pwd -P) ;;
  esac
}

repository_project() {  # <repo>
  git -C "$1" config --local --get firstmate.projectName 2>/dev/null
}

resolve_existing_hooks_path() {  # <repo> <common-dir> <configured-path-or-empty>
  local repo=$1 common=$2 configured=$3
  if [ -z "$configured" ]; then
    printf '%s/hooks\n' "$common"
  elif [ "${configured#/}" != "$configured" ]; then
    printf '%s\n' "$configured"
  else
    (cd "$repo" && mkdir -p "$configured" 2>/dev/null && cd "$configured" && pwd -P)
  fi
}

write_managed_hook() {  # <hook-path>
  local hook=$1 tmp
  tmp=$(mktemp "${hook}.XXXXXX") || return 1
  cat > "$tmp" <<'HOOK'
#!/bin/sh
repo=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "REFUSED: Firstmate pre-push guard cannot resolve this repository." >&2
  exit 1
}
root=$(git config --local --get firstmate.guardRoot 2>/dev/null) || root=
home=$(git config --local --get firstmate.guardHome 2>/dev/null) || home=
if [ -z "$root" ] || [ ! -x "$root/bin/fm-delivery-guard.sh" ]; then
  echo "REFUSED: Firstmate pre-push guard is not available at ${root:-<unset>}." >&2
  exit 1
fi
FM_HOME=$home FM_ROOT_OVERRIDE=$root "$root/bin/fm-delivery-guard.sh" check-push "$repo" "${1:-}" "${2:-}" || exit $?
previous=$(git config --local --get firstmate.previousHooksPath 2>/dev/null) || previous=
if [ -n "$previous" ] && [ -x "$previous/pre-push" ]; then
  exec "$previous/pre-push" "$@"
fi
exit 0
HOOK
  chmod 0755 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$hook"
}

install_guard() {  # <project> <repo>; installs a fail-closed hook without trusting policy
  local project=$1 repo=$2 top common managed configured previous
  top=$(repository_top "$repo") || die "not a Git worktree: $repo"
  common=$(repository_common_dir "$top") || die "cannot resolve the shared Git directory for $top"
  managed="$common/firstmate-hooks"
  configured=$(git -C "$top" config --local --get core.hooksPath 2>/dev/null || true)
  previous=$(git -C "$top" config --local --get firstmate.previousHooksPath 2>/dev/null || true)
  if [ "$configured" != "$managed" ]; then
    previous=$(resolve_existing_hooks_path "$top" "$common" "$configured") || \
      die "cannot resolve the existing hooks path for $top"
  fi
  mkdir -p "$managed" || die "cannot create managed hooks directory $managed"
  write_managed_hook "$managed/pre-push" || die "cannot install managed pre-push hook at $managed/pre-push"
  git -C "$top" config --local firstmate.projectName "$project" || die "cannot record project identity for $top"
  git -C "$top" config --local firstmate.guardRoot "$FM_ROOT" || die "cannot record guard root for $top"
  git -C "$top" config --local firstmate.guardHome "$FM_HOME" || die "cannot record guard home for $top"
  git -C "$top" config --local firstmate.previousHooksPath "$previous" || die "cannot preserve previous hooks path for $top"
  git -C "$top" config --local core.hooksPath "$managed" || die "cannot activate managed hooks for $top"
  ARMED_TOP=$top
}

cmd_arm() {  # <project> <repo>
  local project=$1 repo=$2
  install_guard "$project" "$repo" || return 1
  # Validate only after installation. A malformed or missing policy therefore
  # aborts the caller while leaving a deny-by-default pre-push hook in place.
  fm_repository_policy_load "$project" || return 1
  printf 'armed: project=%s repository=%s push=%s upstream=%s\n' \
    "$project" "$ARMED_TOP" "$FM_REPOSITORY_POLICY_FORK_ID" "$FM_REPOSITORY_POLICY_UPSTREAM_ID"
}

cmd_arm_refuse() {  # <project> <repo>
  install_guard "$1" "$2" || return 1
  printf 'armed-refuse-only: project=%s repository=%s\n' "$1" "$ARMED_TOP"
}

cmd_arm_all() {
  local project repo
  # Fail-close every present clone before trusting config. This protects crews
  # that were already running when a policy became malformed: validation may
  # fail, but their shared pre-push hooks are installed first and will refuse.
  if git -C "$FM_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    cmd_arm_refuse firstmate "$FM_ROOT" || return 1
  fi
  if [ -d "$PROJECTS" ]; then
    for repo in "$PROJECTS"/*; do
      [ -d "$repo" ] || continue
      git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
      cmd_arm_refuse "$(basename "$repo")" "$repo" || return 1
    done
  fi
  fm_repository_policy_validate || return 1
  while IFS= read -r project; do
    [ -n "$project" ] || continue
    if [ "$project" = firstmate ]; then
      repo=$FM_ROOT
    else
      repo="$PROJECTS/$project"
    fi
    if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      printf 'arm-skip: project=%s repository=%s reason=clone-absent\n' "$project" "$repo"
      continue
    fi
    cmd_arm "$project" "$repo" || return 1
  done < <(fm_repository_policy_projects)
}

read_no_mistakes_targets() {  # <repo>; sets NM_UPSTREAM and NM_FORK
  local repo=$1 output
  command -v no-mistakes >/dev/null 2>&1 || {
    printf 'REFUSED: no-mistakes is unavailable, so its GitHub push and PR targets cannot be verified.\n' >&2
    return 1
  }
  output=$(cd "$repo" && no-mistakes status 2>&1) || {
    printf 'REFUSED: no-mistakes target inspection failed for %s: %s\n' "$repo" "$output" >&2
    return 1
  }
  NM_UPSTREAM=$(printf '%s\n' "$output" | sed -n 's/^[[:space:]]*remote:[[:space:]]*//p' | head -1)
  NM_FORK=$(printf '%s\n' "$output" | sed -n 's/^[[:space:]]*fork:[[:space:]]*//p' | head -1)
  [ -n "$NM_UPSTREAM" ] || {
    printf 'REFUSED: no-mistakes did not report its pull-request target for %s.\n' "$repo" >&2
    return 1
  }
  [ -n "$NM_FORK" ] || NM_FORK=$NM_UPSTREAM
}

authorize_exact_target() {  # <action> <url> <expected-identity>
  local action=$1 url=$2 expected=$3
  fm_repository_policy_authorize_url "$action" "$url" "$expected" || return 1
  printf 'DELIVERY TARGET: project=%s action=%s repository=%s account=%s\n' \
    "$FM_REPOSITORY_POLICY_PROJECT" "$action" "$FM_REPOSITORY_POLICY_EFFECTIVE_ID" \
    "$FM_REPOSITORY_POLICY_AUTH_ACCOUNT" >&2
}

cmd_check_push() {  # <repo> <remote-name> <effective-url>
  local repo=$1 remote=$2 url=$3 project
  project=$(repository_project "$repo") || project=
  [ -n "$project" ] || die "repository $repo is not armed with a Firstmate project identity"
  fm_repository_policy_load "$project" || exit 1
  if [ "$remote" = no-mistakes ]; then
    read_no_mistakes_targets "$repo" || exit 1
    authorize_exact_target branch-push "$NM_FORK" "$FM_REPOSITORY_POLICY_FORK_ID" || exit 1
    authorize_exact_target pull-request "$NM_UPSTREAM" "$FM_REPOSITORY_POLICY_FORK_ID" || exit 1
    return 0
  fi
  authorize_exact_target branch-push "$url" "$FM_REPOSITORY_POLICY_FORK_ID"
}

cmd_check_pr() {  # <repo> <target>
  local repo=$1 target=$2 project
  project=$(repository_project "$repo") || project=
  [ -n "$project" ] || die "repository $repo is not armed with a Firstmate project identity"
  fm_repository_policy_load "$project" || exit 1
  authorize_exact_target pull-request "$target" "$FM_REPOSITORY_POLICY_FORK_ID"
}

cmd_pr_target() {  # <repo>
  local repo=$1 project
  project=$(repository_project "$repo") || project=
  [ -n "$project" ] || die "repository $repo is not armed with a Firstmate project identity"
  fm_repository_policy_load "$project" || exit 1
  fm_repository_policy_authorize_identity pull-request "$FM_REPOSITORY_POLICY_FORK_ID" || exit 1
  printf 'DELIVERY TARGET: project=%s action=pull-request repository=%s account=%s\n' \
    "$project" "$FM_REPOSITORY_POLICY_FORK_ID" "$FM_REPOSITORY_POLICY_AUTH_ACCOUNT" >&2
  fm_repository_identity_owner_repo "$FM_REPOSITORY_POLICY_FORK_ID"
}

case "${1:-}" in
  validate)
    [ "$#" -eq 1 ] || usage
    fm_repository_policy_validate
    ;;
  arm)
    [ "$#" -eq 3 ] || usage
    cmd_arm "$2" "$3"
    ;;
  arm-refuse)
    [ "$#" -eq 3 ] || usage
    cmd_arm_refuse "$2" "$3"
    ;;
  arm-all)
    [ "$#" -eq 1 ] || usage
    cmd_arm_all
    ;;
  check-push)
    [ "$#" -eq 4 ] || usage
    cmd_check_push "$2" "$3" "$4"
    ;;
  check-pr)
    [ "$#" -eq 3 ] || usage
    cmd_check_pr "$2" "$3"
    ;;
  pr-target)
    [ "$#" -eq 2 ] || usage
    cmd_pr_target "$2"
    ;;
  -h|--help) usage ;;
  *) usage ;;
esac
