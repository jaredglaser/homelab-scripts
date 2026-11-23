# sshl

Scans a subnet for live hosts and builds a tmux session with one SSH window per host. Each window is split into two panes: a shell on the left and `htop` (or any custom command) on the right.

Runs on your workstation, not on the homelab nodes themselves.

## Requirements

| Tool | Minimum | Why |
|------|---------|-----|
| bash | 4.4 | namerefs (`local -n`) and empty arrays under `set -u`. sshl stops with a message on an older bash |
| tmux | 3.2 | the popups need `display-popup -EE` and the pane borders `pane-border-lines`, both added in 3.2. sshl stops with a message on an older tmux. A click on the `↻` status-bar button needs 3.4 (user mouse ranges and `mouse_status_range`): on 3.2 and 3.3 the button is drawn but a click does nothing, and `<prefix> r` refreshes the same way |
| fzf | 0.46.0 | the popups read `FZF_SELECT_COUNT`, which fzf exports from 0.46.0 on. An older fzf makes the popups fail with a message that names both versions |
| nmap | | the subnet scan |
| ssh | | every pane, host names during a scan, and the status-bar host info |
| getent | | reverse DNS names when ssh cannot name a host |
| flock | | (util-linux) one host-info fetch at a time per host |
| GNU coreutils, awk, tput | | `sort -V`, `readlink -f`, `stat -c`, `mktemp`, `seq` and terminal control in the reorder popup |
| a terminal emulator | | `konsole` by default. See [Terminals](#terminals) |

The tmux and bash minimums come from the features the scripts and `homelab.tmux.conf` use, checked against the tmux and bash change logs. Only tmux 3.4, bash 5.2 and fzf 0.44.1 and 0.54.3 were run. The fzf minimum is the release whose change log adds `FZF_SELECT_COUNT`.

> [!NOTE]
> Key-based SSH auth is strongly recommended. The script opens a session per host automatically, so if you rely on password auth you will need to sign in manually in every window, which defeats the purpose. If you haven't set up SSH keys yet, `ssh-copy-id user@host` is the quickest way to get there.

## Usage

```bash
cd sshl

# First run: creates config from config.example, then edit it
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
| `<prefix> S` | Scan + filter popup. Each row is tagged CURRENT (already a window) or NEW (just found by the scan). Tick a CURRENT to remove its window and add the IP to `ignored.cache`. Tick a NEW to add a window for it. Untouched rows are no-ops, and Enter with nothing ticked changes nothing. Ignored hosts are hidden. A host whose name the scan finds changed is renamed, unless the config names it. |
| `<prefix> O` | Reorder popup. Arrow keys or `j`/`k` move the cursor. Press `space` to grab the highlighted host, arrows to move it, `space` again to drop, `enter` to apply, `q`/`esc` to cancel. |
| `<prefix> I` | Show ignored hosts. Tick to un-ignore (returns them to the next scan as candidates). |
| `<prefix> H` | Fuzzy host picker, jumps to selected window |
| `<prefix> r` | Respawn the active pane if it is dead, and force-refresh host info. A live pane keeps running. |
| `↻` (status bar) | Force-refresh host info for the current window |
| Mouse | Click window tabs to switch hosts |

A popup closes by itself when it succeeds. When it fails it stays open with the error, and `Esc` closes it.

> [!NOTE]
> The script runs on a dedicated socket (`tmux -L homelab`) and won't affect your normal tmux sessions. The server starts with `homelab.tmux.conf` as its only config, so `~/.tmux.conf` is not read there: the prefix is always `Ctrl+b` (`<prefix>` in the keybindings above), and your own bindings and options don't apply. Mouse support is enabled within the session by `homelab.tmux.conf`.

## Status bar host info

The second status row shows uptime and pending package updates for the host in the active window. To get them, the status bar and the launcher's startup warm-up log in to each host over SSH (once a day per host, every 5 minutes while a host gives no usable answer, and whenever you press `↻` or `<prefix> r`) and run `apt-get update` there: directly when the user is root, otherwise through `sudo -n`. Where that user has no passwordless sudo, `sudo -n` fails without prompting, the count comes from the package lists as they were, and each attempt can leave a failed sudo entry in that host's auth log. Results are cached per user and host in `$XDG_RUNTIME_DIR/sshl-host-info` (or `~/.cache/sshl-host-info`). The scan popup does not contact hosts beyond the scan and name lookup.

## Configuration

Configuration lives in `sshl/config` (created from `config.example` on first run). Per-host overrides for username, tab name, and pane commands are supported. See the comments in `config.example`.

A `#` starts a comment at the start of a line or after whitespace, so a `#` inside a value is kept. A line that is not `key=value` is reported with its line number and skipped. The config is rejected at load time, with a message naming the key, when `layout` is not one of `even-horizontal`, `even-vertical`, `main-horizontal`, `main-vertical`, `tiled`, or when `session_name` is empty or contains `.` or `:`. `terminal` may carry arguments (`terminal=konsole --profile homelab`), split on whitespace.

## Terminals

sshl opens the session in a new window of the terminal named by `terminal=`, running `<terminal> -e tmux ...`. These were run with sshl:

| Terminal | `terminal=` | Notes |
|----------|-------------|-------|
| konsole | `konsole` | |
| xterm | `xterm` | Its default bitmap font has no glyph for the pane borders, `●` or `↻`. Use a TrueType font, e.g. `terminal=xterm -fa Monospace -fs 11` |
| alacritty, kitty, tilix | the name | |
| foot | `foot` | Wayland only |
| gnome-terminal | `gnome-terminal` | sshl passes `--` in place of `-e` |
| xfce4-terminal | `xfce4-terminal` | sshl passes `-x` in place of `-e` |

For a terminal that takes the command after some other option, end the value with that option (`-e`, `-x` or `--`) and sshl adds nothing, for example `terminal=gnome-terminal --`. On Debian and Ubuntu, `terminal=x-terminal-emulator` opens the system's default terminal, which accepts `-e`.

gnome-terminal, xfce4-terminal and tilix hand the window to an instance that is already running and return at once. sshl then cannot see a failure inside the window: if the window closes as soon as it opens, run the attach command `tmux -L homelab new-session -t '=homelab'` in a terminal of your own to read the error.

## Tests

`bats sshl/tests/` from the repo root. The popup tests drive the real fzf and skip with a message when it is older than 0.46.0. See the Testing section of the repo's CLAUDE.md for how the tests stay away from real hosts and the real session.
