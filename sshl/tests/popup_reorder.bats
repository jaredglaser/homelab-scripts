#!/usr/bin/env bats

load test_helper

build_three_host_session() {
    printf '192.0.2.1\ta\n192.0.2.2\tb\n192.0.2.3\tc\n' > "$SSHL_DATA_DIR_OVERRIDE/ips.cache"
    read_cache
    build_session
    source "$SSHL_SRC/popup-reorder.sh"
}

@test "apply_reorder: reorders the cache and the live windows" {
    build_three_host_session
    run apply_reorder 192.0.2.3 192.0.2.1 192.0.2.2
    [ "$status" -eq 0 ]
    [ "$(cut -f1 "$SSHL_DATA_DIR_OVERRIDE/ips.cache" | tr '\n' ' ')" = "192.0.2.3 192.0.2.1 192.0.2.2 " ]
    [ "$(live_order)" = "192.0.2.3 192.0.2.1 192.0.2.2 " ]
}

@test "apply_reorder: reorders the live windows while a grouped client is attached" {
    build_three_host_session
    attach_grouped_client
    run apply_reorder 192.0.2.2 192.0.2.1 192.0.2.3
    [ "$status" -eq 0 ]
    [ "$(cut -f1 "$SSHL_DATA_DIR_OVERRIDE/ips.cache" | tr '\n' ' ')" = "192.0.2.2 192.0.2.1 192.0.2.3 " ]
    [ "$(live_order)" = "192.0.2.2 192.0.2.1 192.0.2.3 " ]
}

@test "apply_reorder: leaves the live windows alone when the cache write fails" {
    build_three_host_session
    ln -s /dev/full "$SSHL_DATA_DIR_OVERRIDE/ips.cache.tmp.$$"
    run apply_reorder 192.0.2.3 192.0.2.2 192.0.2.1
    [ "$status" -eq 1 ]
    [ "$(cut -f1 "$SSHL_DATA_DIR_OVERRIDE/ips.cache" | tr '\n' ' ')" = "192.0.2.1 192.0.2.2 192.0.2.3 " ]
    [ "$(live_order)" = "192.0.2.1 192.0.2.2 192.0.2.3 " ]
}

@test "popup_reorder: the list scrolls so the cursor stays on screen" {
    local i
    : > "$SSHL_DATA_DIR_OVERRIDE/ips.cache"
    for i in $(seq 1 20); do
        printf '192.0.2.%d\thost-%02d\n' "$i" "$i" >> "$SSHL_DATA_DIR_OVERRIDE/ips.cache"
    done
    tmux -L "$SOCKET" -f /dev/null new-session -d -s reorder -x 80 -y 12 \
        "env SSHL_DATA_DIR_OVERRIDE='$SSHL_DATA_DIR_OVERRIDE' SSHL_SOCKET_OVERRIDE='$SOCKET' bash '$SSHL_SRC/popup-reorder.sh'"
    wait_for_pane_content reorder '^>  1  192\.0\.2\.1 '
    wait_for_pane_content reorder 'space grab/drop'
    wait_for_pane_content reorder 'rows 1-8 of 20'

    tmux -L "$SOCKET" send-keys -t reorder j j j j j j j j j j j j j j j
    wait_for_pane_content reorder '^> 16  192\.0\.2\.16 '
    wait_for_pane_content reorder 'rows 9-16 of 20'
    wait_for_pane_content reorder 'space grab/drop'

    tmux -L "$SOCKET" send-keys -t reorder q
    wait_until 5 bash -c "! tmux -L '$SOCKET' has-session -t =reorder 2>/dev/null"
}

@test "popup_reorder: Home, End, PgUp and PgDn jump, and carry a grabbed host" {
    local i
    : > "$SSHL_DATA_DIR_OVERRIDE/ips.cache"
    for i in $(seq 1 20); do
        printf '192.0.2.%d\thost-%02d\n' "$i" "$i" >> "$SSHL_DATA_DIR_OVERRIDE/ips.cache"
    done
    tmux -L "$SOCKET" -f /dev/null new-session -d -s reorder -x 80 -y 12 \
        "env SSHL_DATA_DIR_OVERRIDE='$SSHL_DATA_DIR_OVERRIDE' SSHL_SOCKET_OVERRIDE='$SOCKET' bash '$SSHL_SRC/popup-reorder.sh'"
    wait_for_pane_content reorder '^>  1  192\.0\.2\.1 '

    tmux -L "$SOCKET" send-keys -t reorder NPage
    wait_for_pane_content reorder '^>  9  192\.0\.2\.9 '
    tmux -L "$SOCKET" send-keys -t reorder End
    wait_for_pane_content reorder '^> 20  192\.0\.2\.20 '
    tmux -L "$SOCKET" send-keys -t reorder PPage
    wait_for_pane_content reorder '^> 12  192\.0\.2\.12 '
    tmux -L "$SOCKET" send-keys -t reorder G
    wait_for_pane_content reorder '^> 20  192\.0\.2\.20 '

    tmux -L "$SOCKET" send-keys -t reorder Space Home
    wait_for_pane_content reorder '^>> 1  192\.0\.2\.20 '
    tmux -L "$SOCKET" send-keys -t reorder Space Enter
    wait_until 5 bash -c "! tmux -L '$SOCKET' has-session -t =reorder 2>/dev/null"
    [ "$(cut -f1 "$SSHL_DATA_DIR_OVERRIDE/ips.cache" | head -3 | tr '\n' ' ')" = "192.0.2.20 192.0.2.1 192.0.2.2 " ]
    [ "$(wc -l < "$SSHL_DATA_DIR_OVERRIDE/ips.cache")" -eq 20 ]
}
