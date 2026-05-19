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
# Runs automatically after every dpkg/apt operation via
# /etc/apt/apt.conf.d/99-pve-zfs-large-block-patch

set -u

FILE="/usr/share/perl5/PVE/Storage/ZFSPoolPlugin.pm"
BACKUP_DIR="/var/backups/pve-zfs-L-patch"

# libpve-storage-perl 9.1.5+ added -U (--skip-missing) to the send flags.
pkg_ver=$(dpkg-query -W -f='${Version}' libpve-storage-perl 2>/dev/null || true)
if dpkg --compare-versions "$pkg_ver" ge "9.1.5" 2>/dev/null; then
    ORIGINAL_PATTERN="my \$cmd = ['zfs', 'send', '-RpvU'"
    TARGET_PATTERN="my \$cmd = ['zfs', 'send', '-RpvUL'"
    SED_EXPR="s/my \$cmd = \['zfs', 'send', '-RpvU'\]/my \$cmd = ['zfs', 'send', '-RpvUL']/"
else
    ORIGINAL_PATTERN="my \$cmd = ['zfs', 'send', '-Rpv'"
    TARGET_PATTERN="my \$cmd = ['zfs', 'send', '-RpvL'"
    SED_EXPR="s/my \$cmd = \['zfs', 'send', '-Rpv'\]/my \$cmd = ['zfs', 'send', '-RpvL']/"
fi

# Color codes (only if stdout is a terminal)
if [ -t 1 ]; then
    RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
else
    RED=''; GREEN=''; YELLOW=''; BOLD=''; RESET=''
fi

prefix="${BOLD}[pve-zfs-L-patch]${RESET}"

if [ ! -f "$FILE" ]; then
    # File doesn't exist — package not installed or path changed. Stay quiet.
    exit 0
fi

if grep -qF "$TARGET_PATTERN" "$FILE"; then
    echo "${prefix} ${GREEN}OK${RESET} - patch already present in $FILE (no changes needed)"
    exit 0
fi

if grep -qF "$ORIGINAL_PATTERN" "$FILE"; then
    mkdir -p "$BACKUP_DIR"
    backup="${BACKUP_DIR}/ZFSPoolPlugin.pm.prepatch.$(date +%Y%m%d-%H%M%S)"
    cp -a "$FILE" "$backup"

    if sed -i "$SED_EXPR" "$FILE"; then
        if grep -qF "$TARGET_PATTERN" "$FILE"; then
            echo "${prefix} ${YELLOW}APPLIED${RESET} - patched $FILE to add -L flag (backup: $backup)"
            exit 0
        else
            echo "${prefix} ${RED}FAILED${RESET} - sed reported success but pattern not found after! Check $FILE manually." >&2
            exit 1
        fi
    else
        echo "${prefix} ${RED}FAILED${RESET} - sed returned error while patching $FILE" >&2
        exit 1
    fi
fi

# Neither original nor patched pattern found — upstream has changed structure
echo "${prefix} ${RED}WARNING${RESET} - $FILE does not contain expected pattern." >&2
echo "${prefix} ${RED}WARNING${RESET} - Upstream code may have changed. Manual review required." >&2
echo "${prefix} ${RED}WARNING${RESET} - Searched for: $ORIGINAL_PATTERN" >&2
echo "${prefix} ${RED}WARNING${RESET} - Replication for >128K recordsize datasets may be broken." >&2
exit 1