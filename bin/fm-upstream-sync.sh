#!/usr/bin/env bash
# Detect and safely stage original-author upstream changes for captain-owned forks.
#
# Usage:
#   fm-upstream-sync.sh check [<project>]
#   fm-upstream-sync.sh scheduled [<project>]
#   fm-upstream-sync.sh baseline <project> <worktree>
#
# `check` is the on-demand path. `scheduled` runs only entries whose last
# completed check is older than upstreamSync.intervalHours (24 by default).
# Both use the explicit URLs in config/repository-policy.json; neither remote
# names nor a checkout's `origin` participate in the decision.
#
# Fetches land in state/upstream-sync/repos/<project>.git, a bare cache with no
# working tree. Repository validation uses a disposable detached worktree of
# that cache and never changes a project checkout. A clean upstream fast-forward
# reaches the configured fork default only after validation and every repository
# gate passes. Every other candidate is preserved on a stable
# fm/upstream-sync-<upstream-oid> branch with a durable review packet.
#
# `baseline` fetches the configured fork default into a dedicated local ref in
# an already-isolated task worktree and resets that clean task worktree to it.
# fm-spawn uses this after acquiring a new worktree so normal work starts from
# the newest fork state accepted by the synchronization workflow.
#
# No path force-pushes, deletes a remote branch, rewrites history, updates an
# original-author repository, deploys, restarts a service, or runs a migration.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SYNC_ROOT="$STATE/upstream-sync"

# shellcheck source=bin/fm-repository-policy-lib.sh
. "$SCRIPT_DIR/fm-repository-policy-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() { sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//; $d' >&2; exit 2; }
die() { printf 'REFUSED: %s\n' "$1" >&2; return 1; }
now_epoch() {
  local value=${FM_UPSTREAM_SYNC_NOW:-$(date +%s)}
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$value"
}

ACTIVE_LOCK=
VALIDATION_WORKTREE=
VALIDATION_CACHE=
cleanup() {
  if [ -n "$VALIDATION_WORKTREE" ] && [ -n "$VALIDATION_CACHE" ]; then
    git --git-dir "$VALIDATION_CACHE" worktree remove --force "$VALIDATION_WORKTREE" >/dev/null 2>&1 || true
  fi
  VALIDATION_WORKTREE=
  VALIDATION_CACHE=
  if [ -n "$ACTIVE_LOCK" ]; then
    fm_lock_release "$ACTIVE_LOCK" || true
    ACTIVE_LOCK=
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

write_atomic() {  # <destination>, content on stdin
  local destination=$1 tmp
  mkdir -p "$(dirname "$destination")" || return 1
  tmp=$(mktemp "${destination}.XXXXXX") || return 1
  if cat > "$tmp" && mv -f "$tmp" "$destination"; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

state_value() {  # <state-file> <key>
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1
}

policy_json() {  # <jq expression>
  jq -r --arg project "$FM_REPOSITORY_POLICY_PROJECT" \
    ".repositories[\$project].upstreamSync // {} | $1" \
    "$FM_REPOSITORY_POLICY_FILE"
}

policy_array() {  # <field>
  policy_json "(.${1} // [])[]"
}

decode_base64() {
  if base64 --help 2>&1 | grep -q -- '--decode'; then
    base64 --decode
  else
    base64 -D
  fi
}

fetch_release_tags() {  # sets RELEASE_TAGS
  local host owner_repo encoded output
  host=$(fm_repository_identity_host "$FM_REPOSITORY_POLICY_UPSTREAM_ID")
  owner_repo=$(fm_repository_identity_owner_repo "$FM_REPOSITORY_POLICY_UPSTREAM_ID")
  command -v gh-axi >/dev/null 2>&1 || {
    printf 'UPSTREAM_SYNC: %s: release detection failed: gh-axi is unavailable\n' \
      "$FM_REPOSITORY_POLICY_PROJECT" >&2
    return 1
  }
  output=$(GH_HOST="$host" gh-axi api "/repos/$owner_repo/releases?per_page=100" \
    --jq 'map(.tag_name) | @base64' 2>&1) || {
    printf 'UPSTREAM_SYNC: %s: release detection failed for %s: %s\n' \
      "$FM_REPOSITORY_POLICY_PROJECT" "$FM_REPOSITORY_POLICY_UPSTREAM_ID" \
      "$(printf '%s\n' "$output" | head -1)" >&2
    return 1
  }
  case "$output" in
    api_response:*)
      encoded=$(printf '%s\n' "$output" | sed -n 's/^[[:space:]]*body:[[:space:]]*//p' | head -1)
      encoded=${encoded#\"}; encoded=${encoded%\"}
      ;;
    *) encoded=$output ;;
  esac
  [ -n "$encoded" ] || encoded=W10=
  RELEASE_TAGS=$(printf '%s' "$encoded" | decode_base64 2>/dev/null \
    | jq -r '.[] | if type == "object" then .tag_name else . end' 2>/dev/null | LC_ALL=C sort -u) || {
      printf 'UPSTREAM_SYNC: %s: release detection returned an unreadable response\n' \
        "$FM_REPOSITORY_POLICY_PROJECT" >&2
      return 1
    }
}

cache_ref_oid() {  # <cache> <ref>
  git --git-dir "$1" rev-parse --verify --quiet "$2^{commit}" 2>/dev/null
}

fetch_upstream() {  # <cache>
  local cache=$1 output
  authorize_fetch "$cache" upstream-fetch "$FM_REPOSITORY_POLICY_UPSTREAM_URL" \
    "$FM_REPOSITORY_POLICY_UPSTREAM_ID" || return 1
  output=$(git --git-dir "$cache" fetch --quiet --force "$EFFECTIVE_FETCH_URL" \
    "+refs/heads/$FM_REPOSITORY_POLICY_DEFAULT_BRANCH:refs/fm/upstream/heads/$FM_REPOSITORY_POLICY_DEFAULT_BRANCH" \
    '+refs/tags/*:refs/fm/upstream/tags/*' 2>&1) || {
      printf 'UPSTREAM_SYNC: %s: upstream fetch failed for %s: %s\n' \
        "$FM_REPOSITORY_POLICY_PROJECT" "$FM_REPOSITORY_POLICY_UPSTREAM_ID" \
        "$(printf '%s\n' "$output" | head -1)" >&2
      return 1
    }
}

fetch_fork() {  # <cache>
  local cache=$1 output
  authorize_fetch "$cache" fork-fetch "$FM_REPOSITORY_POLICY_FORK_URL" \
    "$FM_REPOSITORY_POLICY_FORK_ID" || return 1
  output=$(git --git-dir "$cache" fetch --quiet --force "$EFFECTIVE_FETCH_URL" \
    "+refs/heads/$FM_REPOSITORY_POLICY_DEFAULT_BRANCH:refs/fm/fork/heads/$FM_REPOSITORY_POLICY_DEFAULT_BRANCH" \
    2>&1) || {
      printf 'REFUSED: project %s fork %s is missing or its default branch cannot be fetched: %s\n' \
        "$FM_REPOSITORY_POLICY_PROJECT" "$FM_REPOSITORY_POLICY_FORK_ID" \
        "$(printf '%s\n' "$output" | head -1)" >&2
      return 1
    }
}

authorize_fetch() {  # <git-dir> <action> <configured-url> <expected-identity>
  local git_dir=$1 action=$2 configured=$3 expected=$4 actual
  EFFECTIVE_FETCH_URL=$(fm_repository_effective_fetch_url "$git_dir" "$configured") || {
    printf 'REFUSED: %s effective URL cannot be resolved for project %s.\n' \
      "$action" "$FM_REPOSITORY_POLICY_PROJECT" >&2
    return 1
  }
  actual=$(fm_repository_url_identity "$EFFECTIVE_FETCH_URL") || {
    printf 'REFUSED: %s has no verifiable GitHub repository target: %s.\n' \
      "$action" "$EFFECTIVE_FETCH_URL" >&2
    return 1
  }
  if [ "$actual" != "$expected" ]; then
    printf 'REFUSED: %s would read from %s, but project %s explicitly configures %s.\n' \
      "$action" "$actual" "$FM_REPOSITORY_POLICY_PROJECT" "$expected" >&2
    return 1
  fi
}

list_upstream_tags() {  # <cache>
  git --git-dir "$1" for-each-ref --format='%(refname:strip=4)' refs/fm/upstream/tags \
    | LC_ALL=C sort -u
}

print_new_snapshot_items() {  # <kind> <old-file> <new-file>
  local kind=$1 old=$2 new=$3 item
  [ -f "$old" ] || return 0
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    printf 'UPSTREAM_SYNC: %s: new upstream %s %s\n' \
      "$FM_REPOSITORY_POLICY_PROJECT" "$kind" "$item"
  done < <(comm -13 "$old" "$new")
}

maybe_interrupt() {  # deterministic crash boundary used by recovery tests
  if [ "${FM_UPSTREAM_SYNC_INTERRUPT_AFTER:-}" = "$1" ]; then
    printf 'UPSTREAM_SYNC: %s: interrupted after %s; durable prior state was preserved\n' \
      "$FM_REPOSITORY_POLICY_PROJECT" "$1" >&2
    return 99
  fi
}

load_command() {  # <field>; fills COMMAND_ARGV
  local field=$1 value
  COMMAND_ARGV=()
  while IFS= read -r value; do
    COMMAND_ARGV+=("$value")
  done < <(policy_array "$field")
}

run_repository_checks() {  # <cache> <candidate> <project> <log-prefix>
  local cache=$1 candidate=$2 project=$3 log_prefix=$4 rc
  VALIDATION_RESULT=not-configured
  GATE_RESULT=clear
  VALIDATION_LOG="${log_prefix}.validation.log"
  GATE_LOG="${log_prefix}.gate.log"
  mkdir -p "$SYNC_ROOT/worktrees" "$(dirname "$VALIDATION_LOG")" || return 1
  git --git-dir "$cache" worktree prune >/dev/null 2>&1 || true
  VALIDATION_WORKTREE="$SYNC_ROOT/worktrees/${project}.$$.$RANDOM"
  VALIDATION_CACHE=$cache
  if ! git --git-dir "$cache" worktree add --quiet --detach "$VALIDATION_WORKTREE" "$candidate"; then
    VALIDATION_RESULT="worktree-failed"
    return 0
  fi

  load_command validationCommand
  if [ "${#COMMAND_ARGV[@]}" -gt 0 ]; then
    if (cd "$VALIDATION_WORKTREE" && "${COMMAND_ARGV[@]}") >"$VALIDATION_LOG" 2>&1; then
      VALIDATION_RESULT=passed
    else
      rc=$?
      VALIDATION_RESULT="failed(exit=$rc)"
    fi
  else
    printf 'repository-defined validationCommand is not configured\n' > "$VALIDATION_LOG"
  fi

  load_command gateCommand
  if [ "${#COMMAND_ARGV[@]}" -gt 0 ]; then
    if (cd "$VALIDATION_WORKTREE" && "${COMMAND_ARGV[@]}") >"$GATE_LOG" 2>&1; then
      GATE_RESULT=clear
    else
      rc=$?
      GATE_RESULT="review-required(exit=$rc)"
    fi
  else
    : > "$GATE_LOG"
  fi
  git --git-dir "$cache" worktree remove --force "$VALIDATION_WORKTREE" >/dev/null 2>&1 || true
  VALIDATION_WORKTREE=
  VALIDATION_CACHE=
}

path_gate_matches() {  # <cache> <fork-oid> <upstream-oid>
  local cache=$1 fork_oid=$2 upstream_oid=$3 category field pattern path
  CHANGED_PATHS=$(git --git-dir "$cache" diff --name-only "$fork_oid" "$upstream_oid" 2>/dev/null || true)
  for category in protected deployment migration repository; do
    case "$category" in
      protected) field=protectedPaths ;;
      deployment) field=deploymentPaths ;;
      migration) field=migrationPaths ;;
      repository) field=reviewRequiredPaths ;;
    esac
    while IFS= read -r pattern; do
      [ -n "$pattern" ] || continue
      while IFS= read -r path; do
        [ -n "$path" ] || continue
        # The pattern is captain-authored policy data and is matched as a shell
        # glob without eval or command execution.
        # shellcheck disable=SC2254
        case "$path" in
          $pattern) printf '%s:%s (pattern %s)\n' "$category" "$path" "$pattern" ;;
        esac
      done <<< "$CHANGED_PATHS"
    done < <(policy_array "$field")
  done
}

make_merge_candidate() {  # <cache> <fork-oid> <upstream-oid>
  local cache=$1 fork_oid=$2 upstream_oid=$3 output tree timestamp message
  output=$(git --git-dir "$cache" merge-tree --write-tree "$fork_oid" "$upstream_oid" 2>&1) || {
    MERGE_RESULT=conflict
    MERGE_DETAIL=$(printf '%s\n' "$output" | tail -n +2 | head -20)
    MERGE_CANDIDATE=$upstream_oid
    return 0
  }
  tree=$(printf '%s\n' "$output" | head -1)
  if ! git --git-dir "$cache" cat-file -e "$tree^{tree}" 2>/dev/null; then
    MERGE_RESULT=conflict
    MERGE_DETAIL='merge-tree did not produce a valid tree'
    MERGE_CANDIDATE=$upstream_oid
    return 0
  fi
  timestamp=$(git --git-dir "$cache" show -s --format=%ct "$upstream_oid" 2>/dev/null || date +%s)
  message="Firstmate upstream sync: $FM_REPOSITORY_POLICY_PROJECT $upstream_oid"
  MERGE_CANDIDATE=$(printf '%s\n' "$message" | env \
    GIT_AUTHOR_NAME='Firstmate Upstream Sync' GIT_AUTHOR_EMAIL='firstmate@localhost' \
    GIT_COMMITTER_NAME='Firstmate Upstream Sync' GIT_COMMITTER_EMAIL='firstmate@localhost' \
    GIT_AUTHOR_DATE="$timestamp +0000" GIT_COMMITTER_DATE="$timestamp +0000" \
    git --git-dir "$cache" commit-tree "$tree" -p "$fork_oid" -p "$upstream_oid") || return 1
  MERGE_RESULT=clean
  MERGE_DETAIL='isolated merge candidate created without changing a project working tree'
}

authorize_push() {  # <cache> <action>; sets EFFECTIVE_PUSH_URL
  local cache=$1 action=$2
  EFFECTIVE_PUSH_URL=$(fm_repository_effective_push_url "$cache" "$FM_REPOSITORY_POLICY_FORK_URL") || {
    printf 'REFUSED: %s effective push URL cannot be resolved for project %s.\n' \
      "$action" "$FM_REPOSITORY_POLICY_PROJECT" >&2
    return 1
  }
  fm_repository_policy_authorize_url "$action" "$EFFECTIVE_PUSH_URL" \
    "$FM_REPOSITORY_POLICY_FORK_ID" || return 1
  printf 'DELIVERY TARGET: project=%s action=%s repository=%s account=%s\n' \
    "$FM_REPOSITORY_POLICY_PROJECT" "$action" "$FM_REPOSITORY_POLICY_EFFECTIVE_ID" \
    "$FM_REPOSITORY_POLICY_AUTH_ACCOUNT" >&2
}

push_new_ref() {  # <cache> <source> <destination-ref> <action>
  local cache=$1 source=$2 destination=$3 action=$4 output existing
  existing=$(git --git-dir "$cache" ls-remote "$FM_REPOSITORY_POLICY_FORK_URL" "$destination" 2>/dev/null \
    | awk 'NR == 1 { print $1 }')
  if [ -n "$existing" ]; then
    if [ "$existing" = "$source" ]; then
      printf 'UPSTREAM_SYNC: %s: %s already exists at %s; no duplicate push\n' \
        "$FM_REPOSITORY_POLICY_PROJECT" "$destination" "$source"
      return 0
    fi
    printf 'REFUSED: project %s will not overwrite existing %s at %s with %s.\n' \
      "$FM_REPOSITORY_POLICY_PROJECT" "$destination" "$existing" "$source" >&2
    return 1
  fi
  authorize_push "$cache" "$action" || return 1
  output=$(git --git-dir "$cache" push --porcelain "$EFFECTIVE_PUSH_URL" \
    "$source:$destination" 2>&1) || {
      printf 'REFUSED: project %s push to %s failed without force: %s\n' \
        "$FM_REPOSITORY_POLICY_PROJECT" "$FM_REPOSITORY_POLICY_EFFECTIVE_ID" \
        "$(printf '%s\n' "$output" | head -1)" >&2
      return 1
    }
}

push_fast_forward() {  # <cache> <source>
  local cache=$1 source=$2 destination output
  destination="refs/heads/$FM_REPOSITORY_POLICY_DEFAULT_BRANCH"
  authorize_push "$cache" upstream-default-fast-forward || return 1
  output=$(git --git-dir "$cache" push --porcelain "$EFFECTIVE_PUSH_URL" \
    "$source:$destination" 2>&1) || {
      printf 'REFUSED: project %s default-branch fast-forward to %s failed without force: %s\n' \
        "$FM_REPOSITORY_POLICY_PROJECT" "$FM_REPOSITORY_POLICY_EFFECTIVE_ID" \
        "$(printf '%s\n' "$output" | head -1)" >&2
      return 1
    }
}

write_review_packet() {  # <packet> <branch> <fork> <upstream> <candidate> <reasons-file> <published>
  local packet=$1 branch=$2 fork_oid=$3 upstream_oid=$4 candidate=$5 reasons_file=$6 published=$7
  write_atomic "$packet" <<EOF
# Upstream synchronization review: $FM_REPOSITORY_POLICY_PROJECT

- Upstream fetch repository: \`$FM_REPOSITORY_POLICY_UPSTREAM_ID\`
- Captain fork repository: \`$FM_REPOSITORY_POLICY_FORK_ID\`
- Default branch: \`$FM_REPOSITORY_POLICY_DEFAULT_BRANCH\`
- Fork commit before review: \`$fork_oid\`
- Upstream commit: \`$upstream_oid\`
- Isolated candidate commit: \`$candidate\`
- Review branch: \`$branch\` ($published)
- Merge assessment: $MERGE_RESULT - $MERGE_DETAIL
- Repository validation: $VALIDATION_RESULT (log: \`$VALIDATION_LOG\`)
- Repository gate command: $GATE_RESULT (log: \`$GATE_LOG\`)

## Why captain review is required

$(sed 's/^/- /' "$reasons_file")

## Decision boundary

Review and integrate the isolated candidate deliberately. This workflow has not changed the fork default branch, deployed, restarted a service, run a migration, force-pushed, rewritten history, deleted a branch, or written to the original-author repository.
EOF
}

persist_completed_check() {  # <state-file> <upstream> <fork> <outcome> <branch> <tags> <releases>
  local state_file=$1 upstream_oid=$2 fork_oid=$3 outcome=$4 branch=$5 tags=$6 releases=$7
  write_atomic "$state_file" <<EOF || return 1
lastChecked=$(now_epoch)
upstreamDefault=$upstream_oid
forkDefault=$fork_oid
outcome=$outcome
reviewBranch=$branch
EOF
  write_atomic "${state_file%.state}.tags" < "$tags" || return 1
  write_atomic "${state_file%.state}.releases" < "$releases" || return 1
}

sync_project() {  # <project> <scheduled:0|1>
  local project=$1 scheduled=$2 cache project_dir state_file old_tags old_releases
  local current_tags current_releases upstream_ref fork_ref upstream_oid fork_oid
  local prior_upstream prior_fork prior_outcome interval last_checked age
  local fork_unique upstream_unique ff candidate review_branch packet reasons_file path_matches
  local outcome final_fork require_review

  fm_repository_policy_load "$project" || return 1
  if [ "$scheduled" -eq 1 ] && [ "$FM_REPOSITORY_POLICY_SYNC_ENABLED" != true ]; then
    return 0
  fi
  project_dir="$SYNC_ROOT/projects/$project"
  cache="$SYNC_ROOT/repos/$project.git"
  state_file="$project_dir/check.state"
  old_tags="$project_dir/check.tags"
  old_releases="$project_dir/check.releases"
  mkdir -p "$SYNC_ROOT/repos" "$project_dir" "$SYNC_ROOT/locks" "$SYNC_ROOT/reviews" "$SYNC_ROOT/logs" || return 1

  if [ "$scheduled" -eq 1 ]; then
    interval=$(( FM_REPOSITORY_POLICY_SYNC_INTERVAL_HOURS * 3600 ))
    last_checked=$(state_value "$state_file" lastChecked)
    case "$last_checked" in ''|*[!0-9]*) ;; *)
      age=$(( $(now_epoch) - last_checked ))
      [ "$age" -ge "$interval" ] || return 0
      ;;
    esac
  fi

  ACTIVE_LOCK="$SYNC_ROOT/locks/$project.lock"
  fm_lock_acquire_wait "$ACTIVE_LOCK" || return 1
  if [ ! -d "$cache" ]; then
    git init --quiet --bare "$cache" || { cleanup; return 1; }
  fi

  fetch_upstream "$cache" || { cleanup; return 1; }
  fetch_release_tags || { cleanup; return 1; }
  fetch_fork "$cache" || { cleanup; return 1; }
  maybe_interrupt fetch || { local interrupt_rc=$?; cleanup; return "$interrupt_rc"; }

  upstream_ref="refs/fm/upstream/heads/$FM_REPOSITORY_POLICY_DEFAULT_BRANCH"
  fork_ref="refs/fm/fork/heads/$FM_REPOSITORY_POLICY_DEFAULT_BRANCH"
  upstream_oid=$(cache_ref_oid "$cache" "$upstream_ref") || {
    printf 'UPSTREAM_SYNC: %s: fetched upstream default is not a commit\n' "$project" >&2
    cleanup; return 1
  }
  fork_oid=$(cache_ref_oid "$cache" "$fork_ref") || {
    printf 'REFUSED: project %s fork default branch %s is missing.\n' \
      "$project" "$FM_REPOSITORY_POLICY_DEFAULT_BRANCH" >&2
    cleanup; return 1
  }

  current_tags="$project_dir/current.tags.$$"
  current_releases="$project_dir/current.releases.$$"
  list_upstream_tags "$cache" > "$current_tags"
  printf '%s\n' "$RELEASE_TAGS" | sed '/^$/d' > "$current_releases"
  print_new_snapshot_items tag "$old_tags" "$current_tags"
  print_new_snapshot_items release "$old_releases" "$current_releases"
  prior_upstream=$(state_value "$state_file" upstreamDefault)
  prior_fork=$(state_value "$state_file" forkDefault)
  prior_outcome=$(state_value "$state_file" outcome)
  if [ -n "$prior_upstream" ] && [ "$prior_upstream" != "$upstream_oid" ]; then
    printf 'UPSTREAM_SYNC: %s: new upstream default commit %s..%s\n' \
      "$project" "$prior_upstream" "$upstream_oid"
  fi

  if [ "$upstream_oid" = "$fork_oid" ]; then
    outcome=already-current
    if [ "$prior_upstream" = "$upstream_oid" ] && [ "$prior_fork" = "$fork_oid" ]; then
      printf 'UPSTREAM_SYNC: %s: already processed %s; no duplicate work\n' "$project" "$upstream_oid"
    else
      printf 'UPSTREAM_SYNC: %s: fork default already matches upstream %s\n' "$project" "$upstream_oid"
    fi
    persist_completed_check "$state_file" "$upstream_oid" "$fork_oid" "$outcome" "" \
      "$current_tags" "$current_releases" || { cleanup; return 1; }
    rm -f "$current_tags" "$current_releases"
    cleanup
    return 0
  fi

  if [ "$prior_upstream" = "$upstream_oid" ] && [ "$prior_fork" = "$fork_oid" ] \
    && [ "$prior_outcome" = review-required ]; then
    printf 'UPSTREAM_SYNC: %s: candidate %s already has a review packet; no duplicate work\n' \
      "$project" "$upstream_oid"
    persist_completed_check "$state_file" "$upstream_oid" "$fork_oid" review-required \
      "$(state_value "$state_file" reviewBranch)" "$current_tags" "$current_releases" \
      || { cleanup; return 1; }
    rm -f "$current_tags" "$current_releases"
    cleanup
    return 0
  fi

  fork_unique=$(git --git-dir "$cache" rev-list --count "$upstream_oid..$fork_oid" 2>/dev/null || echo '?')
  upstream_unique=$(git --git-dir "$cache" rev-list --count "$fork_oid..$upstream_oid" 2>/dev/null || echo '?')
  ff=no
  git --git-dir "$cache" merge-base --is-ancestor "$fork_oid" "$upstream_oid" 2>/dev/null && ff=yes
  candidate=$upstream_oid
  MERGE_RESULT=not-needed
  MERGE_DETAIL='fork default is an ancestor of upstream'
  if [ "$fork_unique" != 0 ] || [ "$ff" != yes ]; then
    make_merge_candidate "$cache" "$fork_oid" "$upstream_oid" || { cleanup; return 1; }
    candidate=$MERGE_CANDIDATE
  fi

  run_repository_checks "$cache" "$candidate" "$project" "$SYNC_ROOT/logs/$project-$upstream_oid" \
    || { cleanup; return 1; }
  reasons_file="$project_dir/reasons.$$"
  : > "$reasons_file"
  [ "$fork_unique" = 0 ] || printf 'fork default has %s unique commit(s) relative to upstream\n' "$fork_unique" >> "$reasons_file"
  [ "$ff" = yes ] || printf 'upstream update is not a true fast-forward of the fork default\n' >> "$reasons_file"
  [ "$MERGE_RESULT" != conflict ] || printf 'isolated integration assessment found merge conflicts\n' >> "$reasons_file"
  [ "$VALIDATION_RESULT" = passed ] || printf 'repository validation is %s\n' "$VALIDATION_RESULT" >> "$reasons_file"
  [ "$GATE_RESULT" = clear ] || printf 'repository gate command is %s\n' "$GATE_RESULT" >> "$reasons_file"
  path_matches=$(path_gate_matches "$cache" "$fork_oid" "$upstream_oid")
  [ -z "$path_matches" ] || printf '%s\n' "$path_matches" >> "$reasons_file"
  require_review=$(policy_json '.requireCaptainReview // false')
  [ "$require_review" != true ] || printf 'repository policy always requires captain review\n' >> "$reasons_file"

  if [ ! -s "$reasons_file" ]; then
    # The four automatic-update conditions are all visibly rechecked here:
    # no fork-unique commits, true FF, passing validation, and no repo gate.
    if [ "$fork_unique" != 0 ] || [ "$ff" != yes ] || [ "$VALIDATION_RESULT" != passed ] \
      || [ "$GATE_RESULT" != clear ] || [ -n "$path_matches" ] || [ "$require_review" = true ]; then
      printf 'internal safety invariant rejected automatic fast-forward\n' >> "$reasons_file"
    fi
  fi

  if [ ! -s "$reasons_file" ]; then
    push_fast_forward "$cache" "$upstream_oid" || { rm -f "$reasons_file"; cleanup; return 1; }
    maybe_interrupt default-push || { local interrupt_rc=$?; rm -f "$reasons_file"; cleanup; return "$interrupt_rc"; }
    final_fork=$upstream_oid
    outcome=fast-forwarded
    printf 'UPSTREAM_SYNC: %s: fast-forwarded captain fork %s from %s to %s after validation\n' \
      "$project" "$FM_REPOSITORY_POLICY_FORK_ID" "$fork_oid" "$upstream_oid"
    persist_completed_check "$state_file" "$upstream_oid" "$final_fork" "$outcome" "" \
      "$current_tags" "$current_releases" || { rm -f "$reasons_file"; cleanup; return 1; }
  else
    review_branch="fm/upstream-sync-$upstream_oid"
    packet="$SYNC_ROOT/reviews/$project-$upstream_oid.md"
    write_review_packet "$packet" "$review_branch" "$fork_oid" "$upstream_oid" "$candidate" \
      "$reasons_file" pending || { rm -f "$reasons_file"; cleanup; return 1; }
    push_new_ref "$cache" "$candidate" "refs/heads/$review_branch" upstream-review-branch \
      || { rm -f "$reasons_file"; cleanup; return 1; }
    write_review_packet "$packet" "$review_branch" "$fork_oid" "$upstream_oid" "$candidate" \
      "$reasons_file" published || { rm -f "$reasons_file"; cleanup; return 1; }
    maybe_interrupt review-push || { local interrupt_rc=$?; rm -f "$reasons_file"; cleanup; return "$interrupt_rc"; }
    outcome=review-required
    final_fork=$fork_oid
    printf 'UPSTREAM_SYNC: %s: REVIEW_REQUIRED branch=%s packet=%s (fork-only=%s upstream-only=%s)\n' \
      "$project" "$review_branch" "$packet" "$fork_unique" "$upstream_unique"
    persist_completed_check "$state_file" "$upstream_oid" "$final_fork" "$outcome" "$review_branch" \
      "$current_tags" "$current_releases" || { rm -f "$reasons_file"; cleanup; return 1; }
  fi
  rm -f "$reasons_file" "$current_tags" "$current_releases"
  cleanup
}

baseline_worktree() {  # <project> <worktree>
  local project=$1 worktree=$2 top git_dir target expected actual status
  top=$(git -C "$worktree" rev-parse --show-toplevel 2>/dev/null) \
    || { die "baseline target is not a Git worktree: $worktree"; return 1; }
  fm_repository_policy_load "$project" || return 1
  git_dir=$(git -C "$top" rev-parse --absolute-git-dir 2>/dev/null) || {
    die "cannot resolve Git metadata for baseline target $top"; return 1;
  }
  authorize_fetch "$git_dir" fork-baseline-fetch "$FM_REPOSITORY_POLICY_FORK_URL" \
    "$FM_REPOSITORY_POLICY_FORK_ID" || return 1
  target="refs/remotes/firstmate-fork/$FM_REPOSITORY_POLICY_DEFAULT_BRANCH"
  status=$(git -C "$top" status --porcelain 2>/dev/null) || {
    die "cannot inspect task worktree $top before selecting its verified baseline"; return 1;
  }
  [ -z "$status" ] || {
    die "task worktree $top is not clean; baseline selection will not discard its changes"; return 1;
  }
  git -C "$top" fetch --quiet "$EFFECTIVE_FETCH_URL" \
    "+refs/heads/$FM_REPOSITORY_POLICY_DEFAULT_BRANCH:$target" || {
      die "cannot fetch explicit captain fork $FM_REPOSITORY_POLICY_FORK_ID for baseline selection"; return 1;
    }
  expected=$(git -C "$top" rev-parse --verify --quiet "$target^{commit}") || {
    die "configured fork default is not a commit: $FM_REPOSITORY_POLICY_FORK_ID/$FM_REPOSITORY_POLICY_DEFAULT_BRANCH"; return 1;
  }
  git -C "$top" reset --hard "$target" >/dev/null || {
    die "cannot set isolated task worktree $top to verified fork baseline $target"; return 1;
  }
  actual=$(git -C "$top" rev-parse --verify --quiet HEAD 2>/dev/null || true)
  [ "$actual" = "$expected" ] || {
    die "task worktree $top did not reach verified fork baseline $expected"; return 1;
  }
  printf 'UPSTREAM BASELINE: project=%s repository=%s branch=%s commit=%s\n' \
    "$project" "$FM_REPOSITORY_POLICY_FORK_ID" "$FM_REPOSITORY_POLICY_DEFAULT_BRANCH" "$expected"
}

run_checks() {  # <scheduled:0|1> [project]
  local scheduled=$1 project=${2:-} candidate rc=0 one_rc
  if [ -e "$FM_HOME/.fm-secondmate-home" ] || [ -L "$FM_HOME/.fm-secondmate-home" ]; then
    [ "$scheduled" -eq 1 ] && return 0
  fi
  if [ -n "$project" ]; then
    sync_project "$project" "$scheduled"
    return $?
  fi
  if ! fm_repository_policy_validate; then
    [ "$scheduled" -eq 0 ] && return 1
    printf 'UPSTREAM_SYNC: skipped: repository policy is missing or invalid; no repository was fetched or written\n' >&2
    return 0
  fi
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if sync_project "$candidate" "$scheduled"; then
      :
    else
      one_rc=$?
      rc=$one_rc
    fi
  done < <(fm_repository_policy_projects)
  return "$rc"
}

case "${1:-}" in
  check)
    [ "$#" -le 2 ] || usage
    run_checks 0 "${2:-}"
    ;;
  scheduled)
    [ "$#" -le 2 ] || usage
    run_checks 1 "${2:-}"
    ;;
  baseline)
    [ "$#" -eq 3 ] || usage
    baseline_worktree "$2" "$3"
    ;;
  -h|--help) usage ;;
  *) usage ;;
esac
