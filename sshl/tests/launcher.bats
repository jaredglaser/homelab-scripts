#!/usr/bin/env bats
# shellcheck disable=SC2154  # session_name is set by sshl-lib.sh

load test_helper
bats_require_minimum_version 1.5.0

setup() {
    sshl_setup
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

seed_cache() {
    printf '192.0.2.1\tfake-host-01\n192.0.2.2\tfake-host-02\n' > "$SSHL_DATA_DIR_OVERRIDE/ips.cache"
}

set_config() {
    sed -i "/^$1=/d" "$SSHL_DATA_DIR_OVERRIDE/config"
    printf '%s=%s\n' "$1" "$2" >> "$SSHL_DATA_DIR_OVERRIDE/config"
}

# A terminal emulator that logs its environment and arguments, then runs
# the command after -e in a pane of the terminal server attach_client_in_terminal
# uses, as konsole would in a window of its own.
install_fake_terminal() {
    # shellcheck disable=SC2016  # expanded by the stub, not here
    stub_cmd fake-term 'log="$SSHL_DATA_DIR_OVERRIDE/term.log"
printf "TMUX=%s\n" "${TMUX:-}" > "$log"
printf "%s\n" "$@" >> "$log"
while (( $# )) && [[ "$1" != -e ]]; do shift; done
shift
cmd="$(printf "%q " "$@")"
exec "$REAL_TMUX" -L "$SSHL_SOCKET_OVERRIDE-term" -f /dev/null new-session -d -s term -x 120 -y 40 \
    "env -u TMUX TERM=xterm-256color script -qfc $(printf "%q" "$cmd") /dev/null"'
}

@test "sshl: an unknown argument fails and names it" {
    run "$SSHL_SRC/sshl" --bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown argument: --bogus"* ]]
    run session_exists
    [ "$status" -ne 0 ]
}

@test "sshl: --help prints the usage and exits 0" {
    run "$SSHL_SRC/sshl" --help
    [ "$status" -eq 0 ]
    [[ "$output" == Usage:* ]]
    [[ "$output" == *"--rebuild"* ]]
    [[ "$output" == *"prefix is Ctrl+b"* ]]
    [[ "$output" == *"prefix r"* ]]
    [[ "$output" == *"Config: $SSHL_DATA_DIR_OVERRIDE/config"* ]]
}

@test "sshl: --rebuild without a cache starts over with a scan" {
    stub_fzf 'grep "^NEW"'
    run env -u TMUX "$SSHL_SRC/sshl" --rebuild
    [ "$status" -eq 0 ]
    [[ "$output" == *"Scanning"* ]]
    [ "$(live_order)" = "192.0.2.1 192.0.2.2 " ]
    session_is_healthy
}

@test "sshl: --rebuild without a cache, while the session runs, replaces it with a scan" {
    printf '192.0.2.9\tgone-host\n' > "$SSHL_DATA_DIR_OVERRIDE/ips.cache"
    read_cache
    build_session
    : > "$SSHL_DATA_DIR_OVERRIDE/ips.cache"
    stub_fzf 'grep "^NEW"'
    run env -u TMUX "$SSHL_SRC/sshl" --rebuild
    [ "$status" -eq 0 ]
    [ "$(live_order)" = "192.0.2.1 192.0.2.2 " ]
    session_is_healthy
}

@test "sshl: --rebuild replaces a healthy session with one built from the cache" {
    printf '192.0.2.1\tfake-host-01\n' > "$SSHL_DATA_DIR_OVERRIDE/ips.cache"
    read_cache
    build_session
    tmux -L "$SOCKET" new-window -t "=$session_name:" -n stray "sleep 30"
    seed_cache
    run env -u TMUX "$SSHL_SRC/sshl" -R
    [ "$status" -eq 0 ]
    [ "$(tmux -L "$SOCKET" list-windows -t "=$session_name" -F '#{window_name}' | tr '\n' ' ')" = "fake-host-01 fake-host-02 " ]
    session_is_healthy
}

@test "sshl: runs through a symlink" {
    seed_cache
    mkdir "$SSHL_DATA_DIR_OVERRIDE/bin"
    ln -s "$SSHL_SRC/sshl" "$SSHL_DATA_DIR_OVERRIDE/bin/sshl"
    run env -u TMUX "$SSHL_DATA_DIR_OVERRIDE/bin/sshl"
    [ "$status" -eq 0 ]
    [ "$(live_order)" = "192.0.2.1 192.0.2.2 " ]
}

@test "sshl: status lines go to stderr" {
    seed_cache
    read_cache
    build_session
    run --separate-stderr env -u TMUX "$SSHL_SRC/sshl"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    # shellcheck disable=SC2154  # set by run --separate-stderr
    [[ "$stderr" == *"Reusing existing session '$session_name'"* ]]
}

@test "sshl: a failed reload of homelab.tmux.conf is shown" {
    seed_cache
    read_cache
    build_session
    stub_cmd tmux "if [[ \" \$* \" == *' source-file '* ]]; then echo 'homelab.tmux.conf:3: unknown command: bogus' >&2; exit 1; fi
exec '$REAL_TMUX' \"\$@\""
    run env -u TMUX "$SSHL_SRC/sshl"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Warning: reloading $SSHL_SRC/homelab.tmux.conf failed"* ]]
    [[ "$output" == *"unknown command: bogus"* ]]
}

@test "sshl: from inside another tmux, the terminal starts without TMUX and attaches" {
    seed_cache
    install_fake_terminal
    set_config terminal fake-term
    run env TMUX="/tmp/tmux-other/default,1,0" "$SSHL_SRC/sshl"
    [ "$status" -eq 0 ]
    wait_for_grouped_client
    [ "$(head -n1 "$SSHL_DATA_DIR_OVERRIDE/term.log")" = "TMUX=" ]
}

@test "sshl: a terminal with arguments gets them before -e" {
    seed_cache
    install_fake_terminal
    set_config terminal "fake-term --profile x"
    run env -u TMUX "$SSHL_SRC/sshl"
    [ "$status" -eq 0 ]
    wait_for_grouped_client
    [ "$(sed -n '2,4p' "$SSHL_DATA_DIR_OVERRIDE/term.log" | tr '\n' ' ')" = "--profile x -e " ]
}

@test "sshl: without a terminal, inside the sshl server it says so" {
    seed_cache
    set_config terminal no-such-terminal
    run env TMUX="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCKET,1,0" "$SSHL_SRC/sshl"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already runs inside the sshl session"* ]]
    [[ "$output" != *"different server"* && "$output" != *"another tmux server"* ]]
}

@test "sshl: without a terminal, inside another tmux it prints the attach command" {
    seed_cache
    set_config terminal no-such-terminal
    run env TMUX="/tmp/tmux-other/default,1,0" "$SSHL_SRC/sshl"
    [ "$status" -eq 0 ]
    [[ "$output" == *"inside another tmux server"* ]]
    [[ "$output" == *"tmux -L $SOCKET -u new-session -t '=$session_name'"* ]]
}

@test "sshl: returns at once when its output is a pipe, and the terminal's output stays out of it" {
    seed_cache
    # shellcheck disable=SC2016  # expanded by the stub, not here
    stub_cmd chatty-term 'echo $$ > "$SSHL_DATA_DIR_OVERRIDE/term.pid"
echo "terminal stdout chatter"
echo "terminal stderr chatter" >&2
exec sleep 30'
    set_config terminal chatty-term
    run timeout 10 bash -c 'env -u TMUX "$1" 2>&1 | cat' _ "$SSHL_SRC/sshl"
    kill "$(cat "$SSHL_DATA_DIR_OVERRIDE/term.pid")" 2>/dev/null || true
    [ "$status" -eq 0 ]
    [[ "$output" != *"chatter"* ]]
}

@test "sshl: a terminal that fails at once is reported with its error" {
    seed_cache
    stub_cmd broken-term 'echo "broken-term: unknown option --bogus" >&2; exit 2'
    set_config terminal broken-term
    run env -u TMUX "$SSHL_SRC/sshl"
    [ "$status" -eq 1 ]
    [[ "$output" == *"broken-term: unknown option --bogus"* ]]
    [[ "$output" == *"Error: the terminal command 'broken-term' exited with status 2"* ]]
}

@test "sshl: a plain run reopens a host window whose panes both exited, in cache order" {
    printf '192.0.2.1\tfake-host-01\n192.0.2.2\tfake-host-02\n192.0.2.3\tfake-host-03\n' \
        > "$SSHL_DATA_DIR_OVERRIDE/ips.cache"
    read_cache
    build_session
    tmux -L "$SOCKET" kill-window -t "$(find_window_id_by_ip 192.0.2.2)"
    run env -u TMUX "$SSHL_SRC/sshl"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Reopened the window for 192.0.2.2 (fake-host-02)."* ]]
    [ "$(live_order)" = "192.0.2.1 192.0.2.2 192.0.2.3 " ]
    [ "$(tmux -L "$SOCKET" list-panes -t "$(find_window_id_by_ip 192.0.2.2)" | wc -l)" -eq 2 ]
}

@test "sshl: a plain run says when the config changed after the build" {
    seed_cache
    run env -u TMUX "$SSHL_SRC/sshl"
    [ "$status" -eq 0 ]
    [[ "$output" != *"changed after the session was built"* ]]
    run env -u TMUX "$SSHL_SRC/sshl"
    [[ "$output" != *"changed after the session was built"* ]]
    set_config default_user otheruser
    touch -d "@$(( $(date +%s) + 10 ))" "$SSHL_DATA_DIR_OVERRIDE/config"
    run env -u TMUX "$SSHL_SRC/sshl"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$SSHL_DATA_DIR_OVERRIDE/config changed after the session was built"* ]]
    run env -u TMUX "$SSHL_SRC/sshl" --rebuild
    [ "$status" -eq 0 ]
    run env -u TMUX "$SSHL_SRC/sshl"
    [[ "$output" != *"changed after the session was built"* ]]
}

# A terminal that records its arguments, one per line, and exits at once.
install_arg_logger() {
    # shellcheck disable=SC2016  # expanded by the stub, not here
    stub_cmd "$1" 'printf "%s\n" "$@" > "$SSHL_DATA_DIR_OVERRIDE/term.log"'
}

@test "sshl: gnome-terminal and xfce4-terminal get the option that takes a command with arguments" {
    seed_cache
    local term opt
    for term in gnome-terminal:-- xfce4-terminal:-x; do
        opt="${term#*:}" term="${term%%:*}"
        install_arg_logger "$term"
        set_config terminal "$term"
        run env -u TMUX "$SSHL_SRC/sshl"
        [ "$status" -eq 0 ]
        [ "$(head -n2 "$SSHL_DATA_DIR_OVERRIDE/term.log" | tr '\n' ' ')" = "$opt tmux " ]
    done
}

@test "sshl: a terminal value that ends in the option before the command is used as written" {
    seed_cache
    install_arg_logger fake-term
    set_config terminal "fake-term start --"
    run env -u TMUX "$SSHL_SRC/sshl"
    [ "$status" -eq 0 ]
    [ "$(head -n3 "$SSHL_DATA_DIR_OVERRIDE/term.log" | tr '\n' ' ')" = "start -- tmux " ]
}

@test "sshl: a tmux older than the minimum is reported before anything runs" {
    seed_cache
    stub_cmd tmux "if [[ \"\$1\" == -V ]]; then echo 'tmux 3.0a'; exit 0; fi
exec '$REAL_TMUX' \"\$@\""
    run env -u TMUX "$SSHL_SRC/sshl"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Error: tmux 3.2 or newer is required, found 3.0a."* ]]
    run session_exists
    [ "$status" -ne 0 ]
}

@test "sshl: a missing ssh is reported before the session is built" {
    seed_cache
    run env -u TMUX PATH="$(path_without ssh)" "$SSHL_SRC/sshl"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Error: 'ssh' is required but not installed"* ]]
    run session_exists
    [ "$status" -ne 0 ]
}
