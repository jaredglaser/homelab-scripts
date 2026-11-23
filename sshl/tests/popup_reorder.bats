#!/usr/bin/env bats

load test_helper

build_three_host_session() {
    printf '192.0.2.1\ta\n192.0.2.2\tb\n192.0.2.3\tc\n' > "$SSHL_DIR_OVERRIDE/ips.cache"
    read_cache
    build_session
    source "$SSHL_SRC/popup-reorder.sh"
}

@test "apply_reorder: reorders the cache and the live windows" {
    build_three_host_session
    run apply_reorder 192.0.2.3 192.0.2.1 192.0.2.2
    [ "$status" -eq 0 ]
    [ "$(cut -f1 "$SSHL_DIR_OVERRIDE/ips.cache" | tr '\n' ' ')" = "192.0.2.3 192.0.2.1 192.0.2.2 " ]
    [ "$(live_order)" = "192.0.2.3 192.0.2.1 192.0.2.2 " ]
}

@test "apply_reorder: reorders the live windows while a grouped client is attached" {
    build_three_host_session
    attach_grouped_client
    run apply_reorder 192.0.2.2 192.0.2.1 192.0.2.3
    [ "$status" -eq 0 ]
    [ "$(cut -f1 "$SSHL_DIR_OVERRIDE/ips.cache" | tr '\n' ' ')" = "192.0.2.2 192.0.2.1 192.0.2.3 " ]
    [ "$(live_order)" = "192.0.2.2 192.0.2.1 192.0.2.3 " ]
}

@test "apply_reorder: leaves the live windows alone when the cache write fails" {
    build_three_host_session
    ln -s /dev/full "$SSHL_DIR_OVERRIDE/ips.cache.tmp.$$"
    run apply_reorder 192.0.2.3 192.0.2.2 192.0.2.1
    [ "$status" -eq 1 ]
    [ "$(cut -f1 "$SSHL_DIR_OVERRIDE/ips.cache" | tr '\n' ' ')" = "192.0.2.1 192.0.2.2 192.0.2.3 " ]
    [ "$(live_order)" = "192.0.2.1 192.0.2.2 192.0.2.3 " ]
}
