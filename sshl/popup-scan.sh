#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=sshl/sshl-lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/sshl-lib.sh"

# Run nmap, present a multi-select fzf where each row carries an
# explicit action tag: CURRENT (already a window) or NEW (just found).
# Ticking acts on the row in the obvious way:
#   tick CURRENT → kill window + add to ignored
#   tick NEW     → add window + cache it
#   untouched    → no-op
#
# This avoids relying on fzf's preselect (which is unreliable across
# many entries and can silently leave the diff thinking "nothing was
# kept", killing every window and destroying the session).
#
# Returns non-zero on every failure, so the popup (display-popup -EE)
# stays open with the message until the user closes it.
popup_scan() {
    require_fzf
    require nmap
    read_cache
    read_ignored
    scan_subnet
    refresh_cached_names

    local -A in_cache=()
    local -A in_ignored=()
    local -A in_scan=()
    local ip
    for ip in "${ips[@]}";         do in_cache["$ip"]=1; done
    for ip in "${ignored_ips[@]}"; do in_ignored["$ip"]=1; done
    for ip in "${discovered_ips[@]}"; do in_scan["$ip"]=1; done

    # Combined list: cache order first, then discovered newcomers.
    local -a entries=()
    local -A entry_tag=()
    for ip in "${ips[@]}"; do
        entries+=("$ip"); entry_tag["$ip"]="CURRENT"
    done
    for ip in "${discovered_ips[@]}"; do
        [[ -n "${in_cache[$ip]:-}" ]]   && continue
        [[ -n "${in_ignored[$ip]:-}" ]] && continue
        entries+=("$ip"); entry_tag["$ip"]="NEW"
    done

    if [[ ${#entries[@]} -eq 0 ]]; then
        echo "Nothing to show: no cached hosts, no scan results, all results ignored." >&2
        return 0
    fi

    # Padded tag so columns align and awk still sees one token per
    # field (whitespace-separated).
    # A host that moved to a new address shows up twice, as a CURRENT row
    # at the old address and a NEW row at the new one, so say which of
    # the two the scan no longer sees.
    local fzf_input="" name display_name tag
    for ip in "${entries[@]}"; do
        name="${host_name[$ip]:-${cached_name[$ip]:-${discovered_name[$ip]:-}}}"
        display_name="${name:--}"
        tag="${entry_tag[$ip]}"
        if [[ "$tag" == CURRENT && -z "${in_scan[$ip]:-}" ]]; then
            display_name+="  (not found by this scan)"
        fi
        printf -v fzf_input '%s%-7s  %-15s  %s\n' "$fzf_input" "$tag" "$ip" "$display_name"
    done
    fzf_input="${fzf_input%$'\n'}"

    local header
    header=$'space or tab tick and move down • enter apply • esc cancel\n'
    header+='tick CURRENT to remove (and ignore)  •  tick NEW to add  •  leave alone for no change'

    local result rc=0
    result=$(printf '%s\n' "$fzf_input" | multi_select 'hosts> ' "$header") || rc=$?
    if (( rc == 1 )); then
        echo "No changes." >&2
        return 0
    fi
    (( rc == 0 )) || return 1

    local -a to_add=() to_remove=()
    local stag sip line
    while IFS= read -r line; do
        stag=$(awk '{print $1}' <<<"$line")
        sip=$(awk '{print $2}' <<<"$line")
        [[ -z "$sip" ]] && continue
        case "$stag" in
            CURRENT) to_remove+=("$sip") ;;
            NEW)     to_add+=("$sip") ;;
        esac
    done <<<"$result"

    apply_scan_diff to_add to_remove
}

apply_scan_diff() {
    local -n _to_add=$1
    local -n _to_remove=$2

    if (( ${#_to_add[@]} == 0 && ${#_to_remove[@]} == 0 )); then
        echo "No changes." >&2
        return 0
    fi

    # Safety net: don't let the apply leave zero hosts. The session
    # dies when its last window is killed, taking the konsole with
    # it. If the user really wants a clean slate, --rebuild does it
    # explicitly.
    local final_count=$(( ${#ips[@]} - ${#_to_remove[@]} + ${#_to_add[@]} ))
    if (( final_count <= 0 )); then
        echo "Refusing: that would remove every host, and the session closes with its last window." >&2
        echo "To start over with a scan, run 'tmux -L $SOCKET kill-server', delete $CACHE_FILE, and run sshl again." >&2
        return 1
    fi

    local ip c

    # Mutate in-memory state to the target shape (cache mirror, no
    # live tmux yet).
    for ip in "${_to_remove[@]}"; do
        local -a new_ips=()
        for c in "${ips[@]}"; do [[ "$c" != "$ip" ]] && new_ips+=("$c"); done
        ips=("${new_ips[@]}")
        ignored_ips+=("$ip")
        # shellcheck disable=SC2034  # write_ignored reads it through a nameref
        ignored_name["$ip"]="${cached_name[$ip]:-${discovered_name[$ip]:-}}"
        unset 'cached_name[$ip]'
    done
    for ip in "${_to_add[@]}"; do
        ips+=("$ip")
        cached_name["$ip"]="${discovered_name[$ip]:-}"
    done

    # Persist before touching live tmux. A failure here leaves the
    # session unchanged, so the user can retry without rebuilding.
    # The reverse ordering risks a divergence where live tmux is
    # ahead of the on-disk cache (no recovery path other than manual
    # --rebuild from a stale cache).
    if ! write_cache; then
        echo "Error: failed to write $CACHE_FILE. Live session unchanged." >&2
        return 1
    fi
    if ! write_ignored; then
        echo "Error: failed to write $IGNORED_FILE. Cache updated, live session unchanged." >&2
        echo "Run 'sshl --rebuild' to restore a consistent state." >&2
        return 1
    fi

    # Live tmux changes. Failures are recoverable via 'sshl --rebuild'
    # since the cache is now authoritative.
    local has_session=0
    local -a no_window=()
    session_exists && has_session=1
    if (( has_session )); then
        # Remove first so freed slots don't leave stale tabs visible
        # while the new ones spawn.
        for ip in "${_to_remove[@]}"; do
            kill_host_window "$ip"
        done
        for ip in "${_to_add[@]}"; do
            add_window "$ip" || no_window+=("$ip")
        done
    fi

    echo "Added ${#_to_add[@]}, removed ${#_to_remove[@]}." >&2
    if (( ${#no_window[@]} > 0 )); then
        echo "No window for ${#no_window[@]} host(s): $(format_host_list "${no_window[@]}")." >&2
        echo "They are saved in the cache. Fix the cause above and run 'sshl --rebuild' to retry." >&2
        return 1
    fi
    # Brief pause so the message is visible before the popup closes.
    if (( has_session )); then sleep 1.2; fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then popup_scan; fi
