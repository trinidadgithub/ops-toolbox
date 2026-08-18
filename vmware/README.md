# VMware Utilities

Read-only utilities for VMware and vSphere operational inspection.

These tools depend on externally configured VMware access. Do not commit credentials, real inventory paths, or exported environment files.

## Requirements

- `bash`
- `govc`
- `jq`
- Optional: `column` for aligned table output

Configure `govc` using environment variables or another secure local method before running these utilities. Typical variables include `GOVC_URL`, `GOVC_USERNAME`, `GOVC_PASSWORD`, and `GOVC_DATACENTER`.

## `vm-cdrom-report.sh`

Reports virtual CD/DVD devices for VMs discovered through one or more vSphere inventory scopes.

Use it before VM maintenance to find stale virtual media and to separate read-only inventory review from any later change window.

```bash
./vmware/vm-cdrom-report.sh --scope "/Example-Datacenter/vm/example-folder"
./vmware/vm-cdrom-report.sh --scope "/Example-Datacenter/vm/example-folder" --only-connected
./vmware/vm-cdrom-report.sh --all-vms --datacenter Example-Datacenter --output csv
```

The utility is read-only. It runs `govc find` and `govc device.info`; it does not eject, disconnect, remove, add, or modify VM devices.

## `vm-disk-provisioning-report.sh`

Reports virtual disk provisioning mode for VMs discovered through one or more vSphere inventory scopes.

The utility reports:

- inventory scope
- VM name
- disk label
- provisioning mode: `thin`, `thick-lazy`, `thick-eager`, or `unknown`
- datastore name parsed from VMDK path
- VMDK path

## Usage

```bash
./vmware/vm-disk-provisioning-report.sh --scope "/Example-Datacenter/vm/example-folder"
./vmware/vm-disk-provisioning-report.sh --scope "/Example-Datacenter/vm/example-folder" --only-thick
./vmware/vm-disk-provisioning-report.sh --all-vms --datacenter Example-Datacenter --output csv
./vmware/vm-disk-provisioning-report.sh --scope "/Example-Datacenter/vm/example-folder" --output json
```

## Output Modes

- `table`: human-readable aligned output
- `csv`: quoted CSV rows
- `json`: machine-readable findings array

## Exit Codes

- `0`: report completed successfully
- `1`: dependency, `govc`, or runtime failure
- `2`: invalid arguments

## Safety

This utility is read-only. It runs `govc find` and `govc vm.info`; it does not modify VMs, disks, datastores, snapshots, or vCenter inventory.

## Limitations

- The report depends on the permissions available to the configured `govc` identity.
- Large inventory scopes can take time; tune `--parallel` and `--timeout` conservatively.
- Datastore names and VMDK paths may be sensitive. Review output before sharing.
- The script reports provisioning metadata; it does not calculate guest filesystem usage or datastore free-space risk.
