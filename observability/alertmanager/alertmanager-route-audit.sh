#!/usr/bin/env bash
set -euo pipefail

ALERTMANAGER_URL="${ALERTMANAGER_URL:-}"
OUTPUT="table"

usage() {
  cat <<'EOF'
Usage: alertmanager-route-audit.sh [options]

Summarize Alertmanager routing configuration when exposed by the status API.

Options:
  --url URL          Alertmanager base URL. Defaults to ALERTMANAGER_URL.
  --output FORMAT   table or json. Default: table.
  -h, --help        Show this help.

Examples:
  ALERTMANAGER_URL=https://alertmanager.example.com ./alertmanager-route-audit.sh
  ./alertmanager-route-audit.sh --url http://localhost:9093 --output json

Safety:
  Read-only. Uses GET /api/v2/status and GET /api/v2/alerts/groups.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) ALERTMANAGER_URL="${2:-}"; shift 2 ;;
    --output|-o) OUTPUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$ALERTMANAGER_URL" ]] || { echo "ERROR: provide --url or ALERTMANAGER_URL." >&2; exit 2; }
case "$OUTPUT" in table|json) ;; *) echo "ERROR: --output must be table or json." >&2; exit 2 ;; esac

command -v curl >/dev/null 2>&1 || die "curl is required."
command -v jq >/dev/null 2>&1 || die "jq is required."

ALERTMANAGER_URL="${ALERTMANAGER_URL%/}"
status_json="$(curl -fsS --connect-timeout 10 --max-time 30 "$ALERTMANAGER_URL/api/v2/status")" \
  || die "failed to query Alertmanager status API."
groups_json="$(curl -fsS --connect-timeout 10 --max-time 30 "$ALERTMANAGER_URL/api/v2/alerts/groups" 2>/dev/null || printf '[]')"

report_json="$(jq -n --argjson status "$status_json" --argjson groups "$groups_json" '
  ($status.config.original // "") as $config
  | ($config | split("\n")) as $lines
  | ($lines | map(capture("^[[:space:]]*receiver:[[:space:]]*(?<name>[^#]+)")? | .name | gsub("[\"'"'"']"; "") | gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(. != ""))) as $routeReceivers
  | ($lines | map(capture("^[[:space:]]*-?[[:space:]]*name:[[:space:]]*(?<name>[^#]+)")? | .name | gsub("[\"'"'"']"; "") | gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(. != ""))) as $namedReceivers
  | ($routeReceivers + $namedReceivers) as $receivers
  | ($receivers | group_by(.) | map(select(length > 1) | {receiver: .[0], count: length})) as $duplicates
  | ($groups | map(.labels // {}) | map(select((.team // .owner // "") == "")) | length) as $alertGroupsMissingTeam
  | ($groups | map(.labels // {}) | map(select((.severity // "") == "")) | length) as $alertGroupsMissingSeverity
  | {
      version: ($status.versionInfo.version // "unknown"),
      config_available: ($config != ""),
      route_receiver_references: ($routeReceivers | unique),
      configured_receiver_names: ($namedReceivers | unique),
      repeated_receiver_names: $duplicates,
      active_alert_groups: ($groups | length),
      alert_groups_missing_team_or_owner: $alertGroupsMissingTeam,
      alert_groups_missing_severity: $alertGroupsMissingSeverity
    }')" || die "failed to parse Alertmanager response."

case "$OUTPUT" in
  json)
    jq '.' <<< "$report_json"
    ;;
  table)
    printf 'Alertmanager route audit\n'
    jq -r '"Version: \(.version)", "Config available from status API: \(.config_available)", "Route receiver references: \(.route_receiver_references | length)", "Configured receiver names: \(.configured_receiver_names | length)", "Repeated receiver names: \(.repeated_receiver_names | length)", "Active alert groups: \(.active_alert_groups)", "Alert groups missing team/owner label: \(.alert_groups_missing_team_or_owner)", "Alert groups missing severity label: \(.alert_groups_missing_severity)", ""' <<< "$report_json"
    printf 'Receiver references:\n'
    jq -r '.route_receiver_references[]? | " - " + .' <<< "$report_json"
    printf '\nRepeated receiver names:\n'
    jq -r '.repeated_receiver_names[]? | " - " + .receiver + " (" + (.count | tostring) + ")"' <<< "$report_json"
    ;;
esac
