#!/usr/bin/env bash
set -euo pipefail

OUTPUT="table"

usage() {
  cat <<'EOF'
Usage: vault-policy-path-audit.sh [options]

Heuristically report broad-looking Vault policy path patterns.

Options:
  --output FORMAT   table or json. Default: table.
  -h, --help        Show this help.

Environment:
  VAULT_ADDR        Vault address used by the vault CLI.
  VAULT_TOKEN       Optional token, or use an existing vault CLI login.

Safety:
  Read-only. Uses vault policy list/read only. Does not read secret values.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
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

policies_json="$(vault policy list -format=json 2>/dev/null)" || die "failed to list Vault policies."

tmp_files=()
finding_files=()
cleanup() {
  if [[ ${#tmp_files[@]} -gt 0 ]]; then
    rm -f "${tmp_files[@]}"
  fi
}
trap cleanup EXIT

add_finding() {
  local policy="$1" finding="$2" path="$3" detail="$4" file
  file="$(mktemp)"
  tmp_files+=("$file")
  jq -n --arg policy "$policy" --arg finding "$finding" --arg path "$path" --arg detail "$detail" '{policy: $policy, finding: $finding, path: $path, detail: $detail}' > "$file"
  finding_files+=("$file")
}

while IFS= read -r policy; do
  [[ -n "$policy" ]] || continue
  policy_text="$(vault policy read "$policy" 2>/dev/null || true)"
  [[ -n "$policy_text" ]] || { add_finding "$policy" "POLICY_READ_DENIED" "" "Policy text was not visible to this token."; continue; }

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    block="$(awk -v p="$path" '
      $0 ~ "^path[[:space:]]+\\\"" p "\\\"" {capture=1}
      capture {print}
      capture && $0 ~ /^}/ {capture=0}
    ' <<< "$policy_text")"

    if [[ "$path" == "*" ]]; then
      add_finding "$policy" "GLOBAL_WILDCARD_PATH" "$path" "Policy contains path \"*\"."
    fi
    if grep -Eq 'capabilities[[:space:]]*=.*"sudo"' <<< "$block"; then
      add_finding "$policy" "SUDO_CAPABILITY" "$path" "Policy grants sudo capability."
    fi
    if [[ "$path" =~ ^(secret|kv|secrets)/\*+$ || "$path" =~ ^(secret|kv|secrets)/data/\*+$ ]]; then
      add_finding "$policy" "BROAD_SECRET_PATH" "$path" "Policy grants broad secret path access."
    fi
    if [[ "$path" =~ ^transit/(keys|encrypt|decrypt|rewrap|export|backup|restore|config)/.*\* ]]; then
      add_finding "$policy" "BROAD_TRANSIT_PATH" "$path" "Policy grants broad transit engine access."
    fi
    if [[ "$path" =~ ^pki/.*/roles/\* || "$path" =~ ^pki/roles/\* ]]; then
      add_finding "$policy" "PKI_WILDCARD_ROLE_ACCESS" "$path" "Policy grants wildcard PKI role access."
    fi
  done < <(grep -E '^path[[:space:]]+"' <<< "$policy_text" | sed -E 's/^path[[:space:]]+"([^"]+)".*/\1/')
done < <(jq -r '.[]?' <<< "$policies_json")

findings_json='[]'
if [[ ${#finding_files[@]} -gt 0 ]]; then findings_json="$(jq -s '.' "${finding_files[@]}")"; fi

report_json="$(jq -n --argjson policies "$policies_json" --argjson findings "$findings_json" '{policy_count: ($policies | length), finding_count: ($findings | length), findings: $findings}')"

case "$OUTPUT" in
  json)
    jq '.' <<< "$report_json"
    ;;
  table)
    printf 'Vault policy path audit\n'
    jq -r '"Policies visible: \(.policy_count)", "Heuristic findings: \(.finding_count)", ""' <<< "$report_json"
    {
      printf 'POLICY\tFINDING\tPATH\tDETAIL\n'
      jq -r '.findings[] | [.policy,.finding,.path,.detail] | @tsv' <<< "$report_json"
    } | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
    ;;
esac
