#!/usr/bin/env bash
set -euo pipefail

CONTEXT=""
ALL_CONTEXTS=false
KUBECONFIG_ARG=""
OUTPUT="table"

usage() {
  cat <<'EOF'
Usage: k8s-node-maintenance-gate-report.sh [options]

Report read-only Kubernetes node maintenance gates.

Options:
  --context NAME        Kubernetes context to query.
  --all-contexts        Query every context in the kubeconfig.
  --kubeconfig PATH     Kubeconfig path. Defaults to kubectl discovery.
  --output FORMAT       table, csv, json, or summary. Default: table.
  -h, --help            Show this help.

Examples:
  k8s-node-maintenance-gate-report.sh --context example-rke2
  k8s-node-maintenance-gate-report.sh --all-contexts --output summary
  k8s-node-maintenance-gate-report.sh --output json

Notes:
  This utility is read-only. It does not cordon, uncordon, drain, reboot,
  delete pods, patch workloads, or modify cluster state.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) CONTEXT="${2:-}"; shift 2 ;;
    --all-contexts) ALL_CONTEXTS=true; shift ;;
    --kubeconfig) KUBECONFIG_ARG="${2:-}"; shift 2 ;;
    --output|-o) OUTPUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$OUTPUT" in
  table|csv|json|summary) ;;
  *) echo "ERROR: --output must be table, csv, json, or summary." >&2; exit 2 ;;
esac

if [[ "$ALL_CONTEXTS" == true && -n "$CONTEXT" ]]; then
  echo "ERROR: use either --context or --all-contexts, not both." >&2
  exit 2
fi

command -v kubectl >/dev/null 2>&1 || die "kubectl is required."
command -v jq >/dev/null 2>&1 || die "jq is required."

KUBECTL_BASE=(kubectl)
if [[ -n "$KUBECONFIG_ARG" ]]; then
  [[ -f "$KUBECONFIG_ARG" ]] || die "kubeconfig not found: $KUBECONFIG_ARG"
  KUBECTL_BASE+=(--kubeconfig "$KUBECONFIG_ARG")
fi

contexts=()
if [[ "$ALL_CONTEXTS" == true ]]; then
  mapfile -t contexts < <("${KUBECTL_BASE[@]}" config get-contexts -o name)
elif [[ -n "$CONTEXT" ]]; then
  contexts=("$CONTEXT")
else
  current_context="$("${KUBECTL_BASE[@]}" config current-context 2>/dev/null || true)"
  [[ -n "$current_context" ]] || die "no current context found; provide --context or --all-contexts."
  contexts=("$current_context")
fi

[[ ${#contexts[@]} -gt 0 ]] || die "no contexts found."

tmp_files=()
cleanup() {
  if [[ ${#tmp_files[@]} -gt 0 ]]; then
    rm -f "${tmp_files[@]}"
  fi
}
trap cleanup EXIT

# shellcheck disable=SC2016
jq_filter='
  def condition($node; $name):
    ($node.status.conditions // [] | map(select(.type == $name)) | first // {});
  def condition_bool($node; $name):
    (condition($node; $name).status // "Unknown");
  def unhealthy_pod:
    (.status.phase != "Succeeded") and
    (
      .status.phase != "Running" or
      ([.status.containerStatuses[]?.ready] | any(. == false)) or
      ([.status.containerStatuses[]?.state.waiting.reason // empty] | length > 0) or
      ([.status.containerStatuses[]?.state.terminated.reason // empty] | length > 0)
    );
  def gate_for($ready; $memory; $disk; $pid; $network; $unsched; $unhealthy):
    if $ready != "True" then "BLOCK_NOT_READY"
    elif $memory == "True" or $disk == "True" or $pid == "True" then "BLOCK_NODE_PRESSURE"
    elif $network == "True" then "BLOCK_NETWORK_UNAVAILABLE"
    elif $unhealthy > 0 then "REVIEW_UNHEALTHY_PODS"
    elif $unsched == true then "REVIEW_ALREADY_CORDONED"
    else "REVIEW_READY" end;

  ($nodes.items // []) as $node_items
  | ($pods.items // []) as $pod_items
  | ($pdbs.items // []) as $pdb_items
  | ($events.items // []) as $event_items
  | ($pdb_items | map(select((.status.disruptionsAllowed // 0) == 0)) | length) as $zero_disruption_pdbs
  | [
      $node_items[]
      | . as $node
      | ($node.metadata.name // "") as $node_name
      | (condition_bool($node; "Ready")) as $ready
      | (condition_bool($node; "MemoryPressure")) as $memory
      | (condition_bool($node; "DiskPressure")) as $disk
      | (condition_bool($node; "PIDPressure")) as $pid
      | (condition_bool($node; "NetworkUnavailable")) as $network
      | ($node.spec.unschedulable // false) as $unsched
      | ($pod_items | map(select((.spec.nodeName // "") == $node_name and unhealthy_pod)) | length) as $unhealthy
      | ($event_items | map(select((.involvedObject.kind // "") == "Node" and (.involvedObject.name // "") == $node_name and (.type // "") == "Warning")) | length) as $node_warnings
      | {
          context: $context,
          node: $node_name,
          ready: $ready,
          unschedulable: $unsched,
          taint_count: (($node.spec.taints // []) | length),
          memory_pressure: $memory,
          disk_pressure: $disk,
          pid_pressure: $pid,
          network_unavailable: $network,
          unhealthy_pods_on_node: $unhealthy,
          node_warning_events: $node_warnings,
          zero_disruption_pdbs_cluster: $zero_disruption_pdbs,
          kubelet_version: ($node.status.nodeInfo.kubeletVersion // ""),
          kernel_version: ($node.status.nodeInfo.kernelVersion // ""),
          boot_id: ($node.status.nodeInfo.bootID // ""),
          ready_transition_time: (condition($node; "Ready").lastTransitionTime // ""),
          gate: gate_for($ready; $memory; $disk; $pid; $network; $unsched; $unhealthy)
        }
    ]'

for ctx in "${contexts[@]}"; do
  nodes_json="$("${KUBECTL_BASE[@]}" --context "$ctx" get nodes -o json --request-timeout=20s)" \
    || die "failed to query nodes for context: $ctx"
  pods_json="$("${KUBECTL_BASE[@]}" --context "$ctx" get pods -A -o json --request-timeout=20s)" \
    || die "failed to query pods for context: $ctx"
  pdbs_json="$("${KUBECTL_BASE[@]}" --context "$ctx" get pdb -A -o json --request-timeout=20s 2>/dev/null || printf '{"items":[]}' )"
  events_json="$("${KUBECTL_BASE[@]}" --context "$ctx" get events -A -o json --request-timeout=20s 2>/dev/null || printf '{"items":[]}' )"

  tmp_file="$(mktemp)"
  tmp_files+=("$tmp_file")
  jq -n \
    --arg context "$ctx" \
    --argjson nodes "$nodes_json" \
    --argjson pods "$pods_json" \
    --argjson pdbs "$pdbs_json" \
    --argjson events "$events_json" \
    "$jq_filter" > "$tmp_file"
done

case "$OUTPUT" in
  json)
    jq -s 'add' "${tmp_files[@]}"
    ;;
  summary)
    jq -s -r '
      add as $rows
      | {
          contexts: ($rows | map(.context) | unique | length),
          nodes: ($rows | length),
          review_ready: ($rows | map(select(.gate == "REVIEW_READY")) | length),
          blocked: ($rows | map(select((.gate | startswith("BLOCK_")))) | length),
          review_required: ($rows | map(select((.gate | startswith("REVIEW_")) and .gate != "REVIEW_READY")) | length)
        }
      | to_entries[] | "\(.key)=\(.value)"' "${tmp_files[@]}"
    ;;
  csv)
    echo 'context,node,ready,unschedulable,taint_count,memory_pressure,disk_pressure,pid_pressure,network_unavailable,unhealthy_pods_on_node,node_warning_events,zero_disruption_pdbs_cluster,kubelet_version,kernel_version,boot_id,ready_transition_time,gate'
    jq -s -r 'add[] | [.context,.node,.ready,.unschedulable,.taint_count,.memory_pressure,.disk_pressure,.pid_pressure,.network_unavailable,.unhealthy_pods_on_node,.node_warning_events,.zero_disruption_pdbs_cluster,.kubelet_version,.kernel_version,.boot_id,.ready_transition_time,.gate] | @csv' "${tmp_files[@]}"
    ;;
  table)
    {
      printf 'CONTEXT\tNODE\tREADY\tCORDONED\tTAINTS\tUNHEALTHY_PODS\tWARNINGS\tZERO_PDBS\tKERNEL\tBOOT_ID\tGATE\n'
      jq -s -r 'add[] | [.context,.node,.ready,.unschedulable,.taint_count,.unhealthy_pods_on_node,.node_warning_events,.zero_disruption_pdbs_cluster,.kernel_version,.boot_id,.gate] | @tsv' "${tmp_files[@]}"
    } | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
    ;;
esac
