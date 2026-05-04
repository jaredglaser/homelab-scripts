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
