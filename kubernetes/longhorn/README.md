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
