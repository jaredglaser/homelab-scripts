# Project Guidelines for Claude

## Project Overview

A collection of bash scripts for monitoring and automating tasks in a homelab environment. Each script lives in its own subdirectory with its own config, README, and supporting files.

**System assumptions**: KDE desktop. Scripts that launch a terminal emulator default to `konsole`. The configured subnet is a private /16.

## Structure Convention

Each script lives in its own subdirectory:

```
<script-name>/
  <script-name>       # main executable
  config.example      # committed template (actual config is gitignored)
  *.conf              # any supporting config files
  *.sh                # helper scripts
```

## Critical Rules

1. **Never commit machine-specific or sensitive files**: Anything with IPs, credentials, local paths, or runtime-generated state belongs in `.gitignore`. The committed version is always a `.example` template. When adding a new script, identify its equivalents upfront and gitignore them before the first commit.
2. **File creation**: Prefer editing existing files over creating new ones.
3. **Scope discipline**: When asked to plan, research, or review, produce only that deliverable. Do not start executing unless explicitly asked.
4. **Commit scope**: Only commit files relevant to the current task.
5. **Verify before claiming fixed**: Run the relevant script path (or at minimum `bash -n`) before reporting a fix as done. Don't claim success without evidence.
6. **No claudisms in written output**: Applies to code, comments, commit messages, and docs. Banned: em dashes, en dashes, `--` as a dash substitute, vocabulary tells ("leverage", "utilize", "delve", "robust", "comprehensive", "meticulous", "facilitate", "it's worth noting"), performative qualifiers ("carefully", "thoroughly"), boilerplate sign-offs. Use plain alternatives.
7. **Document automation in rollback steps**: When a script re-applies state via apt/dpkg hooks, cron, systemd timers, or file watchers, its README's recovery/rollback section must include the step to disable that automation. Otherwise restoring from a backup gets undone on the next trigger.

## Comments

Write comments that capture project-specific WHY: non-obvious constraints, workarounds for specific behavior, invariants a reader would otherwise reverse-engineer. Don't restate what the code obviously does.

Good example (from sshl):
```bash
# Nuke the whole server, not just the base session. kill-session -t =homelab
# leaves any grouped sessions (open konsoles) running with stale windows.
```

Bad example:
```bash
# Loop through all IPs
for ip in "${ips[@]}"; do
```

## Error Handling

Scripts should fail loudly with actionable messages. The pattern in use:

```bash
if [[ ! -f "$CONFIG_FILE" ]]; then
    if [[ -f "${SCRIPT_DIR}/config.example" ]]; then
        cp "${SCRIPT_DIR}/config.example" "$CONFIG_FILE"
        echo "Created config from config.example. Review $CONFIG_FILE before re-running." >&2
    else
        echo "Error: config file not found at $CONFIG_FILE" >&2
    fi
    exit 1
fi
```

Use `>&2` for all error and status output. Use `require()` to check dependencies before doing real work.

## Testing

Two scripts have bats-core suites, both run from the repo root:

- `bats sshl/tests/` gives each test its own tmux socket and temp directory and sets `session_name=test-homelab`, so it cannot reach the real `homelab` session. `SSHL_DATA_DIR_OVERRIDE` moves only the config and caches into the temp directory, so the tests run the real scripts, `homelab.tmux.conf` and `host-info.sh`. Every test points `XDG_RUNTIME_DIR` and `HOME` at the temp directory and stubs `nmap` and `ssh` on PATH, so it cannot reach a real host or the real host-info cache. The host-info, host-picker, launcher and conf tests put a `tmux` shim first on PATH that refuses the `homelab` socket and any bare `tmux` call whose `$TMUX` is not the test's server. Tests that need a user's view attach a client through `script -qfc` inside a pane of a second test server (`<socket>-term`) and read its screen with `capture-pane`. Tests that drive the real fzf skip with a message when it is older than the popups' minimum, and they wait on pane content rather than sleeping between keys. CI also runs shellcheck over the scripts, the test helper and the stubs.
- `bats pve-zfs-large-block-patch/tests/` points the script at a temp directory through its `PVE_ZFS_PATCH_*_OVERRIDE` variables and stubs `dpkg-query` and `logger` on PATH. The script falls back to the real `/usr/share/perl5` path when those variables are empty, so `setup()` confirms `mktemp -d` worked before exporting them.

Before adding tests to other scripts, consider blast radius: scripts that could cause real damage (data loss, network changes, service disruption) are higher priority than easily-recovered ones.
