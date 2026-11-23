# sshl end-to-end lab

`bats sshl/tests/` covers the scripts with stubbed `ssh` and `nmap` and a client in a terminal emulated by tmux. This lab is for what that cannot show: a real konsole window, real SSH logins, a real nmap scan and real package-update counts. Use it to check a change the way a person would meet it, before calling the change done.

Run it as root on a disposable Linux VM with Docker installed (a Claude Code cloud session works). It changes the machine: it installs packages, starts `dockerd` and `Xvfb`, creates a user, and adds one line to `/etc/hosts`.

```bash
sshl/tests/lab/lab.sh up
```

`up` installs the dependencies (konsole, Xvfb, xdotool, nmap, the OpenSSH client, fzf 0.54.3 checked against its sha256), builds two images, starts the hosts below on `172.30.0.0/24`, creates the desktop user `sshlab` with an SSH key, starts a virtual display on `:99`, copies this checkout's `sshl/` to `/home/sshlab/homelab-scripts/sshl`, and checks that each host answers as expected. Run it again after changing the code: `install` keeps the existing `config` and caches, so a rerun also tests an upgrade.

| Host | IP | Login | What it covers |
|------|----|-------|----------------|
| web01 | 172.30.0.10 | root, key | apt as root |
| db01 | 172.30.0.11 | opsudo, key, passwordless sudo | `sudo -n apt-get update` |
| nas01 | 172.30.0.12 | ops, key, no sudo | update counts without a metadata refresh |
| pi01 | 172.30.0.13 | root, key | a host without apt (updates show `?`) |
| cam01 | 172.30.0.15 | key refused, password prompt | names from reverse DNS (`cam01.lab` in `/etc/hosts`) |
| iot01 | 172.30.0.16 | key refused | a host nothing can name (listed by IP) |
| off01 | 172.30.0.17 | no sshd | must not appear in a scan |

The config needs `subnet=172.30.0.0/24`. db01 and nas01 need `host.172.30.0.11.user=opsudo` and `host.172.30.0.12.user=ops` too.

## Driving it

```bash
L=sshl/tests/lab/lab.sh
$L konsole                       # a konsole as sshlab, in ~/homelab-scripts/sshl
$L type $'./sshl\n'              # type into the newest konsole window
$L keys ctrl+b S                 # key presses, xdotool names
$L click 270 500                 # a mouse click at window coordinates
$L shot /tmp/step.png            # screenshot of the newest konsole window
$L tmux list-windows -t =homelab # tmux -L homelab as sshlab
$L as cat ~/.ssh/known_hosts     # any command as sshlab
$L down                          # close konsoles, kill the sshl server, stop the hosts
```

Look at the screenshots: a wrong message, a cut-off status line or a popup that closes too early only shows on screen.

## Things to know

- The desktop runs with `LANG=C.UTF-8`. Without a UTF-8 locale tmux draws `●`, `↻` and the spinner as `_`, which is what a user without one would see too.
- Behind an HTTPS-only proxy on loopback, as in a Claude Code cloud session, `up` builds with `--network host`, switches the images to `https://` Ubuntu mirrors, trusts the proxy CA from `LAB_CA_FILE` (default `/root/.ccr/ca-bundle.crt`), and forwards the proxy port to the lab gateway with socat so `apt-get update` inside the hosts works.
- The no-apt hosts are the Ubuntu image with `apt` and `apt-get` renamed, because Alpine's package mirror is not reachable from every cloud environment. They exercise the same branch of `host-info.sh`.
- Run `lab.sh` as root. Everything sshl itself runs as `sshlab`, never as root, because that is how it is used.
