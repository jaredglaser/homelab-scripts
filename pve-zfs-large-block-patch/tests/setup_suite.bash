# shellcheck shell=bash

# Root ignores file modes, so the unreadable and read-only cases would not
# test what they claim, and the root-refusal tests would install into the
# real /usr/local/sbin and /etc/apt.
setup_suite() {
    if [ "$(id -u)" = 0 ]; then
        echo "Run this suite as a user other than root, for example: setpriv --reuid 65534 --regid 65534 --clear-groups bats pve-zfs-large-block-patch/tests/" >&2
        return 1
    fi
}
