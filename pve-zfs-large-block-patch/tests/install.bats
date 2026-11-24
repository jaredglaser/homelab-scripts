#!/usr/bin/env bats

load test_helper

URL="https://raw.githubusercontent.com/jaredglaser/homelab-scripts/main/pve-zfs-large-block-patch/pve-zfs-large-block-patch.sh"

setup() {
    common_setup
    INSTALL="$(cd "$TESTS_DIR/.." && pwd)/install.sh"
    INSTALLED="$ROOT/usr/local/sbin/pve-zfs-large-block-patch.sh"
    HOOK="$ROOT/etc/apt/apt.conf.d/99-pve-zfs-large-block-patch"
    export FAKE_CURL_SRC="$SCRIPT"
    export FAKE_CURL_ARGS="$PATCH_TMP/curl.args"
    with_stub curl
    seed u.pm
}

# install.sh run as a file next to the patch script, as in a clone.
install_file() {
    run "$INSTALL" --root "$ROOT" "$@"
}

# install.sh piped into bash, as the one-liner runs it, so it downloads.
install_piped() {
    run bash -c 'bash -s -- --root "$2" < "$1"' _ "$INSTALL" "$ROOT"
}

expected_hook() {
    cat <<EOF
DPkg::Post-Invoke {
    "$INSTALLED || { rc=\$?; case \$rc in 126|127) logger -p daemon.err -t pve-zfs-L-patch -- '$INSTALLED could not run, so the -L patch was not checked. Run the installer again.' ;; *) [ \$rc -le 128 ] || logger -p daemon.err -t pve-zfs-L-patch -- '$INSTALLED was stopped by signal '\$((rc - 128))' and may not have finished.' ;; esac; }; true";
};
EOF
}

old_manual_hook() {
    printf 'DPkg::Post-Invoke {\n    "%s || true";\n};\n' "$INSTALLED"
}

nothing_installed() {
    [ ! -e "$INSTALLED" ] && [ ! -e "$HOOK" ] \
        && [ -z "$(find "$ROOT/usr/local" "$ROOT/etc" -type f 2>/dev/null)" ]
}

@test "run from a clone it installs the clone's script, writes the hook and patches" {
    install_file
    [ "$status" -eq 0 ]
    [[ "$output" == *"script installed from $SCRIPT: $INSTALLED"* ]]
    [[ "$output" == *"apt hook written: $HOOK"* ]]
    [[ "$output" == *"APPLIED"* ]]
    cmp "$SCRIPT" "$INSTALLED"
    [ "$(stat -c %a "$INSTALLED")" = 755 ]
    expected_hook | diff - "$HOOK"
    [ "$(stat -c %a "$HOOK")" = 644 ]
    diff "$FIXTURES/u-patched.pm" "$FILE"
    [ ! -e "$FAKE_CURL_ARGS" ]
}

@test "piped into bash it downloads the script from main" {
    install_piped
    [ "$status" -eq 0 ]
    [ "$(sed -n 1p "$FAKE_CURL_ARGS")" = -fsSL ]
    [ "$(sed -n 2p "$FAKE_CURL_ARGS")" = -o ]
    [ "$(sed -n 4p "$FAKE_CURL_ARGS")" = "$URL" ]
    [[ "$output" == *"script installed from $URL: $INSTALLED"* ]]
    cmp "$SCRIPT" "$INSTALLED"
    [ "$(stat -c %a "$INSTALLED")" = 755 ]
    expected_hook | diff - "$HOOK"
    [[ "$output" == *"APPLIED"* ]]
    [ "$(find "$ROOT/usr/local/sbin" -type f | wc -l)" -eq 1 ]
}

@test "the README's manual hook is the one the installer writes" {
    install_file
    [ "$status" -eq 0 ]
    sed -n '/^DPkg::Post-Invoke {$/,/^};$/p' "$TESTS_DIR/../README.md" \
        | sed "s#/usr/local/sbin/pve-zfs-large-block-patch.sh#$INSTALLED#g" | diff - "$HOOK"
}

@test "a rerun says the script and hook are already in place" {
    install_file
    [ "$status" -eq 0 ]
    install_file
    [ "$status" -eq 0 ]
    [[ "$output" == *"script already up to date"* ]]
    [[ "$output" == *"apt hook already in place"* ]]
    [[ "$output" == *"OK - patch already present"* ]]
    [ "$(find "$ROOT/usr/local/sbin" "$ROOT/etc/apt/apt.conf.d" -type f | wc -l)" -eq 2 ]
}

@test "a rerun makes an up-to-date script that lost its execute bit executable" {
    install_file
    chmod 644 "$INSTALLED"
    install_file
    [ "$status" -eq 0 ]
    [[ "$output" == *"script already up to date"* ]]
    [ "$(stat -c %a "$INSTALLED")" = 755 ]
    [[ "$output" == *"OK - patch already present"* ]]
}

@test "a piped run from a directory holding a script of the same name still downloads" {
    mkdir -p "$PATCH_TMP/cwd"
    printf '#!/bin/bash\necho decoy\n# end of pve-zfs-large-block-patch.sh\n' > "$PATCH_TMP/cwd/pve-zfs-large-block-patch.sh"
    run bash -c 'cd "$3" && bash -s -- --root "$2" < "$1"' _ "$INSTALL" "$ROOT" "$PATCH_TMP/cwd"
    [ "$status" -eq 0 ]
    [ "$(sed -n 4p "$FAKE_CURL_ARGS")" = "$URL" ]
    cmp "$SCRIPT" "$INSTALLED"
}

@test "install.sh cut off inside its last line runs nothing" {
    local n full
    install_file
    full=$(wc -c < "$INSTALL")
    # The last byte is the newline after main, so cutting it leaves a whole word.
    for n in 2 3 4 5; do
        head -c $((full - n)) "$INSTALL" > "$PATCH_TMP/cut-install.sh"
        run bash -c 'bash -s -- --uninstall --root "$2" < "$1"' _ "$PATCH_TMP/cut-install.sh" "$ROOT"
        [[ "$output" != *"removed"* ]]
        [[ "$output" != *"running"* ]]
        [ -e "$INSTALLED" ] && [ -e "$HOOK" ]
    done
}

@test "a piped rerun with nothing new leaves no download behind" {
    install_piped
    install_piped
    [ "$status" -eq 0 ]
    [[ "$output" == *"script already up to date"* ]]
    [ "$(find "$ROOT/usr/local/sbin" -type f | wc -l)" -eq 1 ]
}

@test "over a manual install it replaces the script and the || true hook" {
    mkdir -p "$(dirname "$INSTALLED")" "$(dirname "$HOOK")"
    printf '#!/bin/bash\necho old\n' > "$INSTALLED"
    chmod 755 "$INSTALLED"
    old_manual_hook > "$HOOK"
    install_file
    [ "$status" -eq 0 ]
    [[ "$output" == *"script updated from $SCRIPT"* ]]
    [[ "$output" == *"apt hook replaced: $HOOK"* ]]
    cmp "$SCRIPT" "$INSTALLED"
    expected_hook | diff - "$HOOK"
    [[ "$output" == *"APPLIED"* ]]
}

@test "the patch script's exit status and output pass through" {
    seed plain.pm
    sed -i "s/'-Rpv'/'-Rpvw'/" "$FILE"
    install_file
    [ "$status" -eq 1 ]
    [[ "$output" == *"WARNING"*"does not contain expected pattern"* ]]
    [[ "$output" == *"the script and the apt hook are installed, but this first run ended with exit 1."* ]]
}

@test "refuses when not root and changes nothing" {
    run "$INSTALL"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED - must run as root. Use: curl -fsSL https://raw.githubusercontent.com/jaredglaser/homelab-scripts/main/pve-zfs-large-block-patch/install.sh | sudo bash"* ]]
    [ ! -e "$FAKE_CURL_ARGS" ]
}

@test "--uninstall refuses when not root" {
    run "$INSTALL" --uninstall
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED - must run as root"* ]]
    [[ "$output" != *"removed"* ]]
}

@test "a 404 from GitHub installs nothing and says the download failed" {
    FAKE_CURL_SRC=404 install_piped
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED - could not download $URL. Nothing was changed."* ]]
    nothing_installed
    diff "$FIXTURES/u.pm" "$FILE"
}

@test "a 404 body served with success installs nothing" {
    printf '404: Not Found' > "$PATCH_TMP/body"
    FAKE_CURL_SRC="$PATCH_TMP/body" install_piped
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED - $URL is not a complete copy of pve-zfs-large-block-patch.sh. Nothing was changed."* ]]
    nothing_installed
}

@test "a download cut short at any line installs nothing" {
    local lines n
    lines=$(wc -l < "$SCRIPT")
    for n in 1 100 146 $((lines - 1)); do
        head -n "$n" "$SCRIPT" > "$PATCH_TMP/cut"
        FAKE_CURL_SRC="$PATCH_TMP/cut" install_piped
        [ "$status" -eq 1 ]
        [[ "$output" == *"is not a complete copy"* ]]
        nothing_installed
    done
}

@test "a download that ends right but does not parse installs nothing" {
    printf '#!/bin/bash\nif then\n# end of pve-zfs-large-block-patch.sh\n' > "$PATCH_TMP/bad"
    FAKE_CURL_SRC="$PATCH_TMP/bad" install_piped
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED - $URL is not a valid bash script. Nothing was changed."* ]]
    nothing_installed
}

@test "a download with anything after the end line installs nothing" {
    { cat "$SCRIPT"; printf 'echo extra\n'; } > "$PATCH_TMP/extra"
    FAKE_CURL_SRC="$PATCH_TMP/extra" install_piped
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a complete copy"* ]]
    nothing_installed
}

@test "a failed download keeps the installed script" {
    install_file
    printf '#!/bin/bash\necho old\n' > "$INSTALLED"
    cp "$INSTALLED" "$PATCH_TMP/before"
    FAKE_CURL_SRC=404 install_piped
    [ "$status" -eq 1 ]
    cmp "$PATCH_TMP/before" "$INSTALLED"
    [ "$(find "$ROOT/usr/local/sbin" -type f | wc -l)" -eq 1 ]
}

@test "a hook write that fails partway leaves the previous hook intact" {
    install_file
    old_manual_hook > "$HOOK"
    # With a file size limit of 0 every write fails with EFBIG after open,
    # which is what a full disk does to a write in progress.
    run bash -c 'trap "" XFSZ; ulimit -f 0; "$@"' _ "$INSTALL" --root "$ROOT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED - cannot write $HOOK. The script is installed at $INSTALLED, but the apt hook is not, and the patch was not applied. The previous hook, if any, is unchanged."* ]]
    old_manual_hook | diff - "$HOOK"
    [ "$(find "$(dirname "$HOOK")" -type f | wc -l)" -eq 1 ]
}

@test "the hook is written under a name apt skips, then renamed" {
    ln -s "$STUBS/mv" "$PATCH_TMP/bin/mv"
    export FAKE_MV_ARGS="$PATCH_TMP/mv.args"
    install_file
    [ "$status" -eq 0 ]
    grep -qE "^-f $HOOK\.[A-Za-z0-9]{6}\.dpkg-tmp $HOOK\$" "$FAKE_MV_ARGS"
}

@test "the hook logs a script that could not start or was killed, and nothing else" {
    install_file
    local cmd rc
    cmd=$(sed -n 's/^    "\(.*\)";$/\1/p' "$HOOK")
    [ -n "$cmd" ]
    for rc in 0 1 2 126 127 128 137; do
        : > "$FAKE_SYSLOG"
        case "$rc" in
            126) printf '#!/bin/bash\n' > "$INSTALLED"; chmod 644 "$INSTALLED" ;;
            127) rm -f "$INSTALLED" ;;
            137) printf '#!/bin/bash\nkill -KILL $$\n' > "$INSTALLED"; chmod 755 "$INSTALLED" ;;
            *) printf '#!/bin/bash\nexit %s\n' "$rc" > "$INSTALLED"; chmod 755 "$INSTALLED" ;;
        esac
        run sh -c "$cmd"
        [ "$status" -eq 0 ]
        case "$rc" in
            126|127) printf -- '-p daemon.err -t pve-zfs-L-patch -- %s could not run, so the -L patch was not checked. Run the installer again.\n' "$INSTALLED" | diff - "$FAKE_SYSLOG" ;;
            137) printf -- '-p daemon.err -t pve-zfs-L-patch -- %s was stopped by signal 9 and may not have finished.\n' "$INSTALLED" | diff - "$FAKE_SYSLOG" ;;
            *) [ ! -s "$FAKE_SYSLOG" ] ;;
        esac
    done
}

@test "the hook exits 0 even when logger fails" {
    install_file
    local cmd
    cmd=$(sed -n 's/^    "\(.*\)";$/\1/p' "$HOOK")
    rm -f "$INSTALLED"
    printf '#!/bin/sh\nexit 1\n' > "$PATCH_TMP/bin/logger"
    chmod 755 "$PATCH_TMP/bin/logger"
    run sh -c "$cmd"
    [ "$status" -eq 0 ]
}

@test "an unknown argument is refused" {
    install_file --remove
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown argument: --remove"* ]]
    nothing_installed
}

@test "--root without a directory is refused" {
    run "$INSTALL" --root
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED - --root needs a directory."* ]]
}

@test "--uninstall removes the hook and then the script, keeps the patched file and backups" {
    install_file
    [ "$status" -eq 0 ]
    install_file --uninstall
    [ "$status" -eq 0 ]
    [ ! -e "$HOOK" ]
    [ ! -e "$INSTALLED" ]
    diff "$FIXTURES/u-patched.pm" "$FILE"
    [ "$(backup_count)" -eq 1 ]
    [[ "$output" == *"removed $HOOK"*"removed $INSTALLED"* ]]
    [[ "$output" == *"apt-get install --reinstall \"libpve-storage-perl=\$(dpkg-query -W -f='\${Version}' libpve-storage-perl)\""* ]]
    [[ "$output" == *"Backups of the unpatched file are in $BACKUPS"* ]]
    [ ! -e "$FAKE_CURL_ARGS" ]
}

@test "--uninstall with nothing installed says so and exits 0" {
    install_file --uninstall
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to remove"* ]]
}

@test "--uninstall removes a dangling symlink as hook or script" {
    mkdir -p "$(dirname "$INSTALLED")" "$(dirname "$HOOK")"
    ln -s /nonexistent/script "$INSTALLED"
    ln -s /nonexistent/hook "$HOOK"
    install_file --uninstall
    [ "$status" -eq 0 ]
    [[ "$output" == *"removed $HOOK"*"removed $INSTALLED"* ]]
    [ ! -L "$INSTALLED" ] && [ ! -L "$HOOK" ]
}

@test "--uninstall that cannot remove the hook stops before the script" {
    install_file
    chmod 555 "$(dirname "$HOOK")"
    install_file --uninstall
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED - cannot remove $HOOK."* ]]
    [ -e "$HOOK" ] && [ -e "$INSTALLED" ]
}

@test "--uninstall that cannot remove the script says so and exits 1" {
    install_file
    chmod 555 "$(dirname "$INSTALLED")"
    install_file --uninstall
    [ "$status" -eq 1 ]
    [[ "$output" == *"removed $HOOK"* ]]
    [[ "$output" == *"FAILED - cannot remove $INSTALLED."* ]]
    [ ! -e "$HOOK" ] && [ -e "$INSTALLED" ]
}
