#!/usr/bin/env bats

load test_helper

# Each pane touches ran.<ip> after its name is used, so a test can wait for
# every pane command to have run.
build_with_marker_panes() {
    # shellcheck disable=SC2034  # read by build_session in sshl-lib.sh
    left_cmd="echo {hostname}; touch $SSHL_DATA_DIR_OVERRIDE/ran.{ip}; sleep 30"
    build_session
}

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
    printf '192.0.2.1\tfake-host-01\n192.0.2.2\tfake-host-02\n' > "$SSHL_DATA_DIR_OVERRIDE/ips.cache"
    read_cache
    [ "${ips[0]}" = "192.0.2.1" ]
    [ "${ips[1]}" = "192.0.2.2" ]
    [ "${cached_name[192.0.2.1]}" = "fake-host-01" ]
    [ "${cached_name[192.0.2.2]}" = "fake-host-02" ]
}

@test "read_cache: skips blank lines" {
    printf '\n192.0.2.1\tfake-host-01\n\n' > "$SSHL_DATA_DIR_OVERRIDE/ips.cache"
    read_cache
    [ "${#ips[@]}" = "1" ]
    [ "${ips[0]}" = "192.0.2.1" ]
}

@test "read_cache: returns empty arrays when cache file is absent" {
    rm -f "$SSHL_DATA_DIR_OVERRIDE/ips.cache"
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
    [ ! -s "$SSHL_DATA_DIR_OVERRIDE/ips.cache" ]
}

@test "read_ignored: parses ignored ips and names" {
    printf '192.0.2.9\told-host\n' > "$SSHL_DATA_DIR_OVERRIDE/ignored.cache"
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
    echo "boguskey=somevalue" >> "$SSHL_DATA_DIR_OVERRIDE/config"
    unset _SSHL_LIB
    stderr=$(source "$SSHL_SRC/sshl-lib.sh" 2>&1 >/dev/null)
    [[ "$stderr" == *"unknown key 'boguskey'"* ]]
}

# Loads the library in a child bash against the test config, then runs
# the given commands there.
load_config() {
    run bash -c "source '$SSHL_SRC/sshl-lib.sh' && $1"
}

@test "config: a # inside a value is kept, a # after whitespace starts a comment" {
    cat >> "$SSHL_DATA_DIR_OVERRIDE/config" << 'EOF'
left_cmd=ssh -o ProxyCommand=a#b {user}@{ip}   # trailing comment
  # an indented comment line
EOF
    load_config 'printf "%s|" "$left_cmd"'
    [ "$status" -eq 0 ]
    [ "$output" = "ssh -o ProxyCommand=a#b {user}@{ip}|" ]
}

@test "config: a line without = is reported with its number" {
    echo "layout even-vertical" >> "$SSHL_DATA_DIR_OVERRIDE/config"
    load_config 'echo "layout=$layout"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Warning: line 7 of $SSHL_DATA_DIR_OVERRIDE/config is not key=value, ignoring it: layout even-vertical"* ]]
    [[ "$output" == *"layout=even-horizontal"* ]]
}

@test "config: an invalid layout is rejected at load time" {
    echo "layout=even-horizonal" >> "$SSHL_DATA_DIR_OVERRIDE/config"
    load_config 'echo loaded'
    [ "$status" -eq 1 ]
    [[ "$output" == *"layout 'even-horizonal'"* ]]
    [[ "$output" == *"even-horizontal, even-vertical, main-horizontal, main-vertical, tiled"* ]]
    [[ "$output" != *loaded* ]]
}

@test "config: a session_name with . or : is rejected at load time" {
    local bad
    for bad in "home.lab" "home:lab"; do
        sed -i '/^session_name=/d' "$SSHL_DATA_DIR_OVERRIDE/config"
        echo "session_name=$bad" >> "$SSHL_DATA_DIR_OVERRIDE/config"
        load_config 'echo loaded'
        [ "$status" -eq 1 ]
        [[ "$output" == *"session_name '$bad'"*"without '.' or ':'"* ]]
    done
}

@test "config: a terminal with arguments splits into the command and its arguments" {
    sed -i '/^terminal=/d' "$SSHL_DATA_DIR_OVERRIDE/config"
    echo "terminal=konsole --profile x" >> "$SSHL_DATA_DIR_OVERRIDE/config"
    load_config 'printf "%s|" "${terminal_cmd[@]}"'
    [ "$status" -eq 0 ]
    [ "$output" = "konsole|--profile|x|" ]
}

@test "fzf_new_enough: compares against the minimum by version, not by text" {
    fzf_new_enough "$SSHL_FZF_MIN"
    fzf_new_enough 0.54.3
    fzf_new_enough 1.0
    run fzf_new_enough 0.44.1
    [ "$status" -ne 0 ]
    run fzf_new_enough 0.9.0
    [ "$status" -ne 0 ]
    run fzf_new_enough ""
    [ "$status" -ne 0 ]
}

@test "scan_subnet: prints each host nmap reports, grouped by /24" {
    stub_cmd ssh 'exit 255'
    stub_cmd getent 'exit 2'
    scan_subnet 2> "$SSHL_DATA_DIR_OVERRIDE/err.log"
    [ "$(sed -n '2,4p' "$SSHL_DATA_DIR_OVERRIDE/err.log")" = $'  192.0.2.0/24:\n    192.0.2.1\n    192.0.2.2' ]
}

@test "read_cache: succeeds when the last line has no name" {
    printf '192.0.2.51\thost-b\n192.0.2.50\t\n' > "$SSHL_DATA_DIR_OVERRIDE/ips.cache"
    read_cache
    [ "${#ips[@]}" = "2" ]
    [ "${ips[1]}" = "192.0.2.50" ]
    [ -z "${cached_name[192.0.2.50]:-}" ]
}

@test "read_ignored: succeeds when the last line has no name" {
    printf '192.0.2.9\told-host\n192.0.2.10\t\n' > "$SSHL_DATA_DIR_OVERRIDE/ignored.cache"
    read_ignored
    [ "${#ignored_ips[@]}" = "2" ]
    [ "${ignored_ips[1]}" = "192.0.2.10" ]
}

# The writers stage into "<file>.tmp.$$". Pointing that path at /dev/full
# makes every write fail with ENOSPC, which chmod cannot do for root.
@test "write_cache: a failed write returns non-zero and keeps the old cache" {
    printf '192.0.2.1\tfake-host-01\n192.0.2.2\tfake-host-02\n' > "$SSHL_DATA_DIR_OVERRIDE/ips.cache"
    before=$(cat "$SSHL_DATA_DIR_OVERRIDE/ips.cache")
    read_cache
    ln -s /dev/full "$SSHL_DATA_DIR_OVERRIDE/ips.cache.tmp.$$"
    if write_cache; then rc=0; else rc=1; fi
    [ "$rc" -eq 1 ]
    [ ! -L "$SSHL_DATA_DIR_OVERRIDE/ips.cache" ]
    [ "$(cat "$SSHL_DATA_DIR_OVERRIDE/ips.cache")" = "$before" ]
    [ ! -L "$SSHL_DATA_DIR_OVERRIDE/ips.cache.tmp.$$" ]
}

@test "write_ignored: a failed write returns non-zero and keeps the old file" {
    printf '192.0.2.9\told-host\n' > "$SSHL_DATA_DIR_OVERRIDE/ignored.cache"
    read_ignored
    ln -s /dev/full "$SSHL_DATA_DIR_OVERRIDE/ignored.cache.tmp.$$"
    if write_ignored; then rc=0; else rc=1; fi
    [ "$rc" -eq 1 ]
    [ ! -L "$SSHL_DATA_DIR_OVERRIDE/ignored.cache" ]
    [ "$(cat "$SSHL_DATA_DIR_OVERRIDE/ignored.cache")" = $'192.0.2.9\told-host' ]
    [ ! -L "$SSHL_DATA_DIR_OVERRIDE/ignored.cache.tmp.$$" ]
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

@test "substitute: an & in a value is kept literally" {
    result=$(substitute "ssh {user}@{ip} # {hostname}" "10.0.0.1" "a&b" "x&y")
    [ "$result" = "ssh a&b@10.0.0.1 # x&y" ]
}

@test "scan_subnet: a name from ssh that is not a plain hostname falls back to the IP" {
    # shellcheck disable=SC2016  # the payload is meant to stay literal
    stub_cmd ssh 'case "$*" in
    *192.0.2.1*) echo "pve;touch\${IFS}$SSHL_DATA_DIR_OVERRIDE/INJECTED;#" ;;
    *) echo "#[bg=red]x" ;;
esac'
    stub_cmd getent 'exit 2'
    scan_subnet
    [ -z "${discovered_name[192.0.2.1]:-}" ]
    [ -z "${discovered_name[192.0.2.2]:-}" ]
    [ "$(resolve_hostname 192.0.2.1)" = "192.0.2.1" ]
    ips=("${discovered_ips[@]}")
    build_with_marker_panes
    wait_until 5 test -e "$SSHL_DATA_DIR_OVERRIDE/ran.192.0.2.1"
    [ ! -e "$SSHL_DATA_DIR_OVERRIDE/INJECTED" ]
}

@test "read_cache and read_ignored: a line whose IP is not an address is skipped and never runs" {
    {
        printf '192.0.2.1;touch %s/ip-ran\tok\n' "$SSHL_DATA_DIR_OVERRIDE"
        printf '$(touch %s/ip-ran2)\tok\n' "$SSHL_DATA_DIR_OVERRIDE"
        printf '192.0.2.2\tpve;touch %s/name-ran;#\n' "$SSHL_DATA_DIR_OVERRIDE"
    } > "$SSHL_DATA_DIR_OVERRIDE/ips.cache"
    printf "192.0.2.3'x\n" > "$SSHL_DATA_DIR_OVERRIDE/ignored.cache"
    run read_cache
    [[ "$output" == *"skipping line 1 of $SSHL_DATA_DIR_OVERRIDE/ips.cache"* ]]
    [[ "$output" == *"skipping line 2 of $SSHL_DATA_DIR_OVERRIDE/ips.cache"* ]]
    read_cache 2>/dev/null
    read_ignored 2>/dev/null
    [ "${ips[*]}" = "192.0.2.2" ]
    [ "${#ignored_ips[@]}" = "0" ]
    build_with_marker_panes
    wait_until 5 test -e "$SSHL_DATA_DIR_OVERRIDE/ran.192.0.2.2"
    [ "$(live_order)" = "192.0.2.2 " ]
    [ ! -e "$SSHL_DATA_DIR_OVERRIDE/ip-ran" ]
    [ ! -e "$SSHL_DATA_DIR_OVERRIDE/ip-ran2" ]
    [ ! -e "$SSHL_DATA_DIR_OVERRIDE/name-ran" ]
}

@test "valid_hostname: accepts plain names and rejects the rest" {
    local n long
    long="$(printf 'a%.0s' $(seq 1 64))"
    for n in pve host-01 a.b_c 1host "${long:1}"; do
        valid_hostname "$n" || { echo "rejected $n" >&2; return 1; }
    done
    for n in "" -x "#[x]" "a;b" "a b" "$long" 192.168.1.10 10.0.0 1; do
        if valid_hostname "$n"; then echo "accepted '$n'" >&2; return 1; fi
    done
}

@test "scan_subnet: a reverse DNS name that is not a plain hostname is dropped" {
    stub_cmd ssh 'exit 255'
    # shellcheck disable=SC2016  # expanded by the stub, not here
    stub_cmd getent 'echo "$2 #[bg=red]evil.lan"'
    scan_subnet
    [ -z "${discovered_name[192.0.2.1]:-}" ]
}

@test "scan_subnet: ignored IPs are skipped before their names are resolved" {
    # shellcheck disable=SC2016  # expanded by the stub, not here
    stub_cmd ssh 'printf "%s\n" "$*" >> "$SSHL_DATA_DIR_OVERRIDE/ssh.log"; echo name'
    ignored_ips=("192.0.2.1")
    scan_subnet
    [ "${discovered_ips[*]}" = "192.0.2.2" ]
    run grep '192\.0\.2\.1' "$SSHL_DATA_DIR_OVERRIDE/ssh.log"
    [ "$status" -ne 0 ]
}

@test "read_cache and read_ignored: a cached name that is not a plain hostname is dropped" {
    printf '192.0.2.1\t#[bg=red]x\n192.0.2.2\tgood-name\n' > "$SSHL_DATA_DIR_OVERRIDE/ips.cache"
    printf '192.0.2.3\tbad;name\n' > "$SSHL_DATA_DIR_OVERRIDE/ignored.cache"
    read_cache
    read_ignored
    [ "${#ips[@]}" = "2" ]
    [ -z "${cached_name[192.0.2.1]:-}" ]
    [ "${cached_name[192.0.2.2]}" = "good-name" ]
    [ "${ignored_ips[0]}" = "192.0.2.3" ]
    [ -z "${ignored_name[192.0.2.3]:-}" ]
}

@test "config: the first run creates the config and asks for a subnet before any scan" {
    rm "$SSHL_DATA_DIR_OVERRIDE/config"
    load_config 'echo loaded'
    [ "$status" -eq 1 ]
    [[ "$output" == *"Created $SSHL_DATA_DIR_OVERRIDE/config from config.example. Set subnet= in it"* ]]
    [[ "$output" != *loaded* ]]
    cmp "$SSHL_SRC/config.example" "$SSHL_DATA_DIR_OVERRIDE/config"
    load_config 'echo "loaded subnet=$subnet"'
    [ "$status" -eq 1 ]
    [[ "$output" == *"'subnet' is not set in $SSHL_DATA_DIR_OVERRIDE/config"*"subnet=192.168.1.0/24"* ]]
    [[ "$output" != *loaded* ]]
}

@test "config: an unknown key is reported with its line number" {
    echo "defualt_user=admin" >> "$SSHL_DATA_DIR_OVERRIDE/config"
    load_config 'echo "user=$default_user"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Warning: line 7 of $SSHL_DATA_DIR_OVERRIDE/config has an unknown key 'defualt_user', ignoring it."* ]]
    [[ "$output" == *"user=testuser"* ]]
}

@test "config: a per-host key that names a host instead of an IP is reported" {
    echo "host.web01.user=admin" >> "$SSHL_DATA_DIR_OVERRIDE/config"
    load_config 'echo "${#host_user[@]} overrides"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Warning: line 7 of $SSHL_DATA_DIR_OVERRIDE/config: per-host keys take the host's IP, as in host.192.168.1.10.user, ignoring host.web01.user."* ]]
    [[ "$output" == *"0 overrides"* ]]
}

@test "config: quotes around a whole value are dropped" {
    cat >> "$SSHL_DATA_DIR_OVERRIDE/config" << 'EOF2'
subnet="10.0.0.0/24"
terminal='konsole --profile x'
host.192.0.2.5.right_cmd="ssh -t {user}@{ip} "htop -d 10""
EOF2
    load_config 'printf "%s|" "$subnet" "${terminal_cmd[@]}" "${host_right_cmd[192.0.2.5]}"'
    [ "$status" -eq 0 ]
    [ "$output" = '10.0.0.0/24|konsole|--profile|x|ssh -t {user}@{ip} "htop -d 10"|' ]
}

@test "config: an empty default_user, left_cmd or right_cmd is rejected at load time" {
    local key
    for key in default_user left_cmd right_cmd; do
        sed -i "/^$key=/d" "$SSHL_DATA_DIR_OVERRIDE/config"
        echo "$key=" >> "$SSHL_DATA_DIR_OVERRIDE/config"
        load_config 'echo loaded'
        [ "$status" -eq 1 ]
        [[ "$output" == *"Error: '$key' in $SSHL_DATA_DIR_OVERRIDE/config is empty."* ]]
        [[ "$output" != *loaded* ]]
        sed -i "/^$key=/d" "$SSHL_DATA_DIR_OVERRIDE/config"
    done
}

@test "scan_subnet: a subnet nmap cannot read fails and names the config key" {
    # What nmap 7.94 prints for subnet=lan, and its exit status.
    stub_cmd nmap 'echo "Starting Nmap 7.94SVN ( https://nmap.org )"
echo "Failed to resolve \"lan\"." >&2
echo "WARNING: No targets were specified, so 0 hosts scanned." >&2
echo "Nmap done: 0 IP addresses (0 hosts up) scanned in 0.03 seconds"'
    run scan_subnet
    [ "$status" -eq 1 ]
    [[ "$output" == *'Failed to resolve "lan".'* ]]
    [[ "$output" == *"Error: nmap could not read the subnet '$subnet'. Set subnet= in $CONFIG_FILE to one or more ranges in CIDR notation"* ]]
    [[ "$output" != *"No live hosts found"* ]]
}

@test "scan_subnet: several subnets, split on spaces or commas, each reach nmap as a target" {
    # shellcheck disable=SC2016  # expanded by the stub, not here
    stub_cmd nmap 'printf "%s\n" "$@" > "$SSHL_DATA_DIR_OVERRIDE/nmap.args"'
    subnet="192.0.2.0/24  198.51.100.0/24,203.0.113.0/25"
    scan_subnet 2>/dev/null
    grep -qx '192.0.2.0/24' "$SSHL_DATA_DIR_OVERRIDE/nmap.args"
    grep -qx '198.51.100.0/24' "$SSHL_DATA_DIR_OVERRIDE/nmap.args"
    grep -qx '203.0.113.0/25' "$SSHL_DATA_DIR_OVERRIDE/nmap.args"
}

@test "scan_subnet: a netmask nmap rejects fails instead of scanning one host" {
    stub_cmd nmap 'echo "Illegal netmask in \"10.1.0.0/66\". Assuming /32 (one host)" >&2'
    run scan_subnet
    [ "$status" -eq 1 ]
    [[ "$output" == *"Error: nmap could not read the subnet"* ]]
}

@test "resolve_remote_hostname: a banner beside the name is never joined into it" {
    # shellcheck disable=SC2016  # expanded by the stub, not here
    stub_cmd ssh 'printf "%b" "$SSH_REPLY"'
    local reply
    for reply in 'Welcome\npve\n' 'pve\nlogout\n' 'Welcome to pve\n'; do
        SSH_REPLY="$reply" run resolve_remote_hostname 192.0.2.1
        if [ "$status" -eq 0 ] || [ -n "$output" ]; then
            echo "reply '$reply' gave status $status and '$output'" >&2
            return 1
        fi
    done
    SSH_REPLY='\npve\r\n\n' run resolve_remote_hostname 192.0.2.1
    [ "$status" -eq 0 ]
    [ "$output" = "pve" ]
}

@test "scan_subnet: a host whose name comes with a banner is shown by its IP" {
    stub_cmd ssh 'case "$*" in
    *192.0.2.1*) printf "Welcome\npve\n" ;;
    *) printf "pve2\n" ;;
esac'
    stub_cmd getent 'exit 2'
    scan_subnet
    [ -z "${discovered_name[192.0.2.1]:-}" ]
    [ "$(resolve_hostname 192.0.2.1)" = "192.0.2.1" ]
    [ "${discovered_name[192.0.2.2]}" = "pve2" ]
}

@test "scan_subnet: a host that stalls after login is shown by its IP and the scan ends" {
    export SSHL_RESOLVE_TIMEOUT_OVERRIDE=1
    stub_cmd ssh 'case "$*" in
    *192.0.2.1*) exec sleep 30 ;;
    *) printf "pve2\n" ;;
esac'
    stub_cmd getent 'exit 2'
    local start=$SECONDS
    scan_subnet
    (( SECONDS - start < 10 ))
    [ "${discovered_ips[*]}" = "192.0.2.1 192.0.2.2" ]
    [ -z "${discovered_name[192.0.2.1]:-}" ]
    [ "${discovered_name[192.0.2.2]}" = "pve2" ]
}

@test "resolve_remote_hostname: ssh gets keepalives and a 15s limit unless the override is a positive number" {
    local real v
    real="$(command -v timeout)"
    # shellcheck disable=SC2016  # expanded by the stub, not here
    stub_cmd ssh 'printf " %s " "$*" > "$SSHL_DATA_DIR_OVERRIDE/ssh.args"; echo pve'
    # shellcheck disable=SC2016  # expanded by the stub, not here
    stub_cmd timeout 'printf "%s\n" "${*:1:4}" >> "$SSHL_DATA_DIR_OVERRIDE/timeout.log"
exec '"$real"' "$@"'
    resolve_remote_hostname 192.0.2.1 > /dev/null
    for v in 0 abc 3; do
        SSHL_RESOLVE_TIMEOUT_OVERRIDE="$v" resolve_remote_hostname 192.0.2.1 > /dev/null
    done
    [ "$(cat "$SSHL_DATA_DIR_OVERRIDE/timeout.log")" = $'-k 5 15 ssh\n-k 5 15 ssh\n-k 5 15 ssh\n-k 5 3 ssh' ]
    local args
    args="$(cat "$SSHL_DATA_DIR_OVERRIDE/ssh.args")"
    [[ "$args" == *" -o BatchMode=yes "* ]]
    [[ "$args" == *" -o ServerAliveInterval=5 "* ]]
    [[ "$args" == *" -o ServerAliveCountMax=3 "* ]]
}
