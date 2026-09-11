#!/usr/bin/env bash
# Shared target resolution for the gh and gh-axi delivery command shims.
# Source after setting FM_GITHUB_GUARD_TOOL to gh or gh-axi.

fm_github_guard_upper() { LC_ALL=C tr '[:lower:]' '[:upper:]'; }

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

fm_github_guard_hostname() {  # <argv...>; prints explicit/ambient/default host
  local want arg
  want=
  for arg in "$@"; do
    if [ "$want" = host ]; then
      printf '%s\n' "$arg"
      return 0
    fi
    case "$arg" in
      --hostname) want=host ;;
      --hostname=*) printf '%s\n' "${arg#--hostname=}"; return 0 ;;
    esac
  done
  printf '%s\n' "${GH_HOST:-github.com}"
}

fm_github_guard_effective_target() {  # <argv...>
  local target origin host
  host=$(fm_github_guard_hostname "$@") || return 1
  target=$(fm_github_guard_repo_flag "$@") || return 1
  [ -n "$target" ] || target=${GH_REPO:-}
  if [ -n "$target" ]; then
    case "$target" in
      */*/*) printf '%s\n' "$target" ;;
      */*) printf '%s/%s\n' "$host" "$target" ;;
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

fm_github_guard_api_mutation_target() {  # <argv...>; prints repository target or empty
  local method method_explicit arg path owner repo host
  method=GET
  method_explicit=0
  path=''
  host=$(fm_github_guard_hostname "$@") || return 1
  for arg in "$@"; do
    if [ "$method" = __next ]; then
      method=$(printf '%s' "$arg" | fm_github_guard_upper)
      method_explicit=1
      continue
    fi
    case "$arg" in
      [Gg][Ee][Tt]|[Pp][Oo][Ss][Tt]|[Pp][Uu][Tt]|[Pp][Aa][Tt][Cc][Hh]|[Dd][Ee][Ll][Ee][Tt][Ee]|[Hh][Ee][Aa][Dd])
        method=$(printf '%s' "$arg" | fm_github_guard_upper); method_explicit=1
        ;;
      -X|--method) method=__next ;;
      -X*|--method=*)
        method=${arg#*=}; method=${method#-X}
        method=$(printf '%s' "$method" | fm_github_guard_upper)
        method_explicit=1
        ;;
      -f|-F|--field|--raw-field|--input)
        [ "$method_explicit" -eq 1 ] || method=POST
        ;;
      -f*|-F*|--field=*|--raw-field=*|--input=*)
        [ "$method_explicit" -eq 1 ] || method=POST
        ;;
      /*|repos/*) [ -n "$path" ] || path=$arg ;;
      *) ;;
    esac
  done
  case "$method" in POST|PUT|PATCH|DELETE) ;; *) return 0 ;; esac
  path=${path#/}
  case "$path" in
    repos/*/*)
      owner=${path#repos/}; owner=${owner%%/*}
      repo=${path#repos/"$owner"/}; repo=${repo%%/*}
      [ -n "$owner" ] && [ -n "$repo" ] || return 1
      printf '%s/%s/%s\n' "$host" "$owner" "$repo"
      ;;
  esac
}

fm_github_guard_api_is_graphql() {  # <argv...>
  local arg
  for arg in "$@"; do
    case "$arg" in graphql|/graphql) return 0 ;; esac
  done
  return 1
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
    if fm_github_guard_api_is_graphql "$@"; then
      printf 'REFUSED: %s GraphQL is unavailable in a guarded worker because its mutation repository cannot be proven before writing.\n' \
        "$FM_GITHUB_GUARD_TOOL" >&2
      return 1
    fi
    api_target=$(fm_github_guard_api_mutation_target "$@") || {
      printf 'REFUSED: %s could not resolve the GitHub API repository before writing.\n' "$FM_GITHUB_GUARD_TOOL" >&2
      return 1
    }
    if [ -n "$api_target" ]; then
      "$FM_DELIVERY_GUARD_ROOT/bin/fm-delivery-guard.sh" check-pr "$repo" "$api_target"
      return $?
    fi
  fi
  return 0
}
