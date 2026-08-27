#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT_DIR/kubernetes/longhorn/longhorn-storageclass-health-report.sh"
FIXTURE_DIR=""

usage() {
  cat <<'EOF'
Usage: run-longhorn-storageclass-health-fixture.sh --fixture-dir DIR [script options]

Run longhorn-storageclass-health-report.sh with a temporary fake kubectl that
serves JSON from DIR.

Required fixture files:
  pvcs.json
  pvs.json
  storageclasses.json
  volumes.json
  replicas.json
  events.json

Examples:
  tests/kubernetes/longhorn/run-longhorn-storageclass-health-fixture.sh \
    --fixture-dir tests/fixtures/kubernetes/longhorn-storageclass-health \
    --output json

Safety:
  Does not contact a Kubernetes cluster. The fake kubectl only reads fixture
  JSON files and exists in a temporary directory for this process.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fixture-dir)
      FIXTURE_DIR="${2:-}"
      shift 2
      break
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: --fixture-dir must be provided before script options." >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$FIXTURE_DIR" ]] || { echo "ERROR: --fixture-dir is required." >&2; exit 2; }
[[ -d "$FIXTURE_DIR" ]] || { echo "ERROR: fixture directory not found: $FIXTURE_DIR" >&2; exit 2; }

for fixture in pvcs.json pvs.json storageclasses.json volumes.json replicas.json events.json; do
  [[ -f "$FIXTURE_DIR/$fixture" ]] || { echo "ERROR: missing fixture file: $FIXTURE_DIR/$fixture" >&2; exit 2; }
done

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

cat > "$tmp_dir/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

fixture_dir="${LONGHORN_STORAGECLASS_HEALTH_FIXTURE_DIR:?fixture dir not set}"
args=" $* "

if [[ "$args" == *" get pvc "* ]]; then
  cp "$fixture_dir/pvcs.json" /dev/stdout
  exit 0
fi

if [[ "$args" == *" get pv "* ]]; then
  cp "$fixture_dir/pvs.json" /dev/stdout
  exit 0
fi

if [[ "$args" == *" get storageclass "* ]]; then
  cp "$fixture_dir/storageclasses.json" /dev/stdout
  exit 0
fi

if [[ "$args" == *" get volumes.longhorn.io "* ]]; then
  cp "$fixture_dir/volumes.json" /dev/stdout
  exit 0
fi

if [[ "$args" == *" get replicas.longhorn.io "* ]]; then
  cp "$fixture_dir/replicas.json" /dev/stdout
  exit 0
fi

if [[ "$args" == *" get events "* ]]; then
  cp "$fixture_dir/events.json" /dev/stdout
  exit 0
fi

printf 'unexpected kubectl arguments: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$tmp_dir/kubectl"

PATH="$tmp_dir:$PATH" LONGHORN_STORAGECLASS_HEALTH_FIXTURE_DIR="$FIXTURE_DIR" "$SCRIPT" "$@"
