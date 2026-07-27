#!/usr/bin/env bash
set -euo pipefail

CONTEXT=""
KUBECONFIG_ARG=""
NAMESPACE="kube-system"
LABEL_SELECTOR="k8s-app=kube-proxy"
OUTPUT_DIR="reports/kube-proxy"
PREFIX="kube-proxy-diagnostics"
SINCE="1h"
INCLUDE_CNI=false
CREATE_ARCHIVE=true

usage() {
  cat <<'EOF'
Usage: kube-proxy-diagnostics.sh [options]

Collect a read-only kube-proxy diagnostics bundle from the Kubernetes API.

Options:
  --context NAME        Kubernetes context to query.
  --kubeconfig PATH     Kubeconfig path. Defaults to kubectl discovery.
  --namespace NAME      kube-proxy namespace. Default: kube-system.
  --selector LABELS     kube-proxy pod label selector. Default: k8s-app=kube-proxy.
  --since DURATION      Log duration for kubectl logs. Default: 1h.
  --output-dir DIR      Parent output directory. Default: reports/kube-proxy.
  --prefix NAME         Bundle prefix. Default: kube-proxy-diagnostics.
  --include-cni         Include best-effort CNI namespace snapshots.
  --no-archive          Leave output directory unarchived.
  -h, --help            Show this help.

Examples:
  kube-proxy-diagnostics.sh --context example-rke2
  kube-proxy-diagnostics.sh --namespace kube-system --since 2h
  kube-proxy-diagnostics.sh --include-cni --no-archive
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

safe_name() {
  local value="$1"
  value="${value//[^A-Za-z0-9._-]/_}"
  printf '%s' "$value"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) CONTEXT="${2:-}"; shift 2 ;;
    --kubeconfig) KUBECONFIG_ARG="${2:-}"; shift 2 ;;
    --namespace|-n) NAMESPACE="${2:-}"; shift 2 ;;
    --selector|-l) LABEL_SELECTOR="${2:-}"; shift 2 ;;
    --since) SINCE="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --prefix) PREFIX="${2:-}"; shift 2 ;;
    --include-cni) INCLUDE_CNI=true; shift ;;
    --no-archive) CREATE_ARCHIVE=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$NAMESPACE" ]] || { echo "ERROR: --namespace cannot be empty." >&2; exit 2; }
[[ -n "$LABEL_SELECTOR" ]] || { echo "ERROR: --selector cannot be empty." >&2; exit 2; }
[[ -n "$OUTPUT_DIR" ]] || { echo "ERROR: --output-dir cannot be empty." >&2; exit 2; }
[[ -n "$PREFIX" ]] || { echo "ERROR: --prefix cannot be empty." >&2; exit 2; }
[[ -n "$SINCE" ]] || { echo "ERROR: --since cannot be empty." >&2; exit 2; }

command -v kubectl >/dev/null 2>&1 || die "kubectl is required."
command -v tar >/dev/null 2>&1 || die "tar is required."

KUBECTL_BASE=(kubectl)
if [[ -n "$KUBECONFIG_ARG" ]]; then
  [[ -f "$KUBECONFIG_ARG" ]] || die "kubeconfig not found: $KUBECONFIG_ARG"
  KUBECTL_BASE+=(--kubeconfig "$KUBECONFIG_ARG")
fi
if [[ -n "$CONTEXT" ]]; then
  KUBECTL_BASE+=(--context "$CONTEXT")
fi

if [[ -z "$CONTEXT" ]]; then
  CONTEXT="$("${KUBECTL_BASE[@]}" config current-context 2>/dev/null || true)"
fi
[[ -n "$CONTEXT" ]] || die "no current context found; provide --context."

timestamp="$(date +%Y%m%d-%H%M%S)"
bundle_name="$(safe_name "${PREFIX}-${CONTEXT}-${timestamp}")"
bundle_dir="${OUTPUT_DIR}/${bundle_name}"
mkdir -p "$bundle_dir"

log() {
  printf '[%s] %s\n' "$(date -Is)" "$*" | tee -a "${bundle_dir}/collector.log" >&2
}

capture() {
  local label="$1"
  local output_file="$2"
  shift 2

  log "Collecting ${label}"
  {
    printf '## %s\n' "$label"
    printf '## command:'
    printf ' %q' "$@"
    printf '\n\n'
    "$@"
  } > "${bundle_dir}/${output_file}" 2>&1 || true
}

capture_namespaced() {
  local label="$1"
  local output_file="$2"
  shift 2
  capture "$label" "$output_file" "${KUBECTL_BASE[@]}" -n "$NAMESPACE" "$@"
}

log "Creating kube-proxy diagnostics bundle at ${bundle_dir}"

cat > "${bundle_dir}/README.txt" <<EOF
kube-proxy diagnostics bundle
Generated: $(date -Is)
Context: ${CONTEXT}
Namespace: ${NAMESPACE}
Selector: ${LABEL_SELECTOR}
Since: ${SINCE}
Include CNI: ${INCLUDE_CNI}

This bundle may contain hostnames, IP addresses, pod names, service names, events, and logs.
Review before sharing outside the operating environment.
EOF

capture "client and server version" "kubectl-version.yaml" "${KUBECTL_BASE[@]}" version -o yaml
capture "cluster info" "cluster-info.txt" "${KUBECTL_BASE[@]}" cluster-info
capture "nodes wide" "nodes-wide.txt" "${KUBECTL_BASE[@]}" get nodes -o wide
capture "nodes json" "nodes.json" "${KUBECTL_BASE[@]}" get nodes -o json
capture "all events" "events-all.txt" "${KUBECTL_BASE[@]}" get events -A --sort-by=.lastTimestamp -o wide

capture_namespaced "kube-proxy DaemonSet yaml" "kube-proxy-daemonset.yaml" get daemonset kube-proxy -o yaml
capture_namespaced "kube-proxy pods wide" "kube-proxy-pods-wide.txt" get pods -l "$LABEL_SELECTOR" -o wide
capture_namespaced "kube-proxy pods json" "kube-proxy-pods.json" get pods -l "$LABEL_SELECTOR" -o json
capture_namespaced "kube-proxy configmaps" "kube-proxy-configmaps.yaml" get configmap -o yaml
capture_namespaced "namespace events" "events-${NAMESPACE}.txt" get events --sort-by=.lastTimestamp -o wide

mapfile -t pods < <("${KUBECTL_BASE[@]}" -n "$NAMESPACE" get pods -l "$LABEL_SELECTOR" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

for pod in "${pods[@]}"; do
  [[ -n "$pod" ]] || continue
  pod_dir="${bundle_dir}/pods/${pod}"
  mkdir -p "$pod_dir"
  capture "describe pod ${pod}" "pods/${pod}/describe.txt" "${KUBECTL_BASE[@]}" -n "$NAMESPACE" describe pod "$pod"
  capture "logs current ${pod}" "pods/${pod}/logs-current.txt" "${KUBECTL_BASE[@]}" -n "$NAMESPACE" logs "$pod" --all-containers --since "$SINCE" --timestamps
  capture "logs previous ${pod}" "pods/${pod}/logs-previous.txt" "${KUBECTL_BASE[@]}" -n "$NAMESPACE" logs "$pod" --all-containers --previous --timestamps
done

if [[ "$INCLUDE_CNI" == true ]]; then
  for ns in kube-system calico-system tigera-operator cilium; do
    if "${KUBECTL_BASE[@]}" get namespace "$ns" >/dev/null 2>&1; then
      mkdir -p "${bundle_dir}/cni/${ns}"
      capture "CNI pods in ${ns}" "cni/${ns}/pods-wide.txt" "${KUBECTL_BASE[@]}" -n "$ns" get pods -o wide
      capture "CNI daemonsets in ${ns}" "cni/${ns}/daemonsets.yaml" "${KUBECTL_BASE[@]}" -n "$ns" get daemonsets -o yaml
      capture "CNI events in ${ns}" "cni/${ns}/events.txt" "${KUBECTL_BASE[@]}" -n "$ns" get events --sort-by=.lastTimestamp -o wide
    fi
  done
fi

log "Extracting kube-proxy red flags"
grep -R -iE 'crash|back-off|backoff|error|failed|failure|panic|timeout|timed out|permission|denied|conntrack|iptables|ipvs|nftables|oom|killed' \
  "${bundle_dir}" 2>/dev/null \
  | tail -n 400 > "${bundle_dir}/red-flags.txt" || true

if [[ "$CREATE_ARCHIVE" == true ]]; then
  archive_path="${bundle_dir}.tar.gz"
  log "Creating archive ${archive_path}"
  tar -C "$OUTPUT_DIR" -czf "$archive_path" "$bundle_name" || die "failed to create archive: $archive_path"
  log "Done. Wrote ${archive_path}"
  printf '%s\n' "$archive_path"
else
  log "Done. Wrote ${bundle_dir}"
  printf '%s\n' "$bundle_dir"
fi
