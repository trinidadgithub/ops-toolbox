# Kubernetes Node Utilities

Read-only utilities for Kubernetes node maintenance planning and evidence review.

These tools inspect Kubernetes API state and do not cordon, uncordon, drain, reboot, delete pods, patch workloads, or modify cluster state.

## Requirements

- `bash`
- `kubectl`
- `jq`
- Optional: `column` for aligned table output

## `k8s-node-maintenance-gate-report.sh`

Reports node-level maintenance gates from one Kubernetes context or all configured contexts.

The utility highlights:

- node Ready state
- existing cordon state
- taint count
- node pressure conditions
- NetworkUnavailable condition
- unhealthy pods currently assigned to each node
- node warning events
- cluster-level PDBs with zero allowed disruptions
- kubelet version, kernel version, boot ID, and Ready transition time

## Usage

```bash
./kubernetes/nodes/k8s-node-maintenance-gate-report.sh --context example-rke2
./kubernetes/nodes/k8s-node-maintenance-gate-report.sh --all-contexts --output summary
./kubernetes/nodes/k8s-node-maintenance-gate-report.sh --output json
```

## Gates

- `REVIEW_READY`: no obvious node-level blocker was found.
- `REVIEW_ALREADY_CORDONED`: the node is already unschedulable and needs review before maintenance assumptions are made.
- `REVIEW_UNHEALTHY_PODS`: unhealthy pods are already assigned to the node.
- `BLOCK_NOT_READY`: the node is not Ready.
- `BLOCK_NODE_PRESSURE`: memory, disk, or PID pressure is active.
- `BLOCK_NETWORK_UNAVAILABLE`: the node reports network unavailable.

## Safety

This utility is read-only. It does not perform maintenance. The output is a review aid, not approval to reboot or power-cycle a node.

## Limitations

- PDB reporting is cluster-level and intentionally conservative.
- Event retention depends on the target cluster.
- A `REVIEW_READY` gate does not prove workloads are safe to disrupt. It only means the checked node-level signals did not show an obvious blocker.
