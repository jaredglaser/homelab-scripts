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
