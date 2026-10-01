#!/usr/bin/env bash
set -euo pipefail

INPUT=""
OUTPUT="table"

usage() {
  cat <<'EOF'
Usage: vault-openbao-chain-audit-report.sh --input FILE [options]

Offline detector for Vault/OpenBao audit events related to the September 2026
Vault/OpenBao exploit chain described by ControlPlane.

Options:
  --input FILE      Vault/OpenBao audit log file in JSON-lines format. Required.
  --output FORMAT   table or json. Default: table.
  -h, --help        Show this help.

Safety:
  Offline/read-only. Parses an audit log file. Does not connect to Vault/OpenBao.
  The report prints paths, operation names, and accessor-like identifiers only.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input|-i) INPUT="${2:-}"; shift 2 ;;
    --output|-o) OUTPUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$INPUT" ]] || { usage >&2; exit 2; }
[[ -f "$INPUT" ]] || die "input file not found: $INPUT"
case "$OUTPUT" in table|json) ;; *) echo "ERROR: --output must be table or json." >&2; exit 2 ;; esac

command -v jq >/dev/null 2>&1 || die "jq is required."

report_json="$(jq -s '
  def req: .request // {};
  def auth: .auth // {};
  def path: (req.path // .path // "");
  def op: (req.operation // .operation // "");
  def ns: (req.namespace.path // .namespace.path // "root");
  def display: (auth.display_name // auth.entity_id // auth.client_token_accessor // "");
  def remote: (req.remote_address // .remote_address // "");
  def event($severity; $finding; $detail): {
    time: (.time // .timestamp // ""),
    severity: $severity,
    finding: $finding,
    namespace: ns,
    operation: op,
    path: path,
    principal: display,
    remote_address: remote,
    detail: $detail
  };

  [ .[]
    | select(type == "object")
    | if (path | test("(^|/)pki/.*/acme/|(^|/)pki/acme/|/acme/")) then
        event("medium"; "ACME_ACTIVITY"; "ACME endpoint activity. Review URI SAN issuance and EAB requirements.")
      elif ((path | test("^auth/.*/certs/")) and (op | test("update|create|delete"))) then
        event("high"; "CERT_AUTH_ROLE_CHANGE"; "Certificate auth role was modified. Review role name canonicalization, URI SANs, and token policy fields.")
      elif ((path | test("^auth/.*/certs/.*[A-Z]")) and (op | test("update|create|read"))) then
        event("medium"; "CERT_AUTH_NONCANONICAL_ROLE_PATH"; "Certificate auth role path contains uppercase characters.")
      elif ((path | test("sys/policies/acl")) and (op | test("update|create|delete"))) then
        event("high"; "ACL_POLICY_CHANGE"; "ACL policy was changed. Review namespace boundary and token policy escalation risk.")
      elif ((path | test("sys/storage/raft/snapshot-force")) and (op | test("update|create"))) then
        event("critical"; "SNAPSHOT_FORCE_RESTORE"; "Raft snapshot-force restore was invoked. Treat as emergency unless expected and approved.")
      elif ((path | test("sys/raw")) and (op | test("update|create|delete|read"))) then
        event("critical"; "SYS_RAW_ACTIVITY"; "sys/raw activity observed. This can indicate direct storage manipulation risk.")
      else empty end ] as $events
  | {
      event_count: length,
      finding_count: ($events | length),
      findings: $events,
      chain_indicators: {
        acme_activity: any($events[]?; .finding == "ACME_ACTIVITY"),
        cert_auth_role_change: any($events[]?; .finding == "CERT_AUTH_ROLE_CHANGE"),
        acl_policy_change: any($events[]?; .finding == "ACL_POLICY_CHANGE"),
        snapshot_force_restore: any($events[]?; .finding == "SNAPSHOT_FORCE_RESTORE"),
        sys_raw_activity: any($events[]?; .finding == "SYS_RAW_ACTIVITY")
      }
    }
' "$INPUT")"

case "$OUTPUT" in
  json)
    jq '.' <<< "$report_json"
    ;;
  table)
    printf 'Vault/OpenBao exploit-chain audit report\n'
    jq -r '"Findings: \(.finding_count)", ""' <<< "$report_json"
    printf 'Chain indicators:\n'
    jq -r '.chain_indicators | to_entries[] | " - \(.key): \(.value)"' <<< "$report_json"
    printf '\nFindings:\n'
    {
      printf 'TIME\tSEVERITY\tFINDING\tNAMESPACE\tOPERATION\tPATH\tPRINCIPAL\tDETAIL\n'
      jq -r '.findings[] | [.time,.severity,.finding,.namespace,.operation,.path,.principal,.detail] | @tsv' <<< "$report_json"
    } | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
    ;;
esac
