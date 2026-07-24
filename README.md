# ops-toolbox

Practical operations utilities for DevOps, SRE, platform engineering, Linux, Kubernetes, infrastructure automation, storage, networking, and troubleshooting work.

This repository is intended to publish reusable operational techniques, not employer-specific scripts or environment details.

## Project Principles

- Publish the technique, not the employer.
- Prefer small, focused tools over frameworks.
- Keep diagnostic tools read-only by default.
- Require explicit operator intent for state-changing actions.
- Use synthetic examples and documentation-safe names only.
- Treat existing operational scripts as source material, not automatically publishable code.

## Current Status

This repository is in the initial seed stage. The first utilities are clean-room implementations based on general operational patterns, not copied employer-specific scripts.

## Documentation

- `docs/sanitization-policy.md` defines the publication safety policy.
- `docs/publication-checklist.md` provides the review gate for each utility.

The local session seed analysis and original source PDFs are intentionally ignored by git.

## Candidate Utility Areas

- Kubernetes unhealthy workload reporting
- Kubernetes node readiness and maintenance checks
- RKE2 service and maintenance readiness checks
- Longhorn node/storage health inspection
- Linux disk and LVM reporting
- DNS search-domain drift detection
- Calico node IP autodetection auditing
- VMware disk provisioning reporting

Each candidate must pass security, ownership, documentation, and testing review before being added here.

## Initial Utilities

- `kubernetes/workloads/k8s-unhealthy-pods.sh`: report Kubernetes pods that are not healthy.
- `linux/storage/linux-storage-report.sh`: collect a read-only Linux storage and filesystem report.
- `linux/dns/dns-search-drift-detector.sh`: audit DNS search-domain drift locally or across hosts with SSH.
