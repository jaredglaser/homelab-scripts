setup() {
    PATCH_SRC="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    SCRIPT="$PATCH_SRC/pve-zfs-large-block-patch.sh"
    FIXTURES="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/fixtures"
    TEST_BIN="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/bin"

    PATCH_TMP="$(mktemp -d)"
    # The script falls back to the real /usr/share/perl5 path when the overrides
    # are empty, which is what an empty PATCH_TMP produces.
    [ -d "$PATCH_TMP" ] || { echo "mktemp -d failed" >&2; return 1; }
    mkdir -p "$PATCH_TMP/root"

    export PVE_ZFS_PATCH_FILE_OVERRIDE="$PATCH_TMP/root/ZFSPoolPlugin.pm"
    export PVE_ZFS_PATCH_BACKUP_DIR_OVERRIDE="$PATCH_TMP/backups"

    export PATH="$TEST_BIN:$PATH"
    export FAKE_PKG_STATE=installed
    export FAKE_PKG_VER=9.1.5
    export FAKE_SYSLOG="$PATCH_TMP/syslog"
    FILE="$PVE_ZFS_PATCH_FILE_OVERRIDE"
    BACKUPS="$PVE_ZFS_PATCH_BACKUP_DIR_OVERRIDE"
}

teardown() {
    # Several tests chmod 000 or 500 to force failure paths, so rm -rf needs help.
    chmod -R u+rwX "$PATCH_TMP" 2>/dev/null || true
    rm -rf "$PATCH_TMP"
    unset PVE_ZFS_PATCH_FILE_OVERRIDE PVE_ZFS_PATCH_BACKUP_DIR_OVERRIDE FAKE_SYSLOG \
          FAKE_PKG_STATE FAKE_PKG_VER FAKE_PKG_RC FAKE_PKG_RAW
}

seed() {
    cp "$FIXTURES/$1" "$FILE"
}

backup_count() {
    find "$BACKUPS" -maxdepth 1 -name 'ZFSPoolPlugin.pm.prepatch.*' 2>/dev/null | wc -l
}

only_backup() {
    find "$BACKUPS" -maxdepth 1 -name 'ZFSPoolPlugin.pm.prepatch.*' 2>/dev/null | head -1
}
