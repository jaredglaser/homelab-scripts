# sshl test framework design

## Goals

- Catch regressions in pure shell logic (config parsing, cache read/write, string substitution)
- Catch regressions in tmux session management (window creation, session health)
- Catch regressions in popup fzf interactions (key input, cache mutations, window mutations)
- Run in GitHub Actions with no real network, no real SSH targets, no KDE

## Non-goals

- Testing `host-info.sh` (requires live SSH targets)
- Testing real subnet scanning (requires network access and permission for nmap)
- Testing the konsole launch path

## Test framework

**bats-core** with a dedicated tmux socket per test run.

Each test uses `SOCKET="sshl-test-$$-$BATS_TEST_NUMBER"` and `TMUX_CMD=(tmux -L "$SOCKET")`. The `BATS_TEST_NUMBER` suffix makes the socket unique per test, which matters if tests ever run with `bats --jobs`. This socket is completely separate from the real `homelab` socket. `teardown()` kills it unconditionally so a crashing test leaves nothing behind.

## File structure

```
sshl/tests/
  test_helper.bash        # shared setup/teardown, sourced by all .bats files
  lib.bats                # pure shell logic tests
  session.bats            # tmux integration tests
  popup_scan.bats         # popup-scan fzf interaction tests
  bin/
    nmap                  # stub: outputs pre-canned host discovery, no network
    ssh                   # stub: returns a fixture hostname immediately, no connection
```

## Isolation mechanism

`test_helper.bash` applied in every `setup()`:

1. Sets `SOCKET="sshl-test-$$-$BATS_TEST_NUMBER"`, `TMUX_CMD=(tmux -L "$SOCKET")`
2. Creates a temp config in `$BATS_TEST_TMPDIR` with `subnet=192.0.2.0/24` (RFC 5737 TEST-NET, unreachable)
3. Overrides `CONFIG_FILE`, `CACHE_FILE`, `IGNORED_FILE` to paths inside `$BATS_TEST_TMPDIR`
4. Prepends `sshl/tests/bin/` to `PATH` so fake `nmap` and `ssh` shadow the real ones

`teardown()` runs `tmux -L "$SOCKET" kill-server 2>/dev/null || true`.

Nothing in a test can reach the real `homelab` socket, real cache files, or a real host.

## Test categories

### lib.bats — pure logic, no tmux

Sources `sshl-lib.sh`, overrides path vars, calls functions directly. No external processes.

Cases:
- `trim` strips leading and trailing whitespace
- `substitute` replaces `{ip}`, `{user}`, `{hostname}` in command templates
- `read_cache` parses a fixture cache file into `ips[]` and `cached_name[]`
- `write_cache` writes atomically (temp + rename) and produces correct tab-separated output
- `resolve_hostname` priority: config override > cache > discovered > bare IP
- Config parser: unknown keys emit a warning; missing `subnet` exits non-zero

### session.bats — real tmux, fake hosts

Seeds `ips.cache` with 2-3 fake IPs and hostnames, calls lib functions against the test socket.

Cases:
- `build_session` creates one window per cached IP with `@host_ip` set on each
- `session_is_healthy` returns false when `@build_complete` is absent
- `session_is_healthy` returns true after a successful `build_session`
- `add_window` appends a window without disturbing existing windows
- `kill_host_window` removes the correct window by IP and leaves others intact
- `build_session` with an empty cache exits non-zero

### popup_scan.bats — fzf driven via send-keys

Starts a live session on the test socket, runs `popup-scan.sh` in a tmux pane, polls `capture-pane` until fzf is visible, sends keys, then asserts cache and window state.

Helper: `wait_for_pane_content <pane> <pattern> <timeout_seconds>` polls `capture-pane -p` until the pattern appears or timeout expires.

Cases:
- Toggle a NEW host with Space + Enter: host appears in `ips.cache`, window opens
- Toggle a CURRENT host with Space + Enter: host removed from `ips.cache`, window killed
- Press Escape: no changes to cache or session
- Toggle all CURRENT hosts: refused with "would leave zero hosts" message, session unchanged
- Toggle a NEW host and a CURRENT host in same session: both mutations apply atomically (cache written before tmux changes)

## Fake stubs

**`tests/bin/nmap`**

Outputs a greppable file listing 2-3 fake IPs with port 22 open, then exits 0. Parses the `-oG <path>` flag from argv (matching how `scan_subnet` calls nmap) and writes the pre-canned output there.

**`tests/bin/ssh`**

When called with `hostname -s`, prints a fixture hostname (`fake-host-01` etc.) and exits 0. Handles `BatchMode=yes` and other flags without connecting.

## GitHub Actions

`.github/workflows/test-sshl.yml`:

```yaml
name: Test sshl
on:
  push:
    paths: ['sshl/**']
  pull_request:
    paths: ['sshl/**']

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: sudo apt-get install -y tmux bats fzf
      - run: bats sshl/tests/
```

`nmap` is present on ubuntu-latest but `tests/bin/nmap` shadows it. `fzf` must be installed explicitly. No display or desktop environment needed.
