#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR="reports/node-triage"
PREFIX="node-triage"
SINCE="6 hours ago"
RED_FLAG_LINES=400
INCLUDE_NETWORK=false
INCLUDE_RKE2=false
CREATE_ARCHIVE=true

usage() {
  cat <<'EOF'
Usage: node-triage-bundle.sh [options]

Collect a read-only Linux node triage bundle for post-incident review.

Options:
  --output-dir DIR       Parent output directory. Default: reports/node-triage
  --prefix NAME          Bundle name prefix. Default: node-triage
  --since VALUE          journalctl time range. Default: "6 hours ago"
  --red-flag-lines N     Number of red-flag lines to keep. Default: 400
  --include-network      Include IP, route, socket, and resolver snapshots.
  --include-rke2         Include local RKE2 service status and recent logs.
  --no-archive           Leave output directory unarchived.
  -h, --help             Show this help.

Examples:
  node-triage-bundle.sh
  node-triage-bundle.sh --include-network
  node-triage-bundle.sh --include-rke2 --since "12 hours ago"
  node-triage-bundle.sh --output-dir reports/node-triage --prefix worker-01
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

is_positive_integer() {
  [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -gt 0 ]]
}

safe_name() {
  local value="$1"
  value="${value//[^A-Za-z0-9._-]/_}"
  printf '%s' "$value"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --prefix) PREFIX="${2:-}"; shift 2 ;;
    --since) SINCE="${2:-}"; shift 2 ;;
    --red-flag-lines) RED_FLAG_LINES="${2:-}"; shift 2 ;;
    --include-network) INCLUDE_NETWORK=true; shift ;;
    --include-rke2) INCLUDE_RKE2=true; shift ;;
    --no-archive) CREATE_ARCHIVE=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$OUTPUT_DIR" ]] || { echo "ERROR: --output-dir cannot be empty." >&2; exit 2; }
[[ -n "$PREFIX" ]] || { echo "ERROR: --prefix cannot be empty." >&2; exit 2; }
[[ -n "$SINCE" ]] || { echo "ERROR: --since cannot be empty." >&2; exit 2; }
is_positive_integer "$RED_FLAG_LINES" || { echo "ERROR: --red-flag-lines must be a positive integer." >&2; exit 2; }

for cmd in date hostname uname df free ps tar mkdir tee; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required."
done

timestamp="$(date +%Y%m%d-%H%M%S)"
host_short="$(hostname -s 2>/dev/null || hostname)"
bundle_name="$(safe_name "${PREFIX}-${host_short}-${timestamp}")"
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

capture_shell() {
  local label="$1"
  local output_file="$2"
  local script="$3"

  log "Collecting ${label}"
  {
    printf '## %s\n' "$label"
    printf '## shell snippet\n\n'
    bash -c "$script"
  } > "${bundle_dir}/${output_file}" 2>&1 || true
}

log "Creating node triage bundle at ${bundle_dir}"

# shellcheck disable=SC2016
capture_shell "host metadata" "host.txt" '
echo "hostname: $(hostname -f 2>/dev/null || hostname)"
echo "short_hostname: $(hostname -s 2>/dev/null || hostname)"
echo "kernel: $(uname -r)"
echo "architecture: $(uname -m)"
echo "date: $(date -Is)"
echo
if command -v hostnamectl >/dev/null 2>&1; then hostnamectl; fi
echo
if command -v uptime >/dev/null 2>&1; then uptime -a 2>/dev/null || uptime; fi
'

# shellcheck disable=SC2016
capture_shell "boot history" "boot.txt" '
if command -v who >/dev/null 2>&1; then
  echo "== who -b =="
  who -b || true
  echo
fi
if command -v last >/dev/null 2>&1; then
  echo "== last -x (most recent 50 lines) =="
  last -x | head -n 50 || true
else
  echo "last command not installed."
fi
'

# shellcheck disable=SC2016
capture_shell "resource snapshot" "resources.txt" '
echo "== df -hT =="
df -hT || true
echo
echo "== df -ih =="
df -ih || true
echo
echo "== free -h =="
free -h || true
echo
echo "== ps top CPU =="
ps -eo pid,ppid,user,stat,pcpu,pmem,etime,comm --sort=-pcpu | head -n 25 || true
echo
echo "== ps top memory =="
ps -eo pid,ppid,user,stat,pcpu,pmem,etime,comm --sort=-pmem | head -n 25 || true
'

if command -v journalctl >/dev/null 2>&1; then
  capture "recent journal" "journal-recent.txt" journalctl --since "$SINCE" --no-pager
  capture "previous boot journal" "journal-previous-boot.txt" journalctl -b -1 --no-pager
else
  log "Skipping journal collection because journalctl is not installed."
  printf 'journalctl not installed.\n' > "${bundle_dir}/journal-recent.txt"
fi

if command -v dmesg >/dev/null 2>&1; then
  capture "kernel ring buffer" "kernel-ring-buffer.txt" dmesg -T
else
  log "Skipping kernel ring buffer because dmesg is not installed."
  printf 'dmesg not installed.\n' > "${bundle_dir}/kernel-ring-buffer.txt"
fi

if [[ "$INCLUDE_NETWORK" == true ]]; then
  # shellcheck disable=SC2016
  capture_shell "network snapshot" "network.txt" '
if command -v ip >/dev/null 2>&1; then
  echo "== ip address =="
  ip address || true
  echo
  echo "== ip route =="
  ip route || true
  echo
else
  echo "ip command not installed."
fi
if command -v ss >/dev/null 2>&1; then
  echo "== listening sockets =="
  ss -lntup || true
  echo
fi
echo "== /etc/resolv.conf =="
sed -n "1,120p" /etc/resolv.conf 2>/dev/null || true
if command -v resolvectl >/dev/null 2>&1; then
  echo
  echo "== resolvectl status =="
  resolvectl status || true
fi
'
fi

if [[ "$INCLUDE_RKE2" == true ]]; then
  # shellcheck disable=SC2016
  capture_shell "RKE2 service status" "rke2-services.txt" '
if command -v systemctl >/dev/null 2>&1; then
  for service in rke2-server rke2-agent; do
    echo "== ${service} =="
    systemctl status "$service" --no-pager || true
    echo
  done
else
  echo "systemctl not installed."
fi
'

  if command -v journalctl >/dev/null 2>&1; then
    log "Collecting recent RKE2 logs"
    {
      printf '## recent RKE2 logs\n\n'
      for service in rke2-server rke2-agent; do
        printf '== %s since %s ==\n' "$service" "$SINCE"
        journalctl -u "$service" --since "$SINCE" --no-pager || true
        echo
      done
    } > "${bundle_dir}/rke2-recent.txt" 2>&1 || true
  fi
fi

log "Extracting red flags"
red_flag_sources=(
  "${bundle_dir}/journal-recent.txt"
  "${bundle_dir}/journal-previous-boot.txt"
  "${bundle_dir}/kernel-ring-buffer.txt"
)
if [[ "$INCLUDE_RKE2" == true ]]; then
  red_flag_sources+=("${bundle_dir}/rke2-recent.txt")
fi

grep -iE 'oom|out of memory|killed process|kernel panic|BUG:|soft lockup|hard lockup|hung task|I/O error|buffer I/O|ext4.*error|xfs.*error|nvme|scsi|reset|segfault|failed|failure|timeout|timed out|unreachable|not ready|crash|panic' \
  "${red_flag_sources[@]}" 2>/dev/null \
  | tail -n "$RED_FLAG_LINES" > "${bundle_dir}/red-flags.txt" || true

cat > "${bundle_dir}/README.txt" <<EOF
Node triage bundle
Generated: $(date -Is)
Host: $(hostname -f 2>/dev/null || hostname)
Since: ${SINCE}
Network included: ${INCLUDE_NETWORK}
RKE2 included: ${INCLUDE_RKE2}

This bundle may contain sensitive hostnames, IP addresses, usernames, service logs, process names, and filesystem paths.
Review before sharing outside the operating environment.
EOF

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
