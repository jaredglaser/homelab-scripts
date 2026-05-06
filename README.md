# homelab-scripts

A collection of scripts I use to monitor and automate tasks in my homelab environment.

> [!NOTE]
> Some scripts make assumptions about the system they're running on. The most notable is **KDE**: scripts that launch a terminal emulator default to `konsole`. Check the config for your script before running it.

## Scripts

### [sshl](sshl/README.md)

Runs on your workstation. Scans a subnet for live hosts and builds a tmux session with one SSH window per host, with a shell pane and an `htop` pane per window.

### [pve-zfs-large-block-patch](pve-zfs-large-block-patch/README.md)

Runs on a Proxmox VE node. Keeps the `-L` (`--large-block`) flag on `zfs send` after Proxmox package updates, which otherwise revert the patch and break replication chains for datasets with `recordsize > 128K`.

## Contributing

If something isn't working, feel free to [open an issue](https://github.com/jaredglaser/homelab-scripts/issues) and I'll take a look. PRs are also welcome.
