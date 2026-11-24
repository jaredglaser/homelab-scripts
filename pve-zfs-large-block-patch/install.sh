#!/bin/bash
# Installs or removes pve-zfs-large-block-patch and its apt hook.
#
#   curl -fsSL https://raw.githubusercontent.com/jaredglaser/homelab-scripts/main/pve-zfs-large-block-patch/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --uninstall
#
# Piped into bash it downloads the patch script from main. Run as a file with
# pve-zfs-large-block-patch.sh beside it, as in a clone, it installs that copy.
# --root DIR installs under DIR instead of /, for the test suite.

set -u

NAME=pve-zfs-large-block-patch.sh
BASE_URL="https://raw.githubusercontent.com/jaredglaser/homelab-scripts/main/pve-zfs-large-block-patch"
P="[pve-zfs-L-patch install]"
TMP_FILES=()
ARGS=("$@")
trap 'rm -f "${TMP_FILES[@]}"' EXIT

die() {
    echo "$P FAILED - $1" >&2
    exit 1
}

# Next to the target, so the final mv is a rename.
new_tmp() {
    NEW_TMP=$(mktemp ${2:+--suffix="$2"} "$1.XXXXXX") || return 1
    TMP_FILES+=("$NEW_TMP")
}

# Everything runs from main, called alone on the last line, so a download cut
# off anywhere, that line included, runs nothing.
main() {
    local here="" root="" action=install
    # Called from the top level of a file, BASH_SOURCE holds this file twice.
    # Piped, it holds one entry that names no file.
    [ "${#BASH_SOURCE[@]}" -ge 2 ] && here=$(dirname "${BASH_SOURCE[0]}")
    set -- "${ARGS[@]}"
    while [ $# -gt 0 ]; do
        case "$1" in
            --uninstall) action=uninstall; shift ;;
            --root) [ -n "${2:-}" ] || die "--root needs a directory."; root="$2"; shift 2 ;;
            *) die "unknown argument: $1 (the only option is --uninstall)" ;;
        esac
    done

    local script="$root/usr/local/sbin/$NAME"
    local hook="$root/etc/apt/apt.conf.d/99-pve-zfs-large-block-patch"
    local backups="$root/var/backups/pve-zfs-L-patch"

    if [ -z "$root" ] && [ "$(id -u)" != 0 ]; then
        die "must run as root. Use: curl -fsSL $BASE_URL/install.sh | sudo bash"
    fi

    if [ "$action" = uninstall ]; then
        uninstall "$script" "$hook" "$backups"
        exit $?
    fi

    local local_copy="" from
    [ -n "$here" ] && [ -f "$here/$NAME" ] && local_copy="$here/$NAME"
    if [ -z "$local_copy" ]; then
        command -v curl >/dev/null 2>&1 || die "curl not found."
    fi

    mkdir -p "$(dirname "$script")" "$(dirname "$hook")" || die "cannot create $(dirname "$script") or $(dirname "$hook")."
    local tmp="" src
    if [ -n "$local_copy" ]; then
        from="$local_copy"
        src="$local_copy"
    else
        from="$BASE_URL/$NAME"
        new_tmp "$script" || die "cannot write to $(dirname "$script")."
        tmp="$NEW_TMP"
        curl -fsSL -o "$tmp" "$from" || die "could not download $from. Nothing was changed."
        src="$tmp"
    fi
    [ "$(tail -n 1 "$src")" = "# end of $NAME" ] || die "$from is not a complete copy of $NAME. Nothing was changed."
    bash -n "$src" 2>/dev/null || die "$from is not a valid bash script. Nothing was changed."
    if [ -f "$script" ] && cmp -s "$src" "$script"; then
        chmod 755 "$script" || die "cannot make $script executable."
        echo "$P script already up to date: $script" >&2
    else
        local verb=installed
        [ -e "$script" ] && verb=updated
        if [ -z "$tmp" ]; then
            new_tmp "$script" || die "cannot write to $(dirname "$script")."
            tmp="$NEW_TMP"
            cp "$src" "$tmp" || die "cannot write $script."
        fi
        { chmod 755 "$tmp" && mv -f "$tmp" "$script"; } || die "cannot write $script."
        echo "$P script $verb from $from: $script" >&2
    fi

    local want
    want=$(hook_text "$script")
    if [ -f "$hook" ] && [ "$(cat "$hook")" = "$want" ]; then
        echo "$P apt hook already in place: $hook" >&2
    else
        local verb=written
        [ -e "$hook" ] && verb=replaced
        # apt reads every file here on each run but skips names ending in
        # .dpkg-tmp, so a write that fails partway never becomes a hook.
        new_tmp "$hook" .dpkg-tmp || die "cannot write to $(dirname "$hook")."
        { printf '%s\n' "$want" > "$NEW_TMP" && chmod 644 "$NEW_TMP" && mv -f "$NEW_TMP" "$hook"; } \
            || die "cannot write $hook. The script is installed at $script, but the apt hook is not, and the patch was not applied. The previous hook, if any, is unchanged."
        echo "$P apt hook $verb: $hook" >&2
    fi

    echo "$P running $script once now" >&2
    local rc=0
    if [ -n "$root" ]; then
        "$script" --root "$root" || rc=$?
    else
        "$script" || rc=$?
    fi
    [ "$rc" -eq 0 ] || echo "$P the script and the apt hook are installed, but this first run ended with exit $rc. See its message above." >&2
    exit "$rc"
}

hook_text() {
    cat <<EOF
DPkg::Post-Invoke {
    "$1 || { rc=\$?; case \$rc in 126|127) logger -p daemon.err -t pve-zfs-L-patch -- '$1 could not run, so the -L patch was not checked. Run the installer again.' ;; *) [ \$rc -le 128 ] || logger -p daemon.err -t pve-zfs-L-patch -- '$1 was stopped by signal '\$((rc - 128))' and may not have finished.' ;; esac; }; true";
};
EOF
}

uninstall() {
    local script="$1" hook="$2" backups="$3" removed=0
    # Hook first, so no apt run can start a half-removed install.
    if [ -e "$hook" ] || [ -L "$hook" ]; then
        rm -f "$hook" || { echo "$P FAILED - cannot remove $hook." >&2; return 1; }
        echo "$P removed $hook" >&2; removed=1
    fi
    if [ -e "$script" ] || [ -L "$script" ]; then
        rm -f "$script" || { echo "$P FAILED - cannot remove $script." >&2; return 1; }
        echo "$P removed $script" >&2; removed=1
    fi
    [ "$removed" = 1 ] || echo "$P nothing to remove: neither $hook nor $script exists" >&2
    echo "$P ZFSPoolPlugin.pm keeps the -L patch until libpve-storage-perl is next updated. To restore the upstream file now:" >&2
    # shellcheck disable=SC2016 # printed for the operator to run
    echo "$P   apt-get install --reinstall \"libpve-storage-perl=\$(dpkg-query -W -f='\${Version}' libpve-storage-perl)\"" >&2
    echo "$P Backups of the unpatched file are in $backups" >&2
    return 0
}

main
