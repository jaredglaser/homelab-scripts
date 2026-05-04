# Shared library for sshl and the popup scripts. Source this. Do not execute directly.
[[ -n "${_SSHL_LIB:-}" ]] && return 0
_SSHL_LIB=1

SSHL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# SSHL_BIN must be set by the calling script before sourcing this lib.
# Popup scripts don't set it (they never call set_session_options), so
# default to empty to satisfy set -u without breaking their use case.
SSHL_BIN="${SSHL_BIN:-}"

CONFIG_FILE="${SSHL_DIR}/config"
TMUX_CONF="${SSHL_DIR}/homelab.tmux.conf"
PICKER="${SSHL_DIR}/host-picker.sh"
INFO_SCRIPT="${SSHL_DIR}/host-info.sh"
CACHE_FILE="${SSHL_DIR}/ips.cache"
IGNORED_FILE="${SSHL_DIR}/ignored.cache"
SOCKET="homelab"
TMUX_CMD=(tmux -L "$SOCKET")

trim() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    printf '%s' "$v"
}

require() {
    if ! command -v "$1" &>/dev/null; then
        echo "Error: '$1' is required but not installed" >&2
        exit 1
    fi
}

if [[ ! -f "$CONFIG_FILE" ]]; then
    if [[ -f "${SSHL_DIR}/config.example" ]]; then
        cp "${SSHL_DIR}/config.example" "$CONFIG_FILE" || {
            echo "Error: failed to copy config.example to $CONFIG_FILE (check permissions and disk space)" >&2
            exit 1
        }
        echo "Created config from config.example. Review $CONFIG_FILE before re-running." >&2
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

declare -A host_user
declare -A host_name
declare -A host_left_cmd
declare -A host_right_cmd
declare -A cached_name

while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(trim "$line")"
    [[ -z "$line" ]] && continue
    [[ "$line" != *=* ]] && continue
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
    echo "Error: 'subnet' not set in $CONFIG_FILE" >&2
    exit 1
fi

require tmux

# ips.cache mirrors the live tmux session. Each line is `<ip>\t<name>`
# in display order (NOT IP-sorted). The popup flows mutate the cache
# and the live session in lockstep.
#
# ignored.cache is the same format. IPs here never reappear as scan
# candidates until un-ignored via the ignored popup.

declare -a ips=()
declare -a ignored_ips=()
declare -A ignored_name

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
        [[ -n "$c_name" ]] && cached_name["$c_ip"]="$c_name"
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
        [[ -n "$c_name" ]] && ignored_name["$c_ip"]="$c_name"
    done < "$IGNORED_FILE"
}

# Atomic writes via temp + rename so a partial write can't corrupt
# the cache file mid-update. Both return non-zero on rename failure
# so callers can distinguish "wrote it" from "didn't" before they
# touch live tmux state.
write_cache() {
    local tmp="${CACHE_FILE}.tmp.$$"
    : > "$tmp"
    local ip
    for ip in "${ips[@]}"; do
        printf '%s\t%s\n' "$ip" "${cached_name[$ip]:-}" >> "$tmp"
    done
    if ! mv "$tmp" "$CACHE_FILE"; then
        rm -f "$tmp"
        return 1
    fi
    update_cache_mtime_option
    return 0
}

write_ignored() {
    local tmp="${IGNORED_FILE}.tmp.$$"
    : > "$tmp"
    local ip
    for ip in "${ignored_ips[@]}"; do
        printf '%s\t%s\n' "$ip" "${ignored_name[$ip]:-}" >> "$tmp"
    done
    if ! mv "$tmp" "$IGNORED_FILE"; then
        rm -f "$tmp"
        return 1
    fi
    return 0
}

update_cache_mtime_option() {
    local mtime
    mtime=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || stat -f %m "$CACHE_FILE" 2>/dev/null) || return 0
    "${TMUX_CMD[@]}" set-option -g @cache_mtime "$mtime" 2>/dev/null || true
}

declare -a discovered_ips=()
declare -A discovered_name

resolve_remote_hostname() {
    local ip="$1"
    local user="${host_user[$ip]:-$default_user}"
    local name
    # Errors (including auth failures from a wrong user) are silenced
    # because this runs in a background subshell during scan_subnet.
    # A misconfigured user shows up as a bare-IP display name.
    name=$(ssh -o BatchMode=yes \
               -o ConnectTimeout=3 \
               -o StrictHostKeyChecking=accept-new \
               -o LogLevel=ERROR \
               "$user@$ip" hostname -s 2>/dev/null) || return 1
    name="${name//[[:space:]]/}"
    [[ -n "$name" ]] && printf '%s' "$name"
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

    # -oG to file keeps host records out of stdout, leaving only the
    # human-readable stats lines (including --stats-every progress).
    nmap -Pn -n -p 22 --open --min-parallelism 32 --max-rtt-timeout 50ms --max-retries 1 "$subnet" -oG "$nmap_tmp" \
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
        }

    local scanned
    mapfile -t scanned < <(awk '/22\/open/{print $2}' "$nmap_tmp" | sort -V)
    rm -f "$nmap_tmp"

    if [[ ${#scanned[@]} -eq 0 ]]; then
        echo "No live hosts found in $subnet" >&2
        return 0
    fi

    echo "Resolving hostnames for ${#scanned[@]} host(s)..." >&2
    local tmp ip name
    tmp="$(mktemp)"
    for ip in "${scanned[@]}"; do
        (
            name="${host_name[$ip]:-}"
            if [[ -z "$name" ]]; then
                name="$(resolve_remote_hostname "$ip" || true)"
            fi
            if [[ -z "$name" ]]; then
                name="$(getent hosts "$ip" 2>/dev/null | awk '{print $2}' | head -n1)"
                name="${name%%.*}"
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
    tmpl="${tmpl//\{ip\}/$ip}"
    tmpl="${tmpl//\{user\}/$user}"
    tmpl="${tmpl//\{hostname\}/$hostname}"
    printf '%s' "$tmpl"
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

set_session_options() {
    "${TMUX_CMD[@]}" set-option -g @subnet         "$subnet"
    "${TMUX_CMD[@]}" set-option -g @cache_file     "$CACHE_FILE"
    "${TMUX_CMD[@]}" set-option -g @ignored_file   "$IGNORED_FILE"
    "${TMUX_CMD[@]}" set-option -g @sshl_bin       "$SSHL_BIN"
    "${TMUX_CMD[@]}" set-option -g @picker_script  "$PICKER"
    "${TMUX_CMD[@]}" set-option -g @info_script    "$INFO_SCRIPT"
    "${TMUX_CMD[@]}" set-option -g @default_layout "$layout"
    update_cache_mtime_option
    set_session_env
}

# Mirror the @var options into the global tmux environment. The popup
# key bindings need these as shell variables ($SSHL_DIR etc.) because
# display-popup -E does NOT format-expand its shell-command despite
# what the docs imply, so #{@sshl_bin} would reach the spawned shell as a
# literal string. Newly-spawned panes (popups included) inherit this
# global env, so by the time prefix S fires the popup's shell already
# has $SSHL_DIR set.
set_session_env() {
    "${TMUX_CMD[@]}" set-environment -g SSHL_BIN     "$SSHL_BIN"     2>/dev/null || true
    "${TMUX_CMD[@]}" set-environment -g SSHL_DIR     "$SSHL_DIR"     2>/dev/null || true
    "${TMUX_CMD[@]}" set-environment -g SSHL_CACHE   "$CACHE_FILE"   2>/dev/null || true
    "${TMUX_CMD[@]}" set-environment -g SSHL_IGNORED "$IGNORED_FILE" 2>/dev/null || true
    "${TMUX_CMD[@]}" set-environment -g SSHL_PICKER  "$PICKER"       2>/dev/null || true
    "${TMUX_CMD[@]}" set-environment -g SSHL_INFO    "$INFO_SCRIPT"  2>/dev/null || true
}

# Add a window for a host. With --first, opens the session via
# new-session (caller must guarantee no session exists yet). Without
# --first, appends a window to the existing session.
add_window() {
    local first=false
    if [[ "${1:-}" == "--first" ]]; then first=true; shift; fi
    local ip="$1"

    local user name left right right_title
    user="${host_user[$ip]:-$default_user}"
    name="$(resolve_hostname "$ip")"
    left="$(substitute "${host_left_cmd[$ip]:-$left_cmd}" "$ip" "$user" "$name")"
    right="$(substitute "${host_right_cmd[$ip]:-$right_cmd}" "$ip" "$user" "$name")"
    right_title="${host_right_cmd[$ip]:-$right_cmd}"
    right_title="${right_title%% *}"

    local env_args=(-e "HOST_IP=$ip" -e "HOST_NAME=$name" -e "HOST_USER=$user")
    local wid
    if $first; then
        "${TMUX_CMD[@]}" -f "$TMUX_CONF" new-session -d -s "$session_name" \
            -n "$name" "${env_args[@]}" "$left" || {
            echo "Error: failed to create initial session for $ip ($name)" >&2
            return 1
        }
        wid=$("${TMUX_CMD[@]}" display-message -p -t "=$session_name:$name" '#{window_id}' 2>/dev/null) || {
            echo "Error: created session for $ip but could not resolve its window-id" >&2
            return 1
        }
    else
        wid=$("${TMUX_CMD[@]}" new-window -t "=$session_name" -n "$name" \
            -P -F '#{window_id}' "${env_args[@]}" "$left") || {
            echo "Warning: failed to create window for $ip ($name), skipping" >&2
            return 1
        }
    fi

    # Set @host_ip BEFORE any other configuration. If a later step
    # fails, the window still shows up in find_window_id_by_ip and
    # kill_host_window can clean up the orphan.
    "${TMUX_CMD[@]}" set-option -w -t "$wid" @host_ip "$ip"

    # Structural: the right pane is core to the per-host UI. If it
    # fails, kill the partial window rather than leave half a layout.
    if ! "${TMUX_CMD[@]}" split-window -h -t "$wid" "${env_args[@]}" "$right" 2>/dev/null \
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

build_session() {
    # Nuke the whole server, not just the base session. `kill-session
    # -t =homelab` leaves grouped sessions (open konsoles) running with
    # stale windows. kill-server detaches every konsole and ensures
    # the next attach sees the fresh session.
    "${TMUX_CMD[@]}" kill-server 2>/dev/null || true

    # kill-server returns before the socket finishes tearing down. The
    # next tmux command can race into the dying server and abort with
    # "server exited unexpectedly". Wait for list-sessions to confirm
    # the server is gone (cap at ~1s so a wedged server still surfaces).
    local i
    for i in {1..50}; do
        "${TMUX_CMD[@]}" list-sessions >/dev/null 2>&1 || break
        sleep 0.02
    done

    if [[ ${#ips[@]} -eq 0 ]]; then
        echo "Error: cache is empty; nothing to build." >&2
        return 1
    fi

    add_window --first "${ips[0]}"
    set_session_options

    local ip
    for ip in "${ips[@]:1}"; do
        add_window "$ip"
    done

    "${TMUX_CMD[@]}" select-window -t "$session_name:^"
    # Set last so an aborted build leaves the marker unset. The next
    # session_is_healthy check then forces a clean rebuild.
    "${TMUX_CMD[@]}" set-option -g @build_complete 1
}

# Update @cache_mtime after popup-driven cache writes so the status
# bar reflects the new write time.
refresh_session_options() {
    session_exists || return 0
    update_cache_mtime_option
}
