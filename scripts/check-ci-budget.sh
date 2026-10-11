#!/bin/bash
# Input: paginated GitHub Jobs API response including all attempts of this run.
set -euo pipefail

if ! jq -er '
  ["Verify native macOS source", "Verify Swift tooling", "Package and test native macOS arm64"] as $names
  | [.[] | .jobs[]] as $jobs
  | [$names[] as $name
      | [$jobs[] | select(.name == $name)] as $history
      | ($history | map(.run_attempt // 1) | max) as $attempt
      | [$history[] | select((.run_attempt // 1) == $attempt)]
      | if length != 1 then error("Expected one timing record for " + $name) else .[0] end
      | if .status != "completed" then error("Missing completed timing record for " + $name) else . end
      | . as $latest
      | if (.created_at | fromdateiso8601) > (.started_at | fromdateiso8601) then
          # A carried success keeps its original execution, not a new queue.
          # Recover only an exact successful execution match from an older attempt.
          [$history[] | select(
            (.run_attempt // 1) < $attempt and .status == "completed" and .conclusion == "success"
            and $latest.conclusion == "success"
            and .started_at == $latest.started_at and .completed_at == $latest.completed_at
            and (.created_at | fromdateiso8601) <= (.started_at | fromdateiso8601)
          )] | sort_by(.run_attempt // 1) | first
          | if . == null then error("Missing original timing record for carried job " + $name)
            else .created_at as $queued | $latest | .created_at = $queued end
        else . end
      | {name, queued: (.created_at | fromdateiso8601), started: (.started_at | fromdateiso8601), finished: (.completed_at | fromdateiso8601)}
      | if .queued > .started or .started > .finished then error("Invalid timestamp order for " + $name) else . end
    ] as $required
  | ($required | map(.started) | min) as $first
  | ($required | map(.finished - .started) | max) as $elapsed
  | (($required | map(.finished) | max) - $first) as $span
  | ($first - ($required | map(.queued) | min)) as $queue
  | "Required parallel macOS checks (slowest job execution): \($elapsed)s / 600s hard limit (300s target).",
    "Wall-clock span including staggered runner queues: \($span)s.",
    "Initial runner queue (outside budget): \($queue)s.",
    "",
    ($required[] | "- \(.name): \(.finished - .started)s execution, \(.started - .queued)s runner queue."),
    if $elapsed > 600 then error("Required macOS checks exceeded the ten-minute hard limit. Fix the CI regression without removing checks or raising the limit.")
    elif $elapsed > 300 then "::warning::Required macOS checks exceeded the five-minute target but stayed within the ten-minute hard limit."
    else empty end
' "${1:?Usage: check-ci-budget.sh JOBS_JSON}"; then
  echo '::error::Cannot pass the CI execution budget check. See the timing report and error above.'
  exit 1
fi
