#!/usr/bin/env bats
# shellcheck disable=SC2154  # session_name and the caches are set by sshl-lib.sh

load test_helper

# Run popup-scan.sh in a new tmux window. Returns the pane ID.
start_popup() {
    start_popup_window popup-scan.sh
}

# Build a session with one host (192.0.2.1) as the baseline for popup tests.
build_one_host_session() {
    printf '192.0.2.1\tfake-host-01\n' > "$SSHL_DATA_DIR_OVERRIDE/ips.cache"
    read_cache
    build_session
}

# fzf's info line reads "<matched>/<total> (<ticked>)".
wait_for_info() {
    wait_for_pane_content "$1" "$2/2 ($3)"
}

# Left button press and release at a column and row of the pane, in the
# SGR encoding fzf asks the terminal for. Two in a row are a double-click.
double_click() {
    local m=$'\e[<0;5;'"$2"'M'$'\e[<0;5;'"$2"'m'
    tmux -L "$SOCKET" send-keys -t "$1" -l "$m$m"
}

# Screen row (1-based) of the first line of the pane that matches a pattern.
row_of() {
    tmux -L "$SOCKET" capture-pane -t "$1" -p | grep -n -m1 -- "$2" | cut -d: -f1
}

@test "apply_scan_diff: returns 0 when no session exists yet (first run)" {
    source "$SSHL_SRC/popup-scan.sh"
    # shellcheck disable=SC2034,SC2079  # an associative array read by apply_scan_diff
    discovered_name=(["192.0.2.1"]="fake-host-01")
    # shellcheck disable=SC2034  # passed to apply_scan_diff by name
    local to_add=("192.0.2.1") to_remove=()
    apply_scan_diff to_add to_remove
    [ "$(cat "$SSHL_DATA_DIR_OVERRIDE/ips.cache")" = $'192.0.2.1\tfake-host-01' ]
}

@test "apply_scan_diff: a host whose window fails is reported, the rest are added, and it fails" {
    build_one_host_session
    source "$SSHL_SRC/popup-scan.sh"
    fail_split_for_host 192.0.2.2
    # shellcheck disable=SC2034,SC2079  # an associative array read by apply_scan_diff
    discovered_name=(["192.0.2.2"]="fake-host-02" ["192.0.2.3"]="fake-host-03")
    # shellcheck disable=SC2034  # passed to apply_scan_diff by name
    local to_add=("192.0.2.2" "192.0.2.3") to_remove=()
    local rc=0
    apply_scan_diff to_add to_remove 2> "$SSHL_DATA_DIR_OVERRIDE/err.log" || rc=$?
    [ "$rc" -ne 0 ]
    [[ "$(cat "$SSHL_DATA_DIR_OVERRIDE/err.log")" == *"192.0.2.2 (fake-host-02)"* ]]
    [[ "$(cat "$SSHL_DATA_DIR_OVERRIDE/err.log")" == *"Added 2, removed 0."* ]]
    [ "$(live_order)" = "192.0.2.1 192.0.2.3 " ]
}

@test "popup_scan: toggling a NEW host adds it to cache and opens a window" {
    require_popup_fzf
    build_one_host_session

    pane=$(start_popup)
    wait_for_info "$pane" 2 0

    # Type IP to filter to the NEW entry only, then toggle and accept
    tmux -L "$SOCKET" send-keys -t "$pane" -l "192.0.2.2"
    wait_for_info "$pane" 1 0
    tmux -L "$SOCKET" send-keys -t "$pane" " "
    wait_for_info "$pane" 1 1
    tmux -L "$SOCKET" send-keys -t "$pane" "Enter"

    wait_for_popup_exit "$pane" 0
    [ "$(live_order)" = "192.0.2.1 192.0.2.2 " ]
    grep -q "192.0.2.2" "$SSHL_DATA_DIR_OVERRIDE/ips.cache"
}

@test "popup_scan: toggling a CURRENT host removes it from cache and kills its window" {
    require_popup_fzf
    # Start with 2 hosts so removing one does not trigger the zero-hosts guard
    printf '192.0.2.1\tfake-host-01\n192.0.2.2\tfake-host-02\n' > "$SSHL_DATA_DIR_OVERRIDE/ips.cache"
    read_cache
    build_session

    pane=$(start_popup)
    wait_for_info "$pane" 2 0

    tmux -L "$SOCKET" send-keys -t "$pane" -l "192.0.2.1"
    wait_for_info "$pane" 1 0
    tmux -L "$SOCKET" send-keys -t "$pane" " "
    wait_for_info "$pane" 1 1
    tmux -L "$SOCKET" send-keys -t "$pane" "Enter"

    wait_for_popup_exit "$pane" 0
    [ "$(live_order)" = "192.0.2.2 " ]
    run grep "192.0.2.1" "$SSHL_DATA_DIR_OVERRIDE/ips.cache"
    [ "$status" -ne 0 ]
    grep -q "192.0.2.1" "$SSHL_DATA_DIR_OVERRIDE/ignored.cache"
}

@test "popup_scan: pressing Escape makes no changes to cache or session" {
    require_popup_fzf
    build_one_host_session
    before=$(cat "$SSHL_DATA_DIR_OVERRIDE/ips.cache")

    pane=$(start_popup)
    wait_for_info "$pane" 2 0
    tmux -L "$SOCKET" send-keys -t "$pane" "Escape"

    wait_for_popup_exit "$pane" 0
    [ "$(cat "$SSHL_DATA_DIR_OVERRIDE/ips.cache")" = "$before" ]
    [ "$(live_order)" = "192.0.2.1 " ]
}

@test "popup_scan: toggling the only CURRENT host is refused (would leave zero)" {
    require_popup_fzf
    build_one_host_session
    before=$(cat "$SSHL_DATA_DIR_OVERRIDE/ips.cache")

    pane=$(start_popup)
    wait_for_info "$pane" 2 0

    # Cursor starts on CURRENT 192.0.2.1. Toggle it and accept without filtering
    # (typing a fuzzy query risks matching the NEW 192.0.2.2 row as well).
    tmux -L "$SOCKET" send-keys -t "$pane" " "
    wait_for_info "$pane" 2 1
    tmux -L "$SOCKET" send-keys -t "$pane" "Enter"

    # The refusal exits non-zero, and its message stays in the pane.
    wait_for_popup_exit "$pane" 1
    wait_for_pane_content "$pane" "Refusing: would leave zero hosts"
    [ "$(cat "$SSHL_DATA_DIR_OVERRIDE/ips.cache")" = "$before" ]
    [ "$(live_order)" = "192.0.2.1 " ]
}

@test "popup_scan: toggling CURRENT and NEW in the same run applies both" {
    require_popup_fzf
    build_one_host_session

    pane=$(start_popup)
    wait_for_info "$pane" 2 0

    # fzf --reverse lists items in input order: CURRENT 192.0.2.1 first, NEW 192.0.2.2 second.
    # Each Space ticks the row under the cursor and moves down.
    tmux -L "$SOCKET" send-keys -t "$pane" " "
    wait_for_info "$pane" 2 1
    tmux -L "$SOCKET" send-keys -t "$pane" " "
    wait_for_info "$pane" 2 2
    tmux -L "$SOCKET" send-keys -t "$pane" "Enter"

    wait_for_popup_exit "$pane" 0
    [ "$(cut -f1 "$SSHL_DATA_DIR_OVERRIDE/ips.cache" | tr '\n' ' ')" = "192.0.2.2 " ]
    [ "$(live_order)" = "192.0.2.2 " ]
}

@test "popup_scan: tick, untick, Enter changes nothing" {
    require_popup_fzf
    build_one_host_session
    before=$(cat "$SSHL_DATA_DIR_OVERRIDE/ips.cache")

    pane=$(start_popup)
    wait_for_info "$pane" 2 0
    tmux -L "$SOCKET" send-keys -t "$pane" " "
    wait_for_info "$pane" 2 1
    tmux -L "$SOCKET" send-keys -t "$pane" Up " "
    wait_for_info "$pane" 2 0
    # The cursor now rests on the NEW row, which a bare accept would add.
    tmux -L "$SOCKET" send-keys -t "$pane" "Enter"

    wait_for_popup_exit "$pane" 0
    [ "$(cat "$SSHL_DATA_DIR_OVERRIDE/ips.cache")" = "$before" ]
    [ ! -s "$SSHL_DATA_DIR_OVERRIDE/ignored.cache" ]
    [ "$(live_order)" = "192.0.2.1 " ]
}

@test "popup_scan: a double-click with nothing ticked changes nothing" {
    require_popup_fzf
    build_one_host_session
    before=$(cat "$SSHL_DATA_DIR_OVERRIDE/ips.cache")

    pane=$(start_popup)
    wait_for_info "$pane" 2 0
    tmux -L "$SOCKET" send-keys -t "$pane" " "
    wait_for_info "$pane" 2 1
    tmux -L "$SOCKET" send-keys -t "$pane" Up " "
    wait_for_info "$pane" 2 0
    double_click "$pane" "$(row_of "$pane" 'NEW  ')"

    wait_for_popup_exit "$pane" 0
    [ "$(cat "$SSHL_DATA_DIR_OVERRIDE/ips.cache")" = "$before" ]
    [ "$(live_order)" = "192.0.2.1 " ]
}

@test "popup_scan: a double-click with a row ticked applies it" {
    require_popup_fzf
    build_one_host_session

    pane=$(start_popup)
    wait_for_info "$pane" 2 0
    tmux -L "$SOCKET" send-keys -t "$pane" Down " "
    wait_for_info "$pane" 2 1
    double_click "$pane" "$(row_of "$pane" 'NEW  ')"

    wait_for_popup_exit "$pane" 0
    [ "$(live_order)" = "192.0.2.1 192.0.2.2 " ]
}

@test "popup_scan: an fzf failure is an error, not \"No changes.\"" {
    stub_fzf 'cat > /dev/null; echo "fzf: something broke" >&2; exit 2'
    source "$SSHL_SRC/popup-scan.sh"
    local rc=0
    popup_scan 2> "$SSHL_DATA_DIR_OVERRIDE/err.log" || rc=$?
    [ "$rc" -ne 0 ]
    grep -q 'Error: fzf failed with exit status 2' "$SSHL_DATA_DIR_OVERRIDE/err.log"
    run grep 'No changes' "$SSHL_DATA_DIR_OVERRIDE/err.log"
    [ "$status" -ne 0 ]
}

@test "popup-scan.sh: an fzf older than the minimum fails before scanning and names both versions" {
    stub_fzf 'exit 0' 0.44.1
    # shellcheck disable=SC2016  # expanded by the stub, not here
    stub_cmd nmap 'touch "$SSHL_DATA_DIR_OVERRIDE/nmap.ran"'
    run "$SSHL_SRC/popup-scan.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"fzf $SSHL_FZF_MIN or newer is required, found 0.44.1"* ]]
    [ ! -e "$SSHL_DATA_DIR_OVERRIDE/nmap.ran" ]
}

@test "popup-scan.sh: a failure in a popup ends with how to close it" {
    stub_fzf 'exit 0' 0.44.1
    run env SSHL_POPUP=1 "$SSHL_SRC/popup-scan.sh"
    [ "$status" -ne 0 ]
    [[ "${lines[-1]}" == "Press Esc to close this popup." ]]
}

@test "popup_scan: the host list has no preview, so browsing it logs in nowhere" {
    # shellcheck disable=SC2016  # expanded by the stub, not here
    stub_fzf 'printf "%s\n" "$@" > "$SSHL_DATA_DIR_OVERRIDE/fzf.args"; cat > /dev/null; exit 130'
    source "$SSHL_SRC/popup-scan.sh"
    popup_scan 2>/dev/null
    grep -q -- '--multi' "$SSHL_DATA_DIR_OVERRIDE/fzf.args"
    run grep -- '--preview' "$SSHL_DATA_DIR_OVERRIDE/fzf.args"
    [ "$status" -ne 0 ]
}

@test "popup_scan: leaves no trap behind that breaks a later function return" {
    stub_fzf 'cat > /dev/null; exit 130'
    source "$SSHL_SRC/popup-scan.sh"
    popup_scan 2>/dev/null
    [ -z "$(trap -p RETURN)" ]
    later() { return 0; }
    ( set -u; later )
}

@test "popup_scan: a rescan renames a CURRENT host whose name changed" {
    printf '192.0.2.1\told-name\n' > "$SSHL_DATA_DIR_OVERRIDE/ips.cache"
    read_cache
    build_session
    stub_fzf 'cat > /dev/null; exit 130'
    source "$SSHL_SRC/popup-scan.sh"
    popup_scan 2> "$SSHL_DATA_DIR_OVERRIDE/err.log"
    grep -q 'Renamed 192.0.2.1 to fake-host-01.' "$SSHL_DATA_DIR_OVERRIDE/err.log"
    [ "$(cat "$SSHL_DATA_DIR_OVERRIDE/ips.cache")" = $'192.0.2.1\tfake-host-01' ]
    [ "$(tmux -L "$SOCKET" list-windows -t "=$session_name" -F '#{window_name} #{@host_name}')" = "fake-host-01 fake-host-01" ]
}

@test "popup_scan: a rescan leaves a host named in the config alone" {
    echo "host.192.0.2.1.name=pinned" >> "$SSHL_DATA_DIR_OVERRIDE/config"
    unset _SSHL_LIB
    source "$SSHL_SRC/sshl-lib.sh"
    printf '192.0.2.1\tpinned\n' > "$SSHL_DATA_DIR_OVERRIDE/ips.cache"
    read_cache
    build_session
    stub_fzf 'cat > /dev/null; exit 130'
    source "$SSHL_SRC/popup-scan.sh"
    popup_scan 2>/dev/null
    [ "$(cat "$SSHL_DATA_DIR_OVERRIDE/ips.cache")" = $'192.0.2.1\tpinned' ]
    [ "$(tmux -L "$SOCKET" list-windows -t "=$session_name" -F '#{window_name}')" = "pinned" ]
}

@test "popup_scan: a missing ssh is reported before the scan" {
    local pane
    pane=$(tmux -L "$SOCKET" new-session -d -P -F '#{pane_id}' -s probe \
        "env SSHL_DATA_DIR_OVERRIDE='$SSHL_DATA_DIR_OVERRIDE' SSHL_SOCKET_OVERRIDE='$SOCKET' PATH='$(path_without ssh)' bash '$SSHL_SRC/popup-scan.sh'; echo popup-exit=\$?; exec sleep 60")
    wait_for_popup_exit "$pane" 1
    tmux -L "$SOCKET" capture-pane -p -t "$pane" | grep -q "Error: 'ssh' is required but not installed"
    ! tmux -L "$SOCKET" capture-pane -p -t "$pane" | grep -q "Scanning"
}
