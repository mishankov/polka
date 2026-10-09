#!/bin/bash
# Input: paginated GitHub Jobs API response for the current run attempt.
set -euo pipefail

if ! jq -er '
  ["Verify native macOS source", "Verify Swift tooling", "Package and test native macOS arm64"] as $names
  | [.[] | .jobs[]] as $jobs
  | [$names[] as $name
      | [$jobs[] | select(.name == $name)]
      | if length != 1 then error("Expected one timing record for " + $name) else .[0] end
      | if .status != "completed" then error("Missing completed timing record for " + $name) else . end
      | {name, queued: (.created_at | fromdateiso8601), started: (.started_at | fromdateiso8601), finished: (.completed_at | fromdateiso8601)}
      | if .queued > .started or .started > .finished then error("Invalid timestamp order for " + $name) else . end
    ] as $required
  | ($required | map(.started) | min) as $first
  | ($required | map(.finished - .started) | max) as $elapsed
  | (($required | map(.finished) | max) - $first) as $span
  | ($first - ($required | map(.queued) | min)) as $queue
  | "Required parallel macOS checks (slowest job execution): \($elapsed)s / 300s budget.",
    "Wall-clock span including staggered runner queues: \($span)s.",
    "Initial runner queue (outside budget): \($queue)s.",
    "",
    ($required[] | "- \(.name): \(.finished - .started)s execution, \(.started - .queued)s runner queue."),
    if $elapsed > 300 then error("Required macOS checks exceeded five minutes. Fix the CI regression without removing checks or raising the budget.") else empty end
' "${1:?Usage: check-ci-budget.sh JOBS_JSON}"; then
  echo '::error::Cannot pass the five-minute CI budget check. See the timing report and error above.'
  exit 1
fi
