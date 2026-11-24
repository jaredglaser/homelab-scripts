setup() {
    SSHL_SRC="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    TEST_BIN="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/bin"

    export SSHL_DIR_OVERRIDE
    SSHL_DIR_OVERRIDE="$(mktemp -d)"
    # sshl-lib.sh falls back to the real sshl directory and the real homelab
    # socket when the overrides are empty, which is what a failed mktemp gives.
    [ -d "$SSHL_DIR_OVERRIDE" ] || { echo "mktemp -d failed" >&2; return 1; }
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

    STUB_BIN="$SSHL_DIR_OVERRIDE/stub-bin"
    mkdir -p "$STUB_BIN"
    REAL_TMUX="$(command -v tmux)"
    export PATH="$STUB_BIN:$TEST_BIN:$PATH"

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

# Wait for a pane to disappear (its process exited and tmux removed it).
wait_for_pane_gone() {
    local pane="$1" timeout="${2:-10}"
    local i
    for i in $(seq 1 $(( timeout * 10 ))); do
        tmux -L "$SOCKET" list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qF "$pane" || return 0
        sleep 0.1
    done
    echo "Timeout waiting for pane $pane to disappear" >&2
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
    echo "Timeout waiting for window count: expected $expected, got $count" >&2
    return 1
}

# Write an executable stub that shadows a command for the current test only.
stub_cmd() {
    local name="$1" body="$2"
    printf '#!/usr/bin/env bash\n%s\n' "$body" > "$STUB_BIN/$name"
    chmod +x "$STUB_BIN/$name"
    # Without this, a command the test already ran stays hashed to its real path.
    hash -r
}

# Shadow tmux with a shim that fails split-window for one host, so
# add_window gives up on that host after its window already exists.
fail_split_for_host() {
    stub_cmd tmux "if [[ \" \$* \" == *' split-window '* && \" \$* \" == *' HOST_IP=$1 '* ]]; then
    echo 'simulated split-window failure' >&2
    exit 1
fi
exec '$REAL_TMUX' \"\$@\""
}

# Attach a real client to session_name through a grouped session, the way
# sshl's attach command does, and wait until tmux reports it attached.
attach_grouped_client() {
    TERM=xterm-256color script -qfc "tmux -L '$SOCKET' new-session -t '$session_name'" /dev/null \
        >/dev/null 2>&1 3>&- &
    local i
    for i in $(seq 1 100); do
        tmux -L "$SOCKET" list-sessions -F '#{session_group} #{session_attached}' 2>/dev/null \
            | grep -qx "$session_name 1" && return 0
        sleep 0.1
    done
    echo "Timeout waiting for a grouped client on $session_name" >&2
    return 1
}

# @host_ip of each window in session_name, in index order, space separated.
live_order() {
    tmux -L "$SOCKET" list-windows -t "=$session_name" -F '#{@host_ip}' | grep . | tr '\n' ' '
}
