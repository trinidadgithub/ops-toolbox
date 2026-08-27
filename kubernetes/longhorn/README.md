# Longhorn Kubernetes Utilities

Read-only utilities for Longhorn storage troubleshooting and cleanup review.

These tools are clean-room implementations of general operational patterns. They do not include company-specific cluster names, namespaces, hostnames, PVC names, or incident data.

## Safety Model

- All scripts are read-only.
- No script deletes PVCs, PVs, Longhorn volumes, Orphan CRs, replicas, or filesystem paths.
- Cleanup classifications are review aids, not approval to delete data.
- Any state-changing action should be performed manually after evidence review and application-owner confirmation.

## Requirements

- `bash`
- `kubectl`
- `jq`
- Optional: `column` for aligned table output

## `longhorn-scheduler-pressure-report.sh`

Reports Longhorn disk scheduling pressure from `nodes.longhorn.io`.

It helps distinguish physical free space from Longhorn scheduled capacity by reporting:

- disk schedulable condition
- `storageMaximum`
- `storageAvailable`
- `storageScheduled`
- scheduled percentage
- scheduled-over-maximum GiB
- scheduled replica count

Usage:

```bash
./kubernetes/longhorn/longhorn-scheduler-pressure-report.sh --context example-rke2
./kubernetes/longhorn/longhorn-scheduler-pressure-report.sh --output csv
./kubernetes/longhorn/longhorn-scheduler-pressure-report.sh --namespace longhorn-system --output json
```

Use this when Longhorn reports messages such as `no scheduled replicas`, `Replica Scheduling Failure`, `insufficient storage`, or disk `Schedulable=False`.

## `longhorn-orphan-report.sh`

Reports Longhorn orphan resources and cross-checks orphan data names against active `replicas.longhorn.io` objects.

It highlights whether each orphan appears to be a cleanup candidate or needs further review:

- `CLEANUP_CANDIDATE_REVIEW_REQUIRED`
- `DO_NOT_DELETE_MANAGED_OVERLAP`
- `REVIEW_NON_REPLICA_ORPHAN`
- `REVIEW_NOT_CLEANABLE`
- `REVIEW_ERROR_CONDITION`

Usage:

```bash
./kubernetes/longhorn/longhorn-orphan-report.sh --context example-rke2
./kubernetes/longhorn/longhorn-orphan-report.sh --output json
```

This script does not delete Orphan CRs. It is intended to support evidence review before any cleanup.

## `longhorn-pvc-ownership-audit.sh`

Inspects Kubernetes and Longhorn ownership signals for a PVC before considering cleanup.

It checks:

- PVC and PV metadata
- reclaim policy
- Longhorn volume state and robustness
- managed Longhorn replicas
- Pod references
- direct workload references
- StatefulSet `volumeClaimTemplates`
- owner references
- Helm release labels or annotations

Usage:

```bash
./kubernetes/longhorn/longhorn-pvc-ownership-audit.sh \
  --context example-rke2 \
  --namespace example-logs \
  --pvc export-0-example-0

./kubernetes/longhorn/longhorn-pvc-ownership-audit.sh --all-unused --output json
```

Classifications include:

| Classification | Meaning |
| --- | --- |
| `IN_USE` | Referenced by an existing Pod PVC volume. |
| `IN_USE_OR_RETAIN` | Referenced directly by a workload template. |
| `STATEFULSET_DATA_RETAIN` | PVC name matches a current StatefulSet volumeClaimTemplate pattern. |
| `UNOWNED_CANDIDATE` | No obvious Kubernetes owner was found; human review is still required. |
| `REVIEW` | Signals are inconclusive. |

## `longhorn-maintenance-gate-report.sh`

Reports read-only Longhorn gates before storage-node maintenance.

It summarizes:

- attached volume robustness
- running replica count and distinct replica-node count
- Longhorn node readiness
- non-running Longhorn pods
- an overall `REVIEW_READY` or `REVIEW_BLOCKED` maintenance gate

Usage:

```bash
./kubernetes/longhorn/longhorn-maintenance-gate-report.sh --context example-rke2
./kubernetes/longhorn/longhorn-maintenance-gate-report.sh --output json
./kubernetes/longhorn/longhorn-maintenance-gate-report.sh --output summary
```

This script does not approve node maintenance. It collects the evidence an operator should review before power-cycling, rebooting, draining, or otherwise disrupting a Longhorn storage node.

## `longhorn-storageclass-health-report.sh`

Reports health signals for PVCs that use Longhorn storage classes.

It correlates:

- PVCs using storage classes with the Longhorn CSI provisioner
- bound PVs
- Longhorn volume state and robustness
- expected, running, and non-running replicas
- replica node placement
- related Kubernetes warning events

Usage:

```bash
./kubernetes/longhorn/longhorn-storageclass-health-report.sh --context example-rke2
./kubernetes/longhorn/longhorn-storageclass-health-report.sh --namespace example-app --output json
./kubernetes/longhorn/longhorn-storageclass-health-report.sh --output summary
```

This script is intended for readiness and storage-health review when workloads use the Longhorn storage class. It does not repair, detach, attach, delete, expand, or modify any Kubernetes or Longhorn object.

### Local Fixture Capture And Replay

Operators can capture a local fixture from a cluster issue and replay the report against a fake `kubectl` without repeatedly querying the cluster.

Capture read-only JSON from a live cluster:

```bash
tests/kubernetes/longhorn/capture-longhorn-storageclass-health-fixture.sh \
  --context example-rke2 \
  --namespace example-app
```

The default output path is under `reports/fixtures/`, which is ignored by git.

Replay the captured fixture through a temporary fake `kubectl`:

```bash
tests/kubernetes/longhorn/run-longhorn-storageclass-health-fixture.sh \
  --fixture-dir reports/fixtures/longhorn-storageclass-health-YYYYMMDDTHHMMSSZ \
  --output json
```

Captured fixture files can contain real cluster names, namespaces, workload names, node names, labels, annotations, event messages, topology, IPs, domains, and storage details. Do not commit captured fixtures as-is. Minimize and sanitize them before turning a cluster issue into a permanent test case.

Sanitize a captured fixture before preparing a commit-ready test case:

```bash
tests/kubernetes/longhorn/sanitize-longhorn-storageclass-health-fixture.sh \
  --input-dir reports/fixtures/longhorn-storageclass-health-YYYYMMDDTHHMMSSZ \
  --output-dir reports/fixtures/longhorn-storageclass-health-sanitized
```

The sanitizer replaces namespaces, PVCs, PVs, Longhorn volumes, replicas, nodes, and event messages with neutral example values while preserving the relationships used by the report. It also replaces common metadata such as labels, annotations, UIDs, resource versions, owner references, and managed fields with neutral mocked values so future tests can exercise metadata-dependent logic.

Sanitization is a review aid, not a publication guarantee. Review the output before copying any sanitized fixture into `tests/fixtures/`.

## Exit Codes

- `0`: report completed successfully
- `1`: dependency or runtime failure
- `2`: invalid arguments

## Limitations

- These scripts require live Kubernetes API access.
- `--all-unused` means not referenced by current Pod `persistentVolumeClaim` volumes. It does not prove a PVC is disposable.
- StatefulSet template matching is name-pattern based and should be reviewed by an operator.
- Custom operators may reference storage indirectly in ways that require additional application knowledge.
- No script validates business ownership or data retention requirements.
