#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=sshl/sshl-lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/sshl-lib.sh"

# Hand-rolled keyboard TUI. State machine: nav (cursor moves) and grab
# (cursor + held item move together). On apply, rewrite ips.cache in
# the new order and swap the live windows to match.
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
    local top=0

    tput smcup 2>/dev/null || true
    tput civis 2>/dev/null || true
    # Restore terminal on any exit, including ctrl-c.
    trap 'rc=$?; _reorder_restore_term; popup_exit_hint "$rc"' EXIT

    local result=cancelled
    while true; do
        _reorder_render "${items[@]}"
        local key
        IFS= read -rsn1 key
        if [[ "$key" == $'\e' ]]; then
            # Arrow, Home and End keys send ESC, then '[' or 'O', then a
            # letter. Home, End, PgUp and PgDn can also send ESC [ digit ~.
            # Read the rest with a forgiving timeout.
            local c1="" c2="" c3=""
            IFS= read -rsn1 -t 0.1  c1 || c1=""
            if [[ -z "$c1" ]]; then
                key="esc"
            else
                IFS= read -rsn1 -t 0.05 c2 || c2=""
                if [[ "$c2" == [0-9] ]]; then
                    IFS= read -rsn1 -t 0.05 c3 || c3=""
                fi
                case "$c1$c2$c3" in
                    "[A"|"OA") key="up" ;;
                    "[B"|"OB") key="down" ;;
                    "[H"|"OH"|"[1~"|"[7~") key="home" ;;
                    "[F"|"OF"|"[4~"|"[8~") key="end" ;;
                    "[5~") key="pgup" ;;
                    "[6~") key="pgdn" ;;
                    *)         continue ;;  # unknown sequence, ignore
                esac
            fi
        fi
        # Rows per page, as _reorder_render lays them out.
        local page
        page=$(( $(tput lines 2>/dev/null || echo 24) - 4 ))
        (( page < 1 )) && page=1
        case "$key" in
            up|k)   _reorder_move_to $(( cursor - 1 )) ;;
            down|j) _reorder_move_to $(( cursor + 1 )) ;;
            home|g) _reorder_move_to 0 ;;
            end|G)  _reorder_move_to $(( ${#items[@]} - 1 )) ;;
            pgup)   _reorder_move_to $(( cursor - page )) ;;
            pgdn)   _reorder_move_to $(( cursor + page )) ;;
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

    _reorder_restore_term
    trap - EXIT
    if [[ -n "${SSHL_POPUP:-}" ]]; then trap 'popup_exit_hint $?' EXIT; fi

    if [[ "$result" != "apply" ]]; then
        echo "Reorder cancelled." >&2
        return 0
    fi

    apply_reorder "${items[@]}" || return 1
    sleep 1.2
}

# Moves the cursor of popup_reorder to a row, clamped to the list, and
# carries the grabbed host along. Works on the caller's items, cursor and
# grabbed.
_reorder_move_to() {
    local target="$1" last=$(( ${#items[@]} - 1 )) tmp
    (( target < 0 )) && target=0
    (( target > last )) && target=$last
    while (( cursor != target )); do
        local next=$(( cursor < target ? cursor + 1 : cursor - 1 ))
        if (( grabbed )); then
            tmp="${items[cursor]}"
            items[cursor]="${items[next]}"
            items[next]="$tmp"
        fi
        cursor=$next
    done
}

_reorder_restore_term() {
    tput cnorm 2>/dev/null || true
    tput rmcup 2>/dev/null || true
}

# Rewrites ips.cache in the given order, then swaps the live windows to
# match. Returns 1 when the cache write fails, 2 when any swap fails.
apply_reorder() {
    # Persist first. If write_cache fails (ENOSPC, perms), surface it
    # and leave the live session untouched. Cache stays the source of
    # truth, --rebuild reconciles.
    ips=("$@")
    if ! write_cache; then
        echo "Error: failed to write $CACHE_FILE. Live session unchanged." >&2
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
        for ((i=0; i<${#ips[@]}; i++)); do
            ip="${ips[i]}"
            target_wid="$(find_window_id_by_ip "$ip")"
            if [[ -z "$target_wid" ]]; then
                echo "  warn: no window found for $ip, skipping" >&2
                failed=$((failed + 1))
                continue
            fi
            target_slot=$((base_idx + i))
            current_idx="$("${TMUX_CMD[@]}" display-message -p -t "$target_wid" '#{window_index}' 2>/dev/null || echo "")"
            [[ "$current_idx" == "$target_slot" ]] && continue
            # A bare window id resolves through the grouped session a client
            # attaches with, and tmux refuses to swap between grouped sessions.
            if err="$("${TMUX_CMD[@]}" swap-window -d -s "=$session_name:$target_wid" \
                      -t "=$session_name:$target_slot" 2>&1)"; then
                moved=$((moved + 1))
            else
                failed=$((failed + 1))
                echo "  warn: swap $ip -> slot $target_slot failed: $err" >&2
            fi
        done

        "${TMUX_CMD[@]}" move-window -r -t "=$session_name" 2>/dev/null || true
    fi

    if (( failed > 0 )); then
        echo "Reordered $moved window(s), $failed failed. Run 'sshl --rebuild' if the session looks wrong." >&2
        return 2
    fi
    echo "Reordered $moved window(s)." >&2
}

# Uses popup_reorder's locals cursor, grabbed and top, and moves top so the
# list scrolls with the cursor.
_reorder_render() {
    local items=("$@")
    local cols lines
    cols=$(tput cols 2>/dev/null || echo 80)
    lines=$(tput lines 2>/dev/null || echo 24)

    tput clear 2>/dev/null || printf '\033[2J\033[H'
    tput cup 0 0 2>/dev/null || true

    local header_l1="↑/↓ or j/k move cursor • space grab/drop • enter apply • q/esc cancel"
    local header_l2="grabbed: no • Home/End PgUp/PgDn jump"
    (( grabbed )) && header_l2="grabbed: YES, arrows now move the held item"
    printf '%s\n' "$header_l1"
    printf '%s\n' "$header_l2"
    printf '%s\n' "$(printf '─%.0s' $(seq 1 $((cols<60?cols:60))))"

    # Three header lines and one footer line frame the rows.
    local rows=$(( lines - 4 ))
    (( rows < 1 )) && rows=1
    (( cursor < top )) && top=$cursor
    (( cursor >= top + rows )) && top=$(( cursor - rows + 1 ))
    local end=$(( top + rows ))
    (( end > ${#items[@]} )) && end=${#items[@]}

    local i ip name marker prefix style reset
    style=$'\033[7m'   # reverse video (highlighted row)
    reset=$'\033[0m'
    local grab_style=$'\033[33;1m'  # bold yellow (held row)
    for ((i=top; i<end; i++)); do
        ip="${items[i]}"
        name="${cached_name[$ip]:-$ip}"
        if (( i == cursor )); then
            if (( grabbed )); then
                marker=">>"
                prefix="${grab_style}"
            else
                marker="> "
                prefix="${style}"
            fi
        else
            marker="  "
            prefix=""
        fi
        printf '%b%s%2d  %-15s  %s%b\n' "$prefix" "$marker" "$((i+1))" "$ip" "$name" "$reset"
    done
    # No newline after the footer, so the screen never scrolls the header away.
    if (( top > 0 || end < ${#items[@]} )); then
        printf 'rows %d-%d of %d' "$((top + 1))" "$end" "${#items[@]}"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then popup_reorder; fi
