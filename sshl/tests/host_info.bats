#!/usr/bin/env bats
# shellcheck disable=SC2154  # session_name is set by sshl-lib.sh

load test_helper

IP=192.0.2.10

setup() {
    sshl_setup
    unset TMUX
    HI="$SSHL_SRC/host-info.sh"
    export XDG_RUNTIME_DIR="$SSHL_DIR_OVERRIDE/run" HOME="$SSHL_DIR_OVERRIDE/home"
    mkdir -m 700 "$XDG_RUNTIME_DIR" "$HOME"
    CACHE_DIR="$XDG_RUNTIME_DIR/sshl-host-info"
    export SSH_LOG="$SSHL_DIR_OVERRIDE/ssh.log" SSH_OUT="$SSHL_DIR_OVERRIDE/ssh.out" \
        SSH_GATE="$SSHL_DIR_OVERRIDE/ssh.gate"
    : > "$SSH_LOG"
    touch "$SSH_GATE"
    printf 'SSHL\t90000\t3\n' > "$SSH_OUT"
    # Logs the destination, holds until the gate file exists (capped at
    # 10s), then prints the fixture for that destination. baduser fails
    # the way an auth error does.
    # shellcheck disable=SC2016  # expanded by the stub, not here
    stub_cmd ssh 'dest="${*: -2:1}"
printf "%s\n" "$dest" >> "$SSH_LOG"
for _ in $(seq 1 200); do [[ -e "$SSH_GATE" ]] && break; sleep 0.05; done
echo "noise on stderr" >&2
f="$SSH_OUT.$dest"
[[ -e "$f" ]] || f="$SSH_OUT"
[[ "$dest" == baduser@* ]] && exit 255
cat "$f"'
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

ssh_count() { wc -l < "$SSH_LOG"; }
ssh_count_is() { [ "$(ssh_count)" -eq "$1" ]; }
fetch_done() { [ ! -e "$CACHE_DIR/$1.fetching" ] && [ -f "$CACHE_DIR/$1" ]; }
wait_fetch_done() { wait_until 10 fetch_done "$1"; }

start_test_server() {
    tmux -L "$SOCKET" -f /dev/null new-session -d -s "$session_name" sleep 300
    tmux -L "$SOCKET" set -g status-interval 5
}

status_interval_is() {
    [ "$(tmux -L "$SOCKET" show -gv status-interval)" = "$1" ]
}

@test "host-info: a cold cache prints the loading line and starts one fetch" {
    rm -f "$SSH_GATE"
    run "$HI" testuser "$IP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"loading…"* ]]
    wait_until 5 ssh_count_is 1
    touch "$SSH_GATE"
    wait_fetch_done "testuser@$IP"
    run "$HI" testuser "$IP"
    [ "$output" = "up 1d1h · updates 3 · < 1m" ]
    ssh_count_is 1
}

@test "host-info: callers during a slow fetch print a line and start no second fetch" {
    rm -f "$SSH_GATE"
    "$HI" testuser "$IP" > /dev/null
    wait_until 5 ssh_count_is 1
    run "$HI" testuser "$IP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"loading…"* ]]
    run "$HI" -f testuser "$IP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"loading…"* ]]
    touch "$SSH_GATE"
    wait_fetch_done "testuser@$IP"
    ssh_count_is 1
}

@test "host-info: concurrent cold callers each print a line and share one fetch" {
    rm -f "$SSH_GATE"
    local i
    for i in $(seq 1 20); do
        "$HI" testuser "$IP" > "$SSHL_DIR_OVERRIDE/out.$i" 2>&1 &
    done
    wait
    for i in $(seq 1 20); do
        [[ "$(cat "$SSHL_DIR_OVERRIDE/out.$i")" == *"loading…"* ]] || {
            echo "caller $i printed: $(cat "$SSHL_DIR_OVERRIDE/out.$i")" >&2
            return 1
        }
    done
    touch "$SSH_GATE"
    wait_fetch_done "testuser@$IP"
    ssh_count_is 1
}

@test "host-info: a banner before the data is skipped and the entry is not refetched" {
    printf 'Welcome to host\nLast login: yesterday\nSSHL\t90000\t3\n' > "$SSH_OUT"
    "$HI" testuser "$IP" > /dev/null
    wait_fetch_done "testuser@$IP"
    run "$HI" testuser "$IP"
    [ "$output" = "up 1d1h · updates 3 · < 1m" ]
    run "$HI" testuser "$IP"
    ssh_count_is 1
}

@test "host-info: a garbage uptime stores the unknown entry" {
    printf 'SSHL\tabc\t3\n' > "$SSH_OUT"
    "$HI" testuser "$IP" > /dev/null
    wait_fetch_done "testuser@$IP"
    [ "$(cat "$CACHE_DIR/testuser@$IP")" = $'?\t?' ]
    run "$HI" testuser "$IP"
    [ "$output" = "up ? · updates ? · < 1m" ]
    ssh_count_is 1
}

@test "host-info: a garbage update count stores the unknown entry" {
    printf 'SSHL\t90000\t3x\n' > "$SSH_OUT"
    "$HI" testuser "$IP" > /dev/null
    wait_fetch_done "testuser@$IP"
    run "$HI" testuser "$IP"
    [ "$output" = "up ? · updates ? · < 1m" ]
    ssh_count_is 1
}

@test "host-info: tmux markup in the update count never reaches the output" {
    printf 'SSHL\t90000\t#[bg=red]#{pid}\n' > "$SSH_OUT"
    "$HI" testuser "$IP" > /dev/null
    wait_fetch_done "testuser@$IP"
    run "$HI" testuser "$IP"
    [ "$output" = "up ? · updates ? · < 1m" ]
}

@test "host-info: tmux markup planted in the cache never reaches the output" {
    mkdir -m 700 "$CACHE_DIR"
    printf '90000\t#[bg=red]#{pid}\n' > "$CACHE_DIR/testuser@$IP"
    run "$HI" testuser "$IP"
    [[ "$output" != *"bg=red"* && "$output" != *"#{"* ]]
}

@test "host-info: an uptime and count with leading zeros are read as decimal" {
    printf 'SSHL\t0090000\t08\n' > "$SSH_OUT"
    "$HI" testuser "$IP" > /dev/null
    wait_fetch_done "testuser@$IP"
    run "$HI" testuser "$IP"
    [ "$status" -eq 0 ]
    [ "$output" = "up 1d1h · updates 8 · < 1m" ]
}

@test "host-info: the remote script prints one tagged line" {
    local sandbox="$SSHL_DIR_OVERRIDE/sandbox" tool
    mkdir "$sandbox"
    for tool in awk tail wc cat; do ln -s "$(command -v "$tool")" "$sandbox/$tool"; done
    printf '#!/bin/sh\necho 1000\n' > "$sandbox/id"
    printf '#!/bin/sh\nprintf "Listing...\\na/stable 2 amd64 [upgradable from: 1]\\nb/stable 2 amd64 [upgradable from: 1]\\n"\n' > "$sandbox/apt"
    chmod +x "$sandbox/id" "$sandbox/apt"
    # Runs the remote script locally with only the sandbox on PATH, so the
    # apt and id stubs answer and no real package tool can run.
    stub_cmd ssh "printf '%s\n' \"\${*: -2:1}\" >> \"\$SSH_LOG\"
exec env -i PATH='$sandbox' /bin/bash -c \"\${*: -1}\""
    "$HI" testuser "$IP" > /dev/null
    wait_fetch_done "testuser@$IP"
    run cat "$CACHE_DIR/testuser@$IP"
    local tab=$'\t'
    [[ "$output" =~ ^[0-9]+${tab}2$ ]]
}

@test "host-info: a wrong-user entry and a right-user entry do not collide" {
    printf 'SSHL\t90000\t3\n' > "$SSH_OUT.root@$IP"
    "$HI" baduser "$IP" > /dev/null
    wait_fetch_done "baduser@$IP"
    run "$HI" baduser "$IP"
    [ "$output" = "up ? · updates ? · < 1m" ]

    "$HI" root "$IP" > /dev/null
    wait_fetch_done "root@$IP"
    run "$HI" root "$IP"
    [ "$output" = "up 1d1h · updates 3 · < 1m" ]

    run "$HI" baduser "$IP"
    [ "$output" = "up ? · updates ? · < 1m" ]
    ssh_count_is 2
}

@test "host-info: -f refetches a fresh entry, keeps its values meanwhile and paces the bar at 1 Hz" {
    start_test_server
    "$HI" testuser "$IP" > /dev/null
    wait_fetch_done "testuser@$IP"

    printf 'SSHL\t90000\t5\n' > "$SSH_OUT"
    rm -f "$SSH_GATE"
    run "$HI" -f testuser "$IP"
    [ "$status" -eq 0 ]
    [[ "$output" == "up 1d1h · updates #[fg=colour208]"*"#[fg=colour252] · < 1m" ]]
    status_interval_is 1
    run "$HI" testuser "$IP"
    [[ "$output" == "up 1d1h · updates #[fg=colour208]"*"#[fg=colour252] · < 1m" ]]

    touch "$SSH_GATE"
    wait_fetch_done "testuser@$IP"
    wait_until 5 status_interval_is 5
    run "$HI" testuser "$IP"
    [ "$output" = "up 1d1h · updates 5 · < 1m" ]
    ssh_count_is 2
}

@test "host-info: -f follows \$TMUX when no socket override is set" {
    start_test_server
    local socket_path
    socket_path="$(tmux -L "$SOCKET" display -p '#{socket_path}')"
    rm -f "$SSH_GATE"
    env -u SSHL_SOCKET_OVERRIDE TMUX="$socket_path,1,0" "$HI" -f testuser "$IP" > /dev/null
    status_interval_is 1
    touch "$SSH_GATE"
    wait_fetch_done "testuser@$IP"
    wait_until 5 status_interval_is 5
}

@test "host-info: an unknown entry is retried after 5 minutes and a good one after a day" {
    mkdir -m 700 "$CACHE_DIR"
    local now
    now=$(date +%s)
    printf '?\t?\n'       > "$CACHE_DIR/testuser@192.0.2.11"
    printf '?\t?\n'       > "$CACHE_DIR/testuser@192.0.2.12"
    printf '90000\t3\n'   > "$CACHE_DIR/testuser@192.0.2.13"
    printf '90000\t3\n'   > "$CACHE_DIR/testuser@192.0.2.14"
    touch -d "@$(( now - 200 ))"   "$CACHE_DIR/testuser@192.0.2.11"
    touch -d "@$(( now - 400 ))"   "$CACHE_DIR/testuser@192.0.2.12"
    touch -d "@$(( now - 400 ))"   "$CACHE_DIR/testuser@192.0.2.13"
    touch -d "@$(( now - 90000 ))" "$CACHE_DIR/testuser@192.0.2.14"
    local ip
    for ip in 192.0.2.11 192.0.2.12 192.0.2.13 192.0.2.14; do
        "$HI" testuser "$ip" > /dev/null
        wait_fetch_done "testuser@$ip"
    done
    [ "$(sort "$SSH_LOG" | tr '\n' ' ')" = "testuser@192.0.2.12 testuser@192.0.2.14 " ]
}

@test "host-info: a marker left by a killed fetch does not pin the spinner" {
    mkdir -m 700 "$CACHE_DIR"
    printf '90000\t3\n' > "$CACHE_DIR/testuser@$IP"
    : > "$CACHE_DIR/testuser@$IP.fetching"
    run "$HI" testuser "$IP"
    [ "$output" = "up 1d1h · updates 3 · < 1m" ]
    [ ! -e "$CACHE_DIR/testuser@$IP.fetching" ]
    ssh_count_is 0
}

@test "host-info: the cache lives under XDG_RUNTIME_DIR with mode 700" {
    "$HI" testuser "$IP" > /dev/null
    wait_fetch_done "testuser@$IP"
    [ "$(stat -c %a "$CACHE_DIR")" = "700" ]
}

@test "host-info: the cache falls back to ~/.cache without XDG_RUNTIME_DIR" {
    env -u XDG_RUNTIME_DIR "$HI" testuser "$IP" > /dev/null
    CACHE_DIR="$HOME/.cache/sshl-host-info"
    wait_fetch_done "testuser@$IP"
    [ "$(stat -c %a "$CACHE_DIR")" = "700" ]
    [ ! -e "$XDG_RUNTIME_DIR/sshl-host-info" ]
}

@test "host-info: ssh errors are not written through a planted symlink" {
    export TMPDIR="$SSHL_DIR_OVERRIDE/tmp"
    mkdir -p "$TMPDIR/tmux-homelab-info" "$CACHE_DIR"
    chmod 700 "$CACHE_DIR"
    echo keep > "$SSHL_DIR_OVERRIDE/victim"
    ln -s "$SSHL_DIR_OVERRIDE/victim" "$TMPDIR/tmux-homelab-info/$IP.err"
    ln -s "$SSHL_DIR_OVERRIDE/victim" "$CACHE_DIR/testuser@$IP.err"
    "$HI" testuser "$IP" > /dev/null
    wait_until 10 fetch_done "testuser@$IP"
    [ "$(cat "$SSHL_DIR_OVERRIDE/victim")" = "keep" ]
}

@test "host-info: a user or host that is not a plain name is refused" {
    run "$HI" -- "$IP"
    [ "$output" = "host-info: invalid user or host" ]
    run "$HI" "../x" "$IP"
    [ "$output" = "host-info: invalid user or host" ]
    ssh_count_is 0
}

# The status line is drawn from the real homelab.tmux.conf. The info
# script path contains a space to cover the quoting in status-format[1].
@test "host-info: in a real status line the spinner advances while one fetch runs" {
    local wrapdir="$SSHL_DIR_OVERRIDE/dir with space" inv="$SSHL_DIR_OVERRIDE/invocations"
    mkdir "$wrapdir"
    : > "$inv"
    cat > "$wrapdir/info wrapper.sh" << EOF
#!/usr/bin/env bash
out=\$('$HI' "\$@")
printf '%s %s\n' "\$(date +%s)" "\$out" >> '$inv'
printf '%s\n' "\$out"
EOF
    chmod +x "$wrapdir/info wrapper.sh"

    tmux -L "$SOCKET" -f "$SSHL_SRC/homelab.tmux.conf" new-session -d -s "$session_name" sleep 300
    tmux -L "$SOCKET" set -g @info_script "$wrapdir/info wrapper.sh"
    tmux -L "$SOCKET" set -w -t "=$session_name:" @host_user testuser
    tmux -L "$SOCKET" set -w -t "=$session_name:" @host_ip "$IP"
    tmux -L "$SOCKET" set -g status-interval 1
    # Jobs must find the server through $TMUX, as they do under sshl.
    tmux -L "$SOCKET" set-environment -g -u SSHL_SOCKET_OVERRIDE

    rm -f "$SSH_GATE"
    attach_grouped_client "$SSHL_DIR_OVERRIDE/typescript"
    wait_until 10 grep -q 'clients 1' "$SSHL_DIR_OVERRIDE/typescript"
    wait_until 10 grep -q 'dead 0' "$SSHL_DIR_OVERRIDE/typescript"

    inv_count_ge() { [ "$(wc -l < "$inv")" -ge "$1" ]; }
    wait_until 10 inv_count_ge 4
    ssh_count_is 1
    [ "$(awk '{print $2}' "$inv" | sort -u | wc -l)" -ge 2 ]

    touch "$SSH_GATE"
    wait_fetch_done "testuser@$IP"
    wait_until 10 grep -q 'up 1d1h · updates 3' "$inv"

    tmux -L "$SOCKET" set -g status-interval 5
    printf 'SSHL\t90000\t5\n' > "$SSH_OUT"
    rm -f "$SSH_GATE"
    tmux -L "$SOCKET" run-shell -b -t "=$session_name:" \
        "'#{@info_script}' -f '#{@host_user}' '#{@host_ip}' >/dev/null 2>&1"
    wait_until 10 status_interval_is 1
    touch "$SSH_GATE"
    wait_until 10 status_interval_is 5
    ssh_count_is 2
}
