#!/usr/bin/env bash
set -euo pipefail

TRANSIT_MOUNT="${TRANSIT_MOUNT:-transit}"
OUTPUT="table"

usage() {
  cat <<'EOF'
Usage: vault-transit-key-report.sh [options]

Report Vault transit key metadata without encrypting, decrypting, rotating, or exporting keys.

Options:
  --mount PATH      Transit secrets mount. Defaults to TRANSIT_MOUNT or transit.
  --output FORMAT   table or json. Default: table.
  -h, --help        Show this help.

Environment:
  VAULT_ADDR        Vault address used by the vault CLI.
  VAULT_TOKEN       Optional token, or use an existing vault CLI login.
  TRANSIT_MOUNT     Optional transit mount path.

Safety:
  Read-only. Uses vault list/read only. Does not export or use key material.
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mount) TRANSIT_MOUNT="${2:-}"; shift 2 ;;
    --output|-o) OUTPUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$TRANSIT_MOUNT" ]] || { echo "ERROR: transit mount cannot be empty." >&2; exit 2; }
case "$OUTPUT" in table|json) ;; *) echo "ERROR: --output must be table or json." >&2; exit 2 ;; esac

command -v vault >/dev/null 2>&1 || die "vault CLI is required."
command -v jq >/dev/null 2>&1 || die "jq is required."

TRANSIT_MOUNT="${TRANSIT_MOUNT%/}"
keys_json="$(vault list -format=json "$TRANSIT_MOUNT/keys" 2>/dev/null || printf '[]')"

tmp_files=()
key_files=()
cleanup() {
  if [[ ${#tmp_files[@]} -gt 0 ]]; then
    rm -f "${tmp_files[@]}"
  fi
}
trap cleanup EXIT

while IFS= read -r key; do
  [[ -n "$key" ]] || continue
  key_file="$(mktemp)"
  tmp_files+=("$key_file")
  vault_json_or_empty read "$TRANSIT_MOUNT/keys/$key" \
    | jq --arg key "$key" '{
        key: $key,
        type: (.data.type // ""),
        latest_version: (.data.latest_version // ""),
        min_decryption_version: (.data.min_decryption_version // ""),
        min_encryption_version: (.data.min_encryption_version // ""),
        deletion_allowed: (.data.deletion_allowed // false),
        exportable: (.data.exportable // false),
        allow_plaintext_backup: (.data.allow_plaintext_backup // false),
        supports_encryption: (.data.supports_encryption // false),
        supports_decryption: (.data.supports_decryption // false),
        supports_signing: (.data.supports_signing // false),
        supports_derivation: (.data.supports_derivation // false)
      }' > "$key_file"
  key_files+=("$key_file")
done < <(jq -r '.[]?' <<< "$keys_json")

keys_report_json='[]'
if [[ ${#key_files[@]} -gt 0 ]]; then keys_report_json="$(jq -s '.' "${key_files[@]}")"; fi

report_json="$(jq -n --arg mount "$TRANSIT_MOUNT" --argjson keys "$keys_report_json" '{mount: $mount, key_count: ($keys | length), risky_settings: ($keys | map(select(.deletion_allowed == true or .exportable == true or .allow_plaintext_backup == true)) | length), keys: $keys}')"

case "$OUTPUT" in
  json)
    jq '.' <<< "$report_json"
    ;;
  table)
    printf 'Vault transit key report\n'
    jq -r '"Mount: \(.mount)", "Keys visible: \(.key_count)", "Keys with deletion/export/plaintext-backup enabled: \(.risky_settings)", ""' <<< "$report_json"
    {
      printf 'KEY\tTYPE\tLATEST\tMIN_DECRYPT\tMIN_ENCRYPT\tDELETE_ALLOWED\tEXPORTABLE\tPLAINTEXT_BACKUP\tENC\tDEC\tSIGN\n'
      jq -r '.keys[] | [.key,.type,(.latest_version | tostring),(.min_decryption_version | tostring),(.min_encryption_version | tostring),.deletion_allowed,.exportable,.allow_plaintext_backup,.supports_encryption,.supports_decryption,.supports_signing] | @tsv' <<< "$report_json"
    } | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
    ;;
esac
