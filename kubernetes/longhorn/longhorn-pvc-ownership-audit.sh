#!/usr/bin/env bash
set -euo pipefail

CONTEXT=""
KUBECONFIG_ARG=""
LONGHORN_NAMESPACE="longhorn-system"
NAMESPACE=""
PVC=""
ALL_UNUSED=false
OUTPUT="text"

usage() {
  cat <<'EOF'
Usage: longhorn-pvc-ownership-audit.sh [options]

Inspect PVC ownership signals before considering Longhorn PVC cleanup.

Options:
  --context NAME             Kubernetes context to query.
  --kubeconfig PATH          Kubeconfig path. Defaults to kubectl discovery.
  --longhorn-namespace NAME  Longhorn namespace. Default: longhorn-system.
  --namespace NAME           PVC namespace to inspect.
  --pvc NAME                 PVC name to inspect.
  --all-unused               Inspect PVCs not referenced by currently running Pod volume claims.
  --output FORMAT            text or json. Default: text.
  -h, --help                 Show this help.

Examples:
  longhorn-pvc-ownership-audit.sh --context example-rke2 --namespace example-logs --pvc export-0-example-0
  longhorn-pvc-ownership-audit.sh --all-unused --output json

Notes:
  This utility is read-only. Classifications are review aids, not deletion approval.
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
    --longhorn-namespace) LONGHORN_NAMESPACE="${2:-}"; shift 2 ;;
    --namespace|-n) NAMESPACE="${2:-}"; shift 2 ;;
    --pvc) PVC="${2:-}"; shift 2 ;;
    --all-unused) ALL_UNUSED=true; shift ;;
    --output|-o) OUTPUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$OUTPUT" in
  text|json) ;;
  *) echo "ERROR: --output must be text or json." >&2; exit 2 ;;
esac

if [[ "$ALL_UNUSED" == true && ( -n "$NAMESPACE" || -n "$PVC" ) ]]; then
  die "use either --all-unused or --namespace/--pvc, not both."
fi
if [[ "$ALL_UNUSED" == false && ( -z "$NAMESPACE" || -z "$PVC" ) ]]; then
  echo "ERROR: provide --namespace and --pvc, or use --all-unused." >&2
  usage >&2
  exit 2
fi

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

kubectl_json() {
  "${KUBECTL_BASE[@]}" "$@" -o json --request-timeout=20s 2>/dev/null || printf '{"items":[]}'
}

inspect_one() {
  local namespace="$1"
  local pvc="$2"
  local pvc_json pv pv_json volume_handle lh_json pod_refs workload_refs sts_matches owner_refs helm_release helm_namespace classification reasons_json replica_summary

  pvc_json="$("${KUBECTL_BASE[@]}" -n "$namespace" get pvc "$pvc" -o json --request-timeout=20s)" \
    || die "PVC not found: $namespace/$pvc"

  pv="$(jq -r '.spec.volumeName // ""' <<< "$pvc_json")"
  if [[ -n "$pv" ]]; then
    pv_json="$("${KUBECTL_BASE[@]}" get pv "$pv" -o json --request-timeout=20s 2>/dev/null || printf '{}')"
  else
    pv_json='{}'
  fi
  volume_handle="$(jq -r '.spec.csi.volumeHandle // ""' <<< "$pv_json")"

  if [[ -n "$volume_handle" ]]; then
    lh_json="$("${KUBECTL_BASE[@]}" -n "$LONGHORN_NAMESPACE" get volumes.longhorn.io "$volume_handle" -o json --request-timeout=20s 2>/dev/null || printf '{}')"
    replica_summary="$(kubectl_json -n "$LONGHORN_NAMESPACE" get replicas.longhorn.io \
      | jq --arg volume "$volume_handle" '[.items[] | select(.spec.volumeName == $volume) | {name: .metadata.name, node: (.spec.nodeID // ""), failed_at: (.spec.failedAt // "")}]')"
  else
    lh_json='{}'
    replica_summary='[]'
  fi

  pod_refs="$(kubectl_json -n "$namespace" get pods \
    | jq --arg pvc "$pvc" '[.items[] | select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName == $pvc)) | {name: .metadata.name, phase: (.status.phase // "")} ]')"

  workload_refs="$(for kind in deployments statefulsets daemonsets jobs cronjobs; do
    kubectl_json -n "$namespace" get "$kind" \
      | jq --arg pvc "$pvc" --arg kind "$kind" '.items[] | select(any((.spec.template.spec.volumes // .spec.jobTemplate.spec.template.spec.volumes // []); .persistentVolumeClaim.claimName == $pvc)) | {kind: $kind, name: .metadata.name}'
  done | jq -s '.')"

  sts_matches="$(kubectl_json -n "$namespace" get statefulsets \
    | jq --arg pvc "$pvc" '[.items[] as $sts | $sts.spec.volumeClaimTemplates[]? | select($pvc | test("^" + .metadata.name + "-" + $sts.metadata.name + "-[0-9]+$")) | {kind: "statefulset-template", statefulset: $sts.metadata.name, template: .metadata.name, replicas: ($sts.spec.replicas // 0), ready: ($sts.status.readyReplicas // 0)}]')"

  owner_refs="$(jq '[.metadata.ownerReferences[]? | {kind: .kind, name: .name, controller: (.controller // false)}]' <<< "$pvc_json")"
  helm_release="$(jq -r '.metadata.annotations["meta.helm.sh/release-name"] // .metadata.labels["app.kubernetes.io/instance"] // ""' <<< "$pvc_json")"
  helm_namespace="$(jq -r '.metadata.annotations["meta.helm.sh/release-namespace"] // ""' <<< "$pvc_json")"

  classification="REVIEW"
  reasons_json='[]'
  add_reason() {
    reasons_json="$(jq --arg reason "$1" '. + [$reason]' <<< "$reasons_json")"
  }

  if [[ "$(jq 'length' <<< "$pod_refs")" -gt 0 ]]; then
    classification="IN_USE"
    add_reason "Referenced by an existing Pod persistentVolumeClaim volume."
  fi
  if [[ "$(jq 'length' <<< "$workload_refs")" -gt 0 ]]; then
    classification="IN_USE_OR_RETAIN"
    add_reason "Referenced directly by a workload template."
  fi
  if [[ "$(jq 'length' <<< "$sts_matches")" -gt 0 ]]; then
    classification="STATEFULSET_DATA_RETAIN"
    add_reason "Name matches a current StatefulSet volumeClaimTemplate."
  fi
  if [[ "$(jq 'length' <<< "$owner_refs")" -gt 0 ]]; then
    add_reason "PVC has ownerReferences; inspect owner lifecycle before cleanup."
  fi
  if [[ -n "$helm_release" ]]; then
    add_reason "PVC appears associated with Helm release or app instance: $helm_release."
  fi
  if [[ "$(jq 'length' <<< "$pod_refs")" -eq 0 && "$(jq 'length' <<< "$workload_refs")" -eq 0 && "$(jq 'length' <<< "$sts_matches")" -eq 0 && "$(jq 'length' <<< "$owner_refs")" -eq 0 ]]; then
    classification="UNOWNED_CANDIDATE"
    add_reason "No Pod, direct workload, StatefulSet template, or ownerReference found. Human review still required."
  fi

  jq -n \
    --arg namespace "$namespace" \
    --arg pvc "$pvc" \
    --arg pv "$pv" \
    --arg volume_handle "$volume_handle" \
    --arg classification "$classification" \
    --arg helm_release "$helm_release" \
    --arg helm_namespace "$helm_namespace" \
    --argjson pvc_json "$pvc_json" \
    --argjson pv_json "$pv_json" \
    --argjson lh_json "$lh_json" \
    --argjson pod_refs "$pod_refs" \
    --argjson workload_refs "$workload_refs" \
    --argjson sts_matches "$sts_matches" \
    --argjson owner_refs "$owner_refs" \
    --argjson replica_summary "$replica_summary" \
    --argjson reasons "$reasons_json" \
    '{
      namespace: $namespace,
      pvc: $pvc,
      classification: $classification,
      phase: ($pvc_json.status.phase // ""),
      capacity: ($pvc_json.status.capacity.storage // $pvc_json.spec.resources.requests.storage // ""),
      storage_class: ($pvc_json.spec.storageClassName // ""),
      created: ($pvc_json.metadata.creationTimestamp // ""),
      pv: $pv,
      reclaim_policy: ($pv_json.spec.persistentVolumeReclaimPolicy // ""),
      volume_handle: $volume_handle,
      helm_release: $helm_release,
      helm_namespace: $helm_namespace,
      owner_refs: $owner_refs,
      pod_refs: $pod_refs,
      workload_refs: $workload_refs,
      statefulset_template_matches: $sts_matches,
      longhorn_volume: {
        state: ($lh_json.status.state // ""),
        robustness: ($lh_json.status.robustness // ""),
        declared_bytes: ($lh_json.spec.size // ""),
        actual_bytes: ($lh_json.status.actualSize // ""),
        replicas: ($lh_json.spec.numberOfReplicas // "")
      },
      longhorn_replicas: $replica_summary,
      reasons: $reasons
    }'
}

reports=()
tmp_files=()
cleanup() {
  if [[ ${#tmp_files[@]} -gt 0 ]]; then
    rm -f "${tmp_files[@]}"
  fi
}
trap cleanup EXIT

if [[ "$ALL_UNUSED" == true ]]; then
  used_file="$(mktemp)"
  tmp_files+=("$used_file")
  kubectl_json get pods -A \
    | jq -r '.items[] | .metadata.namespace as $ns | .spec.volumes[]? | select(.persistentVolumeClaim != null) | "\($ns)/\(.persistentVolumeClaim.claimName)"' \
    | sort -u > "$used_file"

  while IFS=$'\t' read -r ns name; do
    if ! grep -Fxq "$ns/$name" "$used_file"; then
      report_file="$(mktemp)"
      tmp_files+=("$report_file")
      inspect_one "$ns" "$name" > "$report_file"
      reports+=("$report_file")
    fi
  done < <(kubectl_json get pvc -A | jq -r '.items[] | [.metadata.namespace, .metadata.name] | @tsv' | sort)
else
  report_file="$(mktemp)"
  tmp_files+=("$report_file")
  inspect_one "$NAMESPACE" "$PVC" > "$report_file"
  reports+=("$report_file")
fi

if [[ "$OUTPUT" == "json" ]]; then
  jq -s '.' "${reports[@]}"
else
  for report in "${reports[@]}"; do
    jq -r '
      "================================================================================",
      "PVC: \(.namespace)/\(.pvc)",
      "Classification: \(.classification)",
      "================================================================================",
      "Phase: " + .phase,
      "Capacity: " + .capacity,
      "StorageClass: " + .storage_class,
      "PV: " + .pv,
      "Reclaim policy: " + .reclaim_policy,
      "Longhorn volume: " + .volume_handle,
      "Longhorn state: " + .longhorn_volume.state + " / " + .longhorn_volume.robustness,
      "Longhorn replicas: " + (.longhorn_volume.replicas | tostring),
      "Helm release: " + (if .helm_release == "" then "-" else .helm_release end),
      "Pod refs: " + (.pod_refs | length | tostring),
      "Workload refs: " + (.workload_refs | length | tostring),
      "StatefulSet template matches: " + (.statefulset_template_matches | length | tostring),
      "Owner refs: " + (.owner_refs | length | tostring),
      "Reasons:",
      (.reasons[]? | " - " + .),
      ""
    ' "$report"
  done
fi
