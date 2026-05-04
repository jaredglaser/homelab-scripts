#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/sshl-lib.sh"

# fzf multi-select over ignored.cache. Tick = un-ignore (returns the
# IP to scan-candidate status). No window added immediately.
popup_ignored() {
    require fzf
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

    local header=$'space toggle • tab toggle+down • enter un-ignore • esc cancel\nticked entries return as scan candidates'

    # See popup_scan for the rationale: fzf --multi falls back to the
    # focused line on Enter when nothing is marked. The flag file is
    # touched by every selection-changing keybind, and Enter aborts to a
    # no-op when the flag is absent.
    local flag
    flag=$(mktemp)
    rm -f "$flag"
    trap 'rm -f "$flag"' RETURN

    local result
    result=$(printf '%s\n' "$fzf_input" \
        | SSHL_FLAG="$flag" fzf --multi --reverse --no-sort --height=100% \
              --header="$header" --header-first \
              --bind='space:execute-silent(touch "$SSHL_FLAG")+toggle+down' \
              --bind='tab:execute-silent(touch "$SSHL_FLAG")+toggle+down' \
              --bind='btab:execute-silent(touch "$SSHL_FLAG")+toggle+up' \
              --bind='enter:transform([ -e "$SSHL_FLAG" ] && echo accept || echo abort)' \
              --prompt='ignored> ') || {
        echo "No changes." >&2
        return 0
    }

    [[ -z "$result" ]] && { echo "Nothing selected." >&2; return 0; }

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
        sleep 2.5
        return 1
    fi
    echo "Un-ignored ${#unignore[@]} host(s)." >&2
    sleep 1.2
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && popup_ignored
