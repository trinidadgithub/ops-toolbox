#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT_DIR/vmware/vm-cdrom-report.sh"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

cat > "$tmp_dir/govc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == "find" ]]; then
  printf '/Example-Datacenter/vm/example-folder/worker-1\n'
  printf '/Example-Datacenter/vm/example-folder/worker-2\n'
  exit 0
fi

if [[ "$1" == "device.info" ]]; then
  vm_path="$3"
  case "$vm_path" in
    */worker-1)
      printf '%s\n' \
        'Name: cdrom-16000' \
        'Label: CD/DVD drive 1' \
        'Summary: ISO [datastore-a] ISO/installer.iso' \
        'Connected: true' \
        'Start connected: true'
      ;;
    */worker-2)
      exit 1
      ;;
    *) printf 'unknown vm: %s\n' "$vm_path" >&2; exit 1 ;;
  esac
  exit 0
fi

printf 'unexpected govc arguments: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$tmp_dir/govc"

run_script() {
  PATH="$tmp_dir:$PATH" "$SCRIPT" --scope "/Example-Datacenter/vm/example-folder" "$@"
}

json_output="$(run_script --output json)"
if ! jq -e '.[] | select(.vm | endswith("worker-1")) | select(.has_cdrom == true and .connected == true and .start_connected == true)' <<< "$json_output" >/dev/null; then
  printf 'Missing expected connected CD-ROM row:\n%s\n' "$json_output" >&2
  exit 1
fi

if ! jq -e '.[] | select(.vm | endswith("worker-2")) | select(.has_cdrom == false)' <<< "$json_output" >/dev/null; then
  printf 'Missing expected no-CD-ROM row:\n%s\n' "$json_output" >&2
  exit 1
fi

connected_only="$(run_script --output json --only-connected)"
if [[ "$(jq 'length' <<< "$connected_only")" != "1" ]]; then
  printf 'Expected one connected-only row:\n%s\n' "$connected_only" >&2
  exit 1
fi

printf 'vm-cdrom-report fixture tests passed.\n'
