#!/bin/bash
set -euo pipefail

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

is_uint() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]
}

is_positive_uint() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_int64() {
  local value="$1"
  is_uint "$value" || return 1
  local max="9223372036854775807"
  if (( ${#value} < ${#max} )); then
    return 0
  fi
  if (( ${#value} == ${#max} )) && [[ ! "$value" > "$max" ]]; then
    return 0
  fi
  return 1
}

is_lt_int64_max() {
  local value="$1"
  is_uint "$value" || return 1
  local max="9223372036854775807"
  if (( ${#value} < ${#max} )); then
    return 0
  fi
  if (( ${#value} == ${#max} )) && [[ "$value" < "$max" ]]; then
    return 0
  fi
  return 1
}

base="${NIGHTLY_BASE_VERSION:-}"
if [[ -z "$base" ]]; then
  fail "Nightlies require a stable base version and positive run ID/attempt."
fi

stable="${base#v}"
if [[ ! "$stable" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  fail "Nightlies require a stable base version and positive run ID/attempt."
fi

major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
patch="${BASH_REMATCH[3]}"

if ! is_int64 "$major" || ! is_int64 "$minor" || ! is_lt_int64_max "$patch"; then
  fail "Nightlies require a stable base version and positive run ID/attempt."
fi

run_id="${GITHUB_RUN_ID:-}"
attempt="${GITHUB_RUN_ATTEMPT:-}"
if ! is_positive_uint "$run_id" || ! is_positive_uint "$attempt"; then
  fail "Nightlies require a stable base version and positive run ID/attempt."
fi

output="${GITHUB_OUTPUT:-}"
if [[ -z "$output" ]]; then
  fail "Nightly preparation requires a source commit and GITHUB_OUTPUT."
fi

commit="$(git rev-parse HEAD 2>/dev/null || true)"
commit_tree="$(git rev-parse 'HEAD^{tree}' 2>/dev/null || true)"
if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]] || [[ ! "$commit_tree" =~ ^[0-9a-f]{40}$ ]]; then
  fail "Nightly preparation requires a source commit and GITHUB_OUTPUT."
fi

next_patch=$(( patch + 1 ))
timestamp="${NIGHTLY_TIMESTAMP:-$(date -u +%Y%m%d%H%M%S)}"
if [[ ! "$timestamp" =~ ^[0-9]{14}$ ]]; then
  fail "Invalid nightly timestamp."
fi

tag="v${major}.${minor}.${next_patch}-nightly.${timestamp}.${run_id}.${attempt}"

has_green_build_for_sha() {
  local repo="$1"
  local sha="$2"
  local mode="$3"
  local expected_tree="$4"
  local runs_json
  runs_json="$(gh api "repos/${repo}/actions/workflows/build.yml/runs?head_sha=${sha}&status=completed&per_page=20" 2>/dev/null)" || return 1

  local run_ids
  if [[ "$mode" == "direct" ]]; then
    run_ids="$(jq -r '
      [.workflow_runs[]?
        | select(.conclusion == "success"
          and (.event == "push" or .event == "workflow_dispatch"))
        | .id] | .[]
    ' <<< "$runs_json" 2>/dev/null)" || return 1
  else
    run_ids="$(jq -r '
      [.workflow_runs[]?
        | select(.conclusion == "success" and .event == "pull_request")
        | .id] | .[]
    ' <<< "$runs_json" 2>/dev/null)" || return 1
  fi

  local run_id_candidate
  for run_id_candidate in $run_ids; do
    [[ "$run_id_candidate" =~ ^[1-9][0-9]*$ ]] || continue
    local jobs_json
    jobs_json="$(gh api --paginate --slurp "repos/${repo}/actions/runs/${run_id_candidate}/jobs" 2>/dev/null)" || continue
    local aggregate_id
    aggregate_id="$(jq -r '
      [.[] | .jobs[]?] as $jobs
      | ["Verify native macOS source", "Verify Swift tooling", "Package and test native macOS arm64", "Verify and package macOS arm64"] as $required
      | if all($required[]; . as $name | any($jobs[]; .name == $name and .status == "completed" and .conclusion == "success")) then
          ($jobs | map(select(.name == "Verify and package macOS arm64" and .status == "completed" and .conclusion == "success")) | last | .id // empty)
        else
          empty
        end
    ' <<< "$jobs_json" 2>/dev/null)" || continue
    [[ "$aggregate_id" =~ ^[1-9][0-9]*$ ]] || continue

    local annotations_json=""
    if annotations_json="$(gh api --paginate --slurp "repos/${repo}/check-runs/${aggregate_id}/annotations" 2>/dev/null)"; then
      local recorded_trees
      recorded_trees="$(jq -r '
        [.[] | .[]? | select(.title == "verified-source-tree") | .message] | unique | .[]
      ' <<< "$annotations_json" 2>/dev/null)" || continue
      if [[ -n "$recorded_trees" ]]; then
        if [[ "$recorded_trees" == "$expected_tree" ]]; then
          return 0
        fi
        continue
      fi
    elif [[ "$mode" == "pr" ]]; then
      continue
    fi

    # push/workflow_dispatch checks out head_sha directly, so its tree is always
    # commit_tree even on runs created before verified-source-tree was recorded.
    # pull_request checks out a synthetic merge commit and must record the tree.
    if [[ "$mode" == "direct" ]]; then
      return 0
    fi
  done
  return 1
}

verified_by_ci="false"
repo="${GITHUB_REPOSITORY:-}"
if [[ "${FORCE_FULL_VERIFICATION:-false}" != "true" ]] \
  && [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  && command -v gh >/dev/null 2>&1 \
  && command -v jq >/dev/null 2>&1; then
  if has_green_build_for_sha "$repo" "$commit" "direct" "$commit_tree"; then
    verified_by_ci="true"
  else
    pulls_json="$(gh api "repos/${repo}/commits/${commit}/pulls?per_page=10" 2>/dev/null || true)"
    if [[ -n "$pulls_json" ]]; then
      pr_heads="$(jq -r --arg repo "$repo" --arg commit "$commit" '
        [.[]?
          | select(.merged_at != null
            and .merge_commit_sha == $commit
            and .base.repo.full_name == $repo)
          | .head.sha] | unique | .[]
      ' <<< "$pulls_json" 2>/dev/null || true)"
      for pr_head in $pr_heads; do
        [[ "$pr_head" =~ ^[0-9a-f]{40}$ ]] || continue
        if has_green_build_for_sha "$repo" "$pr_head" "pr" "$commit_tree"; then
          verified_by_ci="true"
          break
        fi
      done
    fi
  fi
fi

{
  printf 'tag=%s\n' "$tag"
  printf 'commit=%s\n' "$commit"
  printf 'verified_by_ci=%s\n' "$verified_by_ci"
} >> "$output"
