#!/usr/bin/env bats

load test_helper

setup() {
    common_setup
    INSTALL="$(cd "$TESTS_DIR/.." && pwd)/install.sh"
    export PVE_ZFS_PATCH_SCRIPT_OVERRIDE="$PATCH_TMP/sbin/pve-zfs-large-block-patch.sh"
    export PVE_ZFS_PATCH_HOOK_OVERRIDE="$PATCH_TMP/apt.conf.d/99-pve-zfs-large-block-patch"
    export FAKE_CURL_SRC="$SCRIPT"
    export FAKE_CURL_ARGS="$PATCH_TMP/curl.args"
    INSTALLED="$PVE_ZFS_PATCH_SCRIPT_OVERRIDE"
    HOOK="$PVE_ZFS_PATCH_HOOK_OVERRIDE"
    with_stub curl
    with_stub id
    seed u.pm
}

expected_hook() {
    printf 'DPkg::Post-Invoke {\n    "%s || true";\n};\n' "$INSTALLED"
}

@test "a fresh install fetches the script from main, writes the hook and patches" {
    run "$INSTALL"
    [ "$status" -eq 0 ]
    grep -qx "https://raw.githubusercontent.com/jaredglaser/homelab-scripts/main/pve-zfs-large-block-patch/pve-zfs-large-block-patch.sh" "$FAKE_CURL_ARGS"
    cmp "$SCRIPT" "$INSTALLED"
    [ -x "$INSTALLED" ]
    expected_hook | diff - "$HOOK"
    [[ "$output" == *"script installed from main"* ]]
    [[ "$output" == *"apt hook written"* ]]
    [[ "$output" == *"APPLIED"* ]]
    diff "$FIXTURES/u-patched.pm" "$FILE"
}

@test "PVE_ZFS_PATCH_BRANCH picks the branch" {
    PVE_ZFS_PATCH_BRANCH=some/branch run "$INSTALL"
    [ "$status" -eq 0 ]
    grep -qx "https://raw.githubusercontent.com/jaredglaser/homelab-scripts/some/branch/pve-zfs-large-block-patch/pve-zfs-large-block-patch.sh" "$FAKE_CURL_ARGS"
}

@test "a rerun says the script and hook are already in place" {
    run "$INSTALL"
    [ "$status" -eq 0 ]
    run "$INSTALL"
    [ "$status" -eq 0 ]
    [[ "$output" == *"script already up to date"* ]]
    [[ "$output" == *"apt hook already in place"* ]]
    [[ "$output" == *"OK - patch already present"* ]]
}

@test "a rerun over an older script updates it and keeps a correct hook" {
    run "$INSTALL"
    printf '#!/bin/bash\necho old\n' > "$INSTALLED"
    run "$INSTALL"
    [ "$status" -eq 0 ]
    [[ "$output" == *"script updated from main"* ]]
    [[ "$output" == *"apt hook already in place"* ]]
    cmp "$SCRIPT" "$INSTALLED"
}

@test "a hook that differs is replaced and says so" {
    mkdir -p "$(dirname "$HOOK")"
    expected_hook | sed 's/^/# /' > "$HOOK"
    run "$INSTALL"
    [ "$status" -eq 0 ]
    [[ "$output" == *"apt hook replaced"* ]]
    expected_hook | diff - "$HOOK"
}

@test "the patch script's exit status and output pass through" {
    seed plain.pm
    sed -i "s/'-Rpv'/'-Rpvw'/" "$FILE"
    run "$INSTALL"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WARNING"*"does not contain expected pattern"* ]]
}

@test "refuses when not root and changes nothing" {
    FAKE_UID=1000 run "$INSTALL"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED - must run as root"* ]]
    [ ! -e "$INSTALLED" ]
    [ ! -e "$HOOK" ]
    diff "$FIXTURES/u.pm" "$FILE"
}

@test "a failed download changes nothing" {
    run "$INSTALL"
    cp "$INSTALLED" "$PATCH_TMP/before"
    FAKE_CURL_SRC="" run "$INSTALL"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED - could not download"* ]]
    cmp "$PATCH_TMP/before" "$INSTALLED"
    [ "$(find "$(dirname "$INSTALLED")" -type f | wc -l)" -eq 1 ]
}

@test "a download that is not a complete bash script is not installed" {
    head -c 2000 "$SCRIPT" > "$PATCH_TMP/truncated"
    FAKE_CURL_SRC="$PATCH_TMP/truncated" run "$INSTALL"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a complete bash script"* ]]
    [ ! -e "$INSTALLED" ]
    [ ! -e "$HOOK" ]
    printf '<html>404</html>\n' > "$PATCH_TMP/html"
    FAKE_CURL_SRC="$PATCH_TMP/html" run "$INSTALL"
    [ "$status" -eq 1 ]
    [ ! -e "$INSTALLED" ]
}

@test "an unknown argument is refused" {
    run "$INSTALL" --remove
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown argument: --remove"* ]]
    [ ! -e "$INSTALLED" ]
}

@test "--uninstall removes the hook and script, keeps the patched file and backups" {
    run "$INSTALL"
    [ "$status" -eq 0 ]
    : > "$FAKE_CURL_ARGS"
    run "$INSTALL" --uninstall
    [ "$status" -eq 0 ]
    [ ! -e "$HOOK" ]
    [ ! -e "$INSTALLED" ]
    diff "$FIXTURES/u-patched.pm" "$FILE"
    [ "$(backup_count)" -eq 1 ]
    [[ "$output" == *"removed $HOOK"*"removed $INSTALLED"* ]]
    [[ "$output" == *"apt-get install --reinstall \"libpve-storage-perl=\$(dpkg-query -W -f='\${Version}' libpve-storage-perl)\""* ]]
    [[ "$output" == *"Backups of the unpatched file are in /var/backups/pve-zfs-L-patch"* ]]
    [ ! -s "$FAKE_CURL_ARGS" ]
}

@test "--uninstall with nothing installed says so and exits 0" {
    run "$INSTALL" --uninstall
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to remove"* ]]
}

@test "--uninstall refuses when not root" {
    run "$INSTALL"
    FAKE_UID=1000 run "$INSTALL" --uninstall
    [ "$status" -eq 1 ]
    [ -e "$HOOK" ]
    [ -e "$INSTALLED" ]
}

@test "the overrides are ignored without PVE_ZFS_PATCH_TESTING=1" {
    # Not root, so the installer stops before it touches the real paths.
    FAKE_UID=1000 PVE_ZFS_PATCH_TESTING="" run "$INSTALL"
    [ "$status" -eq 1 ]
    [[ "$output" != *"TEST MODE"* ]]
    [[ "$output" != *"$PATCH_TMP"* ]]
}

@test "works when piped into bash, as the one-liner runs it" {
    run bash -c 'bash < "$1"' _ "$INSTALL"
    [ "$status" -eq 0 ]
    [[ "$output" == *"APPLIED"* ]]
    expected_hook | diff - "$HOOK"
}
