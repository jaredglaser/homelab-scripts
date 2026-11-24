# Tests

Two layers. The bats suite tests each branch of both scripts against temp files in seconds. The end-to-end check runs them on Debian trixie against the real Proxmox packages. CI runs both on every pull request that touches this directory.

## bats

```bash
bats pve-zfs-large-block-patch/tests/
```

Run it from the repo root as a user other than root. `setup_suite.bash` stops a root run, because root ignores the file modes the unreadable and read-only cases depend on, and because the tests that check the root refusal would then install into the real `/usr/local/sbin` and `/etc/apt`. From a root shell:

```bash
setpriv --reuid 65534 --regid 65534 --clear-groups env TMPDIR=<dir that uid can write> bats pve-zfs-large-block-patch/tests/
```

Every test passes `--root "$ROOT"` to the script and the installer, so both work on a temp directory laid out like `/`. The hook passes no arguments.

`bin/` is always on `PATH`: `dpkg-query` answers with the package state a test sets, and `logger` records what would reach syslog. `stubs/` holds tools a test links in with `with_stub`, for outcomes no real failure produces on demand:

- `curl` serves a file or GitHub's `404: Not Found` answer, and honours `-f` the way curl does.
- `cp` writes a partial copy and exits 0.
- `sed` changes nothing and exits 0.

Real failures come from file modes (`chmod 000`, a read-only directory) and from `ulimit -f 0`, which makes a write fail after the file is opened, as a full disk does.

## Fixtures

`fixtures/u.pm` is lines 941-968 of `ZFSPoolPlugin.pm` in `libpve-storage-perl` 9.1.18 (`-RpvU`). `fixtures/plain.pm` is lines 776-803 of 9.0.6 (`-Rpv`). The `-patched.pm` files are the expected results. Re-cut them when upstream changes the send flags.

## End to end

```bash
pve-zfs-large-block-patch/tests/e2e/run.sh
```

Needs Docker and access to `deb.debian.org`, `download.proxmox.com`, `enterprise.proxmox.com` and `raw.githubusercontent.com`. It starts a `debian:trixie` container, installs `libpve-storage-perl` 9.0.6 from the `pve-no-subscription` repository, runs `install.sh` from this checkout, upgrades to the newest published version, and walks the states in the main README through real apt, dpkg and syslog. It prints one `PASS` or `FAIL` line per check and exits 1 if any failed.

`run.sh --one-liner` runs the README's one-liner instead, which installs what is on `main`. CI runs it after each push to `main`.

The `WARNING` states for an unknown send shape and a missing file come from editing or moving the installed file, because no published version has them. When `https_proxy` or `SSL_CERT_FILE` is set, `run.sh` passes it into the container, which then uses the host network.
