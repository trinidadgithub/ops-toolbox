#!/usr/bin/env bash
set -euo pipefail

CONTEXT=""
ALL_CONTEXTS=false
NAMESPACE=""
KUBECONFIG_ARG=""
OUTPUT="table"
INCLUDE_SUCCEEDED=false

usage() {
  cat <<'EOF'
Usage: k8s-unhealthy-pods.sh [options]

Report Kubernetes pods that are not healthy.

Options:
  --context NAME        Kubernetes context to query.
  --all-contexts        Query every context in the kubeconfig.
  --namespace NAME      Namespace to query. Defaults to all namespaces.
  --kubeconfig PATH     Kubeconfig path. Defaults to kubectl discovery.
  --output FORMAT       table, csv, or json. Default: table.
  --include-succeeded   Include Succeeded pods in output.
  -h, --help            Show this help.

Examples:
  k8s-unhealthy-pods.sh --context example-rke2
  k8s-unhealthy-pods.sh --all-contexts --output csv
  k8s-unhealthy-pods.sh --namespace example-app --output json
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
    --namespace|-n) NAMESPACE="${2:-}"; shift 2 ;;
    --kubeconfig) KUBECONFIG_ARG="${2:-}"; shift 2 ;;
    --output|-o) OUTPUT="${2:-}"; shift 2 ;;
    --include-succeeded) INCLUDE_SUCCEEDED=true; shift ;;
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

# shellcheck disable=SC2016
jq_filter='[.items[]
  | . as $pod
  | [(.status.containerStatuses[]?.state.waiting.reason // empty), (.status.containerStatuses[]?.state.terminated.reason // empty)] as $reasons
  | select(
      (.status.phase != "Running" and .status.phase != "Succeeded")
      or ([.status.containerStatuses[]?.ready] | any(. == false))
      or ($reasons | length > 0)
    )
  | {
      context: $context,
      namespace: .metadata.namespace,
      pod: .metadata.name,
      node: (.spec.nodeName // ""),
      phase: .status.phase,
      ready: (([.status.containerStatuses[]?] | map(select(.ready == true)) | length | tostring) + "/" + ([.status.containerStatuses[]?] | length | tostring)),
      reasons: ($reasons | unique | join(","))
    }
]'

tmp_files=()
cleanup() {
  if [[ ${#tmp_files[@]} -gt 0 ]]; then
    rm -f "${tmp_files[@]}"
  fi
}
trap cleanup EXIT

for ctx in "${contexts[@]}"; do
  args=(--context "$ctx" get pods)
  if [[ -n "$NAMESPACE" ]]; then
    args+=(-n "$NAMESPACE")
  else
    args+=(-A)
  fi
  args+=(-o json --request-timeout=15s)

  pod_json="$("${KUBECTL_BASE[@]}" "${args[@]}")" || die "failed to query pods for context: $ctx"
  tmp_file="$(mktemp)"
  tmp_files+=("$tmp_file")

  if [[ "$INCLUDE_SUCCEEDED" == true ]]; then
    jq --arg context "$ctx" '[.items[] | select(.status.phase != "Running") | {
      context: $context,
      namespace: .metadata.namespace,
      pod: .metadata.name,
      node: (.spec.nodeName // ""),
      phase: .status.phase,
      ready: (([.status.containerStatuses[]?] | map(select(.ready == true)) | length | tostring) + "/" + ([.status.containerStatuses[]?] | length | tostring)),
      reasons: ([.status.containerStatuses[]?.state.waiting.reason // empty, .status.containerStatuses[]?.state.terminated.reason // empty] | unique | join(","))
    }]' <<< "$pod_json" > "$tmp_file"
  else
    jq --arg context "$ctx" "$jq_filter" <<< "$pod_json" > "$tmp_file"
  fi
done

case "$OUTPUT" in
  json)
    jq -s 'add' "${tmp_files[@]}"
    ;;
  csv)
    echo 'context,namespace,pod,node,phase,ready,reasons'
    jq -rs 'add[] | [.context, .namespace, .pod, .node, .phase, .ready, .reasons] | @csv' "${tmp_files[@]}"
    ;;
  table)
    {
      printf 'CONTEXT\tNAMESPACE\tPOD\tNODE\tPHASE\tREADY\tREASONS\n'
      jq -rsr 'add[] | [.context, .namespace, .pod, .node, .phase, .ready, .reasons] | @tsv' "${tmp_files[@]}"
    } | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
    ;;
esac
