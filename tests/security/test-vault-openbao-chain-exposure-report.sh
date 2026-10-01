#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

fake_cli="$tmp_dir/fake-bao"
cat > "$fake_cli" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  version)
    printf 'OpenBao v2.6.2\n'
    ;;
  'status -format=json')
    printf '{"version":"2.6.2","sealed":false}\n'
    ;;
  'auth list -format=json')
    printf '{"cert/":{"type":"cert"}}\n'
    ;;
  'secrets list -format=json')
    printf '{"pki/":{"type":"pki"}}\n'
    ;;
  'policy list -format=json')
    printf '["admin"]\n'
    ;;
  'read pki/config/acme -format=json')
    printf '{"data":{"enabled":true,"eab_policy":"not-required"}}\n'
    ;;
  'list pki/roles -format=json')
    printf '["spiffe"]\n'
    ;;
  'read pki/roles/spiffe -format=json')
    printf '{"data":{"allowed_uri_sans":["spiffe://example.test/ns/*"],"allow_any_name":false}}\n'
    ;;
  'list auth/cert/certs -format=json')
    printf '["AdMiN"]\n'
    ;;
  'read auth/cert/certs/AdMiN -format=json')
    printf '{"data":{"allowed_uri_sans":["spiffe://example.test/ns/provisioner"],"token_policies":["admin"]}}\n'
    ;;
  'policy read admin')
    printf 'path "sys/storage/raft/snapshot-force" { capabilities = ["update"] }\n'
    printf 'path "auth/cert/certs/*" { capabilities = ["update"] }\n'
    printf 'path "sys/policies/acl/*" { capabilities = ["update"] }\n'
    ;;
  *)
    printf '{}\n'
    ;;
esac
EOF
chmod +x "$fake_cli"

json_output="$(VAULT_CLI="$fake_cli" "$ROOT_DIR/security/vault/vault-openbao-chain-exposure-report.sh" --output json)"

jq -e '.product == "openbao"' >/dev/null <<< "$json_output"
jq -e '.version == "2.6.2"' >/dev/null <<< "$json_output"
jq -e '.findings[] | select(.finding == "OPENBAO_VERSION_BEFORE_2_6_3")' >/dev/null <<< "$json_output"
jq -e '.findings[] | select(.finding == "PKI_ACME_ENABLED")' >/dev/null <<< "$json_output"
jq -e '.findings[] | select(.finding == "CERT_AUTH_ROLE_NONCANONICAL_NAME")' >/dev/null <<< "$json_output"
jq -e '.findings[] | select(.finding == "SNAPSHOT_FORCE_POLICY_VISIBLE")' >/dev/null <<< "$json_output"
jq -e '.cert_auth_roles[] | select(.role == "AdMiN")' >/dev/null <<< "$json_output"

printf 'test-vault-openbao-chain-exposure-report passed.\n'
