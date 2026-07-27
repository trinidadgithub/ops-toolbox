# Kubernetes Networking Utilities

Read-only utilities for Kubernetes networking diagnostics.

## Requirements

- `bash`
- `kubectl`
- `tar`

## `kube-proxy-diagnostics.sh`

Collects a local diagnostics bundle for kube-proxy troubleshooting.

The utility captures Kubernetes API evidence such as kube-proxy DaemonSet configuration, pods, describes, current and previous logs, events, nodes, and selected ConfigMaps. It does not modify cluster state.

## Usage

```bash
./kubernetes/networking/kube-proxy-diagnostics.sh --context example-rke2
./kubernetes/networking/kube-proxy-diagnostics.sh --namespace kube-system --since 2h
./kubernetes/networking/kube-proxy-diagnostics.sh --include-cni --no-archive
./kubernetes/networking/kube-proxy-diagnostics.sh --output-dir reports/kube-proxy
```

## Output

By default, output is written under `reports/kube-proxy/` and archived as `*.tar.gz`.

Generated bundles may contain hostnames, node names, pod names, service names, IP addresses, events, and logs. Review before sharing.

## Exit Codes

- `0`: bundle completed successfully
- `1`: dependency or runtime failure
- `2`: invalid arguments

## Safety

This utility is read-only. It does not restart kube-proxy, patch DaemonSets, delete pods, or change networking configuration.

## Limitations

- Log availability depends on pod retention and container runtime state.
- Previous logs may be unavailable if containers have not restarted.
- CNI collection is best-effort and limited to API-visible resources.
