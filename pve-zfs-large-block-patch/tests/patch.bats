#!/usr/bin/env bats

load test_helper

REQUIRED_CMDS=(grep sed cp cmp mv mkdir rm stat date flock logger dpkg-query)

syslog_line() {
    printf -- '-p %s -t pve-zfs-L-patch -- %s\n' "$1" "$2"
}

@test "patches the -RpvU variant to match the expected file exactly" {
    seed u.pm
    patch_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"APPLIED"* ]]
    diff "$FIXTURES/u-patched.pm" "$FILE"
}

@test "patches the -Rpv variant to match the expected file exactly" {
    seed plain.pm
    patch_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"APPLIED"* ]]
    diff "$FIXTURES/plain-patched.pm" "$FILE"
}

@test "the variant comes from the file, so the package version is never asked for" {
    seed u.pm
    patch_run
    [ "$status" -eq 0 ]
    printf '%s\n' -W '-f=${db:Status-Status}\n' libpve-storage-perl | diff - "$FAKE_DPKG_QUERY_ARGS"
}

@test "a file with both reviewed variants gets both patched" {
    printf "my \$cmd = ['zfs', 'send', '-RpvU'];\nmy \$cmd = ['zfs', 'send', '-Rpv'];\n" > "$FILE"
    patch_run
    [ "$status" -eq 0 ]
    printf "my \$cmd = ['zfs', 'send', '-RpvUL'];\nmy \$cmd = ['zfs', 'send', '-RpvL'];\n" | diff - "$FILE"
}

@test "backup is byte-identical to the pre-patch file and keeps its mode and mtime" {
    seed u.pm
    chmod 640 "$FILE"
    touch -d '2024-01-02 03:04:05' "$FILE"
    patch_run
    [ "$status" -eq 0 ]
    [ "$(backup_count)" -eq 1 ]
    diff "$FIXTURES/u.pm" "$(only_backup)"
    [ "$(stat -c '%a %Y' "$(only_backup)")" = "640 $(date -d '2024-01-02 03:04:05' +%s)" ]
    [[ "$output" == *"backup: $(only_backup)"* ]]
}

@test "second run reports OK, creates no second backup and logs nothing" {
    seed u.pm
    patch_run
    [ "$status" -eq 0 ]
    : > "$FAKE_SYSLOG"
    patch_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
    [ "$(backup_count)" -eq 1 ]
    [ ! -s "$FAKE_SYSLOG" ]
}

@test "a file already patched in the -RpvL shape reports OK and is left alone" {
    seed plain-patched.pm
    patch_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK - patch already present"* ]]
    diff "$FIXTURES/plain-patched.pm" "$FILE"
    [ "$(backup_count)" -eq 0 ]
}

@test "two send statements on one line are not the known shape" {
    printf "my \$cmd = ['zfs', 'send', '-RpvU']; my \$cmd = ['zfs', 'send', '-RpvU'];\n" > "$FILE"
    cp "$FILE" "$PATCH_TMP/before"
    patch_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"WARNING - $FILE does not contain expected pattern."* ]]
    diff "$PATCH_TMP/before" "$FILE"
}

@test "a half-patched file gets its remaining site patched" {
    printf "my \$cmd = ['zfs', 'send', '-RpvUL'];\nmy \$cmd = ['zfs', 'send', '-RpvU'];\n" > "$FILE"
    patch_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"APPLIED"* ]]
    [ "$(grep -oF -- "'-RpvU']" "$FILE" | wc -l)" -eq 0 ]
}

@test "symlinked target: real file is patched and the symlink survives" {
    cp "$FIXTURES/u.pm" "$(dirname "$FILE")/real.pm"
    ln -sfn real.pm "$FILE"
    patch_run
    [ "$status" -eq 0 ]
    [ -L "$FILE" ]
    diff "$FIXTURES/u-patched.pm" "$(dirname "$FILE")/real.pm"
    diff "$FIXTURES/u.pm" "$(only_backup)"
}

@test "broken symlink is diagnosed as such" {
    ln -sfn /nonexistent/target.pm "$FILE"
    patch_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED - $FILE is a broken symlink."* ]]
}

@test "a target that is not a regular file is named as such" {
    mkdir -p "$FILE"
    patch_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED - $FILE is a directory, not a regular file."* ]]
}

@test "refuses to patch when the backup directory cannot be created" {
    seed u.pm
    : > "$ROOT/var"
    patch_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED - cannot create $BACKUPS"* ]]
    [[ "$output" == *"Nothing was changed."* ]]
    grep -F -- "-p daemon.err -t pve-zfs-L-patch -- cannot create $BACKUPS: mkdir: " "$FAKE_SYSLOG"
    [[ "$output" != *"APPLIED"* ]]
    diff "$FIXTURES/u.pm" "$FILE"
}

@test "refuses to patch when the backup directory is read-only" {
    seed u.pm
    mkdir -p "$BACKUPS"
    : > "$BACKUPS/.lock"
    chmod 555 "$BACKUPS"
    patch_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED - backup to"* ]]
    [[ "$output" == *"without a backup"* ]]
    diff "$FIXTURES/u.pm" "$FILE"
    [ "$(backup_count)" -eq 0 ]
    # The journal gets only the first message line, so the cause must be on it.
    grep -F -- "-p daemon.err -t pve-zfs-L-patch -- backup to $BACKUPS/" "$FAKE_SYSLOG" | grep -F "Permission denied"
}

@test "a lock file that cannot be created stops the run" {
    seed u.pm
    mkdir -p "$BACKUPS"
    chmod 555 "$BACKUPS"
    patch_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED - cannot open $BACKUPS/.lock."* ]]
    diff "$FIXTURES/u.pm" "$FILE"
}

@test "a second run waits for the lock, then sees the first run's patch" {
    seed u.pm
    mkdir -p "$BACKUPS"
    flock "$BACKUPS/.lock" sleep 2 >/dev/null 2>&1 3>&- &
    wait_for_lock_holder
    local start=$SECONDS
    patch_run
    [ "$status" -eq 0 ]
    [ $((SECONDS - start)) -ge 1 ]
    [[ "$output" == *"APPLIED"* ]]
    wait
}

@test "a lock held past the wait fails cleanly and changes nothing" {
    seed u.pm
    mkdir -p "$BACKUPS"
    flock "$BACKUPS/.lock" sleep 11 >/dev/null 2>&1 3>&- &
    wait_for_lock_holder
    patch_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED - another run has held $BACKUPS/.lock for 10s."* ]]
    diff "$FIXTURES/u.pm" "$FILE"
    [ "$(backup_count)" -eq 0 ]
}

@test "a backup copy that fails partway leaves no partial backup" {
    seed u.pm
    # With a file size limit of 0, cp creates the backup and then every write
    # to it fails with EFBIG, as on a full disk.
    run bash -c 'trap "" XFSZ; ulimit -f 0; "$@"' _ "$SCRIPT" --root "$ROOT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED - backup to $BACKUPS/"*"File too large"* ]]
    diff "$FIXTURES/u.pm" "$FILE"
    [ -d "$BACKUPS" ]
    [ "$(backup_count)" -eq 0 ]
    [ ! -e "$BACKUPS/.partial" ]
}

@test "refuses to patch when the backup copy reports success but differs" {
    seed u.pm
    with_stub cp
    patch_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not match"* ]]
    [[ "$output" == *"without a backup"* ]]
    diff "$FIXTURES/u.pm" "$FILE"
    [ "$(backup_count)" -eq 0 ]
}

@test "a repeated failing write does not pile up identical backups" {
    seed u.pm
    chmod 555 "$(dirname "$FILE")"
    patch_run
    [ "$status" -eq 1 ]
    patch_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"reusing $(only_backup)"* ]]
    [ "$(backup_count)" -eq 1 ]
    diff "$FIXTURES/u.pm" "$(only_backup)"
}

@test "a re-patch of identical content reuses the backup, new content gets its own" {
    seed u.pm
    patch_run
    [ "$status" -eq 0 ]
    first="$(only_backup)"
    seed u.pm
    patch_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"APPLIED"*"(backup: $first)"* ]]
    [ "$(backup_count)" -eq 1 ]
    seed plain.pm
    patch_run
    [ "$status" -eq 0 ]
    [ "$(backup_count)" -eq 2 ]
}

@test "only the backup with the newest name is reused" {
    mkdir -p "$BACKUPS"
    cp "$FIXTURES/plain.pm" "$BACKUPS/ZFSPoolPlugin.pm.prepatch.20240101-000000.1"
    cp "$FIXTURES/u.pm" "$BACKUPS/ZFSPoolPlugin.pm.prepatch.20240301-000000.1"
    cp "$FIXTURES/plain.pm" "$BACKUPS/ZFSPoolPlugin.pm.prepatch.20240201-000000.1"
    seed u.pm
    patch_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"reusing $BACKUPS/ZFSPoolPlugin.pm.prepatch.20240301-000000.1"* ]]
    [ "$(backup_count)" -eq 3 ]
    seed plain.pm
    patch_run
    [ "$status" -eq 0 ]
    [[ "$output" != *"reusing"* ]]
    [ "$(backup_count)" -eq 4 ]
}

@test "a sed that cannot write says the file is unchanged and logs sed's error" {
    seed u.pm
    chmod 555 "$(dirname "$FILE")"
    patch_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED - sed could not patch $FILE: sed: couldn't open temporary file"*"Permission denied"* ]]
    [[ "$output" == *"$FILE is unchanged. Check that it is not immutable (lsattr)"* ]]
    [[ "$output" != *"APPLIED"* ]]
    diff "$FIXTURES/u.pm" "$FILE"
    grep -F -- "-p daemon.err -t pve-zfs-L-patch -- sed could not patch $FILE: sed: couldn't open temporary file" "$FAKE_SYSLOG" | grep -F "Permission denied"
}

@test "a sed that exits 0 without patching is caught for either shape" {
    local fx
    with_stub sed
    for fx in u.pm plain.pm; do
        seed "$fx"
        patch_run
        [ "$status" -eq 1 ]
        [[ "$output" == *"FAILED - $FILE is not correctly patched after sed."* ]]
        [[ "$output" == *"Restore $BACKUPS/"* ]]
        [[ "$output" != *"APPLIED"* ]]
    done
}

@test "an unreadable file is reported as a read error, not as an upstream change" {
    seed u.pm
    chmod 000 "$FILE"
    patch_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED - cannot read $FILE (grep exit 2)"* ]]
    [[ "$output" != *"Upstream code may have changed"* ]]
    [[ "$output" != *"OK"* ]]
    [ "$(backup_count)" -eq 0 ]
}

@test "file missing with the package installed warns, exits 1 and logs to daemon.err" {
    patch_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"WARNING - libpve-storage-perl is installed but $FILE is missing."* ]]
    syslog_line daemon.err "libpve-storage-perl is installed but $FILE is missing." | diff - "$FAKE_SYSLOG"
}

@test "every present dpkg state with no file warns" {
    local state
    for state in installed half-installed unpacked half-configured triggers-awaited triggers-pending; do
        FAKE_PKG_STATE="$state" patch_run
        [ "$status" -eq 1 ]
        [[ "$output" == *"WARNING - libpve-storage-perl is $state but"* ]]
    done
}

@test "no dpkg record of the package and no file exits 0 with removal advice" {
    export FAKE_PKG_RC=1
    patch_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"NOT INSTALLED"* ]]
    [[ "$output" == *"99-pve-zfs-large-block-patch"* ]]
    [ ! -s "$FAKE_SYSLOG" ]
}

@test "not-installed state with no file exits 0" {
    export FAKE_PKG_STATE=not-installed
    patch_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"NOT INSTALLED"* ]]
}

@test "config-files state with no file exits 0" {
    export FAKE_PKG_STATE=config-files
    patch_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"NOT INSTALLED"* ]]
}

@test "a dpkg-query warning on stderr does not become part of the state" {
    export FAKE_PKG_STATE=config-files
    export FAKE_PKG_STDERR="dpkg-query: warning: parsing file '/var/lib/dpkg/status' near line 15 package 'otherpkg':"
    patch_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"NOT INSTALLED"* ]]
    [[ "$output" != *"warning"* ]]
}

@test "a dpkg-query warning on stderr does not stop the patch" {
    export FAKE_PKG_STDERR="dpkg-query: warning: parsing file '/var/lib/dpkg/status' near line 15 package 'otherpkg':"
    seed u.pm
    patch_run
    [ "$status" -eq 0 ]
    diff "$FIXTURES/u-patched.pm" "$FILE"
}

@test "a broken dpkg-query is not treated as an absent package and its error is shown" {
    export FAKE_PKG_RC=2
    patch_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED - cannot determine libpve-storage-perl status (dpkg-query exit 2): dpkg-query: error: unable to read database"* ]]
    [[ "$output" != *"NOT INSTALLED"* ]]
}

@test "a dpkg-query answer that is not a dpkg status value is rejected" {
    local raw
    seed u.pm
    for raw in hold-installed 'installed|9.1.5' bogus '' $'installed\ninstalled'; do
        FAKE_PKG_RAW="$raw" patch_run
        [ "$status" -eq 1 ]
        [[ "$output" == *"FAILED - dpkg-query returned an unrecognised status for libpve-storage-perl"* ]]
        diff "$FIXTURES/u.pm" "$FILE"
    done
}

@test "exit 1 from dpkg-query with output on stdout is rejected" {
    export FAKE_PKG_RAW=installed FAKE_PKG_RC=1
    patch_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"unrecognised status"* ]]
}

@test "unknown upstream shape fails loudly and leaves the file alone" {
    printf "my \$cmd = ['zfs', 'send', '-Rpv', '-w'];\n" > "$FILE"
    cp "$FILE" "$PATCH_TMP/before"
    patch_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not contain expected pattern"* ]]
    diff "$PATCH_TMP/before" "$FILE"
    [ "$(backup_count)" -eq 0 ]
}

@test "a message string that mentions a send command does not stop the patch" {
    seed u.pm
    printf '    die "zfs send -RpvU failed\\n" if $err;\n' >> "$FILE"
    patch_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"APPLIED"* ]]
    patch_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK - patch already present"* ]]
}

@test "a file where the known call is gone warns and exits 1" {
    seed u.pm
    sed -i "/'zfs', 'send'/d" "$FILE"
    printf '    die "zfs send -RpvU failed\\n" if $err;\n' >> "$FILE"
    cp "$FILE" "$PATCH_TMP/before"
    patch_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"WARNING - $FILE does not contain expected pattern."* ]]
    diff "$PATCH_TMP/before" "$FILE"
}

@test "a known call followed by a comment is patched and keeps the comment" {
    printf "    my \$cmd = ['zfs', 'send', '-RpvU']; # upstream\n" > "$FILE"
    patch_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"APPLIED"* ]]
    printf "    my \$cmd = ['zfs', 'send', '-RpvUL']; # upstream\n" | diff - "$FILE"
}

@test "a copy of the known call inside a trailing comment is not the call" {
    local line="    my \$cmd = ['zfs', 'send', '-RpvU', \$x]; # was: my \$cmd = ['zfs', 'send', '-RpvU'];"
    printf '%s\n' "$line" > "$FILE"
    patch_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"WARNING - $FILE does not contain expected pattern."* ]]
    printf '%s\n' "$line" | diff - "$FILE"
}

@test "a commented-out copy before the live line is left alone and the live line is patched" {
    seed u.pm
    { printf "    # my \$cmd = ['zfs', 'send', '-RpvU'];\n"; cat "$FIXTURES/u.pm"; } > "$FILE"
    patch_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"APPLIED"* ]]
    { printf "    # my \$cmd = ['zfs', 'send', '-RpvU'];\n"; cat "$FIXTURES/u-patched.pm"; } | diff - "$FILE"
}

@test "a second send call in list form warns after the known call is patched" {
    seed u.pm
    printf '    my $probe = ["zfs","send", "-nP", $snap];\n' >> "$FILE"
    patch_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"WARNING - $FILE has 2 zfs send calls, the script knows 1. Others on line 29."* ]]
    [[ "$output" == *"The known send call was patched (backup: $(only_backup))."* ]]
    [[ "$output" != *"APPLIED"* ]]
    [ "$(grep -cF -- "'-RpvUL']" "$FILE")" -eq 1 ]
    syslog_line daemon.err "$FILE has 2 zfs send calls, the script knows 1. Others on line 29." | diff - "$FAKE_SYSLOG"
}

@test "a second send call warns on the already-patched path too" {
    seed u-patched.pm
    printf "    my \$a = ['zfs', 'send', '-w'];\n    my \$b = [ 'zfs' , 'send' ];\n" >> "$FILE"
    cp "$FILE" "$PATCH_TMP/before"
    patch_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"WARNING - $FILE has 3 zfs send calls, the script knows 1. Others on line 29, 30."* ]]
    [[ "$output" != *"OK"* ]]
    diff "$PATCH_TMP/before" "$FILE"
}

@test "send calls in whole-line comments are not counted" {
    seed u.pm
    printf "    # my \$probe = ['zfs', 'send', '-nP'];\n" >> "$FILE"
    patch_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"APPLIED"* ]]
}

@test "a commented-out copy of a reviewed line is neither rewritten nor counted" {
    seed u-patched.pm
    printf "    # my \$cmd = ['zfs', 'send', '-Rpv'];\n" >> "$FILE"
    cp "$FILE" "$PATCH_TMP/before"
    patch_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
    diff "$PATCH_TMP/before" "$FILE"
}

@test "patching the live line leaves a commented-out copy as it was" {
    seed u.pm
    printf "    # my \$cmd = ['zfs', 'send', '-RpvU'];\n" >> "$FILE"
    patch_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"APPLIED"* ]]
    { cat "$FIXTURES/u-patched.pm"; printf "    # my \$cmd = ['zfs', 'send', '-RpvU'];\n"; } | diff - "$FILE"
}

@test "a file whose only reviewed line is commented out is an unknown shape" {
    printf "    # my \$cmd = ['zfs', 'send', '-RpvU'];\n" > "$FILE"
    cp "$FILE" "$PATCH_TMP/before"
    patch_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not contain expected pattern"* ]]
    diff "$PATCH_TMP/before" "$FILE"
}

@test "APPLIED is logged at notice level under the script's tag" {
    seed u.pm
    patch_run
    [ "$status" -eq 0 ]
    syslog_line daemon.notice "patched $FILE to add -L flag (backup: $(only_backup))" | diff - "$FAKE_SYSLOG"
}

@test "every command the script needs is checked before any work" {
    local cmd other dir
    for cmd in "${REQUIRED_CMDS[@]}"; do
        dir="$PATCH_TMP/path-without-$cmd"
        mkdir -p "$dir"
        for other in "${REQUIRED_CMDS[@]}"; do
            [ "$other" = "$cmd" ] || ln -s "$(command -v "$other")" "$dir/$other"
        done
        seed u.pm
        PATH="$dir" run "$SCRIPT" --root "$ROOT"
        [ "$status" -eq 1 ]
        [[ "$output" == *"FAILED - required command not found: $cmd"* ]]
        diff "$FIXTURES/u.pm" "$FILE"
    done
}

@test "an unknown argument is refused before any work" {
    seed u.pm
    run "$SCRIPT" --root "$ROOT" --force
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED - unknown argument: --force"* ]]
    diff "$FIXTURES/u.pm" "$FILE"
    [ ! -e "$FAKE_DPKG_QUERY_ARGS" ]
}

@test "--root without a directory is refused" {
    run "$SCRIPT" --root
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED - --root needs a directory."* ]]
    [ ! -e "$FAKE_DPKG_QUERY_ARGS" ]
}
