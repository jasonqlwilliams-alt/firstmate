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

fm_github_guard_check_pr_body() {  # <repo> <argv...>
  local repo=$1
  shift
  case "${2:-}" in
    create|edit|merge) ;;
    *) return 0 ;;
  esac

  local want='' arg
  local body_text='' body_text_set=0 body_file=''
  for arg in "$@"; do
    if [ "$want" = body ]; then
      body_text=$arg
      body_text_set=1
      want=''
      continue
    elif [ "$want" = body_file ]; then
      body_file=$arg
      want=''
      continue
    fi
    case "$arg" in
      -b|--body) want=body ;;
      --body=*) body_text=${arg#--body=}; body_text_set=1 ;;
      -b?*) body_text=${arg#-b}; body_text_set=1 ;;
      -F|--body-file) want=body_file ;;
      --body-file=*) body_file=${arg#--body-file=} ;;
      -F?*) body_file=${arg#-F} ;;
    esac
  done

  if [ "$body_text_set" -eq 1 ]; then
    printf '%s' "$body_text" | "$FM_DELIVERY_GUARD_ROOT/bin/fm-delivery-guard.sh" check-pr-body "$repo" - || return $?
  fi

  if [ -n "$body_file" ]; then
    if [ "$body_file" = "-" ]; then
      local stdin_tmp rc
      stdin_tmp=$(mktemp "${TMPDIR:-/tmp}/fm-delivery-stdin.XXXXXX") || {
        printf 'REFUSED: %s cannot buffer pull-request standard input for body inspection.\n' "$FM_GITHUB_GUARD_TOOL" >&2
        return 1
      }
      cat > "$stdin_tmp"
      "$FM_DELIVERY_GUARD_ROOT/bin/fm-delivery-guard.sh" check-pr-body "$repo" "$stdin_tmp"
      rc=$?
      if [ "$rc" -ne 0 ]; then
        rm -f "$stdin_tmp"
        return "$rc"
      fi
      FM_SAVED_STDIN_FILE=$stdin_tmp
      export FM_SAVED_STDIN_FILE
    else
      "$FM_DELIVERY_GUARD_ROOT/bin/fm-delivery-guard.sh" check-pr-body "$repo" "$body_file" || return $?
    fi
  fi
  return 0
}

fm_github_guard_check_api() {  # <checkout> <api argv...>
  local checkout=$1
  shift
  local arg flag value separate positional_only=0 method='' path='' host=${GH_HOST:-github.com}
  local owner repo has_fields=0 auth_override=0 input_file='' use_stdin=0
  local body_fields=() body_files=()
  while [ "$#" -gt 0 ]; do
    arg=$1
    shift
    if [ "$positional_only" -eq 1 ] || [[ $arg != -* ]]; then
      if [ "$FM_GITHUB_GUARD_TOOL" = gh-axi ] && [ -z "$method$path" ]; then
        case "$arg" in
          [Gg][Ee][Tt]|[Pp][Oo][Ss][Tt]|[Pp][Uu][Tt]|[Pp][Aa][Tt][Cc][Hh]|[Dd][Ee][Ll][Ee][Tt][Ee]|[Hh][Ee][Aa][Dd])
            method=$(printf '%s' "$arg" | fm_github_guard_upper)
            continue
            ;;
        esac
      fi
      [ -n "$path" ] || path=$arg
      continue
    fi
    if [ "$arg" = -- ]; then
      positional_only=1
      continue
    fi
    while [[ $arg == -i?* && $arg != -i=* ]]; do
      arg=-${arg#-i}
    done
    separate=0
    case "$arg" in
      --*=*) flag=${arg%%=*}; value=${arg#*=} ;;
      -[HFXfptqR]?*) flag=${arg:0:2}; value=${arg:2}; value=${value#=} ;;
      *) flag=$arg; separate=1 ;;
    esac
    case "$flag" in
      --hostname|--method|-X|--field|-F|--raw-field|-f|--header|-H|--input|--jq|-q|--template|-t|--preview|-p|--cache|--repo|-R)
        if [ "$separate" -eq 1 ]; then
          [ "$#" -gt 0 ] || break
          value=$1
          shift
        fi
        ;;
      *) continue ;;
    esac
    case "$flag" in
      --hostname) host=$value ;;
      --method|-X)
        if [ "$FM_GITHUB_GUARD_TOOL" = gh ]; then
          method=$(printf '%s' "$value" | fm_github_guard_upper)
        fi
        ;;
      --header|-H)
        case "${value%%:*}" in
          [Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]) auth_override=1 ;;
        esac
        ;;
      --field|-F)
        has_fields=1
        case "$value" in
          body=@*) body_files+=("${value#body=@}") ;;
          body=*) body_fields+=("${value#body=}") ;;
        esac
        ;;
      --raw-field|-f)
        has_fields=1
        case "$value" in
          body=*) body_fields+=("${value#body=}") ;;
        esac
        ;;
      --input) input_file=$value ;;
    esac
  done

  path=${path#/}
  if [ "$path" = graphql ]; then
    printf 'REFUSED: %s GraphQL is unavailable in a guarded worker because its mutation repository cannot be proven before writing.\n' \
      "$FM_GITHUB_GUARD_TOOL" >&2
    return 1
  fi
  if [ "$FM_GITHUB_GUARD_TOOL" = gh ] && [ -z "$method" ] &&
    { [ "$has_fields" -eq 1 ] || [ -n "$input_file" ]; }; then
    method=POST
  fi
  case "$method" in POST|PUT|PATCH|DELETE) ;; *) return 0 ;; esac
  case "$path" in repos/*/*) ;; *) return 0 ;; esac
  owner=${path#repos/}; owner=${owner%%/*}
  repo=${path#repos/"$owner"/}; repo=${repo%%/*}
  if [ -z "$owner" ] || [ -z "$repo" ]; then
    printf 'REFUSED: %s could not resolve the GitHub API repository before writing.\n' "$FM_GITHUB_GUARD_TOOL" >&2
    return 1
  fi
  if [ "$auth_override" -eq 1 ]; then
    printf 'REFUSED: %s REST writes cannot supply an Authorization header.\n' "$FM_GITHUB_GUARD_TOOL" >&2
    return 1
  fi
  "$FM_DELIVERY_GUARD_ROOT/bin/fm-delivery-guard.sh" check-pr "$checkout" "$host/$owner/$repo" || return $?

  for value in ${body_fields[@]+"${body_fields[@]}"}; do
    printf '%s' "$value" | "$FM_DELIVERY_GUARD_ROOT/bin/fm-delivery-guard.sh" check-pr-body "$checkout" - || return $?
  done
  [ -z "$input_file" ] || body_files+=("$input_file")
  for value in ${body_files[@]+"${body_files[@]}"}; do
    if [ "$value" = - ]; then
      use_stdin=1
      continue
    fi
    if [ ! -f "$value" ] || [ ! -r "$value" ]; then
      printf 'REFUSED: %s REST body must come from a readable regular file or standard input.\n' "$FM_GITHUB_GUARD_TOOL" >&2
      return 1
    fi
    [[ $value != -* ]] || value=./$value
    "$FM_DELIVERY_GUARD_ROOT/bin/fm-delivery-guard.sh" check-pr-body "$checkout" "$value" || return $?
  done
  if [ "$use_stdin" -eq 1 ]; then
    if [ "$FM_GITHUB_GUARD_TOOL" = gh-axi ]; then
      printf 'REFUSED: gh-axi REST body files cannot use standard input.\n' >&2
      return 1
    fi
    local stdin_tmp rc
    stdin_tmp=$(mktemp "${TMPDIR:-/tmp}/fm-delivery-api-stdin.XXXXXX") || {
      printf 'REFUSED: %s cannot buffer API standard input for body inspection.\n' "$FM_GITHUB_GUARD_TOOL" >&2
      return 1
    }
    cat > "$stdin_tmp" &&
      "$FM_DELIVERY_GUARD_ROOT/bin/fm-delivery-guard.sh" check-pr-body "$checkout" "$stdin_tmp"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      rm -f "$stdin_tmp"
      return "$rc"
    fi
    FM_SAVED_STDIN_FILE=$stdin_tmp
    export FM_SAVED_STDIN_FILE
  fi

  if [ "$FM_GITHUB_GUARD_TOOL" = gh-axi ]; then
    unset GH_REPO
  fi
  return 0
}

fm_github_guard_check() {  # <argv...>
  local repo target
  repo=$(git rev-parse --show-toplevel 2>/dev/null) || {
    printf 'REFUSED: %s GitHub write ran outside an armed Git repository.\n' "$FM_GITHUB_GUARD_TOOL" >&2
    return 1
  }
  if fm_github_guard_pr_mutation "$@"; then
    target=$(fm_github_guard_effective_target "$@") || {
      printf 'REFUSED: %s could not resolve the pull-request repository before writing.\n' "$FM_GITHUB_GUARD_TOOL" >&2
      return 1
    }
    "$FM_DELIVERY_GUARD_ROOT/bin/fm-delivery-guard.sh" check-pr "$repo" "$target" || return $?
    fm_github_guard_check_pr_body "$repo" "$@" || return $?
    return 0
  fi
  if [ "${1:-}" = api ]; then
    shift
    fm_github_guard_check_api "$repo" "$@" || return $?
  fi
  return 0
}
