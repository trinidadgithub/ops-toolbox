#!/usr/bin/env bash
set -euo pipefail

OUTPUT="table"
DATACENTER=""
ALL_VMS=false
SCOPES=()

usage() {
  cat <<'EOF'
Usage: vm-cdrom-report.sh [options]

Report VMware virtual CD/DVD devices using govc.

Options:
  --scope PATH         vSphere inventory scope to search. Can be repeated.
  --all-vms           Search all visible VMs with govc find / -type m.
  --datacenter NAME   Set GOVC_DATACENTER for this run.
  --output FORMAT     table, csv, or json. Default: table.
  --only-present      Show only VMs with at least one CD/DVD device.
  --only-connected    Show only connected or start-connected CD/DVD devices.
  -h, --help          Show this help.

Examples:
  vm-cdrom-report.sh --scope "/Example-Datacenter/vm/example-folder"
  vm-cdrom-report.sh --scope "/Example-Datacenter/vm/example-folder" --only-connected
  vm-cdrom-report.sh --all-vms --datacenter Example-Datacenter --output csv

Notes:
  This utility is read-only. It runs govc find and govc device.info only.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

ONLY_PRESENT=false
ONLY_CONNECTED=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) SCOPES+=("${2:-}"); shift 2 ;;
    --all-vms) ALL_VMS=true; shift ;;
    --datacenter) DATACENTER="${2:-}"; shift 2 ;;
    --output|-o) OUTPUT="${2:-}"; shift 2 ;;
    --only-present) ONLY_PRESENT=true; shift ;;
    --only-connected) ONLY_CONNECTED=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$OUTPUT" in
  table|csv|json) ;;
  *) echo "ERROR: --output must be table, csv, or json." >&2; exit 2 ;;
esac

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
: > "$vm_list_file"
: > "$results_file"

if [[ "$ALL_VMS" == true ]]; then
  while IFS= read -r vm; do
    [[ -n "$vm" ]] && printf '%s\t%s\n' 'all-vms' "$vm"
  done < <(govc find / -type m -name '*') > "$vm_list_file"
else
  for scope in "${SCOPES[@]}"; do
    [[ -n "$scope" ]] || die "--scope cannot be empty."
    while IFS= read -r vm; do
      [[ -n "$vm" ]] && printf '%s\t%s\n' "$scope" "$vm"
    done < <(govc find "$scope" -type m -name '*') >> "$vm_list_file"
  done
fi

[[ -s "$vm_list_file" ]] || die "no VMs found for requested scope."

emit_device() {
  local scope="$1"
  local vm="$2"
  local name="$3"
  local label="$4"
  local summary="$5"
  local connected="$6"
  local start_connected="$7"

  if [[ "$ONLY_CONNECTED" == true && "$connected" != "true" && "$start_connected" != "true" ]]; then
    return 0
  fi

  jq -cn \
    --arg scope "$scope" \
    --arg vm "$vm" \
    --arg name "$name" \
    --arg label "$label" \
    --arg summary "$summary" \
    --argjson connected "$connected" \
    --argjson start_connected "$start_connected" \
    '{scope:$scope,vm:$vm,device:$name,label:$label,summary:$summary,connected:$connected,start_connected:$start_connected,has_cdrom:true}' \
    >> "$results_file"
}

parse_device_info() {
  local scope="$1"
  local vm="$2"
  local info="$3"
  local name="" label="" summary="" connected="false" start_connected="false" found=false

  flush_device() {
    [[ -n "$name" ]] || return 0
    found=true
    emit_device "$scope" "$vm" "$name" "$label" "$summary" "$connected" "$start_connected"
  }

  while IFS= read -r line; do
    case "$line" in
      Name:*)
        flush_device
        name="${line#Name:}"
        name="${name## }"
        label=""
        summary=""
        connected="false"
        start_connected="false"
        ;;
      Label:*)
        label="${line#Label:}"
        label="${label## }"
        ;;
      Summary:*)
        summary="${line#Summary:}"
        summary="${summary## }"
        ;;
      Connected:*)
        connected="${line#Connected:}"
        connected="${connected## }"
        ;;
      'Start connected:'*)
        start_connected="${line#Start connected:}"
        start_connected="${start_connected## }"
        ;;
    esac
  done <<< "$info"
  flush_device

  if [[ "$found" == false && "$ONLY_PRESENT" == false && "$ONLY_CONNECTED" == false ]]; then
    jq -cn --arg scope "$scope" --arg vm "$vm" \
      '{scope:$scope,vm:$vm,device:"",label:"",summary:"",connected:false,start_connected:false,has_cdrom:false}' \
      >> "$results_file"
  fi
}

while IFS=$'\t' read -r scope vm; do
  if info="$(govc device.info -vm "$vm" 'cdrom-*' 2>/dev/null)"; then
    parse_device_info "$scope" "$vm" "$info"
  elif [[ "$ONLY_PRESENT" == false && "$ONLY_CONNECTED" == false ]]; then
    jq -cn --arg scope "$scope" --arg vm "$vm" \
      '{scope:$scope,vm:$vm,device:"",label:"",summary:"",connected:false,start_connected:false,has_cdrom:false}' \
      >> "$results_file"
  fi
done < "$vm_list_file"

case "$OUTPUT" in
  json)
    jq -s 'sort_by(.scope, .vm, .device)' "$results_file"
    ;;
  csv)
    echo 'scope,vm,has_cdrom,device,label,summary,connected,start_connected'
    jq -sr 'sort_by(.scope, .vm, .device)[] | [.scope,.vm,.has_cdrom,.device,.label,.summary,.connected,.start_connected] | @csv' "$results_file"
    ;;
  table)
    {
      printf 'SCOPE\tVM\tHAS_CDROM\tDEVICE\tLABEL\tCONNECTED\tSTART_CONNECTED\tSUMMARY\n'
      jq -sr 'sort_by(.scope, .vm, .device)[] | [.scope,.vm,.has_cdrom,.device,.label,.connected,.start_connected,.summary] | @tsv' "$results_file"
    } | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
    ;;
esac
