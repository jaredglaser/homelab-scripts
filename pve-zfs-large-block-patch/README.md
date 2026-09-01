# pve-zfs-large-block-patch

Keeps the `-L` (`--large-block`) flag present in Proxmox VE's `zfs send` call inside `/usr/share/perl5/PVE/Storage/ZFSPoolPlugin.pm`. The file ships in `libpve-storage-perl` and upstream sends without `-L` (`-RpvU` since 9.1.3, `-Rpv` before that), so any update of that package overwrites a manually patched copy. This script re-applies the patch automatically from an apt post-invoke hook.

The script is idempotent. It backs up the file to `/var/backups/pve-zfs-L-patch/` before changing anything, and refuses to patch at all if that backup cannot be written. After patching it confirms no unpatched send site remains, so a partial write is caught.

The apt hook discards the exit code by design (see Install), so failures are also sent to syslog. That is a record, not an alarm: nothing alerts on it, but it dates the failure, which re-running the script cannot do. To find out when the patch stopped applying:

```bash
journalctl -t pve-zfs-L-patch
```

To find out whether it applies right now, run the script. It is idempotent and reports current state.

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

2. Register it as an apt post-invoke hook so it runs after every dpkg invocation:

   ```bash
   cat > /etc/apt/apt.conf.d/99-pve-zfs-large-block-patch <<'EOF'
   DPkg::Post-Invoke {
       "/usr/local/sbin/pve-zfs-large-block-patch.sh || true";
   };
   EOF
   ```

   The `|| true` guard is intentional: without it, a script that exits 1 would abort the surrounding `apt` run. It does mean apt reports success even when the patch failed, which is why failures also go to syslog. Do not treat apt's exit code as evidence the patch applied.

3. Apply the patch immediately to confirm it works against the current state of the file:

   ```bash
   /usr/local/sbin/pve-zfs-large-block-patch.sh
   ```

   All output goes to stderr. Expected output is one of:

   - `OK - patch already present in ... (no changes needed)` if the file is already patched. Exits 0.
   - `APPLIED - patched ... to add -L flag (backup: ...)` on first run. Exits 0.
   - `NOT INSTALLED - libpve-storage-perl is absent ...` if the package and the file are both missing. This node has no reason to run the patch, so the message lists the script and the hook file to remove. Exits 0.
   - `WARNING - libpve-storage-perl is <state> but ... is missing` if the package is present but the file is not. `<state>` is the dpkg state, so it reads `installed`, `half-installed`, `unpacked` and so on. Upstream may have moved the file, and replication of >128K recordsize datasets may be silently broken. Exits 1.
   - `WARNING - ... does not contain expected pattern` if upstream restructured the send call beyond what the patch knows how to handle. Exits 1.
   - `FAILED - ...` for anything the script refuses to act on: an unreadable file, a backup that cannot be written, a broken symlink, a target that is not a regular file, or a `dpkg-query` that failed outright. A query reporting the package as absent is not a failure. The file is left untouched. Exits 1.

## Verify the hook re-applies after an update

Package updates revert the file to upstream. To confirm the apt hook will catch this without waiting for a real Proxmox update, reinstall the package that owns the file:

```bash
apt-get install --reinstall libpve-storage-perl
```

The reinstall unpacks the upstream copy of `ZFSPoolPlugin.pm` (the same revert a real upgrade would do), and the `DPkg::Post-Invoke` hook then fires and re-patches it. A successful run ends with the `APPLIED` line, after the trigger processing:

```
0 upgraded, 0 newly installed, 1 reinstalled, 0 to remove and 0 not upgraded.
...
Preparing to unpack .../libpve-storage-perl_9.1.5_all.deb ...
Unpacking libpve-storage-perl (9.1.5) over (9.1.5) ...
Setting up libpve-storage-perl (9.1.5) ...
Processing triggers for pve-manager (9.1.9) ...
Processing triggers for man-db (2.13.1-1) ...
Processing triggers for pve-ha-manager (5.2.0) ...
[pve-zfs-L-patch] APPLIED - patched /usr/share/perl5/PVE/Storage/ZFSPoolPlugin.pm to add -L flag (backup: /var/backups/pve-zfs-L-patch/ZFSPoolPlugin.pm.prepatch.<timestamp>.<pid>)
```

Then confirm the file actually has the `-L` flag now:

```bash
grep -F "send" /usr/share/perl5/PVE/Storage/ZFSPoolPlugin.pm | grep -F "'zfs'"
```

You should see `-RpvUL` on 9.1.3+ or `-RpvL` on older releases. Upstream added `-U` (`--no-preserve-encryption`) in `libpve-storage-perl` 9.1.3.

> [!NOTE]
> `apt update` only refreshes package indexes and does not invoke dpkg, so it does not trigger `DPkg::Post-Invoke`. Use a dpkg-invoking operation (`apt-get install`, `apt-get upgrade`, `apt-get install --reinstall ...`) when testing.

## Recovery

To restore the upstream copy of `ZFSPoolPlugin.pm` (no `-L` flag), first disable the apt hook so it cannot re-patch on the next dpkg operation:

```bash
rm /etc/apt/apt.conf.d/99-pve-zfs-large-block-patch
```

Or comment out the `DPkg::Post-Invoke` block inside it if you want to keep the file around for reference.

Then restore the file. Two options:

- **Reinstall `libpve-storage-perl`** to get the current upstream `ZFSPoolPlugin.pm`:

  ```bash
  apt-get install --reinstall libpve-storage-perl
  ```

  Simplest for a clean rollback, and includes any package-level changes that have shipped since the patch was first applied.

- **Restore a specific timestamped backup** from `/var/backups/pve-zfs-L-patch/` if you need the exact pre-patch byte image from a particular run (for example, to bisect a regression introduced by a later package update). Backups are named `<timestamp>.<pid>` and are only written once verified against the original:

  ```bash
  cp /var/backups/pve-zfs-L-patch/ZFSPoolPlugin.pm.prepatch.<timestamp>.<pid> \
     /usr/share/perl5/PVE/Storage/ZFSPoolPlugin.pm
  ```

## Tests

```bash
bats pve-zfs-large-block-patch/tests/
```

Run from the repo root. The suite drives the script through two environment overrides so it never touches real paths:

| Variable | Default |
| --- | --- |
| `PVE_ZFS_PATCH_FILE_OVERRIDE` | `/usr/share/perl5/PVE/Storage/ZFSPoolPlugin.pm` |
| `PVE_ZFS_PATCH_BACKUP_DIR_OVERRIDE` | `/var/backups/pve-zfs-L-patch` |

The fixtures under `tests/fixtures/` are a verbatim excerpt of upstream `ZFSPoolPlugin.pm` (`pve-storage.git`, lines 845-872 as of 9.1.10), so the patch is exercised against real surrounding code. Re-cut them from upstream when the send flags change.

Production behavior is unchanged when they are unset. `dpkg-query` and `logger` are stubbed on PATH; `dpkg --compare-versions` is not, so the real Debian version ordering is exercised.
