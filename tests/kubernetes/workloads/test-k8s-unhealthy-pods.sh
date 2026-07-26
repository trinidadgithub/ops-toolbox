#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT_DIR/kubernetes/workloads/k8s-unhealthy-pods.sh"
FIXTURE="$ROOT_DIR/tests/fixtures/kubernetes/workloads/pods.json"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

cat > "$tmp_dir/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

fixture="${K8S_UNHEALTHY_PODS_FIXTURE:?fixture not set}"

if [[ "$*" == "config current-context" ]]; then
  printf 'lab-cluster\n'
  exit 0
fi

if [[ "$*" == "config get-contexts -o name" ]]; then
  printf 'lab-cluster\n'
  exit 0
fi

for arg in "$@"; do
  if [[ "$arg" == "pods" ]]; then
    cp "$fixture" /dev/stdout
    exit 0
  fi
done

printf 'unexpected kubectl arguments: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$tmp_dir/kubectl"

run_script() {
  PATH="$tmp_dir:$PATH" K8S_UNHEALTHY_PODS_FIXTURE="$FIXTURE" "$SCRIPT" "$@"
}

assert_names() {
  local actual="$1"
  local expected="$2"

  if [[ "$actual" != "$expected" ]]; then
    printf 'Expected names:\n%s\n\nActual names:\n%s\n' "$expected" "$actual" >&2
    exit 1
  fi
}

default_names="$(run_script --output json | jq -r '.[].pod' | sort)"
assert_names "$default_names" $'api-pending-6b7c9\nimport-failed-28499100\nworker-crashloop-55c8d'

include_succeeded_names="$(run_script --output json --include-succeeded | jq -r '.[].pod' | sort)"
assert_names "$include_succeeded_names" $'api-pending-6b7c9\nbackup-complete-28499100\nimport-failed-28499100\nworker-crashloop-55c8d'

csv_output="$(run_script --output csv)"
if ! grep -Fq '"lab-cluster","example-app","worker-crashloop-55c8d","worker-02","Running","0/1","CrashLoopBackOff"' <<< "$csv_output"; then
  printf 'CSV output did not include expected CrashLoopBackOff row.\n%s\n' "$csv_output" >&2
  exit 1
fi

if grep -Fq 'api-healthy-7d9f8' <<< "$csv_output"; then
  printf 'CSV output included healthy pod unexpectedly.\n%s\n' "$csv_output" >&2
  exit 1
fi

table_output="$(run_script)"
if ! grep -Fq 'worker-crashloop-55c8d' <<< "$table_output"; then
  printf 'Table output did not include expected unhealthy pod.\n%s\n' "$table_output" >&2
  exit 1
fi

if grep -Fq 'backup-complete-28499100' <<< "$table_output"; then
  printf 'Table output included succeeded pod unexpectedly.\n%s\n' "$table_output" >&2
  exit 1
fi

printf 'k8s-unhealthy-pods fixture tests passed.\n'
