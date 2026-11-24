#!/usr/bin/env bats
# shellcheck disable=SC2154  # session_name and TMUX_CONF are set by sshl-lib.sh

# These run the real homelab.tmux.conf with a client attached through
# script, inside a second tmux server that plays the terminal, so each
# test sees what a user would see.

load test_helper

setup() {
    sshl_setup
    unset TMUX
    install_tmux_guard
    printf '192.0.2.1\tfake-host-01\n192.0.2.2\tfake-host-02\n' > "$SSHL_DATA_DIR_OVERRIDE/ips.cache"
    read_cache
    build_session
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

no_popup_script_running() {
    ! pgrep -f "$SSHL_SRC/popup-$1.sh" >/dev/null
}

term_hides() {
    ! term_shows "$1"
}

@test "homelab.tmux.conf: loads without errors and binds the sshl keys" {
    run tmux -L "$SOCKET" source-file "$TMUX_CONF"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    local key
    for key in H S O I r; do
        tmux -L "$SOCKET" list-keys -T prefix "$key" | grep -q "bind-key -T prefix $key "
    done
    tmux -L "$SOCKET" list-keys -T prefix S | grep -q 'display-popup -EE'
    [ "$(tmux -L "$SOCKET" show -gv remain-on-exit)" = "failed" ]
    [ "$(tmux -L "$SOCKET" show -gv @info_script)" = "$SSHL_SRC/host-info.sh" ]
}

@test "prefix S: a failing popup stays open with its error until Esc" {
    stub_cmd nmap 'echo "nmap: Failed to resolve given hostname/IP" >&2; exit 1'
    stub_fzf 'exit 2'
    attach_client_in_terminal
    term_keys C-b S
    wait_until 10 term_shows "Press Esc to close this popup."
    wait_until 10 no_popup_script_running scan
    term_shows "nmap: Failed to resolve"
    term_shows "Error: nmap failed to scan 192.0.2.0/24"
    term_keys Escape
    wait_until 5 term_hides "Press Esc to close this popup."
}

@test "prefix S: a too old fzf is reported in the popup" {
    stub_fzf 'exit 0' 0.44.1
    attach_client_in_terminal
    term_keys C-b S
    wait_until 10 term_shows "fzf 0.46.0 or newer is required, found 0.44.1"
    wait_until 10 no_popup_script_running scan
    term_shows "Press Esc to close this popup."
}

@test "prefix I: a popup that succeeds closes by itself" {
    stub_fzf 'exit 2'
    attach_client_in_terminal
    term_keys C-b I
    wait_until 10 term_shows "No ignored hosts."
    wait_until 10 no_popup_script_running ignored
    wait_until 5 term_hides "No ignored hosts."
}

@test "prefix O: a cancelled reorder closes by itself" {
    attach_client_in_terminal
    term_keys C-b O
    wait_until 10 term_shows "space grab/drop"
    term_keys q
    wait_until 10 no_popup_script_running reorder
    wait_until 5 term_hides "space grab/drop"
}
