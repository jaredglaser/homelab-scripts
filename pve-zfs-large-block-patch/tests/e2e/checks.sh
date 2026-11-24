#!/bin/bash
# Runs as root inside the debian:trixie container that run.sh starts, with
# pve-zfs-large-block-patch/ mounted read-only at /src. Installs
# libpve-storage-perl from the Proxmox pve-no-subscription repository, then
# checks the installer, the script and the hook against real apt and dpkg.
# Prints one PASS or FAIL line per check and exits 1 if any failed.
#
# MODE=local runs /src/install.sh, which installs /src's script. MODE=one-liner
# runs the README's one-liner, which installs what is on main.
#
# Checks pass single-quoted conditions to eval so they expand at check time.
# shellcheck disable=SC2016,SC2034
set -u
umask 022
export DEBIAN_FRONTEND=noninteractive

MODE="${MODE:-local}"
OLD=9.0.6
# The script and hook as the README's manual steps installed them before
# install.sh existed.
OLD_SCRIPT_URL=https://raw.githubusercontent.com/jaredglaser/homelab-scripts/ba1fdf9fa33f564f07f17084e98fe624aba7b656/pve-zfs-large-block-patch/pve-zfs-large-block-patch.sh
KEYRING_URL=https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg
KEYRING_SHA256=136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45
KEYRING=/usr/share/keyrings/proxmox-archive-keyring.gpg

S=/usr/local/sbin/pve-zfs-large-block-patch.sh
H=/etc/apt/apt.conf.d/99-pve-zfs-large-block-patch
F=/usr/share/perl5/PVE/Storage/ZFSPoolPlugin.pm
B=/var/backups/pve-zfs-L-patch
SYSLOG=/var/log/messages

setup_step() {
    local desc="$1" log
    shift
    echo "setup: $desc" >&2
    if ! log=$("$@" 2>&1); then
        printf '%s\n' "$log" >&2
        echo "FAIL: setup: $desc"
        exit 1
    fi
}

apt_q() { apt-get -y -q -o Dpkg::Use-Pty=0 "$@"; }

use_proxy() {
    printf 'Acquire::https::Proxy "%s";\n' "$https_proxy" > /etc/apt/apt.conf.d/90e2e-proxy
    [ -f /ca.crt ] && printf 'Acquire::https::CaInfo "/ca.crt";\n' >> /etc/apt/apt.conf.d/90e2e-proxy
    # apt gets the proxy for https only, so the Debian sources move to https.
    sed -i 's#http://deb.debian.org#https://deb.debian.org#g' /etc/apt/sources.list.d/debian.sources
}

trust_ca() {
    cp /ca.crt /usr/local/share/ca-certificates/e2e-proxy.crt && update-ca-certificates
}

add_pve_repo() {
    curl -fsSL -o "$KEYRING" "$KEYRING_URL" || return 1
    echo "$KEYRING_SHA256  $KEYRING" | sha256sum -c || return 1
    printf 'Types: deb\nURIs: https://download.proxmox.com/debian/pve\nSuites: trixie\nComponents: pve-no-subscription\nSigned-By: %s\n' \
        "$KEYRING" > /etc/apt/sources.list.d/pve.sources
}

start_syslog() {
    busybox syslogd -O "$SYSLOG" && for _ in $(seq 50); do [ -S /dev/log ] && return 0; sleep 0.1; done
    return 1
}

# The debian image deletes downloaded packages, and the checks reinstall them.
rm -f /etc/apt/apt.conf.d/docker-clean
if [ -n "${https_proxy:-}" ]; then setup_step "send apt through https_proxy" use_proxy; fi
setup_step "apt-get update" apt_q update
setup_step "install curl, ca-certificates and busybox" apt_q install --no-install-recommends curl ca-certificates busybox
if [ -f /ca.crt ]; then setup_step "trust SSL_CERT_FILE" trust_ca; fi
setup_step "add the pve-no-subscription repository" add_pve_repo
setup_step "apt-get update with the Proxmox repository" apt_q update
setup_step "install libpve-storage-perl=$OLD" apt_q install --no-install-recommends "libpve-storage-perl=$OLD"
setup_step "start syslogd" start_syslog
setup_step "download the old script" curl -fsSL -o /root/old-script.sh "$OLD_SCRIPT_URL"

INSTALL_LINE=$(grep -m1 -E '^curl -fsSL https://raw\.githubusercontent\.com/[^ ]+/install\.sh \| bash$' /src/README.md)
UNINSTALL_LINE=$(grep -m1 -E '^curl -fsSL https://raw\.githubusercontent\.com/[^ ]+/install\.sh \| bash -s -- --uninstall$' /src/README.md)
case "$MODE" in
    local) FROM=/src/pve-zfs-large-block-patch.sh ;;
    one-liner) FROM=https://raw.githubusercontent.com/jaredglaser/homelab-scripts/main/pve-zfs-large-block-patch/pve-zfs-large-block-patch.sh ;;
    *) echo "FAIL: setup: unknown MODE $MODE"; exit 1 ;;
esac

fails=0
check() {
    if eval "$2" >/dev/null 2>&1; then
        echo "PASS: $1"
    else
        echo "FAIL: $1"
        fails=$((fails + 1))
        printf '  last command: %s\n' "$last" >&2
        printf '%s\n' "$out" | sed 's/^/  | /' >&2
    fi
}

# out, rc and last hold the combined output, exit code and text of the last run.
out=""; rc=0; last=""
run() { last="$*"; out=$("$@" 2>&1); rc=$?; }
has() { [[ "$out" == *"$1"* ]]; }
lacks() { [[ "$out" != *"$1"* ]]; }

installer() {
    case "$MODE:${1:-}" in
        local:) bash /src/install.sh ;;
        local:--uninstall) bash -s -- --uninstall < /src/install.sh ;;
        one-liner:) bash -c "$INSTALL_LINE" ;;
        one-liner:--uninstall) bash -c "$UNINSTALL_LINE" ;;
    esac
}

flags_of() { grep -o "my \$cmd = \['zfs', 'send', '[^']*'\]" "$1" | sed "s/.*'\(-[^']*\)'\]$/\1/"; }
flags_are() { local f; f=$(flags_of "$F"); [ -n "$f" ] && ! grep -qvxF -- "$1" <<< "$f"; }
send_calls() { grep -cE "[\"']zfs[\"'][[:space:]]*,[[:space:]]*[\"']send[\"']" "$1"; }
# The installed version's file as packaged, from the deb apt left in its cache.
packaged_file() {
    dpkg-deb --fsys-tarfile /var/cache/apt/archives/libpve-storage-perl_"$(version)"_all.deb \
        | tar -xO ./usr/share/perl5/PVE/Storage/ZFSPoolPlugin.pm > /root/packaged.pm
}
perl_loads() { perl -e 'use PVE::Storage::ZFSPoolPlugin'; }
version() { dpkg-query -W -f='${Version}' libpve-storage-perl; }
reinstall() { apt_q install --reinstall "libpve-storage-perl=$(version)"; }
# Reinstalling an unrelated package runs dpkg, so the hook fires with the
# patched file left as it is.
poke() { apt_q install --reinstall busybox; }
sends_via_pvesm() { grep -qF "my \$send = ['pvesm', 'export'" /usr/share/perl5/PVE/Storage.pm; }
readme_hook() { sed -n '/^DPkg::Post-Invoke {$/,/^};$/p' /src/README.md; }
packaged_md5() { awk '$2 == "usr/share/perl5/PVE/Storage/ZFSPoolPlugin.pm" {print $1}' /var/lib/dpkg/info/libpve-storage-perl.md5sums; }

# Waits until syslogd has written a marker, so every earlier message is in.
log_cursor=0
log_mark() { log_sync; log_cursor=$(wc -l < "$SYSLOG"); }
log_sync() {
    local m="e2e-sync-$RANDOM$RANDOM"
    logger -t e2e "$m"
    for _ in $(seq 50); do grep -qF "$m" "$SYSLOG" && return 0; sleep 0.1; done
    return 1
}
# Both fail when the marker never arrives, so a dead syslogd fails the check.
log_new() { log_sync || return 1; tail -n +"$((log_cursor + 1))" "$SYSLOG"; }
logged() { local l; l=$(log_new) || return 1; grep -F "$2 pve-zfs-L-patch: " <<< "$l" | grep -qF "$1"; }
not_logged() { local l; l=$(log_new) || return 1; ! grep -F "pve-zfs-L-patch: " <<< "$l" | grep -qF "$1"; }

echo "mode: $MODE"
check "README has the install and uninstall one-liners" '[ -n "$INSTALL_LINE" ] && [ -n "$UNINSTALL_LINE" ]'
check "libpve-storage-perl $OLD sends with -Rpv" 'flags_are -Rpv'
check "libpve-storage-perl $OLD has one zfs send call in list form" '[ "$(send_calls "$F")" -eq 1 ]'

log_mark
run installer
check "install on $OLD: exits 0, installs the script and writes the hook" '[ $rc -eq 0 ] && has "script installed from $FROM: $S" && has "apt hook written: $H"'
check "installed script is this checkout's" 'cmp -s "$S" /src/pve-zfs-large-block-patch.sh'
check "installed hook is the README's manual hook" 'cmp -s "$H" <(readme_hook)'
check "install on $OLD: APPLIED, no WARNING, and the file sends with -RpvL" 'has "APPLIED - patched $F" && lacks WARNING && flags_are -RpvL'
check "install on $OLD: perl loads the patched module" perl_loads
check "one backup, identical to the packaged file" '[ "$(find "$B" -name "ZFSPoolPlugin.pm.prepatch.*" | wc -l)" -eq 1 ] && [ "$(md5sum < "$B"/ZFSPoolPlugin.pm.prepatch.* | cut -d" " -f1)" = "$(packaged_md5)" ]'
check "APPLIED is logged at daemon.notice" 'logged "patched $F to add -L flag" daemon.notice'

run installer
check "install again: script and hook already in place, OK" '[ $rc -eq 0 ] && has "script already up to date" && has "apt hook already in place" && has "OK - patch already present"'

run apt_q install libpve-storage-perl
check "apt-get install of the newest version: apt exits 0, the hook says APPLIED and no WARNING" '[ $rc -eq 0 ] && has "Unpacking libpve-storage-perl" && has "APPLIED - patched $F" && lacks WARNING && [ "$(version)" != "$OLD" ]'
packaged_file
# shellcheck disable=SC2034 # read in checks
UP=$(flags_of /root/packaged.pm)
echo "newest version: $(version), packaged send flags: $UP"
check "newest version ships a send shape the script knows" '[ "$UP" = -RpvU ] || [ "$UP" = -Rpv ]'
check "newest version has one zfs send call in list form" '[ "$(send_calls /root/packaged.pm)" -eq 1 ]'
check "newest version: the file sends with ${UP}L" 'flags_are "${UP}L"'
check "newest version: perl loads the patched module" perl_loads
check "the installed storage code runs each send as a pvesm export command" sends_via_pvesm

run poke
check "OK: an apt run with the file patched says OK, apt exits 0" '[ $rc -eq 0 ] && has "OK - patch already present"'
run "$S"
check "OK: the script exits 0" '[ $rc -eq 0 ] && has "OK - patch already present"'

# Upstream has shipped neither of the next two states, so they are made by
# editing or moving the installed file.
sed -i "s/'${UP}L'\]/'${UP}w']/" "$F"
log_mark
run "$S"
check "WARNING: an unknown send shape exits 1" '[ $rc -eq 1 ] && has "WARNING - $F does not contain expected pattern."'
run poke
check "WARNING: apt exits 0 and shows the warning" '[ $rc -eq 0 ] && has "WARNING - $F does not contain expected pattern."'
check "WARNING: logged at daemon.err" 'logged "does not contain expected pattern" daemon.err'
check "WARNING: the file is left as it was" 'flags_are "${UP}w"'
run reinstall
check "reinstalling restores upstream and the hook patches it" '[ $rc -eq 0 ] && has "APPLIED" && flags_are "${UP}L"'

# Upstream has never shipped a second send call either.
sed "/my \$cmd = \['zfs', 'send'/a\    my \$probe = ['zfs', 'send', '-nP', \$snap];" /root/packaged.pm > "$F"
log_mark
run "$S"
check "WARNING: a second send call exits 1 and names its line" '[ $rc -eq 1 ] && has "WARNING - $F has 2 zfs send calls, the script knows 1. Others on line"'
check "WARNING: with a second send call the known call is still patched" 'has "The known send call was patched" && flags_are "${UP}L"'
check "WARNING: a second send call is logged at daemon.err" 'logged "has 2 zfs send calls" daemon.err'
run reinstall
check "reinstalling restores upstream: APPLIED, no WARNING" '[ $rc -eq 0 ] && has "APPLIED" && lacks WARNING && flags_are "${UP}L"'

mv "$F" /root/moved.pm
run "$S"
check "WARNING: the file missing with the package installed exits 1" '[ $rc -eq 1 ] && has "WARNING - libpve-storage-perl is installed but $F is missing."'
run poke
check "WARNING: file missing, apt exits 0" '[ $rc -eq 0 ] && has "is installed but $F is missing"'
mv /root/moved.pm "$F"

mv "$B" /root/backups
touch "$B"
log_mark
run reinstall
check "FAILED: no backup directory, apt exits 0 and the hook says FAILED" '[ $rc -eq 0 ] && has "FAILED - cannot create $B"'
check "FAILED: the file is left unpatched" 'flags_are "$UP"'
check "FAILED: logged at daemon.err" 'logged "cannot create $B" daemon.err'
run "$S"
check "FAILED: the script exits 1" '[ $rc -eq 1 ] && has "FAILED - cannot create $B"'
rm -f "$B"
mv /root/backups "$B"
run poke
check "the next apt run patches again, reusing the backup" '[ $rc -eq 0 ] && has "reusing $B/" && has "APPLIED" && flags_are "${UP}L"'

run apt_q remove libpve-storage-perl
check "NOT INSTALLED: apt remove exits 0 and the hook says NOT INSTALLED" '[ $rc -eq 0 ] && has "NOT INSTALLED - libpve-storage-perl is absent"'
run "$S"
check "NOT INSTALLED: the script exits 0" '[ $rc -eq 0 ] && has "NOT INSTALLED"'
run apt_q install --no-install-recommends libpve-storage-perl
check "reinstalling the package patches it" '[ $rc -eq 0 ] && has "APPLIED" && flags_are "${UP}L"'

chmod 644 "$S"
log_mark
run poke
chmod 755 "$S"
check "script not executable: apt exits 0 and shows the shell error" '[ $rc -eq 0 ] && has "$S: Permission denied"'
check "script not executable: the hook logs that it could not run" 'logged "$S could not run" daemon.err'

mv "$S" /root/script.sh
log_mark
run poke
mv /root/script.sh "$S"
check "script missing: apt exits 0 and shows the shell error" '[ $rc -eq 0 ] && has "$S: not found"'
check "script missing: the hook logs that it could not run" 'logged "$S could not run" daemon.err'

cp -p "$S" /root/script.sh
printf '#!/bin/bash\nkill -KILL $$\n' > "$S"
log_mark
run poke
cp -p /root/script.sh "$S"
check "script killed: apt exits 0 and shows the shell's Killed" '[ $rc -eq 0 ] && has "Killed"'
check "script killed: the hook logs the signal at daemon.err" 'logged "$S was stopped by signal 9 and may not have finished." daemon.err'
check "script killed: the hook does not say it could not run" 'not_logged "could not run"'

printf 'not an apt config file\n' > "$H.Ab12Cd.dpkg-tmp"
run apt-config dump
check "a hook temp file left behind is skipped by apt without a notice" '[ $rc -eq 0 ] && lacks "Ignoring" && lacks "E:"'
mv "$H.Ab12Cd.dpkg-tmp" "$H.Ab12Cd"
run apt-config dump
check "without the .dpkg-tmp suffix apt prints a notice for it" 'has "Ignoring file"'
rm -f "$H.Ab12Cd"

install -m 755 /root/old-script.sh "$S"
printf 'DPkg::Post-Invoke {\n    "%s || true";\n};\n' "$S" > "$H"
run reinstall
check "old manual install: its script and hook patch the file" '[ $rc -eq 0 ] && flags_are "${UP}L" && ! cmp -s "$S" /src/pve-zfs-large-block-patch.sh'
run installer
check "install over the old manual install replaces the script and the hook" '[ $rc -eq 0 ] && has "script updated from $FROM: $S" && has "apt hook replaced: $H"'
check "replaced script is this checkout's, hook is the README's" 'cmp -s "$S" /src/pve-zfs-large-block-patch.sh && cmp -s "$H" <(readme_hook)'
run reinstall
check "the next apt run re-patches with the new script" '[ $rc -eq 0 ] && has "APPLIED - patched $F" && flags_are "${UP}L"'
chmod 644 "$S"
run installer
check "install over an up-to-date script without its execute bit makes it executable" '[ $rc -eq 0 ] && has "script already up to date" && [ -x "$S" ] && has "OK - patch already present"'

run installer --uninstall
check "uninstall: exits 0, removes the hook and then the script" '[ $rc -eq 0 ] && [[ "$out" == *"removed $H"*"removed $S"* ]] && [ ! -e "$H" ] && [ ! -e "$S" ]'
check "uninstall: the file stays patched" 'flags_are "${UP}L"'
run reinstall
check "after uninstall an apt run restores upstream and runs nothing" '[ $rc -eq 0 ] && lacks "pve-zfs-L-patch" && flags_are "$UP"'
run installer --uninstall
check "uninstall again: nothing to remove, exits 0" '[ $rc -eq 0 ] && has "nothing to remove"'

echo "$fails failed"
[ "$fails" -eq 0 ]
