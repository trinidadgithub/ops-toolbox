#!/usr/bin/env bash
set -euo pipefail

OUTPUT="table"
MAX_DEPTH=2

usage() {
  cat <<'EOF'
Usage: vault-lease-summary.sh [options]

Summarize visible Vault lease prefixes without renewing or revoking leases.

Options:
  --max-depth N     Prefix recursion depth. Default: 2.
  --output FORMAT   table or json. Default: table.
  -h, --help        Show this help.

Environment:
  VAULT_ADDR        Vault address used by the vault CLI.
  VAULT_TOKEN       Optional token, or use an existing vault CLI login.

Safety:
  Read-only. Uses vault list on sys/leases/lookup only. Does not renew or revoke leases.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

is_nonnegative_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-depth) MAX_DEPTH="${2:-}"; shift 2 ;;
    --output|-o) OUTPUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

is_nonnegative_integer "$MAX_DEPTH" || { echo "ERROR: --max-depth must be zero or a positive integer." >&2; exit 2; }
case "$OUTPUT" in table|json) ;; *) echo "ERROR: --output must be table or json." >&2; exit 2 ;; esac

command -v vault >/dev/null 2>&1 || die "vault CLI is required."
command -v jq >/dev/null 2>&1 || die "jq is required."

tmp_files=()
prefix_files=()
permission_note=""
cleanup() {
  if [[ ${#tmp_files[@]} -gt 0 ]]; then
    rm -f "${tmp_files[@]}"
  fi
}
trap cleanup EXIT

walk_prefix() {
  local prefix="$1" depth="$2" path keys_json file child child_prefix leaf_count child_prefix_count
  path="sys/leases/lookup"
  if [[ -n "$prefix" ]]; then
    path="$path/$prefix"
  fi

  if ! keys_json="$(vault list -format=json "$path" 2>/dev/null)"; then
    if [[ -z "$prefix" ]]; then
      permission_note="Token cannot list sys/leases/lookup. Lease visibility is unavailable."
    fi
    return 0
  fi

  leaf_count="$(jq '[.[]? | select(endswith("/") | not)] | length' <<< "$keys_json")"
  child_prefix_count="$(jq '[.[]? | select(endswith("/"))] | length' <<< "$keys_json")"
  file="$(mktemp)"
  tmp_files+=("$file")
  jq -n --arg prefix "${prefix:-/}" --argjson depth "$depth" --argjson leaf_count "$leaf_count" --argjson child_prefix_count "$child_prefix_count" '{prefix: $prefix, depth: $depth, visible_leaf_count: $leaf_count, child_prefix_count: $child_prefix_count}' > "$file"
  prefix_files+=("$file")

  if [[ "$depth" -ge "$MAX_DEPTH" ]]; then
    return 0
  fi

  while IFS= read -r child; do
    child_prefix="${prefix}${child}"
    walk_prefix "$child_prefix" $((depth + 1))
  done < <(jq -r '.[]? | select(endswith("/"))' <<< "$keys_json")
}

walk_prefix "" 0

prefixes_json='[]'
if [[ ${#prefix_files[@]} -gt 0 ]]; then prefixes_json="$(jq -s '.' "${prefix_files[@]}")"; fi

report_json="$(jq -n --arg note "$permission_note" --argjson max_depth "$MAX_DEPTH" --argjson prefixes "$prefixes_json" '{max_depth: $max_depth, permission_note: $note, prefix_count: ($prefixes | length), visible_leaf_count: ($prefixes | map(.visible_leaf_count) | add // 0), prefixes: $prefixes}')"

case "$OUTPUT" in
  json)
    jq '.' <<< "$report_json"
    ;;
  table)
    printf 'Vault lease summary\n'
    jq -r '"Max depth: \(.max_depth)", "Visible prefixes: \(.prefix_count)", "Visible leaf leases at scanned prefixes: \(.visible_leaf_count)", (if .permission_note != "" then "Permission note: " + .permission_note else empty end), ""' <<< "$report_json"
    {
      printf 'PREFIX\tDEPTH\tVISIBLE_LEAF_LEASES\tCHILD_PREFIXES\n'
      jq -r '.prefixes[] | [.prefix,(.depth | tostring),(.visible_leaf_count | tostring),(.child_prefix_count | tostring)] | @tsv' <<< "$report_json"
    } | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
    ;;
esac
