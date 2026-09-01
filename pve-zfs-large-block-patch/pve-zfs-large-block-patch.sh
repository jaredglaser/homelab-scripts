#!/bin/bash
# Maintains the -L (--large-block) flag in PVE's ZFS send command.
# Required for replication of datasets with recordsize > 128K.
#
# Without this patch, replication splits records into 128K chunks on the wire,
# which causes:
#   - Bloated/fragmented copies on the receive side
#   - Hard failures with "incremental send stream requires -L (--large-block),
#     to match previous receive" when migrating back to the source
#
# Runs after every dpkg invocation via the apt hook in
# /etc/apt/apt.conf.d/99-pve-zfs-large-block-patch
#
# The hook discards the exit code, so failures also go to syslog under the tag
# pve-zfs-L-patch. The _OVERRIDE variables exist for the test suite.

set -u

FILE="${PVE_ZFS_PATCH_FILE_OVERRIDE:-/usr/share/perl5/PVE/Storage/ZFSPoolPlugin.pm}"
BACKUP_DIR="${PVE_ZFS_PATCH_BACKUP_DIR_OVERRIDE:-/var/backups/pve-zfs-L-patch}"
HOOK_FILE="/etc/apt/apt.conf.d/99-pve-zfs-large-block-patch"
PKG="libpve-storage-perl"
SELF="$0"

if [ -t 2 ]; then
    RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
else
    RED=''; GREEN=''; YELLOW=''; BOLD=''; RESET=''
fi

prefix="${BOLD}[pve-zfs-L-patch]${RESET}"

# Only the first message line reaches syslog.
report_and_exit() {
    local label="$1" line
    shift
    for line in "$@"; do
        echo "${prefix} ${RED}${label}${RESET} - $line" >&2
    done
    logger -p daemon.err -t pve-zfs-L-patch -- "$1" 2>/dev/null || true
    exit 1
}

fail() { report_and_exit FAILED "$@"; }
warn() { report_and_exit WARNING "$@"; }

require() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || fail "required command not found: $cmd"
    done
}

# grep exits 2 on a read error, 1 on no match.
has_pattern() {
    local rc
    grep -F -- "$1" "$FILE" >/dev/null; rc=$?
    [ "$rc" -le 1 ] && return "$rc"
    fail "cannot read $FILE (grep exit $rc). Check permissions and disk health."
}

require grep sed cp mkdir date dpkg-query dpkg

pkg_state=""
pkg_ver=""
pkg_info=$(dpkg-query -W -f='${db:Status-Status}|${Version}' "$PKG" 2>&1); pkg_rc=$?
case "$pkg_rc" in
    0)
        case "$pkg_info" in
            *"|"*) pkg_state="${pkg_info%%|*}"; pkg_ver="${pkg_info##*|}" ;;
            # Debian versions never contain a pipe.
            *) fail "dpkg-query returned unparsable output for $PKG: $pkg_info" ;;
        esac
        ;;
    # dpkg-query exits 1 for a package it has no record of.
    1) ;;
    *) fail "cannot determine $PKG status: $pkg_info" \
            "Refusing to guess at an unknown package state." ;;
esac

# half-installed, unpacked and triggers-pending are present states too.
case "$pkg_state" in
    ""|not-installed|config-files) pkg_present=0 ;;
    *)                             pkg_present=1 ;;
esac

if [ -L "$FILE" ] && [ ! -e "$FILE" ]; then
    fail "$FILE is a broken symlink." \
         "Point it at the real ZFSPoolPlugin.pm or remove it, then re-run."
fi

if [ ! -e "$FILE" ]; then
    if [ "$pkg_present" -eq 1 ]; then
        warn "$PKG is $pkg_state but $FILE is missing." \
             "Upstream may have moved the file. Manual review required." \
             "Replication for >128K recordsize datasets may be broken."
    fi

    echo "${prefix} ${YELLOW}NOT INSTALLED${RESET} - $PKG is absent and $FILE does not exist. Nothing to patch." >&2
    echo "${prefix} ${YELLOW}NOT INSTALLED${RESET} - This node does not need the patch. To stop this message, remove:" >&2
    echo "${prefix} ${YELLOW}NOT INSTALLED${RESET} -   $SELF" >&2
    echo "${prefix} ${YELLOW}NOT INSTALLED${RESET} -   $HOOK_FILE" >&2
    exit 0
fi

if [ ! -f "$FILE" ]; then
    fail "$FILE is a $(stat -Lc %F "$FILE"), not a regular file."
fi

# libpve-storage-perl 9.1.3 added -U (--no-preserve-encryption) to the send flags.
if dpkg --compare-versions "$pkg_ver" ge "9.1.3"; then
    ORIGINAL_PATTERN="my \$cmd = ['zfs', 'send', '-RpvU']"
    TARGET_PATTERN="my \$cmd = ['zfs', 'send', '-RpvUL']"
    SED_EXPR="s/my \$cmd = \['zfs', 'send', '-RpvU'\]/my \$cmd = ['zfs', 'send', '-RpvUL']/g"
else
    ORIGINAL_PATTERN="my \$cmd = ['zfs', 'send', '-Rpv']"
    TARGET_PATTERN="my \$cmd = ['zfs', 'send', '-RpvL']"
    SED_EXPR="s/my \$cmd = \['zfs', 'send', '-Rpv'\]/my \$cmd = ['zfs', 'send', '-RpvL']/g"
fi

if ! has_pattern "$ORIGINAL_PATTERN"; then
    if has_pattern "$TARGET_PATTERN"; then
        echo "${prefix} ${GREEN}OK${RESET} - patch already present in $FILE (no changes needed)" >&2
        exit 0
    fi
    warn "$FILE does not contain expected pattern." \
         "Upstream code may have changed. Manual review required." \
         "Searched for: $ORIGINAL_PATTERN" \
         "Replication for >128K recordsize datasets may be broken."
fi

# Snapshot the file before touching it, because rollback depends on these backups.
# cp needs -L: -a implies --no-dereference, and the target can be a symlink.
mkdir -p "$BACKUP_DIR" || fail "cannot create $BACKUP_DIR." \
                               "Refusing to patch $FILE without a backup."
backup="${BACKUP_DIR}/ZFSPoolPlugin.pm.prepatch.$(date +%Y%m%d-%H%M%S).$$"
if ! cp -aL "$FILE" "$backup"; then
    rm -f "$backup"
    fail "backup to $backup failed (full or read-only /var?)." \
         "Refusing to patch $FILE without a backup."
fi

# Apply the patch. sed -i replaces the path it is given. --follow-symlinks
# resolves the symlink first.
if ! sed -i --follow-symlinks "$SED_EXPR" "$FILE"; then
    fail "sed returned an error while patching $FILE." \
         "Restore $backup and review manually."
fi

if has_pattern "$ORIGINAL_PATTERN" || ! has_pattern "$TARGET_PATTERN"; then
    fail "$FILE is not correctly patched after sed." \
         "Restore $backup and review manually."
fi

echo "${prefix} ${YELLOW}APPLIED${RESET} - patched $FILE to add -L flag (backup: $backup)" >&2
exit 0
