# sshl Test Framework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a bats-core test suite covering pure shell logic, tmux session management, and fzf popup interactions — fully isolated from real sessions, real devices, and real networks.

**Architecture:** Two env var overrides added to `sshl-lib.sh` (`SSHL_DIR_OVERRIDE` for file paths, `SSHL_SOCKET_OVERRIDE` for the tmux socket) allow tests to redirect all I/O to a temp directory and a dedicated tmux server. Fake `nmap` and `ssh` stubs in `tests/bin/` shadow the real tools for the duration of each test. bats-core drives all three test layers.

**Tech Stack:** bats-core, tmux, fzf, bash

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Modify | `sshl/sshl-lib.sh:5,17-18` | Add `SSHL_DIR_OVERRIDE` and `SSHL_SOCKET_OVERRIDE` support |
| Create | `sshl/tests/test_helper.bash` | Shared setup/teardown and polling helpers for all test files |
| Create | `sshl/tests/bin/nmap` | Fake nmap: writes pre-canned greppable output, no network |
| Create | `sshl/tests/bin/ssh` | Fake ssh: returns fixture hostnames, no connections |
| Create | `sshl/tests/lib.bats` | Pure shell logic tests (trim, substitute, cache, config) |
| Create | `sshl/tests/session.bats` | tmux integration tests (build_session, add_window, etc.) |
| Create | `sshl/tests/popup_scan.bats` | fzf popup tests driven via tmux send-keys |
| Create | `.github/workflows/test-sshl.yml` | CI workflow |

---

### Task 1: Add env var overrides to sshl-lib.sh

**Files:**
- Modify: `sshl/sshl-lib.sh:5` (SSHL_DIR)
- Modify: `sshl/sshl-lib.sh:17-18` (SOCKET, TMUX_CMD)

**Why:** `sshl-lib.sh` computes all path vars from `BASH_SOURCE` and hardcodes the tmux socket name at source time. Without env var overrides, tests can't redirect file I/O to a temp dir, and popup scripts launched inside a test tmux pane would re-source the lib and land on the real `homelab` socket, breaking isolation.

- [ ] **Step 1: Override SSHL_DIR**

In `sshl/sshl-lib.sh`, change line 5 from:
```bash
SSHL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```
to:
```bash
SSHL_DIR="${SSHL_DIR_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
```

- [ ] **Step 2: Override SOCKET and TMUX_CMD**

In `sshl/sshl-lib.sh`, change lines 17-18 from:
```bash
SOCKET="homelab"
TMUX_CMD=(tmux -L "$SOCKET")
```
to:
```bash
SOCKET="${SSHL_SOCKET_OVERRIDE:-homelab}"
TMUX_CMD=(tmux -L "$SOCKET")
```

- [ ] **Step 3: Verify syntax**

```bash
bash -n sshl/sshl-lib.sh
```
Expected: no output, exit 0.

- [ ] **Step 4: Commit**

```bash
git add sshl/sshl-lib.sh
git commit -m "Add SSHL_DIR_OVERRIDE and SSHL_SOCKET_OVERRIDE for test isolation"
```

---

### Task 2: Create test infrastructure

**Files:**
- Create: `sshl/tests/test_helper.bash`
- Create: `sshl/tests/bin/nmap`
- Create: `sshl/tests/bin/ssh`

- [ ] **Step 1: Create directory structure**

```bash
mkdir -p sshl/tests/bin
```

- [ ] **Step 2: Write test_helper.bash**

Create `sshl/tests/test_helper.bash`:
```bash
setup() {
    SSHL_SRC="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    TEST_BIN="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/bin"

    export SSHL_DIR_OVERRIDE
    SSHL_DIR_OVERRIDE="$(mktemp -d)"
    export SSHL_SOCKET_OVERRIDE
    SSHL_SOCKET_OVERRIDE="sshl-test-$$-${BATS_TEST_NUMBER:-0}"

    cat > "$SSHL_DIR_OVERRIDE/config" << 'EOF'
subnet=192.0.2.0/24
session_name=test-homelab
default_user=testuser
terminal=false
left_cmd=sleep 30
right_cmd=sleep 30
EOF

    touch "$SSHL_DIR_OVERRIDE/homelab.tmux.conf"
    : > "$SSHL_DIR_OVERRIDE/ips.cache"
    : > "$SSHL_DIR_OVERRIDE/ignored.cache"

    # Minimal host-info stub so fzf preview doesn't print errors
    printf '#!/usr/bin/env bash\necho "test"\n' > "$SSHL_DIR_OVERRIDE/host-info.sh"
    chmod +x "$SSHL_DIR_OVERRIDE/host-info.sh"

    export PATH="$TEST_BIN:$PATH"

    unset _SSHL_LIB
    source "$SSHL_SRC/sshl-lib.sh"
    # After sourcing: SOCKET=$SSHL_SOCKET_OVERRIDE, TMUX_CMD=(tmux -L "$SOCKET")
}

teardown() {
    tmux -L "$SOCKET" kill-server 2>/dev/null || true
    rm -rf "$SSHL_DIR_OVERRIDE"
    unset SSHL_DIR_OVERRIDE SSHL_SOCKET_OVERRIDE
}

# Poll capture-pane until pattern appears or timeout expires.
wait_for_pane_content() {
    local pane="$1" pattern="$2" timeout="${3:-5}"
    local i
    for i in $(seq 1 $(( timeout * 10 ))); do
        tmux -L "$SOCKET" capture-pane -t "$pane" -p 2>/dev/null | grep -q "$pattern" && return 0
        sleep 0.1
    done
    echo "Timeout waiting for pane content matching: $pattern" >&2
    return 1
}

# Poll window count for session_name until it matches expected, or timeout.
wait_for_window_count() {
    local expected="$1" timeout="${2:-10}"
    local i count
    for i in $(seq 1 $(( timeout * 10 ))); do
        count=$(tmux -L "$SOCKET" list-windows -t "=$session_name" 2>/dev/null | wc -l) || true
        [[ "$count" -eq "$expected" ]] && return 0
        sleep 0.1
    done
    return 1
}
```

- [ ] **Step 3: Write tests/bin/nmap**

Create `sshl/tests/bin/nmap`:
```bash
#!/usr/bin/env bash
# Fake nmap for tests. Parses -oG <path> from args and writes two fake hosts.
output_file=""
args=("$@")
for i in "${!args[@]}"; do
    if [[ "${args[$i]}" == "-oG" ]]; then
        output_file="${args[$((i+1))]}"
        break
    fi
done

if [[ -n "$output_file" ]]; then
    cat > "$output_file" << 'EOF'
Host: 192.0.2.1 ()	Ports: 22/open/tcp//ssh///
Host: 192.0.2.2 ()	Ports: 22/open/tcp//ssh///
EOF
fi
exit 0
```

- [ ] **Step 4: Write tests/bin/ssh**

Create `sshl/tests/bin/ssh`:
```bash
#!/usr/bin/env bash
# Fake ssh for tests. Returns fixture hostnames for resolve_remote_hostname calls.
# Hostname-resolution calls include 'hostname' as a trailing argument.
for arg in "$@"; do
    [[ "$arg" == "hostname" ]] || continue
    for a in "$@"; do
        case "$a" in
            *@192.0.2.1) echo "fake-host-01"; exit 0 ;;
            *@192.0.2.2) echo "fake-host-02"; exit 0 ;;
            *@192.0.2.3) echo "fake-host-03"; exit 0 ;;
        esac
    done
    echo "fake-host-unknown"
    exit 0
done
# Non-hostname calls (window pane commands): exit immediately
exit 0
```

- [ ] **Step 5: Make stubs executable**

```bash
chmod +x sshl/tests/bin/nmap sshl/tests/bin/ssh
```

- [ ] **Step 6: Verify syntax**

```bash
bash -n sshl/tests/test_helper.bash
bash -n sshl/tests/bin/nmap
bash -n sshl/tests/bin/ssh
```
Expected: no output, all exit 0.

- [ ] **Step 7: Commit**

```bash
git add sshl/tests/
git commit -m "Add bats test infrastructure: test_helper and bin stubs"
```

---

### Task 3: Write lib.bats

**Files:**
- Create: `sshl/tests/lib.bats`

These tests source `sshl-lib.sh` via the helper and call pure functions directly. No tmux server is needed.

- [ ] **Step 1: Write lib.bats**

Create `sshl/tests/lib.bats`:
```bash
#!/usr/bin/env bats

load test_helper

# ── trim ──────────────────────────────────────────────────────────────────────

@test "trim: strips leading whitespace" {
    result=$(trim "   hello")
    [ "$result" = "hello" ]
}

@test "trim: strips trailing whitespace" {
    result=$(trim "hello   ")
    [ "$result" = "hello" ]
}

@test "trim: strips both ends" {
    result=$(trim "  hello world  ")
    [ "$result" = "hello world" ]
}

@test "trim: empty string stays empty" {
    result=$(trim "")
    [ "$result" = "" ]
}

# ── substitute ────────────────────────────────────────────────────────────────

@test "substitute: replaces {ip}" {
    result=$(substitute "ssh {ip}" "10.0.0.1" "root" "myhost")
    [ "$result" = "ssh 10.0.0.1" ]
}

@test "substitute: replaces {user}" {
    result=$(substitute "ssh {user}@{ip}" "10.0.0.1" "admin" "myhost")
    [ "$result" = "ssh admin@10.0.0.1" ]
}

@test "substitute: replaces {hostname}" {
    result=$(substitute "echo {hostname}" "10.0.0.1" "root" "myhost")
    [ "$result" = "echo myhost" ]
}

@test "substitute: replaces all tokens in one template" {
    result=$(substitute "ssh {user}@{ip} # {hostname}" "10.0.0.1" "admin" "box01")
    [ "$result" = "ssh admin@10.0.0.1 # box01" ]
}

# ── read_cache ────────────────────────────────────────────────────────────────

@test "read_cache: parses ip and name from tab-separated file" {
    printf '192.0.2.1\tfake-host-01\n192.0.2.2\tfake-host-02\n' > "$SSHL_DIR_OVERRIDE/ips.cache"
    read_cache
    [ "${ips[0]}" = "192.0.2.1" ]
    [ "${ips[1]}" = "192.0.2.2" ]
    [ "${cached_name[192.0.2.1]}" = "fake-host-01" ]
    [ "${cached_name[192.0.2.2]}" = "fake-host-02" ]
}

@test "read_cache: skips blank lines" {
    printf '\n192.0.2.1\tfake-host-01\n\n' > "$SSHL_DIR_OVERRIDE/ips.cache"
    read_cache
    [ "${#ips[@]}" = "1" ]
    [ "${ips[0]}" = "192.0.2.1" ]
}

@test "read_cache: returns empty arrays when cache file is absent" {
    rm -f "$SSHL_DIR_OVERRIDE/ips.cache"
    read_cache
    [ "${#ips[@]}" = "0" ]
}

@test "read_cache: strips inline comments from ip field" {
    printf '192.0.2.1  # stale\tfake-host-01\n' > "$SSHL_DIR_OVERRIDE/ips.cache"
    read_cache
    [ "${ips[0]}" = "192.0.2.1" ]
}

# ── write_cache ───────────────────────────────────────────────────────────────

@test "write_cache: roundtrips ip and name through read_cache" {
    ips=("192.0.2.1" "192.0.2.2")
    cached_name[192.0.2.1]="fake-host-01"
    cached_name[192.0.2.2]="fake-host-02"
    write_cache
    ips=()
    unset cached_name; declare -A cached_name
    read_cache
    [ "${ips[0]}" = "192.0.2.1" ]
    [ "${ips[1]}" = "192.0.2.2" ]
    [ "${cached_name[192.0.2.1]}" = "fake-host-01" ]
}

@test "write_cache: produces empty file when ips array is empty" {
    ips=()
    write_cache
    [ ! -s "$SSHL_DIR_OVERRIDE/ips.cache" ]
}

# ── read_ignored / write_ignored ──────────────────────────────────────────────

@test "read_ignored: parses ignored ips and names" {
    printf '192.0.2.9\told-host\n' > "$SSHL_DIR_OVERRIDE/ignored.cache"
    read_ignored
    [ "${ignored_ips[0]}" = "192.0.2.9" ]
    [ "${ignored_name[192.0.2.9]}" = "old-host" ]
}

@test "write_ignored: roundtrips through read_ignored" {
    ignored_ips=("192.0.2.9")
    ignored_name[192.0.2.9]="old-host"
    write_ignored
    ignored_ips=()
    unset ignored_name; declare -A ignored_name
    read_ignored
    [ "${ignored_ips[0]}" = "192.0.2.9" ]
    [ "${ignored_name[192.0.2.9]}" = "old-host" ]
}

# ── resolve_hostname ──────────────────────────────────────────────────────────

@test "resolve_hostname: prefers config host_name over cache" {
    host_name[192.0.2.1]="config-name"
    cached_name[192.0.2.1]="cache-name"
    result=$(resolve_hostname "192.0.2.1")
    [ "$result" = "config-name" ]
}

@test "resolve_hostname: falls back to cached_name" {
    unset 'host_name[192.0.2.1]'
    cached_name[192.0.2.1]="cache-name"
    result=$(resolve_hostname "192.0.2.1")
    [ "$result" = "cache-name" ]
}

@test "resolve_hostname: falls back to bare IP when no names are set" {
    unset 'host_name[192.0.2.99]'
    unset 'cached_name[192.0.2.99]'
    unset 'discovered_name[192.0.2.99]'
    result=$(resolve_hostname "192.0.2.99")
    [ "$result" = "192.0.2.99" ]
}

# ── config parsing ────────────────────────────────────────────────────────────

@test "config: unknown key emits a warning to stderr" {
    echo "boguskey=somevalue" >> "$SSHL_DIR_OVERRIDE/config"
    unset _SSHL_LIB
    stderr=$(source "$SSHL_SRC/sshl-lib.sh" 2>&1 >/dev/null)
    [[ "$stderr" == *"unknown config key"* ]]
}
```

- [ ] **Step 2: Run lib.bats**

```bash
bats sshl/tests/lib.bats
```
Expected: all tests pass. If any fail, check that `SSHL_DIR_OVERRIDE` was written to the lib correctly in Task 1.

- [ ] **Step 3: Commit**

```bash
git add sshl/tests/lib.bats
git commit -m "Add lib.bats: pure shell logic tests for sshl-lib.sh"
```

---

### Task 4: Write session.bats

**Files:**
- Create: `sshl/tests/session.bats`

These tests spin up a real tmux server on the test socket. The test config uses `left_cmd=sleep 30` and `right_cmd=sleep 30` so window panes stay open long enough for assertions.

- [ ] **Step 1: Write session.bats**

Create `sshl/tests/session.bats`:
```bash
#!/usr/bin/env bats

load test_helper

# Write N fake hosts to ips.cache and call read_cache.
seed_hosts() {
    local n="${1:-2}"
    : > "$SSHL_DIR_OVERRIDE/ips.cache"
    local i
    for i in $(seq 1 "$n"); do
        printf '192.0.2.%d\tfake-host-%02d\n' "$i" "$i" >> "$SSHL_DIR_OVERRIDE/ips.cache"
    done
    read_cache
}

# ── session_is_healthy ────────────────────────────────────────────────────────

@test "session_is_healthy: returns false when no session exists" {
    run session_is_healthy
    [ "$status" -ne 0 ]
}

@test "session_is_healthy: returns false when session exists but @build_complete is absent" {
    seed_hosts 1
    "${TMUX_CMD[@]}" new-session -d -s "$session_name" "sleep 30"
    run session_is_healthy
    [ "$status" -ne 0 ]
}

@test "session_is_healthy: returns true after a successful build_session" {
    seed_hosts 2
    build_session
    run session_is_healthy
    [ "$status" -eq 0 ]
}

# ── build_session ─────────────────────────────────────────────────────────────

@test "build_session: creates one window per cached IP" {
    seed_hosts 3
    build_session
    count=$(tmux -L "$SOCKET" list-windows -t "=$session_name" | wc -l)
    [ "$count" -eq 3 ]
}

@test "build_session: sets @host_ip on each window" {
    seed_hosts 2
    build_session
    found=$(tmux -L "$SOCKET" list-windows -t "=$session_name" -F '#{@host_ip}')
    [[ "$found" == *"192.0.2.1"* ]]
    [[ "$found" == *"192.0.2.2"* ]]
}

@test "build_session: sets @build_complete to 1" {
    seed_hosts 1
    build_session
    val=$(tmux -L "$SOCKET" show-option -gv @build_complete)
    [ "$val" = "1" ]
}

@test "build_session: exits non-zero when cache is empty" {
    ips=()
    run build_session
    [ "$status" -ne 0 ]
}

# ── add_window ────────────────────────────────────────────────────────────────

@test "add_window: appends a window without disturbing existing ones" {
    seed_hosts 1
    build_session
    ips+=("192.0.2.2")
    cached_name[192.0.2.2]="fake-host-02"
    add_window "192.0.2.2"
    count=$(tmux -L "$SOCKET" list-windows -t "=$session_name" | wc -l)
    [ "$count" -eq 2 ]
}

@test "add_window: sets @host_ip on the new window" {
    seed_hosts 1
    build_session
    ips+=("192.0.2.2")
    cached_name[192.0.2.2]="fake-host-02"
    add_window "192.0.2.2"
    found=$(tmux -L "$SOCKET" list-windows -t "=$session_name" -F '#{@host_ip}')
    [[ "$found" == *"192.0.2.2"* ]]
}

# ── kill_host_window ──────────────────────────────────────────────────────────

@test "kill_host_window: removes the window for the target IP" {
    seed_hosts 2
    build_session
    kill_host_window "192.0.2.1"
    found=$(tmux -L "$SOCKET" list-windows -t "=$session_name" -F '#{@host_ip}')
    [[ "$found" != *"192.0.2.1"* ]]
}

@test "kill_host_window: leaves other windows intact" {
    seed_hosts 2
    build_session
    kill_host_window "192.0.2.1"
    found=$(tmux -L "$SOCKET" list-windows -t "=$session_name" -F '#{@host_ip}')
    [[ "$found" == *"192.0.2.2"* ]]
}

@test "kill_host_window: is a no-op for an IP not in the session" {
    seed_hosts 1
    build_session
    run kill_host_window "192.0.2.99"
    [ "$status" -eq 0 ]
    count=$(tmux -L "$SOCKET" list-windows -t "=$session_name" | wc -l)
    [ "$count" -eq 1 ]
}
```

- [ ] **Step 2: Run session.bats**

```bash
bats sshl/tests/session.bats
```
Expected: all tests pass.

- [ ] **Step 3: Commit**

```bash
git add sshl/tests/session.bats
git commit -m "Add session.bats: tmux session integration tests"
```

---

### Task 5: Write popup_scan.bats

**Files:**
- Create: `sshl/tests/popup_scan.bats`

These tests drive a real fzf process inside a tmux pane. They are slower than the other suites — allow ~5 seconds per test, with the "refuse zero hosts" test taking up to 4 seconds due to `sleep 2.5` in `apply_scan_diff`.

**How the window count math works:** `build_one_host_session` creates 1 window. `start_popup` adds a second window (the popup). After the popup exits, that window closes. So waiting for count N means: N host windows remain after the popup has closed.

- [ ] **Step 1: Write popup_scan.bats**

Create `sshl/tests/popup_scan.bats`:
```bash
#!/usr/bin/env bats

load test_helper

# Run popup-scan.sh in a new tmux window. Returns the pane ID.
start_popup() {
    tmux -L "$SOCKET" new-window -P -F '#{pane_id}' \
        "env SSHL_DIR_OVERRIDE='$SSHL_DIR_OVERRIDE' SSHL_SOCKET_OVERRIDE='$SOCKET' PATH='$TEST_BIN:$PATH' bash '$SSHL_SRC/popup-scan.sh'"
}

# Build a session with one host (192.0.2.1) as the baseline for popup tests.
build_one_host_session() {
    printf '192.0.2.1\tfake-host-01\n' > "$SSHL_DIR_OVERRIDE/ips.cache"
    read_cache
    build_session
}

# ── add new host ──────────────────────────────────────────────────────────────

@test "popup_scan: toggling a NEW host adds it to cache and opens a window" {
    build_one_host_session

    pane=$(start_popup)
    wait_for_pane_content "$pane" "hosts>"

    # Type IP to filter to the NEW entry only, then toggle and accept
    tmux -L "$SOCKET" send-keys -t "$pane" -l "192.0.2.2"
    sleep 0.15
    tmux -L "$SOCKET" send-keys -t "$pane" " "
    sleep 0.1
    tmux -L "$SOCKET" send-keys -t "$pane" "Enter"

    # 1 host window + 1 for 192.0.2.2; popup window closes after script exits
    wait_for_window_count 2 10

    grep -q "192.0.2.2" "$SSHL_DIR_OVERRIDE/ips.cache"
    [ "$(tmux -L "$SOCKET" list-windows -t "=$session_name" -F '#{@host_ip}' | grep -c '192.0.2.2')" -eq 1 ]
}

# ── remove current host ───────────────────────────────────────────────────────

@test "popup_scan: toggling a CURRENT host removes it from cache and kills its window" {
    # Start with 2 hosts so removing one does not trigger the zero-hosts guard
    printf '192.0.2.1\tfake-host-01\n192.0.2.2\tfake-host-02\n' > "$SSHL_DIR_OVERRIDE/ips.cache"
    read_cache
    build_session

    pane=$(start_popup)
    wait_for_pane_content "$pane" "hosts>"

    tmux -L "$SOCKET" send-keys -t "$pane" -l "192.0.2.1"
    sleep 0.15
    tmux -L "$SOCKET" send-keys -t "$pane" " "
    sleep 0.1
    tmux -L "$SOCKET" send-keys -t "$pane" "Enter"

    # 2 host windows - 1 removed = 1 remaining; popup window closes
    wait_for_window_count 1 10

    run grep "192.0.2.1" "$SSHL_DIR_OVERRIDE/ips.cache"
    [ "$status" -ne 0 ]
    [ "$(tmux -L "$SOCKET" list-windows -t "=$session_name" -F '#{@host_ip}' | grep -c '192.0.2.1')" -eq 0 ]
}

# ── escape ────────────────────────────────────────────────────────────────────

@test "popup_scan: pressing Escape makes no changes to cache or session" {
    build_one_host_session
    before=$(cat "$SSHL_DIR_OVERRIDE/ips.cache")

    pane=$(start_popup)
    wait_for_pane_content "$pane" "hosts>"

    tmux -L "$SOCKET" send-keys -t "$pane" "Escape"

    # Popup window closes; only the 1 host window remains
    wait_for_window_count 1 10

    after=$(cat "$SSHL_DIR_OVERRIDE/ips.cache")
    [ "$before" = "$after" ]
    [ "$(tmux -L "$SOCKET" list-windows -t "=$session_name" | wc -l)" -eq 1 ]
}

# ── refuse zero hosts ─────────────────────────────────────────────────────────

@test "popup_scan: toggling the only CURRENT host is refused (would leave zero)" {
    build_one_host_session
    before=$(cat "$SSHL_DIR_OVERRIDE/ips.cache")

    pane=$(start_popup)
    wait_for_pane_content "$pane" "hosts>"

    # Cursor starts on CURRENT 192.0.2.1. Toggle it and accept without filtering
    # (typing a fuzzy query risks matching the NEW 192.0.2.2 row as well).
    tmux -L "$SOCKET" send-keys -t "$pane" " "
    sleep 0.15
    tmux -L "$SOCKET" send-keys -t "$pane" "Enter"

    # apply_scan_diff sleeps 2.5s when refusing; allow up to 8s total
    wait_for_window_count 1 8

    after=$(cat "$SSHL_DIR_OVERRIDE/ips.cache")
    [ "$before" = "$after" ]
    [ "$(tmux -L "$SOCKET" list-windows -t "=$session_name" | wc -l)" -eq 1 ]
}

# ── add and remove in the same run ────────────────────────────────────────────

@test "popup_scan: toggling CURRENT and NEW in the same run applies both" {
    build_one_host_session

    pane=$(start_popup)
    wait_for_pane_content "$pane" "hosts>"

    # fzf --reverse lists items in input order: CURRENT 192.0.2.1 first, NEW 192.0.2.2 second.
    # Cursor starts on the first item. First Space toggles 192.0.2.1 and moves cursor down.
    # Second Space toggles 192.0.2.2. Enter accepts (flag was set by first Space).
    tmux -L "$SOCKET" send-keys -t "$pane" " "
    sleep 0.15
    tmux -L "$SOCKET" send-keys -t "$pane" " "
    sleep 0.1
    tmux -L "$SOCKET" send-keys -t "$pane" "Enter"

    # Net result: 1 host (192.0.2.2 added, 192.0.2.1 removed); popup window closes
    wait_for_window_count 1 10

    run grep "192.0.2.1" "$SSHL_DIR_OVERRIDE/ips.cache"
    [ "$status" -ne 0 ]
    grep -q "192.0.2.2" "$SSHL_DIR_OVERRIDE/ips.cache"
}
```

- [ ] **Step 2: Run popup_scan.bats**

```bash
bats sshl/tests/popup_scan.bats
```
Expected: all tests pass. The "refuse zero hosts" test will take ~3-4 seconds — this is normal.

- [ ] **Step 3: Commit**

```bash
git add sshl/tests/popup_scan.bats
git commit -m "Add popup_scan.bats: fzf interaction tests driven via tmux send-keys"
```

---

### Task 6: Write GitHub Actions workflow

**Files:**
- Create: `.github/workflows/test-sshl.yml`

- [ ] **Step 1: Create the workflow file**

```bash
mkdir -p .github/workflows
```

Create `.github/workflows/test-sshl.yml`:
```yaml
name: Test sshl
on:
  push:
    paths: ['sshl/**', '.github/workflows/test-sshl.yml']
  pull_request:
    paths: ['sshl/**', '.github/workflows/test-sshl.yml']

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install dependencies
        run: sudo apt-get install -y tmux bats fzf
      - name: Run sshl tests
        run: bats sshl/tests/
```

- [ ] **Step 2: Validate YAML**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/test-sshl.yml')); print('YAML valid')"
```
Expected: `YAML valid`

- [ ] **Step 3: Run the full test suite one final time**

```bash
bats sshl/tests/
```
Expected: all tests across all three files pass.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/test-sshl.yml
git commit -m "Add GitHub Actions workflow for sshl tests"
```
