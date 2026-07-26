# Kubernetes Workload Utilities

## `k8s-unhealthy-pods.sh`

Reports pods that are not healthy from one Kubernetes context or all configured contexts.

The utility is read-only. It runs `kubectl get pods` and does not modify cluster state.

### Purpose

Quickly identify pods that need operator attention without opening a full dashboard or inspecting every namespace manually.

### Why

Operators often need a compact answer to: which pods are not healthy, where are they running, and what status reason is Kubernetes currently reporting?

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
./kubernetes/workloads/k8s-unhealthy-pods.sh --include-succeeded
```

By default, `Succeeded` pods are excluded because completed Jobs are usually not operationally unhealthy. Use `--include-succeeded` when completed pods are relevant to the investigation.

### Output

Table output is the default:

```text
CONTEXT      NAMESPACE      POD                       NODE       PHASE    READY  REASONS
lab-cluster  example-app    api-pending-6b7c9                    Pending  0/0
lab-cluster  example-app    worker-crashloop-55c8d    worker-02  Running  0/1    CrashLoopBackOff
lab-cluster  example-batch  import-failed-28499100    worker-03  Failed   0/1    Error
```

CSV and JSON output are available for automation:

```bash
./kubernetes/workloads/k8s-unhealthy-pods.sh --output csv
./kubernetes/workloads/k8s-unhealthy-pods.sh --output json
```

### Safety

- Reads pod status through the Kubernetes API.
- Does not patch, delete, restart, scale, cordon, uncordon, drain, or otherwise modify anything.
- Requires only enough Kubernetes permission to list pods in the requested namespace scope.

### Exit Codes

- `0`: command completed successfully
- `1`: dependency or kubectl query failure
- `2`: invalid arguments

### Testing

Fixture-based tests do not require a live Kubernetes cluster:

```bash
./tests/kubernetes/workloads/test-k8s-unhealthy-pods.sh
```

Validation targets:

- `bash -n kubernetes/workloads/k8s-unhealthy-pods.sh`
- `shellcheck kubernetes/workloads/k8s-unhealthy-pods.sh`
- fixture test above

### Limitations

This script reports pod phase and waiting/terminated container reasons. It does not diagnose root cause, inspect events, read logs, evaluate probes directly, or guarantee that every workload-level failure mode is visible from pod status alone.

### Publication Assessment

- Security: uses synthetic documentation and fixture data; no credentials or internal environment details are required.
- Ownership: `B - Work-Inspired Technique`; implementation is generic and should remain clean-room.
- Safety: read-only diagnostic utility.
- Testing: shell syntax, ShellCheck, and fixture-based tests are expected before publication.
- Status: `READY WITH CHANGES` until this branch is reviewed and merged.
