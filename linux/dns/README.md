# Linux DNS Utilities

## `dns-search-drift-detector.sh`

Audits DNS search-domain configuration on the local host or on remote hosts over SSH.

The utility is read-only. It checks `/etc/resolv.conf`, `resolvectl domain`, and netplan search-domain entries when available.

### Requirements

- `bash`
- `ssh` for remote checks
- Optional remote commands: `resolvectl`, `readlink`, `grep`

### Usage

```bash
./linux/dns/dns-search-drift-detector.sh --expected none
./linux/dns/dns-search-drift-detector.sh --hosts hosts.txt --ssh-user ops --expected none --output csv
./linux/dns/dns-search-drift-detector.sh --host worker-01.example.com --expected example.com
```

`--expected none` means no DNS search domains are expected.

### Exit Codes

- `0`: audit completed and no drift was found
- `1`: audit completed and drift was found, or a host was unreachable
- `2`: invalid arguments

### Limitations

This utility reports observed DNS search-domain state. It does not modify resolver, netplan, or systemd-resolved configuration.
