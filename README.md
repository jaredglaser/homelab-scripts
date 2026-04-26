# homelab-scripts

A collection of scripts I use to monitor and automate tasks in my homelab environment.

> [!NOTE]
> Some scripts make assumptions about the system they're running on. The most notable is **KDE**: scripts that launch a terminal emulator default to `konsole`. Check the config for your script before running it.

> [!WARNING]
> This repo does not currently have automated tests. I try to include helpful error messages, but edge cases may slip through. Scripts that manipulate tmux sessions are low-risk, so I haven't prioritized testing yet. That will likely change as more scripts are added, especially any that could have real impact if they go wrong.

## Scripts

### sshl

Scans a subnet for live hosts and builds a tmux session with one SSH window per host. Each window is split into two panes: a shell on the left and `htop` (or any custom command) on the right.

**Dependencies:** `tmux`, `nmap`, `konsole` (or configure your own terminal), `fzf` (optional, required for the host picker keybinding)

> [!NOTE]
> Key-based SSH auth is strongly recommended. The script opens a session per host automatically, so if you rely on password auth you will need to sign in manually in every window, which defeats the purpose. If you haven't set up SSH keys yet, `ssh-copy-id user@host` is the quickest way to get there.

```bash
cd sshl

# First run: creates config from config.example, then edit it
./sshl

# Normal run: uses cached host list
./sshl

# Re-scan the subnet and rebuild the session
./sshl --rescan

# Rebuild the session from the existing cache
./sshl --rebuild

# Just update the cache, no tmux
./sshl --scan-only
```

**Keybindings** (active inside the tmux session):

| Key | Action |
|-----|--------|
| `<prefix> H` | Open fuzzy host picker, jump to selected window |
| `<prefix> r` | Respawn dead pane and force-refresh host info |
| `↻` (status bar) | Force-refresh host info for the current window |
| Mouse | Enabled; click window tabs to switch hosts |

> [!NOTE]
> The script runs on a dedicated socket (`tmux -L homelab`) and won't affect your normal tmux sessions. Mouse support is enabled within the session by `homelab.tmux.conf`. The default tmux prefix is `Ctrl+b` (`<prefix>` in the keybindings above). If you've changed yours in `~/.tmux.conf`, use that instead.

**Configuration** is in `sshl/config` (created from `config.example` on first run). Per-host overrides for username, tab name, and pane commands are supported. See the comments in `config.example`.

## Contributing

If something isn't working, feel free to [open an issue](https://github.com/jaredglaser/homelab-scripts/issues) and I'll take a look. PRs are also welcome.
