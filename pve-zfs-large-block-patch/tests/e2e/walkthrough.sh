#!/bin/bash
# Runs inside the stand-in node as root, after build-debs.sh. Follows the
# README as an operator would and checks each claim against real apt, dpkg
# and journald. Prints PASS or FAIL per check and exits 1 if any failed.
#
# REV set: install the script with the README's curl command at that commit.
# REV unset: install /root/script-under-test instead (the working tree copy).
# Checks pass single-quoted conditions to eval so they expand at check time.
# shellcheck disable=SC2016
set -u
umask 022

S=/usr/local/sbin/pve-zfs-large-block-patch.sh
H=/etc/apt/apt.conf.d/99-pve-zfs-large-block-patch
F=/usr/share/perl5/PVE/Storage/ZFSPoolPlugin.pm
B=/var/backups/pve-zfs-L-patch
TAG=pve-zfs-L-patch
REPO=/srv/e2e-repo
LOGS=/root/e2e-logs
mkdir -p "$LOGS"

fails=0
step=0
check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "PASS: $desc"
    else
        echo "FAIL: $desc"
        fails=$((fails + 1))
    fi
}
section() { step=$((step + 1)); printf '\n== %02d %s\n' "$step" "$*"; }

# out and rc hold the combined output and exit code of the last run.
out=""; rc=0
run() {
    local log
    log="$LOGS/$(printf %02d "$step")-$(date +%s%N).log"
    out=$("$@" 2>&1); rc=$?
    printf '$ %s\n%s\n[exit %s]\n' "$*" "$out" "$rc" > "$log"
}
has() { [[ "$out" == *"$1"* ]]; }
lacks() { [[ "$out" != *"$1"* ]]; }
rc_is() { [ "$rc" -eq "$1" ]; }

apt_q() { DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Use-Pty=0 "$@"; }
pkg_install() { apt_q install --allow-downgrades "libpve-storage-perl=$1"; }
flags() { grep -o "'zfs', 'send', '[^']*'" "$F" 2>/dev/null | head -1; }
flags_are() { [ "$(flags)" = "'zfs', 'send', '$1'" ]; }
backups() { find "$B" -maxdepth 1 -name 'ZFSPoolPlugin.pm.prepatch.*' 2>/dev/null | wc -l; }
installed_md5() { awk '/ZFSPoolPlugin.pm$/ {print $1}' /var/lib/dpkg/info/libpve-storage-perl.md5sums; }

cursor=""
mark() { journalctl --sync; cursor=$(journalctl -n0 --show-cursor | sed -n 's/^-- cursor: //p'); }
journal() { journalctl --sync; journalctl -t "$TAG" --after-cursor "$cursor" -o cat --no-pager "$@"; }
journal_has() { journal "${@:2}" | grep -qF -- "$1"; }
journal_empty() { [ -z "$(journal)" ]; }

# An unrelated package, so a check can fire the hook without touching ours.
poke() { apt_q install --reinstall e2e-poke; }

hook_verbatim() {
    cat > "$H" <<'EOF'
DPkg::Post-Invoke {
    "/usr/local/sbin/pve-zfs-large-block-patch.sh || true";
};
EOF
}

apt_q update >/dev/null 2>&1
apt_q install pve-manager e2e-poke >/dev/null 2>&1

section "Install per README with libpve-storage-perl 9.1.3"
pkg_install 9.1.3 >/dev/null 2>&1
if [ -n "${REV:-}" ]; then
    echo "installing the script from GitHub at REV=$REV"
    curl -fsSL -o /usr/local/sbin/pve-zfs-large-block-patch.sh \
        "https://raw.githubusercontent.com/jaredglaser/homelab-scripts/${REV}/pve-zfs-large-block-patch/pve-zfs-large-block-patch.sh"
    check "curl at the pinned REV downloaded a bash script" grep -q '^#!/bin/bash' "$S"
else
    echo "installing the working tree copy of the script"
    cp /root/script-under-test "$S"
fi
chmod +x "$S"
hook_verbatim
mark
run "$S"
check "first run says APPLIED and exits 0" eval 'rc_is 0 && has "APPLIED - patched $F to add -L flag"'
check "file now has -RpvUL" flags_are -RpvUL
check "one backup, identical to the packaged file" eval '[ "$(backups)" -eq 1 ] && [ "$(md5sum < "$B"/ZFSPoolPlugin.pm.prepatch.* | cut -d" " -f1)" = "$(installed_md5)" ]'
check "APPLIED is in the journal at notice" journal_has "patched $F to add -L flag" -p notice
mark
run "$S"
check "second run says OK and exits 0" eval 'rc_is 0 && has "OK - patch already present"'
check "OK is not logged" journal_empty
check "README's grep shows -RpvUL" eval "grep -F send $F | grep -F \"'zfs'\" | grep -q RpvUL"

section "Verify: reinstall of the installed version fires the hook"
mark
run apt_q install --reinstall "libpve-storage-perl=$(dpkg-query -W -f='${Version}' libpve-storage-perl)"
check "apt says 1 reinstalled and exits 0" eval 'rc_is 0 && has "1 reinstalled"'
check "hook reuses the backup and says APPLIED" eval 'has "reusing $B/" && has "APPLIED"'
check "APPLIED comes after pve-manager's trigger" eval '[[ "$out" == *"Processing triggers for pve-manager"*"APPLIED"* ]]'
check "still one backup" eval '[ "$(backups)" -eq 1 ]'
check "journal has the re-patch" journal_has "patched $F" -p notice

section "A plain --reinstall upgrades when a newer version exists"
run apt_q install --reinstall libpve-storage-perl
check "apt upgraded 9.1.3 to 9.1.23 instead of reinstalling" eval 'has "1 upgraded" && has "Unpacking libpve-storage-perl (9.1.23) over (9.1.3)"'
check "hook patched the new version" flags_are -RpvUL

section "Upgrades and downgrades between upstream versions"
run pkg_install 9.1.2
check "downgrade to 9.1.2 re-patched to -RpvL" eval 'has "APPLIED" && flags_are -RpvL'
run apt_q upgrade
check "apt-get upgrade to 9.1.23 re-patched to -RpvUL" eval 'has "Unpacking libpve-storage-perl (9.1.23)" && has "APPLIED" && flags_are -RpvUL'
run pkg_install 9.1.3
check "downgrade to 9.1.3 re-patched to -RpvUL" eval 'has "APPLIED" && flags_are -RpvUL'
run pkg_install 9.1.23
check "upgrade to 9.1.23 re-patched to -RpvUL" eval 'has "APPLIED" && flags_are -RpvUL'
run apt_q install libpve-storage-perl
check "install of the installed version runs no dpkg, so no hook output" eval 'has "already the newest version" && lacks "pve-zfs-L-patch"'
run apt_q update
check "apt-get update does not fire the hook" lacks "pve-zfs-L-patch"
run poke
check "an unrelated package fires the hook, which says OK" has "OK - patch already present"

section "dpkg -i bypasses the hook"
run dpkg -i "$REPO/libpve-storage-perl_9.1.3_all.deb"
check "dpkg -i prints nothing from the script" lacks "pve-zfs-L-patch"
check "file is unpatched after dpkg -i" flags_are -RpvU
run poke
check "the next apt run of any package re-patches" eval 'has "APPLIED" && flags_are -RpvUL'

section "WARNING states (synthetic packages)"
mark
run pkg_install 9.1.23+syn.moved
check "file moved: WARNING ... is installed but ... is missing, apt still exits 0" eval 'rc_is 0 && has "WARNING - libpve-storage-perl is installed but $F is missing."'
check "file moved: logged at err" journal_has "libpve-storage-perl is installed but $F is missing." -p err
run "$S"
check "file moved: script exits 1" rc_is 1
mark
run pkg_install 9.1.23+syn.shape
check "new shape: WARNING ... does not contain expected pattern" has "WARNING - $F does not contain expected pattern."
check "new shape: file left untouched" flags_are -RpvUw
check "new shape: logged at err" journal_has "does not contain expected pattern" -p err
mark
run pkg_install 9.1.23+syn.extra
check "extra site: WARNING names the call site without -L" has "still has a zfs send call without -L"
check "extra site: WARNING lists the line" has "my \$probe = ['zfs', 'send', '-nP', \$snap];"
check "extra site: WARNING names the backup" has "The known send call was patched (backup: $B/"
check "extra site: known call was patched" flags_are -RpvUL
check "extra site: logged at err" journal_has "still has a zfs send call without -L" -p err
run "$S"
check "extra site: warning repeats on the already-patched path" eval 'rc_is 1 && has "still has a zfs send call without -L"'
dpkg --unpack "$REPO/libpve-storage-perl_9.1.23+syn.moved_all.deb" >/dev/null 2>&1
run "$S"
check "unpacked state with the file missing warns with that state" has "libpve-storage-perl is unpacked but $F is missing."
dpkg --configure -a >/dev/null 2>&1
pkg_install 9.1.23 >/dev/null 2>&1

section "Hook without || true"
sed -i 's/ || true//' "$H"
run pkg_install 9.1.23+syn.shape
check "apt exits 100 with 'Problem executing scripts'" eval 'rc_is 100 && has "E: Problem executing scripts DPkg::Post-Invoke"'
check "the package was installed anyway" eval '[ "$(dpkg-query -W -f="\${Version} \${db:Status-Status}" libpve-storage-perl)" = "9.1.23+syn.shape installed" ]'
hook_verbatim
pkg_install 9.1.23 >/dev/null 2>&1

section "Script missing, not executable, on a noexec mount"
mark
chmod -x "$S"; run poke; chmod +x "$S"
check "no execute bit: shell error in apt output, apt exits 0" eval 'rc_is 0 && has "$S: Permission denied"'
mv "$S" /root/s.sh; run poke; mv /root/s.sh "$S"
check "missing: shell error in apt output, apt exits 0" eval 'rc_is 0 && has "$S: not found"'
mount -t tmpfs -o noexec tmpfs /mnt && cp -a "$S" /mnt/ && mount --bind /mnt/pve-zfs-large-block-patch.sh "$S"
run poke
umount "$S"; umount /mnt
check "noexec: shell error in apt output, apt exits 0" eval 'rc_is 0 && has "$S: Permission denied"'
check "none of the three reached the journal" journal_empty

section "Immutable file"
dpkg -i "$REPO/libpve-storage-perl_9.1.23_all.deb" >/dev/null 2>&1
chattr +i "$F"
mark
run poke
# shellcheck disable=SC2034 # read in a check's eval
n=$(backups)
check "FAILED names sed's error, exits via the hook with apt 0" eval 'rc_is 0 && has "FAILED - sed could not patch $F: sed: cannot rename" && has "Operation not permitted"'
check "says the file is unchanged and points at lsattr" has "lsattr"
check "the cause is in the journal" journal_has "Operation not permitted" -p err
run poke
check "a second failing run adds no backup" eval '[ "$(backups)" -eq "$n" ] && has "reusing $B/"'
check "no sed temp file left behind" eval '[ "$(find "$(dirname "$F")" -name "sed*" | wc -l)" -eq 0 ]'
run apt_q install --reinstall libpve-storage-perl
check "dpkg itself cannot replace an immutable file (apt exits 100)" eval 'rc_is 100 && has "Operation not permitted"'
chattr -i "$F"

section "Read-only /usr/share/perl5"
mount --bind /usr/share/perl5 /usr/share/perl5 && mount -o remount,ro,bind /usr/share/perl5
mark
run "$S"
umount /usr/share/perl5
check "FAILED names Read-only file system" eval 'rc_is 1 && has "FAILED - sed could not patch" && has "Read-only file system"'
check "logged with the cause" journal_has "Read-only file system" -p err

section "Full backup directory"
mv "$B" /root/backups.saved; mkdir "$B"
mount -t tmpfs -o size=64k tmpfs "$B"
dd if=/dev/zero of="$B/fill" bs=4k >/dev/null 2>&1
mark
run "$S"
check "FAILED names No space left on device" eval 'rc_is 1 && has "FAILED - backup to" && has "No space left on device"'
check "no partial backup left" eval '[ "$(backups)" -eq 0 ]'
check "file left unpatched" flags_are -RpvU
check "logged with the cause" journal_has "No space left on device" -p err
umount "$B"; rmdir "$B"; mv /root/backups.saved "$B"

section "Full /tmp"
mount -t tmpfs -o size=8k,nr_inodes=3 tmpfs /tmp
touch /tmp/a /tmp/b /tmp/c 2>/dev/null
run "$S"
umount /tmp
check "patch still applies" eval 'rc_is 0 && has "APPLIED" && flags_are -RpvUL'

section "Read error on the file (FUSE file that returns EIO)"
dpkg -i "$REPO/libpve-storage-perl_9.1.23_all.deb" >/dev/null 2>&1
mkdir -p /eio
python3 /root/eio-fs.py "$F" /eio >/root/eio.log 2>&1 &
fuse_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e /eio/ZFSPoolPlugin.pm ] && break; sleep 0.5; done
mount --bind /eio/ZFSPoolPlugin.pm "$F"
run "$S"
umount "$F"; umount /eio; wait "$fuse_pid" 2>/dev/null
check "FAILED - cannot read ... (grep exit 2)" eval 'rc_is 1 && has "FAILED - cannot read $F (grep exit 2)"'
check "file untouched afterwards" flags_are -RpvU

section "Other FAILED states"
mv /usr/bin/dpkg-query /root/; run "$S"; mv /root/dpkg-query /usr/bin/
check "dpkg-query missing" eval 'rc_is 1 && has "FAILED - required command not found: dpkg-query"'
mv "$F" /root/real.pm; ln -s /nonexistent "$F"; run "$S"; rm "$F"
check "broken symlink" eval 'rc_is 1 && has "is a broken symlink"'
mkdir "$F"; run "$S"; rmdir "$F"; mv /root/real.pm "$F"
check "directory in place of the file" eval 'rc_is 1 && has "is a directory, not a regular file"'
chmod 000 /var/lib/dpkg/status
run setpriv --reuid=65534 --regid=65534 --clear-groups "$S"
chmod 644 /var/lib/dpkg/status
check "unreadable dpkg database shows dpkg-query's error" eval 'rc_is 1 && has "cannot determine libpve-storage-perl status (dpkg-query exit 2)"'

section "Removing the package"
"$S" >/dev/null 2>&1
mark
run apt_q remove libpve-storage-perl
check "remove: NOT INSTALLED names the script and hook, apt exits 0" eval 'rc_is 0 && has "NOT INSTALLED" && has "  $S" && has "  $H"'
check "remove leaves config-files state" eval '[ "$(dpkg-query -W -f="\${db:Status-Status}" libpve-storage-perl)" = config-files ]'
run poke
check "every later apt run prints NOT INSTALLED" has "NOT INSTALLED"
run apt_q purge libpve-storage-perl
check "purge: NOT INSTALLED" has "NOT INSTALLED"
run "$S"
check "no dpkg record: exits 0" eval 'rc_is 0 && has "NOT INSTALLED"'
check "NOT INSTALLED is never logged" journal_empty

section "Recovery per README"
pkg_install 9.1.3 >/dev/null 2>&1
check "patched before recovery" flags_are -RpvUL
rm "$H"
run apt_q install --reinstall "libpve-storage-perl=$(dpkg-query -W -f='${Version}' libpve-storage-perl)"
check "pinned reinstall stays on 9.1.3 and leaves upstream flags" eval 'has "1 reinstalled" && flags_are -RpvU'
run poke
check "with the hook gone, apt runs leave the file alone" eval 'lacks "pve-zfs-L-patch" && flags_are -RpvU'
run dpkg --verify libpve-storage-perl
check "dpkg --verify is clean" eval 'rc_is 0 && [ -z "$out" ]'
hook_verbatim; poke >/dev/null 2>&1; rm "$H"
run dpkg --verify libpve-storage-perl
check "while patched, dpkg --verify flags the checksum" has "??5??????"
match=""
for b in "$B"/ZFSPoolPlugin.pm.prepatch.*; do
    [ "$(md5sum < "$b" | cut -d' ' -f1)" = "$(installed_md5)" ] && match="$b"
done
check "a backup matches the installed version by md5sums" test -n "$match"
cp "$match" /usr/share/perl5/PVE/Storage/ZFSPoolPlugin.pm
run dpkg --verify libpve-storage-perl
check "restored backup: dpkg --verify is clean" eval 'rc_is 0 && [ -z "$out" ]'
hook_verbatim
sed -i 's/^/# /' "$H"
run poke
check "commenting out the hook with # disables it" eval 'lacks "pve-zfs-L-patch" && flags_are -RpvU'

section "Uninstall per README"
rm "$H" "$S"
run poke
check "after uninstall apt prints nothing from the hook" lacks "pve-zfs-L-patch"
check "backups are still there until removed by hand" eval '[ "$(backups)" -gt 0 ]'

printf '\n%s failed\n' "$fails"
[ "$fails" -eq 0 ]
