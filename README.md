# ops-toolbox

Practical operations utilities for DevOps, SRE, platform engineering, Linux, Kubernetes, infrastructure automation, storage, networking, and troubleshooting work.

This repository is intended to publish reusable operational techniques, not employer-specific scripts or environment details.

## Project Principles

- Publish the technique, not the employer.
- Prefer small, focused tools over frameworks.
- Publish only read-only inspection, reporting, and diagnostic utilities for now.
- Exclude scripts that change state, even with dry-run support, until the project has a stronger review and safety process.
- Use synthetic examples and documentation-safe names only.
- Treat existing operational scripts as source material, not automatically publishable code.

## Current Status

This repository is in the initial seed stage. The first utilities are clean-room implementations based on general operational patterns, not copied employer-specific scripts.

## Documentation

- `docs/sanitization-policy.md` defines the publication safety policy.
- `docs/publication-checklist.md` provides the review gate for each utility.
- `docs/design-principles.md` defines the utility design and safety model.

The local session seed analysis and original source PDFs are intentionally ignored by git.

## Candidate Utility Areas

- Kubernetes unhealthy workload reporting
- Kubernetes node readiness and maintenance checks
- RKE2 service and maintenance readiness checks
- Longhorn node/storage health inspection
- Kubernetes storage resize and expansion auditing
- Kubernetes networking diagnostics
- Observability health, alerting, dashboard, and incident-response audits
- Vault PKI, auth, policy, lease, and Transit diagnostics
- Linux disk and LVM reporting
- DNS search-domain drift detection
- Calico node IP autodetection auditing
- VMware disk provisioning reporting

Each candidate must pass security, ownership, documentation, and testing review before being added here.

## Initial Utilities

- `kubernetes/workloads/k8s-unhealthy-pods.sh`: report Kubernetes pods that are not healthy.
- `kubernetes/nodes/k8s-node-maintenance-gate-report.sh`: report read-only Kubernetes node maintenance gates.
- `kubernetes/longhorn/longhorn-scheduler-pressure-report.sh`: report Longhorn disk scheduling pressure and scheduled-capacity overcommitment.
- `kubernetes/longhorn/longhorn-orphan-report.sh`: report Longhorn orphaned replica data and managed replica overlap.
- `kubernetes/longhorn/longhorn-pvc-ownership-audit.sh`: inspect Kubernetes and Longhorn ownership signals before PVC cleanup review.
- `kubernetes/longhorn/longhorn-maintenance-gate-report.sh`: report Longhorn health gates before storage-node maintenance.
- `kubernetes/storage/pvc-resize-audit.sh`: report PVC resize and expansion signals.
- `kubernetes/networking/kube-proxy-diagnostics.sh`: collect a read-only kube-proxy diagnostics bundle.
- `observability/`: read-only Prometheus, Alertmanager, and Grafana audit utilities.
- `security/vault/`: read-only Vault operational audit utilities.
- `linux/storage/linux-storage-report.sh`: collect a read-only Linux storage and filesystem report.
- `linux/dns/dns-search-drift-detector.sh`: audit DNS search-domain drift locally or across hosts with SSH.
- `vmware/vm-disk-provisioning-report.sh`: report VMware virtual disk thin/thick provisioning metadata.
- `vmware/vm-cdrom-report.sh`: report VMware virtual CD/DVD device inventory and connected/start-connected state.
- `linux/system/node-triage-bundle.sh`: collect a read-only Linux node triage bundle for post-incident review.
