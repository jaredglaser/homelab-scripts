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

    # Wait for window count to reach 3 (host-01 + popup + new-host-02).
    # write_cache is called before add_window so the cache is written by this point.
    wait_for_window_count 3 10

    grep -q "192.0.2.2" "$SSHL_DIR_OVERRIDE/ips.cache"
    [ "$(tmux -L "$SOCKET" list-windows -t "=$session_name" -F '#{@host_ip}' | grep -c '192.0.2.2')" -eq 1 ]
}

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

    # The window count is ambiguous here (2→1→2→1 as kill+add+close happen).
    # Sleep long enough for apply_scan_diff to finish (write_cache + tmux + sleep 1.2).
    sleep 2

    run grep "192.0.2.1" "$SSHL_DIR_OVERRIDE/ips.cache"
    [ "$status" -ne 0 ]
    grep -q "192.0.2.2" "$SSHL_DIR_OVERRIDE/ips.cache"
}
