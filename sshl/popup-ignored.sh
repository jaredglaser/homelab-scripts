#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=sshl/sshl-lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/sshl-lib.sh"

# fzf multi-select over ignored.cache. Tick = un-ignore (returns the
# IP to scan-candidate status). No window added immediately.
popup_ignored() {
    require_fzf
    read_ignored

    if [[ ${#ignored_ips[@]} -eq 0 ]]; then
        echo "No ignored hosts." >&2
        sleep 1.5
        return 0
    fi

    local fzf_input="" ip name
    for ip in "${ignored_ips[@]}"; do
        name="${ignored_name[$ip]:--}"
        printf -v fzf_input '%s%-15s  %s\n' "$fzf_input" "$ip" "$name"
    done
    fzf_input="${fzf_input%$'\n'}"

    local header=$'space or tab tick and move down • enter un-ignore • esc cancel\nticked entries return as scan candidates'

    local result rc=0
    result=$(printf '%s\n' "$fzf_input" | multi_select 'ignored> ' "$header") || rc=$?
    if (( rc == 1 )); then
        echo "No changes." >&2
        return 0
    fi
    (( rc == 0 )) || return 1

    local -A unignore=()
    local sip line
    while IFS= read -r line; do
        sip=$(awk '{print $1}' <<<"$line")
        [[ -n "$sip" ]] && unignore["$sip"]=1
    done <<<"$result"

    local -a new_ignored_ips=()
    for ip in "${ignored_ips[@]}"; do
        if [[ -n "${unignore[$ip]:-}" ]]; then
            unset 'ignored_name[$ip]'
        else
            new_ignored_ips+=("$ip")
        fi
    done
    ignored_ips=("${new_ignored_ips[@]}")
    if ! write_ignored; then
        echo "Error: failed to write $IGNORED_FILE. No changes saved." >&2
        return 1
    fi
    echo "Un-ignored ${#unignore[@]} host(s)." >&2
    sleep 1.2
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then popup_ignored; fi
