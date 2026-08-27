#!/usr/bin/env bash
set -euo pipefail

CONTEXT=""
KUBECONFIG_ARG=""
NAMESPACE=""
LONGHORN_NAMESPACE="longhorn-system"
OUTPUT="table"
EVENT_LIMIT=25

usage() {
  cat <<'EOF'
Usage: longhorn-storageclass-health-report.sh [options]

Report health signals for PVCs backed by Longhorn storage classes.

Options:
  --context NAME             Kubernetes context to query.
  --kubeconfig PATH          Kubeconfig path. Defaults to kubectl discovery.
  --namespace NAME           Application namespace to query. Defaults to all namespaces.
  --longhorn-namespace NAME  Longhorn namespace. Default: longhorn-system.
  --event-limit N            Maximum related warning events in output. Default: 25.
  --output FORMAT            table, json, or summary. Default: table.
  -h, --help                 Show this help.

Examples:
  longhorn-storageclass-health-report.sh --context example-rke2
  longhorn-storageclass-health-report.sh --namespace example-app --output json

Notes:
  This utility is read-only. It queries Kubernetes and Longhorn resources only.
  It does not repair, detach, attach, delete, expand, or modify storage objects.
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
    --context) CONTEXT="${2:-}"; shift 2 ;;
    --kubeconfig) KUBECONFIG_ARG="${2:-}"; shift 2 ;;
    --namespace|-n) NAMESPACE="${2:-}"; shift 2 ;;
    --longhorn-namespace) LONGHORN_NAMESPACE="${2:-}"; shift 2 ;;
    --event-limit) EVENT_LIMIT="${2:-}"; shift 2 ;;
    --output|-o) OUTPUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$OUTPUT" in
  table|json|summary) ;;
  *) echo "ERROR: --output must be table, json, or summary." >&2; exit 2 ;;
esac

is_positive_integer "$EVENT_LIMIT" || { echo "ERROR: --event-limit must be a positive integer." >&2; exit 2; }

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

pvc_file="${tmp_dir}/pvcs.json"
pv_file="${tmp_dir}/pvs.json"
sc_file="${tmp_dir}/storageclasses.json"
volumes_file="${tmp_dir}/volumes.json"
replicas_file="${tmp_dir}/replicas.json"
events_file="${tmp_dir}/events.json"

pvc_args=(get pvc)
if [[ -n "$NAMESPACE" ]]; then
  pvc_args+=(-n "$NAMESPACE")
else
  pvc_args+=(-A)
fi
pvc_args+=(-o json --request-timeout=20s)

"${KUBECTL_BASE[@]}" "${pvc_args[@]}" > "$pvc_file" \
  || die "failed to query PVCs"
"${KUBECTL_BASE[@]}" get pv -o json --request-timeout=20s > "$pv_file" \
  || die "failed to query PVs"
"${KUBECTL_BASE[@]}" get storageclass -o json --request-timeout=20s > "$sc_file" \
  || die "failed to query storage classes"
"${KUBECTL_BASE[@]}" -n "$LONGHORN_NAMESPACE" get volumes.longhorn.io -o json --request-timeout=20s > "$volumes_file" \
  || die "failed to query volumes.longhorn.io in namespace: $LONGHORN_NAMESPACE"
"${KUBECTL_BASE[@]}" -n "$LONGHORN_NAMESPACE" get replicas.longhorn.io -o json --request-timeout=20s > "$replicas_file" \
  || die "failed to query replicas.longhorn.io in namespace: $LONGHORN_NAMESPACE"
"${KUBECTL_BASE[@]}" get events -A -o json --request-timeout=20s > "$events_file" 2>/dev/null \
  || printf '{"items":[]}' > "$events_file"

report_json="$(jq -n \
  --slurpfile pvc "$pvc_file" \
  --slurpfile pv "$pv_file" \
  --slurpfile sc "$sc_file" \
  --slurpfile volumes "$volumes_file" \
  --slurpfile replicas "$replicas_file" \
  --slurpfile events "$events_file" \
  --arg namespace_filter "$NAMESPACE" \
  --arg longhorn_namespace "$LONGHORN_NAMESPACE" \
  --argjson event_limit "$EVENT_LIMIT" '
    def longhorn_storageclass($name):
      ($sc[0].items[]? | select(.metadata.name == $name)) as $class
      | (($class.provisioner // "") == "driver.longhorn.io"
         or (($class.metadata.name // "") | test("longhorn"; "i")));
    def pv_for($claim):
      ($pv[0].items[]? | select(.metadata.name == ($claim.spec.volumeName // ""))) // {};
    def volume_for($pv_obj):
      ($volumes[0].items[]? | select((.status.kubernetesStatus.pvName // .metadata.name) == ($pv_obj.metadata.name // ""))) // {};
    def replicas_for($volume_name):
      [$replicas[0].items[]? | select((.spec.volumeName // .status.volumeName // "") == $volume_name)];
    def replica_state($replica):
      ($replica.status.currentState // $replica.status.state // "unknown");
    def expected_replicas($volume):
      (($volume.spec.numberOfReplicas // $volume.status.numberOfReplicas // 0) | tonumber? // 0);
    def event_time($event):
      ($event.lastTimestamp // $event.eventTime // $event.metadata.creationTimestamp // "");
    def related_events($claim; $pv_name; $volume_name):
      [$events[0].items[]?
        | select((.type // "") == "Warning" or ((.reason // "") | test("fail|error|unhealthy|degrad|mount|attach|detach|replica|volume"; "i")))
        | select(
            (.metadata.namespace // "") == ($claim.metadata.namespace // "")
            and (
              (.involvedObject.name // "") == ($claim.metadata.name // "")
              or (.involvedObject.name // "") == $pv_name
              or (.involvedObject.name // "") == $volume_name
              or (.message // "" | contains($claim.metadata.name // ""))
              or (.message // "" | contains($pv_name))
              or (.message // "" | contains($volume_name))
            )
          )
        | {
            namespace: (.metadata.namespace // ""),
            object: ((.involvedObject.kind // "") + "/" + (.involvedObject.name // .metadata.name)),
            reason: (.reason // ""),
            time: event_time(.),
            message: (.message // "")
          }
      ] | sort_by(.time) | reverse | .[:$event_limit];

    ($pvc[0].items // []) as $claims
    | ($claims
      | map(select(longhorn_storageclass(.spec.storageClassName // ""))
        | . as $claim
        | (pv_for($claim)) as $pv_obj
        | (volume_for($pv_obj)) as $volume
        | ($volume.metadata.name // $pv_obj.metadata.name // "") as $volume_name
        | (replicas_for($volume_name)) as $volume_replicas
        | (expected_replicas($volume)) as $expected
        | ($volume_replicas | map(select(replica_state(.) == "running"))) as $running_replicas
        | ($volume_replicas | map(select(replica_state(.) != "running"))) as $non_running_replicas
        | (related_events($claim; ($pv_obj.metadata.name // ""); $volume_name)) as $related
        | {
            namespace: $claim.metadata.namespace,
            pvc: $claim.metadata.name,
            storage_class: ($claim.spec.storageClassName // ""),
            pv: ($pv_obj.metadata.name // ""),
            longhorn_volume: $volume_name,
            volume_state: ($volume.status.state // "MISSING"),
            robustness: ($volume.status.robustness // "MISSING"),
            expected_replicas: $expected,
            running_replicas: ($running_replicas | length),
            non_running_replicas: ($non_running_replicas | length),
            replica_nodes: ($running_replicas | map(.spec.nodeID // .status.currentNodeID // "") | map(select(. != "")) | unique),
            non_running_replica_names: ($non_running_replicas | map(.metadata.name)),
            warning_events: ($related | length),
            health: (
              if ($volume | length) == 0 then "REVIEW_MISSING_LONGHORN_VOLUME"
              elif (($volume.status.robustness // "") != "healthy") then "REVIEW_VOLUME_NOT_HEALTHY"
              elif ($expected > 0 and ($running_replicas | length) < $expected) then "REVIEW_REPLICA_SHORTFALL"
              elif ($non_running_replicas | length) > 0 then "REVIEW_NON_RUNNING_REPLICAS"
              elif ($expected > 1 and ($running_replicas | map(.spec.nodeID // .status.currentNodeID // "") | map(select(. != "")) | unique | length) < 2) then "REVIEW_REPLICA_PLACEMENT"
              elif ($related | length) > 0 then "REVIEW_WARNING_EVENTS"
              else "OK" end
            ),
            events: $related
          })
      ) as $pvc_health
    | {
        namespace_filter: (if $namespace_filter == "" then "all" else $namespace_filter end),
        longhorn_namespace: $longhorn_namespace,
        summary: {
          longhorn_pvcs: ($pvc_health | length),
          ok: ($pvc_health | map(select(.health == "OK")) | length),
          review: ($pvc_health | map(select(.health != "OK")) | length),
          degraded_or_faulted: ($pvc_health | map(select(.robustness != "healthy")) | length),
          replica_shortfall: ($pvc_health | map(select(.health == "REVIEW_REPLICA_SHORTFALL" or .health == "REVIEW_NON_RUNNING_REPLICAS")) | length),
          warning_events: ($pvc_health | map(.warning_events) | add // 0),
          readiness_gate: (if ($pvc_health | map(select(.health != "OK")) | length) == 0 then "REVIEW_READY" else "REVIEW_BLOCKED" end)
        },
        pvc_health: $pvc_health
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
    echo "Longhorn PVC Health"
    {
      printf 'NAMESPACE\tPVC\tSTORAGECLASS\tPV\tVOLUME\tROBUSTNESS\tRUNNING_REPLICAS\tEXPECTED_REPLICAS\tWARNING_EVENTS\tHEALTH\n'
      jq -r '.pvc_health[] | [.namespace,.pvc,.storage_class,.pv,.longhorn_volume,.robustness,.running_replicas,.expected_replicas,.warning_events,.health] | @tsv' <<< "$report_json"
    } | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
    ;;
esac
