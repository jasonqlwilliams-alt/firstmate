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
    def clean_string: type == "string" and length > 0 and (test("[\\n\\r]") | not);
    def optional_strings: . == null or (type == "array" and all(.[]; clean_string));
    def optional_argv: . == null or (type == "array" and length > 0 and all(.[]; clean_string));
    def sync_ok:
      (.upstreamSync // {}) as $sync
      | ($sync | type) == "object"
        and (($sync.enabled // true) | type) == "boolean"
        and (($sync.intervalHours // 24) | type) == "number"
        and (($sync.intervalHours // 24) >= 1)
        and (($sync.intervalHours // 24) <= 8760)
        and (($sync.intervalHours // 24) == (($sync.intervalHours // 24) | floor))
        and (($sync.validationCommand // null) | optional_argv)
        and (($sync.gateCommand // null) | optional_argv)
        and (($sync.protectedPaths // null) | optional_strings)
        and (($sync.deploymentPaths // null) | optional_strings)
        and (($sync.migrationPaths // null) | optional_strings)
        and (($sync.reviewRequiredPaths // null) | optional_strings)
        and (($sync.requireCaptainReview // false) | type) == "boolean";
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
      ((.value.defaultBranch // "main") | type != "string" or length == 0) or
      (.value | sync_ok | not)
    ) then "every repository needs safe URLs/defaultBranch and a well-formed optional upstreamSync policy"
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
#   FM_REPOSITORY_POLICY_SYNC_ENABLED / _SYNC_INTERVAL_HOURS
# shellcheck disable=SC2034 # Public globals are consumed by sourcing callers.
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
  if ! git check-ref-format "refs/heads/$default" >/dev/null 2>&1; then
    printf 'REFUSED: project %s has an invalid defaultBranch: %s.\n' "$project" "$default" >&2
    return 1
  fi
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
  FM_REPOSITORY_POLICY_SYNC_ENABLED=$(jq -r --arg project "$project" \
    '.repositories[$project].upstreamSync.enabled // true' "$file") || return 1
  FM_REPOSITORY_POLICY_SYNC_INTERVAL_HOURS=$(jq -r --arg project "$project" \
    '.repositories[$project].upstreamSync.intervalHours // 24' "$file") || return 1
}

fm_repository_policy_projects() {  # prints repository keys, sorted
  local file
  file=$(fm_repository_policy_config_path) || return 1
  fm_repository_policy_validate "$file" || return 1
  jq -r '.repositories | keys[]' "$file"
}

# Resolve the URL Git would actually fetch after url.*.insteadOf rewriting.
# `ls-remote --get-url` performs only URL expansion and makes no network call.
fm_repository_effective_fetch_url() {  # <git-dir> <configured-url>
  local git_dir=$1 configured=$2 effective
  effective=$(git --git-dir "$git_dir" ls-remote --get-url "$configured" 2>/dev/null) || return 1
  [ -n "$effective" ] || return 1
  printf '%s\n' "$effective"
}

# Resolve the URL Git itself would use after url.*.insteadOf/pushInsteadOf
# rewriting. Git's `remote get-url --push` does not recognize a remote defined
# only through `git -c`, so this uses a uniquely named ephemeral remote inside
# Firstmate's private bare synchronization cache. It never touches a project
# clone's existing remotes.
fm_repository_effective_push_url() {  # <bare-or-common-git-dir> <configured-url>
  local git_dir=$1 configured=$2 effective remote_name
  remote_name="fm-delivery-effective-$$-${RANDOM:-0}"
  git --git-dir "$git_dir" config "remote.$remote_name.url" "$configured" 2>/dev/null \
    || return 1
  effective=$(git --git-dir "$git_dir" remote get-url --push "$remote_name" 2>/dev/null) || {
    git --git-dir "$git_dir" config --remove-section "remote.$remote_name" 2>/dev/null || true
    return 1
  }
  git --git-dir "$git_dir" config --remove-section "remote.$remote_name" 2>/dev/null || return 1
  [ -n "$effective" ] || return 1
  printf '%s\n' "$effective"
}

fm_repository_authenticated_account() {  # <github-host>
  local host=$1 output account
  if ! command -v gh-axi >/dev/null 2>&1; then
    printf 'REFUSED: gh-axi is required to resolve the authenticated GitHub account for %s.\n' "$host" >&2
    return 1
  fi
  # gh-axi selects a host through GH_HOST; unlike gh it deliberately does not
  # expose a --hostname flag on its api surface.
  output=$(GH_HOST="$host" gh-axi api /user --jq .login 2>&1) || {
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

# shellcheck disable=SC2034 # Public account global is consumed by sourcing callers.
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

# shellcheck disable=SC2034 # Public target global is consumed by sourcing callers.
fm_repository_policy_authorize_url() {  # <action> <effective-url> <expected-identity>
  local action=$1 url=$2 expected=$3 actual
  actual=$(fm_repository_url_identity "$url") || {
    printf 'REFUSED: %s has no verifiable GitHub repository target: %s.\n' "$action" "$url" >&2
    return 1
  }
  if [ "$actual" != "$expected" ]; then
    printf 'REFUSED: %s would write to %s, but project %s permits only %s.\n' \
      "$action" "$actual" "$FM_REPOSITORY_POLICY_PROJECT" "$expected" >&2
    return 1
  fi
  fm_repository_policy_authorize_identity "$action" "$actual" || return 1
  FM_REPOSITORY_POLICY_EFFECTIVE_ID=$actual
}

# Resolve the owner/repository identity for Git origin from a target directory,
# worktree, repository, or direct origin URL.
# Fails with a clear message on stderr if origin is unconfigured or unparseable.
# Callers pin GitHub read-side lookups (gh/gh-axi pr view and pr list) to this
# identity, because a bare lookup can silently resolve through the fork's parent
# to a different repository; it must never authorize a write, which stays the
# repository-policy.json authority. tests/fm-origin-repository.test.sh pins it.
fm_origin_repository() {  # [<target-dir-or-repo-or-url>]
  local target=${1:-.} origin identity raw_url host
  case "$target" in
    https://*|http://*|ssh://*|git://*|git@*:*|*@github.com:*|github.com/*)
      origin=$target
      ;;
    *)
      origin=$(git -C "$target" remote get-url origin 2>/dev/null) \
        || origin=$(git -C "$target" config --get remote.origin.url 2>/dev/null) \
        || {
          printf 'error: repository %s has no configured origin remote\n' "$target" >&2
          return 1
        }
      ;;
  esac
  identity=$(fm_repository_url_identity "$origin") || {
    if [ "$origin" != "$target" ] || [ -d "$target" ]; then
      raw_url=$(git -C "$target" config --get remote.origin.url 2>/dev/null) || true
      if [ -n "$raw_url" ] && [ "$raw_url" != "$origin" ]; then
        identity=$(fm_repository_url_identity "$raw_url") || true
      fi
    fi
  }
  if [ -z "$identity" ]; then
    printf 'error: cannot resolve GitHub repository from origin URL: %s\n' "$origin" >&2
    return 1
  fi
  host=$(fm_repository_identity_host "$identity")
  if [ "$host" != "${GH_HOST:-github.com}" ]; then
    printf 'error: cannot resolve GitHub repository from origin URL: %s\n' "$origin" >&2
    return 1
  fi
  fm_repository_identity_owner_repo "$identity"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_origin_repository "$@"
fi
