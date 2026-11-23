# shellcheck shell=bash
# Shared library for sshl and the popup scripts. Source this. Do not execute directly.
[[ -n "${_SSHL_LIB:-}" ]] && return 0
_SSHL_LIB=1

# Scripts and the tmux conf live next to this file. The config and the
# caches live in SSHL_DATA_DIR, which only the tests move.
SSHL_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SSHL_DATA_DIR="${SSHL_DATA_DIR_OVERRIDE:-$SSHL_DIR}"

CONFIG_FILE="${SSHL_DATA_DIR}/config"
TMUX_CONF="${SSHL_DIR}/homelab.tmux.conf"
PICKER="${SSHL_DIR}/host-picker.sh"
INFO_SCRIPT="${SSHL_DIR}/host-info.sh"
CACHE_FILE="${SSHL_DATA_DIR}/ips.cache"
IGNORED_FILE="${SSHL_DATA_DIR}/ignored.cache"
SOCKET="${SSHL_SOCKET_OVERRIDE:-homelab}"
TMUX_CMD=(tmux -L "$SOCKET")

# The popup bindings set SSHL_POPUP. display-popup -EE keeps a popup open
# when its command fails, and nothing else in it says how to close it.
popup_exit_hint() {
    if (( $1 != 0 )) && [[ -n "${SSHL_POPUP:-}" ]]; then
        echo "Press Esc to close this popup." >&2
    fi
}
if [[ -n "${SSHL_POPUP:-}" ]]; then trap 'popup_exit_hint $?' EXIT; fi

trim() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    printf '%s' "$v"
}

# Names from SSH, reverse DNS and the cache are untrusted: they become
# tmux window names (where #[...] is expanded) and fill {hostname} in the
# pane command templates. A leading hyphen would read as an option there.
valid_hostname() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

require() {
    if ! command -v "$1" &>/dev/null; then
        echo "Error: '$1' is required but not installed" >&2
        exit 1
    fi
}

# The popups read FZF_SELECT_COUNT, which fzf exports from 0.46.0 on.
SSHL_FZF_MIN=0.46.0

fzf_version() {
    local v
    v="$(fzf --version 2>/dev/null)" || return 0
    v="${v%% *}"
    if [[ "$v" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then printf '%s' "$v"; fi
}

# True when version $2 is $1 or later.
version_at_least() {
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$1" ]]
}

fzf_new_enough() {
    [[ -n "$1" ]] && version_at_least "$SSHL_FZF_MIN" "$1"
}

# homelab.tmux.conf uses display-popup and pane-border-lines, both new in
# 3.2. On an older tmux the session opens with the config's errors over
# the first pane and none of the popup keys do anything.
SSHL_TMUX_MIN=3.2

# A build from git reports "master" or "openbsd-7.6", which says nothing
# about features, so a version without a number up front is let through.
tmux_new_enough() {
    local v="${1#next-}"
    v="${v%%[!0-9.]*}"
    [[ -z "$v" ]] || version_at_least "$SSHL_TMUX_MIN" "$v"
}

require_tmux() {
    require tmux
    local v
    v="$(tmux -V 2>/dev/null || true)"
    v="${v#tmux }"
    if ! tmux_new_enough "$v"; then
        echo "Error: tmux $SSHL_TMUX_MIN or newer is required, found $v." >&2
        echo "Install a newer tmux from your distribution's backports or https://github.com/tmux/tmux/releases" >&2
        exit 1
    fi
}

require_fzf() {
    require fzf
    local v
    v="$(fzf_version)"
    if ! fzf_new_enough "$v"; then
        echo "Error: fzf $SSHL_FZF_MIN or newer is required, found ${v:-a version sshl could not read}." >&2
        echo "Install a newer fzf from https://github.com/junegunn/fzf/releases" >&2
        exit 1
    fi
}

# Multi-select over stdin with the given prompt and header. Prints the
# ticked rows. Returns 0 on accept, 1 when the user cancels or presses
# Enter with nothing ticked, and 2 when fzf itself fails.
multi_select() {
    local prompt="$1" header="$2" rc=0
    # fzf --multi accepts the highlighted row when nothing is ticked, so
    # Enter and double-click accept only while something is. fzf runs the
    # transform in $SHELL, and a login shell such as fish may not parse it.
    # fzf's default marker is a thin bar, easy to miss next to a row.
    # shellcheck disable=SC2016  # FZF_SELECT_COUNT is expanded by fzf's shell
    SHELL="$BASH" fzf --multi --reverse --no-sort --height=100% \
        --marker='+' \
        --header="$header" --header-first \
        --bind='space:toggle+down' \
        --bind='enter:transform:[ "$FZF_SELECT_COUNT" -gt 0 ] && echo accept || echo abort' \
        --bind='double-click:transform:[ "$FZF_SELECT_COUNT" -gt 0 ] && echo accept || echo abort' \
        --prompt="$prompt" || rc=$?
    case "$rc" in
        0) return 0 ;;
        1|130) return 1 ;;
        *) echo "Error: fzf failed with exit status $rc." >&2; return 2 ;;
    esac
}

if [[ ! -f "$CONFIG_FILE" ]]; then
    if [[ -f "${SSHL_DIR}/config.example" ]]; then
        cp "${SSHL_DIR}/config.example" "$CONFIG_FILE" || {
            echo "Error: failed to copy config.example to $CONFIG_FILE (check permissions and disk space)" >&2
            exit 1
        }
        echo "Created $CONFIG_FILE from config.example. Set subnet= in it to the network your hosts are on, then run sshl again." >&2
    else
        echo "Error: config file not found at $CONFIG_FILE" >&2
    fi
    exit 1
fi

subnet=""
session_name="homelab"
default_user="root"
left_cmd='ssh {user}@{ip}'
right_cmd='ssh -t {user}@{ip} htop'
terminal="konsole"
layout="even-horizontal"

declare -gA host_user
declare -gA host_name
declare -gA host_left_cmd
declare -gA host_right_cmd
declare -gA cached_name

lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    line="$(trim "$line")"
    [[ -z "$line" || "$line" == \#* ]] && continue
    # A # inside a word belongs to the value (ssh -o options, URLs).
    line="${line%%[[:space:]]#*}"
    if [[ "$line" != *=* ]]; then
        echo "Warning: line $lineno of $CONFIG_FILE is not key=value, ignoring it: $line" >&2
        continue
    fi
    key="$(trim "${line%%=*}")"
    value="$(trim "${line#*=}")"
    case "$key" in
        subnet)        subnet="$value" ;;
        session_name)  session_name="$value" ;;
        default_user)  default_user="$value" ;;
        left_cmd)      left_cmd="$value" ;;
        right_cmd)     right_cmd="$value" ;;
        terminal)      terminal="$value" ;;
        layout)        layout="$value" ;;
        host.*.user)       ip="${key#host.}"; host_user["${ip%.user}"]="$value" ;;
        host.*.name)       ip="${key#host.}"; host_name["${ip%.name}"]="$value" ;;
        host.*.left_cmd)   ip="${key#host.}"; host_left_cmd["${ip%.left_cmd}"]="$value" ;;
        host.*.right_cmd)  ip="${key#host.}"; host_right_cmd["${ip%.right_cmd}"]="$value" ;;
        *) echo "Warning: unknown config key '$key'" >&2 ;;
    esac
done < "$CONFIG_FILE"

if [[ -z "$subnet" ]]; then
    echo "Error: 'subnet' is not set in $CONFIG_FILE. Set it to the network your hosts are on, in CIDR form such as subnet=192.168.1.0/24." >&2
    exit 1
fi

case "$layout" in
    even-horizontal|even-vertical|main-horizontal|main-vertical|tiled) ;;
    *)
        echo "Error: layout '$layout' in $CONFIG_FILE is not a tmux layout. Use one of: even-horizontal, even-vertical, main-horizontal, main-vertical, tiled." >&2
        exit 1 ;;
esac

# tmux reads . and : in a target as the window and pane separators.
if [[ -z "$session_name" || "$session_name" == *[.:]* ]]; then
    echo "Error: session_name '$session_name' in $CONFIG_FILE is not usable. Use a non-empty name without '.' or ':'." >&2
    exit 1
fi

read -ra terminal_cmd <<<"$terminal"
if (( ${#terminal_cmd[@]} == 0 )); then
    echo "Error: 'terminal' in $CONFIG_FILE is empty. Set it to a terminal emulator that accepts -e command args, such as konsole." >&2
    exit 1
fi

# The option that comes before the attach command. gnome-terminal and
# xfce4-terminal read -e as a single string, so `-e tmux -L ...` fails on
# -L. A value that already ends in such an option is used as written.
# shellcheck disable=SC2034  # the launcher reads terminal_exec
case "${terminal_cmd[${#terminal_cmd[@]}-1]}" in
    -e|-x|--) terminal_exec=() ;;
    *)
        case "${terminal_cmd[0]##*/}" in
            gnome-terminal) terminal_exec=(--) ;;
            xfce4-terminal) terminal_exec=(-x) ;;
            *)              terminal_exec=(-e) ;;
        esac ;;
esac

require_tmux

# ips.cache mirrors the live tmux session. Each line is `<ip>\t<name>`
# in display order (NOT IP-sorted). The popup flows mutate the cache
# and the live session in lockstep.
#
# ignored.cache is the same format. IPs here never reappear as scan
# candidates until un-ignored via the ignored popup.

declare -ga ips=()
declare -ga ignored_ips=()
declare -gA ignored_name

read_cache() {
    ips=()
    cached_name=()
    # Explicit `return 0`: bare `return` propagates the [[ -f ]] exit
    # status, which would trip set -e in callers when the file is absent.
    [[ -f "$CACHE_FILE" ]] || return 0
    local c_ip c_name
    while IFS=$'\t' read -r c_ip c_name || [[ -n "$c_ip" ]]; do
        c_ip="$(trim "${c_ip%%#*}")"
        c_name="$(trim "$c_name")"
        [[ -z "$c_ip" ]] && continue
        ips+=("$c_ip")
        if valid_hostname "$c_name"; then cached_name["$c_ip"]="$c_name"; fi
    done < "$CACHE_FILE"
}

read_ignored() {
    ignored_ips=()
    ignored_name=()
    [[ -f "$IGNORED_FILE" ]] || return 0
    local c_ip c_name
    while IFS=$'\t' read -r c_ip c_name || [[ -n "$c_ip" ]]; do
        c_ip="$(trim "${c_ip%%#*}")"
        c_name="$(trim "$c_name")"
        [[ -z "$c_ip" ]] && continue
        ignored_ips+=("$c_ip")
        # shellcheck disable=SC2034  # write_ignored reads it through a nameref
        if valid_hostname "$c_name"; then ignored_name["$c_ip"]="$c_name"; fi
    done < "$IGNORED_FILE"
}

# Atomic writes via temp + rename, and the rename only happens after
# the whole body was written, so a failed write (ENOSPC included) keeps
# the old file. Both return non-zero on any failure so callers can tell
# "wrote it" from "didn't" before they touch live tmux state.
_write_host_file() {
    local dest="$1"
    local -n _whf_ips=$2 _whf_names=$3
    local tmp="${dest}.tmp.$$" body="" ip
    for ip in "${_whf_ips[@]}"; do
        body+="$ip"$'\t'"${_whf_names[$ip]:-}"$'\n'
    done
    if ! printf '%s' "$body" > "$tmp" || ! mv "$tmp" "$dest"; then
        rm -f "$tmp"
        return 1
    fi
}

write_cache() {
    _write_host_file "$CACHE_FILE" ips cached_name
}

write_ignored() {
    _write_host_file "$IGNORED_FILE" ignored_ips ignored_name
}

declare -ga discovered_ips=()
declare -gA discovered_name

resolve_remote_hostname() {
    local ip="$1"
    local user="${host_user[$ip]:-$default_user}"
    local name
    # Errors (including auth failures from a wrong user) are silenced
    # because this runs in a background subshell during scan_subnet.
    # A host that neither this nor reverse DNS can name is still listed,
    # and its window is named by its IP.
    name=$(ssh -o BatchMode=yes \
               -o ConnectTimeout=3 \
               -o StrictHostKeyChecking=accept-new \
               -o LogLevel=ERROR \
               "$user@$ip" hostname -s 2>/dev/null) || return 1
    name="${name//[[:space:]]/}"
    valid_hostname "$name" || return 1
    printf '%s' "$name"
}

# Run nmap, populate discovered_ips/discovered_name. No file writes,
# no cache mutation. Callers decide what to do with the results.
scan_subnet() {
    require nmap
    discovered_ips=()
    discovered_name=()

    echo "Scanning $subnet for live hosts..." >&2
    local nmap_tmp
    nmap_tmp="$(mktemp)"

    # -oG to a file keeps the grepable records off stdout. The loop prints
    # the "Nmap scan report for" lines of the normal output as progress.
    if ! nmap -Pn -n -p 22 --open --min-parallelism 32 --max-rtt-timeout 50ms --max-retries 1 "$subnet" -oG "$nmap_tmp" \
        | {
            local current_prefix="" line ip prefix
            while IFS= read -r line; do
                [[ "$line" != "Nmap scan report for "* ]] && continue
                ip="${line#Nmap scan report for }"
                prefix="${ip%.*}"
                if [[ "$prefix" != "$current_prefix" ]]; then
                    echo "  $prefix.0/24:" >&2
                    current_prefix="$prefix"
                fi
                echo "    $ip" >&2
            done
        }; then
        rm -f "$nmap_tmp"
        echo "Error: nmap failed to scan $subnet. Check the subnet in $CONFIG_FILE and nmap's message above." >&2
        return 1
    fi

    local -a scanned=()
    local -A skip=()
    local ip
    for ip in "${ignored_ips[@]}"; do skip["$ip"]=1; done
    while IFS= read -r ip; do
        [[ -n "${skip[$ip]:-}" ]] || scanned+=("$ip")
    done < <(awk '/22\/open/{print $2}' "$nmap_tmp" | sort -V)
    rm -f "$nmap_tmp"

    if [[ ${#scanned[@]} -eq 0 ]]; then
        echo "No live hosts found in $subnet" >&2
        return 0
    fi

    echo "Resolving hostnames for ${#scanned[@]} host(s)..." >&2
    local tmp name
    tmp="$(mktemp)"
    for ip in "${scanned[@]}"; do
        (
            name="${host_name[$ip]:-}"
            if [[ -z "$name" ]]; then
                name="$(resolve_remote_hostname "$ip" || true)"
            fi
            if [[ -z "$name" ]]; then
                name="$(getent hosts "$ip" 2>/dev/null | awk '{print $2}' | head -n1 || true)"
                name="${name%%.*}"
                valid_hostname "$name" || name=""
            fi
            printf '%s\t%s\n' "$ip" "$name"
        ) >>"$tmp" &
    done
    wait
    while IFS=$'\t' read -r ip name; do
        discovered_ips+=("$ip")
        [[ -n "$name" ]] && discovered_name["$ip"]="$name"
    done < <(sort -V "$tmp")
    rm -f "$tmp"
}

resolve_hostname() {
    local ip="$1"
    if [[ -n "${host_name[$ip]:-}" ]]; then
        printf '%s' "${host_name[$ip]}"
    elif [[ -n "${cached_name[$ip]:-}" ]]; then
        printf '%s' "${cached_name[$ip]}"
    elif [[ -n "${discovered_name[$ip]:-}" ]]; then
        printf '%s' "${discovered_name[$ip]}"
    else
        printf '%s' "$ip"
    fi
}

substitute() {
    local tmpl="$1" ip="$2" user="$3" hostname="$4"
    tmpl="${tmpl//\{ip\}/"$ip"}"
    tmpl="${tmpl//\{user\}/"$user"}"
    tmpl="${tmpl//\{hostname\}/"$hostname"}"
    printf '%s' "$tmpl"
}

config_mtime() {
    stat -c %Y "$CONFIG_FILE" 2>/dev/null || true
}

# Users, names and pane commands from the config only reach a window when
# it is created, so an edit made after the build does not show until a
# rebuild.
config_changed_since_build() {
    local built
    built="$("${TMUX_CMD[@]}" show-option -gqv @config_mtime 2>/dev/null)" || return 1
    [[ -n "$built" && "$built" != "$(config_mtime)" ]]
}

session_exists() {
    "${TMUX_CMD[@]}" has-session -t "=$session_name" 2>/dev/null
}

# A session is "healthy" only if build_session ran to completion and set
# the marker. Without this, a build that fails partway (e.g. a tmux
# command errors under set -e) leaves a partial session that the next
# run would happily "reuse", masking the failure and missing every host
# past the failure point.
session_is_healthy() {
    session_exists || return 1
    [[ "$("${TMUX_CMD[@]}" show-option -gv @build_complete 2>/dev/null)" == "1" ]]
}

# Find the window-id (e.g. @5) for a host IP via the @host_ip option
# we set per-window. Empty string if not found. Targeting by id avoids
# the duplicate-window-name ambiguity that targeting by name has.
find_window_id_by_ip() {
    local target="$1"
    "${TMUX_CMD[@]}" list-windows -t "=$session_name" \
        -F '#{window_id} #{@host_ip}' 2>/dev/null \
        | awk -v ip="$target" '$2 == ip {print $1; exit}'
}

# The status bar and prefix r read @info_script as a format.
set_session_options() {
    "${TMUX_CMD[@]}" set-option -g @info_script "$INFO_SCRIPT"
    set_session_env
}

# The popup key bindings read these as shell variables because
# display-popup does not format-expand its shell-command, so #{@var}
# would reach the popup's shell as a literal string. Popups inherit
# tmux's global environment when they spawn.
set_session_env() {
    "${TMUX_CMD[@]}" set-environment -g SSHL_DIR    "$SSHL_DIR"   2>/dev/null || true
    "${TMUX_CMD[@]}" set-environment -g SSHL_PICKER "$PICKER"     2>/dev/null || true
}

# Add a window for a host. With --first, opens the session via
# new-session (caller must guarantee no session exists yet). With
# --before WID, inserts the window before window WID. Otherwise appends a
# window to the existing session. Returns 1, with any partial window
# already killed, when the host gets no usable window.
add_window() {
    local first=false
    local -a where=(-t "=$session_name:")
    if [[ "${1:-}" == "--first" ]]; then first=true; shift; fi
    if [[ "${1:-}" == "--before" ]]; then where=(-b -t "$2"); shift 2; fi
    local ip="$1"

    local user name left right right_title
    user="${host_user[$ip]:-$default_user}"
    name="$(resolve_hostname "$ip")"
    left="$(substitute "${host_left_cmd[$ip]:-$left_cmd}" "$ip" "$user" "$name")"
    right="$(substitute "${host_right_cmd[$ip]:-$right_cmd}" "$ip" "$user" "$name")"
    right_title="${host_right_cmd[$ip]:-$right_cmd}"
    right_title="${right_title%% *}"

    local wid
    if $first; then
        wid=$("${TMUX_CMD[@]}" -f "$TMUX_CONF" new-session -d -s "$session_name" \
            -n "$name" -P -F '#{window_id}' "$left") || {
            echo "Warning: failed to open the session with $ip ($name), skipping" >&2
            return 1
        }
    else
        wid=$("${TMUX_CMD[@]}" new-window "${where[@]}" -n "$name" \
            -P -F '#{window_id}' "$left") || {
            echo "Warning: failed to create window for $ip ($name), skipping" >&2
            return 1
        }
    fi

    # Set @host_ip BEFORE any other configuration. If a later step
    # fails, the window still shows up in find_window_id_by_ip and
    # kill_host_window can clean up the orphan.
    if ! "${TMUX_CMD[@]}" set-option -w -t "$wid" @host_ip "$ip"; then
        echo "Warning: failed to tag the window for $ip ($name), killing partial window" >&2
        "${TMUX_CMD[@]}" kill-window -t "$wid" 2>/dev/null || true
        return 1
    fi

    # Structural: the right pane is core to the per-host UI. If it
    # fails, kill the partial window rather than leave half a layout.
    if ! "${TMUX_CMD[@]}" split-window -h -t "$wid" "$right" 2>/dev/null \
       || ! "${TMUX_CMD[@]}" select-layout -t "$wid" "$layout" 2>/dev/null; then
        echo "Warning: pane layout failed for $ip ($name), killing partial window" >&2
        "${TMUX_CMD[@]}" kill-window -t "$wid" 2>/dev/null || true
        return 1
    fi

    # Cosmetic: pane titles and the remaining @vars don't affect
    # functionality. Best-effort so a flake doesn't abort the build.
    "${TMUX_CMD[@]}" select-pane -t "$wid.0" -T "ssh $user@$name" 2>/dev/null || true
    "${TMUX_CMD[@]}" select-pane -t "$wid.1" -T "$right_title"     2>/dev/null || true
    "${TMUX_CMD[@]}" select-pane -t "$wid.0"                       2>/dev/null || true
    "${TMUX_CMD[@]}" set-option -w -t "$wid" @host_user "$user"    2>/dev/null || true
    "${TMUX_CMD[@]}" set-option -w -t "$wid" @host_name "$name"    2>/dev/null || true
}

kill_host_window() {
    local ip="$1"
    local wid
    wid="$(find_window_id_by_ip "$ip")"
    if [[ -z "$wid" ]]; then
        # Either the window was already gone (fine) or it exists but
        # lost its @host_ip option (an orphan from a partial add). The
        # caller can't tell the difference, so flag it for the user.
        echo "  warn: no window found for $ip during remove. May be orphaned, run --rebuild if it persists." >&2
        return 0
    fi
    "${TMUX_CMD[@]}" kill-window -t "$wid" 2>/dev/null || true
}

# A host's window closes for good when both of its panes exit with status
# 0 (exit in the shell, q in htop), while its IP stays in the cache.
# Reopen such windows in cache order, so a plain sshl run brings them back
# without the --rebuild that would close every open terminal.
reopen_missing_windows() {
    local i j ip next
    local -a reopened=() not_reopened=()
    for (( i = 0; i < ${#ips[@]}; i++ )); do
        ip="${ips[i]}"
        [[ -z "$(find_window_id_by_ip "$ip")" ]] || continue
        next=""
        for (( j = i + 1; j < ${#ips[@]}; j++ )); do
            next="$(find_window_id_by_ip "${ips[j]}")"
            [[ -z "$next" ]] || break
        done
        if [[ -n "$next" ]]; then
            add_window --before "$next" "$ip" || { not_reopened+=("$ip"); continue; }
        else
            add_window "$ip" || { not_reopened+=("$ip"); continue; }
        fi
        reopened+=("$ip")
    done
    if (( ${#reopened[@]} > 0 )); then
        echo "Reopened the window for $(format_host_list "${reopened[@]}")." >&2
    fi
    if (( ${#not_reopened[@]} > 0 )); then
        echo "Could not reopen the window for $(format_host_list "${not_reopened[@]}"). Fix the cause above and run 'sshl --rebuild' to retry." >&2
    fi
    return 0
}

# kill-server, or killing a session's last window, returns before the
# socket finishes tearing down. The next tmux command can race into the
# dying server and abort with "server exited unexpectedly". Wait for
# list-sessions to confirm the server is gone (cap at ~1s so a wedged
# server still surfaces).
wait_for_server_exit() {
    local _
    for _ in {1..50}; do
        "${TMUX_CMD[@]}" list-sessions >/dev/null 2>&1 || return 0
        sleep 0.02
    done
}

format_host_list() {
    local out="" ip
    for ip in "$@"; do
        out+="${out:+, }$ip ($(resolve_hostname "$ip"))"
    done
    printf '%s' "$out"
}

build_session() {
    # Nuke the whole server, not just the base session. `kill-session
    # -t =homelab` leaves grouped sessions (open konsoles) running with
    # stale windows. kill-server detaches every konsole and ensures
    # the next attach sees the fresh session.
    "${TMUX_CMD[@]}" kill-server 2>/dev/null || true
    wait_for_server_exit

    if [[ ${#ips[@]} -eq 0 ]]; then
        echo "Error: the cache is empty, so there is nothing to build." >&2
        return 1
    fi

    # Skip a failing host instead of aborting. An aborted build is never
    # marked complete, so every later run would rebuild and fail at the
    # same host, and the scan popup that could remove it needs a session.
    local ip opened=false
    local -a skipped=()
    for ip in "${ips[@]}"; do
        if $opened; then
            add_window "$ip" || skipped+=("$ip")
        elif add_window --first "$ip"; then
            opened=true
            set_session_options
        else
            skipped+=("$ip")
            wait_for_server_exit
        fi
    done

    if ! $opened; then
        echo "Error: no host got a window, so there is no session to attach to. See the warnings above." >&2
        return 1
    fi

    "${TMUX_CMD[@]}" select-window -t "=$session_name:^"
    # Set last so an aborted build leaves the marker unset. The next
    # session_is_healthy check then forces a clean rebuild.
    "${TMUX_CMD[@]}" set-option -g @build_complete 1
    "${TMUX_CMD[@]}" set-option -g @config_mtime "$(config_mtime)"

    if (( ${#skipped[@]} > 0 )); then
        echo "Skipped ${#skipped[@]} host(s): $(format_host_list "${skipped[@]}"). Fix the cause above and run 'sshl --rebuild' to retry." >&2
    fi
}

# A rescan can name a CURRENT host better than when it was added (keys
# installed since, or a rename). A host.<ip>.name in the config wins.
refresh_cached_names() {
    local ip name wid
    local -a renamed=()
    local -A old_name=()
    for ip in "${ips[@]}"; do
        [[ -z "${host_name[$ip]:-}" ]] || continue
        name="${discovered_name[$ip]:-}"
        [[ -n "$name" && "$name" != "${cached_name[$ip]:-}" ]] || continue
        old_name["$ip"]="${cached_name[$ip]:-}"
        cached_name["$ip"]="$name"
        renamed+=("$ip")
    done
    (( ${#renamed[@]} > 0 )) || return 0
    if ! write_cache; then
        echo "Warning: failed to write $CACHE_FILE, so renamed hosts keep their old names." >&2
        for ip in "${renamed[@]}"; do cached_name["$ip"]="${old_name[$ip]}"; done
        return 0
    fi
    for ip in "${renamed[@]}"; do
        name="${cached_name[$ip]}"
        echo "Renamed $ip to $name." >&2
        wid="$(find_window_id_by_ip "$ip")"
        [[ -n "$wid" ]] || continue
        "${TMUX_CMD[@]}" rename-window -t "$wid" "$name" 2>/dev/null || true
        "${TMUX_CMD[@]}" set-option -w -t "$wid" @host_name "$name" 2>/dev/null || true
        "${TMUX_CMD[@]}" select-pane -t "$wid.0" -T "ssh ${host_user[$ip]:-$default_user}@$name" 2>/dev/null || true
    done
}
