# sshl

Scans a subnet for live hosts and builds a tmux session with one SSH window per host. Each window is split into two panes: a shell on the left and `htop` (or any custom command) on the right.

Runs on your workstation, not on the homelab nodes themselves.

## Requirements

- bash, tmux and fzf 0.46.0 or newer. sshl was tested with tmux 3.4, bash 5.2 and fzf 0.54.3.
- nmap, an SSH client, `flock` (util-linux), `getent`
- a terminal emulator. konsole is the default. xterm, alacritty, kitty, tilix and foot also work: set `terminal=` in `config`.
- a UTF-8 locale, or `●` and `↻` show as `_`

> [!NOTE]
> Key-based SSH auth is strongly recommended. The script opens a session per host automatically, so if you rely on password auth you will need to sign in manually in every window, which defeats the purpose. If you haven't set up SSH keys yet, `ssh-copy-id user@host` is the quickest way to get there.

Host keys: the scan's name lookup and the status-bar host info connect with `StrictHostKeyChecking=accept-new`, so sshl's first contact with a host adds its key to `~/.ssh/known_hosts` without asking, and the panes then connect without the usual prompt. A key that changes later is refused as usual: the pane shows ssh's warning and dies, and the host info shows `?`.

## Usage

```bash
cd sshl

# First run: creates config from config.example and stops. Set subnet=
# in it to the network your hosts are on, such as 192.168.1.0/24 (separate
# several with spaces), and default_user= to the user you log in as.
./sshl

# After config is set up, the first sshl run scans the subnet and pops a
# checklist so you pick which hosts become windows. Subsequent runs just
# attach a new grouped view to the existing session.
./sshl

# Emergency: close every sshl terminal, rebuild the session from the
# cache and open a fresh terminal on it. With an empty ips.cache, start
# over with a scan.
./sshl --rebuild
```

`sshl` also works through a symlink, for example `ln -s "$PWD/sshl" ~/bin/sshl`. The config and caches stay next to the script.

Run from inside another tmux, `sshl` still opens a new terminal for the session. Without a terminal emulator it attaches in the current shell, or, inside tmux, prints the command to attach from a fresh terminal.

Day-to-day host management (rescan + add, delete, reorder, un-ignore) lives inside the tmux session as key bindings rather than CLI flags. See below.

## Keybindings

Active inside the tmux session:

| Key | Action |
|-----|--------|
| `<prefix> S` | Scan + filter popup. Each row is tagged CURRENT (already a window) or NEW (just found by the scan). Tick a CURRENT to remove its window and add the IP to `ignored.cache`. Tick a NEW to add a window for it. Untouched rows are no-ops, and Enter with nothing ticked changes nothing. Ignored hosts are hidden. |
| `<prefix> O` | Reorder popup. Arrow keys or `j`/`k` move the cursor. Press `space` to grab the highlighted host, arrows to move it, `space` again to drop, `enter` to apply, `q`/`esc` to cancel. |
| `<prefix> I` | Show ignored hosts. Tick to un-ignore (returns them to the next scan as candidates). |
| `<prefix> H` | Fuzzy host picker, jumps to selected window |
| `<prefix> r` | Respawn dead pane and force-refresh host info |
| `↻` (status bar) | Force-refresh host info for the current window |
| Mouse | Click window tabs to switch hosts |

A popup closes by itself when it succeeds. When it fails it stays open with the error, and `Esc` closes it.

> [!NOTE]
> The script runs on a dedicated socket (`tmux -L homelab`) and won't affect your normal tmux sessions. The server starts with `homelab.tmux.conf` as its only config, so `~/.tmux.conf` is not read there: the prefix is always `Ctrl+b` (`<prefix>` in the keybindings above), and your own bindings and options don't apply. Mouse support is enabled within the session by `homelab.tmux.conf`.

## Status bar host info

The second status row shows uptime and pending package updates for the host in the active window, then how long ago they were fetched, as in `web01 up 6m · updates 4 · 2m`. A `?` means the host gave no answer for that field: the login failed, or for updates, the host has no apt. To get them, the status bar and the launcher's startup warm-up log in to each host over SSH (once a day per host, every 5 minutes while a host gives no usable answer, and whenever you press `↻` or `<prefix> r`) and run `apt-get update` there: directly when the user is root, otherwise through `sudo -n`. Where that user has no passwordless sudo, `sudo -n` fails without prompting, the count comes from the package lists as they were, and each attempt can leave a failed sudo entry in that host's auth log. Results are cached per user and host in `$XDG_RUNTIME_DIR/sshl-host-info` (or `~/.cache/sshl-host-info`). The scan popup does not contact hosts beyond the scan and name lookup.

## Configuration

Configuration lives in `sshl/config` (created from `config.example` on first run). Per-host overrides for username, tab name, and pane commands are supported. See the comments in `config.example`.

The scan names each host by logging in as its user (`default_user`, or `host.<ip>.user`) and running `hostname -s`. A host that refuses that user shows up by its IP, or by its reverse DNS name, and its panes ask for a password. Add `host.<ip>.user` for it, then `sshl --rebuild` logs its panes in as that user.

The config is read when a window is created. After an edit, new windows use it at once, but open windows keep their old user, name and commands until `sshl --rebuild`, which closes every sshl terminal and opens a fresh one. A plain `sshl` run says when the config changed after the session was built.

A `#` starts a comment at the start of a line or after whitespace, and quotes around a whole value are dropped. A line that is not `key=value`, an unknown key, or a per-host key that names a host instead of its IP is reported with its line number and skipped. The config is rejected at load time, with a message naming the key, when `subnet` is not set, when `default_user`, `left_cmd` or `right_cmd` is empty, when `layout` is not one of `even-horizontal`, `even-vertical`, `main-horizontal`, `main-vertical`, `tiled`, or when `session_name` is empty or contains `.` or `:`. `terminal` may carry arguments (`terminal=konsole --profile homelab`). sshl runs it with `-e` and the attach command, unless the value already ends in the option the terminal takes before a command (`-e`, `-x` or `--`).

sshl uses your `~/.ssh/config` for entries that match the host's IP, such as `Port` or `ProxyJump`. Two exceptions: the user always comes from `default_user` or `host.<ip>.user`, and the scan only finds hosts listening on port 22.

## Tests

Run `bats sshl/tests/` from the repo root. [tests/README.md](tests/README.md) explains how the tests work.
