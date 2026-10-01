# Vault/OpenBao Control Validation Research

This directory contains defensive research tooling for independently validating controls related to the publicly disclosed ControlPlane Vault/OpenBao attack chain.

The tooling is designed for isolated disposable labs. Default behavior is dry-run and local evidence generation only.

## Research Boundary

The objective is control validation, not full exploit reproduction.

Allowed research targets:

- observable prerequisites in isolated labs
- recommended controls that interrupt those prerequisites
- patched-version behavior for the same test condition
- evidence collection and PASS / FAIL / UNKNOWN classification

Out of scope:

- RCE payloads
- malicious Raft snapshots
- `snapshot-force` restore of attacker-controlled data
- plugin catalog replacement
- malicious plugin execution
- production mutation
- unpublished ControlPlane PoC reconstruction

## Result Language

Use narrow claims only.

Valid statement:

```text
Under the documented test conditions, the recommended control prevented the
specific prerequisite behavior reproduced in the affected baseline.
```

Invalid statements:

```text
Vault is secure.
OpenBao is not vulnerable.
RCE is impossible.
The chain is fully mitigated.
```

## Evidence Layout

Each phase writes evidence under:

```text
evidence/<experiment-id>/<phase>/
  metadata.json
  environment.json
  hypothesis.md
  requests/
  responses/
  state/
  result.json
  interpretation.md
```

Do not store Vault/OpenBao tokens, private keys, production secrets, or unredacted credentials in evidence.

## Experiment 1: Non-Canonical Cert-Auth ACL Behavior

Experiment script:

```text
vault-openbao-noncanonical-cert-auth-experiment.sh
```

Comparator:

```text
vault-openbao-experiment-compare.sh
```

Research question:

```text
Does the recommended mitigation or patched version prevent the publicly
documented non-canonical ACL behavior while an otherwise equivalent affected
baseline demonstrates it?
```

The specific observation is:

```text
affected baseline:
  canonical protected path     -> DENIED
  non-canonical protected path -> ALLOWED

mitigated or patched phase:
  canonical protected path     -> DENIED
  non-canonical protected path -> DENIED
```

If the affected baseline does not reproduce the prerequisite, the comparison result is `UNKNOWN` even if the mitigated or patched phase denies every request.

## Dry Run

Dry-run creates the evidence skeleton and planned requests without contacting Vault/OpenBao:

```bash
./security/vault/research/vault-openbao-noncanonical-cert-auth-experiment.sh \
  --phase baseline \
  --target-name openbao-2.6.2-lab \
  --evidence-root /tmp/vault-chain-evidence
```

Expected dry-run result:

```text
Result: UNKNOWN
Reason: dry-run only
```

## Live Lab Execution

Live execution mutates a disposable auth mount, policy, and role state. It is refused unless all mutation gates are present.

Required gates:

```text
--execute
--allow-lab-mutation
--acknowledge I_UNDERSTAND_THIS_MUTATES_AN_ISOLATED_LAB
VAULT_ADDR must look like localhost or RFC1918 lab address
```

Example baseline phase:

```bash
VAULT_CLI=bao \
VAULT_ADDR=http://127.0.0.1:8200 \
VAULT_TOKEN=<lab-admin-token> \
./security/vault/research/vault-openbao-noncanonical-cert-auth-experiment.sh \
  --execute \
  --allow-lab-mutation \
  --acknowledge I_UNDERSTAND_THIS_MUTATES_AN_ISOLATED_LAB \
  --phase baseline \
  --target-name openbao-2.6.2-lab \
  --certificate-file /path/to/disposable-public-cert.pem \
  --evidence-root /tmp/vault-chain-evidence
```

The certificate file must contain public certificate material only. Do not store private keys in evidence.

Run the mitigated and patched phases against separate, equivalent lab targets or snapshots:

```bash
--phase mitigated
--phase patched
```

Keep controlled variables the same unless the independent variable is the mitigation or product version under test.

## Compare Phases

Compare evidence after running the relevant phases:

```bash
./security/vault/research/vault-openbao-experiment-compare.sh \
  --baseline /tmp/vault-chain-evidence/ACL-NONCANONICAL-001/baseline \
  --mitigated /tmp/vault-chain-evidence/ACL-NONCANONICAL-001/mitigated \
  --patched /tmp/vault-chain-evidence/ACL-NONCANONICAL-001/patched
```

PASS requires:

```text
baseline reproduced the prerequisite
all supplied control phases denied the tested variants
```

FAIL means:

```text
baseline reproduced the prerequisite
at least one supplied control phase still allowed a tested non-canonical variant
```

UNKNOWN means:

```text
baseline did not reproduce the prerequisite
or no control phase was supplied
or evidence is incomplete
```

## Reproducibility Checklist

Record for every phase:

- product and version
- storage backend
- seal state
- target name
- phase name
- disposable cert-auth mount path
- protected role
- provisioner policy
- path variants tested
- before/after role state
- request path
- response status
- interpretation
- limitations

## Current Limitations

- Only the configured path variants are tested.
- The first experiment does not test ACME, namespace traversal, snapshot restore, plugin catalog behavior, or RCE.
- A phase-level PASS from the runner is not a complete control-validation PASS; use the comparator so baseline reproduction is required.
- This tooling does not prove that all canonicalization variants are fixed.
