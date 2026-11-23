#!/bin/bash
# Installs or removes pve-zfs-large-block-patch and its apt hook.
#
#   curl -fsSL https://raw.githubusercontent.com/jaredglaser/homelab-scripts/main/pve-zfs-large-block-patch/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --uninstall
#
# PVE_ZFS_PATCH_BRANCH picks the branch the patch script is fetched from
# (default main), so a branch can be tried before it merges.

set -u

# Everything runs from main, called on the last line, so a download cut off
# halfway through runs nothing.
main() {
    local repo_url="https://raw.githubusercontent.com/jaredglaser/homelab-scripts"
    local branch="${PVE_ZFS_PATCH_BRANCH:-main}"
    local script="/usr/local/sbin/pve-zfs-large-block-patch.sh"
    local hook="/etc/apt/apt.conf.d/99-pve-zfs-large-block-patch"
    local backups="/var/backups/pve-zfs-L-patch"
    local p="[pve-zfs-L-patch install]"

    # Same rule as the patch script: overrides only count in test mode.
    if [ "${PVE_ZFS_PATCH_TESTING:-}" = 1 ]; then
        script="${PVE_ZFS_PATCH_SCRIPT_OVERRIDE:-$script}"
        hook="${PVE_ZFS_PATCH_HOOK_OVERRIDE:-$hook}"
        echo "$p TEST MODE - using $script and $hook" >&2
    fi

    if [ "$(id -u)" != 0 ]; then
        echo "$p FAILED - must run as root. Use: curl -fsSL $repo_url/$branch/pve-zfs-large-block-patch/install.sh | sudo bash" >&2
        exit 1
    fi

    case "${1:-}" in
        "") ;;
        --uninstall) uninstall; exit $? ;;
        *) echo "$p FAILED - unknown argument: $1 (the only option is --uninstall)" >&2; exit 1 ;;
    esac

    command -v curl >/dev/null 2>&1 || { echo "$p FAILED - curl not found." >&2; exit 1; }

    local url="$repo_url/$branch/pve-zfs-large-block-patch/pve-zfs-large-block-patch.sh"
    local tmp
    mkdir -p "$(dirname "$script")" "$(dirname "$hook")" || exit 1
    # Download next to the target so the final mv is a rename.
    tmp=$(mktemp "$script.XXXXXX") || { echo "$p FAILED - cannot write to $(dirname "$script")." >&2; exit 1; }
    trap 'rm -f "$tmp"' EXIT
    if ! curl -fsSL -o "$tmp" "$url"; then
        echo "$p FAILED - could not download $url" >&2
        exit 1
    fi
    if [ "$(head -c 11 "$tmp")" != '#!/bin/bash' ] || ! bash -n "$tmp" 2>/dev/null; then
        echo "$p FAILED - $url is not a complete bash script. Nothing was changed." >&2
        exit 1
    fi
    chmod 755 "$tmp"
    if [ -f "$script" ] && cmp -s "$tmp" "$script"; then
        echo "$p script already up to date: $script" >&2
    else
        local verb=installed
        [ -e "$script" ] && verb=updated
        mv -f "$tmp" "$script" || { echo "$p FAILED - cannot write $script." >&2; exit 1; }
        echo "$p script $verb from $branch: $script" >&2
    fi

    local want
    want=$(hook_text "$script")
    if [ -f "$hook" ] && [ "$(cat "$hook")" = "$want" ]; then
        echo "$p apt hook already in place: $hook" >&2
    else
        local verb=written
        [ -e "$hook" ] && verb=replaced
        printf '%s\n' "$want" > "$hook" || { echo "$p FAILED - cannot write $hook." >&2; exit 1; }
        echo "$p apt hook $verb: $hook" >&2
    fi

    echo "$p running $script once now" >&2
    # stdin is this script when piped from curl, so the child must not read it.
    "$script" < /dev/null
    exit $?
}

hook_text() {
    cat <<EOF
DPkg::Post-Invoke {
    "$1 || [ \$? -lt 126 ] || logger -p daemon.err -t pve-zfs-L-patch -- '$1 could not run, so the -L patch was not checked. Run the installer again.'; true";
};
EOF
}

uninstall() {
    local removed=0
    # Hook first, so no apt run can start a half-removed install.
    if [ -e "$hook" ]; then
        rm -f "$hook" || { echo "$p FAILED - cannot remove $hook." >&2; return 1; }
        echo "$p removed $hook" >&2; removed=1
    fi
    if [ -e "$script" ]; then
        rm -f "$script" || { echo "$p FAILED - cannot remove $script." >&2; return 1; }
        echo "$p removed $script" >&2; removed=1
    fi
    [ "$removed" = 1 ] || echo "$p nothing to remove: neither $hook nor $script exists" >&2
    echo "$p ZFSPoolPlugin.pm keeps the -L patch until libpve-storage-perl is next updated. To restore the upstream file now:" >&2
    # shellcheck disable=SC2016 # printed for the operator to run
    echo "$p   apt-get install --reinstall \"libpve-storage-perl=\$(dpkg-query -W -f='\${Version}' libpve-storage-perl)\"" >&2
    echo "$p Backups of the unpatched file are in $backups" >&2
    return 0
}

main "$@"
