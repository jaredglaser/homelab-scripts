#!/bin/bash
# Runs checks.sh in a debian:trixie container. Needs Docker and network
# access to deb.debian.org, download.proxmox.com, enterprise.proxmox.com and
# raw.githubusercontent.com.
#
#   run.sh               install with this checkout's install.sh and script
#   run.sh --one-liner   install with the README's one-liner, which fetches main
#
# https_proxy and SSL_CERT_FILE are passed in when set, for a network that
# only reaches those hosts through an HTTPS proxy.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/../.." && pwd)"

case "${1:-}" in
    "") mode=local ;;
    --one-liner) mode=one-liner ;;
    *) echo "usage: $0 [--one-liner]" >&2; exit 2 ;;
esac

name="pve-e2e-$$"
args=(--rm --name "$name" -e "MODE=$mode" -v "$src:/src:ro")
if [ -n "${https_proxy:-}" ]; then
    # A proxy on the host's loopback is out of reach from a bridged container.
    args+=(--network host -e "https_proxy=$https_proxy")
fi
if [ -n "${SSL_CERT_FILE:-}" ]; then
    args+=(-v "$SSL_CERT_FILE:/ca.crt:ro")
fi

trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT
docker run "${args[@]}" debian:trixie bash /src/tests/e2e/checks.sh
