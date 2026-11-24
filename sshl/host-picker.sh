#!/usr/bin/env bash
# Fuzzy-pick a host window of the sshl session and jump to it.
# Invoked from the `<prefix> H` binding in homelab.tmux.conf.
set -euo pipefail

# The popup shell carries $TMUX for the sshl server, and a bare tmux
# command follows it. Outside tmux, fall back to the sshl socket.
if [[ -n "${SSHL_SOCKET_OVERRIDE:-}" ]]; then
    tmux_cmd=(tmux -L "$SSHL_SOCKET_OVERRIDE")
elif [[ -n "${TMUX:-}" ]]; then
    tmux_cmd=(tmux)
else
    tmux_cmd=(tmux -L homelab)
fi

if ! command -v fzf &>/dev/null; then
    "${tmux_cmd[@]}" display-message \
        "fzf not installed. Install it to use the host picker."
    exit 0
fi

# List the windows rather than ips.cache, so each row carries the name on
# its tab, host.<ip>.name from the config included.
rc=0
pick=$("${tmux_cmd[@]}" list-windows -F '#{@host_ip} #{window_name}' 2>/dev/null | awk '
    NF == 2 { printf "%-18s %s\n", $1, $2 }
' | fzf --prompt='host> ' --height=100% --reverse --no-sort) || rc=$?
# 1 is no match and 130 is Esc. The popup (display-popup -EE) stays open
# on any other status, so the message below stays readable.
case "$rc" in
    0) ;;
    1|130) exit 0 ;;
    *) echo "Error: the host picker failed (exit status $rc). Press Esc to close this popup." >&2
       exit 1 ;;
esac

[[ -z "${pick:-}" ]] && exit 0

ip=$(awk '{print $1}'  <<<"$pick")
name=$(awk '{print $2}' <<<"$pick")
display="${name:-$ip}"

# Target the window by id resolved from @host_ip, not by name. Two
# hosts with the same short hostname collide under name targeting
# and tmux picks the first match.
wid=$("${tmux_cmd[@]}" list-windows -F '#{window_id} #{@host_ip}' 2>/dev/null \
      | awk -v ip="$ip" '$2 == ip {print $1; exit}')

if [[ -n "$wid" ]]; then
    "${tmux_cmd[@]}" select-window -t "$wid"
else
    "${tmux_cmd[@]}" display-message "Host '$display' not found. Use <prefix> S to rescan."
fi
