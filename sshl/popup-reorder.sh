#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/sshl-lib.sh"

# Hand-rolled keyboard TUI. State machine: nav (cursor moves) and grab
# (cursor + held item move together). On apply, rewrite ips.cache in
# the new order and run tmux move-window for any positions that moved.
popup_reorder() {
    read_cache
    if [[ ${#ips[@]} -le 1 ]]; then
        echo "Need at least 2 hosts to reorder." >&2
        sleep 1.5
        return 0
    fi

    local -a items=("${ips[@]}")
    local cursor=0
    local grabbed=0

    # ANSI helpers. tput hides/shows cursor and uses smcup/rmcup to
    # save+restore the terminal state so the popup vanishes cleanly.
    tput smcup 2>/dev/null || true
    tput civis 2>/dev/null || true
    # Restore terminal on any exit, including ctrl-c.
    trap 'tput cnorm 2>/dev/null || true; tput rmcup 2>/dev/null || true' EXIT

    local result=cancelled
    while true; do
        _reorder_render "${items[@]}"
        local key
        IFS= read -rsn1 key
        if [[ "$key" == $'\e' ]]; then
            # Arrow keys send a 3-byte escape sequence: ESC, then '[' or
            # 'O', then a direction letter. Read the next two chars with
            # a forgiving timeout.
            local c1="" c2=""
            IFS= read -rsn1 -t 0.1  c1 || c1=""
            if [[ -z "$c1" ]]; then
                key="esc"
            else
                IFS= read -rsn1 -t 0.05 c2 || c2=""
                case "$c1$c2" in
                    "[A"|"OA") key="up" ;;
                    "[B"|"OB") key="down" ;;
                    *)         continue ;;  # unknown sequence, ignore
                esac
            fi
        fi
        case "$key" in
            up|k)
                if (( cursor > 0 )); then
                    if (( grabbed )); then
                        local tmp="${items[cursor]}"
                        items[cursor]="${items[cursor-1]}"
                        items[cursor-1]="$tmp"
                    fi
                    ((cursor--))
                fi
                ;;
            down|j)
                if (( cursor < ${#items[@]} - 1 )); then
                    if (( grabbed )); then
                        local tmp="${items[cursor]}"
                        items[cursor]="${items[cursor+1]}"
                        items[cursor+1]="$tmp"
                    fi
                    (( ++cursor ))
                fi
                ;;
            ' ')
                grabbed=$((1 - grabbed))
                ;;
            ''|$'\n'|$'\r')
                result=apply
                break
                ;;
            q|esc)
                if (( grabbed )); then
                    grabbed=0
                else
                    result=cancelled
                    break
                fi
                ;;
        esac
    done

    tput cnorm 2>/dev/null || true
    tput rmcup 2>/dev/null || true
    trap - EXIT

    if [[ "$result" != "apply" ]]; then
        echo "Reorder cancelled." >&2
        return 0
    fi

    # Persist first. If write_cache fails (ENOSPC, perms), surface it
    # and leave the live session untouched. Cache stays the source of
    # truth, --rebuild reconciles.
    ips=("${items[@]}")
    if ! write_cache; then
        echo "Error: failed to write $CACHE_FILE. Live session unchanged." >&2
        sleep 2.5
        return 1
    fi

    local moved=0 failed=0
    if session_exists; then
        # Pack any pre-existing gaps so swap-window can address every
        # target slot. Without this, swapping into a gap fails and
        # leaves the window in place.
        "${TMUX_CMD[@]}" move-window -r -t "=$session_name" 2>/dev/null || true

        local base_idx
        base_idx=$("${TMUX_CMD[@]}" show-option -gv base-index 2>/dev/null || echo 0)

        # Decompose the permutation into pair swaps. swap-window keeps
        # window-ids stable across slot changes, so per-iteration lookup
        # by @host_ip stays correct after earlier swaps. move-window -k
        # is unsafe (kills the destination window).
        local i ip target_wid current_idx target_slot err
        for ((i=0; i<${#items[@]}; i++)); do
            ip="${items[i]}"
            target_wid="$(find_window_id_by_ip "$ip")"
            if [[ -z "$target_wid" ]]; then
                echo "  warn: no window found for $ip, skipping" >&2
                failed=$((failed + 1))
                continue
            fi
            target_slot=$((base_idx + i))
            current_idx="$("${TMUX_CMD[@]}" display-message -p -t "$target_wid" '#{window_index}' 2>/dev/null || echo "")"
            [[ "$current_idx" == "$target_slot" ]] && continue
            err="$("${TMUX_CMD[@]}" swap-window -s "$target_wid" -t "${session_name}:$target_slot" 2>&1)" \
                && moved=$((moved + 1)) \
                || { failed=$((failed + 1)); echo "  warn: swap $ip -> slot $target_slot failed: $err" >&2; }
        done

        "${TMUX_CMD[@]}" move-window -r -t "=$session_name" 2>/dev/null || true
    fi

    refresh_session_options
    if (( failed > 0 )); then
        echo "Reordered $moved window(s), $failed failed. Run 'sshl --rebuild' if the session looks wrong." >&2
        sleep 2.5
    else
        echo "Reordered $moved window(s)." >&2
        sleep 1.2
    fi
}

# Reads `cursor` and `grabbed` from the caller's scope (popup_reorder
# declares both as local). Items pass through as positional arguments
# so the function doesn't also need to dynamically scope `items`.
_reorder_render() {
    local items=("$@")
    local cols
    cols=$(tput cols 2>/dev/null || echo 80)

    tput clear 2>/dev/null || printf '\033[2J\033[H'
    tput cup 0 0 2>/dev/null || true

    local header_l1="↑/↓ or j/k move cursor • space grab/drop • enter apply • q/esc cancel"
    local header_l2="grabbed: $([[ $grabbed -eq 1 ]] && echo 'YES, arrows now move the held item' || echo 'no')"
    printf '%s\n' "$header_l1"
    printf '%s\n' "$header_l2"
    printf '%s\n' "$(printf '─%.0s' $(seq 1 $((cols<60?cols:60))))"

    local i ip name marker prefix style reset
    style=$'\033[7m'   # reverse video (highlighted row)
    reset=$'\033[0m'
    local grab_style=$'\033[33;1m'  # bold yellow (held row)
    for ((i=0; i<${#items[@]}; i++)); do
        ip="${items[i]}"
        name="${cached_name[$ip]:-$ip}"
        if (( i == cursor )); then
            if (( grabbed )); then
                marker="${grab_style}>>${reset} "
                prefix="${grab_style}"
            else
                marker="${style}> ${reset}"
                prefix="${style}"
            fi
        else
            marker="  "
            prefix=""
        fi
        printf '%b%2d  %-15s  %s%b\n' "$prefix" "$((i+1))" "$ip" "$name" "$reset"
    done
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && popup_reorder
