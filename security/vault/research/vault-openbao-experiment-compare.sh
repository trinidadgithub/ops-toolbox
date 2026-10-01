#!/usr/bin/env bash
set -euo pipefail

BASELINE=""
MITIGATED=""
PATCHED=""
OUTPUT="table"

usage() {
  cat <<'EOF'
Usage: vault-openbao-experiment-compare.sh --baseline DIR [options]

Compare phase evidence for a Vault/OpenBao control-validation experiment.
The comparator intentionally refuses to report PASS when the affected baseline
did not reproduce the prerequisite.

Options:
  --baseline DIR    Evidence phase directory for affected baseline. Required.
  --mitigated DIR   Evidence phase directory for mitigated same-version phase.
  --patched DIR     Evidence phase directory for patched-release phase.
  --output FORMAT   table or json. Default: table.
  -h, --help        Show this help.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

phase_result_file() {
  local dir="$1"
  [[ -f "$dir/result.json" ]] || die "missing result.json in $dir"
  printf '%s/result.json\n' "$dir"
}

phase_attempt_file() {
  local dir="$1" file
  file="$(jq -r '.observations.attempts_file // empty' "$dir/result.json")"
  [[ -n "$file" && -f "$file" ]] || die "missing attempts evidence for $dir"
  printf '%s\n' "$file"
}

phase_summary_json() {
  local name="$1" dir="$2" result_file attempts_file metadata_file protected_role
  result_file="$(phase_result_file "$dir")"
  metadata_file="$dir/metadata.json"
  [[ -f "$metadata_file" ]] || die "missing metadata.json in $dir"
  protected_role="$(jq -r '.controlled_variables.protected_role // "admin"' "$metadata_file")"
  attempts_file="$(phase_attempt_file "$dir")"
  jq -n \
    --arg phase_name "$name" \
    --arg protected_role "$protected_role" \
    --argjson result "$(jq '.' "$result_file")" \
    --argjson attempts "$(jq '.' "$attempts_file")" '{
      phase_name: $phase_name,
      protected_role: $protected_role,
      result: $result.result,
      reason: $result.reason,
      canonical_denied: ([$attempts[] | select(.variant == $protected_role and .observed == "DENIED")] | length > 0),
      noncanonical_allowed_count: ([$attempts[] | select(.variant != $protected_role and .observed == "ALLOWED")] | length),
      attempts: $attempts
    }'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline) BASELINE="${2:-}"; shift 2 ;;
    --mitigated) MITIGATED="${2:-}"; shift 2 ;;
    --patched) PATCHED="${2:-}"; shift 2 ;;
    --output|-o) OUTPUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$BASELINE" ]] || { usage >&2; exit 2; }
case "$OUTPUT" in table|json) ;; *) die "--output must be table or json." ;; esac
command -v jq >/dev/null 2>&1 || die "jq is required."

baseline_json="$(phase_summary_json baseline "$BASELINE")"
phase_files=()
tmp_files=()
cleanup() {
  if [[ ${#tmp_files[@]} -gt 0 ]]; then rm -f "${tmp_files[@]}"; fi
}
trap cleanup EXIT

baseline_file="$(mktemp)"
tmp_files+=("$baseline_file")
printf '%s\n' "$baseline_json" > "$baseline_file"
phase_files+=("$baseline_file")

if [[ -n "$MITIGATED" ]]; then
  file="$(mktemp)"
  tmp_files+=("$file")
  phase_summary_json mitigated "$MITIGATED" > "$file"
  phase_files+=("$file")
fi

if [[ -n "$PATCHED" ]]; then
  file="$(mktemp)"
  tmp_files+=("$file")
  phase_summary_json patched "$PATCHED" > "$file"
  phase_files+=("$file")
fi

phases_json="$(jq -s '.' "${phase_files[@]}")"
baseline_reproduced="$(jq -r '.[0].canonical_denied and (.[0].noncanonical_allowed_count > 0)' <<< "$phases_json")"
controls_tested="$(jq '[.[] | select(.phase_name != "baseline")] | length' <<< "$phases_json")"
controls_all_denied="$(jq 'if ([.[] | select(.phase_name != "baseline")] | length) == 0 then false else all(.[] | select(.phase_name != "baseline"); .canonical_denied and (.noncanonical_allowed_count == 0)) end' <<< "$phases_json")"
controls_any_allowed="$(jq 'any(.[] | select(.phase_name != "baseline"); .noncanonical_allowed_count > 0)' <<< "$phases_json")"

overall="UNKNOWN"
reason="affected baseline did not reproduce the prerequisite, so mitigation effectiveness cannot be inferred"
if [[ "$baseline_reproduced" == "true" && "$controls_tested" -eq 0 ]]; then
  overall="UNKNOWN"
  reason="affected baseline reproduced the prerequisite, but no mitigated or patched phase was provided"
elif [[ "$baseline_reproduced" == "true" && "$controls_any_allowed" == "true" ]]; then
  overall="FAIL"
  reason="at least one mitigated or patched phase still allowed a tested non-canonical variant"
elif [[ "$baseline_reproduced" == "true" && "$controls_all_denied" == "true" ]]; then
  overall="PASS"
  reason="affected baseline reproduced the prerequisite and all provided control phases denied tested variants"
fi

report_json="$(jq -n \
  --arg compared_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg type "CONTROL_VALIDATION" \
  --arg result "$overall" \
  --arg reason "$reason" \
  --argjson baseline_reproduced "$baseline_reproduced" \
  --argjson phases "$phases_json" '{
    compared_at: $compared_at,
    type: $type,
    result: $result,
    reason: $reason,
    baseline_reproduced: $baseline_reproduced,
    phases: $phases,
    limitations: [
      "Only explicitly tested variants are evaluated.",
      "PASS does not establish that all canonicalization variants are fixed.",
      "PASS does not establish that Vault/OpenBao is secure or that RCE is impossible."
    ]
  }')"

case "$OUTPUT" in
  json)
    jq '.' <<< "$report_json"
    ;;
  table)
    printf 'Vault/OpenBao experiment comparison\n'
    jq -r '"Type: \(.type)", "Result: \(.result)", "Reason: \(.reason)", "Baseline reproduced: \(.baseline_reproduced)", ""' <<< "$report_json"
    {
      printf 'PHASE\tCANONICAL_DENIED\tNONCANONICAL_ALLOWED\tRESULT\n'
      jq -r '.phases[] | [.phase_name,.canonical_denied,.noncanonical_allowed_count,.result] | @tsv' <<< "$report_json"
    } | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
    ;;
esac
