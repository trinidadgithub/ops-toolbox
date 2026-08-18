#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT_DIR/kubernetes/nodes/k8s-node-maintenance-gate-report.sh"
FIXTURE_DIR="$ROOT_DIR/tests/fixtures/kubernetes/nodes"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

cat > "$tmp_dir/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

fixture_dir="${NODE_GATE_FIXTURE_DIR:?fixture dir not set}"
args=" $* "

if [[ "$*" == "config current-context" ]]; then
  printf 'lab-cluster\n'
  exit 0
fi

if [[ "$*" == "config get-contexts -o name" ]]; then
  printf 'lab-cluster\n'
  exit 0
fi

if [[ "$args" == *" get nodes "* ]]; then
  cp "$fixture_dir/nodes.json" /dev/stdout
  exit 0
fi

if [[ "$args" == *" get pods "* ]]; then
  cp "$fixture_dir/pods.json" /dev/stdout
  exit 0
fi

if [[ "$args" == *" get pdb "* ]]; then
  cp "$fixture_dir/pdbs.json" /dev/stdout
  exit 0
fi

if [[ "$args" == *" get events "* ]]; then
  cp "$fixture_dir/events.json" /dev/stdout
  exit 0
fi

printf 'unexpected kubectl arguments: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$tmp_dir/kubectl"

run_script() {
  PATH="$tmp_dir:$PATH" NODE_GATE_FIXTURE_DIR="$FIXTURE_DIR" "$SCRIPT" "$@"
}

json_output="$(run_script --output json)"

if ! jq -e '.[] | select(.node == "worker-1" and .gate == "REVIEW_READY" and .boot_id == "boot-worker-1")' <<< "$json_output" >/dev/null; then
  printf 'Missing expected ready worker row:\n%s\n' "$json_output" >&2
  exit 1
fi

if ! jq -e '.[] | select(.node == "worker-2" and .gate == "REVIEW_UNHEALTHY_PODS" and .unhealthy_pods_on_node == 1)' <<< "$json_output" >/dev/null; then
  printf 'Missing expected unhealthy pod gate:\n%s\n' "$json_output" >&2
  exit 1
fi

if ! jq -e '.[] | select(.node == "worker-3" and .gate == "BLOCK_NOT_READY")' <<< "$json_output" >/dev/null; then
  printf 'Missing expected not-ready gate:\n%s\n' "$json_output" >&2
  exit 1
fi

summary_output="$(run_script --output summary)"
if ! grep -Fq 'blocked=1' <<< "$summary_output" || ! grep -Fq 'review_required=1' <<< "$summary_output"; then
  printf 'Summary output missing expected counts:\n%s\n' "$summary_output" >&2
  exit 1
fi

printf 'k8s-node-maintenance-gate-report fixture tests passed.\n'
