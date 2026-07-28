#!/usr/bin/env bash
set -euo pipefail

OUTPUT="table"
PARALLEL=8
TIMEOUT="30s"
ONLY_THICK=false
ALL_VMS=false
DATACENTER=""
SCOPES=()

usage() {
  cat <<'EOF'
Usage: vm-disk-provisioning-report.sh [options]

Report VMware virtual disk provisioning modes using govc.

Options:
  --scope PATH         vSphere inventory scope to search. Can be repeated.
  --all-vms           Search all visible VMs with govc find / -type m.
  --datacenter NAME   Set GOVC_DATACENTER for this run.
  --output FORMAT     table, csv, or json. Default: table.
  --parallel N        Parallel govc vm.info calls. Default: 8.
  --timeout DURATION  Per-VM govc timeout. Default: 30s.
  --only-thick        Show only thick-lazy or thick-eager disks.
  -h, --help          Show this help.

Examples:
  vm-disk-provisioning-report.sh --scope "/Example-Datacenter/vm/example-folder"
  vm-disk-provisioning-report.sh --scope "/Example-Datacenter/vm/example-folder" --only-thick
  vm-disk-provisioning-report.sh --all-vms --datacenter Example-Datacenter --output csv
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

is_positive_integer() {
  [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -gt 0 ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) SCOPES+=("${2:-}"); shift 2 ;;
    --all-vms) ALL_VMS=true; shift ;;
    --datacenter) DATACENTER="${2:-}"; shift 2 ;;
    --output|-o) OUTPUT="${2:-}"; shift 2 ;;
    --parallel) PARALLEL="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    --only-thick) ONLY_THICK=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$OUTPUT" in
  table|csv|json) ;;
  *) echo "ERROR: --output must be table, csv, or json." >&2; exit 2 ;;
esac

is_positive_integer "$PARALLEL" || { echo "ERROR: --parallel must be a positive integer." >&2; exit 2; }

if [[ "$ALL_VMS" == true && ${#SCOPES[@]} -gt 0 ]]; then
  echo "ERROR: use either --scope or --all-vms, not both." >&2
  exit 2
fi

if [[ "$ALL_VMS" == false && ${#SCOPES[@]} -eq 0 ]]; then
  echo "ERROR: provide at least one --scope, or use --all-vms." >&2
  exit 2
fi

command -v govc >/dev/null 2>&1 || die "govc is required."
command -v jq >/dev/null 2>&1 || die "jq is required."
command -v timeout >/dev/null 2>&1 || die "timeout is required."

if [[ -n "$DATACENTER" ]]; then
  export GOVC_DATACENTER="$DATACENTER"
fi

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

vm_list_file="${tmp_dir}/vms.tsv"
results_file="${tmp_dir}/results.jsonl"
jq_program_file="${tmp_dir}/disk-provisioning.jq"
: > "$vm_list_file"
: > "$results_file"

if [[ "$ALL_VMS" == true ]]; then
  govc find / -type m -name '*' | awk 'BEGIN{OFS="\t"} {print "all-vms", $0}' > "$vm_list_file"
else
  for scope in "${SCOPES[@]}"; do
    [[ -n "$scope" ]] || die "--scope cannot be empty."
    govc find "$scope" -type m -name '*' | awk -v scope="$scope" 'BEGIN{OFS="\t"} {print scope, $0}' >> "$vm_list_file"
  done
fi

if [[ ! -s "$vm_list_file" ]]; then
  die "no VMs found for requested scope."
fi

cat > "$jq_program_file" <<'JQ'
  .virtualMachines[0] as $vm
  | ($vm.name // "") as $vm_name
  | [
      $vm.config.hardware.device[]?
      | select((.deviceInfo.label // "") | startswith("Hard disk"))
      | . as $disk
      | ($disk.backing // {}) as $backing
      | ($backing.fileName // "") as $vmdk
      | ($vmdk | capture("^\\[(?<datastore>[^\\]]+)\\]"; "g").datastore // "") as $datastore
      | (if ($backing.thinProvisioned // false) then "thin"
         elif ($backing.eagerlyScrub // false) then "thick-eager"
         elif ($backing | has("thinProvisioned")) or ($backing | has("eagerlyScrub")) then "thick-lazy"
         else "unknown" end) as $provisioning
      | {
          scope: $scope,
          vm: $vm_name,
          disk: ($disk.deviceInfo.label // ""),
          provisioning: $provisioning,
          datastore: $datastore,
          vmdk: $vmdk
        }
    ][]
JQ

worker() {
  local scope="$1"
  local vm_path="$2"
  local info

  if ! info="$(timeout "$TIMEOUT" govc vm.info -json "$vm_path" 2>/dev/null)"; then
    jq -n --arg scope "$scope" --arg vm "$vm_path" \
      '{scope: $scope, vm: $vm, disk: "", provisioning: "error", datastore: "", vmdk: "govc vm.info failed"}'
    return 0
  fi

  jq -c --arg scope "$scope" -f "$JQ_PROGRAM_FILE" <<< "$info"
}

export -f worker
export TIMEOUT JQ_PROGRAM_FILE="$jq_program_file"

# shellcheck disable=SC2016
xargs -P "$PARALLEL" -n 2 bash -c 'worker "$1" "$2"' _ < "$vm_list_file" > "$results_file"

if [[ "$ONLY_THICK" == true ]]; then
  filtered_file="${tmp_dir}/filtered.jsonl"
  jq -c 'select(.provisioning == "thick-lazy" or .provisioning == "thick-eager" or .provisioning == "error")' "$results_file" > "$filtered_file"
  mv "$filtered_file" "$results_file"
fi

case "$OUTPUT" in
  json)
    jq -s 'sort_by(.scope, .vm, .disk)' "$results_file"
    ;;
  csv)
    echo 'scope,vm,disk,provisioning,datastore,vmdk'
    jq -sr 'sort_by(.scope, .vm, .disk)[] | [.scope,.vm,.disk,.provisioning,.datastore,.vmdk] | @csv' "$results_file"
    ;;
  table)
    {
      printf 'SCOPE\tVM\tDISK\tPROVISIONING\tDATASTORE\tVMDK\n'
      jq -sr 'sort_by(.scope, .vm, .disk)[] | [.scope,.vm,.disk,.provisioning,.datastore,.vmdk] | @tsv' "$results_file"
    } | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
    ;;
esac
