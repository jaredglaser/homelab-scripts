# Stand-in Proxmox VE node: Ubuntu 24.04 (Debian mirrors are not reachable
# from the build VM) with systemd and journald as PID 1, so the hook's
# logger calls land where journalctl -t reads them.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends systemd systemd-sysv curl ca-certificates \
        dpkg-dev e2fsprogs util-linux python3-fusepy fuse3 \
 && apt-get clean
# Units that fail or hang without real hardware in a container.
RUN systemctl mask systemd-udevd.service systemd-udevd-kernel.socket systemd-udevd-control.socket \
        systemd-modules-load.service sys-kernel-config.mount sys-kernel-debug.mount \
        sys-kernel-tracing.mount systemd-remount-fs.service getty.target console-getty.service \
        systemd-networkd.service systemd-resolved.service
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
