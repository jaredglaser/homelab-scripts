# sshl

Scans a subnet for live hosts and builds a tmux session with one SSH window per host. Each window is split into two panes: a shell on the left and `htop` (or any custom command) on the right.

Runs on your workstation, not on the homelab nodes themselves.

## Requirements

- bash, tmux and fzf. sshl was tested with tmux 3.4, bash 5.2 and fzf 0.54.3. It stops with an error on an fzf older than 0.46.0, which lacks a feature the popups use.
- nmap, an SSH client, `flock` (util-linux), `getent`
- a terminal emulator, konsole by default. To use another, set `terminal=` in `config` to its command. sshl adds `-e` and the attach command, unless the value already ends in an option, as in `terminal=wezterm start --`.
- a UTF-8 locale, or `●` and `↻` show as `_`

> [!NOTE]
> Key-based SSH auth is strongly recommended. The script opens a session per host automatically, so if you rely on password auth you will need to sign in manually in every window, which defeats the purpose. If you haven't set up SSH keys yet, `ssh-copy-id user@host` is the quickest way to get there.

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

# Emergency: nuke the tmux server and rebuild from the cache
./sshl --rebuild
```

`sshl` also works through a symlink, for example `ln -s "$PWD/sshl" ~/bin/sshl`. The config and caches stay next to the script.

Run from inside another tmux, `sshl` still opens a new terminal for the session. Without a terminal emulator it attaches in the current shell, or, inside tmux, prints the command to attach from a fresh terminal.

Day-to-day host management (rescan + add, delete, reorder, un-ignore) lives inside the tmux session as key bindings rather than CLI flags. See below.

## Keybindings

Active inside the tmux session:

| Key | Action |
|-----|--------|
| `<prefix> S` | Scan + filter popup. Each row is tagged CURRENT (already a window) or NEW (just found by the scan). Tick a CURRENT to remove its window and add the IP to `ignored.cache`. Tick a NEW to add a window for it. Untouched rows are no-ops. Ignored hosts are hidden. |
| `<prefix> O` | Reorder popup. Arrow keys or `j`/`k` move the cursor. Press `space` to grab the highlighted host, arrows to move it, `space` again to drop, `enter` to apply, `q`/`esc` to cancel. |
| `<prefix> I` | Show ignored hosts. Tick to un-ignore (returns them to the next scan as candidates). |
| `<prefix> H` | Fuzzy host picker, jumps to selected window |
| `<prefix> r` | Respawn dead pane and force-refresh host info |
| `↻` (status bar) | Force-refresh host info for the current window |
| Mouse | Click window tabs to switch hosts |

> [!NOTE]
> The script runs on a dedicated socket (`tmux -L homelab`) and won't affect your normal tmux sessions. The server starts with `homelab.tmux.conf` as its only config, so `~/.tmux.conf` is not read there: the prefix is always `Ctrl+b` (`<prefix>` in the keybindings above), and your own bindings and options don't apply. Mouse support is enabled within the session by `homelab.tmux.conf`.

## Status bar host info

The second status row shows uptime and pending package updates for the host in the active window. To get them, the status bar and the launcher's startup warm-up log in to each host over SSH (once a day per host, every 5 minutes while a host gives no usable answer, and whenever you press `↻` or `<prefix> r`) and run `apt-get update` there: directly when the user is root, otherwise through `sudo -n`. Where that user has no passwordless sudo, `sudo -n` fails without prompting, the count comes from the package lists as they were, and each attempt can leave a failed sudo entry in that host's auth log. Results are cached per user and host in `$XDG_RUNTIME_DIR/sshl-host-info` (or `~/.cache/sshl-host-info`). The scan popup does not contact hosts beyond the scan and name lookup.

## Configuration

Configuration lives in `sshl/config` (created from `config.example` on first run). Per-host overrides for username, tab name, and pane commands are supported. See the comments in `config.example`.

A `#` starts a comment at the start of a line or after whitespace. One pair of quotes around a whole value is dropped, and any other quote is kept as written. A line that is not `key=value`, an unknown key, or a per-host key that names a host instead of its IP is reported with its line number and skipped. The config is rejected at load time, with a message naming the key or value, when `subnet` is not set or an entry in it is not an IPv4 range in CIDR form, when `default_user`, `left_cmd` or `right_cmd` is empty, when `layout` is not one of `even-horizontal`, `even-vertical`, `main-horizontal`, `main-vertical`, `tiled`, when `session_name` is empty or contains `.` or `:`, or when a `host.<ip>.name` is not a plain host name (letters, digits, `.`, `_` and `-`). `terminal` may carry arguments (`terminal=konsole --profile homelab`). It is split on spaces, so no argument can contain one, quoted or not.

sshl uses your `~/.ssh/config` for entries that match the host's IP, such as `Port` or `ProxyJump`. Two exceptions: the user always comes from `default_user` or `host.<ip>.user`, and the scan only finds hosts listening on port 22.

## Tests

Run `bats sshl/tests/` from the repo root. [tests/README.md](tests/README.md) explains how the tests work.
