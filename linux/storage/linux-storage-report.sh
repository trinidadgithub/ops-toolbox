#!/usr/bin/env bash
set -euo pipefail

OUTPUT=""
SCAN_PATH="/"
TOP_COUNT=10
TOP_DEPTH=1
INCLUDE_RKE2=false

usage() {
  cat <<'EOF'
Usage: linux-storage-report.sh [options]

Generate a read-only Linux storage and filesystem report.

Options:
  --output PATH       Write report to PATH. Defaults to stdout.
  --path PATH         Path for top-consumer scan. Default: /.
  --top-count N       Number of top disk consumers. Default: 10.
  --top-depth N       Depth for du scan. Default: 1.
  --include-rke2      Include common RKE2 storage paths when present.
  -h, --help          Show this help.

Examples:
  linux-storage-report.sh
  linux-storage-report.sh --output reports/storage-worker-01.txt
  linux-storage-report.sh --include-rke2 --path /var/lib/rancher/rke2
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
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --path) SCAN_PATH="${2:-}"; shift 2 ;;
    --top-count) TOP_COUNT="${2:-}"; shift 2 ;;
    --top-depth) TOP_DEPTH="${2:-}"; shift 2 ;;
    --include-rke2) INCLUDE_RKE2=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -d "$SCAN_PATH" ]] || die "scan path is not a directory: $SCAN_PATH"
is_positive_integer "$TOP_COUNT" || { echo "ERROR: --top-count must be a positive integer." >&2; exit 2; }
[[ "$TOP_DEPTH" =~ ^[0-9]+$ ]] || { echo "ERROR: --top-depth must be zero or a positive integer." >&2; exit 2; }

for cmd in date hostname uname df lsblk du sort; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required."
done

if [[ -n "$OUTPUT" ]]; then
  mkdir -p "$(dirname "$OUTPUT")"
  exec > "$OUTPUT"
fi

section() {
  printf '\n## %s\n\n' "$1"
}

run_if_available() {
  local cmd="$1"
  shift
  if command -v "$cmd" >/dev/null 2>&1; then
    "$cmd" "$@" 2>&1 || true
  else
    printf '%s not installed.\n' "$cmd"
  fi
}

echo "Linux Storage Report"
echo "Generated: $(date -Is)"
echo "Hostname:  $(hostname -f 2>/dev/null || hostname)"
echo "Kernel:    $(uname -r)"
echo "User:      $(id -un 2>/dev/null || true)"

section "Filesystem Usage"
df -hT

section "Inode Usage"
df -ih

section "Block Devices"
lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL 2>/dev/null || lsblk

section "Mounts"
findmnt -rno TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null || mount

section "LVM Summary"
echo "Physical volumes:"
run_if_available pvs
echo
echo "Volume groups:"
run_if_available vgs
echo
echo "Logical volumes:"
run_if_available lvs

section "Top Disk Consumers"
echo "Path: $SCAN_PATH"
du -x -h --max-depth="$TOP_DEPTH" "$SCAN_PATH" 2>/dev/null | sort -hr | head -n "$TOP_COUNT" || true

section "Large Files"
find "$SCAN_PATH" -xdev -type f -size +100M -printf '%s\t%p\n' 2>/dev/null \
  | sort -nr \
  | head -n "$TOP_COUNT" \
  | awk -F'\t' '{cmd="numfmt --to=iec " $1; cmd | getline size; close(cmd); print size "\t" $2}' || true

if [[ "$INCLUDE_RKE2" == true ]]; then
  section "RKE2 Paths"
  for path in /var/lib/rancher/rke2 /var/lib/rancher/rke2/agent/containerd /var/lib/kubelet; do
    if [[ -d "$path" ]]; then
      printf '%s\n' "$path"
      du -h --max-depth=1 "$path" 2>/dev/null | sort -hr | head -n "$TOP_COUNT" || true
      echo
    else
      printf '%s not present.\n\n' "$path"
    fi
  done
fi

section "Summary"
df -h / 2>/dev/null | awk 'NR==2 {print "Root filesystem: " $3 " used of " $2 " (" $5 ")"}' || true

if [[ -n "$OUTPUT" ]]; then
  printf 'Report written to %s\n' "$OUTPUT" >&2
fi
