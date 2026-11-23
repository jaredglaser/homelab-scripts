# Tests

```bash
bats pve-zfs-large-block-patch/tests/
```

Run from the repo root. The suite passes as root and as an unprivileged user.

## Test mode

Both scripts honour path overrides only when `PVE_ZFS_PATCH_TESTING=1` is set, and print `TEST MODE` with the paths in use. Without it they ignore the overrides and say so.

| Variable | Script | Default |
| --- | --- | --- |
| `PVE_ZFS_PATCH_FILE_OVERRIDE` | patch | `/usr/share/perl5/PVE/Storage/ZFSPoolPlugin.pm` |
| `PVE_ZFS_PATCH_BACKUP_DIR_OVERRIDE` | patch | `/var/backups/pve-zfs-L-patch` |
| `PVE_ZFS_PATCH_SCRIPT_OVERRIDE` | install | `/usr/local/sbin/pve-zfs-large-block-patch.sh` |
| `PVE_ZFS_PATCH_HOOK_OVERRIDE` | install | `/etc/apt/apt.conf.d/99-pve-zfs-large-block-patch` |

Two rules keep the suite away from the real files. `setup()` checks that `mktemp -d` worked before exporting the overrides, because empty overrides fall back to the real paths. A test that runs without `PVE_ZFS_PATCH_TESTING=1` must make the script stop before it touches any file.

## Stubs

`bin/` is always on `PATH`: `dpkg-query` and `logger` record their arguments. `stubs/` holds per-test stubs linked in by `with_stub`: `cp`, `sed`, `grep` and `mktemp` that fail on demand (root ignores file modes, so `chmod` cannot force failures), and `curl` and `id` for `install.sh`.

## Fixtures

`fixtures/u.pm` is lines 941-968 of upstream `src/PVE/Storage/ZFSPoolPlugin.pm` at `HEAD` on 2026-11-23 (`libpve-storage-perl` 9.1.23). `plain.pm` is lines 776-803 of commit `e17a33794c34`, the last version before `-U`. The `-patched.pm` files are the expected results. The script was also checked against full copies of those two and of `c705a2c03f2c`, which added `-U`. Re-cut the fixtures when upstream changes the send flags.

## End to end

[e2e/](e2e/README.md) runs the installer and the hook on a stand-in node in Docker with real apt, dpkg and journald. bats does not run it.
