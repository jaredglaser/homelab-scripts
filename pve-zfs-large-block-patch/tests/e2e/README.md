# End-to-end check for pve-zfs-large-block-patch

Runs the script the way an operator lives with it: installed per the README, fired by a real apt `DPkg::Post-Invoke` hook, against real `libpve-storage-perl` packages served by a local apt repository, with journald collecting its syslog lines. The bats suite in `tests/` does not run this; it needs Docker, root and network access.

```bash
pve-zfs-large-block-patch/tests/e2e/run.sh              # this working tree's script
REV=<full commit hash> pve-zfs-large-block-patch/tests/e2e/run.sh   # the README's curl at that commit
KEEP=1 pve-zfs-large-block-patch/tests/e2e/run.sh       # leave the container up afterwards
```

It prints `PASS` or `FAIL` per check, exits 1 if any failed, and names a directory holding each step's command and full output. Behind an HTTPS proxy, export `https_proxy` and set `E2E_CA_BUNDLE` to the proxy's CA file.

## The stand-in node

- `Dockerfile`: Ubuntu 24.04 with systemd and journald as PID 1, so `logger` lands where `journalctl -t pve-zfs-L-patch` reads it. Ubuntu because Debian mirrors were not reachable from the VM this was built in; the script only uses dpkg, apt, coreutils, sed and grep, which behave the same here. The container runs privileged for the tmpfs, bind and FUSE mounts and for `chattr`.
- `build-debs.sh`: builds `libpve-storage-perl` packages that ship only `ZFSPoolPlugin.pm`, from upstream `pve-storage.git`, fetched by `run.sh`:

  | Version | Upstream commit | Send flags |
  | --- | --- | --- |
  | 9.1.2 | `e17a33794c34`, the file as shipped up to 9.1.2 | `-Rpv` |
  | 9.1.3 | `c705a2c03f2c`, which added `-U` | `-RpvU` |
  | 9.1.23 | `HEAD` as of 2026-11-23 | `-RpvU` |

  Three synthetic variants of HEAD reach the `WARNING` states: `9.1.23+syn.moved` ships the file under another name, `9.1.23+syn.shape` changes the flags to `-RpvUw`, and `9.1.23+syn.extra` adds a second send call without `-L`. They are pinned below the real versions, so only an explicit `libpve-storage-perl=<version>` installs one.

  Each package has a conffile, so `apt remove` leaves the `config-files` state, and activates the `pve-api-updates` trigger as upstream does. A stand-in `pve-manager` declares interest in that trigger as upstream does; where upstream reloads pvedaemon, pveproxy and pvescheduler, it records the send flags on disk to `/var/log/e2e-daemon-reload.log`. That shows what the reloaded daemons would run with. `e2e-poke` is an unrelated package to reinstall when a check needs the hook to fire.
- `eio-fs.py`: a one-file FUSE filesystem whose reads fail with EIO, bind-mounted over the target to give the script a real read error. The VM kernel has no device-mapper, so dm-error was not an option.
- `walkthrough.sh`: the checks, in README order: install and first run, the README's verify steps, upgrades, downgrades and reinstalls, `dpkg -i`, each `WARNING`, the hook without `|| true`, the script missing, without its execute bit or on a `noexec` mount, an immutable target, a read-only `/usr/share/perl5`, a full backup directory, a full `/tmp`, a read error, the other `FAILED` states, `apt remove` and `purge`, Recovery and Uninstall.

## Not covered

Real Proxmox daemons: the stand-in `pve-manager` only records what its trigger would have reloaded with. A read error that starts after `sed` has rewritten the file: that needs a writable FUSE filesystem that supports rename, so only the bats suite covers it, with a stub.
