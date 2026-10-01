#!/usr/bin/env bash
set -euo pipefail

OUTPUT="table"
VAULT_CLI="${VAULT_CLI:-vault}"

usage() {
  cat <<'EOF'
Usage: vault-openbao-chain-exposure-report.sh [options]

Read-only exposure review for the Vault/OpenBao exploit chain described by
ControlPlane in September 2026. This does not exploit Vault or OpenBao.

Options:
  --output FORMAT   table or json. Default: table.
  -h, --help        Show this help.

Environment:
  VAULT_ADDR        Vault/OpenBao address used by the CLI.
  VAULT_TOKEN       Optional token, or use an existing CLI login.
  VAULT_CLI         CLI binary to use. Default: vault. Set to bao for OpenBao.

Safety:
  Read-only. Uses status, list, read, auth list, secrets list, and policy read/list.
  Does not issue certificates, restore snapshots, write policies, or change state.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

json_or_empty_object() {
  "$VAULT_CLI" "$@" -format=json 2>/dev/null || printf '{}'
}

json_or_empty_array() {
  "$VAULT_CLI" "$@" -format=json 2>/dev/null || printf '[]'
}

add_finding() {
  local severity="$1" finding="$2" location="$3" detail="$4" file
  file="$(mktemp)"
  tmp_files+=("$file")
  jq -n \
    --arg severity "$severity" \
    --arg finding "$finding" \
    --arg location "$location" \
    --arg detail "$detail" \
    '{severity: $severity, finding: $finding, location: $location, detail: $detail}' > "$file"
  finding_files+=("$file")
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output|-o) OUTPUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$OUTPUT" in table|json) ;; *) echo "ERROR: --output must be table or json." >&2; exit 2 ;; esac

command -v "$VAULT_CLI" >/dev/null 2>&1 || die "$VAULT_CLI CLI is required. Set VAULT_CLI=vault or VAULT_CLI=bao."
command -v jq >/dev/null 2>&1 || die "jq is required."

tmp_files=()
finding_files=()
pki_files=()
cert_role_files=()
policy_signal_files=()
cleanup() {
  if [[ ${#tmp_files[@]} -gt 0 ]]; then
    rm -f "${tmp_files[@]}"
  fi
}
trap cleanup EXIT

cli_version="$($VAULT_CLI version 2>/dev/null || true)"
status_json="$(json_or_empty_object status)"
auth_json="$(json_or_empty_object auth list)"
mounts_json="$(json_or_empty_object secrets list)"
policies_json="$(json_or_empty_array policy list)"

product="unknown"
if grep -qi 'openbao\|bao' <<< "$cli_version"; then
  product="openbao"
elif grep -qi 'vault' <<< "$cli_version"; then
  product="vault"
fi

version="$(jq -r '.version // ""' <<< "$status_json")"
if [[ -z "$version" || "$version" == "null" ]]; then
  version="$(grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' <<< "$cli_version" | head -n 1 || true)"
fi

if [[ "$product" == "openbao" ]]; then
  case "$version" in
    2.6.0|2.6.1|2.6.2)
      add_finding "critical" "OPENBAO_VERSION_BEFORE_2_6_3" "version" "OpenBao ${version} is before the patched 2.6.3 release referenced by ControlPlane."
      ;;
    2.7.0|2.6.3)
      ;;
    "")
      add_finding "medium" "OPENBAO_VERSION_UNKNOWN" "version" "Could not determine OpenBao server version."
      ;;
    *)
      add_finding "info" "OPENBAO_VERSION_REVIEW" "version" "Confirm this OpenBao version includes the September 2026 security fixes: ${version}."
      ;;
  esac
elif [[ "$product" == "vault" ]]; then
  add_finding "high" "VAULT_VERSION_REVIEW_REQUIRED" "version" "The ControlPlane write-up says the chain affects HashiCorp Vault. Confirm IBM/HashiCorp advisory status and patched version for ${version:-unknown}."
else
  add_finding "medium" "PRODUCT_UNKNOWN" "version" "Could not determine whether the target is Vault or OpenBao from CLI/version output."
fi

while IFS=$'\t' read -r mount type; do
  [[ -n "$mount" ]] || continue
  mount="${mount%/}"
  if [[ "$type" == "pki" ]]; then
    acme_json="$(json_or_empty_object read "$mount/config/acme")"
    roles_json="$(json_or_empty_array list "$mount/roles")"
    pki_file="$(mktemp)"
    tmp_files+=("$pki_file")
    jq -n --arg mount "$mount" --argjson acme "$acme_json" --argjson roles "$roles_json" '{
      mount: $mount,
      acme_visible: (($acme.data // {}) != {}),
      acme_enabled: ($acme.data.enabled // null),
      acme_eab_policy: ($acme.data.eab_policy // $acme.data.external_account_binding_policy // ""),
      roles_visible: ($roles | length),
      role_names: $roles
    }' > "$pki_file"
    pki_files+=("$pki_file")

    if jq -e '.data.enabled == true' <<< "$acme_json" >/dev/null 2>&1; then
      add_finding "high" "PKI_ACME_ENABLED" "$mount/config/acme" "ACME is enabled on this PKI mount. Review URI SAN controls and EAB requirements."
    elif jq -e '.data != null' <<< "$acme_json" >/dev/null 2>&1; then
      add_finding "info" "PKI_ACME_CONFIG_VISIBLE" "$mount/config/acme" "ACME config is visible. Confirm whether public ACME is disabled or requires EAB."
    fi

    while IFS= read -r role; do
      [[ -n "$role" ]] || continue
      role_json="$(json_or_empty_object read "$mount/roles/$role")"
      if jq -e '(.data.allow_any_name == true) or ((.data.allowed_uri_sans // []) | length > 0) or (.data.allow_glob_domains == true)' <<< "$role_json" >/dev/null 2>&1; then
        add_finding "medium" "PKI_ROLE_SAN_REVIEW" "$mount/roles/$role" "PKI role has broad name or URI SAN-related settings visible to this token."
      fi
    done < <(jq -r '.[]?' <<< "$roles_json")
  fi
done < <(jq -r 'to_entries[]? | [.key, .value.type] | @tsv' <<< "$mounts_json")

while IFS=$'\t' read -r mount type; do
  [[ -n "$mount" ]] || continue
  mount="${mount%/}"
  if [[ "$type" == "cert" ]]; then
    certs_json="$(json_or_empty_array list "auth/$mount/certs")"
    while IFS= read -r cert_role; do
      [[ -n "$cert_role" ]] || continue
      role_json="$(json_or_empty_object read "auth/$mount/certs/$cert_role")"
      role_file="$(mktemp)"
      tmp_files+=("$role_file")
      jq -n --arg mount "$mount" --arg role "$cert_role" --argjson data "$role_json" '{
        mount: $mount,
        role: $role,
        allowed_uri_sans_count: (($data.data.allowed_uri_sans // []) | length),
        token_policies_count: (($data.data.token_policies // $data.data.policies // []) | length),
        has_certificate_material: (($data.data.certificate // "") != "")
      }' > "$role_file"
      cert_role_files+=("$role_file")

      if [[ "$cert_role" =~ [A-Z] ]]; then
        add_finding "medium" "CERT_AUTH_ROLE_NONCANONICAL_NAME" "auth/$mount/certs/$cert_role" "Role name contains uppercase characters. Review for canonicalization-sensitive policy assumptions."
      fi
      if jq -e '((.data.allowed_uri_sans // []) | length > 0)' <<< "$role_json" >/dev/null 2>&1; then
        add_finding "medium" "CERT_AUTH_URI_SAN_ROLE" "auth/$mount/certs/$cert_role" "Cert auth role uses URI SAN matching. Review SPIFFE/SVID boundaries and issuer trust."
      fi
      if jq -e '((.data.token_policies // .data.policies // []) | length > 0)' <<< "$role_json" >/dev/null 2>&1; then
        add_finding "info" "CERT_AUTH_TOKEN_POLICIES" "auth/$mount/certs/$cert_role" "Cert auth role assigns token policies. Ensure only intended roles can modify this field."
      fi
    done < <(jq -r '.[]?' <<< "$certs_json")
  fi
done < <(jq -r 'to_entries[]? | [.key, .value.type] | @tsv' <<< "$auth_json")

while IFS= read -r policy; do
  [[ -n "$policy" ]] || continue
  policy_text="$($VAULT_CLI policy read "$policy" 2>/dev/null || true)"
  [[ -n "$policy_text" ]] || continue
  policy_file="$(mktemp)"
  tmp_files+=("$policy_file")
  jq -n --arg policy "$policy" --argjson snapshot "$([[ "$policy_text" =~ sys/storage/raft/snapshot-force ]] && printf true || printf false)" --argjson raw "$([[ "$policy_text" =~ sys/raw ]] && printf true || printf false)" --argjson cert_write "$([[ "$policy_text" =~ auth/.*/certs/.* ]] && printf true || printf false)" --argjson policy_write "$([[ "$policy_text" =~ sys/policies/acl ]] && printf true || printf false)" '{policy: $policy, snapshot_force: $snapshot, sys_raw: $raw, cert_auth_role_paths: $cert_write, acl_policy_paths: $policy_write}' > "$policy_file"
  policy_signal_files+=("$policy_file")

  if [[ "$policy_text" =~ sys/storage/raft/snapshot-force ]]; then
    add_finding "critical" "SNAPSHOT_FORCE_POLICY_VISIBLE" "policy/$policy" "Policy references sys/storage/raft/snapshot-force. Keep this path extremely restricted and monitored."
  fi
  if [[ "$policy_text" =~ sys/raw ]]; then
    add_finding "critical" "SYS_RAW_POLICY_VISIBLE" "policy/$policy" "Policy references sys/raw. This is unsafe in most environments and should be disabled/restricted."
  fi
  if [[ "$policy_text" =~ auth/.*/certs/.* && "$policy_text" =~ update|create|sudo ]]; then
    add_finding "high" "CERT_AUTH_ROLE_WRITE_POLICY" "policy/$policy" "Policy appears to allow writes to cert auth roles. Review canonical path variants and denied fields."
  fi
  if [[ "$policy_text" =~ sys/policies/acl && "$policy_text" =~ update|create|sudo ]]; then
    add_finding "high" "ACL_POLICY_WRITE_POLICY" "policy/$policy" "Policy appears to allow ACL policy writes. Review namespace boundaries and token policy assignment paths."
  fi
done < <(jq -r '.[]?' <<< "$policies_json")

pki_report='[]'
cert_role_report='[]'
policy_signal_report='[]'
findings_report='[]'
if [[ ${#pki_files[@]} -gt 0 ]]; then pki_report="$(jq -s '.' "${pki_files[@]}")"; fi
if [[ ${#cert_role_files[@]} -gt 0 ]]; then cert_role_report="$(jq -s '.' "${cert_role_files[@]}")"; fi
if [[ ${#policy_signal_files[@]} -gt 0 ]]; then policy_signal_report="$(jq -s '.' "${policy_signal_files[@]}")"; fi
if [[ ${#finding_files[@]} -gt 0 ]]; then findings_report="$(jq -s '.' "${finding_files[@]}")"; fi

report_json="$(jq -n \
  --arg cli_version "$cli_version" \
  --arg product "$product" \
  --arg version "$version" \
  --argjson pki "$pki_report" \
  --argjson cert_roles "$cert_role_report" \
  --argjson policy_signals "$policy_signal_report" \
  --argjson findings "$findings_report" '{
    product: $product,
    version: $version,
    cli_version: $cli_version,
    pki_mounts: $pki,
    cert_auth_roles: $cert_roles,
    policy_signals: $policy_signals,
    finding_count: ($findings | length),
    findings: $findings
  }')"

case "$OUTPUT" in
  json)
    jq '.' <<< "$report_json"
    ;;
  table)
    printf 'Vault/OpenBao exploit-chain exposure report\n'
    jq -r '"Product: \(.product)", "Version: \(.version // \"unknown\")", "Findings: \(.finding_count)", ""' <<< "$report_json"
    printf 'Findings:\n'
    {
      printf 'SEVERITY\tFINDING\tLOCATION\tDETAIL\n'
      jq -r '.findings[] | [.severity,.finding,.location,.detail] | @tsv' <<< "$report_json"
    } | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
    printf '\nPKI mounts:\n'
    {
      printf 'MOUNT\tACME_VISIBLE\tACME_ENABLED\tEAB_POLICY\tROLES_VISIBLE\n'
      jq -r '.pki_mounts[] | [.mount,.acme_visible,(.acme_enabled // ""),.acme_eab_policy,.roles_visible] | @tsv' <<< "$report_json"
    } | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
    printf '\nCert auth roles:\n'
    {
      printf 'MOUNT\tROLE\tURI_SAN_COUNT\tTOKEN_POLICY_COUNT\tCERT_MATERIAL_VISIBLE\n'
      jq -r '.cert_auth_roles[] | [.mount,.role,.allowed_uri_sans_count,.token_policies_count,.has_certificate_material] | @tsv' <<< "$report_json"
    } | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
    ;;
esac
