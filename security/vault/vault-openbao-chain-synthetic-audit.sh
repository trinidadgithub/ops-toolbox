#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: vault-openbao-chain-synthetic-audit.sh

Print synthetic Vault/OpenBao audit JSON-lines that resemble the observable
stages of the September 2026 exploit chain without exploiting anything.

Safety:
  Offline demonstration only. Writes JSON-lines to stdout. Does not connect to
  Vault/OpenBao, does not issue certificates, and does not restore snapshots.
EOF
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -gt 0 ]]; then
  echo "ERROR: unknown argument: $1" >&2
  usage >&2
  exit 2
fi

cat <<'EOF'
{"time":"2026-09-28T12:00:00Z","type":"request","auth":{"display_name":"entity:external-client","client_token_accessor":"hmac-sha256:accessor-001"},"request":{"operation":"update","path":"pki/acme/new-order","namespace":{"path":"root"},"remote_address":"198.51.100.10"}}
{"time":"2026-09-28T12:01:00Z","type":"request","auth":{"display_name":"cert-spiffe-provisioner","client_token_accessor":"hmac-sha256:accessor-002"},"request":{"operation":"update","path":"auth/cert/certs/AdMiN","namespace":{"path":"sandbox/"},"remote_address":"198.51.100.10"}}
{"time":"2026-09-28T12:02:00Z","type":"request","auth":{"display_name":"cert-spiffe-admin","client_token_accessor":"hmac-sha256:accessor-003"},"request":{"operation":"update","path":"sys/policies/acl/admin-escalation","namespace":{"path":"sandbox/"},"remote_address":"198.51.100.10"}}
{"time":"2026-09-28T12:03:00Z","type":"request","auth":{"display_name":"cert-spiffe-admin","client_token_accessor":"hmac-sha256:accessor-004"},"request":{"operation":"update","path":"sys/storage/raft/snapshot-force","namespace":{"path":"root"},"remote_address":"198.51.100.10"}}
EOF
