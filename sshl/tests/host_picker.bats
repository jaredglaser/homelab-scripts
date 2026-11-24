#!/usr/bin/env bats
# shellcheck disable=SC2154  # session_name is set by sshl-lib.sh

load test_helper

setup() {
    sshl_setup
    unset TMUX
    install_tmux_guard
}

teardown() {
    local refused=""
    [[ -s "${TMUX_GUARD_LOG:-}" ]] && refused="$(cat "$TMUX_GUARD_LOG")"
    sshl_teardown
    if [[ -n "$refused" ]]; then
        echo "$refused" >&2
        return 1
    fi
}

@test "host-picker: jumps to the picked host's window on the sshl socket" {
    printf '192.0.2.1\tfake-host-01\n192.0.2.2\tfake-host-02\n' > "$SSHL_DATA_DIR_OVERRIDE/ips.cache"
    read_cache
    build_session
    stub_cmd fzf 'grep 192.0.2.2'
    tmux -L "$SOCKET" select-window -t "=$session_name:^"

    "$SSHL_SRC/host-picker.sh"
    [ "$(tmux -L "$SOCKET" display -p -t "=$session_name:" '#{@host_ip}')" = "192.0.2.2" ]
}

@test "host-picker: lists each window by the name on its tab" {
    echo "host.192.0.2.2.name=renamed" >> "$SSHL_DATA_DIR_OVERRIDE/config"
    unset _SSHL_LIB
    source "$SSHL_SRC/sshl-lib.sh"
    printf '192.0.2.1\tfake-host-01\n192.0.2.2\tfake-host-02\n' > "$SSHL_DATA_DIR_OVERRIDE/ips.cache"
    read_cache
    build_session
    # shellcheck disable=SC2016  # expanded by the stub, not here
    stub_cmd fzf 'tee "$SSHL_DATA_DIR_OVERRIDE/fzf.in" | grep 192.0.2.2'

    "$SSHL_SRC/host-picker.sh"
    [ "$(tr -s ' ' < "$SSHL_DATA_DIR_OVERRIDE/fzf.in")" = $'192.0.2.1 fake-host-01\n192.0.2.2 renamed' ]
    [ "$(tmux -L "$SOCKET" display -p -t "=$session_name:" '#{@host_ip}')" = "192.0.2.2" ]
}

@test "host-picker: inside the session with only \$TMUX set, it lists and jumps on that server" {
    printf '192.0.2.1\tfake-host-01\n192.0.2.2\tfake-host-02\n' > "$SSHL_DATA_DIR_OVERRIDE/ips.cache"
    read_cache
    build_session
    # shellcheck disable=SC2016  # expanded by the stub, not here
    stub_cmd fzf 'tee "$SSHL_DATA_DIR_OVERRIDE/fzf.in" | grep 192.0.2.2'
    tmux -L "$SOCKET" select-window -t "=$session_name:^"
    local socket_path sid
    socket_path="$(tmux -L "$SOCKET" display -p '#{socket_path}')"
    sid="$(tmux -L "$SOCKET" display -p -t "=$session_name:" '#{session_id}')"

    env -u SSHL_SOCKET_OVERRIDE TMUX="$socket_path,$$,${sid#\$}" \
        TMUX_HOMELAB_CACHE="$SSHL_DATA_DIR_OVERRIDE/ips.cache" "$SSHL_SRC/host-picker.sh"
    [ "$(awk '{print $1}' "$SSHL_DATA_DIR_OVERRIDE/fzf.in" | tr '\n' ' ')" = "192.0.2.1 192.0.2.2 " ]
    [ "$(tmux -L "$SOCKET" display -p -t "=$session_name:" '#{@host_ip}')" = "192.0.2.2" ]
}
