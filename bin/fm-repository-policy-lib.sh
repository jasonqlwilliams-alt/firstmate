#!/usr/bin/env bash
# Shared parser and GitHub identity checks for repository delivery policy.
#
# The primary-authoritative, gitignored config/repository-policy.json records
# the explicit upstream fetch URL and fork push URL for every remotely delivered
# project, plus the GitHub owners and authenticated accounts the captain has
# approved.  Remote names are deliberately absent from the authority decision:
# "origin" is only a local label and is never evidence that its repository is
# safe to write.
#
# Usage: source this file, then call fm_repository_policy_load <project>.
# The function sets FM_REPOSITORY_POLICY_* globals documented immediately below.

fm_repository_policy_config_path() {
  local home config
  home=${FM_HOME:-${FM_ROOT_OVERRIDE:-}}
  config=${FM_CONFIG_OVERRIDE:-${home:+$home/config}}
  [ -n "$config" ] || return 1
  printf '%s/repository-policy.json\n' "$config"
}

fm_repository_policy_validate() {  # [<config-file>]
  local file=${1:-} error
  [ -n "$file" ] || file=$(fm_repository_policy_config_path) || {
    printf 'REFUSED: repository policy location cannot be resolved; FM_HOME is unset.\n' >&2
    return 1
  }
  if [ ! -f "$file" ] || [ -L "$file" ]; then
    printf 'REFUSED: repository delivery policy is missing or unsafe: %s\n' "$file" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'REFUSED: jq is required to validate repository delivery policy %s.\n' "$file" >&2
    return 1
  fi
  error=$(jq -r '
    def strings: type == "array" and length > 0 and all(.[]; type == "string" and length > 0);
    if type != "object" then "top level must be an object"
    elif .version != 1 then "version must be 1"
    elif (.approvedOwners | strings | not) then "approvedOwners must be a non-empty string array"
    elif ((.approvedAccounts // .approvedOwners) | strings | not) then "approvedAccounts must be a non-empty string array when present"
    elif (.repositories | type) != "object" then "repositories must be an object"
    elif (.repositories | length) == 0 then "repositories must not be empty"
    elif any(.repositories | to_entries[];
      (.key | test("^[A-Za-z0-9._-]+$") | not) or
      (.value | type != "object") or
      (.value.upstreamFetchUrl | type != "string" or length == 0) or
      (.value.forkPushUrl | type != "string" or length == 0) or
      ((.value.defaultBranch // "main") | type != "string" or length == 0)
    ) then "every repository needs a safe name plus non-empty upstreamFetchUrl, forkPushUrl, and defaultBranch"
    else empty end
  ' "$file" 2>/dev/null) || error='malformed JSON'
  if [ -n "$error" ]; then
    printf 'REFUSED: invalid repository delivery policy %s: %s.\n' "$file" "$error" >&2
    return 1
  fi
}

# Print a stable lower-case "host/owner/repository" identity for a GitHub URL,
# or fail for local paths, remote helpers, malformed URLs, and deeper paths.
# Accepted transport spellings are https/http/ssh/git URLs and scp-like SSH.
fm_repository_url_identity() {  # <url-or-host/owner/repo>
  local input=$1 rest authority host path owner repo identity
  case "$input" in
    ''|-*|*[$'\t\r\n ']*) return 1 ;;
  esac
  case "$input" in
    https://*|http://*|ssh://*|git://*)
      rest=${input#*://}
      authority=${rest%%/*}
      [ "$authority" != "$rest" ] || return 1
      host=${authority##*@}
      host=${host%%:*}
      path=${rest#*/}
      ;;
    *@*:*|[A-Za-z0-9._-]*:*)
      authority=${input%%:*}
      host=${authority##*@}
      path=${input#*:}
      ;;
    */*/*)
      host=${input%%/*}
      path=${input#*/}
      ;;
    *) return 1 ;;
  esac
  path=${path#/}
  path=${path%/}
  path=${path%.git}
  owner=${path%%/*}
  repo=${path#*/}
  [ -n "$host" ] && [ -n "$owner" ] && [ -n "$repo" ] || return 1
  [ "$repo" = "${repo%%/*}" ] || return 1
  case "$host$owner$repo" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  identity=$(printf '%s/%s/%s' "$host" "$owner" "$repo" | LC_ALL=C tr '[:upper:]' '[:lower:]')
  printf '%s\n' "$identity"
}

fm_repository_identity_host() { printf '%s\n' "${1%%/*}"; }
fm_repository_identity_owner_repo() { printf '%s\n' "${1#*/}"; }
fm_repository_identity_owner() {
  local owner_repo=${1#*/}
  printf '%s\n' "${owner_repo%%/*}"
}

fm_repository_policy_array_contains() {  # <config> <json-field> <value>
  local file=$1 field=$2 value=$3
  jq -e --arg field "$field" --arg value "$value" '
    ((.[ $field ] // (if $field == "approvedAccounts" then .approvedOwners else [] end))
      | map(ascii_downcase) | index($value | ascii_downcase)) != null
  ' "$file" >/dev/null 2>&1
}

# Globals set on success:
#   FM_REPOSITORY_POLICY_FILE
#   FM_REPOSITORY_POLICY_PROJECT
#   FM_REPOSITORY_POLICY_UPSTREAM_URL / _UPSTREAM_ID
#   FM_REPOSITORY_POLICY_FORK_URL / _FORK_ID
#   FM_REPOSITORY_POLICY_DEFAULT_BRANCH
fm_repository_policy_load() {  # <project>
  local project=$1 file upstream fork default owner
  file=$(fm_repository_policy_config_path) || return 1
  fm_repository_policy_validate "$file" || return 1
  if ! jq -e --arg project "$project" '.repositories[$project] != null' "$file" >/dev/null 2>&1; then
    printf 'REFUSED: project %s has no explicit upstream/fork entry in %s.\n' "$project" "$file" >&2
    return 1
  fi
  upstream=$(jq -r --arg project "$project" '.repositories[$project].upstreamFetchUrl' "$file") || return 1
  fork=$(jq -r --arg project "$project" '.repositories[$project].forkPushUrl' "$file") || return 1
  default=$(jq -r --arg project "$project" '.repositories[$project].defaultBranch // "main"' "$file") || return 1
  FM_REPOSITORY_POLICY_UPSTREAM_ID=$(fm_repository_url_identity "$upstream") || {
    printf 'REFUSED: project %s has a non-GitHub upstreamFetchUrl: %s.\n' "$project" "$upstream" >&2
    return 1
  }
  FM_REPOSITORY_POLICY_FORK_ID=$(fm_repository_url_identity "$fork") || {
    printf 'REFUSED: project %s has a non-GitHub forkPushUrl: %s.\n' "$project" "$fork" >&2
    return 1
  }
  owner=$(fm_repository_identity_owner "$FM_REPOSITORY_POLICY_FORK_ID")
  if ! fm_repository_policy_array_contains "$file" approvedOwners "$owner"; then
    printf 'REFUSED: project %s fork owner %s is not captain-approved in %s.\n' "$project" "$owner" "$file" >&2
    return 1
  fi
  FM_REPOSITORY_POLICY_FILE=$file
  FM_REPOSITORY_POLICY_PROJECT=$project
  FM_REPOSITORY_POLICY_UPSTREAM_URL=$upstream
  FM_REPOSITORY_POLICY_FORK_URL=$fork
  FM_REPOSITORY_POLICY_DEFAULT_BRANCH=$default
}

fm_repository_authenticated_account() {  # <github-host>
  local host=$1 output account
  if ! command -v gh-axi >/dev/null 2>&1; then
    printf 'REFUSED: gh-axi is required to resolve the authenticated GitHub account for %s.\n' "$host" >&2
    return 1
  fi
  output=$(gh-axi api --hostname "$host" /user --jq .login 2>&1) || {
    printf 'REFUSED: could not resolve the authenticated GitHub account for %s: %s\n' "$host" "$output" >&2
    return 1
  }
  account=$(printf '%s\n' "$output" | sed -n 's/^[[:space:]]*body:[[:space:]]*//p' | head -1)
  account=${account#\"}
  account=${account%\"}
  if [ -z "$account" ]; then
    printf 'REFUSED: gh-axi returned no authenticated GitHub account for %s.\n' "$host" >&2
    return 1
  fi
  printf '%s\n' "$account"
}

fm_repository_policy_authorize_identity() {  # <action> <identity>
  local action=$1 identity=$2 host owner account
  host=$(fm_repository_identity_host "$identity")
  owner=$(fm_repository_identity_owner "$identity")
  if ! fm_repository_policy_array_contains "$FM_REPOSITORY_POLICY_FILE" approvedOwners "$owner"; then
    printf 'REFUSED: %s targets %s, whose owner %s is not captain-approved in %s.\n' \
      "$action" "$identity" "$owner" "$FM_REPOSITORY_POLICY_FILE" >&2
    return 1
  fi
  account=$(fm_repository_authenticated_account "$host") || return 1
  if ! fm_repository_policy_array_contains "$FM_REPOSITORY_POLICY_FILE" approvedAccounts "$account"; then
    printf 'REFUSED: authenticated GitHub account %s is not captain-approved in %s; %s would target %s.\n' \
      "$account" "$FM_REPOSITORY_POLICY_FILE" "$action" "$identity" >&2
    return 1
  fi
  FM_REPOSITORY_POLICY_AUTH_ACCOUNT=$account
}
