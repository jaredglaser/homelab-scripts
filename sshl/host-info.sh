#!/usr/bin/env bash
# Report remote-host uptime + pending package updates for the tmux status bar.
# Invoked via:  host-info.sh [-f] <user> <ip>
# Output: one short line, e.g. "up 3d14h · updates 7 · 12m"
#
# Fetches run async: the script returns immediately with either cached
# data (possibly stale) or a loading placeholder, while SSH fires in a
# backgrounded subshell. A marker file prevents duplicate concurrent
# fetches and also drives the in-flight spinner animation. Cached
# results live in ${TMPDIR:-/tmp}/tmux-homelab-info/<ip> with a 24h TTL.
# -f bypasses the TTL and triggers an immediate refetch.
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

cache_dir="${TMPDIR:-/tmp}/tmux-homelab-info"
mkdir -p "$cache_dir"
cache="$cache_dir/$ip"
marker="$cache.refreshing"
# 24 hours. Once a day is plenty for update-count drift. The refresh
# button (-f) bypasses this whenever you want a right-now check.
ttl=86400

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

printf '%s\t%s\n' "$up_sec" "$n"
REMOTE
)

# Fetch remote data in the background. The marker both serializes
# concurrent fetch attempts (one per IP) AND signals the spinner path.
async_fetch() {
    if [[ -f "$marker" ]]; then
        local marker_age=$(( $(date +%s) - $(stat -c %Y "$marker" 2>/dev/null || echo 0) ))
        (( marker_age <= 30 )) && return
        rm -f "$marker"
    fi
    ( set -C; > "$marker" ) 2>/dev/null || return
    trap 'rm -f "$marker"; tmux -L homelab set -g status-interval 5 2>/dev/null || true' EXIT
    (
        local o
        o=$(ssh -o BatchMode=yes \
                -o ConnectTimeout=2 \
                -o StrictHostKeyChecking=accept-new \
                -o LogLevel=ERROR \
                "$user@$ip" "$remote" 2>"${cache}.err") || o=$'?\t?'
        local tmp="${cache}.tmp.$$"
        printf '%s\n' "$o" > "$tmp" && mv "$tmp" "$cache" || rm -f "$tmp"
    ) &
    disown 2>/dev/null || true
}

if $force; then
    rm -f "$cache"
    # Bump status-interval so the spinner animates at 1Hz instead of
    # ticking once every 5s like the normal cadence.
    tmux -L homelab set -g status-interval 1 2>/dev/null || true
fi

need_fetch=true
if [[ -f "$cache" ]]; then
    mtime=$(stat -c %Y "$cache" 2>/dev/null || echo 0)
    # Use a shorter effective TTL when uptime is unknown (up_sec == "?").
    # Without this, a transient SSH blip pins the host as unknown for the
    # full 24h. 5m recovers quickly from a network glitch but avoids
    # hammering a host that's genuinely down.
    cached_up=""
    IFS=$'\t' read -r cached_up _ < "$cache" 2>/dev/null || true
    if [[ "$cached_up" == "?" ]]; then
        effective_ttl=300
    else
        effective_ttl=$ttl
    fi
    if (( $(date +%s) - mtime < effective_ttl )); then
        need_fetch=false
    fi
fi

# Every real fetch refreshes the remote's package metadata. Otherwise
# `apt list --upgradable` reports stale/empty counts on a fresh host,
# and the user sees "0 updates" until they manually click refresh. The
# TTL above (24 h) bounds how often we pay this cost.

if $need_fetch; then
    async_fetch
fi

# If we've never fetched this host, the cache file doesn't exist yet.
# Show a loading indicator rather than blocking tmux or outputting
# empty. The background fetch will populate the cache shortly.
if [[ ! -f "$cache" ]]; then
    printf '#[fg=colour208]%s#[fg=colour252] loading…\n' "$(spinner_frame)"
    exit 0
fi

# Uptime and age both derive from cache mtime so they tick every poll.
IFS=$'\t' read -r up_at_fetch updates < "$cache" || { up_at_fetch='?'; updates='?'; }
mtime=$(stat -c %Y "$cache" 2>/dev/null || date +%s)
age=$(( $(date +%s) - mtime ))

# Guard against a non-numeric up_at_fetch value (corrupt or manually-written cache).
if [[ "$up_at_fetch" != "?" && ! "$up_at_fetch" =~ ^[0-9]+$ ]]; then
    rm -f "$cache"
    up_at_fetch="?"
    updates="?"
fi

if [[ "$up_at_fetch" == "?" ]]; then
    up_display="?"
else
    up_display=$(format_uptime $((up_at_fetch + age)))
fi

# Any fetch in flight (refresh click OR natural async fetch) replaces
# the updates count with an animated spinner frame. The frame index is
# driven by wall-clock seconds so consecutive polls pick up new frames.
if [[ -f "$marker" ]] && ! $force; then
    updates="#[fg=colour208]$(spinner_frame)#[fg=colour252]"
fi

printf 'up %s · updates %s · %s\n' "$up_display" "$updates" "$(format_age "$age")"
