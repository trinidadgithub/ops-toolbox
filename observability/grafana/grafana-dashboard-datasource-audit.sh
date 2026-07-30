#!/usr/bin/env bash
set -euo pipefail

GRAFANA_URL="${GRAFANA_URL:-}"
GRAFANA_TOKEN="${GRAFANA_TOKEN:-}"
OUTPUT="table"
LIMIT=200

usage() {
  cat <<'EOF'
Usage: grafana-dashboard-datasource-audit.sh [options]

Audit Grafana dashboards and datasource references without exporting dashboard queries.

Options:
  --url URL          Grafana base URL. Defaults to GRAFANA_URL.
  --token TOKEN      Grafana API token. Defaults to GRAFANA_TOKEN.
  --limit N          Dashboard search limit. Default: 200.
  --output FORMAT   table or json. Default: table.
  -h, --help        Show this help.

Examples:
  GRAFANA_URL=https://grafana.example.com GRAFANA_TOKEN=REDACTED ./grafana-dashboard-datasource-audit.sh
  ./grafana-dashboard-datasource-audit.sh --url http://localhost:3000 --token "$GRAFANA_TOKEN" --output json

Safety:
  Read-only. Uses Grafana GET APIs. Does not export dashboard queries or modify dashboards.
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
    --url) GRAFANA_URL="${2:-}"; shift 2 ;;
    --token) GRAFANA_TOKEN="${2:-}"; shift 2 ;;
    --limit) LIMIT="${2:-}"; shift 2 ;;
    --output|-o) OUTPUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$GRAFANA_URL" ]] || { echo "ERROR: provide --url or GRAFANA_URL." >&2; exit 2; }
[[ -n "$GRAFANA_TOKEN" ]] || { echo "ERROR: provide --token or GRAFANA_TOKEN." >&2; exit 2; }
is_positive_integer "$LIMIT" || { echo "ERROR: --limit must be a positive integer." >&2; exit 2; }
case "$OUTPUT" in table|json) ;; *) echo "ERROR: --output must be table or json." >&2; exit 2 ;; esac

command -v curl >/dev/null 2>&1 || die "curl is required."
command -v jq >/dev/null 2>&1 || die "jq is required."

GRAFANA_URL="${GRAFANA_URL%/}"

grafana_get() {
  local path="$1"
  curl -fsS --connect-timeout 10 --max-time 30 \
    -H "Authorization: Bearer $GRAFANA_TOKEN" \
    -H "Accept: application/json" \
    "$GRAFANA_URL$path"
}

datasources_json="$(grafana_get "/api/datasources")" || die "failed to query Grafana datasources API."
search_json="$(grafana_get "/api/search?type=dash-db&limit=$LIMIT")" || die "failed to query Grafana dashboard search API."

tmp_files=()
cleanup() {
  if [[ ${#tmp_files[@]} -gt 0 ]]; then
    rm -f "${tmp_files[@]}"
  fi
}
trap cleanup EXIT

dashboard_reports=()
while IFS=$'\t' read -r uid title folder; do
  [[ -n "$uid" ]] || continue
  dashboard_file="$(mktemp)"
  report_file="$(mktemp)"
  tmp_files+=("$dashboard_file" "$report_file")
  if ! grafana_get "/api/dashboards/uid/$uid" > "$dashboard_file"; then
    jq -n --arg uid "$uid" --arg title "$title" --arg folder "$folder" '{uid: $uid, title: $title, folder: $folder, fetch_error: true}' > "$report_file"
  else
    jq --arg fallback_uid "$uid" --arg fallback_title "$title" --arg fallback_folder "$folder" '
      .dashboard as $dash
      | [($dash.panels // [])[]? | .. | objects | .datasource? // empty] as $refs
      | ($refs | map(if type == "object" then (.uid // .type // "object") else tostring end) | unique) as $datasourceRefs
      | {
          uid: (.meta.uid // $fallback_uid),
          title: ($dash.title // $fallback_title),
          folder: (.meta.folderTitle // $fallback_folder // "General"),
          fetch_error: false,
          tags: ($dash.tags // []),
          datasource_references: $datasourceRefs,
          datasource_reference_count: ($datasourceRefs | length),
          missing_datasource_references: (($datasourceRefs | length) == 0),
          likely_slo_or_incident_response: ((($dash.title // "") | test("slo|burn|error.?budget|incident|on.?call|escalation"; "i")) or (($dash.tags // []) | map(test("slo|burn|incident|on.?call|escalation"; "i")) | any))
        }' "$dashboard_file" > "$report_file"
  fi
  dashboard_reports+=("$report_file")
done < <(jq -r '.[]? | [.uid, .title, (.folderTitle // "General")] | @tsv' <<< "$search_json")

if [[ ${#dashboard_reports[@]} -gt 0 ]]; then
  dashboards_json="$(jq -s '.' "${dashboard_reports[@]}")"
else
  dashboards_json='[]'
fi

report_json="$(jq -n --argjson datasources "$datasources_json" --argjson dashboards "$dashboards_json" '{
  datasource_count: ($datasources | length),
  datasources: ($datasources | map({name: .name, type: .type, uid: (.uid // ""), access: (.access // "")})),
  dashboard_count: ($dashboards | length),
  dashboards_missing_datasource_references: ($dashboards | map(select(.missing_datasource_references == true)) | length),
  likely_slo_or_incident_dashboards: ($dashboards | map(select(.likely_slo_or_incident_response == true)) | length),
  dashboards: $dashboards
}')"

case "$OUTPUT" in
  json)
    jq '.' <<< "$report_json"
    ;;
  table)
    printf 'Grafana dashboard datasource audit\n'
    jq -r '"Datasources: \(.datasource_count)", "Dashboards scanned: \(.dashboard_count)", "Dashboards missing datasource references: \(.dashboards_missing_datasource_references)", "Likely SLO/incident dashboards: \(.likely_slo_or_incident_dashboards)", ""' <<< "$report_json"
    printf 'Dashboards:\n'
    {
      printf 'TITLE\tFOLDER\tDATASOURCE_REFS\tMISSING_REFS\tSLO_OR_INCIDENT_HINT\n'
      jq -r '.dashboards[] | [.title,.folder,(.datasource_references | join(",")),.missing_datasource_references,.likely_slo_or_incident_response] | @tsv' <<< "$report_json"
    } | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
    ;;
esac
