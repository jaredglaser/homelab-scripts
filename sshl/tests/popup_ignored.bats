#!/usr/bin/env bats
# shellcheck disable=SC2154  # session_name is set by sshl-lib.sh

load test_helper

seed_ignored() {
    printf '192.0.2.8\told-a\n192.0.2.9\told-b\n' > "$SSHL_DATA_DIR_OVERRIDE/ignored.cache"
}

# Run popup-ignored.sh in a window of a one-host session. Returns the pane ID.
start_popup() {
    printf '192.0.2.1\tfake-host-01\n' > "$SSHL_DATA_DIR_OVERRIDE/ips.cache"
    read_cache
    build_session
    start_popup_window popup-ignored.sh
}

wait_for_info() {
    wait_for_pane_content "$1" "$2/2 ($3)"
}

@test "popup_ignored: ticking a host un-ignores it" {
    require_popup_fzf
    seed_ignored
    pane=$(start_popup)
    wait_for_info "$pane" 2 0
    tmux -L "$SOCKET" send-keys -t "$pane" Down " "
    wait_for_info "$pane" 2 1
    tmux -L "$SOCKET" send-keys -t "$pane" Enter
    wait_for_popup_exit "$pane" 0
    [ "$(cat "$SSHL_DATA_DIR_OVERRIDE/ignored.cache")" = $'192.0.2.8\told-a' ]
}

@test "popup_ignored: tick, untick, Enter changes nothing" {
    require_popup_fzf
    seed_ignored
    pane=$(start_popup)
    wait_for_info "$pane" 2 0
    tmux -L "$SOCKET" send-keys -t "$pane" " "
    wait_for_info "$pane" 2 1
    tmux -L "$SOCKET" send-keys -t "$pane" Up " "
    wait_for_info "$pane" 2 0
    tmux -L "$SOCKET" send-keys -t "$pane" Enter
    wait_for_popup_exit "$pane" 0
    [ "$(cat "$SSHL_DATA_DIR_OVERRIDE/ignored.cache")" = $'192.0.2.8\told-a\n192.0.2.9\told-b' ]
}

@test "popup_ignored: Escape changes nothing" {
    require_popup_fzf
    seed_ignored
    pane=$(start_popup)
    wait_for_info "$pane" 2 0
    tmux -L "$SOCKET" send-keys -t "$pane" " " Escape
    wait_for_popup_exit "$pane" 0
    [ "$(cat "$SSHL_DATA_DIR_OVERRIDE/ignored.cache")" = $'192.0.2.8\told-a\n192.0.2.9\told-b' ]
}

@test "popup_ignored: says so when nothing is ignored" {
    stub_fzf 'exit 2'
    stub_cmd sleep 'exit 0'
    source "$SSHL_SRC/popup-ignored.sh"
    run popup_ignored
    [ "$status" -eq 0 ]
    [ "$output" = "No ignored hosts." ]
}

@test "popup_ignored: a failed write is an error and keeps the file" {
    seed_ignored
    stub_fzf 'grep 192.0.2.8'
    source "$SSHL_SRC/popup-ignored.sh"
    ln -s /dev/full "$SSHL_DATA_DIR_OVERRIDE/ignored.cache.tmp.$$"
    local rc=0
    popup_ignored 2> "$SSHL_DATA_DIR_OVERRIDE/err.log" || rc=$?
    [ "$rc" -ne 0 ]
    grep -q 'Error: failed to write' "$SSHL_DATA_DIR_OVERRIDE/err.log"
    [ "$(cat "$SSHL_DATA_DIR_OVERRIDE/ignored.cache")" = $'192.0.2.8\told-a\n192.0.2.9\told-b' ]
}

@test "popup_ignored: an fzf failure is an error, not \"No changes.\"" {
    seed_ignored
    stub_fzf 'cat > /dev/null; exit 2'
    source "$SSHL_SRC/popup-ignored.sh"
    local rc=0
    popup_ignored 2> "$SSHL_DATA_DIR_OVERRIDE/err.log" || rc=$?
    [ "$rc" -ne 0 ]
    grep -q 'Error: fzf failed with exit status 2' "$SSHL_DATA_DIR_OVERRIDE/err.log"
}
