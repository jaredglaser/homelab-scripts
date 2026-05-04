#!/usr/bin/env bash
# Fuzzy-pick a host from the sshl cache and jump to its window.
# Invoked from the `<prefix> H` binding in homelab.tmux.conf.
set -euo pipefail

cache="${TMUX_HOMELAB_CACHE:?TMUX_HOMELAB_CACHE not set}"
socket="homelab"

if ! command -v fzf &>/dev/null; then
    tmux -L "$socket" display-message \
        "fzf not installed. Install it to use the host picker."
    exit 0
fi

pick=$(awk -F'\t' '
    NF && $1 !~ /^#/ {
        printf "%-18s %s\n", $1, ($2 == "" ? "-" : $2)
    }
' "$cache" | fzf --prompt='host> ' --height=100% --reverse --no-sort)

[[ -z "${pick:-}" ]] && exit 0

ip=$(awk '{print $1}'  <<<"$pick")
name=$(awk '{print $2}' <<<"$pick")
display="${name:-$ip}"
[[ "$display" == "-" ]] && display="$ip"

# Target the window by id resolved from @host_ip, not by name. Two
# hosts with the same short hostname collide under name targeting
# and tmux picks the first match.
wid=$(tmux -L "$socket" list-windows -F '#{window_id} #{@host_ip}' 2>/dev/null \
      | awk -v ip="$ip" '$2 == ip {print $1; exit}')

if [[ -n "$wid" ]]; then
    tmux -L "$socket" select-window -t "$wid"
else
    tmux -L "$socket" display-message "Host '$display' not found. Use <prefix> S to rescan."
fi
