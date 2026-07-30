#!/usr/bin/env bash
set -euo pipefail

ALERTMANAGER_URL="${ALERTMANAGER_URL:-}"
OUTPUT="table"

usage() {
  cat <<'EOF'
Usage: alertmanager-silence-report.sh [options]

Summarize active and pending Alertmanager silences.

Options:
  --url URL          Alertmanager base URL. Defaults to ALERTMANAGER_URL.
  --output FORMAT   table or json. Default: table.
  -h, --help        Show this help.

Examples:
  ALERTMANAGER_URL=https://alertmanager.example.com ./alertmanager-silence-report.sh
  ./alertmanager-silence-report.sh --url http://localhost:9093 --output json

Safety:
  Read-only. Uses GET /api/v2/silences. It does not create or expire silences.
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
silences_json="$(curl -fsS --connect-timeout 10 --max-time 30 "$ALERTMANAGER_URL/api/v2/silences")" \
  || die "failed to query Alertmanager silences API."

report_json="$(jq '[.[]? | select(.status.state == "active" or .status.state == "pending") | {
  id: (.id // ""),
  state: (.status.state // ""),
  created_by: (.createdBy // ""),
  starts_at: (.startsAt // ""),
  ends_at: (.endsAt // ""),
  matcher_count: (.matchers | length),
  comment_present: ((.comment // "") != ""),
  matchers: [.matchers[]? | .name + .operator + .value]
}]' <<< "$silences_json")" || die "failed to parse Alertmanager silences response."

case "$OUTPUT" in
  json)
    jq '.' <<< "$report_json"
    ;;
  table)
    printf 'Alertmanager silence report\n'
    printf 'Active or pending silences: %s\n\n' "$(jq 'length' <<< "$report_json")"
    {
      printf 'STATE\tSTARTS_AT\tENDS_AT\tCREATED_BY\tMATCHERS\tCOMMENT\tID\n'
      jq -r '.[] | [.state,.starts_at,.ends_at,.created_by,.matcher_count,.comment_present,.id] | @tsv' <<< "$report_json"
    } | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
    ;;
esac
