#!/usr/bin/env bash
set -euo pipefail

EXPECTED="none"
HOST=""
HOSTS_FILE=""
SSH_USER=""
SSH_OPTS=()
OUTPUT="table"

usage() {
  cat <<'EOF'
Usage: dns-search-drift-detector.sh [options]

Audit DNS search-domain drift locally or across SSH hosts.

Options:
  --expected VALUE      Expected search domain. Use "none" for no search domain. Default: none.
  --host HOST          Remote host to audit over SSH.
  --hosts PATH         File containing remote hosts, one per line.
  --ssh-user USER      SSH user for remote checks.
  --ssh-option OPTION  Extra SSH option. Can be repeated.
  --output FORMAT      table or csv. Default: table.
  -h, --help           Show this help.

Examples:
  dns-search-drift-detector.sh --expected none
  dns-search-drift-detector.sh --host worker-01.example.com --expected example.com
  dns-search-drift-detector.sh --hosts hosts.txt --ssh-user ops --output csv
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --expected) EXPECTED="${2:-}"; shift 2 ;;
    --host) HOST="${2:-}"; shift 2 ;;
    --hosts) HOSTS_FILE="${2:-}"; shift 2 ;;
    --ssh-user) SSH_USER="${2:-}"; shift 2 ;;
    --ssh-option) SSH_OPTS+=(-o "${2:-}"); shift 2 ;;
    --output|-o) OUTPUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$OUTPUT" in
  table|csv) ;;
  *) echo "ERROR: --output must be table or csv." >&2; exit 2 ;;
esac

if [[ -n "$HOST" && -n "$HOSTS_FILE" ]]; then
  echo "ERROR: use either --host or --hosts, not both." >&2
  exit 2
fi

if [[ -n "$HOSTS_FILE" && ! -f "$HOSTS_FILE" ]]; then
  echo "ERROR: hosts file not found: $HOSTS_FILE" >&2
  exit 2
fi

# shellcheck disable=SC2016
remote_script='set -eu
host=$(hostname -f 2>/dev/null || hostname)
resolv_search=$(awk "/^search/{\$1=\"\"; sub(/^ /,\"\"); print; exit} /^domain/{print \$2; exit}" /etc/resolv.conf 2>/dev/null || true)
[ -n "$resolv_search" ] || resolv_search="NONE"
if [ -L /etc/resolv.conf ]; then
  resolv_type="symlink:$(readlink -f /etc/resolv.conf 2>/dev/null || true)"
else
  resolv_type="file"
fi
netplan_search=$(grep -R "search:" /etc/netplan/*.yaml /etc/netplan/*.yml 2>/dev/null | sed "s/.*search:[[:space:]]*//" | paste -sd ";" - || true)
[ -n "$netplan_search" ] || netplan_search="NONE"
resolved_domains="NONE"
if command -v resolvectl >/dev/null 2>&1; then
  resolved_domains=$(resolvectl domain 2>/dev/null | sed "s/[[:space:]]\+/ /g" | paste -sd ";" - || true)
  [ -n "$resolved_domains" ] || resolved_domains="NONE"
fi
printf "%s\t%s\t%s\t%s\t%s\n" "$host" "$resolv_search" "$netplan_search" "$resolv_type" "$resolved_domains"
'

hosts=("local")
if [[ -n "$HOST" ]]; then
  hosts=("$HOST")
elif [[ -n "$HOSTS_FILE" ]]; then
  mapfile -t hosts < <(grep -Ev '^([[:space:]]*#|[[:space:]]*$)' "$HOSTS_FILE")
fi

status=0
rows=()

for target in "${hosts[@]}"; do
  if [[ "$target" == "local" ]]; then
    if ! result="$(bash -c "$remote_script")"; then
      rows+=("local	ERROR	ERROR	ERROR	ERROR	UNREACHABLE")
      status=1
      continue
    fi
  else
    ssh_target="$target"
    if [[ -n "$SSH_USER" ]]; then
      ssh_target="${SSH_USER}@${target}"
    fi
    if ! result="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "${SSH_OPTS[@]}" "$ssh_target" "$remote_script")"; then
      rows+=("$target	ERROR	ERROR	ERROR	ERROR	UNREACHABLE")
      status=1
      continue
    fi
  fi

  IFS=$'\t' read -r actual_host resolv_search netplan_search resolv_type resolved_domains <<< "$result"

  drift="OK"
  if [[ "$EXPECTED" == "none" ]]; then
    if [[ "$resolv_search" != "NONE" || "$netplan_search" != "NONE" ]]; then
      drift="DRIFT"
      status=1
    fi
  elif [[ "$resolv_search" != *"$EXPECTED"* && "$netplan_search" != *"$EXPECTED"* && "$resolved_domains" != *"$EXPECTED"* ]]; then
    drift="DRIFT"
    status=1
  fi

  rows+=("$actual_host	$resolv_search	$netplan_search	$resolv_type	$resolved_domains	$drift")
done

if [[ "$OUTPUT" == "csv" ]]; then
  echo 'host,resolv_conf_search,netplan_search,resolv_conf_type,resolved_domains,status'
  for row in "${rows[@]}"; do
    awk -F'\t' 'BEGIN{OFS=","} {for (i=1;i<=NF;i++) {gsub(/"/, "\"\"", $i); $i="\"" $i "\""} print}' <<< "$row"
  done
else
  {
    printf 'HOST\tRESOLV_CONF_SEARCH\tNETPLAN_SEARCH\tRESOLV_CONF_TYPE\tRESOLVED_DOMAINS\tSTATUS\n'
    printf '%s\n' "${rows[@]}"
  } | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
fi

exit "$status"
