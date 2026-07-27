# Linux System Utilities

## `node-triage-bundle.sh`

Collects a read-only Linux node triage bundle for post-incident review.

The utility gathers host metadata, boot history, resource snapshots, recent journal messages, kernel messages, and a red-flag summary. Optional flags collect network state and RKE2 service logs.

Generated bundles may contain sensitive hostnames, usernames, IP addresses, process names, kernel messages, service logs, and local filesystem paths. Do not publish generated bundles without review.

## Requirements

- `bash`
- Common Linux tools: `date`, `hostname`, `uname`, `df`, `free`, `ps`, `tar`
- Optional tools improve output: `hostnamectl`, `uptime`, `who`, `last`, `journalctl`, `dmesg`, `ip`, `ss`, `systemctl`

## Usage

```bash
./linux/system/node-triage-bundle.sh
./linux/system/node-triage-bundle.sh --include-network
./linux/system/node-triage-bundle.sh --include-rke2 --since "12 hours ago"
./linux/system/node-triage-bundle.sh --output-dir reports/node-triage --prefix worker-01
./linux/system/node-triage-bundle.sh --no-archive
```

## Output

By default, the utility creates a timestamped directory under `reports/node-triage/` and archives it as `*.tar.gz`.

Typical files include:

- `collector.log`
- `host.txt`
- `boot.txt`
- `resources.txt`
- `journal-recent.txt`
- `kernel-ring-buffer.txt`
- `red-flags.txt`
- `network.txt` when `--include-network` is set
- `rke2-services.txt` and `rke2-recent.txt` when `--include-rke2` is set

## Exit Codes

- `0`: bundle created successfully
- `1`: required dependency or archive creation failed
- `2`: invalid arguments

## Safety

This utility is read-only. It does not restart services, modify configuration, delete files, or change cluster state.

Some commands may return partial output unless run with elevated privileges.

## Limitations

- The bundle is a point-in-time collector, not a root-cause analysis engine.
- Recent journal output depends on host journald retention.
- Kernel logs may require elevated privileges on hardened systems.
- RKE2 collection only checks local systemd service names and does not query Kubernetes.
