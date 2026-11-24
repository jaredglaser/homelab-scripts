#!/usr/bin/env bats

load test_helper

@test "trim: strips leading whitespace" {
    result=$(trim "   hello")
    [ "$result" = "hello" ]
}

@test "trim: strips trailing whitespace" {
    result=$(trim "hello   ")
    [ "$result" = "hello" ]
}

@test "trim: empty string stays empty" {
    result=$(trim "")
    [ "$result" = "" ]
}

@test "substitute: replaces all tokens in one template" {
    result=$(substitute "ssh {user}@{ip} # {hostname}" "10.0.0.1" "admin" "box01")
    [ "$result" = "ssh admin@10.0.0.1 # box01" ]
}

@test "read_cache: parses ip and name from tab-separated file" {
    printf '192.0.2.1\tfake-host-01\n192.0.2.2\tfake-host-02\n' > "$SSHL_DIR_OVERRIDE/ips.cache"
    read_cache
    [ "${ips[0]}" = "192.0.2.1" ]
    [ "${ips[1]}" = "192.0.2.2" ]
    [ "${cached_name[192.0.2.1]}" = "fake-host-01" ]
    [ "${cached_name[192.0.2.2]}" = "fake-host-02" ]
}

@test "read_cache: skips blank lines" {
    printf '\n192.0.2.1\tfake-host-01\n\n' > "$SSHL_DIR_OVERRIDE/ips.cache"
    read_cache
    [ "${#ips[@]}" = "1" ]
    [ "${ips[0]}" = "192.0.2.1" ]
}

@test "read_cache: returns empty arrays when cache file is absent" {
    rm -f "$SSHL_DIR_OVERRIDE/ips.cache"
    read_cache
    [ "${#ips[@]}" = "0" ]
}

@test "write_cache: roundtrips ip and name through read_cache" {
    ips=("192.0.2.1" "192.0.2.2")
    cached_name[192.0.2.1]="fake-host-01"
    cached_name[192.0.2.2]="fake-host-02"
    write_cache
    ips=()
    unset cached_name; declare -A cached_name
    read_cache
    [ "${ips[0]}" = "192.0.2.1" ]
    [ "${ips[1]}" = "192.0.2.2" ]
    [ "${cached_name[192.0.2.1]}" = "fake-host-01" ]
}

@test "write_cache: produces empty file when ips array is empty" {
    ips=()
    write_cache
    [ ! -s "$SSHL_DIR_OVERRIDE/ips.cache" ]
}

@test "read_ignored: parses ignored ips and names" {
    printf '192.0.2.9\told-host\n' > "$SSHL_DIR_OVERRIDE/ignored.cache"
    read_ignored
    [ "${ignored_ips[0]}" = "192.0.2.9" ]
    [ "${ignored_name[192.0.2.9]}" = "old-host" ]
}

@test "write_ignored: roundtrips through read_ignored" {
    ignored_ips=("192.0.2.9")
    ignored_name[192.0.2.9]="old-host"
    write_ignored
    ignored_ips=()
    unset ignored_name; declare -A ignored_name
    read_ignored
    [ "${ignored_ips[0]}" = "192.0.2.9" ]
    [ "${ignored_name[192.0.2.9]}" = "old-host" ]
}

@test "resolve_hostname: prefers config host_name over cache" {
    host_name[192.0.2.1]="config-name"
    cached_name[192.0.2.1]="cache-name"
    result=$(resolve_hostname "192.0.2.1")
    [ "$result" = "config-name" ]
}

@test "resolve_hostname: falls back to cached_name" {
    unset 'host_name[192.0.2.1]'
    cached_name[192.0.2.1]="cache-name"
    result=$(resolve_hostname "192.0.2.1")
    [ "$result" = "cache-name" ]
}

@test "resolve_hostname: falls back to bare IP when no names are set" {
    unset 'host_name[192.0.2.99]'
    unset 'cached_name[192.0.2.99]'
    unset 'discovered_name[192.0.2.99]'
    result=$(resolve_hostname "192.0.2.99")
    [ "$result" = "192.0.2.99" ]
}

@test "config: unknown key emits a warning to stderr" {
    echo "boguskey=somevalue" >> "$SSHL_DIR_OVERRIDE/config"
    unset _SSHL_LIB
    stderr=$(source "$SSHL_SRC/sshl-lib.sh" 2>&1 >/dev/null)
    [[ "$stderr" == *"unknown config key"* ]]
}

@test "read_cache: succeeds when the last line has no name" {
    printf '192.0.2.51\thost-b\n192.0.2.50\t\n' > "$SSHL_DIR_OVERRIDE/ips.cache"
    read_cache
    [ "${#ips[@]}" = "2" ]
    [ "${ips[1]}" = "192.0.2.50" ]
    [ -z "${cached_name[192.0.2.50]:-}" ]
}

@test "read_ignored: succeeds when the last line has no name" {
    printf '192.0.2.9\told-host\n192.0.2.10\t\n' > "$SSHL_DIR_OVERRIDE/ignored.cache"
    read_ignored
    [ "${#ignored_ips[@]}" = "2" ]
    [ "${ignored_ips[1]}" = "192.0.2.10" ]
}

# The writers stage into "<file>.tmp.$$". Pointing that path at /dev/full
# makes every write fail with ENOSPC, which chmod cannot do for root.
@test "write_cache: a failed write returns non-zero and keeps the old cache" {
    printf '192.0.2.1\tfake-host-01\n192.0.2.2\tfake-host-02\n' > "$SSHL_DIR_OVERRIDE/ips.cache"
    before=$(cat "$SSHL_DIR_OVERRIDE/ips.cache")
    read_cache
    ln -s /dev/full "$SSHL_DIR_OVERRIDE/ips.cache.tmp.$$"
    if write_cache; then rc=0; else rc=1; fi
    [ "$rc" -eq 1 ]
    [ ! -L "$SSHL_DIR_OVERRIDE/ips.cache" ]
    [ "$(cat "$SSHL_DIR_OVERRIDE/ips.cache")" = "$before" ]
    [ ! -L "$SSHL_DIR_OVERRIDE/ips.cache.tmp.$$" ]
}

@test "write_ignored: a failed write returns non-zero and keeps the old file" {
    printf '192.0.2.9\told-host\n' > "$SSHL_DIR_OVERRIDE/ignored.cache"
    read_ignored
    ln -s /dev/full "$SSHL_DIR_OVERRIDE/ignored.cache.tmp.$$"
    if write_ignored; then rc=0; else rc=1; fi
    [ "$rc" -eq 1 ]
    [ ! -L "$SSHL_DIR_OVERRIDE/ignored.cache" ]
    [ "$(cat "$SSHL_DIR_OVERRIDE/ignored.cache")" = $'192.0.2.9\told-host' ]
    [ ! -L "$SSHL_DIR_OVERRIDE/ignored.cache.tmp.$$" ]
}

@test "scan_subnet: keeps hosts that neither ssh nor reverse DNS can name" {
    stub_cmd ssh 'exit 255'
    stub_cmd getent 'exit 2'
    scan_subnet
    # shellcheck disable=SC2154  # set by scan_subnet in sshl-lib.sh
    [ "${#discovered_ips[@]}" = "2" ]
    [ "${discovered_ips[0]}" = "192.0.2.1" ]
    [ "${discovered_ips[1]}" = "192.0.2.2" ]
    [ -z "${discovered_name[192.0.2.1]:-}" ]
    [ "$(resolve_hostname 192.0.2.1)" = "192.0.2.1" ]

    ips=("${discovered_ips[@]}")
    write_cache
    read_cache
    [ "${#ips[@]}" = "2" ]
}
