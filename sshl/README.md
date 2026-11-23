# sshl

Scans your network for machines you can SSH into and opens them all in one tmux session: one window per host, with a shell on the left and `htop` on the right. Run it on your workstation.

## Requirements

- bash 4.4, tmux 3.2 and fzf 0.46.0 or newer. Clicking `↻` needs tmux 3.4. On an older tmux, `prefix r` does the same.
- nmap, an SSH client, `flock` (util-linux), `getent`
- a terminal emulator. konsole is the default. xterm, alacritty, kitty, tilix, foot, gnome-terminal and xfce4-terminal also work: set `terminal=` in `config`.

Set up SSH keys for your hosts first (`ssh-copy-id user@host`). Otherwise every window asks for a password.

## First run

```bash
git clone https://github.com/jaredglaser/homelab-scripts.git
cd homelab-scripts/sshl
./sshl
```

The first run creates `config` and stops. Set `subnet=` to your network, such as `192.168.1.0/24` (separate several with spaces), and `default_user=` to the user you log in as. Then run `./sshl` again: it scans the subnet and shows a checklist. Tick the hosts you want with space and press Enter. A konsole window opens with the session.

Run `./sshl` again at any time to open another window on the same session. It also reopens a host's window if both of its panes were closed. You can link it into your PATH (`ln -s "$PWD/sshl" ~/bin/sshl`).

## Keys

The prefix is `Ctrl+b`. The session runs on its own tmux server, so your `~/.tmux.conf` and other tmux sessions are not affected.

| Key | Action |
|-----|--------|
| `prefix S` | Scan again. Tick a NEW host to add it, or a CURRENT host to remove it. A removed host that still answers is hidden from later scans. A host that did not answer is marked `(not found by this scan)`. |
| `prefix I` | Show removed hosts. Tick one to let scans offer it again. |
| `prefix O` | Reorder windows: `j`/`k` or arrows to move (Home, End, PgUp and PgDn jump), space to pick up and drop, Enter to apply. |
| `prefix H` | Jump to a host by name. |
| `prefix r` | Reconnect the window's dropped panes and refresh the host info. |
| Click a tab | Switch host. |
| Click `↻` | Refresh the host info. |

If a popup hits an error, it stays open with the message. Press Esc to close it.

## Status bar

The second row shows the current host's uptime, its pending package updates, and how long ago that was checked, for example `web01 192.168.1.10 up 6m · updates 4 · 2m`. When a host can't be read, the row says why in red: unreachable, host key changed, login refused, no answer or ssh failed.

To get these, sshl logs in to each host about once a day and runs `apt-get update` there, as root or through `sudo -n`. Without passwordless sudo the count may be out of date.

## Configuration

`config` sits next to the script. The comments in `config.example` explain each setting. You can override the user, the tab name and the pane commands per host:

```
host.192.168.1.10.user=admin
host.192.168.1.10.name=webserver
```

sshl uses your `~/.ssh/config` for entries that match the host's IP, such as `Port` or `ProxyJump`. Two exceptions: the user always comes from `default_user` or `host.<ip>.user`, and the scan only finds hosts listening on port 22.

Changes apply to new windows straight away. Open windows keep their old settings until `./sshl --rebuild`, which closes every sshl window and opens a fresh one. sshl tells you when that is needed.

## When something goes wrong

- **A host shows up as an IP and asks for a password.** sshl could not log in as `default_user`. Add `host.<ip>.user=` for it, then press `prefix S` to rename it and run `./sshl --rebuild` to log in as that user.
- **A pane says the host key changed.** The host was reinstalled or its keys regenerated. Check that it is the machine you expect, remove the old key with `ssh-keygen -R <ip>`, then press `prefix r`. sshl accepts the key of a host it has never seen without asking.
- **The terminal window closes as soon as it opens.** gnome-terminal, xfce4-terminal and tilix hide the error. Run `tmux -L homelab -u new-session -t '=homelab'` in a terminal you already have open to read it.
- **To start over with a fresh scan:** delete `ips.cache` and run `./sshl --rebuild`.

## Tests

Run `bats sshl/tests/` from the repo root. [tests/README.md](tests/README.md) explains how the tests work.
