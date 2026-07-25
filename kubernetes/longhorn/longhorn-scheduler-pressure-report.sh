#!/usr/bin/env bash
set -euo pipefail

CONTEXT=""
KUBECONFIG_ARG=""
LONGHORN_NAMESPACE="longhorn-system"
OUTPUT="table"

usage() {
  cat <<'EOF'
Usage: longhorn-scheduler-pressure-report.sh [options]

Report Longhorn disk scheduling pressure from nodes.longhorn.io.

Options:
  --context NAME        Kubernetes context to query.
  --kubeconfig PATH     Kubeconfig path. Defaults to kubectl discovery.
  --namespace NAME      Longhorn namespace. Default: longhorn-system.
  --output FORMAT       table, csv, or json. Default: table.
  -h, --help            Show this help.

Examples:
  longhorn-scheduler-pressure-report.sh --context example-rke2
  longhorn-scheduler-pressure-report.sh --namespace longhorn-system --output csv

Notes:
  This utility is read-only. It does not modify Longhorn or Kubernetes objects.
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

nodes_json="$("${KUBECTL_BASE[@]}" -n "$LONGHORN_NAMESPACE" get nodes.longhorn.io -o json --request-timeout=20s)" \
  || die "failed to query nodes.longhorn.io in namespace: $LONGHORN_NAMESPACE"

# shellcheck disable=SC2016
jq_filter='
  def bytes_to_gib: (. / 1073741824);
  def pct($num; $den): if ($den // 0) == 0 then 0 else (($num / $den) * 100) end;
  def condition_status($conditions; $name):
    ($conditions // [] | map(select(.type == $name)) | first // {});

  [.items[]
    | .metadata.name as $node
    | (.spec.allowScheduling // false) as $nodeAllowScheduling
    | (.status.conditions // []) as $nodeConditions
    | (.status.diskStatus // {})
    | to_entries[]
    | .key as $disk
    | .value as $status
    | ($status.storageMaximum // 0 | tonumber) as $maximum
    | ($status.storageAvailable // 0 | tonumber) as $available
    | ($status.storageScheduled // 0 | tonumber) as $scheduled
    | (condition_status(($status.conditions // []); "Schedulable")) as $schedulable
    | {
        node: $node,
        disk: $disk,
        node_allow_scheduling: $nodeAllowScheduling,
        node_ready: (condition_status($nodeConditions; "Ready").status // "Unknown"),
        disk_schedulable: ($schedulable.status // "Unknown"),
        disk_reason: ($schedulable.reason // ""),
        maximum_gib: ($maximum | bytes_to_gib),
        available_gib: ($available | bytes_to_gib),
        scheduled_gib: ($scheduled | bytes_to_gib),
        scheduled_pct: pct($scheduled; $maximum),
        available_pct: pct($available; $maximum),
        scheduled_over_max_gib: ((if $scheduled > $maximum then ($scheduled - $maximum) else 0 end) | bytes_to_gib),
        scheduled_replica_count: (($status.scheduledReplica // {}) | length),
        message: ($schedulable.message // "")
      }
  ]'

report_json="$(jq "$jq_filter" <<< "$nodes_json")"

case "$OUTPUT" in
  json)
    jq '.' <<< "$report_json"
    ;;
  csv)
    echo 'node,disk,node_allow_scheduling,node_ready,disk_schedulable,disk_reason,maximum_gib,available_gib,scheduled_gib,scheduled_pct,available_pct,scheduled_over_max_gib,scheduled_replica_count,message'
    jq -r '.[] | [.node,.disk,.node_allow_scheduling,.node_ready,.disk_schedulable,.disk_reason,((.maximum_gib * 100 | round) / 100),((.available_gib * 100 | round) / 100),((.scheduled_gib * 100 | round) / 100),((.scheduled_pct * 100 | round) / 100),((.available_pct * 100 | round) / 100),((.scheduled_over_max_gib * 100 | round) / 100),.scheduled_replica_count,.message] | @csv' <<< "$report_json"
    ;;
  table)
    {
      printf 'NODE\tDISK\tREADY\tSCHEDULABLE\tREASON\tMAX_GIB\tAVAILABLE_GIB\tSCHEDULED_GIB\tSCHEDULED%%\tOVER_MAX_GIB\tREPLICAS\n'
      jq -r '.[] | [.node,.disk,.node_ready,.disk_schedulable,.disk_reason,((.maximum_gib * 100 | round) / 100),((.available_gib * 100 | round) / 100),((.scheduled_gib * 100 | round) / 100),((.scheduled_pct * 100 | round) / 100),((.scheduled_over_max_gib * 100 | round) / 100),.scheduled_replica_count] | @tsv' <<< "$report_json"
    } | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
    ;;
esac
