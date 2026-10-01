#!/usr/bin/env bash

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required."
}

utc_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

json_string() {
  jq -Rn --arg value "$1" '$value'
}

write_json_file() {
  local path="$1"
  jq '.' > "$path"
}

redact_text() {
  sed -E \
    -e 's/(hvs\.)[A-Za-z0-9._-]+/\1REDACTED/g' \
    -e 's/(s\.)[A-Za-z0-9._-]+/\1REDACTED/g' \
    -e 's/(client_token"[[:space:]]*:[[:space:]]*")[^"]+/(client_token":"REDACTED/g' \
    -e 's/(VAULT_TOKEN=)[^[:space:]]+/\1REDACTED/g'
}

ensure_evidence_dir() {
  local evidence_root="$1" experiment_id="$2" phase="$3" dir
  dir="$evidence_root/$experiment_id/$phase"
  mkdir -p "$dir/requests" "$dir/responses" "$dir/state"
  printf '%s\n' "$dir"
}

write_hypothesis() {
  local path="$1" hypothesis="$2"
  cat > "$path" <<EOF
# Hypothesis

$hypothesis
EOF
}

collect_environment_json() {
  local vault_cli="$1" phase="$2" target_name="$3" mutation_mode="$4"
  local cli_version status_json auth_json secrets_json
  cli_version="$($vault_cli version 2>/dev/null || true)"
  status_json="$($vault_cli status -format=json 2>/dev/null || printf '{}')"
  auth_json="$($vault_cli auth list -format=json 2>/dev/null || printf '{}')"
  secrets_json="$($vault_cli secrets list -format=json 2>/dev/null || printf '{}')"

  jq -n \
    --arg collected_at "$(utc_now)" \
    --arg target_name "$target_name" \
    --arg phase "$phase" \
    --arg mutation_mode "$mutation_mode" \
    --arg vault_addr "${VAULT_ADDR:-}" \
    --arg vault_cli "$vault_cli" \
    --arg cli_version "$cli_version" \
    --argjson status "$status_json" \
    --argjson auth "$auth_json" \
    --argjson secrets "$secrets_json" '{
      collected_at: $collected_at,
      target_name: $target_name,
      phase: $phase,
      mutation_mode: $mutation_mode,
      vault_addr: $vault_addr,
      vault_cli: $vault_cli,
      cli_version: $cli_version,
      status: $status,
      auth_mounts_visible: ($auth | keys),
      secrets_mounts_visible: ($secrets | keys)
    }'
}

write_metadata_json() {
  local path="$1" experiment_id="$2" phase="$3" type="$4" hypothesis="$5" independent_variable="$6" controlled_variables_json="$7"
  jq -n \
    --arg experiment_id "$experiment_id" \
    --arg created_at "$(utc_now)" \
    --arg phase "$phase" \
    --arg type "$type" \
    --arg hypothesis "$hypothesis" \
    --arg independent_variable "$independent_variable" \
    --argjson controlled_variables "$controlled_variables_json" '{
      experiment_id: $experiment_id,
      created_at: $created_at,
      phase: $phase,
      type: $type,
      hypothesis: $hypothesis,
      independent_variable: $independent_variable,
      controlled_variables: $controlled_variables
    }' > "$path"
}

write_result_json() {
  local path="$1" experiment_id="$2" phase="$3" type="$4" result="$5" reason="$6" observations_json="$7" limitations_json="$8"
  jq -n \
    --arg experiment_id "$experiment_id" \
    --arg completed_at "$(utc_now)" \
    --arg phase "$phase" \
    --arg type "$type" \
    --arg result "$result" \
    --arg reason "$reason" \
    --argjson observations "$observations_json" \
    --argjson limitations "$limitations_json" '{
      experiment_id: $experiment_id,
      completed_at: $completed_at,
      phase: $phase,
      type: $type,
      result: $result,
      reason: $reason,
      observations: $observations,
      limitations: $limitations
    }' > "$path"
}

write_interpretation() {
  local path="$1" result="$2" interpretation="$3" limitations="$4"
  cat > "$path" <<EOF
# Interpretation

Result: $result

$interpretation

## Limitations

$limitations
EOF
}

require_lab_mutation_ack() {
  local execute="$1" allow_lab_mutation="$2" acknowledgement="$3"
  if [[ "$execute" != "true" ]]; then
    return 0
  fi
  [[ "$allow_lab_mutation" == "true" ]] || die "live mutation requires --allow-lab-mutation."
  [[ "$acknowledgement" == "I_UNDERSTAND_THIS_MUTATES_AN_ISOLATED_LAB" ]] || die "live mutation requires --acknowledge I_UNDERSTAND_THIS_MUTATES_AN_ISOLATED_LAB."
  [[ -n "${VAULT_ADDR:-}" ]] || die "VAULT_ADDR is required for live mutation."
  case "${VAULT_ADDR}" in
    http://127.0.0.1:*|https://127.0.0.1:*|http://localhost:*|https://localhost:*|http://10.*|https://10.*|http://172.16.*|https://172.16.*|http://172.17.*|https://172.17.*|http://172.18.*|https://172.18.*|http://172.19.*|https://172.19.*|http://172.2[0-9].*|https://172.2[0-9].*|http://172.3[0-1].*|https://172.3[0-1].*|http://192.168.*|https://192.168.*) ;;
    *) die "live mutation requires VAULT_ADDR to look like localhost or RFC1918 lab address." ;;
  esac
}

request_json() {
  local method="$1" path="$2" variant="$3" expected="$4"
  jq -n --arg method "$method" --arg path "$path" --arg variant "$variant" --arg expected "$expected" '{method: $method, path: $path, variant: $variant, expected: $expected}'
}
