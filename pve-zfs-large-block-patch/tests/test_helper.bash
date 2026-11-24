# shellcheck shell=bash

common_setup() {
    TESTS_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
    SCRIPT="$(cd "$TESTS_DIR/.." && pwd)/pve-zfs-large-block-patch.sh"
    FIXTURES="$TESTS_DIR/fixtures"
    STUBS="$TESTS_DIR/stubs"

    PATCH_TMP="$(mktemp -d)"
    ROOT="$PATCH_TMP/root"
    FILE="$ROOT/usr/share/perl5/PVE/Storage/ZFSPoolPlugin.pm"
    BACKUPS="$ROOT/var/backups/pve-zfs-L-patch"
    mkdir -p "$(dirname "$FILE")" "$PATCH_TMP/bin"

    export PATH="$PATCH_TMP/bin:$TESTS_DIR/bin:$PATH"
    export FAKE_PKG_STATE=installed
    export FAKE_SYSLOG="$PATCH_TMP/syslog"
    export FAKE_DPKG_QUERY_ARGS="$PATCH_TMP/dpkg-query.args"
}

common_teardown() {
    chmod -R u+rwX "$PATCH_TMP"
    rm -rf "$PATCH_TMP"
}

patch_run() {
    run "$SCRIPT" --root "$ROOT" "$@"
}

seed() {
    cp "$FIXTURES/$1" "$FILE"
}

with_stub() {
    ln -s "$STUBS/$1" "$PATCH_TMP/bin/$1"
}

backup_count() {
    find "$BACKUPS" -maxdepth 1 -name 'ZFSPoolPlugin.pm.prepatch.*' 2>/dev/null | wc -l
}

only_backup() {
    find "$BACKUPS" -maxdepth 1 -name 'ZFSPoolPlugin.pm.prepatch.*' 2>/dev/null | head -1
}

wait_for_lock_holder() {
    local _
    for _ in $(seq 100); do
        flock -n "$BACKUPS/.lock" true || return 0
        sleep 0.05
    done
    return 1
}

# A .bats file that needs more setup defines its own setup() that calls
# common_setup first.
setup() { common_setup; }
teardown() { common_teardown; }
