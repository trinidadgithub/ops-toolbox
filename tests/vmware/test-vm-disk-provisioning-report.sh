#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT_DIR/vmware/vm-disk-provisioning-report.sh"
FIXTURE_DIR="$ROOT_DIR/tests/fixtures/vmware"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

cat > "$tmp_dir/govc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

fixture_dir="${VMWARE_FIXTURE_DIR:?fixture dir not set}"

if [[ "$1" == "find" ]]; then
  printf '/Example-Datacenter/vm/example-folder/web-01\n'
  printf '/Example-Datacenter/vm/example-folder/db-01\n'
  exit 0
fi

if [[ "$1" == "vm.info" ]]; then
  vm_path="${*: -1}"
  case "$vm_path" in
    */web-01) cp "$fixture_dir/vm-web-01.json" /dev/stdout ;;
    */db-01) cp "$fixture_dir/vm-db-01.json" /dev/stdout ;;
    *) printf 'unknown vm: %s\n' "$vm_path" >&2; exit 1 ;;
  esac
  exit 0
fi

printf 'unexpected govc arguments: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$tmp_dir/govc"

run_script() {
  PATH="$tmp_dir:$PATH" VMWARE_FIXTURE_DIR="$FIXTURE_DIR" "$SCRIPT" --scope "/Example-Datacenter/vm/example-folder" --parallel 1 "$@"
}

json_output="$(run_script --output json)"

if ! jq -e '.[] | select(.vm == "web-01" and .disk == "Hard disk 1" and .provisioning == "thin" and .datastore == "datastore-a")' <<< "$json_output" >/dev/null; then
  printf 'Missing expected thin disk row:\n%s\n' "$json_output" >&2
  exit 1
fi

if ! jq -e '.[] | select(.vm == "web-01" and .disk == "Hard disk 2" and .provisioning == "thick-lazy" and .datastore == "datastore-b")' <<< "$json_output" >/dev/null; then
  printf 'Missing expected thick-lazy disk row:\n%s\n' "$json_output" >&2
  exit 1
fi

if ! jq -e '.[] | select(.vm == "db-01" and .disk == "Hard disk 1" and .provisioning == "thick-eager" and .datastore == "datastore-c")' <<< "$json_output" >/dev/null; then
  printf 'Missing expected thick-eager disk row:\n%s\n' "$json_output" >&2
  exit 1
fi

only_thick="$(run_script --output json --only-thick)"
if jq -e '.[] | select(.provisioning == "thin")' <<< "$only_thick" >/dev/null; then
  printf 'Only-thick output unexpectedly included thin disk:\n%s\n' "$only_thick" >&2
  exit 1
fi

csv_output="$(run_script --output csv)"
if ! grep -Fq '"/Example-Datacenter/vm/example-folder","web-01","Hard disk 2","thick-lazy","datastore-b"' <<< "$csv_output"; then
  printf 'CSV output missing expected thick-lazy row.\n%s\n' "$csv_output" >&2
  exit 1
fi

printf 'vm-disk-provisioning-report fixture tests passed.\n'
