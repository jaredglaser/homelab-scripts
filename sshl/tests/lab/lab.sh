#!/usr/bin/env bash
# End-to-end lab for sshl: real SSH hosts in Docker, a konsole on a virtual
# display, and a non-root desktop user who runs sshl the way a person would.
# Run as root on a disposable Linux VM. See README.md next to this script.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SSHL_SRC="$(cd "$LAB_DIR/../.." && pwd)"
LAB_USER="${LAB_USER:-sshlab}"
LAB_HOME="/home/$LAB_USER"
LAB_STATE="${LAB_STATE:-/var/tmp/sshl-lab}"
LAB_NET="sshl-lab"
LAB_SUBNET="172.30.0.0/24"
LAB_GW="172.30.0.1"
DISPLAY_NUM="${LAB_DISPLAY:-:99}"
FZF_VER="0.54.3"
FZF_SHA256="6867008c46307f036e48b42ab9bfdc3224657f6a65d70c58a1f456c4d9348cf6"

# name ip image login-user key? description
HOSTS=(
    "web01 172.30.0.10 sshl-lab-apt root key"
    "db01 172.30.0.11 sshl-lab-apt opsudo key"
    "nas01 172.30.0.12 sshl-lab-apt ops key"
    "pi01 172.30.0.13 sshl-lab-noapt root key"
    "cam01 172.30.0.15 sshl-lab-noapt root nokey"
    "iot01 172.30.0.16 sshl-lab-noapt root nokey"
)

die() { echo "lab: $*" >&2; exit 1; }
need_root() { [[ "$(id -u)" == 0 ]] || die "run as root"; }
as_user() {
    runuser -u "$LAB_USER" -- env -i HOME="$LAB_HOME" USER="$LAB_USER" LOGNAME="$LAB_USER" SHELL=/bin/bash \
        DISPLAY="$DISPLAY_NUM" LANG=C.UTF-8 XDG_RUNTIME_DIR="$LAB_STATE/run" \
        PATH="$LAB_HOME/bin:/usr/local/bin:/usr/bin:/bin" "$@"
}

# Behind an HTTPS-only proxy on loopback (as in Claude Code cloud sessions),
# containers can neither reach 127.0.0.1 nor fetch plain http mirrors.
proxy_url() { printf '%s' "${HTTPS_PROXY:-${https_proxy:-}}"; }
ca_file() {
    local f="${LAB_CA_FILE:-/root/.ccr/ca-bundle.crt}"
    [[ -f "$f" ]] && printf '%s' "$f"
}

cmd_deps() {
    need_root
    # A fresh VM may have no package lists yet.
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        konsole xvfb xdotool x11-utils x11-apps imagemagick dbus-x11 fonts-dejavu-core \
        openssh-client nmap socat tmux bats shellcheck curl ca-certificates iproute2 >/dev/null
    command -v docker >/dev/null || die "docker is not installed"
    install -d "$LAB_STATE/bin"
    if [[ ! -x "$LAB_STATE/bin/fzf" ]]; then
        curl -fsSLo "$LAB_STATE/fzf.tgz" \
            "https://github.com/junegunn/fzf/releases/download/v${FZF_VER}/fzf-${FZF_VER}-linux_amd64.tar.gz"
        echo "${FZF_SHA256}  $LAB_STATE/fzf.tgz" | sha256sum -c - >/dev/null
        tar -xzf "$LAB_STATE/fzf.tgz" -C "$LAB_STATE/bin" fzf
    fi
    echo "deps ok: $(tmux -V), fzf $("$LAB_STATE/bin/fzf" --version | cut -d' ' -f1), $(nmap --version | head -1)"
}

cmd_docker() {
    need_root
    if ! docker info >/dev/null 2>&1; then
        (dockerd >"$LAB_STATE/dockerd.log" 2>&1 &)
        local _
        for _ in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 1; done
    fi
    docker info >/dev/null 2>&1 || die "dockerd did not start, see $LAB_STATE/dockerd.log"

    local build="$LAB_STATE/build" proxy ca
    proxy="$(proxy_url)"; ca="$(ca_file || true)"
    install -d "$build/apt" "$build/noapt"
    : > "$build/apt/ca.crt"
    [[ -n "$ca" ]] && cp "$ca" "$build/apt/ca.crt"
    cat > "$build/apt/Dockerfile" <<'EOF'
FROM ubuntu:24.04
ARG https_proxy=""
COPY ca.crt /usr/local/share/ca-certificates/lab-proxy.crt
RUN if [ -n "$https_proxy" ]; then \
      sed -i 's#http://\(archive\|security\).ubuntu.com#https://\1.ubuntu.com#g' /etc/apt/sources.list.d/ubuntu.sources; \
      printf 'Acquire::https::Proxy "%s";\n' "$https_proxy" > /etc/apt/apt.conf.d/90proxy; \
      if [ -s /usr/local/share/ca-certificates/lab-proxy.crt ]; then \
        echo 'Acquire::https::CaInfo "/usr/local/share/ca-certificates/lab-proxy.crt";' >> /etc/apt/apt.conf.d/90proxy; fi; \
    fi \
 && apt-get update -qq && apt-get install -y -qq --no-install-recommends openssh-server sudo procps htop >/dev/null \
 && mkdir -p /run/sshd && useradd -m -s /bin/bash ops && useradd -m -s /bin/bash opsudo \
 && echo 'opsudo ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/opsudo \
 && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
CMD ["/usr/sbin/sshd", "-D", "-e"]
EOF
    cat > "$build/noapt/Dockerfile" <<'EOF'
FROM sshl-lab-apt
RUN mv /usr/bin/apt /usr/bin/apt.hidden && mv /usr/bin/apt-get /usr/bin/apt-get.hidden
EOF
    docker image inspect sshl-lab-apt >/dev/null 2>&1 || \
        docker build -q --network host --build-arg https_proxy="$proxy" -t sshl-lab-apt "$build/apt" >/dev/null
    docker image inspect sshl-lab-noapt >/dev/null 2>&1 || \
        docker build -q -t sshl-lab-noapt "$build/noapt" >/dev/null
    echo "images ok"
}

cmd_user() {
    need_root
    id "$LAB_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$LAB_USER"
    install -d -m 700 -o "$LAB_USER" -g "$LAB_USER" "$LAB_HOME/.ssh" "$LAB_HOME/bin"
    install -d -m 700 -o "$LAB_USER" -g "$LAB_USER" "$LAB_STATE/run"
    [[ -f "$LAB_HOME/.ssh/id_ed25519" ]] || \
        runuser -u "$LAB_USER" -- ssh-keygen -q -t ed25519 -N "" -f "$LAB_HOME/.ssh/id_ed25519"
    install -m 755 -o "$LAB_USER" -g "$LAB_USER" "$LAB_STATE/bin/fzf" "$LAB_HOME/bin/fzf"
    echo "user ok: $LAB_USER"
}

cmd_hosts() {
    need_root
    docker network inspect "$LAB_NET" >/dev/null 2>&1 || \
        docker network create --subnet "$LAB_SUBNET" --gateway "$LAB_GW" "$LAB_NET" >/dev/null
    local proxy port
    proxy="$(proxy_url)"
    if [[ "$proxy" =~ ^https?://(127\.0\.0\.1|localhost):([0-9]+) ]]; then
        port="${BASH_REMATCH[2]}"
        pgrep -f "TCP-LISTEN:$port,bind=$LAB_GW" >/dev/null || \
            (socat "TCP-LISTEN:$port,bind=$LAB_GW,reuseaddr,fork" "TCP:127.0.0.1:$port" >/dev/null 2>&1 &)
        proxy="http://$LAB_GW:$port"
    fi
    local spec name ip image user key home
    for spec in "${HOSTS[@]}"; do
        read -r name ip image user key <<<"$spec"
        if ! docker container inspect "$name" >/dev/null 2>&1; then
            docker run -d --name "$name" --hostname "$name" --network "$LAB_NET" --ip "$ip" "$image" >/dev/null
        fi
        docker start "$name" >/dev/null
        if [[ "$key" == key ]]; then
            home="/home/$user"; [[ "$user" == root ]] && home=/root
            docker exec "$name" install -d -m 700 -o "$user" -g "$user" "$home/.ssh"
            docker exec -i "$name" tee "$home/.ssh/authorized_keys" < "$LAB_HOME/.ssh/id_ed25519.pub" >/dev/null
            docker exec "$name" chown "$user:$user" "$home/.ssh/authorized_keys"
            docker exec "$name" chmod 600 "$home/.ssh/authorized_keys"
        fi
        if [[ "$image" == sshl-lab-apt && -n "$proxy" ]]; then
            docker exec "$name" sed -i "s#^Acquire::https::Proxy .*#Acquire::https::Proxy \"$proxy\";#" /etc/apt/apt.conf.d/90proxy
        fi
    done
    # The local image without sshd running, so no Docker Hub pull (which a
    # cloud VM can hit the rate limit on) is needed.
    docker container inspect off01 >/dev/null 2>&1 || \
        docker run -d --name off01 --hostname off01 --network "$LAB_NET" --ip 172.30.0.17 sshl-lab-noapt sleep infinity >/dev/null
    docker start off01 >/dev/null
    grep -q " cam01.lab$" /etc/hosts || echo "172.30.0.15 cam01.lab" >> /etc/hosts
    echo "hosts ok"
}

cmd_display() {
    need_root
    pgrep -f "Xvfb $DISPLAY_NUM" >/dev/null || (Xvfb "$DISPLAY_NUM" -screen 0 1600x1000x24 >/dev/null 2>&1 &)
    local _
    for _ in $(seq 1 20); do DISPLAY="$DISPLAY_NUM" xdpyinfo >/dev/null 2>&1 && break; sleep 0.25; done
    DISPLAY="$DISPLAY_NUM" xdpyinfo >/dev/null 2>&1 || die "Xvfb did not start on $DISPLAY_NUM"
    echo "display ok: $DISPLAY_NUM"
}

# Copies the checkout's sshl into the lab user's home, as a git clone would.
# Keeps an existing config and caches so a reinstall tests an upgrade.
cmd_install() {
    need_root
    local dest="$LAB_HOME/homelab-scripts/sshl"
    install -d -o "$LAB_USER" -g "$LAB_USER" "$LAB_HOME/homelab-scripts" "$dest"
    tar -C "$SSHL_SRC" --exclude=./config --exclude='./*.cache' -cf - . | tar -C "$dest" -xf -
    chown -R "$LAB_USER:$LAB_USER" "$dest"
    echo "installed $(git -C "$SSHL_SRC" rev-parse --short HEAD 2>/dev/null || echo '?') into $dest"
}

cmd_up() {
    cmd_deps; cmd_docker; cmd_user; cmd_hosts; cmd_display; cmd_install
    cmd_check
}

cmd_check() {
    local spec name ip image user key out
    for spec in "${HOSTS[@]}"; do
        read -r name ip image user key <<<"$spec"
        out="$(as_user ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$user@$ip" hostname -s 2>&1 || true)"
        printf '%-6s %-12s %-7s expect %-5s got: %s\n' "$name" "$ip" "$user" "$key" "$out"
    done
    printf 'nmap sees port 22 open on: %s\n' \
        "$(nmap -Pn -n -p 22 --open --max-retries 1 "$LAB_SUBNET" -oG - 2>/dev/null | awk '/22\/open/{printf "%s ", $2}')"
}

# Opens a konsole for the lab user. Extra arguments are run in it.
cmd_konsole() {
    need_root
    if (( $# )); then
        (as_user dbus-launch --exit-with-session konsole --workdir "$LAB_HOME/homelab-scripts/sshl" -e "$@" \
            >"$LAB_STATE/konsole.log" 2>&1 &)
    else
        (as_user dbus-launch --exit-with-session konsole --workdir "$LAB_HOME/homelab-scripts/sshl" \
            >"$LAB_STATE/konsole.log" 2>&1 &)
    fi
    sleep 3
    cmd_windows
}

cmd_windows() {
    local w
    for w in $(DISPLAY="$DISPLAY_NUM" xdotool search --class konsole 2>/dev/null); do
        DISPLAY="$DISPLAY_NUM" xwininfo -id "$w" 2>/dev/null | awk -v w="$w" \
            '/Map State: IsViewable/{v=1} /Width:/{wd=$2} /Height:/{h=$2} END{if (v && wd > 100) printf "%s %sx%s\n", w, wd, h}'
    done
}

newest_window() { cmd_windows | tail -1 | cut -d' ' -f1; }

cmd_shot() {
    local out="${1:?usage: lab.sh shot FILE.png [WINDOW]}" w="${2:-$(newest_window)}"
    [[ -n "$w" ]] || die "no konsole window"
    DISPLAY="$DISPLAY_NUM" xwd -silent -id "$w" | convert xwd:- "$out"
    echo "$out"
}

cmd_keys() {
    local w; w="$(newest_window)"; [[ -n "$w" ]] || die "no konsole window"
    DISPLAY="$DISPLAY_NUM" xdotool windowfocus --sync "$w"
    DISPLAY="$DISPLAY_NUM" xdotool key --delay 120 "$@"
}

cmd_type() {
    local w; w="$(newest_window)"; [[ -n "$w" ]] || die "no konsole window"
    DISPLAY="$DISPLAY_NUM" xdotool windowfocus --sync "$w"
    DISPLAY="$DISPLAY_NUM" xdotool type --delay 50 "$1"
}

cmd_click() {
    local w; w="$(newest_window)"; [[ -n "$w" ]] || die "no konsole window"
    DISPLAY="$DISPLAY_NUM" xdotool windowfocus --sync "$w"
    DISPLAY="$DISPLAY_NUM" xdotool mousemove --window "$w" "$1" "$2" click 1
}

cmd_as() { as_user "$@"; }

cmd_tmux() { as_user tmux -L homelab "$@"; }

cmd_down() {
    need_root
    pkill -u "$LAB_USER" konsole 2>/dev/null || true
    as_user tmux -L homelab kill-server 2>/dev/null || true
    local spec name
    for spec in "${HOSTS[@]}" "off01"; do
        read -r name _ <<<"$spec"
        docker stop -t 1 "$name" >/dev/null 2>&1 || true
    done
    echo "konsoles closed, tmux server killed, hosts stopped. lab.sh up starts them again."
}

usage() {
    cat <<EOF
Usage: lab.sh COMMAND
  up                 everything below, in order, then check
  deps docker user hosts display install check
  konsole [CMD...]   open a konsole as $LAB_USER (optionally running CMD)
  windows            list konsole windows
  shot FILE [WIN]    screenshot the newest konsole window
  keys KEY...        send key presses, xdotool names (ctrl+b S Return)
  type TEXT          type text into the newest konsole window
  click X Y          click at window coordinates
  as CMD...          run a command as $LAB_USER with the lab environment
  tmux ARGS...       tmux -L homelab ARGS as $LAB_USER
  down               close konsoles, kill the sshl server, stop the hosts
EOF
}

main() {
    local cmd="${1:-}"; shift || true
    case "$cmd" in
        up|deps|docker|user|hosts|display|install|check|konsole|windows|shot|keys|type|click|as|tmux|down)
            "cmd_$cmd" "$@" ;;
        *) usage; [[ -z "$cmd" || "$cmd" == -h || "$cmd" == --help ]] || exit 1 ;;
    esac
}

main "$@"
