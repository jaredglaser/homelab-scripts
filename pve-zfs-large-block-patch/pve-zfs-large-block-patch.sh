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
# Runs after every apt-driven dpkg run via the apt hook in
# /etc/apt/apt.conf.d/99-pve-zfs-large-block-patch. A direct dpkg -i does not
# run the hook.
#
# The hook discards the exit code, so failures go to syslog (daemon.err) under
# the tag pve-zfs-L-patch, and each re-patch goes there at daemon.notice.
#
# --root DIR works on the same paths under DIR instead of /. The test suite
# uses it. The hook passes no arguments.

set -u

PKG="libpve-storage-perl"
TAG="pve-zfs-L-patch"
SELF="$0"

if [ -t 2 ]; then
    RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
else
    RED=''; GREEN=''; YELLOW=''; BOLD=''; RESET=''
fi

prefix="${BOLD}[${TAG}]${RESET}"

# Only the first message line reaches syslog.
report_and_exit() {
    local label="$1" line
    shift
    for line in "$@"; do
        echo "${prefix} ${RED}${label}${RESET} - $line" >&2
    done
    logger -p daemon.err -t "$TAG" -- "$1" 2>/dev/null || true
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

read_fail() {
    fail "cannot read $FILE (grep exit $1). Check permissions and disk health."
}

# The send statement with flags $1, alone on its line apart from a trailing
# comment, so a copy inside a comment never counts. Group 1 ends before the
# closing quote, group 2 is the rest of the line.
call_re() {
    echo "^([[:space:]]*my [\$]cmd = [[]'zfs', 'send', '$1)'[]];([[:space:]]*(#.*)?)\$"
}

has_call() {
    local rc
    grep -qE -- "$(call_re "$1")" "$FILE"; rc=$?
    [ "$rc" -le 1 ] || read_fail "$rc"
    [ "$rc" -eq 0 ]
}

SEND_RE="[\"']zfs[\"'][[:space:]]*,[[:space:]]*[\"']send[\"']"

# Warns when the file has more send calls in list form, outside whole-line
# comments, than the known patched statements. It cannot see a command built
# some other way, such as qw(zfs send) or a string.
check_send_count() {
    local lines rc entry text total=0 known=0 others="" known_re
    known_re="($(call_re -RpvUL))|($(call_re -RpvL))"
    lines=$(grep -nE -- "$SEND_RE" "$FILE"); rc=$?
    [ "$rc" -le 1 ] || read_fail "$rc"
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        text="${entry#*:}"
        [[ $text =~ ^[[:space:]]*# ]] && continue
        total=$((total + 1))
        if [[ $text =~ $known_re ]]; then
            known=$((known + 1))
        else
            others="${others:+$others, }${entry%%:*}"
        fi
    done <<< "$lines"
    [ "$total" -gt "$known" ] || return 0
    warn "$FILE has $total zfs send calls, the script knows $known. Others on line $others." \
         "$@" \
         "Upstream code may have changed. Manual review required." \
         "Replication for >128K recordsize datasets may be broken."
}

ROOT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --root)
            [ -n "${2:-}" ] || fail "--root needs a directory."
            ROOT="$2"; shift 2 ;;
        *) fail "unknown argument: $1" "Run it with no arguments." ;;
    esac
done

FILE="$ROOT/usr/share/perl5/PVE/Storage/ZFSPoolPlugin.pm"
BACKUP_DIR="$ROOT/var/backups/pve-zfs-L-patch"
HOOK_FILE="$ROOT/etc/apt/apt.conf.d/99-pve-zfs-large-block-patch"

require grep sed cp cmp mv mkdir rm stat date flock logger dpkg-query

# dpkg prints warnings about unrelated packages on stderr with exit 0, and
# those must not be read as this package's state.
pkg_state=$(dpkg-query -W -f='${db:Status-Status}\n' "$PKG" 2>/dev/null); pkg_rc=$?

case "$pkg_rc" in
    0|1) ;;
    *) pkg_err=$(dpkg-query -W -f='${db:Status-Status}\n' "$PKG" 2>&1 >/dev/null)
       fail "cannot determine $PKG status (dpkg-query exit $pkg_rc): ${pkg_err:-no error text}" \
            "Refusing to guess at an unknown package state." ;;
esac

# dpkg-query exits 1 with empty stdout for a package it has no record of.
if [ "$pkg_rc" -eq 1 ] && [ -z "$pkg_state" ]; then
    pkg_present=0
else
    case "$pkg_rc:$pkg_state" in
        0:not-installed|0:config-files) pkg_present=0 ;;
        0:installed|0:half-installed|0:unpacked|0:half-configured|0:triggers-awaited|0:triggers-pending)
            pkg_present=1 ;;
        *) fail "dpkg-query returned an unrecognised status for $PKG: '$pkg_state' (exit $pkg_rc)" \
                "Refusing to guess at an unknown package state." ;;
    esac
fi

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

mkdir_err=$(mkdir -p "$BACKUP_DIR" 2>&1) || fail "cannot create $BACKUP_DIR: ${mkdir_err:-no error text}" \
                                                 "It holds the backups and the lock. Nothing was changed."

# The apt hook and a manual run can overlap, and the second would back up the
# file the first has just patched.
LOCK="$BACKUP_DIR/.lock"
LOCK_WAIT=10
{ exec 9>"$LOCK"; } 2>/dev/null || fail "cannot open $LOCK." "Nothing was changed."
flock -w "$LOCK_WAIT" 9 || fail "another run has held $LOCK for ${LOCK_WAIT}s." \
                              "Nothing was changed. Run the script again once the other run has finished."

# The two reviewed upstream shapes. libpve-storage-perl 9.1.3 added -U
# (--no-preserve-encryption).
sed_args=()
for flags in -RpvU -Rpv; do
    has_call "$flags" && sed_args+=(-e "s/$(call_re "$flags")/\\1L'];\\2/")
done

if [ "${#sed_args[@]}" -eq 0 ]; then
    if has_call -RpvUL || has_call -RpvL; then
        check_send_count
        echo "${prefix} ${GREEN}OK${RESET} - patch already present in $FILE (no changes needed)" >&2
        exit 0
    fi
    warn "$FILE does not contain expected pattern." \
         "Upstream code may have changed. Manual review required." \
         "Searched for a line holding only: my \$cmd = ['zfs', 'send', '-RpvU'];" \
         "Searched for a line holding only: my \$cmd = ['zfs', 'send', '-Rpv'];" \
         "Replication for >128K recordsize datasets may be broken."
fi

# A write that keeps failing (immutable file, read-only /usr) would otherwise
# add an identical copy on every apt run. The names sort by timestamp.
newest=""
for candidate in "$BACKUP_DIR"/ZFSPoolPlugin.pm.prepatch.*; do
    [ -f "$candidate" ] && newest="$candidate"
done

if [ -n "$newest" ] && cmp -s "$FILE" "$newest"; then
    backup="$newest"
    echo "${prefix} reusing $backup, which already holds this exact content" >&2
else
    backup="${BACKUP_DIR}/ZFSPoolPlugin.pm.prepatch.$(date +%Y%m%d-%H%M%S).$$"
    # Under the final name only once complete, so a run killed mid-copy never
    # leaves a truncated file that looks like a backup.
    partial="$BACKUP_DIR/.partial"
    # -L because the target can be a symlink, -a to keep mode and mtime.
    if ! cp_err=$(cp -aL "$FILE" "$partial" 2>&1); then
        rm -f "$partial"
        fail "backup to $backup failed: ${cp_err:-no error text}" \
             "Refusing to patch $FILE without a backup. Free space in $BACKUP_DIR or make it writable, then re-run."
    fi
    if ! cmp -s "$FILE" "$partial"; then
        rm -f "$partial"
        fail "backup $backup does not match $FILE after copying." \
             "Refusing to patch $FILE without a backup."
    fi
    mv_err=$(mv "$partial" "$backup" 2>&1) || fail "backup to $backup failed: ${mv_err:-no error text}" \
                                                   "Refusing to patch $FILE without a backup."
fi

# --follow-symlinks, or sed -i replaces a symlinked target with a regular file.
if ! sed_err=$(sed -i -E --follow-symlinks "${sed_args[@]}" "$FILE" 2>&1); then
    fail "sed could not patch $FILE: ${sed_err:-no error text}" \
         "$FILE is unchanged. Check that it is not immutable (lsattr) and that its filesystem is writable."
fi

if has_call -RpvU || has_call -Rpv; then
    fail "$FILE is not correctly patched after sed." \
         "Restore $backup and review manually."
fi

check_send_count "The known send call was patched (backup: $backup)."

echo "${prefix} ${YELLOW}APPLIED${RESET} - patched $FILE to add -L flag (backup: $backup)" >&2
logger -p daemon.notice -t "$TAG" -- "patched $FILE to add -L flag (backup: $backup)" 2>/dev/null || true
exit 0
# install.sh rejects a download whose last line is not this one.
# end of pve-zfs-large-block-patch.sh
