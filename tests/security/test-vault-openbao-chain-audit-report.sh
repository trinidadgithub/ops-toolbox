#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_file="$(mktemp)"
cleanup() {
  rm -f "$tmp_file"
}
trap cleanup EXIT

"$ROOT_DIR/security/vault/vault-openbao-chain-synthetic-audit.sh" > "$tmp_file"

json_output="$($ROOT_DIR/security/vault/vault-openbao-chain-audit-report.sh --input "$tmp_file" --output json)"

jq -e '.finding_count == 4' >/dev/null <<< "$json_output"
jq -e '.chain_indicators.acme_activity == true' >/dev/null <<< "$json_output"
jq -e '.chain_indicators.cert_auth_role_change == true' >/dev/null <<< "$json_output"
jq -e '.chain_indicators.acl_policy_change == true' >/dev/null <<< "$json_output"
jq -e '.chain_indicators.snapshot_force_restore == true' >/dev/null <<< "$json_output"

table_output="$($ROOT_DIR/security/vault/vault-openbao-chain-audit-report.sh --input "$tmp_file")"
grep -q 'SNAPSHOT_FORCE_RESTORE' <<< "$table_output"
grep -q 'CERT_AUTH_ROLE_CHANGE' <<< "$table_output"

printf 'test-vault-openbao-chain-audit-report passed.\n'
