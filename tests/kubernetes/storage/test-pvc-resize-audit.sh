#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT_DIR/kubernetes/storage/pvc-resize-audit.sh"
FIXTURE_DIR="$ROOT_DIR/tests/fixtures/kubernetes/storage"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

cat > "$tmp_dir/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

fixture_dir="${PVC_RESIZE_FIXTURE_DIR:?fixture dir not set}"
args=" $* "

if [[ "$*" == "config current-context" ]]; then
  printf 'lab-cluster\n'
  exit 0
fi

if [[ "$*" == "config get-contexts -o name" ]]; then
  printf 'lab-cluster\n'
  exit 0
fi

if [[ "$args" == *" get pvc "* ]]; then
  cp "$fixture_dir/pvcs.json" /dev/stdout
  exit 0
fi

if [[ "$args" == *" get pv "* ]]; then
  cp "$fixture_dir/pvs.json" /dev/stdout
  exit 0
fi

if [[ "$args" == *" get storageclass "* ]]; then
  cp "$fixture_dir/storageclasses.json" /dev/stdout
  exit 0
fi

if [[ "$args" == *" get events "* ]]; then
  cp "$fixture_dir/events.json" /dev/stdout
  exit 0
fi

if [[ "$args" == *" get volumes.longhorn.io "* ]]; then
  cp "$fixture_dir/longhorn-volumes.json" /dev/stdout
  exit 0
fi

printf 'unexpected kubectl arguments: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$tmp_dir/kubectl"

run_script() {
  PATH="$tmp_dir:$PATH" PVC_RESIZE_FIXTURE_DIR="$FIXTURE_DIR" "$SCRIPT" "$@"
}

json_output="$(run_script --output json)"
names="$(jq -r '.[].name' <<< "$json_output" | sort)"
if [[ "$names" != $'data-api-0\nlogs-api-0' ]]; then
  printf 'Unexpected PVC findings:\n%s\n' "$json_output" >&2
  exit 1
fi

if ! jq -e '.[] | select(.name == "data-api-0" and .signal == "FILESYSTEM_RESIZE_PENDING" and .allowExpansion == true and .reclaimPolicy == "Retain")' <<< "$json_output" >/dev/null; then
  printf 'Missing expected FileSystemResizePending finding:\n%s\n' "$json_output" >&2
  exit 1
fi

if ! jq -e '.[] | select(.name == "logs-api-0" and .signal == "REQUEST_CAPACITY_MISMATCH" and .allowExpansion == false)' <<< "$json_output" >/dev/null; then
  printf 'Missing expected request/capacity mismatch finding:\n%s\n' "$json_output" >&2
  exit 1
fi

json_with_events="$(run_script --output json --include-events --include-longhorn)"
if ! jq -e '.[] | select(.source == "event" and .name == "data-api-0" and .signal == "FileSystemResizeRequired")' <<< "$json_with_events" >/dev/null; then
  printf 'Missing expected resize event finding:\n%s\n' "$json_with_events" >&2
  exit 1
fi

if ! jq -e '.[] | select(.source == "longhorn" and .name == "pvc-data-api-0" and .signal == "LONGHORN_VOLUME_REVIEW")' <<< "$json_with_events" >/dev/null; then
  printf 'Missing expected Longhorn degraded volume finding:\n%s\n' "$json_with_events" >&2
  exit 1
fi

csv_output="$(run_script --output csv)"
if ! grep -Fq '"lab-cluster","pvc","example-app","data-api-0","example-expandable","20Gi","10Gi"' <<< "$csv_output"; then
  printf 'CSV output missing expected PVC row.\n%s\n' "$csv_output" >&2
  exit 1
fi

printf 'pvc-resize-audit fixture tests passed.\n'
