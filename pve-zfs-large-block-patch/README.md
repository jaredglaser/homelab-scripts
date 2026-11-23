# pve-zfs-large-block-patch

Proxmox VE replicates ZFS datasets with `zfs send` but without `-L` (`--large-block`). This script adds `-L` to that call in `/usr/share/perl5/PVE/Storage/ZFSPoolPlugin.pm`, and an apt hook runs it again after every package update, because each update of `libpve-storage-perl` puts the upstream file back. Before changing the file it saves a copy in `/var/backups/pve-zfs-L-patch/`.

> [!WARNING]
> This patches a Proxmox-managed file. Read `pve-zfs-large-block-patch.sh` before installing it on a production node.

## Why -L matters

Without `-L`, datasets with `recordsize` above 128K (1M is common for media storage) are sent in 128K pieces. Once a replication chain has been started with `-L`, every later incremental must use it too. So when an update reverts the patch, the next replication fails with:

```
cannot receive incremental stream: incremental send stream requires -L (--large-block), to match previous receive.
```

The same error appears when you migrate a guest and replicate back to the node it came from. Datasets that never had `recordsize` above 128K are not affected.

## Install

Run as root on each Proxmox node:

```bash
curl -fsSL https://raw.githubusercontent.com/jaredglaser/homelab-scripts/main/pve-zfs-large-block-patch/install.sh | bash
```

This installs the script to `/usr/local/sbin/pve-zfs-large-block-patch.sh`, adds the apt hook `/etc/apt/apt.conf.d/99-pve-zfs-large-block-patch`, and patches the file once. Run it again to update the script.

<details>
<summary>Manual install</summary>

```bash
curl -fsSL -o /usr/local/sbin/pve-zfs-large-block-patch.sh \
    https://raw.githubusercontent.com/jaredglaser/homelab-scripts/main/pve-zfs-large-block-patch/pve-zfs-large-block-patch.sh
chmod +x /usr/local/sbin/pve-zfs-large-block-patch.sh

cat > /etc/apt/apt.conf.d/99-pve-zfs-large-block-patch <<'EOF'
DPkg::Post-Invoke {
    "/usr/local/sbin/pve-zfs-large-block-patch.sh || true";
};
EOF

/usr/local/sbin/pve-zfs-large-block-patch.sh
```

`|| true` keeps a failed patch from making apt exit with an error after every package has already installed. It also means apt's exit status says nothing about the patch; the log does.

</details>

No service restart is needed. Replication and migration start a new `pvesm export` process for each send, and it reads the patched file.

## Check it works

Run the script. It reports the current state and patches the file if needed:

```bash
/usr/local/sbin/pve-zfs-large-block-patch.sh
```

To check that the hook re-patches after an update, reinstall the version you already have. The output should end with an `APPLIED` line:

```bash
apt-get install --reinstall "libpve-storage-perl=$(dpkg-query -W -f='${Version}' libpve-storage-perl)"
```

Name the version as shown: a plain `--reinstall` upgrades the package when a newer one is available.

Every re-patch and every failure is logged:

```bash
journalctl -t pve-zfs-L-patch
```

The hook only runs from apt. After `dpkg -i`, run the script by hand, or let the next apt run catch it. If the script is missing or not executable, apt shows a shell error and nothing is logged.

## Messages

| Message | Meaning | What to do |
| --- | --- | --- |
| `OK` | Already patched. | Nothing. |
| `APPLIED` | Patched now, backup named in the message. | Nothing. |
| `NOT INSTALLED` | No `libpve-storage-perl` and no file. | If this node no longer runs Proxmox VE, uninstall. |
| `WARNING` | Upstream changed the file in a way the script does not know. It changes nothing, or patches the known call and lists the other send call it found without `-L`. | Replication of large-record datasets may be broken. Check this repository for an updated script before editing the file by hand. |
| `FAILED` | Something stopped the patch: the message gives the cause, such as a full disk or a read-only file. | Fix the cause and run the script again. The file is unchanged unless the message names a backup to restore. |

`WARNING` and `FAILED` exit 1 and are logged at `daemon.err`. Because of `|| true`, apt still succeeds, so check the log after updates.

## Uninstall and restore

```bash
curl -fsSL https://raw.githubusercontent.com/jaredglaser/homelab-scripts/main/pve-zfs-large-block-patch/install.sh | bash -s -- --uninstall
```

This removes the hook first, then the script. The patched file and the backups stay. To put the upstream file back, reinstall the installed version:

```bash
apt-get install --reinstall "libpve-storage-perl=$(dpkg-query -W -f='${Version}' libpve-storage-perl)"
```

To restore one specific backup instead, remove the hook first, otherwise the next apt run patches the file again:

```bash
rm /etc/apt/apt.conf.d/99-pve-zfs-large-block-patch
cp /var/backups/pve-zfs-L-patch/ZFSPoolPlugin.pm.prepatch.<timestamp>.<pid> /usr/share/perl5/PVE/Storage/ZFSPoolPlugin.pm
```

<details>
<summary>Manual uninstall</summary>

```bash
rm /etc/apt/apt.conf.d/99-pve-zfs-large-block-patch
rm /usr/local/sbin/pve-zfs-large-block-patch.sh
rm -r /var/backups/pve-zfs-L-patch   # optional, once you no longer need the backups
```

</details>

## Tests

From the repo root: `bats pve-zfs-large-block-patch/tests/`. See [tests/README.md](tests/README.md).
