#!/usr/bin/env bash
set -euo pipefail

CONTEXT=""
ALL_CONTEXTS=false
NAMESPACE=""
KUBECONFIG_ARG=""
OUTPUT="table"
INCLUDE_EVENTS=false
INCLUDE_LONGHORN=false
EVENT_LIMIT=25
LONGHORN_NAMESPACE="longhorn-system"

usage() {
  cat <<'EOF'
Usage: pvc-resize-audit.sh [options]

Audit Kubernetes PVC resize and expansion signals.

Options:
  --context NAME             Kubernetes context to query.
  --all-contexts             Query every context in the kubeconfig.
  --namespace NAME           Namespace to query. Defaults to all namespaces.
  --kubeconfig PATH          Kubeconfig path. Defaults to kubectl discovery.
  --output FORMAT            table, csv, or json. Default: table.
  --include-events           Include recent resize-related events.
  --event-limit N            Maximum event findings per context. Default: 25.
  --include-longhorn         Include Longhorn volume health signals when available.
  --longhorn-namespace NAME  Longhorn namespace. Default: longhorn-system.
  -h, --help                 Show this help.

Examples:
  pvc-resize-audit.sh --context example-rke2
  pvc-resize-audit.sh --namespace example-app --include-events
  pvc-resize-audit.sh --all-contexts --output csv
  pvc-resize-audit.sh --include-longhorn --output json
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
    --all-contexts) ALL_CONTEXTS=true; shift ;;
    --namespace|-n) NAMESPACE="${2:-}"; shift 2 ;;
    --kubeconfig) KUBECONFIG_ARG="${2:-}"; shift 2 ;;
    --output|-o) OUTPUT="${2:-}"; shift 2 ;;
    --include-events) INCLUDE_EVENTS=true; shift ;;
    --event-limit) EVENT_LIMIT="${2:-}"; shift 2 ;;
    --include-longhorn) INCLUDE_LONGHORN=true; shift ;;
    --longhorn-namespace) LONGHORN_NAMESPACE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$OUTPUT" in
  table|csv|json) ;;
  *) echo "ERROR: --output must be table, csv, or json." >&2; exit 2 ;;
esac

if [[ "$ALL_CONTEXTS" == true && -n "$CONTEXT" ]]; then
  echo "ERROR: use either --context or --all-contexts, not both." >&2
  exit 2
fi

is_positive_integer "$EVENT_LIMIT" || { echo "ERROR: --event-limit must be a positive integer." >&2; exit 2; }

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

tmp_files=()
cleanup() {
  if [[ ${#tmp_files[@]} -gt 0 ]]; then
    rm -f "${tmp_files[@]}"
  fi
}
trap cleanup EXIT

for ctx in "${contexts[@]}"; do
  pvc_args=(--context "$ctx" get pvc)
  if [[ -n "$NAMESPACE" ]]; then
    pvc_args+=(-n "$NAMESPACE")
  else
    pvc_args+=(-A)
  fi
  pvc_args+=(-o json --request-timeout=15s)

  pvc_json="$("${KUBECTL_BASE[@]}" "${pvc_args[@]}")" || die "failed to query PVCs for context: $ctx"
  pv_json="$("${KUBECTL_BASE[@]}" --context "$ctx" get pv -o json --request-timeout=15s 2>/dev/null || printf '{"items":[]}')"
  sc_json="$("${KUBECTL_BASE[@]}" --context "$ctx" get storageclass -o json --request-timeout=15s 2>/dev/null || printf '{"items":[]}')"

  tmp_file="$(mktemp)"
  tmp_files+=("$tmp_file")

  jq -n \
    --arg context "$ctx" \
    --arg source "pvc" \
    --slurpfile pvc <(printf '%s' "$pvc_json") \
    --slurpfile pv <(printf '%s' "$pv_json") \
    --slurpfile sc <(printf '%s' "$sc_json") \
    '
    def pv_for($claim):
      ($pv[0].items[]? | select(.metadata.name == ($claim.spec.volumeName // ""))) // {};
    def sc_for($claim):
      ($sc[0].items[]? | select(.metadata.name == ($claim.spec.storageClassName // ""))) // {};
    [
      $pvc[0].items[]?
      | . as $claim
      | (pv_for($claim)) as $pv_obj
      | (sc_for($claim)) as $sc_obj
      | ([.status.conditions[]?.type] | unique) as $conditions
      | (.spec.resources.requests.storage // "") as $requested
      | (.status.capacity.storage // "") as $capacity
      | select(
          ($conditions | any(. == "FileSystemResizePending" or . == "Resizing"))
          or ($requested != "" and $capacity != "" and $requested != $capacity)
        )
      | {
          context: $context,
          source: $source,
          namespace: .metadata.namespace,
          name: .metadata.name,
          storageClass: (.spec.storageClassName // ""),
          requested: $requested,
          capacity: $capacity,
          pv: (.spec.volumeName // ""),
          pvCapacity: ($pv_obj.spec.capacity.storage // ""),
          reclaimPolicy: ($pv_obj.spec.persistentVolumeReclaimPolicy // ""),
          allowExpansion: ($sc_obj.allowVolumeExpansion // null),
          signal: (if ($conditions | any(. == "FileSystemResizePending")) then "FILESYSTEM_RESIZE_PENDING"
                   elif ($conditions | any(. == "Resizing")) then "RESIZING"
                   else "REQUEST_CAPACITY_MISMATCH" end),
          details: ($conditions | join(","))
        }
    ]' > "$tmp_file"

  if [[ "$INCLUDE_EVENTS" == true ]]; then
    events_json="$("${KUBECTL_BASE[@]}" --context "$ctx" get events -A -o json --request-timeout=15s 2>/dev/null || printf '{"items":[]}')"
    event_file="$(mktemp)"
    tmp_files+=("$event_file")
    jq \
      --arg context "$ctx" \
      --argjson limit "$EVENT_LIMIT" \
      '[.items[]?
        | select((.message // "" | test("resize|expand|filesystemresize|nodeexpandvolume"; "i")) or ((.reason // "") | test("resize|expand|filesystemresize|nodeexpandvolume"; "i")))
        | {
            context: $context,
            source: "event",
            namespace: (.metadata.namespace // ""),
            name: (.involvedObject.name // .metadata.name),
            storageClass: "",
            requested: "",
            capacity: "",
            pv: "",
            pvCapacity: "",
            reclaimPolicy: "",
            allowExpansion: null,
            signal: (.reason // "RESIZE_EVENT"),
            details: ((.lastTimestamp // .eventTime // .metadata.creationTimestamp // "") + " " + (.message // ""))
          }
      ] | sort_by(.details) | reverse | .[:$limit]' <<< "$events_json" > "$event_file"
  fi

  if [[ "$INCLUDE_LONGHORN" == true ]]; then
    longhorn_check_file="$(mktemp)"
    tmp_files+=("$longhorn_check_file")
    if "${KUBECTL_BASE[@]}" --context "$ctx" -n "$LONGHORN_NAMESPACE" get volumes.longhorn.io -o json --request-timeout=15s >"$longhorn_check_file" 2>/dev/null; then
      longhorn_json="$(< "$longhorn_check_file")"
      longhorn_file="$(mktemp)"
      tmp_files+=("$longhorn_file")
      jq --arg context "$ctx" --arg namespace "$LONGHORN_NAMESPACE" '[.items[]?
        | select(
            ((.status.robustness // "") != "" and (.status.robustness // "") != "healthy")
            or ((.status.conditions // []) | tostring | test("expand|resize|filesystem"; "i"))
            or ((.status.state // "") | test("fault|degrad|error"; "i"))
          )
        | {
            context: $context,
            source: "longhorn",
            namespace: $namespace,
            name: .metadata.name,
            storageClass: "",
            requested: "",
            capacity: (.status.size // ""),
            pv: (.status.kubernetesStatus.pvName // ""),
            pvCapacity: "",
            reclaimPolicy: "",
            allowExpansion: null,
            signal: "LONGHORN_VOLUME_REVIEW",
            details: ("state=" + (.status.state // "") + ";robustness=" + (.status.robustness // ""))
          }
      ]' <<< "$longhorn_json" > "$longhorn_file"
    fi
  fi
done

case "$OUTPUT" in
  json)
    jq -s 'add' "${tmp_files[@]}"
    ;;
  csv)
    echo 'context,source,namespace,name,storageClass,requested,capacity,pv,pvCapacity,reclaimPolicy,allowExpansion,signal,details'
    jq -rsr 'add[] | [.context,.source,.namespace,.name,.storageClass,.requested,.capacity,.pv,.pvCapacity,.reclaimPolicy,(.allowExpansion|tostring),.signal,.details] | @csv' "${tmp_files[@]}"
    ;;
  table)
    {
      printf 'CONTEXT\tSOURCE\tNAMESPACE\tNAME\tREQUESTED\tCAPACITY\tSTORAGECLASS\tALLOW_EXPANSION\tSIGNAL\tDETAILS\n'
      jq -rsr 'add[] | [.context,.source,.namespace,.name,.requested,.capacity,.storageClass,(.allowExpansion|tostring),.signal,.details] | @tsv' "${tmp_files[@]}"
    } | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
    ;;
esac
