#!/usr/bin/env bash
# Shared target resolution for the gh and gh-axi delivery command shims.
# Source after setting FM_GITHUB_GUARD_TOOL to gh or gh-axi.

# shellcheck source=bin/fm-repository-policy-lib.sh
. "$FM_DELIVERY_GUARD_ROOT/bin/fm-repository-policy-lib.sh"

fm_github_guard_upper() { LC_ALL=C tr '[:lower:]' '[:upper:]'; }

fm_github_guard_repo_flag() {  # <argv...>; prints explicit selector or empty
  local want='' arg selector=''
  for arg in "$@"; do
    if [ "$want" = repo ]; then
      selector=$arg
      want=''
      continue
    fi
    case "$arg" in
      --) break ;;
      -R|--repo) want=repo ;;
      -R=*) selector=${arg#-R=} ;;
      -R?*) selector=${arg#-R} ;;
      --repo=*) selector=${arg#--repo=} ;;
    esac
  done
  printf '%s\n' "$selector"
}

fm_github_guard_effective_target() {  # <host> <selector>
  local host=$1 selector=$2
  case "$selector" in
    */*/*) printf '%s\n' "$selector" ;;
    */*) printf '%s/%s\n' "$host" "$selector" ;;
    '') git remote get-url origin 2>/dev/null ;;
    *) return 1 ;;
  esac
}

fm_github_guard_authorize_target() {  # <checkout> <target> <pr|api> [<explicit-host>]
  local identity host
  identity=$(fm_repository_url_identity "$2") || {
    printf 'REFUSED: pull-request has no verifiable GitHub repository target: %s.\n' "$2" >&2
    return 1
  }
  host=${identity%%/*}
  if [ "$#" -eq 4 ] && [ "$(printf '%s' "$4" | fm_github_guard_upper)" != "$(printf '%s' "$host" | fm_github_guard_upper)" ]; then
    printf 'REFUSED: %s hostname does not match the pull-request repository host %s.\n' \
      "$FM_GITHUB_GUARD_TOOL" "$host" >&2
    return 1
  fi
  "$FM_DELIVERY_GUARD_ROOT/bin/fm-delivery-guard.sh" check-pr "$1" "$identity" || return $?
  export GH_HOST="$host"
  if [ "$3" = pr ]; then
    export GH_REPO="${identity#*/}"
  fi
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

fm_github_guard_check_api() {  # <checkout> <host> <api argv...>
  local checkout=$1 host=$2
  shift 2
  local arg flag value separate positional_only=0 method='' path=''
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
      -[HFXfptq]?*) flag=${arg:0:2}; value=${arg:2}; value=${value#=} ;;
      *) flag=$arg; separate=1 ;;
    esac
    case "$flag" in
      --hostname|--method|-X|--field|-F|--raw-field|-f|--header|-H|--input|--jq|-q|--template|-t|--preview|-p|--cache)
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
  fm_github_guard_authorize_target "$checkout" "$host/$owner/$repo" api "$host" || return $?

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
  local repo target selector='' host=${GH_HOST:-github.com}
  repo=$(git rev-parse --show-toplevel 2>/dev/null) || {
    printf 'REFUSED: %s GitHub write ran outside an armed Git repository.\n' "$FM_GITHUB_GUARD_TOOL" >&2
    return 1
  }
  local explicit_host=()
  if [ "$FM_GITHUB_GUARD_TOOL" = gh-axi ] && [[ ${1:-} == pr || ${1:-} == api ]]; then
    local args=("$1")
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --hostname) [ "$#" -gt 1 ] || break; host=$2; explicit_host=("$host"); shift ;;
        --hostname=?*) host=${1#*=}; explicit_host=("$host") ;;
        --repo|-R) [ "$#" -gt 1 ] || break; selector=$2; shift ;;
        --repo=?*|-R=?*) selector=${1#*=} ;;
        *) args+=("$1") ;;
      esac
      shift
    done
    set -- "${args[@]}" "$@"
  fi
  if fm_github_guard_pr_mutation "$@"; then
    if [ "$FM_GITHUB_GUARD_TOOL" = gh ]; then
      selector=$(fm_github_guard_repo_flag "$@")
    fi
    target=$(fm_github_guard_effective_target "$host" "${selector:-${GH_REPO:-}}") || {
      printf 'REFUSED: %s could not resolve the pull-request repository before writing.\n' "$FM_GITHUB_GUARD_TOOL" >&2
      return 1
    }
    fm_github_guard_authorize_target "$repo" "$target" pr ${explicit_host[@]+"${explicit_host[@]}"} || return $?
    fm_github_guard_check_pr_body "$repo" "$@" || return $?
    return 0
  fi
  if [ "${1:-}" = api ]; then
    shift
    fm_github_guard_check_api "$repo" "$host" "$@" || return $?
  fi
  return 0
}
