#!/bin/bash
# Runs inside the stand-in node. Builds libpve-storage-perl packages that ship
# only ZFSPoolPlugin.pm, one per upstream copy in $1, plus synthetic variants
# for the WARNING states, and publishes them as a local apt repository.
set -euo pipefail
# docker exec runs with umask 0, and dpkg-deb rejects a world-writable DEBIAN.
umask 022

src="${1:?usage: build-debs.sh <dir with upstream .pm files>}"
repo=/srv/e2e-repo
work=$(mktemp -d)
mkdir -p "$repo"

# build <version> <path inside package> <source .pm> <description>
build() {
    local ver="$1" path="$2" pm="$3" desc="$4" root="$work/$1"
    mkdir -p "$root/DEBIAN" "$root$(dirname "$path")"
    cp "$pm" "$root$path"
    # A conffile makes apt remove leave the package in the config-files
    # state, which the script treats as absent.
    mkdir -p "$root/etc"
    echo "# e2e stand-in conffile" > "$root/etc/e2e-libpve-storage-perl.conf"
    echo /etc/e2e-libpve-storage-perl.conf > "$root/DEBIAN/conffiles"
    # Upstream debian/triggers, which pve-manager declares interest in.
    echo "activate-noawait pve-api-updates" > "$root/DEBIAN/triggers"
    cat > "$root/DEBIAN/control" <<CTL
Package: libpve-storage-perl
Version: $ver
Architecture: all
Maintainer: e2e harness <root@localhost>
Section: perl
Priority: optional
Description: stand-in for the Proxmox VE storage library ($desc)
CTL
    dpkg-deb --root-owner-group -Zgzip --build "$root" "$repo/libpve-storage-perl_${ver}_all.deb" >/dev/null
}

f=/usr/share/perl5/PVE/Storage/ZFSPoolPlugin.pm
build 9.1.2  "$f" "$src/ZFSPoolPlugin.pm.e17a33794c34" "upstream e17a33794c34, -Rpv"
build 9.1.3  "$f" "$src/ZFSPoolPlugin.pm.c705a2c03f2c" "upstream c705a2c03f2c, -RpvU"
build 9.1.23 "$f" "$src/ZFSPoolPlugin.pm.HEAD"         "upstream HEAD, -RpvU"

# Synthetic variants of HEAD, pinned below the real ones so a plain upgrade
# never picks them: apt-get install libpve-storage-perl=<version> selects one.
syn="$work/syn"; mkdir -p "$syn"
sed "s/'zfs', 'send', '-RpvU'/'zfs', 'send', '-RpvUw'/" "$src/ZFSPoolPlugin.pm.HEAD" > "$syn/shape.pm"
awk '{print} /my \$cmd = \[.zfs., .send., .-RpvU.\];/ && !done {print "    my $probe = [\x27zfs\x27, \x27send\x27, \x27-nP\x27, $snap];"; done=1}' \
    "$src/ZFSPoolPlugin.pm.HEAD" > "$syn/extra.pm"
grep -q "'-RpvUw'" "$syn/shape.pm"
grep -q "'-nP'" "$syn/extra.pm"
build 9.1.23+syn.moved "/usr/share/perl5/PVE/Storage/ZFSPoolPlugin/Base.pm" "$src/ZFSPoolPlugin.pm.HEAD" "synthetic: file moved"
build 9.1.23+syn.shape "$f" "$syn/shape.pm" "synthetic: send flags changed to -RpvUw"
build 9.1.23+syn.extra "$f" "$syn/extra.pm" "synthetic: a second send site without -L"

# Stand-in pve-manager with upstream's trigger interest, so apt output
# has "Processing triggers for pve-manager" where a real node has it.
mgr="$work/pve-manager"
mkdir -p "$mgr/DEBIAN"
cat > "$mgr/DEBIAN/control" <<CTL
Package: pve-manager
Version: 9.1.9
Architecture: all
Maintainer: e2e harness <root@localhost>
Description: stand-in for the Proxmox VE manager (trigger interest only)
CTL
printf 'interest-noawait pve-api-updates\n' > "$mgr/DEBIAN/triggers"
dpkg-deb --root-owner-group -Zgzip --build "$mgr" "$repo/pve-manager_9.1.9_all.deb" >/dev/null

# An unrelated package to reinstall, so a check can fire the hook without
# touching libpve-storage-perl or needing a mirror.
poke="$work/e2e-poke"
mkdir -p "$poke/DEBIAN" "$poke/usr/share/doc/e2e-poke"
printf 'Package: e2e-poke\nVersion: 1.0\nArchitecture: all\nMaintainer: e2e harness <root@localhost>\nDescription: unrelated package for the e2e harness\n' > "$poke/DEBIAN/control"
echo "e2e" > "$poke/usr/share/doc/e2e-poke/README"
dpkg-deb --root-owner-group -Zgzip --build "$poke" "$repo/e2e-poke_1.0_all.deb" >/dev/null

(cd "$repo" && dpkg-scanpackages --multiversion . /dev/null 2>/dev/null > Packages)
echo "deb [trusted=yes] file:$repo ./" > /etc/apt/sources.list.d/e2e.list
cat > /etc/apt/preferences.d/e2e-synthetic <<'PIN'
Package: libpve-storage-perl
Pin: version 9.1.23+syn*
Pin-Priority: 50
PIN
rm -rf "$work"
ls "$repo"
