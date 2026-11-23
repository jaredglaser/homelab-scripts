# sshl end-to-end lab

Real SSH hosts in Docker and a konsole on a virtual display, so a change can be checked the way a person uses sshl. Run it as root on a disposable Linux VM with Docker. It installs packages, starts `dockerd` and `Xvfb`, creates the user `sshlab` and adds a line to `/etc/hosts`.

```bash
sshl/tests/lab/lab.sh up
```

`up` installs what it needs, starts the hosts below on `172.30.0.0/24` and `172.31.0.0/24`, creates `sshlab` with an SSH key, copies this checkout's `sshl/` into its home, and checks every host. Run it again after a change: it keeps the existing config, so it also tests an upgrade.

| Host | Login | Covers |
|------|-------|--------|
| web01 .10 | root, key | apt as root |
| db01 .11 | opsudo, key, passwordless sudo | `sudo -n apt-get update` |
| nas01 .12 | ops, key, no sudo | stale update counts |
| pi01 .13 | root, key | no apt (updates show `?`) |
| cam01 .15 | key refused | name from reverse DNS |
| iot01 .16 | key refused | no name at all |
| off01 .17 | no sshd | left out of a scan |
| vlan01 172.31.0.10 | root, key | a second subnet |

In the config, set `subnet=172.30.0.0/24 172.31.0.0/24`, `host.172.30.0.11.user=opsudo` and `host.172.30.0.12.user=ops`.

```bash
L=sshl/tests/lab/lab.sh
$L konsole               # a konsole as sshlab
$L type $'./sshl\n'      # type into it (once attached, that is a host's shell)
$L keys ctrl+b S         # press keys
$L click 270 500         # click at window coordinates
$L shot /tmp/step.png    # screenshot
$L tmux list-windows     # tmux -L homelab as sshlab
$L down                  # stop everything
$L many 50                # 50 more hosts on .101 and up
$L rekey web01            # give a host new SSH host keys
```

Look at every screenshot. A wrong message or a cut-off status line only shows on screen.

`shot`, `keys` and `type` find konsole windows only. To check another terminal, start it as `sshlab` on `DISPLAY=:99` and take the screenshot with `xwd -root -display :99`.

If `docker` or the display stops answering, `$L docker` or `$L display` starts it again. Behind a loopback HTTPS proxy, as in a Claude Code cloud session, `up` builds through the proxy and forwards it to the hosts so `apt-get update` works there.
