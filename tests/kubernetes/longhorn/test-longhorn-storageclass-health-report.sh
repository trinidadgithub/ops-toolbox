#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
FIXTURE_DIR="$ROOT_DIR/tests/fixtures/kubernetes/longhorn-storageclass-health"
RUNNER="$ROOT_DIR/tests/kubernetes/longhorn/run-longhorn-storageclass-health-fixture.sh"

run_script() {
  "$RUNNER" --fixture-dir "$FIXTURE_DIR" "$@"
}

json_output="$(run_script --output json)"
if ! jq -e '.summary.readiness_gate == "REVIEW_BLOCKED" and .summary.longhorn_pvcs == 2 and .summary.review == 1' <<< "$json_output" >/dev/null; then
  printf 'Missing expected blocked summary:\n%s\n' "$json_output" >&2
  exit 1
fi

if ! jq -e '.pvc_health[] | select(.pvc == "data-api-0" and .health == "REVIEW_VOLUME_NOT_HEALTHY" and .non_running_replicas == 1 and .warning_events == 1)' <<< "$json_output" >/dev/null; then
  printf 'Missing expected degraded Longhorn PVC signal:\n%s\n' "$json_output" >&2
  exit 1
fi

if jq -e '.pvc_health[] | select(.pvc == "archive-api-0")' <<< "$json_output" >/dev/null; then
  printf 'Non-Longhorn PVC should not be reported:\n%s\n' "$json_output" >&2
  exit 1
fi

summary_output="$(run_script --output summary)"
if ! grep -Fq 'readiness_gate=REVIEW_BLOCKED' <<< "$summary_output"; then
  printf 'Summary output missing blocked gate:\n%s\n' "$summary_output" >&2
  exit 1
fi

printf 'longhorn-storageclass-health-report fixture tests passed.\n'
