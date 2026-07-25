# Sanitization Policy

Every utility promoted into this repository must be reviewed for public release.

## Sensitive Material

Treat the following as sensitive until reviewed:

- Employer, customer, project, cluster, namespace, and datacenter names.
- Internal domains, hostnames, IP addresses, usernames, and filesystem paths.
- Kubeconfigs, certificates, SSH material, API keys, tokens, passwords, and credentials.
- Storage array names, vCenter inventory paths, DNS zones, and network topology.
- Ticket, incident, or case identifiers.
- Comments, examples, sample output, or workflows revealing internal architecture.
- Terraform, Packer, Ansible, or Kubernetes files containing real environment details.

## Ownership Classification

Classify each candidate before implementation.

| Class | Meaning | Action |
| --- | --- | --- |
| A | Clearly personal code | Sanitize, generalize, test, document, publish |
| B | Work-inspired general technique | Prefer clean-room rewrite from the concept |
| C | Clearly employer-owned or proprietary | Do not publish without written approval |

## Generalization Requirements

- Replace hard-coded names with validated command-line arguments, environment variables, config files, or auto-discovery.
- Use safe synthetic examples only.
- Do not preserve internal naming, structure, comments, topology, or example output.
- Do not claim compatibility with environments that were not actually tested.
- Keep remediation out of published utilities for now. Publish audit and reporting only.

## Publication Rule

Sanitization is not proof of ownership. If publication rights are unclear, do not publish the code. Reimplement the technique cleanly or request human review.

At this stage, only read-only inspection, reporting, audit, and diagnostic utilities are eligible for publication. Scripts that change system, cluster, network, storage, DNS, or infrastructure state are not eligible, even when sanitized.
