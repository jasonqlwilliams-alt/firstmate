#!/usr/bin/env bash
# Shared target resolution for the gh and gh-axi delivery command shims.
# Source after setting FM_GITHUB_GUARD_TOOL to gh or gh-axi.

fm_github_guard_repo_flag() {  # <argv...>; prints explicit selector or empty
  local want='' arg
  for arg in "$@"; do
    if [ "$want" = repo ]; then
      printf '%s\n' "$arg"
      return 0
    fi
    case "$arg" in
      -R|--repo) want=repo ;;
      -R?*) printf '%s\n' "${arg#-R}"; return 0 ;;
      --repo=*) printf '%s\n' "${arg#--repo=}"; return 0 ;;
    esac
  done
  return 0
}

fm_github_guard_effective_target() {  # <argv...>
  local target origin
  target=$(fm_github_guard_repo_flag "$@") || return 1
  [ -n "$target" ] || target=${GH_REPO:-}
  if [ -n "$target" ]; then
    case "$target" in
      */*/*) printf '%s\n' "$target" ;;
      */*) printf 'github.com/%s\n' "$target" ;;
      *) return 1 ;;
    esac
    return 0
  fi
  origin=$(git remote get-url origin 2>/dev/null) || return 1
  printf '%s\n' "$origin"
}

fm_github_guard_pr_mutation() {  # <argv...>
  [ "${1:-}" = pr ] || return 1
  case "${2:-}" in
    create|edit|close|merge|review|ready|reopen|comment|update-branch|revert) return 0 ;;
  esac
  return 1
}

fm_github_guard_api_pr_mutation_target() {  # <argv...>; prints target or empty
  local method=GET arg path='' owner repo
  for arg in "$@"; do
    case "$arg" in
      GET|POST|PUT|PATCH|DELETE|HEAD) method=$arg ;;
      -X|--method) method=__next ;;
      -X*|--method=*) method=${arg#*=}; method=${method#-X} ;;
      /*|repos/*) [ -n "$path" ] || path=$arg ;;
      *)
        if [ "$method" = __next ]; then method=$arg; fi
        ;;
    esac
  done
  case "$method" in POST|PUT|PATCH|DELETE) ;; *) return 0 ;; esac
  path=${path#/}
  case "$path" in
    repos/*/pulls|repos/*/pulls/*)
      owner=${path#repos/}; owner=${owner%%/*}
      repo=${path#repos/"$owner"/}; repo=${repo%%/*}
      [ -n "$owner" ] && [ -n "$repo" ] || return 1
      printf 'github.com/%s/%s\n' "$owner" "$repo"
      ;;
  esac
}

fm_github_guard_check() {  # <argv...>
  local repo target api_target
  repo=$(git rev-parse --show-toplevel 2>/dev/null) || {
    printf 'REFUSED: %s GitHub write ran outside an armed Git repository.\n' "$FM_GITHUB_GUARD_TOOL" >&2
    return 1
  }
  if fm_github_guard_pr_mutation "$@"; then
    target=$(fm_github_guard_effective_target "$@") || {
      printf 'REFUSED: %s could not resolve the pull-request repository before writing.\n' "$FM_GITHUB_GUARD_TOOL" >&2
      return 1
    }
    "$FM_DELIVERY_GUARD_ROOT/bin/fm-delivery-guard.sh" check-pr "$repo" "$target"
    return $?
  fi
  if [ "${1:-}" = api ]; then
    shift
    api_target=$(fm_github_guard_api_pr_mutation_target "$@") || {
      printf 'REFUSED: %s could not resolve the pull-request API repository before writing.\n' "$FM_GITHUB_GUARD_TOOL" >&2
      return 1
    }
    if [ -n "$api_target" ]; then
      "$FM_DELIVERY_GUARD_ROOT/bin/fm-delivery-guard.sh" check-pr "$repo" "$api_target"
      return $?
    fi
  fi
  return 0
}
