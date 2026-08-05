#!/usr/bin/env bash
set -euo pipefail

OUTPUT="table"

usage() {
  cat <<'EOF'
Usage: vault-auth-method-report.sh [options]

Report enabled Vault auth methods and Kubernetes auth role mappings.

Options:
  --output FORMAT   table or json. Default: table.
  -h, --help        Show this help.

Environment:
  VAULT_ADDR        Vault address used by the vault CLI.
  VAULT_TOKEN       Optional token, or use an existing vault CLI login.

Safety:
  Read-only. Uses vault auth list and vault read/list only.
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
    --output|-o) OUTPUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$OUTPUT" in table|json) ;; *) echo "ERROR: --output must be table or json." >&2; exit 2 ;; esac

command -v vault >/dev/null 2>&1 || die "vault CLI is required."
command -v jq >/dev/null 2>&1 || die "jq is required."

auth_json="$(vault auth list -format=json 2>/dev/null)" || die "failed to list Vault auth methods."

tmp_files=()
auth_files=()
k8s_role_files=()
cleanup() {
  if [[ ${#tmp_files[@]} -gt 0 ]]; then
    rm -f "${tmp_files[@]}"
  fi
}
trap cleanup EXIT

while IFS=$'\t' read -r path type accessor; do
  [[ -n "$path" ]] || continue
  tune_json="$(vault_json_or_empty read "sys/auth/${path%/}/tune")"
  auth_file="$(mktemp)"
  tmp_files+=("$auth_file")
  jq -n --arg path "$path" --arg type "$type" --arg accessor "$accessor" --argjson tune "$tune_json" '{
    path: $path,
    type: $type,
    accessor_present: ($accessor != ""),
    default_lease_ttl: ($tune.data.default_lease_ttl // ""),
    max_lease_ttl: ($tune.data.max_lease_ttl // ""),
    token_type: ($tune.data.token_type // "")
  }' > "$auth_file"
  auth_files+=("$auth_file")

  if [[ "$type" == "kubernetes" ]]; then
    roles_json="$(vault_list_json_or_empty "auth/$path/role")"
    while IFS= read -r role; do
      [[ -n "$role" ]] || continue
      role_json="$(vault_json_or_empty read "auth/$path/role/$role")"
      role_file="$(mktemp)"
      tmp_files+=("$role_file")
      jq -n --arg mount "$path" --arg role "$role" --argjson data "$role_json" '{
        mount: $mount,
        role: $role,
        bound_service_account_names: ($data.data.bound_service_account_names // []),
        bound_service_account_namespaces: ($data.data.bound_service_account_namespaces // []),
        policies: ($data.data.policies // []),
        token_ttl: ($data.data.token_ttl // ""),
        token_max_ttl: ($data.data.token_max_ttl // ""),
        audience: ($data.data.audience // "")
      }' > "$role_file"
      k8s_role_files+=("$role_file")
    done < <(jq -r '.[]?' <<< "$roles_json")
  fi
done < <(jq -r 'to_entries[] | [.key, .value.type, (.value.accessor // "")] | @tsv' <<< "$auth_json")

auth_methods_json='[]'
k8s_roles_json='[]'
if [[ ${#auth_files[@]} -gt 0 ]]; then auth_methods_json="$(jq -s '.' "${auth_files[@]}")"; fi
if [[ ${#k8s_role_files[@]} -gt 0 ]]; then k8s_roles_json="$(jq -s '.' "${k8s_role_files[@]}")"; fi

report_json="$(jq -n --argjson methods "$auth_methods_json" --argjson k8s "$k8s_roles_json" '{auth_method_count: ($methods | length), kubernetes_role_count: ($k8s | length), auth_methods: $methods, kubernetes_roles: $k8s}')"

case "$OUTPUT" in
  json)
    jq '.' <<< "$report_json"
    ;;
  table)
    printf 'Vault auth method report\n'
    jq -r '"Auth methods: \(.auth_method_count)", "Kubernetes roles visible: \(.kubernetes_role_count)", ""' <<< "$report_json"
    printf 'Auth methods:\n'
    {
      printf 'PATH\tTYPE\tACCESSOR\tDEFAULT_TTL\tMAX_TTL\tTOKEN_TYPE\n'
      jq -r '.auth_methods[] | [.path,.type,.accessor_present,.default_lease_ttl,.max_lease_ttl,.token_type] | @tsv' <<< "$report_json"
    } | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
    printf '\nKubernetes auth roles:\n'
    {
      printf 'MOUNT\tROLE\tSERVICE_ACCOUNTS\tNAMESPACES\tPOLICIES\tTTL\tMAX_TTL\n'
      jq -r '.kubernetes_roles[] | [.mount,.role,(.bound_service_account_names | join(",")),(.bound_service_account_namespaces | join(",")),(.policies | join(",")),.token_ttl,.token_max_ttl] | @tsv' <<< "$report_json"
    } | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
    ;;
esac
