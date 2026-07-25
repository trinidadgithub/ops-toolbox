#!/usr/bin/env bash
set -euo pipefail

CONTEXT=""
KUBECONFIG_ARG=""
LONGHORN_NAMESPACE="longhorn-system"
OUTPUT="table"

usage() {
  cat <<'EOF'
Usage: longhorn-orphan-report.sh [options]

Report Longhorn orphaned replica data and whether each orphan overlaps an active Replica CR.

Options:
  --context NAME        Kubernetes context to query.
  --kubeconfig PATH     Kubeconfig path. Defaults to kubectl discovery.
  --namespace NAME      Longhorn namespace. Default: longhorn-system.
  --output FORMAT       table, csv, or json. Default: table.
  -h, --help            Show this help.

Examples:
  longhorn-orphan-report.sh --context example-rke2
  longhorn-orphan-report.sh --output json

Notes:
  This utility is read-only. It does not delete Orphan CRs or filesystem data.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) CONTEXT="${2:-}"; shift 2 ;;
    --kubeconfig) KUBECONFIG_ARG="${2:-}"; shift 2 ;;
    --namespace|-n) LONGHORN_NAMESPACE="${2:-}"; shift 2 ;;
    --output|-o) OUTPUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$OUTPUT" in
  table|csv|json) ;;
  *) echo "ERROR: --output must be table, csv, or json." >&2; exit 2 ;;
esac

command -v kubectl >/dev/null 2>&1 || die "kubectl is required."
command -v jq >/dev/null 2>&1 || die "jq is required."

KUBECTL_BASE=(kubectl)
if [[ -n "$KUBECONFIG_ARG" ]]; then
  [[ -f "$KUBECONFIG_ARG" ]] || die "kubeconfig not found: $KUBECONFIG_ARG"
  KUBECTL_BASE+=(--kubeconfig "$KUBECONFIG_ARG")
fi
if [[ -n "$CONTEXT" ]]; then
  KUBECTL_BASE+=(--context "$CONTEXT")
fi

orphans_json="$("${KUBECTL_BASE[@]}" -n "$LONGHORN_NAMESPACE" get orphans.longhorn.io -o json --request-timeout=20s 2>/dev/null || printf '{"items":[]}')"
replicas_json="$("${KUBECTL_BASE[@]}" -n "$LONGHORN_NAMESPACE" get replicas.longhorn.io -o json --request-timeout=20s 2>/dev/null || printf '{"items":[]}')"

report_json="$(jq -n \
  --argjson orphans "$orphans_json" \
  --argjson replicas "$replicas_json" '
  def condition_status($conditions; $name):
    ($conditions // [] | map(select(.type == $name)) | first // {} | .status // "Unknown");

  ($replicas.items | map(.metadata.name) | unique) as $managedNames
  | [$orphans.items[]
      | (.spec.parameters.DataName // "") as $dataName
      | {
          orphan: .metadata.name,
          node: (.spec.nodeID // ""),
          orphan_type: (.spec.orphanType // ""),
          data_name: $dataName,
          disk_name: (.spec.parameters.DiskName // ""),
          disk_path: (.spec.parameters.DiskPath // ""),
          data_cleanable: condition_status(.status.conditions; "DataCleanable"),
          error: condition_status(.status.conditions; "Error"),
          overlaps_managed_replica: ($managedNames | index($dataName) != null),
          review_hint: (
            if ($managedNames | index($dataName) != null) then "DO_NOT_DELETE_MANAGED_OVERLAP"
            elif (.spec.orphanType // "") != "replica" then "REVIEW_NON_REPLICA_ORPHAN"
            elif condition_status(.status.conditions; "DataCleanable") != "True" then "REVIEW_NOT_CLEANABLE"
            elif condition_status(.status.conditions; "Error") == "True" then "REVIEW_ERROR_CONDITION"
            else "CLEANUP_CANDIDATE_REVIEW_REQUIRED"
            end
          )
        }
    ]')"

case "$OUTPUT" in
  json)
    jq '.' <<< "$report_json"
    ;;
  csv)
    echo 'orphan,node,orphan_type,data_name,disk_name,disk_path,data_cleanable,error,overlaps_managed_replica,review_hint'
    jq -r '.[] | [.orphan,.node,.orphan_type,.data_name,.disk_name,.disk_path,.data_cleanable,.error,.overlaps_managed_replica,.review_hint] | @csv' <<< "$report_json"
    ;;
  table)
    {
      printf 'ORPHAN\tNODE\tTYPE\tDATA_CLEANABLE\tERROR\tMANAGED_OVERLAP\tREVIEW_HINT\tDATA_NAME\n'
      jq -r '.[] | [.orphan,.node,.orphan_type,.data_cleanable,.error,.overlaps_managed_replica,.review_hint,.data_name] | @tsv' <<< "$report_json"
    } | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
    ;;
esac
