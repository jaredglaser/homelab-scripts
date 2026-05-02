# pve-zfs-large-block-patch

Keeps the `-L` (`--large-block`) flag present in Proxmox VE's `zfs send` call inside `/usr/share/perl5/PVE/Storage/ZFSPoolPlugin.pm`. Upstream Proxmox ships this file with `zfs send -Rpv` (no `-L`), and any `pve-manager` (or related) package update overwrites a manually patched copy. This script re-applies the patch automatically from an apt post-invoke hook.

The script is idempotent. It backs up the file to `/var/backups/pve-zfs-L-patch/` before changing anything and exits non-zero only if the upstream file has been restructured beyond what the patch knows how to handle.

> [!WARNING]
> This patches a Proxmox-managed file. Read `pve-zfs-large-block-patch.sh` before installing it on a production node so you understand exactly what it does.

## Why -L matters

From the OpenZFS [`zfs-send(8)` man page](https://openzfs.github.io/openzfs-docs/man/master/8/zfs-send.8.html):

> Generate a stream which may contain blocks larger than 128 KiB. This flag has no effect if the **large_blocks** pool feature is disabled, or if the **recordsize** property of this filesystem has never been set above 128 KiB. The receiving system must have the **large_blocks** pool feature enabled as well.

For datasets whose `recordsize` has never been set above 128K, the flag is a no-op. It matters for datasets with `recordsize > 128K`. The 1M recordsize commonly set on media bulk-storage datasets is a typical example.

Once a replication chain has been established with `-L` (the patch was working when replication was first set up), every subsequent incremental in that chain also has to be sent with `-L`. ZFS rejects mixed-mode chains at receive time. This is what happens after a Proxmox update reverts the patch: the next scheduled replication of any affected dataset fails with the error below. The receive-side dataset is fine, the failure is the receiver refusing the new stream because its chain history doesn't match.

```
cannot receive incremental stream: incremental send stream requires -L (--large-block), to match previous receive.
```

The same mismatch breaks replication when migrating a guest to a previously-replicated node and trying to replicate back. The return chain inherits the original direction's mode, so the unpatched PVE on the new source can't produce a stream that the existing receive chain on the old source will accept.

## Install

Run these on the Proxmox node, as root.

1. Download the script and make it executable:

   ```bash
   curl -fsSL -o /usr/local/sbin/pve-zfs-large-block-patch.sh \
       https://raw.githubusercontent.com/jaredglaser/homelab-scripts/main/pve-zfs-large-block-patch/pve-zfs-large-block-patch.sh
   chmod +x /usr/local/sbin/pve-zfs-large-block-patch.sh
   ```

2. Register it as an apt post-invoke hook so it runs after every `dpkg`/`apt` operation:

   ```bash
   cat > /etc/apt/apt.conf.d/99-pve-zfs-large-block-patch <<'EOF'
   DPkg::Post-Invoke {
       "/usr/local/sbin/pve-zfs-large-block-patch.sh || true";
   };
   EOF
   ```

   The `|| true` guard is intentional. If a future Proxmox release restructures `ZFSPoolPlugin.pm` enough that the patch can't find its target, the script exits 1 and prints a warning to stderr. Without `|| true`, that exit code would abort the surrounding `apt` run.

3. Apply the patch immediately to confirm it works against the current state of the file:

   ```bash
   /usr/local/sbin/pve-zfs-large-block-patch.sh
   ```

   Expected output is one of:

   - `OK - patch already present` if the file is already patched.
   - `APPLIED - patched ... to add -L flag (backup: ...)` on first run.

## Verify the hook re-applies after an update

Package updates revert the file to upstream. To confirm the apt hook will catch this without waiting for a real Proxmox update, simulate the revert by stripping the `-L` flag back out:

```bash
sed -i "s/my \$cmd = \['zfs', 'send', '-RpvL'\]/my \$cmd = ['zfs', 'send', '-Rpv']/" \
    /usr/share/perl5/PVE/Storage/ZFSPoolPlugin.pm
```

Then trigger any apt operation, for example:

```bash
apt update
```

The post-invoke hook should fire and print `APPLIED - patched ...`. Confirm with:

```bash
grep -F "'-RpvL'" /usr/share/perl5/PVE/Storage/ZFSPoolPlugin.pm
```

## Recovery

Each `APPLIED` run writes a timestamped backup to `/var/backups/pve-zfs-L-patch/`. To roll back a specific patch run:

```bash
cp /var/backups/pve-zfs-L-patch/ZFSPoolPlugin.pm.prepatch.<timestamp> \
   /usr/share/perl5/PVE/Storage/ZFSPoolPlugin.pm
```

For the rollback to stick, also disable the apt hook. Otherwise the very next `apt`/`dpkg` operation re-applies the patch and undoes your restore. Either remove the file outright:

```bash
rm /etc/apt/apt.conf.d/99-pve-zfs-large-block-patch
```

or comment out the `DPkg::Post-Invoke` block inside it if you want to keep it around for reference.