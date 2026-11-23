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

active_pane() {
    tmux -L "$SOCKET" display -p -t "=$session_name:" "#{$1}"
}

active_pane_is() {
    [ "$(active_pane "$1")" = "$2" ]
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

@test "prefix r: leaves a live pane running and refreshes the host info" {
    attach_client_in_terminal
    local pid
    pid="$(active_pane pane_pid)"
    term_keys C-b r
    wait_until 5 term_shows "pane is still running, not respawned. Refreshing fake-host-01"
    [ "$(active_pane pane_pid)" = "$pid" ]
    [ "$(active_pane pane_dead)" = "0" ]
    wait_until 5 test -f "$XDG_RUNTIME_DIR/sshl-host-info/testuser@192.0.2.1"
}

@test "prefix r: respawns a dead pane" {
    local marker="$SSHL_DATA_DIR_OVERRIDE/respawned"
    tmux -L "$SOCKET" respawn-pane -k -t "=$session_name:.0" \
        "if [ -e '$marker' ]; then exec sleep 30; fi; touch '$marker'; exit 3"
    wait_until 5 active_pane_is pane_dead 1
    attach_client_in_terminal
    term_keys C-b r
    wait_until 5 term_shows "respawned the pane, refreshing fake-host-01"
    wait_until 5 active_pane_is pane_current_command sleep
    [ "$(active_pane pane_dead)" = "0" ]
}

@test "pane-died: the message names the window" {
    attach_client_in_terminal
    tmux -L "$SOCKET" respawn-pane -k -t "=$session_name:.0" "exit 3"
    wait_until 5 term_shows "pane died in fake-host-01. Press <prefix> r to respawn."
    tmux -L "$SOCKET" show-messages | grep -q "pane died in fake-host-01\."
}

@test "pane-died: a pane that dies before any client attaches writes nothing into a pane" {
    tmux -L "$SOCKET" respawn-pane -k -t "=$session_name:.0" "exit 3"
    wait_until 5 active_pane_is pane_dead 1
    attach_client_in_terminal
    wait_until 10 term_shows "clients 1"
    [ "$(tmux -L "$SOCKET" list-panes -s -t "=$session_name" -F '#{pane_in_mode}' | grep -c 1)" -eq 0 ]
    term_hides "(null)"
}

# Clicks are sent as SGR mouse reports, as a terminal sends them for a
# real click, at the cell left of the refresh glyph, on it, and right of it.
# The glyph moves while a refresh redraws the text before it, so each click
# waits for an idle status line and finds the glyph again.
refresh_glyph_cell() {
    local row line prefix
    row="$(term_screen | grep -n "↻" | cut -d: -f1)"
    line="$(term_screen | sed -n "${row}p")"
    prefix="${line%%↻*}"
    printf '%s %s' "$(( $(printf %s "$prefix" | wc -m) + 1 ))" "$row"
}

@test "refresh button: a click on or next to the glyph forces a refresh" {
    # Without a UTF-8 locale tmux draws the glyph as "_", as any terminal would.
    export LANG=C.UTF-8 LC_ALL=C.UTF-8
    attach_client_in_terminal
    local col row dx
    for dx in -1 0 1; do
        tmux -L "$SOCKET" set -g display-time 100
        wait_until 10 term_hides "refreshing fake-host-01"
        wait_until 10 term_shows "updates ? ·"
        tmux -L "$SOCKET" set -g display-time 3000
        read -r col row <<<"$(refresh_glyph_cell)"
        term_keys -l $'\e[<0;'"$((col + dx))"';'"$row"'M'$'\e[<0;'"$((col + dx))"';'"$row"'m'
        wait_until 5 term_shows "refreshing fake-host-01"
    done
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
