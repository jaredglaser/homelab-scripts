#!/usr/bin/env bash
# Report remote-host uptime + pending package updates for the tmux status bar.
# Invoked via:  host-info.sh [-f] <user> <ip>
# Output: one short line, e.g. "up 3d14h · updates 7 · 12m"
#
# The script answers at once from a cache and refreshes it in a background
# SSH call, which also runs apt-get update on the host. Entries are keyed on
# user and ip and live in ${XDG_RUNTIME_DIR:-~/.cache}/sshl-host-info with a
# 24h TTL (5m when the last fetch failed). The background job holds a flock
# for its whole life, so the status bar, the launcher's warm-up and a forced
# refresh never run two fetches for the same entry. While it runs the bar
# shows a spinner that advances one frame per status poll. -f bypasses the
# TTL and sets status-interval to 1 until the fetch it started ends.
set -euo pipefail

force=false
if [[ "${1:-}" == "-f" ]]; then
    force=true
    shift
fi

user="${1:-}"
ip="${2:-}"

if [[ -z "$ip" || -z "$user" ]]; then
    echo ""
    exit 0
fi

# Both end up in a file name and in ssh's destination argument, where a
# leading hyphen would be read as an option.
if [[ ! "$user" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ || ! "$ip" =~ ^[A-Za-z0-9][A-Za-z0-9.:_-]*$ ]]; then
    echo "host-info: invalid user or host"
    exit 0
fi

if ! command -v flock >/dev/null 2>&1; then
    echo "host-info: install flock (util-linux)"
    exit 0
fi

# #() and run-shell jobs carry $TMUX for the server that runs them, and a
# bare tmux command follows it. Outside tmux, fall back to the sshl socket.
if [[ -n "${SSHL_SOCKET_OVERRIDE:-}" ]]; then
    tmux_cmd=(tmux -L "$SSHL_SOCKET_OVERRIDE")
elif [[ -n "${TMUX:-}" ]]; then
    tmux_cmd=(tmux)
else
    tmux_cmd=(tmux -L homelab)
fi

format_age() {
    local s=$1
    if   (( s < 60 ));    then printf '< 1m'
    elif (( s < 3600 ));  then printf '%dm' "$((s/60))"
    elif (( s < 86400 )); then printf '%dh' "$((s/3600))"
    else                       printf '%dd' "$((s/86400))"
    fi
}

# Uptime uses a longer form ("3d14h", "2h15m", "47m") since it's the
# primary content of the segment, not a freshness hint.
format_uptime() {
    local s=$1
    local d=$((s/86400))
    local h=$(((s%86400)/3600))
    local m=$(((s%3600)/60))
    if   (( d > 0 )); then printf '%dd%dh' "$d" "$h"
    elif (( h > 0 )); then printf '%dh%dm' "$h" "$m"
    else                   printf '%dm' "$m"
    fi
}

# Remote output and the cache are untrusted: tmux expands #[...] and #{...}
# in #() output. Only digits (at most 12, so arithmetic cannot overflow) or
# "?" pass. 10# keeps a leading zero from being read as octal.
valid_field() {
    [[ "$1" == "?" || "$1" =~ ^[0-9]{1,12}$ ]]
}

normalize_field() {
    if [[ "$1" == "?" ]]; then printf '?'; else printf '%d' "$((10#$1))"; fi
}

cache_dir="${XDG_RUNTIME_DIR:-${HOME:?HOME not set}/.cache}/sshl-host-info"
(umask 077 && mkdir -p "$cache_dir")
if [[ ! -O "$cache_dir" || -L "$cache_dir" ]]; then
    echo "host-info: $cache_dir is not owned by you"
    exit 0
fi
cache="$cache_dir/$user@$ip"
lockfile="$cache.lock"
marker="$cache.fetching"
# 24 hours. Once a day is plenty for update-count drift. The refresh
# button (-f) bypasses this whenever you want a right-now check.
ttl=86400
# A failed fetch retries after 5m instead of pinning the host as unknown
# for the full 24h, without hammering a host that's genuinely down.
unknown_ttl=300
# ConnectTimeout covers only connecting. Without a cap, a host that freezes
# after login holds the fetch, its lock and the spinner forever.
fetch_timeout="${SSHL_FETCH_TIMEOUT_OVERRIDE:-}"
[[ "$fetch_timeout" =~ ^[1-9][0-9]{0,5}$ ]] || fetch_timeout=120

spinner_frame() {
    local f=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    printf '%s' "${f[$(( $(date +%s) % 10 ))]}"
}

remote=$(cat <<'REMOTE'
# Raw uptime in seconds. Caller formats and projects it locally so the
# display can tick between fetches without a round-trip.
up_sec=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
[ -z "$up_sec" ] && up_sec="?"

# Privilege-aware apt-update helper. Root runs it directly. Non-root
# tries passwordless sudo (-n) and falls through silently if it can't.
sync_apt() {
    if [ "$(id -u)" = "0" ]; then
        apt-get update -qq >/dev/null 2>&1 || true
    elif command -v sudo >/dev/null 2>&1; then
        sudo -n apt-get update -qq >/dev/null 2>&1 || true
    fi
}

if command -v apt >/dev/null 2>&1; then
    sync_apt
    n=$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l)
elif command -v checkupdates >/dev/null 2>&1; then
    # checkupdates uses its own private sync dir, syncs on its own.
    n=$(checkupdates 2>/dev/null | wc -l)
elif command -v pacman >/dev/null 2>&1; then
    n=$(pacman -Qu 2>/dev/null | wc -l)
elif command -v dnf >/dev/null 2>&1; then
    # dnf check-update refreshes metadata on its own when stale.
    n=$(dnf -q check-update 2>/dev/null | awk 'NF && !/^(Last|Loaded|Obsoleting)/' | wc -l)
else
    n="?"
fi

# Tagged so the caller can find the data among banners and rc-file output.
printf 'SSHL\t%s\t%s\n' "$up_sec" "$n"
REMOTE
)

# Prints "<uptime>\t<updates>" from the last tagged line of the SSH output,
# or "?\t?" when there is none or either field fails validation.
parse_remote() {
    local line tag up n rest entry=$'?\t?'
    # Bounded first: read is quadratic on a long line (2 MB took 17 s).
    while IFS= read -r line; do
        line="${line%$'\r'}"
        IFS=$'\t' read -r tag up n rest <<<"$line" || true
        [[ "$tag" == "SSHL" && -z "$rest" ]] || continue
        if valid_field "$up" && valid_field "$n"; then
            entry="$(normalize_field "$up")"$'\t'"$(normalize_field "$n")"
        else
            entry=$'?\t?'
        fi
    done < <(tail -n 20 | cut -b -512)
    printf '%s\n' "$entry"
}

fetch() {
    local out tmp
    # 9>&- keeps an ssh ControlPersist master from holding the lock.
    # Keepalives end a silent connection early, timeout one whose command hangs.
    out=$(timeout -k 5 "$fetch_timeout" ssh -o BatchMode=yes \
              -o ConnectTimeout=2 \
              -o ServerAliveInterval=5 \
              -o ServerAliveCountMax=3 \
              -o StrictHostKeyChecking=accept-new \
              -o LogLevel=ERROR \
              "$user@$ip" "$remote" 2>/dev/null 9>&-) || out=""
    tmp=$(mktemp "$cache_dir/.tmp.XXXXXX")
    if ! { parse_remote <<<"$out" > "$tmp" && mv "$tmp" "$cache"; }; then
        rm -f "$tmp"
    fi
}

# The whole subshell inherits fd 9, so the lock lives exactly as long as
# the fetch. Its output goes to /dev/null so it does not hold tmux's #()
# pipe open: tmux does not rerun a job whose pipe is still open.
start_fetch() {
    : > "$marker"
    (
        trap 'rm -f "$marker"; if $force; then "${tmux_cmd[@]}" set -g status-interval 5 9>&- 2>/dev/null || true; fi' EXIT
        fetch
    ) </dev/null >/dev/null 2>&1 &
}

read_entry() {
    entry_up="?"
    entry_updates="?"
    entry_ok=false
    [[ -f "$cache" ]] || return 0
    local up n
    IFS=$'\t' read -r up n < "$cache" 2>/dev/null || true
    if valid_field "${up:-}" && valid_field "${n:-}"; then
        entry_up="$(normalize_field "$up")"
        entry_updates="$(normalize_field "$n")"
        entry_ok=true
    fi
}

now=$(date +%s)
read_entry
mtime=0
[[ -f "$cache" ]] && mtime=$(stat -c %Y "$cache" 2>/dev/null || echo 0)

need_fetch=true
if ! $force && $entry_ok; then
    effective_ttl=$ttl
    [[ "$entry_up" == "?" ]] && effective_ttl=$unknown_ttl
    (( now - mtime < effective_ttl )) && need_fetch=false
fi

# Without this, a full or read-only cache directory starts an ssh on every
# status poll, since no attempt is ever recorded.
cache_writable() {
    local probe
    probe=$(mktemp "$cache_dir/.tmp.XXXXXX" 2>/dev/null) || return 1
    if ! printf 'x\n' 2>/dev/null > "$probe"; then
        rm -f "$probe"
        return 1
    fi
    rm -f "$probe"
}

if $need_fetch && ! cache_writable; then
    echo "host-info: cannot write to $cache_dir"
    exit 0
fi

exec 9>>"$lockfile"
fetching=false
if $need_fetch; then
    if flock -n 9; then
        if $force; then
            # 1 Hz polls so the spinner advances once a second while the
            # forced fetch runs. The fetch's EXIT trap restores 5, so this
            # must come first or a fast fetch leaves the bar at 1 Hz.
            "${tmux_cmd[@]}" set -g status-interval 1 9>&- 2>/dev/null || true
        fi
        start_fetch
    fi
    fetching=true
elif [[ -e "$marker" ]]; then
    # A marker with a free lock was left by a fetch that was killed.
    if flock -n 9; then rm -f "$marker"; else fetching=true; fi
fi
exec 9>&-

if [[ ! -f "$cache" ]]; then
    printf '#[fg=colour208]%s#[fg=colour252] loading…\n' "$(spinner_frame)"
    exit 0
fi

# Uptime and age both derive from cache mtime so they tick every poll.
age=$(( now - mtime ))
(( age < 0 )) && age=0

if [[ "$entry_up" == "?" ]]; then
    up_display="?"
else
    up_display=$(format_uptime $((entry_up + age)))
fi

updates="$entry_updates"
if $fetching; then
    updates="#[fg=colour208]$(spinner_frame)#[fg=colour252]"
fi

printf 'up %s · updates %s · %s\n' "$up_display" "$updates" "$(format_age "$age")"
