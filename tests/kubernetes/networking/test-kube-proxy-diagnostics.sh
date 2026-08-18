#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT_DIR/kubernetes/networking/kube-proxy-diagnostics.sh"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

cat > "$tmp_dir/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

args=" $* "

if [[ "$*" == "config current-context" ]]; then
  printf 'lab-cluster\n'
  exit 0
fi

if [[ "$args" == *" version "* ]]; then
  printf 'clientVersion:\n  gitVersion: v1.30.0\n'
  exit 0
fi

if [[ "$args" == *" cluster-info "* ]]; then
  printf 'Kubernetes control plane is running\n'
  exit 0
fi

if [[ "$args" == *" get nodes -o wide "* ]]; then
  printf 'NAME STATUS ROLES AGE VERSION\nworker-01 Ready worker 1d v1.30.0\n'
  exit 0
fi

if [[ "$args" == *" get nodes -o json "* ]]; then
  printf '{"items":[{"metadata":{"name":"worker-01"}}]}\n'
  exit 0
fi

if [[ "$args" == *" get events "* ]]; then
  printf 'LAST SEEN TYPE REASON OBJECT MESSAGE\n1m Warning BackOff pod/kube-proxy-example Back-off restarting failed container\n'
  exit 0
fi

if [[ "$args" == *" get daemonset kube-proxy "* ]]; then
  printf 'apiVersion: apps/v1\nkind: DaemonSet\nmetadata:\n  name: kube-proxy\n'
  exit 0
fi

if [[ "$args" == *" get pods "* && "$args" == *" -o wide "* ]]; then
  printf 'NAME READY STATUS RESTARTS AGE IP NODE\nkube-proxy-example 0/1 CrashLoopBackOff 4 5m 192.0.2.10 worker-01\n'
  exit 0
fi

if [[ "$args" == *" get pods "* && "$args" == *" -o json "* ]]; then
  printf '{"items":[{"metadata":{"name":"kube-proxy-example"}}]}\n'
  exit 0
fi

if [[ "$args" == *" get pods "* && "$args" == *"jsonpath"* ]]; then
  printf 'kube-proxy-example\n'
  exit 0
fi

if [[ "$args" == *" get configmap "* ]]; then
  printf 'apiVersion: v1\nitems: []\n'
  exit 0
fi

if [[ "$args" == *" describe pod kube-proxy-example "* ]]; then
  printf 'Name: kube-proxy-example\nEvents:\n  Warning BackOff\n'
  exit 0
fi

if [[ "$args" == *" logs kube-proxy-example "* ]]; then
  printf 'E0101 kube-proxy failed to sync iptables rules\n'
  exit 0
fi

printf 'unexpected kubectl arguments: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$tmp_dir/kubectl"

output_dir="$tmp_dir/output"
bundle_path="$(PATH="$tmp_dir:$PATH" "$SCRIPT" --context lab-cluster --output-dir "$output_dir" --no-archive 2>/dev/null)"

if [[ ! -d "$bundle_path" ]]; then
  printf 'Expected bundle directory was not created: %s\n' "$bundle_path" >&2
  exit 1
fi

for expected in README.txt kube-proxy-pods-wide.txt pods/kube-proxy-example/logs-current.txt red-flags.txt; do
  if [[ ! -f "$bundle_path/$expected" ]]; then
    printf 'Missing expected bundle file: %s\n' "$expected" >&2
    exit 1
  fi
done

if ! grep -Fq 'failed to sync iptables rules' "$bundle_path/red-flags.txt"; then
  printf 'Red flags did not include expected kube-proxy log line.\n' >&2
  exit 1
fi

printf 'kube-proxy-diagnostics smoke tests passed.\n'
