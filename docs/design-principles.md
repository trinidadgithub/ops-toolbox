# Design Principles

`ops-toolbox` publishes practical operational diagnostics that are safe to inspect, understand, and run.

## Read-Only Publication Rule

For now, published utilities must be read-only.

Eligible utilities may:

- inspect state
- report state
- audit configuration
- summarize health signals
- collect diagnostic evidence
- produce human-readable or machine-readable output

Ineligible utilities include scripts that:

- delete files, data, volumes, replicas, Kubernetes objects, or infrastructure resources
- restart services, pods, nodes, workloads, or daemons
- patch, label, annotate, scale, cordon, uncordon, drain, attach, detach, mount, unmount, format, resize, or remediate anything
- modify DNS, resolver, netplan, systemd, SSH, firewall, routing, storage, Kubernetes, Longhorn, VMware, Terraform, or Ansible-managed state
- perform cleanup automatically or semi-automatically

Dry-run support is not enough to make a state-changing script publishable at this stage.

## Operational Model

Prefer this flow:

- inspect
- report
- explain limitations
- let the operator decide

Avoid this flow for now:

- inspect
- decide automatically
- remediate

## Utility Shape

- Keep tools small and focused.
- Prefer shell or lightweight Python when appropriate.
- Avoid frameworks unless they solve a real operational problem.
- Validate arguments and dependencies.
- Use meaningful exit codes.
- Support automation-friendly output only when it adds practical value.
- Use synthetic examples and fixture data in documentation and tests.

## Cleanup-Related Diagnostics

Cleanup-oriented inspection tools must be especially conservative.

They may identify review candidates, ownership signals, or risk indicators. They must not approve deletion or imply that cleanup is safe without human review.
