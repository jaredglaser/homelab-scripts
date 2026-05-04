# sshl

Scans a subnet for live hosts and builds a tmux session with one SSH window per host. Each window is split into two panes: a shell on the left and `htop` (or any custom command) on the right.

Runs on your workstation, not on the homelab nodes themselves.

**Dependencies:** `tmux`, `nmap`, `fzf`, `konsole` (or configure your own terminal)

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

Day-to-day host management (rescan + add, delete, reorder, un-ignore) lives inside the tmux session as key bindings rather than CLI flags. See below.

## Keybindings

Active inside the tmux session:

| Key | Action |
|-----|--------|
| `<prefix> S` | Scan + filter popup. Cached hosts appear pre-checked, newly-discovered hosts unchecked, ignored hosts hidden. Confirm = kill windows for unticked, add windows for newly-ticked, write changes to `ips.cache` and `ignored.cache`. |
| `<prefix> O` | Reorder popup. Arrow keys / `j`/`k` move the cursor; `space` to grab the highlighted host, arrows to move it, `space` to drop, `enter` to apply, `q`/`esc` to cancel. |
| `<prefix> I` | Show ignored hosts. Tick to un-ignore (returns them to the next scan as candidates). |
| `<prefix> H` | Fuzzy host picker, jump to selected window |
| `<prefix> r` | Respawn dead pane and force-refresh host info |
| `↻` (status bar) | Force-refresh host info for the current window |
| Mouse | Enabled; click window tabs to switch hosts |

> [!NOTE]
> The script runs on a dedicated socket (`tmux -L homelab`) and won't affect your normal tmux sessions. Mouse support is enabled within the session by `homelab.tmux.conf`. The default tmux prefix is `Ctrl+b` (`<prefix>` in the keybindings above). If you've changed yours in `~/.tmux.conf`, use that instead.

## Configuration

Configuration lives in `sshl/config` (created from `config.example` on first run). Per-host overrides for username, tab name, and pane commands are supported. See the comments in `config.example`.
