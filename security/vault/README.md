# Vault Operational Utilities

Read-only Vault inspection tools for operational review, incident context, and security hygiene checks.

This area complements Vault content on `trinidadmarroquin.com`, including PKI secrets engine operations, Transit engine usage, Kubernetes auth method design, and secrets rotation patterns.

## Safety Model

- These utilities are read-only.
- They use `vault list`, `vault read`, `vault auth list`, and `vault policy read/list` only.
- They do not rotate, revoke, renew, write, delete, enable, disable, tune, encrypt, decrypt, sign, export, or modify Vault data or configuration.
- They do not print raw secret values, Vault tokens, private keys, certificate private keys, ciphertext payloads, plaintext payloads, or sensitive secret bodies.
- Permission-denied paths are reported as limited visibility instead of being treated as approval or failure of the environment.

## Prerequisites

- `bash`
- `vault` CLI
- `jq`
- Optional: `column` for aligned table output

The tools assume the caller already has a Vault token or an existing Vault CLI login.

## Environment Variables

- `VAULT_ADDR`: Vault server address used by the Vault CLI.
- `VAULT_TOKEN`: optional Vault token. Existing CLI login also works.
- `PKI_MOUNT`: optional PKI mount path. Default: `pki`.
- `TRANSIT_MOUNT`: optional Transit mount path. Default: `transit`.

Do not commit tokens, generated reports, Vault addresses from private environments, policy exports, or command output that reveals internal paths.

## Expected Vault Permissions

Permissions vary by script and environment. In general, the token needs read/list access to the paths being inspected.

Useful read-only capabilities include:

- `read` on `sys/auth/*/tune`
- `read` on `sys/auth`
- `list` on `auth/<mount>/role`
- `read` on `auth/<mount>/role/<role>`
- `list` on `<pki_mount>/roles`
- `read` on `<pki_mount>/roles/<role>`
- `read` on `<pki_mount>/config/urls`
- `list` on `<transit_mount>/keys`
- `read` on `<transit_mount>/keys/<key>`
- `read` on `sys/policies/acl/<policy>` through `vault policy read`
- `list` on `sys/leases/lookup` if lease visibility is allowed

Limited permissions are normal. These tools should make visibility gaps obvious without requiring broad administrative tokens.

## Operational Checklist

| Question | Utility |
| --- | --- |
| Which auth methods are enabled? | `vault-auth-method-report.sh` |
| Which Kubernetes service accounts map to Vault roles? | `vault-auth-method-report.sh` |
| Which policies look overly broad? | `vault-policy-path-audit.sh` |
| Which PKI roles allow risky issuance? | `vault-pki-certificate-report.sh` |
| Which transit keys have risky settings? | `vault-transit-key-report.sh` |
| What lease visibility does the operator have? | `vault-lease-summary.sh` |

## Utilities

### `vault-pki-certificate-report.sh`

Reports PKI role settings and URL configuration where visible.

```bash
VAULT_ADDR=https://vault.example.com \
  ./security/vault/vault-pki-certificate-report.sh

PKI_MOUNT=pki_int \
  ./security/vault/vault-pki-certificate-report.sh --output json
```

Fields include role name, max TTL, allowed domains, wildcard allowance, bare-domain allowance, `allow_any_name`, and visible URL config.

### `vault-auth-method-report.sh`

Reports enabled auth methods and Kubernetes auth roles where visible.

```bash
VAULT_ADDR=https://vault.example.com \
  ./security/vault/vault-auth-method-report.sh
```

For Kubernetes auth mounts, the report includes role names, bound service account names, namespaces, policies, and token TTL settings.

### `vault-policy-path-audit.sh`

Heuristically reports broad-looking ACL policy patterns.

```bash
VAULT_ADDR=https://vault.example.com \
  ./security/vault/vault-policy-path-audit.sh
```

Findings may include global wildcard paths, `sudo` capability, broad secret paths, broad Transit paths, and wildcard PKI role access.

This is not a security scanner. It is an operator review aid.

### `vault-lease-summary.sh`

Summarizes visible lease prefixes and visible leaf counts where permissions allow.

```bash
VAULT_ADDR=https://vault.example.com \
  ./security/vault/vault-lease-summary.sh

./security/vault/vault-lease-summary.sh --max-depth 3 --output json
```

This script does not renew or revoke leases.

### `vault-transit-key-report.sh`

Reports Transit key metadata where visible.

```bash
VAULT_ADDR=https://vault.example.com \
  ./security/vault/vault-transit-key-report.sh

TRANSIT_MOUNT=transit \
  ./security/vault/vault-transit-key-report.sh --output json
```

Fields include key type, latest version, minimum decrypt/encrypt versions, deletion allowed, exportable, plaintext backup allowance, and visible usage support flags.

## Output Sanitization Warnings

These tools avoid printing raw secret values, but Vault metadata can still reveal internal architecture.

Review output before sharing publicly. Treat the following as sensitive until reviewed:

- mount names
- policy names
- role names
- service account names
- namespaces
- allowed domains
- issuer URLs
- CRL URLs
- lease prefixes
- key names

## Content Series Mapping

- Vault PKI Secrets Engine For Internal Certificates: `vault-pki-certificate-report.sh`
- Vault Transit Engine For Application Encryption: `vault-transit-key-report.sh`
- Vault Kubernetes Auth Method Deep Dive: `vault-auth-method-report.sh`
- Secrets Rotation Patterns With Vault: `vault-lease-summary.sh` and `vault-policy-path-audit.sh`

## Limitations

- Output depends on Vault version, enabled engines, and token capabilities.
- Some enterprise features may expose different metadata than open-source Vault.
- Policy findings are heuristic and need human review.
- Lease visibility is commonly restricted.
- The scripts do not validate whether a PKI, auth, Transit, or rotation design is correct.

## Publication Assessment

- Security: examples use documentation-safe domains only.
- Ownership: generic Vault operational inspection techniques.
- Safety: read-only diagnostics using Vault CLI read/list operations.
- Status: `READY WITH CHANGES` until reviewed against sanitized fixtures or a local Vault lab.
