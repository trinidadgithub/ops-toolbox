#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

experiment="$ROOT_DIR/security/vault/research/vault-openbao-noncanonical-cert-auth-experiment.sh"
compare="$ROOT_DIR/security/vault/research/vault-openbao-experiment-compare.sh"

dry_run_json="$($experiment --evidence-root "$tmp_dir/evidence" --target-name fixture-lab --output json)"
jq -e '.result == "UNKNOWN"' >/dev/null <<< "$dry_run_json"
jq -e '.reason == "dry-run only"' >/dev/null <<< "$dry_run_json"
test -f "$tmp_dir/evidence/ACL-NONCANONICAL-001/baseline/metadata.json"
test -f "$tmp_dir/evidence/ACL-NONCANONICAL-001/baseline/requests/planned-requests.json"

make_phase() {
  local phase_dir="$1" protected_role="$2" canonical="$3" noncanonical="$4"
  mkdir -p "$phase_dir/responses"
  jq -n --arg protected_role "$protected_role" '{controlled_variables: {protected_role: $protected_role}}' > "$phase_dir/metadata.json"
  jq -n --arg attempts_file "$phase_dir/responses/mutation-attempts.json" '{observations: {attempts_file: $attempts_file}, result: "FIXTURE", reason: "fixture"}' > "$phase_dir/result.json"
  jq -n \
    --arg protected_role "$protected_role" \
    --arg canonical "$canonical" \
    --arg noncanonical "$noncanonical" '[
      {variant: $protected_role, observed: $canonical, protected_role_changed: false},
      {variant: "AdMiN", observed: $noncanonical, protected_role_changed: ($noncanonical == "ALLOWED")}
    ]' > "$phase_dir/responses/mutation-attempts.json"
}

make_phase "$tmp_dir/pass/baseline" admin DENIED ALLOWED
make_phase "$tmp_dir/pass/mitigated" admin DENIED DENIED
make_phase "$tmp_dir/pass/patched" admin DENIED DENIED
pass_json="$($compare --baseline "$tmp_dir/pass/baseline" --mitigated "$tmp_dir/pass/mitigated" --patched "$tmp_dir/pass/patched" --output json)"
jq -e '.result == "PASS"' >/dev/null <<< "$pass_json"
jq -e '.baseline_reproduced == true' >/dev/null <<< "$pass_json"

make_phase "$tmp_dir/unknown/baseline" admin DENIED DENIED
make_phase "$tmp_dir/unknown/mitigated" admin DENIED DENIED
unknown_json="$($compare --baseline "$tmp_dir/unknown/baseline" --mitigated "$tmp_dir/unknown/mitigated" --output json)"
jq -e '.result == "UNKNOWN"' >/dev/null <<< "$unknown_json"
jq -e '.baseline_reproduced == false' >/dev/null <<< "$unknown_json"

make_phase "$tmp_dir/fail/baseline" admin DENIED ALLOWED
make_phase "$tmp_dir/fail/mitigated" admin DENIED ALLOWED
fail_json="$($compare --baseline "$tmp_dir/fail/baseline" --mitigated "$tmp_dir/fail/mitigated" --output json)"
jq -e '.result == "FAIL"' >/dev/null <<< "$fail_json"

printf 'test-vault-openbao-research-framework passed.\n'
