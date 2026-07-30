#!/usr/bin/env bash
set -euo pipefail

PROMETHEUS_URL="${PROMETHEUS_URL:-}"
OUTPUT="table"

usage() {
  cat <<'EOF'
Usage: prometheus-target-health-report.sh [options]

Report unhealthy Prometheus scrape targets.

Options:
  --url URL          Prometheus base URL. Defaults to PROMETHEUS_URL.
  --output FORMAT   table or json. Default: table.
  -h, --help        Show this help.

Examples:
  PROMETHEUS_URL=https://prometheus.example.com ./prometheus-target-health-report.sh
  ./prometheus-target-health-report.sh --url http://localhost:9090 --output json

Safety:
  Read-only. Uses GET /api/v1/targets.
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
targets_json="$(curl -fsS --connect-timeout 10 --max-time 30 "$PROMETHEUS_URL/api/v1/targets")" \
  || die "failed to query Prometheus targets API."

report_json="$(jq '
  if .status != "success" then error("Prometheus API status was not success") else . end
  | [.data.activeTargets[]?
      | select(.health != "up")
      | {
          scrape_pool: (.scrapePool // ""),
          scrape_url: (.scrapeUrl // ""),
          health: (.health // ""),
          last_scrape: (.lastScrape // ""),
          last_error: (.lastError // ""),
          job: (.labels.job // .discoveredLabels.__meta_kubernetes_pod_label_job // ""),
          instance: (.labels.instance // ""),
          labels: (.labels // {})
        }
    ]' <<< "$targets_json")" || die "failed to parse Prometheus targets response."

case "$OUTPUT" in
  json)
    jq '.' <<< "$report_json"
    ;;
  table)
    total_unhealthy="$(jq 'length' <<< "$report_json")"
    printf 'Prometheus target health report\n'
    printf 'Unhealthy targets: %s\n\n' "$total_unhealthy"
    if [[ "$total_unhealthy" -eq 0 ]]; then
      printf 'No unhealthy active targets reported.\n'
      exit 0
    fi
    {
      printf 'HEALTH\tJOB\tINSTANCE\tSCRAPE_POOL\tLAST_SCRAPE\tLAST_ERROR\tSCRAPE_URL\n'
      jq -r '.[] | [.health,.job,.instance,.scrape_pool,.last_scrape,.last_error,.scrape_url] | @tsv' <<< "$report_json"
    } | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
    ;;
esac
