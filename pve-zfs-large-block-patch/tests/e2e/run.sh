#!/bin/bash
# Builds the stand-in Proxmox node, publishes the libpve-storage-perl
# packages in it and runs walkthrough.sh. Needs Docker and root (the
# container is privileged for mounts, chattr and FUSE).
#
#   BRANCH=<branch> run.sh   install with the one-liner from that pushed branch
#                            (default: the current branch)
#   KEEP=1 run.sh            leave the container running for inspection
#
# Behind an HTTPS proxy, export https_proxy and set E2E_CA_BUNDLE to the
# proxy's CA file; the container then shares the host network.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
branch="${BRANCH:-$(git -C "$here" rev-parse --abbrev-ref HEAD)}"
name=pve-zfs-e2e
image=pve-zfs-e2e
logs="${E2E_LOGS:-$(mktemp -d)}"

# Upstream revisions and the package versions that shipped them, from
# debian/changelog: e17a33794c34 is the file as shipped up to 9.1.2,
# c705a2c03f2c added -U for 9.1.3, HEAD is 9.1.23 as of 2026-11-23.
revs=(e17a33794c34 c705a2c03f2c HEAD)

src=$(mktemp -d)
trap 'rm -rf "$src"; [ "${KEEP:-}" = 1 ] || docker rm -f "$name" >/dev/null 2>&1 || true' EXIT
# The installed script must match the pushed branch, which catches a stale
# raw.githubusercontent.com cache as well as an unpushed change.
git -C "$here" fetch -q origin "$branch"
git -C "$here" show "FETCH_HEAD:pve-zfs-large-block-patch/pve-zfs-large-block-patch.sh" > "$src/expected-script"
echo "testing branch $branch at $(git -C "$here" rev-parse --short FETCH_HEAD)" >&2
for rev in "${revs[@]}"; do
    curl -fsS -o "$src/ZFSPoolPlugin.pm.$rev" \
        "https://git.proxmox.com/?p=pve-storage.git;a=blob_plain;f=src/PVE/Storage/ZFSPoolPlugin.pm;hb=$rev"
done

docker build -q -t "$image" "$here" >/dev/null

net=()
envs=()
if [ -n "${https_proxy:-}" ]; then
    net=(--network host)
    envs=(-e "https_proxy=$https_proxy")
fi
docker rm -f "$name" >/dev/null 2>&1 || true
docker run -d --name "$name" "${net[@]}" --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock "$image" >/dev/null

for _ in $(seq 1 30); do
    state=$(docker exec "$name" systemctl is-system-running 2>/dev/null || true)
    case "$state" in running|degraded) break ;; esac
    sleep 1
done
echo "systemd in the container: ${state:-not up}" >&2

if [ -n "${E2E_CA_BUNDLE:-}" ]; then
    docker cp "$E2E_CA_BUNDLE" "$name:/usr/local/share/ca-certificates/e2e-proxy.crt"
    docker exec "$name" update-ca-certificates >/dev/null
fi
docker cp "$src" "$name:/root/upstream"
docker cp "$here/build-debs.sh" "$name:/root/"
docker cp "$here/walkthrough.sh" "$name:/root/"
docker cp "$here/eio-fs.py" "$name:/root/"
docker cp "$src/expected-script" "$name:/root/expected-script"
docker exec "$name" /root/build-debs.sh /root/upstream >/dev/null

rc=0
docker exec "${envs[@]}" -e "BRANCH=$branch" "$name" /root/walkthrough.sh || rc=$?

docker cp "$name:/root/e2e-logs/." "$logs"
echo "per-step command output: $logs" >&2
exit "$rc"
