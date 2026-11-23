# shellcheck shell=bash
setup() {
    sshl_setup
}

teardown() {
    sshl_teardown
}

sshl_setup() {
    SSHL_SRC="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    TEST_BIN="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/bin"

    export SSHL_DATA_DIR_OVERRIDE
    SSHL_DATA_DIR_OVERRIDE="$(mktemp -d)"
    # sshl-lib.sh falls back to the real sshl directory and the real homelab
    # socket when the overrides are empty, which is what a failed mktemp gives.
    [ -d "$SSHL_DATA_DIR_OVERRIDE" ] || { echo "mktemp -d failed" >&2; return 1; }
    export SSHL_SOCKET_OVERRIDE
    SSHL_SOCKET_OVERRIDE="sshl-test-$$-${BATS_TEST_NUMBER:-0}"
    # host-info.sh keeps its cache under these, and the launcher and the
    # status bar run it.
    export XDG_RUNTIME_DIR="$SSHL_DATA_DIR_OVERRIDE/run" HOME="$SSHL_DATA_DIR_OVERRIDE/home"
    mkdir -m 700 "$XDG_RUNTIME_DIR" "$HOME"

    cat > "$SSHL_DATA_DIR_OVERRIDE/config" << 'EOF'
subnet=192.0.2.0/24
session_name=test-homelab
default_user=testuser
terminal=true
left_cmd=sleep 30
right_cmd=sleep 30
EOF

    : > "$SSHL_DATA_DIR_OVERRIDE/ips.cache"
    : > "$SSHL_DATA_DIR_OVERRIDE/ignored.cache"

    STUB_BIN="$SSHL_DATA_DIR_OVERRIDE/stub-bin"
    mkdir -p "$STUB_BIN"
    REAL_TMUX="$(command -v tmux)"
    export PATH="$STUB_BIN:$TEST_BIN:$PATH"

    unset _SSHL_LIB
    # shellcheck source=sshl/sshl-lib.sh
    source "$SSHL_SRC/sshl-lib.sh"
    # After sourcing: SOCKET=$SSHL_SOCKET_OVERRIDE, TMUX_CMD=(tmux -L "$SOCKET")
}

sshl_teardown() {
    tmux -L "$SOCKET-term" kill-server 2>/dev/null || true
    tmux -L "$SOCKET" kill-server 2>/dev/null || true
    # A host-info.sh the launcher started in the background would recreate
    # the cache directory after the rm below.
    wait_until 10 no_host_info_running || true
    rm -rf "$SSHL_DATA_DIR_OVERRIDE"
    unset SSHL_DATA_DIR_OVERRIDE SSHL_SOCKET_OVERRIDE
}

no_host_info_running() {
    ! pgrep -f "$SSHL_SRC/host-info.sh" >/dev/null
}

# Skip a test that drives the real fzf when it is older than the popups need.
require_popup_fzf() {
    local v
    v="$(fzf_version)"
    fzf_new_enough "$v" \
        || skip "the popups need fzf $SSHL_FZF_MIN or newer (for FZF_SELECT_COUNT), found ${v:-none}"
}

# Poll capture-pane until pattern appears or timeout expires.
wait_for_pane_content() {
    local pane="$1" pattern="$2" timeout="${3:-5}"
    local _
    for _ in $(seq 1 $(( timeout * 10 ))); do
        tmux -L "$SOCKET" capture-pane -t "$pane" -p 2>/dev/null | grep -q -- "$pattern" && return 0
        sleep 0.1
    done
    echo "Timeout waiting for pane content matching: $pattern" >&2
    tmux -L "$SOCKET" capture-pane -t "$pane" -p >&2 2>/dev/null || true
    return 1
}

# Run one of the popup scripts in a new window of the session and print
# the pane ID. The window stays after the script ends and shows its exit
# status: remain-on-exit failed sometimes keeps a pane whose program
# exited 0 with no status, so waiting for the pane to close is flaky.
start_popup_window() {
    local pane
    pane=$(tmux -L "$SOCKET" new-window -P -F '#{pane_id}' \
        "env SSHL_DATA_DIR_OVERRIDE='$SSHL_DATA_DIR_OVERRIDE' SSHL_SOCKET_OVERRIDE='$SOCKET' PATH='$PATH' bash '$SSHL_SRC/$1'; echo popup-exit=\$?; exec sleep 60")
    printf '%s\n' "$pane"
}

wait_for_popup_exit() {
    wait_for_pane_content "$1" "^popup-exit=$2\$" 10
}

# Poll a command until it succeeds or timeout (seconds) expires.
wait_until() {
    local timeout="$1"; shift
    local _
    for _ in $(seq 1 $(( timeout * 20 ))); do
        "$@" && return 0
        sleep 0.05
    done
    echo "Timeout waiting for: $*" >&2
    return 1
}

# Shadow tmux with a shim that refuses the real homelab socket, and a bare
# tmux call unless $TMUX points at this test's server. Refusals land in
# $TMUX_GUARD_LOG so a test can assert there were none.
install_tmux_guard() {
    export TMUX_GUARD_LOG="$SSHL_DATA_DIR_OVERRIDE/tmux-guard.log" TEST_SOCKET="$SOCKET" REAL_TMUX
    : > "$TMUX_GUARD_LOG"
    cat > "$STUB_BIN/tmux" << 'EOF'
#!/usr/bin/env bash
args=" $* "
[[ "$args" == " -V " ]] && exec "$REAL_TMUX" -V
if [[ "$args" == *" -L homelab "* ]]; then
    echo "refused: tmux $*" >> "$TMUX_GUARD_LOG"
    exit 1
fi
if [[ "$args" != *" -L "* && "$args" != *" -S "* && "${TMUX%%,*}" != */"$TEST_SOCKET" ]]; then
    echo "refused: tmux $* with TMUX=${TMUX:-}" >> "$TMUX_GUARD_LOG"
    exit 1
fi
exec "$REAL_TMUX" "$@"
EOF
    chmod +x "$STUB_BIN/tmux"
    hash -r
}

# Write an executable stub that shadows a command for the current test only.
stub_cmd() {
    local name="$1" body="$2"
    printf '#!/usr/bin/env bash\n%s\n' "$body" > "$STUB_BIN/$name"
    chmod +x "$STUB_BIN/$name"
    # Without this, a command the test already ran stays hashed to its real path.
    hash -r
}

# Stub fzf with a body that stands in for the user's choice. The stub
# reports a version new enough for the popups unless one is given.
stub_fzf() {
    local body="$1" version="${2:-0.54.3}"
    stub_cmd fzf "if [[ \"\${1:-}\" == --version ]]; then echo '$version (stub)'; exit 0; fi
$body"
}

# Shadow tmux with a shim that fails split-window in the window tagged with
# the given IP, so add_window gives up on that host after its window exists.
fail_split_for_host() {
    # shellcheck disable=SC2016  # expanded by the stub, not here
    stub_cmd tmux 'if [[ " $* " == *" split-window "* ]]; then
    args=("$@")
    for i in "${!args[@]}"; do
        [[ "${args[i]}" == -t ]] || continue
        if [[ "$("$REAL_TMUX" -L "$SSHL_SOCKET_OVERRIDE" show-options -wqv -t "${args[i+1]}" @host_ip)" == "'"$1"'" ]]; then
            echo "simulated split-window failure" >&2
            exit 1
        fi
    done
fi
exec "$REAL_TMUX" "$@"'
    export REAL_TMUX
}

# Attach a real client to session_name through a grouped session, the way
# sshl's attach command does, and wait until tmux reports it attached.
# An optional file receives everything the client draws.
attach_grouped_client() {
    local typescript="${1:-/dev/null}"
    TERM=xterm-256color script -qfc "tmux -L '$SOCKET' new-session -t '=$session_name'" "$typescript" \
        >/dev/null 2>&1 3>&- &
    wait_for_grouped_client
}

wait_for_grouped_client() {
    local _
    for _ in $(seq 1 100); do
        tmux -L "$SOCKET" list-sessions -F '#{session_group} #{session_attached}' 2>/dev/null \
            | grep -qx "$session_name 1" && return 0
        sleep 0.1
    done
    echo "Timeout waiting for a grouped client on $session_name" >&2
    return 1
}

# Attach a client the way attach_grouped_client does, but inside a pane of
# a second tmux server that plays the terminal, so term_screen can read
# what the client shows, popups and status messages included.
attach_client_in_terminal() {
    tmux -L "$SOCKET-term" -f /dev/null new-session -d -s term -x 120 -y 40 \
        "env -u TMUX TERM=xterm-256color script -qfc \"tmux -L '$SOCKET' new-session -t '=$session_name'\" /dev/null"
    wait_for_grouped_client
}

term_screen() {
    tmux -L "$SOCKET-term" capture-pane -p -t term
}

term_shows() {
    term_screen | grep -q -- "$1"
}

# Type keys into the terminal, so the client receives them as a user's.
term_keys() {
    tmux -L "$SOCKET-term" send-keys -t term "$@"
}

# @host_ip of each window in session_name, in index order, space separated.
live_order() {
    tmux -L "$SOCKET" list-windows -t "=$session_name" -F '#{@host_ip}' | grep . | tr '\n' ' '
}
