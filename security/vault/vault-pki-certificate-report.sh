#!/usr/bin/env bash
set -euo pipefail

PKI_MOUNT="${PKI_MOUNT:-pki}"
OUTPUT="table"

usage() {
  cat <<'EOF'
Usage: vault-pki-certificate-report.sh [options]

Report Vault PKI role and URL configuration without issuing or revoking certificates.

Options:
  --mount PATH      PKI secrets mount. Defaults to PKI_MOUNT or pki.
  --output FORMAT   table or json. Default: table.
  -h, --help        Show this help.

Environment:
  VAULT_ADDR        Vault address used by the vault CLI.
  VAULT_TOKEN       Optional token, or use an existing vault CLI login.
  PKI_MOUNT         Optional PKI mount path.

Safety:
  Read-only. Uses vault list/read only. Does not issue, revoke, rotate, or write certificates.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

vault_json_or_empty() {
  local command="$1" path="$2"
  vault "$command" -format=json "$path" 2>/dev/null || printf '{}'
}

vault_list_json_or_empty() {
  vault list -format=json "$1" 2>/dev/null || printf '[]'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mount) PKI_MOUNT="${2:-}"; shift 2 ;;
    --output|-o) OUTPUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$PKI_MOUNT" ]] || { echo "ERROR: PKI mount cannot be empty." >&2; exit 2; }
case "$OUTPUT" in table|json) ;; *) echo "ERROR: --output must be table or json." >&2; exit 2 ;; esac

command -v vault >/dev/null 2>&1 || die "vault CLI is required."
command -v jq >/dev/null 2>&1 || die "jq is required."

PKI_MOUNT="${PKI_MOUNT%/}"

roles_json="$(vault_list_json_or_empty "$PKI_MOUNT/roles")"
urls_json="$(vault_json_or_empty read "$PKI_MOUNT/config/urls")"

role_reports=()
tmp_files=()
cleanup() {
  if [[ ${#tmp_files[@]} -gt 0 ]]; then
    rm -f "${tmp_files[@]}"
  fi
}
trap cleanup EXIT

while IFS= read -r role; do
  [[ -n "$role" ]] || continue
  role_file="$(mktemp)"
  tmp_files+=("$role_file")
  vault_json_or_empty read "$PKI_MOUNT/roles/$role" \
    | jq --arg role "$role" '{
        role: $role,
        max_ttl: (.data.max_ttl // ""),
        ttl: (.data.ttl // ""),
        allowed_domains: (.data.allowed_domains // []),
        allow_subdomains: (.data.allow_subdomains // false),
        allow_wildcard_certificates: (.data.allow_wildcard_certificates // false),
        allow_bare_domains: (.data.allow_bare_domains // false),
        allow_any_name: (.data.allow_any_name // false),
        key_type: (.data.key_type // ""),
        key_bits: (.data.key_bits // "")
      }' > "$role_file"
  role_reports+=("$role_file")
done < <(jq -r '.[]?' <<< "$roles_json")

if [[ ${#role_reports[@]} -gt 0 ]]; then
  roles_report_json="$(jq -s '.' "${role_reports[@]}")"
else
  roles_report_json='[]'
fi

report_json="$(jq -n \
  --arg mount "$PKI_MOUNT" \
  --argjson roles "$roles_report_json" \
  --argjson urls "$urls_json" '{
    mount: $mount,
    role_count: ($roles | length),
    roles_visible: ($roles | length > 0),
    urls_visible: (($urls.data // {}) != {}),
    url_config: ($urls.data // {}),
    roles: $roles
  }')"

case "$OUTPUT" in
  json)
    jq '.' <<< "$report_json"
    ;;
  table)
    printf 'Vault PKI certificate role report\n'
    jq -r '"Mount: \(.mount)", "Roles visible: \(.role_count)", "URL config visible: \(.urls_visible)", ""' <<< "$report_json"
    printf 'URL config:\n'
    jq -r '.url_config | to_entries[]? | " - " + .key + ": " + ((.value // []) | if type == "array" then join(",") else tostring end)' <<< "$report_json"
    printf '\nRoles:\n'
    {
      printf 'ROLE\tMAX_TTL\tALLOWED_DOMAINS\tWILDCARD\tBARE_DOMAIN\tANY_NAME\tKEY_TYPE\tKEY_BITS\n'
      jq -r '.roles[] | [.role,.max_ttl,(.allowed_domains | join(",")),.allow_wildcard_certificates,.allow_bare_domains,.allow_any_name,.key_type,(.key_bits | tostring)] | @tsv' <<< "$report_json"
    } | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
    ;;
esac
