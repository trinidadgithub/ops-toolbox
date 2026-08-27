#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SANITIZER="$ROOT_DIR/tests/kubernetes/longhorn/sanitize-longhorn-storageclass-health-fixture.sh"
RUNNER="$ROOT_DIR/tests/kubernetes/longhorn/run-longhorn-storageclass-health-fixture.sh"
FIXTURE_DIR="$ROOT_DIR/tests/fixtures/kubernetes/longhorn-storageclass-health"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

sanitized_dir="$tmp_dir/sanitized"
"$SANITIZER" --input-dir "$FIXTURE_DIR" --output-dir "$sanitized_dir" >/dev/null

json_output="$($RUNNER --fixture-dir "$sanitized_dir" --output json)"
if ! jq -e '.summary.readiness_gate == "REVIEW_BLOCKED" and .summary.longhorn_pvcs == 2 and .summary.review == 1' <<< "$json_output" >/dev/null; then
  printf 'Sanitized fixture did not preserve expected health summary:\n%s\n' "$json_output" >&2
  exit 1
fi

if ! jq -e '.pvc_health[] | select(.pvc == "example-pvc-3" and .health == "REVIEW_VOLUME_NOT_HEALTHY" and .non_running_replicas == 1 and .warning_events == 1)' <<< "$json_output" >/dev/null; then
  printf 'Sanitized fixture did not preserve degraded PVC semantics:\n%s\n' "$json_output" >&2
  exit 1
fi

if grep -R -E 'data-api-0|cache-api-0|archive-api-0|pvc-data-api-0|pvc-cache-api-0|storage-[0-9]' "$sanitized_dir" >/dev/null; then
  printf 'Sanitized fixture still contains original fixture identifiers.\n' >&2
  exit 1
fi

if ! jq -e '.items[] | select(.metadata.labels["app.kubernetes.io/part-of"] and .metadata.annotations["example.com/sanitized"] == "true" and .metadata.uid == "00000000-0000-4000-8000-000000000001")' "$sanitized_dir/pvcs.json" >/dev/null; then
  printf 'Sanitized PVC fixture is missing neutral mocked metadata.\n' >&2
  exit 1
fi

if ! jq -e '.items[] | select(.metadata.managedFields[0].manager == "example-manager" and .metadata.ownerReferences != null)' "$sanitized_dir/volumes.json" >/dev/null; then
  printf 'Sanitized Longhorn volume fixture is missing neutral mocked metadata.\n' >&2
  exit 1
fi

printf 'longhorn-storageclass-health sanitizer fixture tests passed.\n'
