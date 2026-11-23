# shellcheck shell=bash

common_setup() {
    TESTS_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
    # shellcheck disable=SC2034 # read by patch.bats
    SCRIPT="$(cd "$TESTS_DIR/.." && pwd)/pve-zfs-large-block-patch.sh"
    FIXTURES="$TESTS_DIR/fixtures"
    STUBS="$TESTS_DIR/stubs"

    PATCH_TMP="$(mktemp -d)"
    # The script falls back to the real /usr/share/perl5 path when the overrides
    # are empty, which is what an empty PATCH_TMP produces.
    [ -d "$PATCH_TMP" ] || { echo "mktemp -d failed" >&2; return 1; }
    mkdir -p "$PATCH_TMP/root" "$PATCH_TMP/bin"

    export PVE_ZFS_PATCH_TESTING=1
    export PVE_ZFS_PATCH_FILE_OVERRIDE="$PATCH_TMP/root/ZFSPoolPlugin.pm"
    export PVE_ZFS_PATCH_BACKUP_DIR_OVERRIDE="$PATCH_TMP/backups"

    # Stubs that fail on purpose live in $PATCH_TMP/bin, linked in per test by
    # with_stub, so they shadow the real tools for that test only.
    REAL_GREP="$(command -v grep)"
    export REAL_GREP
    export PATH="$PATCH_TMP/bin:$TESTS_DIR/bin:$PATH"
    export FAKE_PKG_STATE=installed
    export FAKE_SYSLOG="$PATCH_TMP/syslog"
    export FAKE_DPKG_QUERY_ARGS="$PATCH_TMP/dpkg-query.args"
    FILE="$PVE_ZFS_PATCH_FILE_OVERRIDE"
    BACKUPS="$PVE_ZFS_PATCH_BACKUP_DIR_OVERRIDE"
}

common_teardown() {
    rm -rf "$PATCH_TMP"
    unset PVE_ZFS_PATCH_TESTING PVE_ZFS_PATCH_FILE_OVERRIDE PVE_ZFS_PATCH_BACKUP_DIR_OVERRIDE \
          FAKE_SYSLOG FAKE_DPKG_QUERY_ARGS FAKE_PKG_STATE FAKE_PKG_RC FAKE_PKG_RAW FAKE_PKG_STDERR \
          FAKE_CP_MODE FAKE_SED_MODE FAKE_GREP_FAIL_MATCH REAL_GREP \
          PVE_ZFS_PATCH_SCRIPT_OVERRIDE PVE_ZFS_PATCH_HOOK_OVERRIDE PVE_ZFS_PATCH_BRANCH \
          FAKE_CURL_SRC FAKE_CURL_ARGS FAKE_UID
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

# A .bats file that needs more setup defines its own setup() that calls
# common_setup first.
setup() { common_setup; }
teardown() { common_teardown; }
