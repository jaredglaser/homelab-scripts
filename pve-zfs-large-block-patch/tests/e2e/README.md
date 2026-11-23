# End-to-end check

Installs the script with the README's one-liner on a stand-in Proxmox node and walks every state the README describes, through real apt, dpkg and journald.

```bash
BRANCH=<pushed branch> pve-zfs-large-block-patch/tests/e2e/run.sh
```

Needs Docker, root and network access. It tests what is pushed to `BRANCH` (default: the current branch), because the one-liner fetches from GitHub. It prints `PASS` or `FAIL` per check and exits 1 on any failure. Behind an HTTPS proxy, export `https_proxy` and set `E2E_CA_BUNDLE` to the proxy's CA file. `KEEP=1` leaves the container running.

The node is Ubuntu 24.04 with systemd as PID 1. `build-debs.sh` builds `libpve-storage-perl` 9.1.2, 9.1.3 and 9.1.23 from upstream `ZFSPoolPlugin.pm`, plus pinned-down synthetic versions for the `WARNING` states. `eio-fs.py` provides a file whose reads fail.
