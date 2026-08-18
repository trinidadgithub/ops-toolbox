#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT_DIR/kubernetes/longhorn/longhorn-maintenance-gate-report.sh"
FIXTURE_DIR="$ROOT_DIR/tests/fixtures/kubernetes/longhorn-maintenance"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

cat > "$tmp_dir/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

fixture_dir="${LONGHORN_GATE_FIXTURE_DIR:?fixture dir not set}"
args=" $* "

if [[ "$args" == *" get volumes.longhorn.io "* ]]; then
  cp "$fixture_dir/volumes.json" /dev/stdout
  exit 0
fi

if [[ "$args" == *" get replicas.longhorn.io "* ]]; then
  cp "$fixture_dir/replicas.json" /dev/stdout
  exit 0
fi

if [[ "$args" == *" get nodes.longhorn.io "* ]]; then
  cp "$fixture_dir/nodes.json" /dev/stdout
  exit 0
fi

if [[ "$args" == *" get pods "* ]]; then
  cp "$fixture_dir/pods.json" /dev/stdout
  exit 0
fi

printf 'unexpected kubectl arguments: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$tmp_dir/kubectl"

run_script() {
  PATH="$tmp_dir:$PATH" LONGHORN_GATE_FIXTURE_DIR="$FIXTURE_DIR" "$SCRIPT" "$@"
}

json_output="$(run_script --output json)"
if ! jq -e '.summary.maintenance_gate == "REVIEW_BLOCKED" and .summary.attached_volume_gates_not_ok == 1 and .summary.non_running_pods == 1' <<< "$json_output" >/dev/null; then
  printf 'Missing expected blocked summary:\n%s\n' "$json_output" >&2
  exit 1
fi

if ! jq -e '.attached_volume_gates[] | select(.volume == "pvc-degraded" and .gate == "BLOCK_UNHEALTHY_VOLUME")' <<< "$json_output" >/dev/null; then
  printf 'Missing expected degraded volume gate:\n%s\n' "$json_output" >&2
  exit 1
fi

summary_output="$(run_script --output summary)"
if ! grep -Fq 'maintenance_gate=REVIEW_BLOCKED' <<< "$summary_output"; then
  printf 'Summary output missing blocked gate:\n%s\n' "$summary_output" >&2
  exit 1
fi

printf 'longhorn-maintenance-gate-report fixture tests passed.\n'
