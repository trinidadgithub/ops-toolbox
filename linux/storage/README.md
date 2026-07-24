# Linux Storage Utilities

## `linux-storage-report.sh`

Collects a read-only report of Linux storage state, filesystem usage, block devices, LVM state, and top disk consumers.

The utility does not modify disks, filesystems, LVM, or services.

### Requirements

- `bash`
- Standard Linux tools such as `df`, `lsblk`, `du`, and optionally LVM tools

### Usage

```bash
./linux/storage/linux-storage-report.sh
./linux/storage/linux-storage-report.sh --output reports/storage-example.txt
./linux/storage/linux-storage-report.sh --include-rke2 --path /var/lib/rancher/rke2
```

### Exit Codes

- `0`: report generated successfully
- `1`: dependency or runtime failure
- `2`: invalid arguments

### Limitations

Some commands may report partial information when run without elevated privileges.
