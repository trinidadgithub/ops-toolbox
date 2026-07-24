# Kubernetes Workload Utilities

## `k8s-unhealthy-pods.sh`

Reports pods that are not healthy from one Kubernetes context or all configured contexts.

The utility is read-only. It runs `kubectl get pods` and does not modify cluster state.

### Requirements

- `bash`
- `kubectl`
- `jq`
- Optional: `column` for aligned table output

### Usage

```bash
./kubernetes/workloads/k8s-unhealthy-pods.sh --context example-rke2
./kubernetes/workloads/k8s-unhealthy-pods.sh --all-contexts --output csv
./kubernetes/workloads/k8s-unhealthy-pods.sh --namespace example-app --output json
```

### Exit Codes

- `0`: command completed successfully
- `1`: dependency or kubectl query failure
- `2`: invalid arguments

### Limitations

This script reports pod phase and waiting/terminated container reasons. It does not diagnose root cause or inspect events.
