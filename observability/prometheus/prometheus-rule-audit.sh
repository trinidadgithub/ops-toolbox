#!/usr/bin/env bash
set -euo pipefail

PROMETHEUS_URL="${PROMETHEUS_URL:-}"
OUTPUT="table"

usage() {
  cat <<'EOF'
Usage: prometheus-rule-audit.sh [options]

Summarize Prometheus alerting rules and common operational context gaps.

Options:
  --url URL          Prometheus base URL. Defaults to PROMETHEUS_URL.
  --output FORMAT   table or json. Default: table.
  -h, --help        Show this help.

Examples:
  PROMETHEUS_URL=https://prometheus.example.com ./prometheus-rule-audit.sh
  ./prometheus-rule-audit.sh --url http://localhost:9090 --output json

Safety:
  Read-only. Uses GET /api/v1/rules.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) PROMETHEUS_URL="${2:-}"; shift 2 ;;
    --output|-o) OUTPUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$PROMETHEUS_URL" ]] || { echo "ERROR: provide --url or PROMETHEUS_URL." >&2; exit 2; }
case "$OUTPUT" in table|json) ;; *) echo "ERROR: --output must be table or json." >&2; exit 2 ;; esac

command -v curl >/dev/null 2>&1 || die "curl is required."
command -v jq >/dev/null 2>&1 || die "jq is required."

PROMETHEUS_URL="${PROMETHEUS_URL%/}"
rules_json="$(curl -fsS --connect-timeout 10 --max-time 30 "$PROMETHEUS_URL/api/v1/rules")" \
  || die "failed to query Prometheus rules API."

report_json="$(jq '
  if .status != "success" then error("Prometheus API status was not success") else . end
  | [.data.groups[]? as $group
      | $group.rules[]?
      | select(.type == "alerting")
      | {
          group: ($group.name // ""),
          name: (.name // ""),
          state: (.state // "unknown"),
          severity: (.labels.severity // ""),
          team: (.labels.team // .labels.owner // ""),
          has_runbook: ((.annotations.runbook_url // .annotations.runbook // "") != ""),
          has_dashboard: ((.annotations.dashboard_url // .annotations.dashboard // "") != ""),
          possible_slo_burn_rate: ((.name // "" | test("slo|burn|error.?budget|multi.?window"; "i")) or ((.labels.slo // "") != "")),
          labels: (.labels // {}),
          annotations: (.annotations // {})
        }
    ] as $rules
  | {
      total_alerting_rules: ($rules | length),
      inactive: ($rules | map(select(.state == "inactive")) | length),
      pending: ($rules | map(select(.state == "pending")) | length),
      firing: ($rules | map(select(.state == "firing")) | length),
      missing_severity: ($rules | map(select(.severity == "")) | length),
      missing_runbook: ($rules | map(select(.has_runbook | not)) | length),
      missing_dashboard: ($rules | map(select(.has_dashboard | not)) | length),
      possible_slo_burn_rate_rules: ($rules | map(select(.possible_slo_burn_rate)) | length),
      rules: $rules
    }' <<< "$rules_json")" || die "failed to parse Prometheus rules response."

case "$OUTPUT" in
  json)
    jq '.' <<< "$report_json"
    ;;
  table)
    printf 'Prometheus rule audit\n'
    jq -r '"Alerting rules: \(.total_alerting_rules)", "Inactive: \(.inactive)", "Pending: \(.pending)", "Firing: \(.firing)", "Missing severity: \(.missing_severity)", "Missing runbook annotation: \(.missing_runbook)", "Missing dashboard annotation: \(.missing_dashboard)", "Possible SLO/burn-rate rules: \(.possible_slo_burn_rate_rules)", ""' <<< "$report_json"
    printf 'Rules needing context review:\n'
    {
      printf 'STATE\tGROUP\tALERT\tSEVERITY\tTEAM\tRUNBOOK\tDASHBOARD\tSLO_HINT\n'
      jq -r '.rules[] | select(.severity == "" or (.has_runbook | not) or (.has_dashboard | not) or .possible_slo_burn_rate) | [.state,.group,.name,(if .severity == "" then "MISSING" else .severity end),(if .team == "" then "-" else .team end),.has_runbook,.has_dashboard,.possible_slo_burn_rate] | @tsv' <<< "$report_json"
    } | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
    ;;
esac
