#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tests=(
  "$ROOT_DIR/tests/kubernetes/workloads/test-k8s-unhealthy-pods.sh"
  "$ROOT_DIR/tests/kubernetes/storage/test-pvc-resize-audit.sh"
  "$ROOT_DIR/tests/kubernetes/networking/test-kube-proxy-diagnostics.sh"
  "$ROOT_DIR/tests/vmware/test-vm-disk-provisioning-report.sh"
)

for test_script in "${tests[@]}"; do
  "$test_script"
done

printf 'All tests passed.\n'
