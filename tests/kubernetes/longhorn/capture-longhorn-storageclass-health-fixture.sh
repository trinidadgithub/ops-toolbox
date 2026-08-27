#!/usr/bin/env bash
set -euo pipefail

CONTEXT=""
KUBECONFIG_ARG=""
NAMESPACE=""
LONGHORN_NAMESPACE="longhorn-system"
OUTPUT_DIR=""

usage() {
  cat <<'EOF'
Usage: capture-longhorn-storageclass-health-fixture.sh [options]

Capture read-only Kubernetes and Longhorn JSON for building a local fixture for
longhorn-storageclass-health-report.sh.

Options:
  --context NAME             Kubernetes context to query.
  --kubeconfig PATH          Kubeconfig path. Defaults to kubectl discovery.
  --namespace NAME           Application namespace to query. Defaults to all namespaces.
  --longhorn-namespace NAME  Longhorn namespace. Default: longhorn-system.
  --output-dir DIR           Destination directory. Defaults under reports/fixtures/.
  -h, --help                 Show this help.

Files written:
  pvcs.json
  pvs.json
  storageclasses.json
  volumes.json
  replicas.json
  events.json
  README.md

Safety:
  Read-only. Uses kubectl get only. Captured files may contain real cluster,
  namespace, node, workload, storage, event, and topology details. The default
  reports/ output path is ignored by git; do not commit captured fixtures until
  they are minimized, sanitized, and reviewed.
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
    --namespace|-n) NAMESPACE="${2:-}"; shift 2 ;;
    --longhorn-namespace) LONGHORN_NAMESPACE="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v kubectl >/dev/null 2>&1 || die "kubectl is required."
command -v jq >/dev/null 2>&1 || die "jq is required."

if [[ -z "$OUTPUT_DIR" ]]; then
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  OUTPUT_DIR="reports/fixtures/longhorn-storageclass-health-$timestamp"
fi

KUBECTL_BASE=(kubectl)
if [[ -n "$KUBECONFIG_ARG" ]]; then
  [[ -f "$KUBECONFIG_ARG" ]] || die "kubeconfig not found: $KUBECONFIG_ARG"
  KUBECTL_BASE+=(--kubeconfig "$KUBECONFIG_ARG")
fi
if [[ -n "$CONTEXT" ]]; then
  KUBECTL_BASE+=(--context "$CONTEXT")
fi

mkdir -p "$OUTPUT_DIR"

pvc_args=(get pvc)
if [[ -n "$NAMESPACE" ]]; then
  pvc_args+=(-n "$NAMESPACE")
else
  pvc_args+=(-A)
fi
pvc_args+=(-o json --request-timeout=20s)

"${KUBECTL_BASE[@]}" "${pvc_args[@]}" | jq '.' > "$OUTPUT_DIR/pvcs.json" \
  || die "failed to capture PVCs"
"${KUBECTL_BASE[@]}" get pv -o json --request-timeout=20s | jq '.' > "$OUTPUT_DIR/pvs.json" \
  || die "failed to capture PVs"
"${KUBECTL_BASE[@]}" get storageclass -o json --request-timeout=20s | jq '.' > "$OUTPUT_DIR/storageclasses.json" \
  || die "failed to capture storage classes"
"${KUBECTL_BASE[@]}" -n "$LONGHORN_NAMESPACE" get volumes.longhorn.io -o json --request-timeout=20s | jq '.' > "$OUTPUT_DIR/volumes.json" \
  || die "failed to capture volumes.longhorn.io in namespace: $LONGHORN_NAMESPACE"
"${KUBECTL_BASE[@]}" -n "$LONGHORN_NAMESPACE" get replicas.longhorn.io -o json --request-timeout=20s | jq '.' > "$OUTPUT_DIR/replicas.json" \
  || die "failed to capture replicas.longhorn.io in namespace: $LONGHORN_NAMESPACE"

if ! "${KUBECTL_BASE[@]}" get events -A -o json --request-timeout=20s | jq '.' > "$OUTPUT_DIR/events.json"; then
  printf '{"apiVersion":"v1","items":[]}' | jq '.' > "$OUTPUT_DIR/events.json"
fi

cat > "$OUTPUT_DIR/README.md" <<EOF
# Local Longhorn StorageClass Health Fixture

Captured at: $(date -u +%Y-%m-%dT%H:%M:%SZ)

This directory was generated from live cluster reads for local reproduction.

## Safety

- Treat these files as sensitive until reviewed.
- Do not commit this directory as-is.
- Minimize and sanitize names, namespaces, nodes, event messages, labels, annotations, UIDs, IPs, hostnames, domains, and topology before publication.
- The default reports/ path is ignored by git.

## Replay

From the repo root:

\`\`\`bash
tests/kubernetes/longhorn/run-longhorn-storageclass-health-fixture.sh \\
  --fixture-dir "$OUTPUT_DIR" \\
  --output json
\`\`\`
EOF

printf 'Captured fixture files in: %s\n' "$OUTPUT_DIR"
printf 'Replay with:\n'
printf '  tests/kubernetes/longhorn/run-longhorn-storageclass-health-fixture.sh --fixture-dir %q --output json\n' "$OUTPUT_DIR"
printf '\nWARNING: captured fixtures may contain sensitive environment details. Do not commit without sanitization review.\n'
