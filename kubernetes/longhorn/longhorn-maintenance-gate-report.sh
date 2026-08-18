#!/usr/bin/env bash
set -euo pipefail

CONTEXT=""
KUBECONFIG_ARG=""
LONGHORN_NAMESPACE="longhorn-system"
OUTPUT="table"

usage() {
  cat <<'EOF'
Usage: longhorn-maintenance-gate-report.sh [options]

Report Longhorn health gates before storage-node maintenance.

Options:
  --context NAME        Kubernetes context to query.
  --kubeconfig PATH     Kubeconfig path. Defaults to kubectl discovery.
  --namespace NAME      Longhorn namespace. Default: longhorn-system.
  --output FORMAT       table, json, or summary. Default: table.
  -h, --help            Show this help.

Examples:
  longhorn-maintenance-gate-report.sh --context example-rke2
  longhorn-maintenance-gate-report.sh --output json

Notes:
  This utility is read-only. It does not drain nodes, modify Longhorn objects,
  or approve maintenance. It summarizes evidence an operator should review.
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
  table|json|summary) ;;
  *) echo "ERROR: --output must be table, json, or summary." >&2; exit 2 ;;
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

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

volumes_file="${tmp_dir}/volumes.json"
replicas_file="${tmp_dir}/replicas.json"
nodes_file="${tmp_dir}/nodes.json"
pods_file="${tmp_dir}/pods.json"

"${KUBECTL_BASE[@]}" -n "$LONGHORN_NAMESPACE" get volumes.longhorn.io -o json --request-timeout=20s > "$volumes_file" \
  || die "failed to query volumes.longhorn.io in namespace: $LONGHORN_NAMESPACE"
"${KUBECTL_BASE[@]}" -n "$LONGHORN_NAMESPACE" get replicas.longhorn.io -o json --request-timeout=20s > "$replicas_file" \
  || die "failed to query replicas.longhorn.io in namespace: $LONGHORN_NAMESPACE"
"${KUBECTL_BASE[@]}" -n "$LONGHORN_NAMESPACE" get nodes.longhorn.io -o json --request-timeout=20s > "$nodes_file" \
  || die "failed to query nodes.longhorn.io in namespace: $LONGHORN_NAMESPACE"
"${KUBECTL_BASE[@]}" -n "$LONGHORN_NAMESPACE" get pods -o json --request-timeout=20s > "$pods_file" \
  || die "failed to query pods in namespace: $LONGHORN_NAMESPACE"

report_json="$(jq -n \
  --slurpfile volumes "$volumes_file" \
  --slurpfile replicas "$replicas_file" \
  --slurpfile nodes "$nodes_file" \
  --slurpfile pods "$pods_file" \
  --arg namespace "$LONGHORN_NAMESPACE" '
    def condition_status($conditions; $name):
      ($conditions // [] | map(select(.type == $name)) | first // {});

    ($volumes[0].items // []) as $volume_items
    | ($replicas[0].items // []) as $replica_items
    | ($nodes[0].items // []) as $node_items
    | ($pods[0].items // []) as $pod_items
    | ($volume_items
      | map({
          name: .metadata.name,
          state: (.status.state // ""),
          robustness: (.status.robustness // ""),
          node: (.status.currentNodeID // ""),
          attached: ((.status.state // "") == "attached"),
          healthy: ((.status.state // "") != "attached" or (.status.robustness // "") == "healthy")
        })) as $volumes_report
    | ($replica_items
      | map({
          name: .metadata.name,
          volume: (.spec.volumeName // .status.volumeName // ""),
          node: (.spec.nodeID // .status.currentNodeID // ""),
          running: ((.status.currentState // .status.state // "") == "running"),
          state: (.status.currentState // .status.state // "")
        })) as $replicas_report
    | ($volumes_report
      | map(select(.attached) as $vol
        | ($replicas_report | map(select(.volume == $vol.name and .running))) as $running
        | {
            volume: $vol.name,
            robustness: $vol.robustness,
            attached_node: $vol.node,
            running_replicas: ($running | length),
            replica_nodes: ($running | map(.node) | unique),
            distinct_replica_nodes: ($running | map(.node) | unique | length),
            gate: (if $vol.robustness != "healthy" then "BLOCK_UNHEALTHY_VOLUME"
                   elif ($running | length) < 2 then "REVIEW_LOW_RUNNING_REPLICAS"
                   elif ($running | map(.node) | unique | length) < 2 then "REVIEW_REPLICA_PLACEMENT"
                   else "OK" end)
          })) as $attached_volume_gates
    | ($node_items
      | map({
          node: .metadata.name,
          allow_scheduling: (.spec.allowScheduling // false),
          ready: (condition_status((.status.conditions // []); "Ready").status // "Unknown"),
          schedulable: ([.status.diskStatus // {} | to_entries[]? | (condition_status((.value.conditions // []); "Schedulable").status // "Unknown")] | unique | join(","))
        })) as $node_gates
    | ($pod_items
      | map(select((.status.phase != "Running") and (.status.phase != "Succeeded"))
        | {pod: .metadata.name, phase: .status.phase, node: (.spec.nodeName // ""), reason: (.status.reason // "")})
      ) as $pod_gates
    | {
        namespace: $namespace,
        summary: {
          attached_volumes: ($attached_volume_gates | length),
          attached_volume_gates_not_ok: ($attached_volume_gates | map(select(.gate != "OK")) | length),
          longhorn_nodes: ($node_gates | length),
          longhorn_nodes_not_ready: ($node_gates | map(select(.ready != "True")) | length),
          non_running_pods: ($pod_gates | length),
          maintenance_gate: (if (($attached_volume_gates | map(select(.gate != "OK")) | length) == 0
                                and ($node_gates | map(select(.ready != "True")) | length) == 0
                                and ($pod_gates | length) == 0)
                             then "REVIEW_READY"
                             else "REVIEW_BLOCKED" end)
        },
        attached_volume_gates: $attached_volume_gates,
        longhorn_node_gates: $node_gates,
        non_running_pods: $pod_gates
      }
  ')"

case "$OUTPUT" in
  json)
    jq '.' <<< "$report_json"
    ;;
  summary)
    jq -r '.summary | to_entries[] | "\(.key)=\(.value)"' <<< "$report_json"
    ;;
  table)
    echo "Summary"
    jq -r '.summary | to_entries[] | "\(.key)\t\(.value)"' <<< "$report_json" \
      | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
    echo
    echo "Attached Volume Gates"
    {
      printf 'VOLUME\tROBUSTNESS\tRUNNING_REPLICAS\tDISTINCT_REPLICA_NODES\tGATE\n'
      jq -r '.attached_volume_gates[] | [.volume,.robustness,.running_replicas,.distinct_replica_nodes,.gate] | @tsv' <<< "$report_json"
    } | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
    echo
    echo "Longhorn Node Gates"
    {
      printf 'NODE\tREADY\tALLOW_SCHEDULING\tDISK_SCHEDULABLE\n'
      jq -r '.longhorn_node_gates[] | [.node,.ready,.allow_scheduling,.schedulable] | @tsv' <<< "$report_json"
    } | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
    ;;
esac
