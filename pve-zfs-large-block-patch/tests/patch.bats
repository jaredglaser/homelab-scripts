#!/usr/bin/env bats

load test_helper

REQUIRED_CMDS=(grep sed cp cmp mkdir rm stat date mktemp dpkg-query)

syslog_line() {
    printf -- '-p %s -t pve-zfs-L-patch -- %s\n' "$1" "$2"
}

@test "patches the -RpvU variant to match the expected file exactly" {
    seed u.pm
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"APPLIED"* ]]
    diff "$FIXTURES/u-patched.pm" "$FILE"
}

@test "patches the -Rpv variant to match the expected file exactly" {
    seed plain.pm
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"APPLIED"* ]]
    diff "$FIXTURES/plain-patched.pm" "$FILE"
}

@test "the variant comes from the file, so the package version is never asked for" {
    seed u.pm
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    printf '%s\n' -W '-f=${db:Status-Status}\n' libpve-storage-perl | diff - "$FAKE_DPKG_QUERY_ARGS"
}

@test "a file with both reviewed variants gets both patched" {
    printf "my \$cmd = ['zfs', 'send', '-RpvU'];\nmy \$cmd = ['zfs', 'send', '-Rpv'];\n" > "$FILE"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    printf "my \$cmd = ['zfs', 'send', '-RpvUL'];\nmy \$cmd = ['zfs', 'send', '-RpvL'];\n" | diff - "$FILE"
}

@test "backup is byte-identical to the pre-patch file" {
    seed u.pm
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(backup_count)" -eq 1 ]
    diff "$FIXTURES/u.pm" "$(only_backup)"
    [[ "$output" == *"backup: $(only_backup)"* ]]
}

@test "second run reports OK, creates no second backup and logs nothing" {
    seed u.pm
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    : > "$FAKE_SYSLOG"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
    [ "$(backup_count)" -eq 1 ]
    [ ! -s "$FAKE_SYSLOG" ]
}

@test "patches repeated call sites on one line" {
    printf "my \$cmd = ['zfs', 'send', '-RpvU']; my \$cmd = ['zfs', 'send', '-RpvU'];\n" > "$FILE"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(grep -oF -- "'-RpvU']" "$FILE" | wc -l)" -eq 0 ]
    [ "$(grep -oF -- "'-RpvUL']" "$FILE" | wc -l)" -eq 2 ]
}

@test "a half-patched file gets its remaining site patched" {
    printf "my \$cmd = ['zfs', 'send', '-RpvUL'];\nmy \$cmd = ['zfs', 'send', '-RpvU'];\n" > "$FILE"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"APPLIED"* ]]
    [ "$(grep -oF -- "'-RpvU']" "$FILE" | wc -l)" -eq 0 ]
}

@test "symlinked target: real file is patched and the symlink survives" {
    cp "$FIXTURES/u.pm" "$PATCH_TMP/root/real.pm"
    ln -sfn real.pm "$FILE"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -L "$FILE" ]
    diff "$FIXTURES/u-patched.pm" "$PATCH_TMP/root/real.pm"
    diff "$FIXTURES/u.pm" "$(only_backup)"
}

@test "broken symlink is diagnosed as such" {
    ln -sfn /nonexistent/target.pm "$FILE"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"broken symlink"* ]]
}

@test "a target that is not a regular file is named as such" {
    mkdir -p "$FILE"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"directory"* ]]
    [[ "$output" == *"not a regular file"* ]]
}

@test "refuses to patch when the backup directory cannot be created" {
    seed u.pm
    : > "$PATCH_TMP/not-a-dir"
    export PVE_ZFS_PATCH_BACKUP_DIR_OVERRIDE="$PATCH_TMP/not-a-dir/backups"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED - cannot create $PATCH_TMP/not-a-dir/backups"* ]]
    [[ "$output" == *"without a backup"* ]]
    grep -F -- "-p daemon.err -t pve-zfs-L-patch -- cannot create $PATCH_TMP/not-a-dir/backups: mkdir: " "$FAKE_SYSLOG"
    [[ "$output" != *"APPLIED"* ]]
    diff "$FIXTURES/u.pm" "$FILE"
}

@test "refuses to patch when the backup copy fails, leaving no partial backup" {
    seed u.pm
    with_stub cp
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED - backup to"* ]]
    [[ "$output" == *"without a backup"* ]]
    diff "$FIXTURES/u.pm" "$FILE"
    [ "$(backup_count)" -eq 0 ]
    # The journal gets only the first message line, so the cause must be on it.
    grep -F -- "-p daemon.err -t pve-zfs-L-patch -- backup to $BACKUPS/" "$FAKE_SYSLOG" | grep -F "No space left on device"
}

@test "refuses to patch when the backup copy reports success but differs" {
    seed u.pm
    with_stub cp
    export FAKE_CP_MODE=partial-ok
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not match"* ]]
    [[ "$output" == *"without a backup"* ]]
    diff "$FIXTURES/u.pm" "$FILE"
    [ "$(backup_count)" -eq 0 ]
}

@test "a repeated failing write does not pile up identical backups" {
    seed u.pm
    with_stub sed
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [ "$(backup_count)" -eq 1 ]
    diff "$FIXTURES/u.pm" "$(only_backup)"
}

@test "a re-patch of identical content reuses the backup, new content gets its own" {
    seed u.pm
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    first="$(only_backup)"
    seed u.pm
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"APPLIED"*"(backup: $first)"* ]]
    [ "$(backup_count)" -eq 1 ]
    seed plain.pm
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(backup_count)" -eq 2 ]
}

@test "a sed error that left the file alone says there is nothing to restore" {
    seed u.pm
    with_stub sed
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"sed could not patch $FILE: sed: couldn't edit $FILE: I/O error"* ]]
    [[ "$output" == *"unchanged"*"lsattr"* ]]
    [[ "$output" != *"Restore"* ]]
    diff "$FIXTURES/u.pm" "$FILE"
    syslog_line daemon.err "sed could not patch $FILE: sed: couldn't edit $FILE: I/O error" | diff - "$FAKE_SYSLOG"
}

@test "a sed error that changed the file points at the backup" {
    seed u.pm
    with_stub sed
    export FAKE_SED_MODE=fail-changed
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"sed could not patch $FILE: sed: couldn't edit $FILE: I/O error"* ]]
    [[ "$output" == *"Restore $(only_backup)"* ]]
}

@test "a sed that exits 0 without patching is caught by the post-patch check" {
    seed u.pm
    with_stub sed
    export FAKE_SED_MODE=noop-ok
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED"*"not correctly patched"* ]]
    [[ "$output" == *"Restore $(only_backup)"* ]]
    [[ "$output" != *"APPLIED"* ]]
}

@test "a read error is reported as such, not as an upstream change" {
    seed u.pm
    with_stub grep
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED - cannot read $FILE (grep exit 2)"* ]]
    [[ "$output" != *"Upstream code may have changed"* ]]
    [[ "$output" != *"OK"* ]]
    [[ "$output" != *"Restore"* ]]
}

@test "a read error in the call-site check is reported as such" {
    seed u.pm
    with_stub grep
    export FAKE_GREP_FAIL_MATCH=-nE
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED - cannot read $FILE (grep exit 2)"* ]]
    [[ "$output" == *"already rewritten. Restore $(only_backup)"* ]]
    [[ "$output" != *"APPLIED"* ]]
}

@test "file missing with the package installed warns, exits 1 and logs to daemon.err" {
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WARNING - libpve-storage-perl is installed but $FILE is missing."* ]]
    syslog_line daemon.err "libpve-storage-perl is installed but $FILE is missing." | diff - "$FAKE_SYSLOG"
}

@test "every present dpkg state with no file warns" {
    local state
    for state in installed half-installed unpacked half-configured triggers-awaited triggers-pending; do
        FAKE_PKG_STATE="$state" run "$SCRIPT"
        [ "$status" -eq 1 ]
        [[ "$output" == *"WARNING - libpve-storage-perl is $state but"* ]]
    done
}

@test "no dpkg record of the package and no file exits 0 with removal advice" {
    export FAKE_PKG_RC=1
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"NOT INSTALLED"* ]]
    [[ "$output" == *"99-pve-zfs-large-block-patch"* ]]
    [ ! -s "$FAKE_SYSLOG" ]
}

@test "not-installed state with no file exits 0" {
    export FAKE_PKG_STATE=not-installed
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"NOT INSTALLED"* ]]
}

@test "config-files state with no file exits 0" {
    export FAKE_PKG_STATE=config-files
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"NOT INSTALLED"* ]]
}

@test "a dpkg-query warning on stderr does not become part of the state" {
    export FAKE_PKG_STATE=config-files
    export FAKE_PKG_STDERR="dpkg-query: warning: parsing file '/var/lib/dpkg/status' near line 15 package 'otherpkg':"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"NOT INSTALLED"* ]]
    [[ "$output" != *"warning"* ]]
}

@test "a dpkg-query warning on stderr does not stop the patch" {
    export FAKE_PKG_STDERR="dpkg-query: warning: parsing file '/var/lib/dpkg/status' near line 15 package 'otherpkg':"
    seed u.pm
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    diff "$FIXTURES/u-patched.pm" "$FILE"
}

@test "a full /tmp does not stop the patch" {
    seed u.pm
    with_stub mktemp
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"APPLIED"* ]]
    diff "$FIXTURES/u-patched.pm" "$FILE"
}

@test "a full /tmp still shows a broken dpkg-query's error" {
    seed u.pm
    with_stub mktemp
    export FAKE_PKG_RC=2
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"dpkg-query: error: unable to read database"* ]]
    [[ "$output" == *"FAILED - cannot determine libpve-storage-perl status (dpkg-query exit 2)"* ]]
    diff "$FIXTURES/u.pm" "$FILE"
}

@test "a broken dpkg-query is not treated as an absent package and its error is shown" {
    export FAKE_PKG_RC=2
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED - cannot determine libpve-storage-perl status (dpkg-query exit 2): dpkg-query: error: unable to read database"* ]]
    [[ "$output" != *"NOT INSTALLED"* ]]
}

@test "a dpkg-query answer that is not a dpkg status value is rejected" {
    local raw
    seed u.pm
    for raw in hold-installed 'installed|9.1.5' bogus '' $'installed\ninstalled'; do
        FAKE_PKG_RAW="$raw" run "$SCRIPT"
        [ "$status" -eq 1 ]
        [[ "$output" == *"FAILED - dpkg-query returned an unrecognised status for libpve-storage-perl"* ]]
        diff "$FIXTURES/u.pm" "$FILE"
    done
}

@test "exit 1 from dpkg-query with output on stdout is rejected" {
    export FAKE_PKG_RAW=installed FAKE_PKG_RC=1
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unrecognised status"* ]]
}

@test "unknown upstream shape fails loudly and leaves the file alone" {
    printf "my \$cmd = ['zfs', 'send', '-Rpv', '-w'];\n" > "$FILE"
    cp "$FILE" "$PATCH_TMP/before"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not contain expected pattern"* ]]
    diff "$PATCH_TMP/before" "$FILE"
    [ "$(backup_count)" -eq 0 ]
}

@test "a second call site without -L fails after patching the known one" {
    seed u.pm
    printf "    my \$send = ['zfs', 'send', '-Rpvw', '--', \$snap];\n" >> "$FILE"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WARNING - $FILE still has a zfs send call without -L (line 29)."* ]]
    [[ "$output" == *"line 29: my \$send"* ]]
    [[ "$output" == *"known send call was patched"* ]]
    [[ "$output" != *"APPLIED"* ]]
    [ "$(grep -cF -- "'-RpvUL']" "$FILE")" -eq 1 ]
    syslog_line daemon.err "$FILE still has a zfs send call without -L (line 29)." | diff - "$FAKE_SYSLOG"
}

@test "a second call site without -L fails on the already-patched path" {
    seed u-patched.pm
    printf "    run_command(\"zfs send -Rpv \$snap\");\n" >> "$FILE"
    cp "$FILE" "$PATCH_TMP/before"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"without -L (line 29)"* ]]
    [[ "$output" != *"OK"* ]]
    diff "$PATCH_TMP/before" "$FILE"
}

@test "a call site with no flags at all counts as missing -L" {
    seed u-patched.pm
    printf "    my \$send = [\"zfs\", \"send\", '--', \$snap];\n" >> "$FILE"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"without -L (line 29)"* ]]
}

@test "two call sites on one line are checked separately" {
    printf "my \$cmd = ['zfs', 'send', '-RpvUL']; my \$b = ['zfs','send','-w'];\n" > "$FILE"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"without -L (line 1)"* ]]
}

@test "other call sites that already carry -L or --large-block are accepted" {
    seed u-patched.pm
    printf "    my \$a = ['zfs', 'send', '-wL', \$snap];\n    my \$b = ['zfs', 'send', '--large-block', \$snap];\n" >> "$FILE"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "message strings that mention zfs send are not call sites" {
    cat > "$FILE" <<'EOF'
    my $cmd = ['zfs', 'send', '-RpvUL'];
    die "zfs send failed\n" if $err;
    my $msg = "zfs send/receive failed";
    warn "zfs send stream for $snap was empty\n";
    log_warn('zfs send aborted');
    $class->zfs_request($scfg, undef, 'send', '-v', $snap);
    my $recv = ['zfs', 'recv', '-F', '--', $dataset];
EOF
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "a string-form zfs send command without -L is still a call site" {
    local cmd
    for cmd in '"zfs send -Rpv $snap"' '"zfs send $snap"' '"zfs send @args"' '"zfs send"' "'zfs send -w'"; do
        cp "$FIXTURES/u-patched.pm" "$FILE"
        printf '    run_command(%s);\n' "$cmd" >> "$FILE"
        run "$SCRIPT"
        [ "$status" -eq 1 ]
        [[ "$output" == *"without -L (line 29)"* ]]
    done
}

@test "a string-form zfs send command with -L passes" {
    seed u-patched.pm
    printf '    run_command("zfs send -RpvUL $snap");\n' >> "$FILE"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "a commented-out send line is not a call site" {
    seed u-patched.pm
    printf "    # my \$send = ['zfs', 'send', '-Rpvw', \$snap];\n#\"zfs send -Rpv \$snap\"\n" >> "$FILE"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "a commented-out copy of a reviewed line is neither rewritten nor counted" {
    seed u-patched.pm
    printf "    # my \$cmd = ['zfs', 'send', '-Rpv'];\n" >> "$FILE"
    cp "$FILE" "$PATCH_TMP/before"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
    diff "$PATCH_TMP/before" "$FILE"
}

@test "patching the live line leaves a commented-out copy as it was" {
    seed u.pm
    printf "    # my \$cmd = ['zfs', 'send', '-RpvU'];\n" >> "$FILE"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"APPLIED"* ]]
    { cat "$FIXTURES/u-patched.pm"; printf "    # my \$cmd = ['zfs', 'send', '-RpvU'];\n"; } | diff - "$FILE"
}

@test "a file whose only reviewed line is commented out is an unknown shape" {
    printf "    # my \$cmd = ['zfs', 'send', '-RpvU'];\n" > "$FILE"
    cp "$FILE" "$PATCH_TMP/before"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not contain expected pattern"* ]]
    diff "$PATCH_TMP/before" "$FILE"
}

@test "APPLIED is logged at notice level under the script's tag" {
    seed u.pm
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    syslog_line daemon.notice "patched $FILE to add -L flag (backup: $(only_backup))" | diff - "$FAKE_SYSLOG"
}

@test "test mode is announced with the paths it uses" {
    seed u.pm
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"TEST MODE - PVE_ZFS_PATCH_TESTING=1, using $FILE and $BACKUPS"* ]]
}

@test "the overrides are ignored, and say so, without PVE_ZFS_PATCH_TESTING=1" {
    # A broken dpkg-query stops the script before it touches any file, so this
    # cannot reach the real ZFSPoolPlugin.pm on a Proxmox node.
    export FAKE_PKG_RC=2
    local testing
    for testing in "" 0 yes; do
        PVE_ZFS_PATCH_TESTING="$testing" run "$SCRIPT"
        [ "$status" -eq 1 ]
        [[ "$output" == *"ignoring PVE_ZFS_PATCH_FILE_OVERRIDE and PVE_ZFS_PATCH_BACKUP_DIR_OVERRIDE"* ]]
        [[ "$output" == *"using /usr/share/perl5/PVE/Storage/ZFSPoolPlugin.pm"* ]]
        [[ "$output" != *"TEST MODE"* ]]
        [[ "$output" != *"$PATCH_TMP"* ]]
        [[ "$output" == *"FAILED - cannot determine"* ]]
    done
}

@test "every command the script needs is checked before any work" {
    local cmd other dir
    for cmd in "${REQUIRED_CMDS[@]}"; do
        dir="$PATCH_TMP/path-without-$cmd"
        mkdir -p "$dir"
        for other in "${REQUIRED_CMDS[@]}" logger; do
            [ "$other" = "$cmd" ] || ln -s "$(command -v "$other")" "$dir/$other"
        done
        seed u.pm
        PATH="$dir" run "$SCRIPT"
        [ "$status" -eq 1 ]
        [[ "$output" == *"FAILED - required command not found: $cmd"* ]]
        diff "$FIXTURES/u.pm" "$FILE"
    done
}
