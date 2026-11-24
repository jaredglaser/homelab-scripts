# pve-zfs-large-block-patch

Proxmox VE replicates ZFS datasets with `zfs send` but without `-L` (`--large-block`). This script adds `-L` to that call in `/usr/share/perl5/PVE/Storage/ZFSPoolPlugin.pm`, and an apt hook reruns it after every update, because each `libpve-storage-perl` update restores the upstream file. It backs the file up to `/var/backups/pve-zfs-L-patch/` first.

> [!WARNING]
> This patches a Proxmox-managed file. Read `pve-zfs-large-block-patch.sh` before installing it on a production node.

## Why -L matters

Without `-L`, datasets with `recordsize` above 128K (1M is common for media) are sent in 128K pieces. Once a replication chain has been started with `-L`, every later incremental must use it too. So when an update reverts the patch, the next replication fails with:

```
cannot receive incremental stream: incremental send stream requires -L (--large-block), to match previous receive.
```

The same error appears when you migrate a guest and replicate back to the node it came from. Datasets that never had `recordsize` above 128K are not affected.

## Install

Run as root on each Proxmox node:

```bash
curl -fsSL https://raw.githubusercontent.com/jaredglaser/homelab-scripts/main/pve-zfs-large-block-patch/install.sh | bash
```

This installs the script to `/usr/local/sbin/pve-zfs-large-block-patch.sh` and the apt hook to `/etc/apt/apt.conf.d/99-pve-zfs-large-block-patch`, then patches once. Run it again to update, also over a manual install.

<details>
<summary>Manual install</summary>

```bash
curl -fsSL -o /usr/local/sbin/pve-zfs-large-block-patch.sh \
    https://raw.githubusercontent.com/jaredglaser/homelab-scripts/main/pve-zfs-large-block-patch/pve-zfs-large-block-patch.sh
chmod +x /usr/local/sbin/pve-zfs-large-block-patch.sh

cat > /etc/apt/apt.conf.d/99-pve-zfs-large-block-patch <<'EOF'
DPkg::Post-Invoke {
    "/usr/local/sbin/pve-zfs-large-block-patch.sh || { rc=$?; case $rc in 126|127) logger -p daemon.err -t pve-zfs-L-patch -- '/usr/local/sbin/pve-zfs-large-block-patch.sh could not run, so the -L patch was not checked. Run the installer again.' ;; *) [ $rc -le 128 ] || logger -p daemon.err -t pve-zfs-L-patch -- '/usr/local/sbin/pve-zfs-large-block-patch.sh was stopped by signal '$((rc - 128))' and may not have finished.' ;; esac; }; true";
};
EOF

/usr/local/sbin/pve-zfs-large-block-patch.sh
```

The hook logs a script that could not start or was killed, and ends with `true` so a failed patch does not fail apt after the packages are installed. Check the log, not apt's exit status.

</details>

No service restart is needed: Proxmox storage migration runs each send in a new `pvesm export` process, which loads the patched file.

## Check it works

Run the script. It reports the state and patches if needed:

```bash
/usr/local/sbin/pve-zfs-large-block-patch.sh
```

To check the hook, reinstall the installed version. The output should end with `APPLIED`:

```bash
apt-get install --reinstall "libpve-storage-perl=$(dpkg-query -W -f='${Version}' libpve-storage-perl)"
```

Name the version as shown: a plain `--reinstall` upgrades the package when a newer one is available.

Every re-patch and every failure is logged:

```bash
journalctl -t pve-zfs-L-patch
```

The hook only runs from apt. After `dpkg -i`, run the script by hand or let the next apt run catch it. If the script is missing, not executable or killed, apt shows a shell error and the hook logs it.

## Messages

| Message | Meaning | What to do |
| --- | --- | --- |
| `OK` | Already patched. | Nothing. |
| `APPLIED` | Patched now, backup named in the message. | Nothing. |
| `NOT INSTALLED` | No `libpve-storage-perl` and no file. | If this node no longer runs Proxmox VE, uninstall. |
| `WARNING` | Upstream changed the send call, or added another one. A known call is still patched. | Large-record replication may be broken. Check here for an updated script before editing the file. |
| `FAILED` | Something stopped the patch, such as a full disk or a read-only filesystem. The message gives the cause. | Fix it and rerun. The file is unchanged unless the message names a backup to restore. |

`WARNING` and `FAILED` exit 1 and are logged at `daemon.err`. `OK` and `APPLIED` mean the known call has `-L` and no other `'zfs', 'send'` list is in the file. A send command built another way, such as `qw(zfs send)` or a string, is not detected.

## Uninstall and restore

```bash
curl -fsSL https://raw.githubusercontent.com/jaredglaser/homelab-scripts/main/pve-zfs-large-block-patch/install.sh | bash -s -- --uninstall
```

This removes the hook, then the script. The patched file and backups stay. To restore the upstream file, reinstall the installed version. Replication of datasets already sent with `-L` then fails, as described above:

```bash
apt-get install --reinstall "libpve-storage-perl=$(dpkg-query -W -f='${Version}' libpve-storage-perl)"
```

To restore a backup instead, pick the newest. Backups are never deleted. Remove the hook first, or the next apt run patches again:

```bash
rm /etc/apt/apt.conf.d/99-pve-zfs-large-block-patch   # only after a manual install
cp /var/backups/pve-zfs-L-patch/ZFSPoolPlugin.pm.prepatch.<timestamp>.<pid> /usr/share/perl5/PVE/Storage/ZFSPoolPlugin.pm
```

<details>
<summary>Manual uninstall</summary>

```bash
rm /etc/apt/apt.conf.d/99-pve-zfs-large-block-patch
rm /usr/local/sbin/pve-zfs-large-block-patch.sh
rm -r /var/backups/pve-zfs-L-patch   # optional
```

</details>

## Tests

See [tests/README.md](tests/README.md).
