#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=security/vault/research/vault-chain-common.sh
source "$SCRIPT_DIR/vault-chain-common.sh"

VAULT_CLI="${VAULT_CLI:-vault}"
EXPERIMENT_ID="ACL-NONCANONICAL-001"
PHASE="baseline"
TARGET_NAME="unnamed-lab"
EVIDENCE_ROOT="evidence"
CERT_MOUNT="cpacl-test"
PROTECTED_ROLE="admin"
PROVISIONER_POLICY="cpacl-provisioner"
PROVISIONER_TOKEN=""
CERTIFICATE_FILE=""
EXECUTE="false"
ALLOW_LAB_MUTATION="false"
ACKNOWLEDGEMENT=""
OUTPUT="table"
VARIANTS=("admin" "AdMiN" "admin/" "./admin")

usage() {
  cat <<'EOF'
Usage: vault-openbao-noncanonical-cert-auth-experiment.sh [options]

Prepare or execute the Stage 3 non-canonical ACL/cert-auth validation experiment.
Dry-run is the default. Live mutation is refused unless explicit lab safety flags
are provided.

Options:
  --experiment-id ID       Default: ACL-NONCANONICAL-001.
  --phase PHASE            baseline, mitigated, or patched. Default: baseline.
  --target-name NAME       Human-readable lab target name.
  --evidence-root DIR      Evidence root directory. Default: evidence.
  --cert-mount PATH        Disposable cert-auth mount path. Default: cpacl-test.
  --protected-role ROLE    Protected role name. Default: admin.
  --provisioner-policy P   Disposable provisioner policy name. Default: cpacl-provisioner.
  --provisioner-token T    Existing low-privilege token for mutation attempts.
  --certificate-file FILE  Public PEM certificate used for disposable role writes.
  --variant VALUE          Add a path variant. May be repeated. Defaults are used unless --clear-variants is set.
  --clear-variants         Remove default variants before adding custom variants.
  --execute                Execute live lab mutation. Default is dry-run only.
  --allow-lab-mutation     Required with --execute.
  --acknowledge TEXT       Required with --execute: I_UNDERSTAND_THIS_MUTATES_AN_ISOLATED_LAB
  --output FORMAT          table or json. Default: table.
  -h, --help               Show this help.

Environment:
  VAULT_ADDR               Lab Vault/OpenBao address.
  VAULT_TOKEN              Admin/setup token for setup and evidence collection.
  VAULT_CLI                CLI binary. Default: vault. Set to bao for OpenBao.

Safety:
  Default mode writes only local evidence files and planned requests.
  Execution mode mutates a disposable lab auth mount, policy, and role state.
  Do not run execution mode against production.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --experiment-id) EXPERIMENT_ID="${2:-}"; shift 2 ;;
    --phase) PHASE="${2:-}"; shift 2 ;;
    --target-name) TARGET_NAME="${2:-}"; shift 2 ;;
    --evidence-root) EVIDENCE_ROOT="${2:-}"; shift 2 ;;
    --cert-mount) CERT_MOUNT="${2:-}"; shift 2 ;;
    --protected-role) PROTECTED_ROLE="${2:-}"; shift 2 ;;
    --provisioner-policy) PROVISIONER_POLICY="${2:-}"; shift 2 ;;
    --provisioner-token) PROVISIONER_TOKEN="${2:-}"; shift 2 ;;
    --certificate-file) CERTIFICATE_FILE="${2:-}"; shift 2 ;;
    --variant) VARIANTS+=("${2:-}"); shift 2 ;;
    --clear-variants) VARIANTS=(); shift ;;
    --execute) EXECUTE="true"; shift ;;
    --allow-lab-mutation) ALLOW_LAB_MUTATION="true"; shift ;;
    --acknowledge) ACKNOWLEDGEMENT="${2:-}"; shift 2 ;;
    --output|-o) OUTPUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$PHASE" in baseline|mitigated|patched) ;; *) die "--phase must be baseline, mitigated, or patched." ;; esac
case "$OUTPUT" in table|json) ;; *) die "--output must be table or json." ;; esac
[[ -n "$EXPERIMENT_ID" ]] || die "--experiment-id cannot be empty."
[[ -n "$CERT_MOUNT" ]] || die "--cert-mount cannot be empty."
[[ -n "$PROTECTED_ROLE" ]] || die "--protected-role cannot be empty."
[[ ${#VARIANTS[@]} -gt 0 ]] || die "at least one variant is required."

require_command jq
require_command date
require_command sed
command -v "$VAULT_CLI" >/dev/null 2>&1 || [[ "$EXECUTE" != "true" ]] || die "$VAULT_CLI CLI is required for execution."
require_lab_mutation_ack "$EXECUTE" "$ALLOW_LAB_MUTATION" "$ACKNOWLEDGEMENT"

if [[ "$EXECUTE" == "true" ]]; then
  [[ -n "$CERTIFICATE_FILE" ]] || die "--certificate-file is required for execution."
  [[ -f "$CERTIFICATE_FILE" ]] || die "certificate file not found: $CERTIFICATE_FILE"
fi

EVIDENCE_DIR="$(ensure_evidence_dir "$EVIDENCE_ROOT" "$EXPERIMENT_ID" "$PHASE")"
HYPOTHESIS="A token with broad cert-auth role write access and a specific deny for the protected role cannot mutate the protected role through canonical or tested non-canonical path variants once the mitigation or patch is effective."
CONTROLLED_VARIABLES_JSON="$(jq -n \
  --arg cert_mount "$CERT_MOUNT" \
  --arg protected_role "$PROTECTED_ROLE" \
  --arg provisioner_policy "$PROVISIONER_POLICY" \
  --argjson variants "$(printf '%s\n' "${VARIANTS[@]}" | jq -R . | jq -s .)" '{cert_mount: $cert_mount, protected_role: $protected_role, provisioner_policy: $provisioner_policy, variants: $variants}')"

write_metadata_json "$EVIDENCE_DIR/metadata.json" "$EXPERIMENT_ID" "$PHASE" "CONTROL_VALIDATION" "$HYPOTHESIS" "$PHASE" "$CONTROLLED_VARIABLES_JSON"
write_hypothesis "$EVIDENCE_DIR/hypothesis.md" "$HYPOTHESIS"

if command -v "$VAULT_CLI" >/dev/null 2>&1; then
  collect_environment_json "$VAULT_CLI" "$PHASE" "$TARGET_NAME" "$EXECUTE" > "$EVIDENCE_DIR/environment.json"
else
  jq -n --arg collected_at "$(utc_now)" --arg target_name "$TARGET_NAME" --arg phase "$PHASE" --arg vault_cli "$VAULT_CLI" '{collected_at: $collected_at, target_name: $target_name, phase: $phase, vault_cli: $vault_cli, collection: "skipped_cli_not_available"}' > "$EVIDENCE_DIR/environment.json"
fi

planned_requests_file="$EVIDENCE_DIR/requests/planned-requests.json"
{
  for variant in "${VARIANTS[@]}"; do
    expected="DENIED"
    request_json "write" "auth/${CERT_MOUNT}/certs/${variant}" "$variant" "$expected"
  done
} | jq -s '.' > "$planned_requests_file"

if [[ "$EXECUTE" != "true" ]]; then
  observations_json="$(jq -n --arg mode "dry-run" --arg planned_requests "$planned_requests_file" '{mode: $mode, live_mutation_performed: false, planned_requests_file: $planned_requests}')"
  limitations_json='["Dry-run only; no Vault/OpenBao requests were executed.","No affected baseline prerequisite was observed.","Result is UNKNOWN until execution evidence exists from an isolated lab."]'
  write_result_json "$EVIDENCE_DIR/result.json" "$EXPERIMENT_ID" "$PHASE" "CONTROL_VALIDATION" "UNKNOWN" "dry-run only" "$observations_json" "$limitations_json"
  write_interpretation "$EVIDENCE_DIR/interpretation.md" "UNKNOWN" "The experiment plan and evidence structure were generated, but no live mutation was performed. This cannot validate whether the prerequisite is observable or mitigated." "Dry-run output is suitable for review before selecting an isolated lab target."
else
  auth_list_before="$EVIDENCE_DIR/state/auth-list-before.json"
  policy_before="$EVIDENCE_DIR/state/policy-before.txt"
  protected_before="$EVIDENCE_DIR/state/protected-role-before.json"
  protected_after="$EVIDENCE_DIR/state/protected-role-after.json"
  attempts_file="$EVIDENCE_DIR/responses/mutation-attempts.json"

  "$VAULT_CLI" auth list -format=json 2>/dev/null | redact_text > "$auth_list_before" || printf '{}\n' > "$auth_list_before"

  if ! jq -e --arg mount "${CERT_MOUNT}/" 'has($mount)' "$auth_list_before" >/dev/null 2>&1; then
    "$VAULT_CLI" auth enable -path="$CERT_MOUNT" cert >/dev/null
  fi

  cat > "$EVIDENCE_DIR/state/${PROVISIONER_POLICY}.hcl" <<EOF
path "auth/${CERT_MOUNT}/certs/*" {
  capabilities = ["create", "update", "read"]
}

path "auth/${CERT_MOUNT}/certs/${PROTECTED_ROLE}" {
  capabilities = ["deny"]
}
EOF
  "$VAULT_CLI" policy write "$PROVISIONER_POLICY" "$EVIDENCE_DIR/state/${PROVISIONER_POLICY}.hcl" >/dev/null
  "$VAULT_CLI" policy read "$PROVISIONER_POLICY" 2>/dev/null | redact_text > "$policy_before" || true

  "$VAULT_CLI" write "auth/${CERT_MOUNT}/certs/${PROTECTED_ROLE}" \
    display_name="protected-${PROTECTED_ROLE}" \
    token_policies="protected-policy" \
    certificate=@"$CERTIFICATE_FILE" >/dev/null

  "$VAULT_CLI" read -format=json "auth/${CERT_MOUNT}/certs/${PROTECTED_ROLE}" 2>/dev/null | redact_text > "$protected_before" || printf '{}\n' > "$protected_before"

  if [[ -z "$PROVISIONER_TOKEN" ]]; then
    token_json="$($VAULT_CLI token create -format=json -policy="$PROVISIONER_POLICY" -ttl=30m 2>/dev/null)"
    PROVISIONER_TOKEN="$(jq -r '.auth.client_token // empty' <<< "$token_json")"
    jq 'del(.auth.client_token)' <<< "$token_json" | redact_text > "$EVIDENCE_DIR/state/provisioner-token-redacted.json"
  fi
  [[ -n "$PROVISIONER_TOKEN" ]] || die "failed to obtain provisioner token."

  attempt_files=()
  for variant in "${VARIANTS[@]}"; do
    attempt_path="auth/${CERT_MOUNT}/certs/${variant}"
    response_file="$EVIDENCE_DIR/responses/attempt-$(printf '%s' "$variant" | tr -cs 'A-Za-z0-9._-' '_').txt"
    before_hash="$(sha256sum "$protected_before" | awk '{print $1}')"
    set +e
    VAULT_TOKEN="$PROVISIONER_TOKEN" "$VAULT_CLI" write "$attempt_path" \
      display_name="attempt-${variant}" \
      token_policies="attempt-policy" \
      certificate=@"$CERTIFICATE_FILE" > "$response_file" 2>&1
    rc=$?
    set -e
    "$VAULT_CLI" read -format=json "auth/${CERT_MOUNT}/certs/${PROTECTED_ROLE}" 2>/dev/null | redact_text > "$protected_after" || printf '{}\n' > "$protected_after"
    after_hash="$(sha256sum "$protected_after" | awk '{print $1}')"
    observed="DENIED"
    [[ $rc -eq 0 ]] && observed="ALLOWED"
    changed="false"
    [[ "$before_hash" != "$after_hash" ]] && changed="true"
    attempt_json_file="$(mktemp)"
    jq -n \
      --arg variant "$variant" \
      --arg path "$attempt_path" \
      --arg observed "$observed" \
      --argjson exit_code "$rc" \
      --arg protected_role_changed "$changed" \
      --arg response_file "$response_file" '{variant: $variant, path: $path, observed: $observed, exit_code: $exit_code, protected_role_changed: ($protected_role_changed == "true"), response_file: $response_file}' > "$attempt_json_file"
    attempt_files+=("$attempt_json_file")
  done
  jq -s '.' "${attempt_files[@]}" > "$attempts_file"
  rm -f "${attempt_files[@]}"

  canonical_observed="$(jq -r --arg role "$PROTECTED_ROLE" '.[] | select(.variant == $role) | .observed' "$attempts_file" | head -n 1)"
  noncanonical_allowed="$(jq --arg role "$PROTECTED_ROLE" '[.[] | select(.variant != $role and .observed == "ALLOWED")] | length' "$attempts_file")"

  phase_result="UNKNOWN"
  reason="phase observation recorded; compare baseline/mitigated/patched with vault-openbao-experiment-compare.sh"
  if [[ "$PHASE" == "baseline" && "$canonical_observed" == "DENIED" && "$noncanonical_allowed" -gt 0 ]]; then
    phase_result="FAIL"
    reason="affected-baseline prerequisite observable: canonical denied and at least one non-canonical variant allowed"
  elif [[ "$canonical_observed" == "DENIED" && "$noncanonical_allowed" -eq 0 ]]; then
    phase_result="PASS"
    reason="tested variants denied in this phase; full control validation still requires affected baseline comparison"
  fi

  observations_json="$(jq -n --arg attempts_file "$attempts_file" --arg canonical "$canonical_observed" --argjson noncanonical_allowed "$noncanonical_allowed" '{live_mutation_performed: true, attempts_file: $attempts_file, canonical_observed: $canonical, noncanonical_allowed_count: $noncanonical_allowed}')"
  limitations_json='["Mutates only a disposable lab mount and policy.","Only explicitly configured variants are tested.","A phase-level PASS does not prove control validation unless the affected baseline reproduced the prerequisite."]'
  write_result_json "$EVIDENCE_DIR/result.json" "$EXPERIMENT_ID" "$PHASE" "CONTROL_VALIDATION" "$phase_result" "$reason" "$observations_json" "$limitations_json"
  write_interpretation "$EVIDENCE_DIR/interpretation.md" "$phase_result" "$reason" "Only the tested variants and configured lab policy shape are covered."
fi

case "$OUTPUT" in
  json)
    jq '.' "$EVIDENCE_DIR/result.json"
    ;;
  table)
    printf 'Vault/OpenBao non-canonical cert-auth experiment\n'
    jq -r '"Experiment: \(.experiment_id)", "Phase: \(.phase)", "Type: \(.type)", "Result: \(.result)", "Reason: \(.reason)"' "$EVIDENCE_DIR/result.json"
    printf 'Evidence: %s\n' "$EVIDENCE_DIR"
    ;;
esac
