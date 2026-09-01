#!/usr/bin/env bats

load test_helper

@test "patches the -RpvU variant to match the expected file exactly" {
    seed u.pm
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"APPLIED"* ]]
    diff "$FIXTURES/u-patched.pm" "$FILE"
}

@test "patches the pre-9.1.3 variant to match the expected file exactly" {
    export FAKE_PKG_VER=9.1.2
    seed plain.pm
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    diff "$FIXTURES/plain-patched.pm" "$FILE"
}

@test "9.1.3 selects the -U variant" {
    export FAKE_PKG_VER=9.1.3
    seed u.pm
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    diff "$FIXTURES/u-patched.pm" "$FILE"
}

@test "9.1.4 selects the -U variant" {
    export FAKE_PKG_VER=9.1.4
    seed u.pm
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    diff "$FIXTURES/u-patched.pm" "$FILE"
}

@test "backup is byte-identical to the pre-patch file" {
    seed u.pm
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(backup_count)" -eq 1 ]
    diff "$FIXTURES/u.pm" "$(only_backup)"
}

@test "second run reports OK and creates no second backup" {
    seed u.pm
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
    [ "$(backup_count)" -eq 1 ]
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

@test "refuses to patch when the backup directory cannot be created" {
    seed u.pm
    mkdir -p "$PATCH_TMP/ro"
    chmod 500 "$PATCH_TMP/ro"
    export PVE_ZFS_PATCH_BACKUP_DIR_OVERRIDE="$PATCH_TMP/ro/backups"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED"* ]]
    diff "$FIXTURES/u.pm" "$FILE"
}

@test "refuses to patch when the backup copy fails, leaving no partial backup" {
    seed u.pm
    mkdir -p "$BACKUPS"
    chmod 500 "$BACKUPS"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"without a backup"* ]]
    diff "$FIXTURES/u.pm" "$FILE"
    chmod 700 "$BACKUPS"
    [ "$(backup_count)" -eq 0 ]
}

@test "a target that is not a regular file is named as such" {
    mkdir -p "$FILE"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"directory"* ]]
    [[ "$output" == *"not a regular file"* ]]
}

@test "unreadable target is reported as a read failure, not an upstream change" {
    seed u.pm
    chmod 000 "$FILE"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED"* ]]
    [[ "$output" != *"Upstream code may have changed"* ]]
}

@test "file missing with the package present warns and exits 1" {
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WARNING"* ]]
    [[ "$output" == *"is missing"* ]]
}

@test "file missing with the package absent exits 0 with removal advice" {
    export FAKE_PKG_RC=1
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"NOT INSTALLED"* ]]
    [[ "$output" == *"99-pve-zfs-large-block-patch"* ]]
}

@test "config-files state with no file exits 0" {
    export FAKE_PKG_STATE=config-files
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"NOT INSTALLED"* ]]
}

@test "present-but-not-installed states are treated as present" {
    local state
    for state in hold-installed half-installed unpacked half-configured triggers-pending triggers-awaited; do
        FAKE_PKG_STATE="$state" run "$SCRIPT"
        [ "$status" -eq 1 ]
        [[ "$output" == *"WARNING"* ]]
    done
}

@test "a broken dpkg-query is not treated as an absent package" {
    export FAKE_PKG_RC=2
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED"* ]]
    [[ "$output" != *"NOT INSTALLED"* ]]
}

@test "dpkg-query output without a separator is rejected" {
    export FAKE_PKG_RAW=installed
    seed u.pm
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unparsable"* ]]
    diff "$FIXTURES/u.pm" "$FILE"
}

@test "unknown upstream shape fails loudly and leaves the file alone" {
    printf "my \$cmd = ['zfs', 'send', '-Rpv', '-w'];\n" > "$FILE"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not contain expected pattern"* ]]
    [ "$(grep -c -- "-w" "$FILE")" -eq 1 ]
}

@test "failures reach syslog" {
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    grep -q "is missing" "$FAKE_SYSLOG"
}

@test "successful runs log nothing to syslog" {
    seed u.pm
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -s "$FAKE_SYSLOG" ]
}
