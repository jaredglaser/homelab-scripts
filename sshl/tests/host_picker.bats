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
    printf '192.0.2.1\tfake-host-01\n192.0.2.2\tfake-host-02\n' > "$SSHL_DIR_OVERRIDE/ips.cache"
    read_cache
    build_session
    stub_cmd fzf 'grep 192.0.2.2'
    tmux -L "$SOCKET" select-window -t "=$session_name:^"

    TMUX_HOMELAB_CACHE="$SSHL_DIR_OVERRIDE/ips.cache" "$SSHL_SRC/host-picker.sh"
    [ "$(tmux -L "$SOCKET" display -p -t "=$session_name:" '#{@host_ip}')" = "192.0.2.2" ]
}
