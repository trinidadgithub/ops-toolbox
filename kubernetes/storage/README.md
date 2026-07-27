# Kubernetes Storage Utilities

Read-only utilities for Kubernetes storage troubleshooting.

These tools inspect Kubernetes API state and do not modify PVCs, PVs, StorageClasses, workloads, or storage backend resources.

## Requirements

- `bash`
- `kubectl`
- `jq`
- Optional: `column` for aligned table output

## `pvc-resize-audit.sh`

Reports PVC resize and expansion signals from one Kubernetes context or all configured contexts.

The utility highlights:

- PVCs with `FileSystemResizePending` or `Resizing` conditions
- PVCs where requested storage and reported capacity differ
- StorageClass `allowVolumeExpansion` values
- PV capacity and reclaim policy for matched claims
- Recent resize-related events
- Optional Longhorn volume health signals when Longhorn CRDs are installed

## Usage

```bash
./kubernetes/storage/pvc-resize-audit.sh --context example-rke2
./kubernetes/storage/pvc-resize-audit.sh --all-contexts --output csv
./kubernetes/storage/pvc-resize-audit.sh --namespace example-app --include-events
./kubernetes/storage/pvc-resize-audit.sh --include-longhorn --output json
```

## Output Modes

- `table`: human-readable aligned output
- `csv`: one row per finding
- `json`: machine-readable findings array

## Exit Codes

- `0`: audit completed successfully
- `1`: dependency or Kubernetes API query failure
- `2`: invalid arguments

## Safety

This utility is read-only. It does not resize volumes, patch PVCs, restart pods, or inspect node filesystems.

## Limitations

- A request/capacity mismatch is a signal for review, not proof of failure.
- Event retention depends on the target cluster.
- Backend-specific expansion behavior varies by CSI driver.
- Longhorn checks are optional and only run when requested.
