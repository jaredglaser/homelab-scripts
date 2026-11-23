# pve-zfs-large-block-patch

Keeps the `-L` (`--large-block`) flag present in Proxmox VE's `zfs send` call inside `/usr/share/perl5/PVE/Storage/ZFSPoolPlugin.pm`. The file ships in `libpve-storage-perl` and upstream sends without `-L` (`-RpvU` since 9.1.3, `-Rpv` before that), so any update of that package overwrites a manually patched copy. This script re-applies the patch automatically from an apt post-invoke hook.

The script only ever rewrites two exact lines, `my $cmd = ['zfs', 'send', '-RpvU']` and `my $cmd = ['zfs', 'send', '-Rpv']`, and picks between them by looking at the file, not at the package version. A line whose first non-blank character is `#` is a comment: a commented-out copy of either line is neither rewritten nor taken as evidence that the file is patched. Before changing anything it copies the file to `/var/backups/pve-zfs-L-patch/`, compares the copy with the original byte for byte, and refuses to patch if the copy cannot be written or does not match. If the newest existing backup already holds the same bytes, it reuses that one instead of writing another.

After patching, and also when it finds the file already patched, it checks every `zfs send` call site in the file and stops with a `WARNING` if any of them sends without `-L`. A call site is `'zfs', 'send'` written as a Perl list (single or double quotes, any spacing), or a quoted string that starts with `zfs send` followed either by the closing quote or by whitespace and a word starting with `-`, `$` or `@` (so `"zfs send -Rpv $snap"` and `"zfs send"` count, while message text such as `"zfs send failed"` or `"zfs send/receive failed"` does not). Lines whose first non-blank character is `#` are skipped, so a commented-out send line is ignored. The site counts as having `-L` when a flag word after it on the same line (a word such as `-RpvUL`), up to the next call site, contains `L`, or when `--large-block` follows it. A site with no flags on its own line, such as one whose flags continue on the next line, counts as missing `-L`. Sites the check flags are reported, never rewritten.

This rule has been checked against three upstream copies of `ZFSPoolPlugin.pm` from `pve-storage.git`: `HEAD` as of 2026-11-23 (`libpve-storage-perl` 9.1.22), commit `c705a2c03f2c` (which added `-U`), and commit `e17a33794c34` (the last change to the file before it). Each has one send site, the script patched it on the first run, reported `OK` on the second, and flagged nothing. Releases after 9.1.22 have not been checked. If the warning appears on a file you have read and found correct (every `zfs send` it runs carries `-L`), the rule has matched something it should not: replication is not affected by that line, but the hook will keep exiting 1 and logging to `daemon.err` on every apt run, so open an issue with the reported line so the rule can be narrowed.

The apt hook discards the exit code by design (see Install), so the script writes to syslog under the tag `pve-zfs-L-patch`: every failure at `daemon.err`, and every re-patch (`APPLIED`) at `daemon.notice`. A run that finds the file already patched, or finds the package absent, logs nothing. That is a record, not an alarm: nothing alerts on it, but it dates each re-patch and each failure, which re-running the script cannot do. To see when the patch was last applied or when it stopped applying:

```bash
journalctl -t pve-zfs-L-patch
```

The record only covers runs that got as far as starting the script. If the script is missing, has lost its execute bit, or sits on a `noexec` mount, the shell prints its error in the apt output, the hook's `|| true` discards the exit code, and nothing reaches syslog.

To find out whether the patch is in place right now, run the script. There is no check-only mode: if the file is unpatched, the run patches it.

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

1. Download the script and make it executable. Read the script first, then set `REV` to the full hash of the commit you read, so a later push to `main` cannot change what you install:

   ```bash
   REV=main   # replace with the commit hash you reviewed
   curl -fsSL -o /usr/local/sbin/pve-zfs-large-block-patch.sh \
       "https://raw.githubusercontent.com/jaredglaser/homelab-scripts/${REV}/pve-zfs-large-block-patch/pve-zfs-large-block-patch.sh"
   chmod +x /usr/local/sbin/pve-zfs-large-block-patch.sh
   ```

2. Register it as an apt post-invoke hook so it runs after every dpkg run that apt drives:

   ```bash
   cat > /etc/apt/apt.conf.d/99-pve-zfs-large-block-patch <<'EOF'
   DPkg::Post-Invoke {
       "/usr/local/sbin/pve-zfs-large-block-patch.sh || true";
   };
   EOF
   ```

   The `|| true` guard is intentional: without it, a script that exits 1 would abort the surrounding `apt` run. It does mean apt reports success even when the patch failed, which is why failures also go to syslog. Do not treat apt's exit code as evidence the patch applied.

   `DPkg::Post-Invoke` is an apt setting. Running `dpkg` directly (`dpkg -i libpve-storage-perl_*.deb`, `dpkg --configure -a`) can replace the file without running the hook, so run the script by hand after doing that.

3. Apply the patch immediately to confirm it works against the current state of the file:

   ```bash
   /usr/local/sbin/pve-zfs-large-block-patch.sh
   ```

   All output goes to stderr. Expected output is one of:

   - `OK - patch already present in ... (no changes needed)` if the file is already patched and every call site has `-L`. Exits 0. Not logged.
   - `APPLIED - patched ... to add -L flag (backup: ...)` when the script rewrote the file, followed by the reload command from step 4. Exits 0. Logged at `daemon.notice`.
   - `NOT INSTALLED - libpve-storage-perl is absent ...` if the file is missing and dpkg has no record of the package or reports it as `not-installed` or `config-files`. This node has no reason to run the patch, so the message lists the script and the hook file to remove. Exits 0. Not logged.
   - `WARNING - libpve-storage-perl is <state> but ... is missing` if the file is missing but the package is present. `<state>` is the dpkg state: `installed`, `half-installed`, `unpacked`, `half-configured`, `triggers-awaited` or `triggers-pending`. Upstream may have moved the file, and replication of >128K recordsize datasets may be silently broken. Exits 1.
   - `WARNING - ... does not contain expected pattern` if the file has neither of the two lines the script rewrites, nor their patched forms, outside comments. The file is left untouched. Exits 1.
   - `WARNING - ... still has a zfs send call without -L (line N)` if the call-site check above finds a site without `-L`. Each such line is listed. When this follows a rewrite, the message says the known send call was patched and names the backup. Exits 1.
   - `FAILED - ...` for anything the script refuses to act on or could not finish: a required command missing, a `dpkg-query` that failed or printed something other than one dpkg status value, a broken symlink, a target that is not a regular file, a read error, a backup directory that cannot be created, a backup copy that fails or does not match the original, a `sed` error, or a file that is not correctly patched after `sed`. A query reporting the package as absent is not a failure. Exits 1.

   Every `FAILED` before the rewrite leaves the file untouched. After a `sed` error the script compares the file with the backup and says either that the file is unchanged or which backup to restore. A failure after the rewrite (the post-patch check, or a read error while checking the result) names the backup to restore.

4. Reload the Proxmox daemons after every `APPLIED`, this first one included:

   ```bash
   systemctl reload-or-try-restart pvedaemon.service pveproxy.service pvescheduler.service
   ```

   Patching the file on disk does not change the code that is already running. `pvescheduler` forks each replication run from the Perl modules it loaded when it started, and `pvedaemon` and `pveproxy` do the same for API calls such as a migration started from the web UI. When `libpve-storage-perl` is upgraded, pve-manager's dpkg trigger reloads these daemons while dpkg is still running, which is before the hook patches the file. So after every re-patch by the hook, replication keeps sending without `-L` until the daemons are reloaded again, and the next replication of a dataset whose chain was started with `-L` fails. The `APPLIED` output repeats this command, and it is the same reload pve-manager runs on each update of its Perl packages.

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
[pve-zfs-L-patch] APPLIED - Running Proxmox daemons still hold the unpatched code. Reload them so replication and migration send with -L:
[pve-zfs-L-patch] APPLIED -   systemctl reload-or-try-restart pvedaemon.service pveproxy.service pvescheduler.service
```

`Processing triggers for pve-manager` is where the daemons were reloaded, with the unpatched file, so run the reload command from Install step 4 now.

The same message is in `journalctl -t pve-zfs-L-patch`. If the reinstalled file is identical to the newest backup, the run says it is reusing that backup and the `APPLIED` line names it.

Then confirm the file actually has the `-L` flag now:

```bash
grep -F "send" /usr/share/perl5/PVE/Storage/ZFSPoolPlugin.pm | grep -F "'zfs'"
```

You should see `-RpvUL` on 9.1.3+ or `-RpvL` on older releases. Upstream added `-U` (`--no-preserve-encryption`) in `libpve-storage-perl` 9.1.3.

> [!NOTE]
> `apt update` only refreshes package indexes and does not invoke dpkg, so it does not trigger `DPkg::Post-Invoke`. Use a dpkg-invoking apt operation (`apt-get install`, `apt-get upgrade`, `apt-get install --reinstall ...`) when testing.

## Recovery

To restore the upstream copy of `ZFSPoolPlugin.pm` (no `-L` flag), first disable the apt hook so it cannot re-patch on the next apt-driven dpkg run:

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

- **Restore a specific timestamped backup** from `/var/backups/pve-zfs-L-patch/` if you need the exact pre-patch byte image from a particular run (for example, to bisect a regression introduced by a later package update). Backups are named `<timestamp>.<pid>`, and each one was compared byte for byte with the file it was copied from before the script patched anything. A run whose file matched the newest backup did not write a new one, so one backup can cover several runs:

  ```bash
  cp /var/backups/pve-zfs-L-patch/ZFSPoolPlugin.pm.prepatch.<timestamp>.<pid> \
     /usr/share/perl5/PVE/Storage/ZFSPoolPlugin.pm
  ```

## Tests

```bash
bats pve-zfs-large-block-patch/tests/
```

Run from the repo root. The suite passes as root and as an unprivileged user. It drives the script through two path overrides, which the script honours only when `PVE_ZFS_PATCH_TESTING=1` is also set. In that mode every run prints a `TEST MODE` line naming the paths in use. Without it the script ignores the overrides, says so, and works on the real paths, so an override left exported in a root shell cannot redirect an apt run.

| Variable | Default |
| --- | --- |
| `PVE_ZFS_PATCH_FILE_OVERRIDE` | `/usr/share/perl5/PVE/Storage/ZFSPoolPlugin.pm` |
| `PVE_ZFS_PATCH_BACKUP_DIR_OVERRIDE` | `/var/backups/pve-zfs-L-patch` |

The fixtures under `tests/fixtures/` are verbatim excerpts of upstream `src/PVE/Storage/ZFSPoolPlugin.pm` from `pve-storage.git`, so the patch is exercised against real surrounding code. `u.pm` is lines 941-968 of `HEAD` as of 2026-11-23 (`libpve-storage-perl` 9.1.22). `plain.pm` is lines 776-803 of commit `e17a33794c34`, the last version of the file before `-U` was added. The `-patched.pm` files are the same excerpts with `L` added to the send flags, the expected results. Re-cut them from upstream when the send flags change.

`tests/bin/` is on `PATH` for every test and holds stubs for `dpkg-query` and `logger`. Both record their full argument lists, so the tests assert the package name, the query format, and the syslog priority and tag. Root ignores file modes, so failures are forced with stubs in `tests/stubs/` instead of `chmod`: a `cp` that writes a partial copy, a `sed` that fails or does nothing, and a `grep` that reports a read error. A test links one in with `with_stub` for that test only. A backup directory whose parent is a regular file covers the `mkdir` failure.
