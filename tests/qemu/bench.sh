#!/usr/bin/env bash
#
# QEMU bench of the Archer A5 v4 / C50 v4 build: boots the malta/le build of the firmware (the
# same mipsel_24kc programs and kernel options as the router) with the CPU and RAM of the router
# and two network cards, and tests it from a LAN client and a WAN side in network namespaces.
#
#   docker/run.sh --bench tests/qemu/bench.sh                # our build (build.sh --qemu)
#   docker/run.sh --bench tests/qemu/bench.sh --official     # the official malta/le image
#   docker/run.sh --bench tests/qemu/bench.sh --shell        # stay in a shell of the LAN client
#
#   router (QEMU malta, 24KEc, 64 MiB)
#     LAN eth0 192.168.1.1 -- br-lan0 -- namespace "lan": client 192.168.1.10 (+ DHCP test)
#     WAN eth1             -- br-wan0 -- namespace "wan": the ISP 192.0.2.1 (DHCP, DNS, PPPoE
#                                         10.64.0.1, L2TP 10.65.0.1, WireGuard 10.99.0.1) and an
#                                         internet host 198.18.0.1 (iperf3)
#
# The internet host lives in 198.18.0.0/15 (RFC 2544) under an ordinary domain: dnsmasq treats
# the documentation ranges of RFC 5737 as private (the DNS rebind protection of OpenWrt drops
# answers that point there), and OpenWrt never forwards the special-use domains of RFC 6761
# (.test, .local, …; /usr/share/dnsmasq/rfc6761.conf). The ISP's DNS answers NXDOMAIN for the rest.
#
# A check that needs what the image does not carry (WireGuard, an NTP server switched on) is
# skipped with the reason. What QEMU cannot show: speed (TCG emulation), the radios
# (mac80211_hwsim instead), the switch and the flash layout of the router.
# Results: tmp/qemu-bench/results.txt; console.log has the serial console of the router.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"
W="$REPO/tmp/qemu-bench"
VERSION="$(sed -n 's/^VERSION_NUMBER:=.*,\([0-9][0-9.]*\))$/\1/p' include/version.mk)"
OFFICIAL_URL="https://downloads.openwrt.org/releases/$VERSION/targets/malta/le"
MEM=64
SOURCE=local
SHELL_AFTER=0
HOOK=""

usage() {
    echo "Usage: $0 [--official] [--mem <MiB>] [--shell] [--hook <file>]"
    echo "  --official   boot the official OpenWrt $VERSION malta/le image instead of our build"
    echo "  --mem <MiB>  RAM of the virtual router (default: $MEM, as the Archer C50 v4)"
    echo "  --shell      after the tests, open a shell in the LAN namespace (the router stays up)"
    echo "  --hook <file>  instead of the tests, run a bash snippet once the network is up (debugging);"
    echo "               it can use r (a command on the router), nsx lan|wan (a command on a side),"
    echo "               check <name> <test> and the t_* tests"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --official) SOURCE=official ;;
        --mem) MEM="${2:?--mem needs a size}"; shift ;;
        --shell) SHELL_AFTER=1 ;;
        --hook) HOOK="$(realpath "${2:?--hook needs a file}")"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
    shift
done

[ "$(id -u)" = 0 ] || { echo "Run as root with network rights: docker/run.sh --bench $0"; exit 1; }

# The bench runs as root, but tmp/ belongs to the build, which runs as the owner of the checkout:
# a root-owned tmp/ makes the build's prerequisite checks fail (they compile into tmp/).
OWNER="${HOST_UID:-$(stat -c %u "$REPO")}:${HOST_GID:-$(stat -c %g "$REPO")}"
mkdir -p "$REPO/tmp"
chown "$OWNER" "$REPO/tmp"
rm -rf "$W"
mkdir -p "$W"
RESULTS="$W/results.txt"
: > "$RESULTS"

log() { echo "[bench] $*"; }

# ---------------------------------------------------------------------------------------------
# Images: the kernel (vmlinux.elf) and the squashfs root file system on a virtual disk, so that
# the root file system sits outside the RAM as on the flash of the router.

if [ "$SOURCE" = official ]; then
    IMG_DIR="$REPO/tmp/qemu-official-$VERSION"
    mkdir -p "$IMG_DIR"
    for f in sha256sums "openwrt-$VERSION-malta-le-vmlinux.elf" "openwrt-$VERSION-malta-le-rootfs-squashfs.img.gz"; do
        [ -s "$IMG_DIR/$f" ] || curl -fsS -o "$IMG_DIR/$f" "$OFFICIAL_URL/$f"
    done
    (cd "$IMG_DIR" && grep -E "malta-le-(vmlinux\.elf|rootfs-squashfs\.img\.gz)$" sha256sums | sha256sum -c --quiet -)
    chown -R "$OWNER" "$IMG_DIR"
    KERNEL="$IMG_DIR/openwrt-$VERSION-malta-le-vmlinux.elf"
    ROOTFS_GZ="$IMG_DIR/openwrt-$VERSION-malta-le-rootfs-squashfs.img.gz"
else
    KERNEL="$(ls bin/targets/malta/le/openwrt*malta-le-vmlinux.elf 2>/dev/null | head -n 1 || true)"
    ROOTFS_GZ="$(ls bin/targets/malta/le/openwrt*malta-le-rootfs-squashfs.img.gz 2>/dev/null | head -n 1 || true)"
    if [ -z "$KERNEL" ] || [ -z "$ROOTFS_GZ" ]; then
        echo "No QEMU build in bin/targets/malta/le: run docker/run.sh ./build.sh --qemu, or use --official."
        exit 1
    fi
fi
gunzip -c "$ROOTFS_GZ" > "$W/rootfs.img"
log "Kernel: $KERNEL"
log "Root file system: $ROOTFS_GZ"

# ---------------------------------------------------------------------------------------------
# Network: two namespaces held by sleeping processes, bridged to the tap devices of QEMU.

NS_PIDS=()
ns_create() {
    unshare --net -- sleep infinity &
    echo $! > "$W/ns-$1.pid"
    NS_PIDS+=($!)
    sleep 0.2
    nsx "$1" ip link set lo up
}
nsx() {
    local ns="$1"
    shift
    nsenter --net="/proc/$(cat "$W/ns-$ns.pid")/ns/net" -- "$@"
}

cleanup() {
    set +e
    [ -f "$W/qemu.pid" ] && kill "$(cat "$W/qemu.pid")" 2>/dev/null
    for p in "$W"/*.pid; do
        [ -f "$p" ] && kill "$(cat "$p")" 2>/dev/null
    done
    for pid in "${NS_PIDS[@]}"; do kill "$pid" 2>/dev/null; done
    for l in tap-lan tap-wan v-lan v-wan br-lan0 br-wan0; do ip link del "$l" 2>/dev/null; done
    chown -R "$OWNER" "$W" 2>/dev/null
}
trap cleanup EXIT

for side in lan wan; do
    ns_create "$side"
    ip link add "br-${side}0" type bridge
    ip tuntap add dev "tap-$side" mode tap
    ip link add "v-$side" type veth peer name eth0 netns "$(cat "$W/ns-$side.pid")"
    ip link set "tap-$side" master "br-${side}0"
    ip link set "v-$side" master "br-${side}0"
    for l in "br-${side}0" "tap-$side" "v-$side"; do ip link set "$l" up; done
    nsx "$side" ip link set eth0 up
done

# LAN client: a static address for the management of the router; the DHCP test runs apart
nsx lan ip addr add 192.168.1.10/24 dev eth0
nsx lan ip route add default via 192.168.1.1

# WAN side: the ISP (DHCP and DNS) and a host "on the internet" behind it
nsx wan ip addr add 192.0.2.1/24 dev eth0
nsx wan ip addr add 198.18.0.1/32 dev lo
wan_dnsmasq_start() {
    local lo="$1" hi="$2"
    if [ -f "$W/dnsmasq-wan.pid" ]; then
        kill "$(cat "$W/dnsmasq-wan.pid")" 2>/dev/null || true
        sleep 0.5
    fi
    rm -f "$W/wan.leases" "$W/dnsmasq-wan.pid"
    nsx wan dnsmasq --no-resolv --no-hosts --interface=eth0 --bind-interfaces --listen-address=192.0.2.1 \
        --dhcp-range="$lo,$hi,255.255.255.0,1h" \
        --dhcp-option=option:router,192.0.2.1 --dhcp-option=option:dns-server,192.0.2.1 \
        --address=/openwrt-bench.net/198.18.0.1 --local=/#/ --dhcp-leasefile="$W/wan.leases" --pid-file="$W/dnsmasq-wan.pid"
}
wan_dnsmasq_start 192.0.2.100 192.0.2.150
nsx wan iperf3 -s -D -B 198.18.0.1 --pidfile "$W/iperf3.pid"

# PPPoE server of the ISP (pppd needs /dev/ppp, passed by docker/run.sh --bench)
PPPOE_OK=0
if [ -c /dev/ppp ] && command -v pppoe-server >/dev/null; then
    mkdir -p /etc/ppp
    printf '"bench" * "bench" *\n' > /etc/ppp/pap-secrets
    printf 'require-pap\nlcp-echo-interval 5\nlcp-echo-failure 3\nms-dns 192.0.2.1\nmtu 1492\nmru 1492\n' \
        > "$W/pppoe-server-options"
    if nsx wan pppoe-server -I eth0 -L 10.64.0.1 -R 10.64.0.10 -N 4 -O "$W/pppoe-server-options" \
            -X "$W/pppoe-server.pid" 2> "$W/pppoe-server.log"; then
        PPPOE_OK=1
    fi
fi

# L2TP LNS of the ISP (pppd needs /dev/ppp, passed by docker/run.sh --bench)
L2TP_OK=0
if [ -c /dev/ppp ] && command -v xl2tpd >/dev/null; then
    mkdir -p /etc/ppp
    printf '"bench" * "bench" *\n' > /etc/ppp/pap-secrets
    printf '"bench" * "bench" *\n' > /etc/ppp/chap-secrets
    cat <<EOF > "$W/xl2tpd-wan.options"
require-pap
refuse-chap
refuse-mschap
refuse-mschap-v2
refuse-eap
lcp-echo-interval 5
lcp-echo-failure 3
ms-dns 192.0.2.1
mtu 1400
mru 1400
EOF
    cat <<EOF > "$W/xl2tpd-wan.conf"
[global]
listen-addr = 192.0.2.1
[lns default]
ip range = 10.65.0.10-10.65.0.20
local ip = 10.65.0.1
require pap = yes
require chap = no
refuse chap = yes
require authentication = yes
pppoptfile = $W/xl2tpd-wan.options
EOF
    : > "$W/xl2tpd-wan.secrets"
    nsx wan xl2tpd -c "$W/xl2tpd-wan.conf" -s "$W/xl2tpd-wan.secrets" \
        -p "$W/xl2tpd-wan.pid" -C "$W/xl2tpd-wan.ctl" -D > "$W/xl2tpd-wan.log" 2>&1 &
    L2TP_PID=$!
    sleep 0.5
    if kill -0 "$L2TP_PID" 2>/dev/null; then
        L2TP_OK=1
    fi
fi

# ---------------------------------------------------------------------------------------------
# The router: MT7628AN = MIPS 24KEc, 64 MiB. The first -nic is malta's onboard card (PCI slot
# 0x0b) and becomes eth0 (LAN, the default of OpenWrt); the second sits in slot 0x12 and becomes
# eth1 (seen in the console of the first run).

LAN_MAC=52:54:00:a5:00:01
WAN_MAC=52:54:00:a5:00:02
log "Booting the router (malta, -cpu 24KEc, -m $MEM)..."
qemu-system-mipsel -M malta -cpu 24KEc -m "$MEM" \
    -kernel "$KERNEL" -append "root=/dev/sda rootfstype=squashfs rootwait console=ttyS0" \
    -drive file="$W/rootfs.img",format=raw,if=ide \
    -nic tap,ifname=tap-lan,script=no,downscript=no,model=pcnet,mac=$LAN_MAC \
    -nic tap,ifname=tap-wan,script=no,downscript=no,model=pcnet,mac=$WAN_MAC \
    -display none -monitor none -serial file:"$W/console.log" \
    -daemonize -pidfile "$W/qemu.pid"

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
          -o BatchMode=yes -o ConnectTimeout=5)
r() { nsx lan ssh "${SSH_OPTS[@]}" root@192.168.1.1 "$@"; }

wait_ssh() {
    local start
    start=$(date +%s)
    until r true 2>/dev/null; do
        if [ $(( $(date +%s) - start )) -gt 300 ]; then
            echo "The router did not answer over SSH within 300 s; last lines of the console:"
            tail -n 30 "$W/console.log"
            exit 1
        fi
        sleep 5
    done
    echo $(( $(date +%s) - start ))
}

# Waits up to $1 seconds for the command to succeed
wait_for() {
    local timeout="$1" start
    shift
    start=$(date +%s)
    # without pipefail: "… | grep -q" would fail when grep stops reading early
    until (set +o pipefail; "$@") >/dev/null 2>&1; do
        [ $(( $(date +%s) - start )) -lt "$timeout" ] || return 1
        sleep 3
    done
}

BOOT_SECS="$(wait_ssh)"
log "SSH up after $BOOT_SECS s"

# The cards must be where the bench expects them
LANDEV="$(r "grep -l -i '$LAN_MAC' /sys/class/net/eth*/address" | cut -d/ -f5)"
WANDEV="$(r "grep -l -i '$WAN_MAC' /sys/class/net/eth*/address" | cut -d/ -f5)"
log "LAN card: $LANDEV, WAN card: $WANDEV"

# malta has no network layout of its own: put the WAN card into the wan interface (and wan6, as
# config_generate does on the router when the kernel has IPv6)
wan_dhcp() {
    r "uci -q get network.wan >/dev/null || uci set network.wan=interface
       uci set network.wan.device='$WANDEV'; uci set network.wan.proto=dhcp
       uci -q delete network.wan.username; uci -q delete network.wan.password
       if [ -d /proc/sys/net/ipv6 ] && ! uci -q get network.wan6 >/dev/null; then
           uci set network.wan6=interface; uci set network.wan6.device='$WANDEV'; uci set network.wan6.proto=dhcpv6
       fi
       uci commit network; /etc/init.d/network reload" >/dev/null
}
wan_up() { r 'ubus call network.interface.wan status' | grep -q '"up": true'; }
wan_dhcp
wait_for 60 wan_up || true


# ---------------------------------------------------------------------------------------------
# Tests

FAILS=0
SKIPS=0
check() {
    local name="$1" out
    shift
    # without pipefail: "… | grep -q" would fail when grep stops reading early, or when the
    # command before it fails although its output matched
    if out="$(set +o pipefail; "$@" 2>&1)"; then
        echo "PASS  $name" | tee -a "$RESULTS"
    else
        echo "FAIL  $name" | tee -a "$RESULTS"
        echo "$out" | tail -n 5 | sed 's/^/      /' | tee -a "$RESULTS"
        FAILS=$((FAILS + 1))
    fi
}
skip() { echo "SKIP  $1: $2" | tee -a "$RESULTS"; SKIPS=$((SKIPS + 1)); }
info() { echo "INFO  $*" | tee -a "$RESULTS"; }
section() { echo "----  $*" | tee -a "$RESULTS"; }

wan_addr() { r 'ubus call network.interface.wan status' | sed -n 's/.*"address": "\([0-9.]*\)".*/\1/p' | head -n 1; }
has() { r "command -v $1" >/dev/null 2>&1; }

# --- System
t_lan_is_eth0() { [ "$LANDEV" = eth0 ]; }
t_no_unknown_symbols() { ! r dmesg | grep -i 'unknown symbol'; }
t_kernel_clean() { ! r dmesg | grep -E -i 'Oops|BUG:|Kernel panic|Call Trace|segfault'; }
t_uci_defaults_done() { [ -z "$(r 'ls /etc/uci-defaults')" ]; }
t_router_wifi_drivers() { r 'lsmod' | grep -q '^mt7603e' && r 'lsmod' | grep -q '^mt76x2e'; }
# The delay interrupts of both radios by default (mt76 patches 0326 and 0327: delay_int 0x9032880a)
t_mt76_delay_int() { [ "$(r 'cat /sys/module/mt76x02_lib/parameters/delay_int')" = 2419230730 ] &&
    [ "$(r 'cat /sys/module/mt7603e/parameters/delay_int')" = 2419230730 ]; }
# The 5 GHz TX optimization switches by default (mt76 patches 0328-0331: tx_opt 0xf)
t_mt76_tx_opt() { [ "$(r 'cat /sys/module/mt76x02_lib/parameters/tx_opt')" = 15 ]; }
# GRO off on every network device by the kernel of the build (hack patch 601), without any
# configuration, and threaded NAPI on eth0 (/etc/init.d/a5v4-threaded-napi; on malta eth0 comes
# from a module, on the router from a built-in driver); netifd's device status reads the GRO flag
# from the kernel
t_gro_no_config() { ! r 'uci -q show network' | grep -q '\.gro='; }
dev_gro_off() {
    r "ubus call network.device status '{\"name\":\"$1\"}'" | grep -q '"gro": false' || { echo "$1: GRO not off"; return 1; }
}
t_gro_off_eth0() { dev_gro_off eth0; }
t_threaded_napi() {
    [ "$(r 'cat /sys/class/net/eth0/threaded')" = 1 ] || { echo "eth0 threaded: $(r 'cat /sys/class/net/eth0/threaded')"; return 1; }
    r 'grep -l "^napi/eth0-" /proc/[0-9]*/comm' | grep -q . || { echo "no napi/eth0 thread"; return 1; }
}
# Every Wi-Fi interface: the access point (radio0) and the client (radio1) of the bench
t_gro_off_wifi() {
    local devs d
    devs="$(r 'iw dev' | awk '$1 == "Interface" {print $2}')"
    [ -n "$devs" ] || { echo "no Wi-Fi interface"; return 1; }
    for d in $devs; do dev_gro_off "$d" || return 1; done
}
t_gro_off_wg() { dev_gro_off wg0; }
# A device section with gro 1 turns GRO on (set before the reboot at the end, on the WAN card)
t_gro_on_by_section() {
    r "ubus call network.device status '{\"name\":\"$WANDEV\"}'" | grep -q '"gro": true' || { echo "$WANDEV: GRO not on"; return 1; }
}

# --- LAN services
t_lan_dhcp() { nsx lan udhcpc -i eth0 -n -q -f -t 5 -x hostname:benchclient -s /bin/true; }
t_dns_router_name() { nsx lan dig +short +time=3 +tries=2 "$(r 'uci get system.@system[0].hostname').lan" @192.168.1.1 | grep -qx 192.168.1.1; }
t_dns_dhcp_client() { nsx lan dig +short +time=3 +tries=2 benchclient.lan @192.168.1.1 | grep -q '^192\.168\.1\.'; }
# DNS of the internet: dnsmasq asks the WAN's DNS (with https-dns-proxy in the image, after
# t_doh_off)
t_dns() {
    local a
    a="$(nsx lan dig +short +time=3 +tries=2 host.openwrt-bench.net @192.168.1.1)"
    [ "$a" = 198.18.0.1 ] && return 0
    echo "the router answered: '$a'"
    echo "the ISP's DNS through NAT: '$(nsx lan dig +short +time=3 +tries=1 host.openwrt-bench.net @192.0.2.1)'"
    echo "resolv.conf.auto: $(r 'cat /tmp/resolv.conf.d/resolv.conf.auto' | tr '\n' ' ')"
    r 'logread | grep -i dnsmasq | tail -n 2'
    return 1
}
# One SNTP request (mode 3); a server answers in mode 4 with a transmit time
t_ntp_server() {
    nsx lan python3 -I -c '
import socket, struct, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(5)
s.sendto(b"\x23" + 47 * b"\0", ("192.168.1.1", 123))
data = s.recv(512)
mode, seconds = data[0] & 7, struct.unpack("!I", data[40:44])[0]
print("mode", mode, "transmit", seconds)
sys.exit(0 if mode == 4 and seconds else 1)'
}
# Without a session LuCI answers with its login form (HTTP 403)
t_luci_page() { nsx lan curl -s --max-time 60 http://192.168.1.1/cgi-bin/luci/ | grep -q 'luci_password'; }
# check() runs each test in a subshell, so every test that needs a session logs in itself
luci_session() {
    nsx lan curl -s --max-time 60 http://192.168.1.1/ubus -d \
        '{"jsonrpc":"2.0","id":1,"method":"call","params":["00000000000000000000000000000000","session","login",{"username":"root","password":""}]}' \
        | sed -n 's/.*"ubus_rpc_session": *"\([0-9a-f]*\)".*/\1/p'
}
t_luci_login() { [ -n "$(luci_session)" ]; }
# The login page in the language the browser asks for
t_luci_ru() {
    nsx lan curl -s --max-time 60 -H 'Accept-Language: ru' http://192.168.1.1/cgi-bin/luci/ \
        | grep -q -e 'lang="ru"' && nsx lan curl -s --max-time 60 -H 'Accept-Language: ru' \
        http://192.168.1.1/cgi-bin/luci/ | grep -q 'Пароль'
}
t_luci_rpc() {
    local session
    session="$(luci_session)"
    nsx lan curl -s --max-time 60 http://192.168.1.1/ubus -d \
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"call\",\"params\":[\"$session\",\"system\",\"board\",{}]}" \
        | grep -q '"kernel"'
}

# --- WAN and routing
t_wan_dhcp() { wan_addr | grep -q '^192\.0\.2\.1[0-9][0-9]$'; }
t_fw4_inet() { r 'nft list tables' | grep -q 'table inet fw4'; }
t_nat() { nsx lan ping -c 3 -W 2 198.18.0.1; }
nat_once() { nsx lan ping -c 1 -W 2 198.18.0.1; }
# After a change of the WAN, fw4 needs a moment to move the zone to the new device
t_nat_settled() { wait_for 60 nat_once && t_nat; }
t_router_internet() { r 'ping -c 2 -W 2 198.18.0.1' && r 'nslookup host.openwrt-bench.net 127.0.0.1' | grep -q 198.18.0.1; }
t_wan_closed() {
    local addr port
    addr="$(wan_addr)"
    [ -n "$addr" ] || return 1
    for port in 22 80; do
        if nsx wan timeout 5 bash -c "exec 3<>/dev/tcp/$addr/$port" 2>/dev/null; then
            echo "port $port of the WAN address $addr is open"
            return 1
        fi
    done
}
# The WAN zone of the image drops (first-boot defaults): a closed port gives no answer at all, and
# ping still does (OpenWrt's Allow-Ping rule)
t_wan_stealth() {
    local addr
    addr="$(wan_addr)"
    [ -n "$addr" ] || return 1
    nsx wan ping -c 2 -W 2 "$addr" >/dev/null || { echo "no answer to ping on $addr"; return 1; }
    nsx wan python3 -c '
import socket, sys
addr = sys.argv[1]
try:
    socket.create_connection((addr, 22), timeout=3)
except TimeoutError:
    sys.exit(0)
except Exception as e:
    print("TCP 22 of", addr, "answered:", e)
sys.exit(1)' "$addr"
}
t_offload() { r 'cat /proc/net/nf_conntrack' | grep -q OFFLOAD; }
# fw4 rejects on the WAN zone: a closed TCP port answers with a reset, a closed UDP port with an
# ICMP port unreachable (the reject expression of the inet table)
reject_probe() { # $1 = tcp or udp
    local addr
    addr="$(wan_addr)"
    [ -n "$addr" ] || return 1
    nsx wan python3 -c '
import socket, sys
proto, addr = sys.argv[1], sys.argv[2]
try:
    if proto == "tcp":
        socket.create_connection((addr, 22), timeout=3)
    else:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(3)
        s.connect((addr, 9))
        s.send(b"bench")
        s.recv(1)
except ConnectionRefusedError:
    sys.exit(0)
except Exception as e:
    print(proto, addr, e)
sys.exit(1)' "$1" "$addr"
}
t_reject_tcp() { reject_probe tcp; }
t_reject_udp() { reject_probe udp; }
# The WAN zone of the image drops (first-boot defaults); a rule that rejects two ports from the WAN
# keeps the reject expression of the inet table under test
reject_rule() { # $1 = add or delete
    if [ "$1" = add ]; then
        r "uci set firewall.benchreject=rule; uci set firewall.benchreject.name=bench-reject
           uci set firewall.benchreject.src=wan; uci set firewall.benchreject.proto='tcp udp'
           uci set firewall.benchreject.dest_port='22 9'; uci set firewall.benchreject.target=REJECT
           uci commit firewall; fw4 -q reload" >/dev/null
    else
        r "uci -q delete firewall.benchreject; uci commit firewall; fw4 -q reload" >/dev/null
    fi
}
# The defaults of 99-a5v4-defaults: flow offloading, the NTP server, the WAN zone dropping, no IPv6
# rules, the marker
t_first_boot_defaults() {
    local fw
    fw="$(r 'uci show firewall; uci -q get system.ntp.enable_server; uci -q get a5v4.defaults.applied')"
    echo "$fw" | grep -qxF "firewall.@defaults[0].flow_offloading='1'" || { echo "no flow offloading"; return 1; }
    echo "$fw" | grep -qxF "firewall.@defaults[0].drop_invalid='1'" || { echo "invalid packets not dropped"; return 1; }
    [ "$(r 'uci -q get dropbear.@dropbear[0].Interface')" = lan ] || { echo "SSH not bound to the LAN"; return 1; }
    local rule
    for rule in Allow-DHCP-Renew Allow-Ping Allow-IGMP Allow-IPSec-ESP Allow-ISAKMP; do
        echo "$fw" | grep -q "\.name='$rule'$" || { echo "rule $rule is gone"; return 1; }
    done
    local wan
    wan="$(echo "$fw" | sed -n "s/^firewall\.\([^.]*\)\.name='wan'$/\1/p" | head -n 1)"
    echo "$fw" | grep -qxF "firewall.$wan.input='DROP'" || { echo "WAN input does not drop"; return 1; }
    echo "$fw" | grep -qxF "firewall.$wan.forward='DROP'" || { echo "WAN forward does not drop"; return 1; }
    echo "$fw" | grep -qxF "firewall.@defaults[0].input='DROP'" || { echo "default input does not drop"; return 1; }
    echo "$fw" | grep -qxF "firewall.@defaults[0].forward='DROP'" || { echo "default forward does not drop"; return 1; }
    [ "$(echo "$fw" | tail -n 2 | tr '\n' ' ')" = "1 1 " ] || { echo "NTP server or marker missing"; return 1; }
}
# IPv6 in the LAN: odhcpd announces the ULA prefix of the router, the LAN client takes an address
# by SLAAC and reaches the router over IPv6
lan_ula() { nsx lan ip -6 addr show scope global | grep -q 'inet6 fd'; }
t_ipv6_lan() {
    wait_for 60 lan_ula || { nsx lan ip -6 addr; return 1; }
    local ula
    ula="$(r 'ip -6 addr show dev br-lan scope global' | sed -n 's/.*inet6 \(fd[0-9a-f:]*\)\/.*/\1/p' | head -n 1)"
    [ -n "$ula" ] || { echo "br-lan has no ULA"; return 1; }
    nsx lan ping -6 -c 2 -W 2 "$ula" > /dev/null
}
# The WAN side asks for IPv6 with odhcp6c (the bench offers none), and fw4 has its IPv6 rules
t_ipv6_wan_fw() {
    r 'pidof odhcp6c' > /dev/null || { echo "no odhcp6c"; return 1; }
    r 'nft list ruleset' | grep -q icmpv6 || { echo "no IPv6 rules in fw4"; return 1; }
}
# DoH: https-dns-proxy runs, dnsmasq asks only its instances (noresolv, as the package sets it),
# LAN clients are not forced onto it
t_doh_setup() {
    local d
    r 'pidof https-dns-proxy' > /dev/null || { echo "https-dns-proxy does not run"; return 1; }
    d="$(r 'uci show dhcp; uci -q get https-dns-proxy.config.force_dns')"
    echo "$d" | grep -q "server=.*'127.0.0.1#5053'" || { echo "dnsmasq does not use the proxy"; return 1; }
    echo "$d" | grep -q "^dhcp\..*\.noresolv='1'" || { echo "dnsmasq also asks the WAN's DNS"; return 1; }
    [ "$(echo "$d" | tail -n 1)" = 0 ] || { echo "force_dns is on"; return 1; }
    # HTTP/2, the default of https-dns-proxy: libcurl must have it, or every request logs an error
    r 'curl -V' | grep -q 'HTTP2' || { echo "libcurl without HTTP/2"; return 1; }
    ! r 'logread' | grep -q "HTTP/2 version failed" || { echo "HTTP/2 errors in the log"; return 1; }
}
# DoH turned off as README describes: dnsmasq asks the WAN's DNS again, and no address of a proxy
# instance is left among its servers (feeds-patches/packages/0001)
dns_inet_once() { nsx lan dig +short +time=2 +tries=1 host.openwrt-bench.net @192.168.1.1 | grep -qx 198.18.0.1; }
t_doh_off() {
    local d
    r '/etc/init.d/https-dns-proxy stop; /etc/init.d/https-dns-proxy disable' > /dev/null 2>&1
    ! r 'pidof https-dns-proxy' > /dev/null || { echo "https-dns-proxy still runs"; return 1; }
    d="$(r 'uci show dhcp')"
    ! echo "$d" | grep -q "^dhcp\..*\.noresolv='1'" || { echo "noresolv still set"; return 1; }
    ! echo "$d" | grep "127\.0\.0\.1#505" || { echo "proxy addresses left in dnsmasq"; return 1; }
    wait_for 30 dns_inet_once || true
}
# The VPN modules load when a tunnel is created, not at boot
mod_loaded() { r "grep -q '^$1 ' /proc/modules"; }
t_wg_mod_absent() { ! mod_loaded wireguard; }
t_wg_mod_loaded() { mod_loaded wireguard; }
t_awg_mod_absent() { ! mod_loaded amneziawg; }
t_awg_mod_loaded() { mod_loaded amneziawg; }
# Two AmneziaWG interfaces of the router with the same obfuscation, through 127.0.0.1
awg_obf_handshake() { r 'awg show awg2 latest-handshakes' | awk '$2 > 0' | grep -q .; }
t_awg_obfuscated() { wait_for 60 awg_obf_handshake; }
# Without IPv6 in the kernel config_generate writes no IPv6 settings
t_no_ipv6_config() { ! r 'uci -q get network.wan6; uci -q get network.globals.ula_prefix; uci -q get network.lan.ip6assign' | grep .; }

offload_run() { # $1 = name of the check
    r "uci set firewall.@defaults[0].flow_offloading=1; uci commit firewall; fw4 -q reload" >/dev/null
    nsx lan iperf3 -c 198.18.0.1 -t 10 > "$W/iperf3-$2.log" 2>&1 &
    local pid=$!
    sleep 6
    check "$1" t_offload
    wait "$pid" || true
    info "iperf3 LAN -> internet ($2): $(grep -E 'sender$' "$W/iperf3-$2.log" | awk '{print $7, $8}') (TCG, not the router's speed)"
}

# --- Firmware updates (luci-app-fwupdate). At idle the checker sleeps and has downloaded nothing.
# A test server on the internet host, set in the hidden option url, serves release.json, written
# by the release script of the workflow, and an image: the first 3 MiB of the bench's own malta
# image. The whole one (5.3 MB) needs 11.5 MB of MemAvailable with the margin, about what the bench
# has at this point (11.3-11.6 MB in a run): the malta kernel leaves 4 MB less RAM than the router's.
# The router runs as release r1 of a made-up series: r2 (marked reset) and r3 (auto) are newer.
FWU_SRV="$W/fwu-srv"
FWU_URL=http://198.18.0.1:8080
FWU_TAG=v25.12.5-a5v4-r3
FWU_IMG="$W/openwrt-malta-le-bench.bin"
# Anchored: the shell that runs a command over SSH has the pattern in its own command line
fwu_daemon() { r "pgrep -f '^/bin/sh /usr/libexec/fwupdate-daemon'"; }
fwu_busy() { r "pgrep -f '^/usr/bin/ucode /usr/libexec/fwupdate [cd]'" | grep -q .; }
fwu_idle() { ! fwu_busy; }
# Private and resident memory and page tables of the checker and its child (asleep: sleep)
fwu_daemon_mem() {
    r 'd=$(pgrep -f "^/bin/sh /usr/libexec/fwupdate-daemon" | head -n 1)
       for p in $d $(grep -l "^PPid:[[:space:]]*$d\$" /proc/[0-9]*/status 2>/dev/null | cut -d/ -f3); do
           printf "%s %s/%s kB, page tables %s kB; " "$(cat /proc/$p/comm)" \
               "$(sed -n "s/^RssAnon:[[:space:]]*\([0-9]*\).*/\1/p" /proc/$p/status)" \
               "$(sed -n "s/^VmRSS:[[:space:]]*\([0-9]*\).*/\1/p" /proc/$p/status)" \
               "$(sed -n "s/^VmPTE:[[:space:]]*\([0-9]*\).*/\1/p" /proc/$p/status)"
       done'
}
t_fwu_idle() {
    fwu_daemon | grep -q . || { echo "the checker does not run"; return 1; }
    ! r 'ls /tmp/fwupdate/firmware.bin /tmp/fwupdate/firmware.part /tmp/fwupdate/download.json' 2>/dev/null
}
# git refuses a checkout of another owner (the bench runs as root)
bench_git() { GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*' "$@"; }
# release.json of FWU_TAG with the last two commits as its changes, carrying over a made-up
# release.json of r2 and r1
fwu_release() {
    local img
    img="$FWU_SRV/releases/download/$FWU_TAG/$(basename "$FWU_IMG")"
    mkdir -p "$(dirname "$img")"
    [ -f "$FWU_IMG" ] || head -c 3145728 "$ROOTFS_GZ" > "$FWU_IMG"
    cp "$FWU_IMG" "$img"
    cat > "$FWU_SRV/prev-release.json" <<EOF
{"tag": "v25.12.5-a5v4-r2", "releases": [
 {"tag": "v25.12.5-a5v4-r2", "date": "2026-11-02T00:00:00Z", "url": "$FWU_URL/r2", "upgrade": "reset",
  "note": {"en": "Bench: the settings cannot be kept.", "ru": "Стенд: настройки не сохраняются."},
  "changes": [{"commit": "0000000000", "subject": "bench: an earlier release"}]},
 {"tag": "v25.12.5-a5v4-r1", "date": "2026-11-01T00:00:00Z", "url": "$FWU_URL/r1", "upgrade": "auto", "changes": []}]}
EOF
    bench_git python3 .github/scripts/a5v4-release-json.py --tag "$FWU_TAG" \
        --commit "$(bench_git git rev-parse HEAD)" --repo-url "$FWU_URL" --image "$img" \
        --prev-tag HEAD~2 --prev-json "$FWU_SRV/prev-release.json" > "$FWU_SRV/release.json"
}
fwu_serve() {
    nsx wan python3 -m http.server 8080 --bind 198.18.0.1 --directory "$FWU_SRV" >> "$W/fwu-srv.log" 2>&1 &
    echo $! > "$W/fwu-srv.pid"
    fwu_up() { r "curl -fsS -o /dev/null $FWU_URL/release.json"; }
    wait_for 20 fwu_up
}
fwu_stop() {
    [ -f "$W/fwu-srv.pid" ] && kill "$(cat "$W/fwu-srv.pid")" 2>/dev/null
    rm -f "$W/fwu-srv.pid"
}
# release.json changed on the server: check again, then download
fwu_download() { r '/usr/libexec/fwupdate check >/dev/null 2>&1; /usr/libexec/fwupdate download; echo "rc=$?"; cat /tmp/fwupdate/download.json'; }
fwu_meminfo() { r "grep -E '^(MemFree|MemAvailable|Cached|Shmem):' /proc/meminfo" | tr -s ' \n' ' '; }
fwu_json() { # $1 = file on the router, $2 = a Python expression of s that must hold
    r "cat $1" | python3 -c 'import json, sys
s = json.load(sys.stdin)
if not eval("(" + sys.argv[1] + ")"):
    print(json.dumps(s)[:600])
    sys.exit(1)' "$2"
}
# The status lists both newer releases with their changes, newest first, and the method of the
# update is the strictest of them (reset)
t_fwu_check() {
    r "uci set fwupdate.settings.url='$FWU_URL/release.json'; uci commit fwupdate
       /usr/libexec/fwupdate check" || return 1
    fwu_json /tmp/fwupdate/status.json \
        's["update"] is True and s["local"] is False and s["method"] == "reset" and s["error"] is None
         and [x["tag"] for x in s["releases"]] == ["'"$FWU_TAG"'", "v25.12.5-a5v4-r2"]
         and len(s["releases"][0]["changes"]) == 2 and s["releases"][0]["upgrade"] == "auto"
         and s["releases"][1]["changes"][0]["subject"] == "bench: an earlier release"
         and s["releases"][1]["note"]["ru"] and s["latest"]["sysupgrade"]["size"] > 1000000'
}
# What the Overview page asks on every refresh, as LuCI asks it (session, ACL)
t_fwu_notice() {
    local session
    session="$(luci_session)"
    nsx lan curl -s --max-time 60 http://192.168.1.1/ubus -d \
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"call\",\"params\":[\"$session\",\"luci.fwupdate\",\"notice\",{}]}" \
        | grep -q "\"tag\": *\"$FWU_TAG\""
}
# Size and SHA256 match; then sysupgrade of malta refuses the image (no platform_check_image)
t_fwu_download_malta() {
    fwu_download | grep -q '^rc=1' || return 1
    fwu_json /tmp/fwupdate/download.json 's["error"] == "invalid" and "not implemented" in s.get("detail", "")' &&
        ! r 'ls /tmp/fwupdate/firmware.bin /tmp/fwupdate/firmware.part' 2>/dev/null
}
# With a platform check that accepts it, the image is ready to install; discard frees it
t_fwu_download_ready() {
    local sum
    r 'echo "platform_check_image() { return 0; }" > /lib/upgrade/zz-bench.sh' || return 1
    fwu_meminfo > "$W/fwu-mem.txt"
    fwu_download | grep -q '^rc=0' || { r 'rm -f /lib/upgrade/zz-bench.sh'; return 1; }
    r 'rm -f /lib/upgrade/zz-bench.sh'
    sum="$(sha256sum < "$FWU_IMG" | cut -d' ' -f1)"
    fwu_json /tmp/fwupdate/download.json \
        's["state"] == "ready" and s["valid"] is True and s["allow_backup"] is True and s["sha256"] == "'"$sum"'"
         and "before_drop" in s["mem"] and s["mem"]["available"] >= s["mem"]["needed"]' || return 1
    [ "$(r 'sha256sum /tmp/fwupdate/firmware.bin' | cut -d' ' -f1)" = "$sum" ] || return 1
    echo "; with the image in /tmp: $(fwu_meminfo)" >> "$W/fwu-mem.txt"
    r 'ubus call luci.fwupdate discard' | grep -q '"ok"' && ! r 'ls /tmp/fwupdate/firmware.bin' 2>/dev/null
}
t_fwu_bad_checksum() {
    fwu_release
    sed -i 's/"sha256": "[0-9a-f]*"/"sha256": "'"$(printf '%064d' 0)"'"/' "$FWU_SRV/release.json"
    fwu_download | grep -q '^rc=1' || return 1
    fwu_json /tmp/fwupdate/download.json 's["error"] == "checksum"' &&
        ! r 'ls /tmp/fwupdate/firmware.bin /tmp/fwupdate/firmware.part' 2>/dev/null
}
# An image larger than MemAvailable minus the margin is not downloaded at all, also after the drop
# of the page cache, and without waiting for memory that the drop cannot free
t_fwu_no_memory() {
    fwu_release
    sed -i 's/"size": [0-9]*/"size": 67108864/' "$FWU_SRV/release.json"
    : > "$W/fwu-srv.log"
    fwu_download | grep -q '^rc=1' || return 1
    fwu_json /tmp/fwupdate/download.json 's["error"] == "space" and s["mem"]["available"] < s["mem"]["needed"]
        and "before_drop" in s["mem"] and s["mem"]["waited"] == 0' &&
        ! grep -q 'GET /releases/' "$W/fwu-srv.log"
}
# The test server stopped: no connection (exit code 2), and the page keeps what the last check found
t_fwu_no_connection() {
    fwu_stop
    r '/usr/libexec/fwupdate check; [ $? = 2 ]' || return 1
    fwu_json /tmp/fwupdate/status.json 's["error"] == "network" and s["latest"]["tag"] == "'"$FWU_TAG"'"'
}
fwu_cleanup() {
    fwu_stop
    r 'uci -q delete fwupdate.settings.url; uci commit fwupdate; cp /rom/etc/a5v4_release /etc/a5v4_release
       cp /rom/usr/lib/os-release /usr/lib/os-release
       rm -rf /tmp/fwupdate /lib/upgrade/zz-bench.sh; /etc/init.d/fwupdate start' >/dev/null
}
# The release name in the firmware version, which 99-a5v4-defaults sets on every flash: LuCI's
# Overview shows the description of "ubus call system board"
board_desc() { r 'ubus call system board' | sed -n 's/.*"description": "\(.*\)".*/\1/p'; }
# The bench image is a local build: no release, the version as built
t_relname_local() {
    r 'cmp -s /usr/lib/os-release /rom/usr/lib/os-release' || { echo "os-release changed"; return 1; }
    board_desc | grep -q '^OpenWrt ' && ! board_desc | grep -q 'a5v4-r'
}
# With the release r1 in /etc/a5v4_release, as after a flash; a second run does not add it again
t_relname_release() {
    r 'sh /rom/etc/uci-defaults/99-a5v4-defaults' >/dev/null 2>&1
    board_desc | grep -q '^OpenWrt .* a5v4-r1$' || { board_desc; return 1; }
}
t_relname_once() {
    r 'sh /rom/etc/uci-defaults/99-a5v4-defaults' >/dev/null 2>&1
    [ "$(board_desc | grep -o 'a5v4-r1' | wc -l)" = 1 ] || { board_desc; return 1; }
}

# --- PPPoE
wan_pppoe() {
    r "uci set network.wan.proto=pppoe; uci set network.wan.username=bench; uci set network.wan.password=bench
       uci commit network; /etc/init.d/network reload" >/dev/null
}
pppoe_addr() { r 'ubus call network.interface.wan status' | grep -q '"address": "10\.64\.0\.'; }
t_pppoe_up() { wait_for 90 pppoe_addr; }

# --- L2TP (on top of the DHCP WAN)
l2tp_addr() { r 'ubus call network.interface.l2tp status' 2>/dev/null | grep -q '"address": "10\.65\.0\.'; }
l2tp_gone() { ! l2tp_addr; }
l2tp_uci_add() {
    r "uci set network.l2tp=interface; uci set network.l2tp.proto=l2tp
       uci set network.l2tp.server=192.0.2.1; uci set network.l2tp.username=bench
       uci set network.l2tp.password=bench
       for z in \$(uci show firewall | sed -n \"s/^firewall\\.\\([^.]*\\)\\.name='wan'\$/\\1/p\"); do
           uci add_list firewall.\$z.network=l2tp
       done
       uci commit; sync
       ${1:+/etc/init.d/network reload; fw4 -q reload}" >/dev/null
}
l2tp_uci_del() {
    r "uci -q delete network.l2tp
       for z in \$(uci show firewall | sed -n \"s/^firewall\\.\\([^.]*\\)\\.name='wan'\$/\\1/p\"); do
           uci -q del_list firewall.\$z.network=l2tp
       done
       uci commit; /etc/init.d/network reload; fw4 -q reload" >/dev/null
    wait_for 60 t_wan_dhcp || true
}
t_l2tp_idle() {
    ! r 'pidof xl2tpd' >/dev/null 2>&1 || { echo "xl2tpd is running at idle"; return 1; }
    ! mod_loaded l2tp_ppp && ! mod_loaded l2tp_core || { echo "l2tp module loaded at idle"; return 1; }
}
t_l2tp_up() {
    wait_for 90 l2tp_addr || { r 'logread | tail -n 20'; return 1; }
    mod_loaded l2tp_ppp && mod_loaded l2tp_core || { echo "l2tp kernel modules missing"; r 'lsmod'; return 1; }
    r 'logread' | grep -q 'Using l2tp kernel support\.' || { echo "xl2tpd did not report kernel support"; r 'logread | grep xl2tpd | tail -n 10'; return 1; }
    r 'ping -c 3 -W 2 -I l2tp-l2tp 10.65.0.1'
}
t_l2tp_down() {
    r 'ifdown l2tp' >/dev/null
    wait_for 30 l2tp_gone || { r 'ubus call network.interface.l2tp status'; return 1; }
}

# --- WAN link watch (a5v4-wan-watch): malta has no switch (eth1 is a card of its own), so at
# idle the service waits without polling; the tests use the test-only link_file and interval
# options in /etc/config/a5v4.
WW_LINK=/tmp/bench-wan-link
ww_daemon_idle() { r "pgrep -f '^/bin/sh /usr/libexec/a5v4-wan-watch idle'" | grep -q .; }
ww_daemon_watch() { r "pgrep -f '^/bin/sh /usr/libexec/a5v4-wan-watch watch '" | grep -q .; }
ww_daemon_any() { r "pgrep -f '^/bin/sh /usr/libexec/a5v4-wan-watch '" | grep -q .; }
ww_daemon_mem() {
    r 'd=$(pgrep -f "^/bin/sh /usr/libexec/a5v4-wan-watch " | head -n 1)
       for p in $d $(grep -l "^PPid:[[:space:]]*$d\$" /proc/[0-9]*/status 2>/dev/null | cut -d/ -f3); do
           printf "%s %s/%s kB, page tables %s kB; " "$(cat /proc/$p/comm)" \
               "$(sed -n "s/^RssAnon:[[:space:]]*\([0-9]*\).*/\1/p" /proc/$p/status)" \
               "$(sed -n "s/^VmRSS:[[:space:]]*\([0-9]*\).*/\1/p" /proc/$p/status)" \
               "$(sed -n "s/^VmPTE:[[:space:]]*\([0-9]*\).*/\1/p" /proc/$p/status)"
       done'
}
# --- watchcat: off until a rule is added (the build ships an empty /etc/config/watchcat); its LuCI
# page and the Russian translation are in the image. The rule of the check reboots after 6 h without a
# reply from 8.8.8.8 (no route there on the bench, but a run is far shorter) and is removed again.
wc_pid() { r "pgrep -f '^/bin/sh /usr/bin/watchcat.sh '" | head -n 1; }
wc_mem() {
    r 'd=$(pgrep -f "^/bin/sh /usr/bin/watchcat.sh " | head -n 1)
       for p in $d $(grep -l "^PPid:[[:space:]]*$d\$" /proc/[0-9]*/status 2>/dev/null | cut -d/ -f3); do
           printf "%s %s/%s kB, page tables %s kB; " "$(cat /proc/$p/comm)" \
               "$(sed -n "s/^RssAnon:[[:space:]]*\([0-9]*\).*/\1/p" /proc/$p/status)" \
               "$(sed -n "s/^VmRSS:[[:space:]]*\([0-9]*\).*/\1/p" /proc/$p/status)" \
               "$(sed -n "s/^VmPTE:[[:space:]]*\([0-9]*\).*/\1/p" /proc/$p/status)"
       done'
}
t_watchcat() {
    [ -z "$(wc_pid)" ] || { echo "watchcat runs without a rule"; r 'ps w | grep watchcat'; return 1; }
    [ -z "$(r 'uci -q show watchcat')" ] || { echo "watchcat has a rule by default: $(r 'uci -q show watchcat')"; return 1; }
    r '[ -f /www/luci-static/resources/view/watchcat.js ] && [ -f /usr/share/luci/menu.d/luci-app-watchcat.json ] &&
       [ -f /usr/share/rpcd/acl.d/luci-app-watchcat.json ] && [ -f /usr/lib/lua/luci/i18n/watchcat.ru.lmo ]' ||
        { echo "the LuCI page of watchcat or its Russian translation is missing"; return 1; }
}
wc_rule_running() { r "pgrep -f '^/bin/sh /usr/bin/watchcat.sh ping_reboot 21600 30 8.8.8.8 '" | grep -q .; }
t_watchcat_rule() {
    r 'w=$(uci add watchcat watchcat); uci set watchcat.$w.mode=ping_reboot; uci set watchcat.$w.period=6h
       uci set watchcat.$w.pinghosts=8.8.8.8; uci set watchcat.$w.forcedelay=30; uci commit watchcat
       /etc/init.d/watchcat restart' >/dev/null
    wait_for 10 wc_rule_running ||
        { echo "watchcat did not start with a rule"; r 'ps w | grep watchcat'; return 1; }
}
t_watchcat_rule_off() {
    r 'uci -q delete watchcat.@watchcat[0]; uci commit watchcat; /etc/init.d/watchcat restart' >/dev/null
    sleep 2
    [ -z "$(wc_pid)" ] || { echo "watchcat still runs without a rule"; return 1; }
}
t_ww_idle() {
    ww_daemon_idle || { echo "a5v4-wan-watch is not idle"; r "ps w | grep wan-watch"; return 1; }
    ! ww_daemon_watch || { echo "a5v4-wan-watch is polling without a switch"; return 1; }
    [ -z "$(r '/usr/libexec/a5v4-wan-watch detect')" ] || { echo "detect found a switch on malta"; return 1; }
}
t_ww_confirm_short() {
    local pid0 pid1 logs
    pid0="$(r 'pidof udhcpc')"
    [ -n "$pid0" ] || { echo "no udhcpc"; return 1; }
    # Four 3 s drops spaced 13 s apart (3 s down, 10 s up) cover every phase of the 10 s cycle
    # while keeping each 5 s confirmation check inside an up window.
    r "i=0
       while [ \$i -lt 4 ]; do
           echo '0 down' > $WW_LINK
           sleep 3
           echo '0 up' > $WW_LINK
           [ \$i -lt 3 ] && sleep 10 || sleep 6
           i=\$((i + 1))
       done"
    pid1="$(r 'pidof udhcpc')"
    logs="$(r 'logread -e a5v4-wan-watch')"
    [ "$pid0" = "$pid1" ] && [ -z "$logs" ] || {
        echo "restarted on 3 s short drops: pid $pid0 -> $pid1, log: $logs"; return 1;
    }
}
t_ww_confirm_long() {
    local pid0 pid1 n1 n2 log_line
    pid0="$(r 'pidof udhcpc')"
    [ -n "$pid0" ] || { echo "no udhcpc"; return 1; }
    r "echo '0 down' > $WW_LINK"
    sleep 22
    r "echo '0 up' > $WW_LINK"
    udhcpc_restarted() {
        local p
        p="$(r 'pidof udhcpc' || true)"
        [ -n "$p" ] && [ "$p" != "$pid0" ] && t_wan_dhcp
    }
    wait_for 25 udhcpc_restarted || {
        echo "WAN did not restart after two-poll drop at 10 s (pid $pid0 -> $(r 'pidof udhcpc' || true))"
        r 'logread | tail -n 15'; return 1;
    }
    pid1="$(r 'pidof udhcpc')"
    n1="$(r 'logread -e a5v4-wan-watch | wc -l')"
    log_line="$(r 'logread -e a5v4-wan-watch' | tail -n 1)"
    [ "$n1" -eq 1 ] && echo "$log_line" | grep -Eq 'port 0 up after [2-9][0-9]* polls down, restarting:.*wan' || {
        echo "expected 1 restart log line, got $n1: $log_line"; return 1;
    }
    sleep 12
    n2="$(r 'logread -e a5v4-wan-watch | wc -l')"
    [ "$n2" -eq 1 ] && [ "$(r 'pidof udhcpc')" = "$pid1" ] || {
        echo "restarted more than once: lines $n1 -> $n2, pid $pid1 -> $(r 'pidof udhcpc')"; return 1;
    }
}
t_ww_steady() {
    local pid0 pid1 n0 n1
    pid0="$(r 'pidof udhcpc')"
    [ -n "$pid0" ] || { echo "no udhcpc"; return 1; }
    n0="$(r 'logread -e a5v4-wan-watch | wc -l')"
    sleep 11
    pid1="$(r 'pidof udhcpc')"
    n1="$(r 'logread -e a5v4-wan-watch | wc -l')"
    [ "$pid0" = "$pid1" ] && [ "$n0" = "$n1" ] || {
        echo "restarted while link stayed up: pid $pid0 -> $pid1, log lines $n0 -> $n1"; return 1;
    }
}
wan_addr_2xx() { wan_addr | grep -q '^192\.0\.2\.2[0-5][0-9]$'; }
t_ww_dhcp_recover() {
    local v6_before v6_after log_line
    v6_before="$(r 'pidof odhcp6c' || true)"
    r "echo '0 down' > $WW_LINK"
    sleep 7
    wan_dnsmasq_start 192.0.2.200 192.0.2.250
    r "echo '0 up' > $WW_LINK"
    wait_for 25 wan_addr_2xx || { echo "WAN did not get 192.0.2.2xx: $(wan_addr)"; r 'logread | tail -n 15'; return 1; }
    log_line="$(r 'logread -e a5v4-wan-watch' | tail -n 1)"
    echo "$log_line" | grep -Eq 'port 0 up after [2-9][0-9]* polls down, restarting:.*wan' || {
        echo "missing/unexpected log line: $log_line"; return 1;
    }
    if [ "$IPV6_KERNEL" = yes ]; then
        v6_after="$(r 'pidof odhcp6c' || true)"
        [ -n "$v6_before" ] && [ -n "$v6_after" ] && [ "$v6_before" != "$v6_after" ] || {
            echo "wan6 (odhcp6c) was not restarted: $v6_before -> $v6_after"; return 1;
        }
    fi
    t_nat_settled
}
t_ww_off() {
    r 'uci set a5v4.network.wan_watch=0; uci commit a5v4; /etc/init.d/a5v4-wan-watch reload' >/dev/null
    sleep 2
    ! ww_daemon_any || { echo "a5v4-wan-watch still running when disabled"; r 'ps w | grep wan-watch'; return 1; }
}
t_ww_control() {
    local old_addr new_addr
    old_addr="$(wan_addr)"
    echo "$old_addr" | grep -q '^192\.0\.2\.2[0-5][0-9]$' || { echo "unexpected initial addr: $old_addr"; return 1; }
    r "echo '0 down' > $WW_LINK"
    sleep 7
    wan_dnsmasq_start 192.0.2.100 192.0.2.150
    r "echo '0 up' > $WW_LINK"
    sleep 10
    new_addr="$(wan_addr)"
    [ "$old_addr" = "$new_addr" ] || { echo "address changed with service off: $old_addr -> $new_addr"; return 1; }
}
t_ww_pppoe() {
    local pid0
    wan_pppoe
    wait_for 90 pppoe_addr || { echo "PPPoE did not come up"; return 1; }
    pid0="$(r 'pidof pppd')"
    [ -n "$pid0" ] || { echo "no pppd"; return 1; }
    r "echo '0 down' > $WW_LINK"
    sleep 7
    r "echo '0 up' > $WW_LINK"
    pppd_restarted() {
        local p
        p="$(r 'pidof pppd' || true)"
        [ -n "$p" ] && [ "$p" != "$pid0" ] && pppoe_addr
    }
    wait_for 90 pppd_restarted || { echo "PPPoE did not recover (pid $pid0 -> $(r 'pidof pppd' || true))"; r 'logread | tail -n 15'; return 1; }
    t_nat_settled
}
t_ww_l2tp() {
    wan_dhcp
    wait_for 60 t_wan_dhcp || { echo "DHCP WAN not up before L2TP"; return 1; }
    l2tp_uci_add reload
    wait_for 90 l2tp_addr || { echo "L2TP did not come up before flap"; return 1; }
    r "echo '0 down' > $WW_LINK"
    sleep 7
    wan_dnsmasq_start 192.0.2.200 192.0.2.250
    r "echo '0 up' > $WW_LINK"
    wait_for 25 wan_addr_2xx || { echo "DHCP WAN did not recover to 2xx: $(wan_addr)"; return 1; }
    l2tp_ping() { l2tp_addr && r 'ping -c 2 -W 2 -I l2tp-l2tp 10.65.0.1' >/dev/null 2>&1; }
    wait_for 90 l2tp_ping || { echo "L2TP did not recover after WAN restart"; r 'logread | tail -n 20'; return 1; }
    r 'ping -c 3 -W 2 -I l2tp-l2tp 10.65.0.1'
}

# --- WireGuard (remote access to the router through a tunnel with a host on the WAN side)
wg_handshake() { nsx wan wg show wg0 latest-handshakes | awk '$2 > 0' | grep -q .; }
t_wg_handshake() { wait_for 60 wg_handshake; }
wg_up() { r 'ubus call network.interface.wg0 status' | grep -q '"up": true'; }
# SSH listens on the LAN address only (first-boot defaults): the host on the WAN side reaches it
# through the tunnel, which routes the LAN to the router
wg_ssh_once() { nsx wan ssh "${SSH_OPTS[@]}" root@192.168.1.1 true; }
t_wg_ssh() { wait_for 30 wg_ssh_once || wg_ssh_once; }

# --- Multicast from the WAN (IPTV): a stream on the WAN side, a receiver in the LAN. The build has
# no IPTV since 2026-11-06 (RESEARCH.md section 8); the igmpproxy and udpxy checks stay for an image
# that carries them again
MC_GROUP=239.255.1.1
MC_PORT=5004
mc_send() { # a stream from the WAN host for $1 seconds
    nsx wan python3 -c '
import socket, sys, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 8)
s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton("192.0.2.1"))
end = time.time() + float(sys.argv[3])
while time.time() < end:
    s.sendto(b"bench-iptv" * 100, (sys.argv[1], int(sys.argv[2])))
    time.sleep(0.05)' "$MC_GROUP" "$MC_PORT" "$1" &
    MC_PID=$!
}
mc_receive() { # joins the group on the LAN client and waits for one datagram
    nsx lan python3 -c '
import socket, struct, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("", int(sys.argv[2])))
s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
             struct.pack("4s4s", socket.inet_aton(sys.argv[1]), socket.inet_aton("192.168.1.10")))
s.settimeout(15)
s.recv(2048)' "$MC_GROUP" "$MC_PORT"
}
# IPTV is off by default (first-boot defaults), with the upstream altnet 0.0.0.0/0: the package's
# 192.168.1.0/24 makes igmpproxy ignore the reports of LAN clients
t_iptv_default_off() {
    ! r '/etc/init.d/igmpproxy enabled' && r 'uci -q get igmpproxy.@phyint[0].altnet' | grep -qx '0.0.0.0/0' &&
        ! mc_receive
}
t_iptv_igmpproxy() { r '/etc/init.d/igmpproxy enable; /etc/init.d/igmpproxy restart' && sleep 3 && mc_receive; }
t_iptv_blocked() { r '/etc/init.d/igmpproxy stop' && sleep 3 && ! mc_receive; }
t_iptv_udpxy() {
    # udpxy receives on the WAN: multicast to the router itself needs an input rule there
    r "uci set udpxy.@udpxy[0].disabled=0; uci set udpxy.@udpxy[0].source=\$(uci -q get network.wan.device || echo eth1)
       uci commit udpxy; /etc/init.d/udpxy restart
       uci set firewall.iptv=rule; uci set firewall.iptv.name=Allow-IPTV-udpxy; uci set firewall.iptv.src=wan
       uci set firewall.iptv.proto=udp; uci set firewall.iptv.dest_ip=224.0.0.0/4; uci set firewall.iptv.target=ACCEPT
       uci commit firewall; fw4 -q reload" >/dev/null && sleep 3 &&
        [ "$(nsx lan curl -s --max-time 8 "http://192.168.1.1:4022/udp/$MC_GROUP:$MC_PORT" | head -c 1000 | wc -c)" -ge 1000 ]
}
# Without IPTV: no multicast routing in the kernel (IPv4 and IPv6), and a LAN client that joins a
# group gets nothing from the WAN
t_no_mroute() { ! r '[ -e /proc/net/ip_mr_vif ] || [ -e /proc/net/ip6_mr_vif ]'; }
t_no_mc_lan() { ! mc_receive; }

# --- Wi-Fi: an access point on one hwsim radio, a WPA2 client of it on the other
t_radios() { [ "$(r 'ls /sys/class/ieee80211 | wc -l')" -ge 2 ]; }
# The Wi-Fi defaults of the first boot (77_wireless with the CONFIG_PACKAGE_MAC80211_* of the seed):
# the radio and its access point on, country PA, the key of the seed, and per band 2.4 GHz WPA2 on
# channel 1 with 20 MHz, or 5 GHz WPA2/WPA3 (with SAE in hostapd) on channel 36 with 80 MHz
wifi_defaults_radio() { # $1 = number of the radio
    local n="$1" band enc out
    band="$(r "uci -q get wireless.radio$n.band")"
    enc=psk2+ccmp
    [ "$band" = 5g ] && [ "$SAE" = yes ] && enc=sae-mixed
    out="$(r "uci -q get wireless.radio$n.disabled; uci -q get wireless.radio$n.country
              uci -q get wireless.default_radio$n.disabled; uci -q get wireless.default_radio$n.encryption
              uci -q get wireless.default_radio$n.key" | tr '\n' ' ')"
    [ "$out" = "0 PA 0 $enc 12345678 " ] || { echo "radio$n ($band): $out"; return 1; }
    out="$(r "uci -q get wireless.radio$n.channel; uci -q get wireless.radio$n.htmode" | tr '\n' ' ')"
    case "$band:$out" in
        "2g:1 HT20 "|"5g:36 VHT80 ") ;;
        6g:*) ;; # mac80211_hwsim offers 6 GHz, which the router does not have
        *) echo "radio$n: $band $out"; return 1 ;;
    esac
    r "uci -q get wireless.default_radio$n.ssid" | grep -q -- "-$band-$n" || { echo "radio$n: SSID"; return 1; }
    local acs_2g_bias="1:0.6 6:0.6 11:0.6"
    if [ "$band" = 2g ]; then
        [ "$(r "uci -q get wireless.radio$n.channels" | tr -d '\r\n')" = "1-11" ] || { echo "radio$n channels != 1-11"; return 1; }
        [ "$(r "uci -q get wireless.radio$n.hostapd_options" | tr -d '\r\n')" = "acs_num_scans=2" ] || { echo "radio$n hostapd_options != acs_num_scans=2"; return 1; }
        [ -z "$acs_2g_bias" ] || [ "$(r "uci -q get wireless.radio$n.acs_chan_bias" | tr -d '\r\n')" = "$acs_2g_bias" ] || { echo "radio$n bias mismatch"; return 1; }
    elif [ "$band" = 5g ]; then
        [ "$(r "uci -q get wireless.radio$n.acs_exclude_dfs" | tr -d '\r\n')" = "1" ] || { echo "radio$n acs_exclude_dfs != 1"; return 1; }
        [ -z "$(r "uci -q get wireless.radio$n.channels" | tr -d '\r\n')" ] || { echo "radio$n channels not empty"; return 1; }
        [ "$(r "uci -q get wireless.radio$n.hostapd_options" | tr -d '\r\n')" = "acs_num_scans=1 min_tx_power=15" ] || { echo "radio$n hostapd_options != acs_num_scans=1 min_tx_power=15"; return 1; }
    fi
}
t_wifi_defaults() { wifi_defaults_radio 0 && wifi_defaults_radio 1; }
# The radios of mac80211_hwsim come up on 6 GHz: run the script again with the bands of the router
t_wifi_defaults_router_bands() {
    r "uci -q delete wireless.default_radio0.key; uci -q delete wireless.default_radio1.key
       uci -q delete wireless.radio0.channels; uci -q delete wireless.radio0.hostapd_options; uci -q delete wireless.radio0.acs_chan_bias
       uci -q delete wireless.radio1.channels; uci -q delete wireless.radio1.hostapd_options; uci -q delete wireless.radio1.acs_exclude_dfs
       uci set wireless.radio0.band=2g; uci set wireless.radio1.band=5g; uci commit wireless
       sh /rom/etc/uci-defaults/77_wireless" >/dev/null
    wifi_defaults_radio 0 && wifi_defaults_radio 1
}
sta_connected() { r 'for d in $(ls /sys/class/net); do iw dev "$d" link 2>/dev/null; done' | grep -q 'Connected to'; }
sta_gone() { ! sta_connected; }
t_wifi_wpa2() {
    wait_for 120 sta_connected && return 0
    r 'iw dev; logread | grep -E "hostapd|wpa_supplicant|netifd" | tail -n 8'
    return 1
}
# The access point (radio0) and the client (radio1) with other encryptions: $1 of the access point,
# $2 of the client. A client with "sae" can only use WPA3.
t_wifi_assoc() {
    r "uci set wireless.default_radio0.encryption=$1; uci set wireless.default_radio1.encryption=$2
       uci commit wireless; wifi down" >/dev/null
    wait_for 60 sta_gone || { echo "the client did not go down"; return 1; }
    r 'wifi up' >/dev/null
    t_wifi_wpa2
}
# The interface wizard of travelmate (what LuCI runs) creates the uplink interface in the WAN zone,
# and without IPv6 no IPv6 uplink (feeds-patches/packages); then the configuration is put back
t_trm_wizard() {
    local out
    out="$(r '/etc/init.d/travelmate setup trm_wwan wan 100 >/dev/null 2>&1
              uci show network; uci show firewall; uci -q get travelmate.global.trm_iface')"
    r "uci -q delete network.trm_wwan; uci -q delete network.trm_wwan6
       for z in \$(uci show firewall | sed -n \"s/^firewall\\.\\([^.]*\\)\\.name='wan'\$/\\1/p\"); do
           uci -q del_list firewall.\$z.network=trm_wwan; uci -q del_list firewall.\$z.network=trm_wwan6
       done
       uci set travelmate.global.trm_enabled=0; uci -q delete travelmate.global.trm_iface
       uci commit; /etc/init.d/network reload; fw4 -q reload" >/dev/null
    echo "$out" | grep -qxF "network.trm_wwan.proto='dhcp'" || { echo "no trm_wwan"; return 1; }
    echo "$out" | grep "^firewall\..*\.network=" | grep -q "'trm_wwan'" || { echo "trm_wwan not in the WAN zone"; return 1; }
    echo "$out" | tail -n 1 | grep -qx trm_wwan || { echo "travelmate not set to trm_wwan"; return 1; }
    if [ "$IPV6_KERNEL" = no ]; then
        ! echo "$out" | grep -q "trm_wwan6" || { echo "trm_wwan6 without IPv6"; return 1; }
    fi
}

if [ -n "$HOOK" ]; then
    log "Running $HOOK"
    # shellcheck source=/dev/null
    . "$HOOK"
    echo "Failed: $FAILS, skipped: $SKIPS" | tee -a "$RESULTS"
    exit "$FAILS"
fi

info "image: $(r 'cat /etc/openwrt_release' | sed -n "s/^DISTRIB_DESCRIPTION='\(.*\)'/\1/p"), kernel $(r 'uname -r')"
info "boot to SSH: $BOOT_SECS s (TCG emulation, not the speed of the router)"
IPV6_KERNEL="$(r '[ -d /proc/sys/net/ipv6 ] && echo yes || echo no')"
info "IPv6 in the kernel: $IPV6_KERNEL"
# Read 90 s after the boot, when the services have settled: right after SSH comes up the value moves
# by megabytes with what is being started and cached (RESEARCH.md, Method and sources)
uptime_90() { [ "$(r 'cut -d. -f1 /proc/uptime')" -ge 90 ]; }
wait_for 120 uptime_90 || true
info "memory 90 s after boot: $(r "grep -E 'MemTotal|MemAvailable' /proc/meminfo" | tr -s ' ' | tr '\n' ' ')"

section "System"
check "LAN card is eth0" t_lan_is_eth0
check "no unknown kernel symbols" t_no_unknown_symbols
check "first-boot scripts done" t_uci_defaults_done
if r '[ -f /rom/etc/uci-defaults/99-a5v4-defaults ]'; then
    check "first-boot defaults (offload, NTP server, WAN drops, SSH on the LAN)" t_first_boot_defaults
else
    skip "first-boot defaults" "the image has no 99-a5v4-defaults"
fi
NETDEF="$(r '[ -f /rom/etc/init.d/a5v4-threaded-napi ] && echo yes || echo no')"
if [ "$NETDEF" = yes ]; then
    check "GRO: no gro option in /etc/config/network" t_gro_no_config
    check "GRO off on eth0" t_gro_off_eth0
    check "threaded NAPI on eth0" t_threaded_napi
else
    skip "GRO off and threaded NAPI" "the image does not set them"
fi
if r 'ls /lib/modules/*/mt7603e.ko' >/dev/null 2>&1; then
    check "router Wi-Fi drivers load (mt7603e, mt76x2e)" t_router_wifi_drivers
    check "mt76x02 and mt7603: delay interrupts by default (delay_int)" t_mt76_delay_int
    check "mt76x02: 5 GHz TX optimization switches by default (tx_opt)" t_mt76_tx_opt
else
    skip "router Wi-Fi drivers load" "the image has no mt7603e"
fi
if r '[ -x /usr/libexec/fwupdate ]'; then
    check "update checker at idle: runs, nothing downloaded" t_fwu_idle
    info "update check at idle: $(r 'cat /tmp/fwupdate/status.json 2>/dev/null || echo "none yet"' | cut -c1-200)"
else
    skip "update checker at idle" "the image has no luci-app-fwupdate"
fi
if r '[ -x /usr/bin/watchcat.sh ]'; then
    check "watchcat: off without a rule, LuCI page in Russian" t_watchcat
    check "watchcat: a rule starts it" t_watchcat_rule
    info "memory of watchcat asleep: $(wc_mem)(private/resident)"
    check "watchcat: removing the rule stops it" t_watchcat_rule_off
else
    skip "watchcat" "the image has no watchcat"
fi
if r '[ -x /usr/libexec/a5v4-wan-watch ]'; then
    check "WAN watch at idle: waits without polling when WAN is not on a switch" t_ww_idle
    info "memory of a5v4-wan-watch asleep: $(ww_daemon_mem)(private/resident)"
else
    skip "WAN watch at idle" "the image has no a5v4-wan-watch"
fi

section "LAN services"
check "DHCP lease on the LAN" t_lan_dhcp
check "DNS: the router's name" t_dns_router_name
check "DNS: the name of a DHCP client" t_dns_dhcp_client
if r '[ -x /etc/init.d/https-dns-proxy ]'; then
    check "DoH: https-dns-proxy runs over HTTP/2, dnsmasq asks only it, no forced DNS" t_doh_setup
    info "memory of https-dns-proxy: $(r 'for p in $(pidof https-dns-proxy); do
        printf "%s/%s kB; " "$(sed -n "s/^RssAnon:[[:space:]]*\([0-9]*\).*/\1/p" /proc/$p/status)" "$(sed -n "s/^VmRSS:[[:space:]]*\([0-9]*\).*/\1/p" /proc/$p/status)"
    done') (private/resident per instance)"
    # The bench has no internet, so DoH cannot answer: the checks that need DNS of the internet
    # (and NTP) run with DoH turned off
    check "DoH off: dnsmasq back on the WAN's DNS, no proxy address left" t_doh_off
else
    skip "DoH" "the image has no https-dns-proxy"
fi
check "DNS of the internet through the router" t_dns
if [ "$(r 'uci -q get system.ntp.enable_server' || true)" = 1 ]; then
    check "NTP server answers" t_ntp_server
else
    skip "NTP server answers" "system.ntp.enable_server is off in this image"
fi
LUCI_START=$(date +%s%N)
check "LuCI page" t_luci_page
info "LuCI page load: $(( ($(date +%s%N) - LUCI_START) / 1000000 )) ms (TCG)"
check "LuCI login (ubus session)" t_luci_login
check "LuCI rpc call (system board)" t_luci_rpc
if r 'ls /usr/lib/lua/luci/i18n/base.ru.lmo' >/dev/null 2>&1; then
    check "LuCI in Russian" t_luci_ru
else
    skip "LuCI in Russian" "the image has no Russian translation"
fi

section "WAN, firewall, routing"
check "WAN address over DHCP" t_wan_dhcp
check "fw4 table inet fw4" t_fw4_inet
check "NAT to the internet host" t_nat
check "the router reaches and resolves the internet" t_router_internet
check "SSH and LuCI closed on the WAN" t_wan_closed
if r '[ -f /rom/etc/uci-defaults/99-a5v4-defaults ]'; then
    check "WAN: closed ports silent, ping answered" t_wan_stealth
else
    skip "WAN: closed ports silent" "the image has no 99-a5v4-defaults"
fi
reject_rule add
check "reject: TCP reset from the WAN zone" t_reject_tcp
check "reject: ICMP port unreachable from the WAN zone" t_reject_udp
reject_rule delete
if [ "$IPV6_KERNEL" = yes ]; then
    check "IPv6 in the LAN: a ULA by SLAAC, ping to the router" t_ipv6_lan
    check "IPv6 on the WAN (odhcp6c) and in the firewall" t_ipv6_wan_fw
else
    check "no IPv6 settings (wan6, ula_prefix, ip6assign)" t_no_ipv6_config
fi
offload_run "flow offloading ([OFFLOAD] in conntrack)" dhcp

section "Firmware updates"
if ! r '[ -x /usr/libexec/fwupdate ]'; then
    skip "firmware updates" "the image has no luci-app-fwupdate"
else
    # the checker stops for the tests, so that its own checks do not run in between
    r '/etc/init.d/fwupdate stop' >/dev/null
    wait_for 120 fwu_idle || true
    check "firmware version without a release: as built ($(board_desc))" t_relname_local
    r "rm -rf /tmp/fwupdate; printf \"RELEASE='v25.12.5-a5v4-r1'\nREPO=''\nCOMMIT='bench'\n\" > /etc/a5v4_release" >/dev/null
    check "firmware version with a release: the release after the version" t_relname_release
    check "firmware version: the release only once after a second run" t_relname_once
    info "firmware version with the release: $(board_desc)"
    mkdir -p "$FWU_SRV"
    fwu_release
    if fwu_serve; then
        check "update check: the newer releases with their changes and method (reset)" t_fwu_check
        check "update notice of the Overview page (LuCI rpc)" t_fwu_notice
        check "download: size and SHA256 match, sysupgrade of malta refuses the image" t_fwu_download_malta
        info "sysupgrade -T of malta: $(r 'jsonfilter -i /tmp/fwupdate/download.json -e @.detail')"
        check "download: ready with a platform check that accepts it, discard frees it" t_fwu_download_ready
        info "memory (kB) before the download of $(( $(stat -c %s "$FWU_IMG") / 1024 )) KiB: $(tr -d '\n' < "$W/fwu-mem.txt" 2>/dev/null)"
        check "download: a wrong SHA256 is refused and nothing is kept" t_fwu_bad_checksum
        check "download: refused without MemAvailable for the image and the margin" t_fwu_no_memory
        check "update check without the server: no connection, the last result kept" t_fwu_no_connection
    else
        check "update test server on the internet host" false
    fi
    fwu_cleanup
    sleep 3
    check "update checker runs again" t_fwu_idle
    info "memory of the update checker asleep: $(fwu_daemon_mem)(private/resident)"
fi

section "PPPoE"
if [ "$PPPOE_OK" = 1 ]; then
    wan_pppoe
    check "PPPoE session up (10.64.0.x)" t_pppoe_up
    check "NAT over PPPoE" t_nat_settled
    offload_run "flow offloading over PPPoE" pppoe
    wan_dhcp
    wait_for 60 t_wan_dhcp || true
else
    skip "PPPoE" "no pppoe-server on the WAN side ($(tr '\n' ' ' < "$W/pppoe-server.log" 2>/dev/null))"
fi

section "L2TP"
if ! has xl2tpd; then
    skip "L2TP" "the image has no xl2tpd"
elif [ "$L2TP_OK" != 1 ]; then
    check "L2TP LNS on the bench host" false
else
    check "L2TP idle: no xl2tpd process and no l2tp modules at boot" t_l2tp_idle
    info "memory at L2TP idle: $(r "grep -E 'MemAvailable' /proc/meminfo" | tr -s ' ')"
    l2tp_uci_add reload
    check "L2TP up (10.65.0.x, kernel modules, kernel support log, ping 10.65.0.1)" t_l2tp_up
    info "memory of xl2tpd: $(r 'for p in $(pidof xl2tpd); do
        printf "%s/%s kB; " "$(sed -n "s/^RssAnon:[[:space:]]*\([0-9]*\).*/\1/p" /proc/$p/status)" "$(sed -n "s/^VmRSS:[[:space:]]*\([0-9]*\).*/\1/p" /proc/$p/status)"
    done') (private/resident)"
    info "memory with L2TP up: $(r "grep -E 'MemAvailable' /proc/meminfo" | tr -s ' ')"
    check "L2TP down: address gone after ifdown l2tp" t_l2tp_down
    l2tp_uci_del
fi

section "WAN link watch"
if ! r '[ -x /usr/libexec/a5v4-wan-watch ]'; then
    skip "WAN link watch" "the image has no a5v4-wan-watch"
else
    # First with a 10 s interval, where the 5 s down confirmation is active
    r "echo '0 up' > $WW_LINK
       uci set a5v4.network=network
       uci set a5v4.network.wan_watch_link_file=$WW_LINK
       uci set a5v4.network.wan_watch_interval=10
       uci commit a5v4
       /etc/init.d/a5v4-wan-watch reload" >/dev/null
    sleep 2
    check "WAN watch (10 s, 5 s confirm): 3 s short drops do not restart" t_ww_confirm_short
    check "WAN watch (10 s, 5 s confirm): drop over two polls restarts once" t_ww_confirm_long
    info "WAN watch 10 s log: $(r 'logread -e a5v4-wan-watch' | tail -n 1)"
    # Switch to a 3 s interval for the remaining checks
    r "uci set a5v4.network.wan_watch_interval=3
       uci commit a5v4
       /etc/init.d/a5v4-wan-watch reload" >/dev/null
    sleep 2
    check "WAN watch: no restart over several polls while link is up" t_ww_steady
    check "WAN watch: recovers DHCP lease after link down and up, restarts wan6" t_ww_dhcp_recover
    info "WAN watch log: $(r 'logread -e a5v4-wan-watch' | tail -n 1)"
    check "WAN watch off: no daemon runs" t_ww_off
    check "WAN watch control (service off): stale DHCP lease stays" t_ww_control
    # Restore service on and WAN back to 192.0.2.1xx
    r 'uci -q delete a5v4.network.wan_watch; uci commit a5v4; /etc/init.d/a5v4-wan-watch reload; ifup wan' >/dev/null
    wait_for 60 t_wan_dhcp || true
    if [ "$PPPOE_OK" = 1 ]; then
        check "WAN watch: PPPoE session comes back after link flap" t_ww_pppoe
        wan_dhcp
        wait_for 60 t_wan_dhcp || true
    else
        skip "WAN watch PPPoE" "no pppoe-server on the WAN side"
    fi
    if has xl2tpd && [ "$L2TP_OK" = 1 ]; then
        check "WAN watch: L2TP over DHCP WAN comes back after link flap" t_ww_l2tp
        wan_dnsmasq_start 192.0.2.100 192.0.2.150
        r 'ifup wan' >/dev/null
        l2tp_uci_del
    else
        skip "WAN watch L2TP" "no xl2tpd or LNS"
        wan_dnsmasq_start 192.0.2.100 192.0.2.150
    fi
    # Remove test-only options and ensure WAN is back on 192.0.2.1xx
    r "uci -q delete a5v4.network.wan_watch_link_file
       uci -q delete a5v4.network.wan_watch_interval
       uci -q delete a5v4.network.wan_watch
       uci commit a5v4
       rm -f $WW_LINK
       /etc/init.d/a5v4-wan-watch reload" >/dev/null
    t_wan_dhcp || { r 'ifup wan' >/dev/null; wait_for 60 t_wan_dhcp || true; }
    sleep 2
    check "WAN watch restored to idle without test link source" t_ww_idle
fi

section "WireGuard"
if ! has wg; then
    skip "WireGuard" "the image has no wireguard-tools"
elif ! nsx wan ip link add wg0 type wireguard 2>/dev/null; then
    skip "WireGuard" "the kernel of the bench host has no WireGuard"
else
    check "WireGuard module not loaded before a tunnel" t_wg_mod_absent
    WG_SRV_KEY="$(wg genkey)"
    WG_RTR_KEY="$(wg genkey)"
    printf '%s\n' "$WG_SRV_KEY" > "$W/wg-server.key"
    nsx wan wg set wg0 listen-port 51820 private-key "$W/wg-server.key" \
        peer "$(printf '%s' "$WG_RTR_KEY" | wg pubkey)" allowed-ips 10.99.0.2/32,192.168.1.0/24
    nsx wan ip addr add 10.99.0.1/24 dev wg0
    nsx wan ip link set wg0 up
    nsx wan ip route add 192.168.1.0/24 dev wg0
    r "uci set network.wg0=interface; uci set network.wg0.proto=wireguard
       uci set network.wg0.private_key='$WG_RTR_KEY'; uci add_list network.wg0.addresses=10.99.0.2/24
       uci set network.wgsrv=wireguard_wg0; uci set network.wgsrv.public_key='$(printf '%s' "$WG_SRV_KEY" | wg pubkey)'
       uci set network.wgsrv.endpoint_host=192.0.2.1; uci set network.wgsrv.endpoint_port=51820
       uci add_list network.wgsrv.allowed_ips=10.99.0.0/24; uci set network.wgsrv.route_allowed_ips=1
       uci set network.wgsrv.persistent_keepalive=5
       uci add_list firewall.@zone[0].network=wg0
       uci commit; /etc/init.d/network reload" >/dev/null
    # fw4 only knows the device of an interface that is up
    wait_for 60 wg_up || true
    r 'fw4 -q reload' >/dev/null
    check "WireGuard handshake" t_wg_handshake
    check "SSH to the router's LAN address through the tunnel" t_wg_ssh
    check "WireGuard module loaded with the tunnel" t_wg_mod_loaded
    if [ "$NETDEF" = yes ]; then
        check "GRO off on wg0" t_gro_off_wg
    fi
fi

section "AmneziaWG"
if ! has awg; then
    skip "AmneziaWG" "the image has no amneziawg-tools"
elif [ -z "${WG_RTR_KEY:-}" ]; then
    skip "AmneziaWG" "no WireGuard peer on the WAN side"
else
    check "AmneziaWG module not loaded before a tunnel" t_awg_mod_absent
    # Without obfuscation AmneziaWG speaks WireGuard: the tunnel of the WireGuard test, with the same
    # key, through awg0 to the WireGuard server on the WAN side (its peer added again, so that the
    # handshake is a new one)
    WG_RTR_PUB="$(printf '%s' "$WG_RTR_KEY" | wg pubkey)"
    nsx wan wg set wg0 peer "$WG_RTR_PUB" remove
    nsx wan wg set wg0 peer "$WG_RTR_PUB" allowed-ips 10.99.0.2/32,192.168.1.0/24
    r "uci -q delete network.wg0; uci -q delete network.wgsrv; uci -q del_list firewall.@zone[0].network=wg0
       uci set network.awg0=interface; uci set network.awg0.proto=amneziawg
       uci set network.awg0.private_key='$WG_RTR_KEY'; uci add_list network.awg0.addresses=10.99.0.2/24
       uci set network.awgsrv=amneziawg_awg0; uci set network.awgsrv.public_key='$(printf '%s' "$WG_SRV_KEY" | wg pubkey)'
       uci set network.awgsrv.endpoint_host=192.0.2.1; uci set network.awgsrv.endpoint_port=51820
       uci add_list network.awgsrv.allowed_ips=10.99.0.0/24; uci set network.awgsrv.route_allowed_ips=1
       uci set network.awgsrv.persistent_keepalive=5
       uci add_list firewall.@zone[0].network=awg0
       uci commit; /etc/init.d/network reload" >/dev/null
    awg_up() { r 'ubus call network.interface.awg0 status' | grep -q '"up": true'; }
    wait_for 60 awg_up || true
    r 'fw4 -q reload' >/dev/null
    check "AmneziaWG without obfuscation: handshake with WireGuard" t_wg_handshake
    check "SSH to the router's LAN address through AmneziaWG" t_wg_ssh
    check "AmneziaWG module loaded with the tunnel" t_awg_mod_loaded
    # With obfuscation: junk packets, padded handshakes and own message types on both sides
    K1="$(wg genkey)"; K2="$(wg genkey)"
    obf="uci set network.\$i.awg_jc=4; uci set network.\$i.awg_jmin=8; uci set network.\$i.awg_jmax=80
         uci set network.\$i.awg_s1=15; uci set network.\$i.awg_s2=30; uci set network.\$i.awg_h1=1234567
         uci set network.\$i.awg_h2=2345678; uci set network.\$i.awg_h3=3456789; uci set network.\$i.awg_h4=4567890"
    r "for i in awg1 awg2; do uci set network.\$i=interface; uci set network.\$i.proto=amneziawg; $obf; done
       uci set network.awg1.private_key='$K1'; uci set network.awg1.listen_port=51821
       uci add_list network.awg1.addresses=10.98.0.1/32
       uci set network.awg1p=amneziawg_awg1; uci set network.awg1p.public_key='$(printf '%s' "$K2" | wg pubkey)'
       uci add_list network.awg1p.allowed_ips=10.98.0.2/32
       uci set network.awg2.private_key='$K2'; uci add_list network.awg2.addresses=10.98.0.2/32
       uci set network.awg2p=amneziawg_awg2; uci set network.awg2p.public_key='$(printf '%s' "$K1" | wg pubkey)'
       uci set network.awg2p.endpoint_host=127.0.0.1; uci set network.awg2p.endpoint_port=51821
       uci add_list network.awg2p.allowed_ips=10.98.0.1/32; uci set network.awg2p.persistent_keepalive=5
       uci commit network; /etc/init.d/network reload" >/dev/null
    check "AmneziaWG with obfuscation: handshake between two interfaces" t_awg_obfuscated
fi

section "Multicast from the WAN (IPTV)"
if ! has igmpproxy; then
    mc_send 25
    if [ "$SOURCE" = local ]; then
        check "no multicast routing in the kernel" t_no_mroute
    fi
    check "no multicast from the WAN reaches the LAN" t_no_mc_lan
    wait "$MC_PID" || true
else
    mc_send 95
    check "IPTV off by default: no multicast from the WAN" t_iptv_default_off
    check "multicast from the WAN reaches the LAN (igmpproxy)" t_iptv_igmpproxy
    check "no multicast from the WAN without igmpproxy" t_iptv_blocked
    if has udpxy; then
        check "udpxy serves the stream over HTTP" t_iptv_udpxy
    else
        skip "udpxy" "the image has no udpxy"
    fi
    wait "$MC_PID" || true
fi

section "Wi-Fi (mac80211_hwsim)"
SAE="$(r '/usr/sbin/hostapd -vsae >/dev/null 2>&1 && echo yes || echo no')"
info "WPA3 (SAE) in hostapd: $SAE"
info "memory of wpad: $(r 'for p in $(pgrep -f "^/usr/sbin/(hostapd|wpa_supplicant) "); do
    printf "%s %s/%s kB; " "$(tr "\0" " " < /proc/$p/cmdline | cut -d" " -f1 | sed "s|.*/||")" \
        "$(sed -n "s/^RssAnon:[[:space:]]*\([0-9]*\).*/\1/p" /proc/$p/status)" "$(sed -n "s/^VmRSS:[[:space:]]*\([0-9]*\).*/\1/p" /proc/$p/status)"
done') (private/resident)"
check "Wi-Fi radios" t_radios
if r '[ -x /etc/init.d/travelmate ]'; then
    check "travelmate wizard: uplink in the WAN zone, no IPv6 uplink without IPv6" t_trm_wizard
else
    skip "travelmate wizard" "the image has no travelmate"
fi
if r 'grep -q "^radio_en=y" /rom/etc/uci-defaults/77_wireless' 2>/dev/null; then
    check "Wi-Fi defaults of the first boot (on, PA, encryption, channel and width)" t_wifi_defaults
    check "Wi-Fi defaults with the bands of the router (2.4 GHz WPA2, 5 GHz WPA2/WPA3)" t_wifi_defaults_router_bands
else
    skip "Wi-Fi defaults of the first boot" "the image does not set them"
fi
r "uci set wireless.radio0.disabled=0; uci set wireless.radio1.disabled=0
   for radio in radio0 radio1; do
       uci set wireless.\$radio.band=2g; uci set wireless.\$radio.channel=1; uci set wireless.\$radio.htmode=HT20
       # hostapd refuses the world domain 00 of hwsim with 802.11d; PA is the default of this build
       uci set wireless.\$radio.country=PA
   done
   uci set wireless.default_radio0.disabled=0; uci set wireless.default_radio1.disabled=0
   uci set wireless.default_radio0.mode=ap; uci set wireless.default_radio0.ssid=bench-ap
   uci set wireless.default_radio0.encryption=psk2; uci set wireless.default_radio0.key=bench-pass-1
   uci set wireless.default_radio1.mode=sta; uci set wireless.default_radio1.ssid=bench-ap
   uci set wireless.default_radio1.encryption=psk2; uci set wireless.default_radio1.key=bench-pass-1
   uci set wireless.default_radio1.network=wwan
   uci set network.wwan=interface; uci set network.wwan.proto=none
   uci commit; /etc/init.d/network reload" >/dev/null
check "WPA2 client associates with the access point" t_wifi_wpa2
if [ "$NETDEF" = yes ]; then
    check "GRO off on the Wi-Fi access point and client" t_gro_off_wifi
fi
if [ "$SAE" = yes ]; then
    check "WPA2 client associates with a WPA2/WPA3 access point" t_wifi_assoc sae-mixed psk2
    check "WPA3 client associates with a WPA2/WPA3 access point" t_wifi_assoc sae-mixed sae
    if [ "$NETDEF" = yes ]; then
        check "GRO off on the Wi-Fi interfaces after wifi down and up" t_gro_off_wifi
    fi
else
    skip "WPA3" "hostapd of the image has no SAE"
fi

# --- Wi-Fi ACS (mac80211_hwsim): automatic channel selection and acs_scan_duration
# Measure ACS start -> AP-ENABLED in ms via /proc/uptime while logread -f follows hostapd.
acs_ap_gone() { ! r 'iw dev phy0-ap0 info >/dev/null 2>&1'; }
acs_ap_done() { r 'grep -q "AP-ENABLED" /tmp/acs-lr.log 2>/dev/null'; }
acs_run() {
    local chan="$1" scans="$2" dur="$3"
    r "uci set wireless.radio1.disabled=1
       uci set wireless.radio0.channel='$chan'
       uci -q delete wireless.radio0.channels
       uci add_list wireless.radio0.channels='1-11'
       uci -q delete wireless.radio0.hostapd_options
       [ -n '$scans' ] && uci add_list wireless.radio0.hostapd_options='acs_num_scans=$scans'
       [ -n '$dur' ] && uci add_list wireless.radio0.hostapd_options='acs_scan_duration=$dur'
       uci commit wireless
       wifi down radio0" >/dev/null
    wait_for 30 acs_ap_gone || true
    r "rm -f /tmp/acs-lr.log /tmp/acs-ms /tmp/acs-lr.pid
       sh -c 'echo \$\$ > /tmp/acs-lr.pid; exec logread -f' | {
           t0=''
           while IFS= read -r line; do
               printf '%s\n' \"\$line\" >> /tmp/acs-lr.log
               case \"\$line\" in
                   *'ACS: Automatic channel selection started'*|*'ACS-STARTED'*)
                       [ -n \"\$t0\" ] || read -r t0 _ < /proc/uptime ;;
                   *'AP-ENABLED'*)
                       read -r t1 _ < /proc/uptime
                       [ -n \"\$t0\" ] && awk -v a=\"\$t0\" -v b=\"\$t1\" 'BEGIN{printf \"%.0f\n\", (b-a)*1000}' > /tmp/acs-ms
                       ;;
               esac
           done
       } >/dev/null 2>&1 &
       sleep 1
       wifi up radio0" >/dev/null
    wait_for 60 acs_ap_done
    local rc=$?
    sleep 1
    r 'kill "$(cat /tmp/acs-lr.pid 2>/dev/null)" 2>/dev/null || true; rm -f /tmp/acs-lr.pid' >/dev/null
    return "$rc"
}
acs_log_clean() {
    ! r 'grep -iE "unknown configuration item|invalid acs_|Line [0-9]+:.*(invalid|error)|ACS: Failed|ACS-FAILED" /tmp/acs-lr.log'
}
acs_survey_dump() {
    r 'iw dev phy0-ap0 survey dump'
}
ACS_BASE_MS=""
ACS_DUR0_MS=""
ACS_DUR300_MS=""
t_acs_base() {
    local ms ch surv
    acs_run auto 1 "" || return 1
    acs_log_clean || return 1
    r 'grep -q "ACS-COMPLETED" /tmp/acs-lr.log' || { r 'cat /tmp/acs-lr.log'; return 1; }
    ms="$(r 'cat /tmp/acs-ms 2>/dev/null' | tr -d '\r\n')"
    [ -n "$ms" ] || { echo "missing ACS duration"; r 'cat /tmp/acs-lr.log'; return 1; }
    ch="$(r "iw dev phy0-ap0 info" | sed -n 's/.*channel \([0-9]*\).*/\1/p')"
    [ -n "$ch" ] && [ "$ch" -ge 1 ] && [ "$ch" -le 11 ] || { echo "unexpected channel: $ch"; return 1; }
    surv="$(acs_survey_dump | grep -E 'frequency:|channel active time:|channel busy time:|noise:' | head -12 | tr '\n' ' ')"
    printf '%s\n' "$ms" > "$W/acs-base-ms"
    printf '%s\n' "$ch" > "$W/acs-base-ch"
    printf '%s\n' "$surv" > "$W/acs-base-surv"
}
t_acs_dur0() {
    local ms base_ms
    acs_run auto 1 0 || return 1
    acs_log_clean || return 1
    r 'grep -q "ACS-COMPLETED" /tmp/acs-lr.log' || return 1
    ms="$(r 'cat /tmp/acs-ms 2>/dev/null' | tr -d '\r\n')"
    [ -n "$ms" ] || { echo "missing ACS duration"; return 1; }
    base_ms="$(cat "$W/acs-base-ms")"
    [ "$ms" -lt $((base_ms + 1000)) ] && [ "$base_ms" -lt $((ms + 1000)) ] || {
        echo "acs_scan_duration=0 ($ms ms) differed from default ($base_ms ms) by >= 1000 ms"
        return 1
    }
    printf '%s\n' "$ms" > "$W/acs-dur0-ms"
}
t_acs_dur300() {
    local ms base_ms dur0_ms surv
    acs_run auto 1 300 || return 1
    acs_log_clean || return 1
    r 'grep -q "ACS-COMPLETED" /tmp/acs-lr.log' || return 1
    ms="$(r 'cat /tmp/acs-ms 2>/dev/null' | tr -d '\r\n')"
    [ -n "$ms" ] || { echo "missing ACS duration"; return 1; }
    base_ms="$(cat "$W/acs-base-ms")"
    dur0_ms="$(cat "$W/acs-dur0-ms")"
    # 11 channels * (300 - 110) ms = ~2090 ms extra; allow a wide margin on TCG
    [ "$ms" -ge $((base_ms + 1000)) ] && [ "$ms" -ge $((dur0_ms + 1000)) ] || {
        echo "acs_scan_duration=300 ($ms ms) did not exceed baseline ($base_ms / $dur0_ms ms) by >= 1000 ms"
        return 1
    }
    surv="$(acs_survey_dump | grep -E 'frequency:|channel active time:|channel busy time:|noise:' | head -12 | tr '\n' ' ')"
    printf '%s\n' "$ms" > "$W/acs-dur300-ms"
    printf '%s\n' "$surv" > "$W/acs-dur300-surv"
}
t_acs_fixed_chan() {
    local info conf
    acs_run 1 1 300 || return 1
    acs_log_clean || return 1
    ! r 'grep -qE "ACS-STARTED|ACS-COMPLETED" /tmp/acs-lr.log' || { echo "ACS ran on fixed channel"; return 1; }
    conf="$(r 'cat /var/run/hostapd-phy0.conf')"
    echo "$conf" | grep -q '^channel=1$' || { echo "$conf"; return 1; }
    echo "$conf" | grep -q '^chanlist=1-11$' || { echo "$conf"; return 1; }
    echo "$conf" | grep -q '^acs_num_scans=1$' || { echo "$conf"; return 1; }
    info="$(r 'iw dev phy0-ap0 info')"
    echo "$info" | grep -q 'channel 1 (2412 MHz)' || { echo "$info"; return 1; }
    echo "$info" | grep -q 'width: 20 MHz' || { echo "$info"; return 1; }
}
t_acs_preset_hostapd_conf() {
    local conf conf5 cnt avail
    r "uci set wireless.radio1.disabled=1
       uci set wireless.radio0.band=2g; uci set wireless.radio0.channel=auto; uci set wireless.radio0.htmode=HT20
       uci -q delete wireless.radio0.channels; uci add_list wireless.radio0.channels='1-11'
       uci set wireless.radio0.acs_chan_bias='1:0.6 6:0.6 11:0.6'
       uci -q delete wireless.radio0.hostapd_options; uci add_list wireless.radio0.hostapd_options='acs_num_scans=2'
       uci commit wireless; wifi down radio0" >/dev/null
    wait_for 30 acs_ap_gone || true
    r "rm -f /tmp/acs-lr.log /tmp/acs-ms /tmp/acs-lr.pid
       sh -c 'echo \$\$ > /tmp/acs-lr.pid; exec logread -f' > /tmp/acs-lr.log 2>&1 &
       sleep 1; wifi up radio0" >/dev/null
    wait_for 60 acs_ap_done || { r 'kill $(cat /tmp/acs-lr.pid 2>/dev/null) 2>/dev/null || true'; return 1; }
    r 'kill $(cat /tmp/acs-lr.pid 2>/dev/null) 2>/dev/null || true; rm -f /tmp/acs-lr.pid' >/dev/null
    conf="$(r 'cat /var/run/hostapd-phy0.conf')"
    echo "$conf" | grep -q '^channel=0$' || { echo "$conf"; return 1; }
    echo "$conf" | grep -q '^chanlist=1-11$' || { echo "$conf"; return 1; }
    echo "$conf" | grep -q '^acs_num_scans=2$' || { echo "$conf"; return 1; }
    echo "$conf" | grep -q '^acs_chan_bias=1:0\.6 6:0\.6 11:0\.6$' || { echo "$conf"; return 1; }

    # 5 GHz presets on PA: min_tx_power=15 + acs_exclude_dfs=1 still scans all enabled PA channels.
    # Use VHT20 so hostapd skips post-ACS HT_SCAN (which resets hwsim survey_data).
    r "uci set wireless.radio0.disabled=1
       uci set wireless.radio1.disabled=0; uci set wireless.radio1.band=5g; uci set wireless.radio1.htmode=VHT20
       uci set wireless.radio1.country=PA; uci set wireless.radio1.channel=auto; uci set wireless.radio1.acs_exclude_dfs=1
       uci -q delete wireless.radio1.channels; uci -q delete wireless.radio1.hostapd_options
       uci add_list wireless.radio1.hostapd_options='acs_num_scans=1'
       uci add_list wireless.radio1.hostapd_options='min_tx_power=15'
       uci set wireless.default_radio1.disabled=0; uci set wireless.default_radio1.mode=ap; uci set wireless.default_radio1.network=lan
       uci set wireless.default_radio1.ssid=pa-acs; uci set wireless.default_radio1.encryption=psk2
       uci set wireless.default_radio1.key=bench-pass-1
       uci commit wireless; wifi down" >/dev/null
    wait_for 30 phy1_gone || true
    r "rm -f /tmp/acs-de.log /tmp/acs-de.pid
       sh -c 'echo \$\$ > /tmp/acs-de.pid; exec logread -f' > /tmp/acs-de.log 2>&1 &
       sleep 1; wifi up radio1" >/dev/null
    wait_for 30 phy1_done || { r 'kill $(cat /tmp/acs-de.pid 2>/dev/null) 2>/dev/null || true; cat /tmp/acs-de.log'; return 1; }
    r 'kill $(cat /tmp/acs-de.pid 2>/dev/null) 2>/dev/null || true; rm -f /tmp/acs-de.pid' >/dev/null
    conf5="$(r 'cat /var/run/hostapd-phy1.conf')"
    echo "$conf5" | grep -q '^acs_exclude_dfs=1$' || { echo "$conf5"; return 1; }
    echo "$conf5" | grep -q '^acs_num_scans=1$' || { echo "$conf5"; return 1; }
    echo "$conf5" | grep -q '^min_tx_power=15$' || { echo "$conf5"; return 1; }
    avail="$(r 'iw phy phy1 info' | grep -E '5[0-9]{3}\.0 MHz' | grep -vc '(disabled)')"
    cnt="$(r 'iw dev phy1-ap0 survey dump' | awk '/frequency:/{f=$2} /channel active time:/{if (f>=5000 && $4+0>0) c++} END{print c+0}')"
    printf '%s/%s\n' "$cnt" "$avail" > "$W/acs-pa-cnt"
    [ "$avail" -ge 24 ] && [ "$cnt" = "$avail" ] || { echo "PA 5 GHz surveyed channels: $cnt != $avail"; return 1; }
}
t_acs_migration() {
    r '
    cp /etc/config/wireless /tmp/w.bak
    cp /etc/config/a5v4 /tmp/a.bak
    uci -q delete a5v4.defaults.acs; uci commit a5v4
    uci set wireless.radio0.band=2g; uci set wireless.radio0.channel=1
    uci -q delete wireless.radio0.channels; uci -q delete wireless.radio0.acs_chan_bias
    uci -q delete wireless.radio0.hostapd_options; uci add_list wireless.radio0.hostapd_options="foo=bar"
    uci set wireless.radio1.band=5g; uci set wireless.radio1.channel=36
    uci -q delete wireless.radio1.acs_exclude_dfs; uci -q delete wireless.radio1.hostapd_options
    uci commit wireless
    sh /rom/etc/uci-defaults/99-a5v4-defaults
    ok=1
    [ "$(uci -q get wireless.radio0.channels)" = "1-11" ] || ok=0
    [ "$(uci -q get wireless.radio0.acs_chan_bias)" = "1:0.6 6:0.6 11:0.6" ] || ok=0
    [ "$(uci -q get wireless.radio0.hostapd_options)" = "foo=bar acs_num_scans=2" ] || ok=0
    [ "$(uci -q get wireless.radio1.acs_exclude_dfs)" = "1" ] || ok=0
    [ "$(uci -q get wireless.radio1.hostapd_options)" = "acs_num_scans=1 min_tx_power=15" ] || ok=0
    [ "$(uci -q get a5v4.defaults.acs)" = "1" ] || ok=0
    # Second run changes nothing
    before="$(uci export wireless)"
    sh /rom/etc/uci-defaults/99-a5v4-defaults
    [ "$before" = "$(uci export wireless)" ] || ok=0
    # User values are preserved even if marker is absent
    uci -q delete a5v4.defaults.acs; uci commit a5v4
    uci -q delete wireless.radio0.channels; uci add_list wireless.radio0.channels="1 6 11"
    uci set wireless.radio0.acs_chan_bias="1:0.5"
    uci -q delete wireless.radio0.hostapd_options; uci add_list wireless.radio0.hostapd_options="acs_num_scans=4"
    uci set wireless.radio1.acs_exclude_dfs="0"
    uci -q delete wireless.radio1.hostapd_options
    uci add_list wireless.radio1.hostapd_options="acs_num_scans=3"
    uci add_list wireless.radio1.hostapd_options="min_tx_power=18"
    uci commit wireless
    sh /rom/etc/uci-defaults/99-a5v4-defaults
    [ "$(uci -q get wireless.radio0.channels)" = "'"'1 6 11'"'" ] || ok=0
    [ "$(uci -q get wireless.radio0.acs_chan_bias)" = "1:0.5" ] || ok=0
    [ "$(uci -q get wireless.radio0.hostapd_options)" = "acs_num_scans=4" ] || ok=0
    [ "$(uci -q get wireless.radio1.acs_exclude_dfs)" = "0" ] || ok=0
    [ "$(uci -q get wireless.radio1.hostapd_options)" = "acs_num_scans=3 min_tx_power=18" ] || ok=0
    cp /tmp/w.bak /etc/config/wireless; cp /tmp/a.bak /etc/config/a5v4
    rm -f /tmp/w.bak /tmp/a.bak
    [ "$ok" = 1 ]
    '
}
t_acs_luci() {
    local cj code js
    cj="$(mktemp)"
    nsx lan curl -s -o /dev/null -c "$cj" -d "luci_username=root&luci_password=" http://192.168.1.1/cgi-bin/luci/
    code="$(nsx lan curl -s -o /dev/null -w '%{http_code}' -b "$cj" http://192.168.1.1/cgi-bin/luci/admin/network/wireless)"
    rm -f "$cj"
    [ "$code" = 200 ] || { echo "wireless page status: $code"; return 1; }
    js="$(nsx lan curl -s --max-time 60 http://192.168.1.1/luci-static/resources/view/network/wireless.js)"
    echo "$js" | grep -q 'acs_exclude_dfs' || { echo "missing acs_exclude_dfs in wireless.js"; return 1; }
    echo "$js" | grep -q 'Include channels 12 and 13 in automatic channel selection' || { echo "missing 12-13 label in wireless.js"; return 1; }
    echo "$js" | grep -q 'Where every 5 GHz channel needs a radar check, automatic selection works only with this box on' || { echo "missing all-DFS note in wireless.js"; return 1; }
    r 'grep -q "Автовыбор включая DFS-каналы" /usr/lib/lua/luci/i18n/base.ru.lmo && grep -q "Автовыбор включая каналы 12 и 13" /usr/lib/lua/luci/i18n/base.ru.lmo && grep -q "автовыбор работает только с этой галочкой" /usr/lib/lua/luci/i18n/base.ru.lmo' || {
        echo "missing Russian strings in base.ru.lmo"; return 1
    }
}
phy1_gone() { ! r 'iw dev phy1-ap0 info >/dev/null 2>&1'; }
phy1_done() { r 'grep -q "phy1-ap0: AP-ENABLED" /tmp/acs-de.log 2>/dev/null'; }
t_acs_de_dfs() {
    local ch t0 t1 freqs surveyed_5g ch_vht80
    # Run VHT20 first so post-ACS HT_SCAN does not wipe hwsim survey_data, proving 149-173 stay unvisited
    r "uci set wireless.radio0.disabled=1
       uci set wireless.radio1.disabled=0; uci set wireless.radio1.band=5g; uci set wireless.radio1.htmode=VHT20
       uci set wireless.radio1.country=DE; uci set wireless.radio1.channel=auto; uci set wireless.radio1.acs_exclude_dfs=1
       uci -q delete wireless.radio1.channels; uci -q delete wireless.radio1.hostapd_options
       uci add_list wireless.radio1.hostapd_options=acs_num_scans=1
       uci add_list wireless.radio1.hostapd_options=min_tx_power=15
       uci set wireless.default_radio1.disabled=0; uci set wireless.default_radio1.mode=ap; uci set wireless.default_radio1.network=lan
       uci set wireless.default_radio1.ssid=de-acs; uci set wireless.default_radio1.encryption=psk2
       uci set wireless.default_radio1.key=bench-pass-1
       uci commit wireless; wifi down" >/dev/null
    wait_for 30 phy1_gone || true
    r "rm -f /tmp/acs-de.log /tmp/acs-de.pid
       sh -c 'echo \$\$ > /tmp/acs-de.pid; exec logread -f' > /tmp/acs-de.log 2>&1 &
       sleep 1; wifi up radio1" >/dev/null
    t0="$(date +%s)"
    wait_for 30 phy1_done
    local rc=$?
    t1="$(date +%s)"
    r 'kill $(cat /tmp/acs-de.pid 2>/dev/null) 2>/dev/null || true; rm -f /tmp/acs-de.pid' >/dev/null
    [ "$rc" = 0 ] || { r 'cat /tmp/acs-de.log'; return 1; }
    ch="$(r 'iw dev phy1-ap0 info' | sed -n 's/.*channel \([0-9]*\).*/\1/p')"
    surveyed_5g="$(r 'iw dev phy1-ap0 survey dump' | awk '/frequency:/{f=$2} /channel active time:/{if (f>=5000 && $4+0>0) printf "%s=%s ", f, $4}')"
    freqs="$(r 'iw phy phy1 info' | sed -n '/5180\.0 MHz/,/5870\.0 MHz/p' | grep -E 'MHz \[' | tr '\n' ';')"
    printf '%s\n' "$ch" > "$W/acs-de-ch"
    printf '%s\n' "$((t1 - t0))" > "$W/acs-de-s"
    printf '%s\n' "$freqs" > "$W/acs-de-freqs"
    printf '%s\n' "$surveyed_5g" > "$W/acs-de-surv"
    r 'grep -q "acs_exclude_dfs=1" /var/run/hostapd-phy1.conf && grep -q "min_tx_power=15" /var/run/hostapd-phy1.conf' || return 1
    [ -n "$ch" ] && [ "$ch" -ge 36 ] && [ "$ch" -le 48 ] || { echo "DE ch $ch not in 36-48"; return 1; }
    case "$surveyed_5g" in
        *5745=*|*5765=*|*5785=*|*5805=*|*5825=*|*5845=*|*5855=*|*5860=*|*5865=*)
            echo "DE 149-173 surveyed unexpectedly: $surveyed_5g"; return 1 ;;
    esac
    # Confirm VHT80 also skips DFS CAC and lands in 36-48
    r "uci set wireless.radio1.htmode=VHT80; uci commit wireless; wifi down" >/dev/null
    wait_for 30 phy1_gone || true
    r "rm -f /tmp/acs-de.log /tmp/acs-de.pid
       sh -c 'echo \$\$ > /tmp/acs-de.pid; exec logread -f' > /tmp/acs-de.log 2>&1 &
       sleep 1; wifi up radio1" >/dev/null
    wait_for 30 phy1_done || { r 'kill $(cat /tmp/acs-de.pid 2>/dev/null) 2>/dev/null || true; cat /tmp/acs-de.log'; return 1; }
    r 'kill $(cat /tmp/acs-de.pid 2>/dev/null) 2>/dev/null || true; rm -f /tmp/acs-de.pid' >/dev/null
    ch_vht80="$(r 'iw dev phy1-ap0 info' | sed -n 's/.*channel \([0-9]*\).*/\1/p')"
    [ -n "$ch_vht80" ] && [ "$ch_vht80" -ge 36 ] && [ "$ch_vht80" -le 48 ] || { echo "DE VHT80 ch $ch_vht80 not in 36-48"; return 1; }
}
am_nochan() { r 'grep -q "ACS: No available channels found" /tmp/acs-am.log 2>/dev/null && grep -q "AP-DISABLED" /tmp/acs-am.log 2>/dev/null'; }
am_cac() { r 'grep -q "DFS-CAC-START" /tmp/acs-am2.log 2>/dev/null'; }
t_acs_am_dfs() {
    local nochan cac
    r "uci set wireless.radio0.disabled=1
       uci set wireless.radio1.disabled=0; uci set wireless.radio1.band=5g; uci set wireless.radio1.htmode=VHT80
       uci set wireless.radio1.country=AM; uci set wireless.radio1.channel=auto; uci set wireless.radio1.acs_exclude_dfs=1
       uci -q delete wireless.radio1.channels; uci -q delete wireless.radio1.hostapd_options
       uci add_list wireless.radio1.hostapd_options=acs_num_scans=1
       uci add_list wireless.radio1.hostapd_options=min_tx_power=15
       uci commit wireless; wifi down" >/dev/null
    wait_for 30 phy1_gone || true
    r "rm -f /tmp/acs-am.log /tmp/acs-am.pid
       sh -c 'echo \$\$ > /tmp/acs-am.pid; exec logread -f' > /tmp/acs-am.log 2>&1 &
       sleep 1; wifi up radio1" >/dev/null
    wait_for 20 am_nochan
    local rc1=$?
    r 'kill $(cat /tmp/acs-am.pid 2>/dev/null) 2>/dev/null || true; rm -f /tmp/acs-am.pid' >/dev/null
    [ "$rc1" = 0 ] || { r 'cat /tmp/acs-am.log'; return 1; }
    ! r 'iw dev phy1-ap0 info 2>/dev/null | grep -q channel' || { echo "AM AP came up on a channel despite acs_exclude_dfs=1"; return 1; }
    nochan="$(r 'grep "ACS: No available channels found" /tmp/acs-am.log | head -n 1')"
    printf '%s\n' "$nochan" > "$W/acs-am-nochan"

    # With acs_exclude_dfs=0, ACS enters DFS-CAC-START (skip waiting out the 60 s CAC in hwsim)
    r "uci set wireless.radio1.acs_exclude_dfs=0; uci commit wireless; wifi down" >/dev/null
    wait_for 15 phy1_gone || true
    r "rm -f /tmp/acs-am2.log /tmp/acs-am2.pid
       sh -c 'echo \$\$ > /tmp/acs-am2.pid; exec logread -f' > /tmp/acs-am2.log 2>&1 &
       sleep 1; wifi up radio1" >/dev/null
    wait_for 25 am_cac
    local rc2=$?
    r 'kill $(cat /tmp/acs-am2.pid 2>/dev/null) 2>/dev/null || true; rm -f /tmp/acs-am2.pid' >/dev/null
    [ "$rc2" = 0 ] || { r 'cat /tmp/acs-am2.log'; return 1; }
    cac="$(r 'grep "DFS-CAC-START" /tmp/acs-am2.log | head -n 1')"
    printf '%s\n' "$cac" > "$W/acs-am-cac"
}
t_acs_restore_wifi() {
    r "rm -f /tmp/acs-lr.log /tmp/acs-ms /tmp/acs-lr.pid /tmp/acs-de.log /tmp/acs-de.pid /tmp/acs-am.log /tmp/acs-am.pid /tmp/acs-am2.log /tmp/acs-am2.pid
       uci set wireless.radio0.disabled=0; uci set wireless.radio1.disabled=0
       for radio in radio0 radio1; do
           uci set wireless.\$radio.band=2g; uci set wireless.\$radio.channel=1; uci set wireless.\$radio.htmode=HT20
           uci set wireless.\$radio.country=PA
           uci -q delete wireless.\$radio.channels; uci -q delete wireless.\$radio.acs_chan_bias
           uci -q delete wireless.\$radio.acs_exclude_dfs; uci -q delete wireless.\$radio.hostapd_options
       done
       uci set wireless.default_radio0.mode=ap; uci set wireless.default_radio0.ssid=bench-ap
       uci set wireless.default_radio0.encryption=psk2; uci set wireless.default_radio0.key=bench-pass-1
       uci set wireless.default_radio1.mode=sta; uci set wireless.default_radio1.ssid=bench-ap
       uci set wireless.default_radio1.encryption=psk2; uci set wireless.default_radio1.key=bench-pass-1
       uci set wireless.default_radio1.network=wwan
       uci commit wireless
       wifi down" >/dev/null
    wait_for 30 sta_gone || true
    r 'wifi up' >/dev/null
    t_wifi_wpa2
}
section "Wi-Fi ACS"
if r 'grep -qa acs_scan_duration /usr/sbin/wpad'; then
    check "ACS with channels and acs_num_scans=1 brings AP up (ACS-COMPLETED, no option errors)" t_acs_base
    ACS_BASE_MS="$(cat "$W/acs-base-ms" 2>/dev/null || true)"
    ACS_BASE_CHAN="$(cat "$W/acs-base-ch" 2>/dev/null || true)"
    ACS_BASE_SURVEY="$(cat "$W/acs-base-surv" 2>/dev/null || true)"
    [ -n "$ACS_BASE_MS" ] && info "ACS (1-11, 1 scan, default dwell) -> ch ${ACS_BASE_CHAN:-?}, ACS start to AP-ENABLED: $ACS_BASE_MS ms"
    [ -n "$ACS_BASE_SURVEY" ] && info "hwsim survey (default dwell): $ACS_BASE_SURVEY"
    check "ACS with acs_scan_duration=0 starts as without the option" t_acs_dur0
    ACS_DUR0_MS="$(cat "$W/acs-dur0-ms" 2>/dev/null || true)"
    [ -n "$ACS_DUR0_MS" ] && info "ACS (1-11, 1 scan, acs_scan_duration=0): $ACS_DUR0_MS ms"
    check "ACS with acs_scan_duration=300 increases ACS duration (11 ch * ~190 ms)" t_acs_dur300
    ACS_DUR300_MS="$(cat "$W/acs-dur300-ms" 2>/dev/null || true)"
    ACS_DUR300_SURVEY="$(cat "$W/acs-dur300-surv" 2>/dev/null || true)"
    [ -n "$ACS_DUR300_MS" ] && info "ACS (1-11, 1 scan, acs_scan_duration=300): $ACS_DUR300_MS ms (delta $((ACS_DUR300_MS - ACS_BASE_MS)) ms)"
    [ -n "$ACS_DUR300_SURVEY" ] && info "hwsim survey (acs_scan_duration=300): $ACS_DUR300_SURVEY"
    check "Fixed channel ignores acs_num_scans and acs_scan_duration (channel 1, 20 MHz)" t_acs_fixed_chan
    check "ACS presets write chanlist=1-11, bias, min_tx_power=15 and scan all PA channels" t_acs_preset_hostapd_conf
    PA_CNT="$(cat "$W/acs-pa-cnt" 2>/dev/null || true)"
    [ -n "$PA_CNT" ] && info "PA 5 GHz surveyed channels with min_tx_power=15: $PA_CNT"
    check "99-a5v4-defaults migrates ACS presets once and preserves user options" t_acs_migration
    check "LuCI wireless page and base.ru.lmo have ACS DFS and ch 12-13 options" t_acs_luci
    check "Country DE with acs_exclude_dfs=1 and min_tx_power=15 picks 36-48 and skips 149-173" t_acs_de_dfs
    DE_CH="$(cat "$W/acs-de-ch" 2>/dev/null || true)"
    DE_S="$(cat "$W/acs-de-s" 2>/dev/null || true)"
    DE_SURV="$(cat "$W/acs-de-surv" 2>/dev/null || true)"
    DE_FREQS="$(cat "$W/acs-de-freqs" 2>/dev/null || true)"
    [ -n "$DE_CH" ] && info "DE 5 GHz acs_exclude_dfs=1 min_tx_power=15 landed on ch $DE_CH (${DE_S:-?} s)"
    [ -n "$DE_SURV" ] && info "DE 5 GHz surveyed channels (VHT20): $DE_SURV"
    [ -n "$DE_FREQS" ] && info "DE 5 GHz regdb on hwsim: $DE_FREQS"
    check "Country AM (all DFS): no channels when DFS excluded, CAC starts when DFS enabled" t_acs_am_dfs
    AM_NOCHAN="$(cat "$W/acs-am-nochan" 2>/dev/null || true)"
    AM_CAC="$(cat "$W/acs-am-cac" 2>/dev/null || true)"
    [ -n "$AM_NOCHAN" ] && info "AM (acs_exclude_dfs=1): $AM_NOCHAN"
    [ -n "$AM_CAC" ] && info "AM (acs_exclude_dfs=0, 60 s hwsim CAC wait skipped): $AM_CAC"
    check "Wi-Fi restored to bench configuration and client re-associated" t_acs_restore_wifi
else
    skip "Wi-Fi ACS" "wpad of the image has no acs_scan_duration"
fi

section "Persistence"
check "no kernel Oops, BUG or panic" t_kernel_clean
info "memory after the tests: $(r "grep -E 'MemAvailable' /proc/meminfo" | tr -s ' ')"
r "uci set system.@system[0].hostname=benchrouter; uci commit system; sync" >/dev/null
if [ "$NETDEF" = yes ]; then
    r "s=\$(uci add network device); uci set network.\$s.name='$WANDEV'; uci set network.\$s.gro=1; uci commit network; sync" >/dev/null
fi
if has xl2tpd && [ "$L2TP_OK" = 1 ]; then
    l2tp_uci_add
fi
r 'reboot' >/dev/null 2>&1 || true
ssh_down() { ! r true; }
wait_for 120 ssh_down || true
BOOT2_SECS="$(wait_ssh)"
info "second boot to SSH: $BOOT2_SECS s"
if has xl2tpd && [ "$L2TP_OK" = 1 ]; then
    L2TP_BOOT_T0="$(date +%s)"
    wait_for 90 l2tp_addr >/dev/null 2>&1 || true
    L2TP_BOOT_SECS=$(( $(date +%s) - L2TP_BOOT_T0 ))
    info "L2TP address after reboot: $L2TP_BOOT_SECS s from SSH"
    check "L2TP at boot (10.65.0.x, kernel modules, kernel support log, ping 10.65.0.1)" t_l2tp_up
    l2tp_uci_del
fi
t_persist() { [ "$(r 'uci get system.@system[0].hostname')" = benchrouter ]; }
check "settings survive a reboot (overlay)" t_persist
check "no kernel Oops, BUG or panic after the reboot" t_kernel_clean
if [ "$NETDEF" = yes ]; then
    # the init script runs at every boot
    check "GRO off on eth0 after the reboot" t_gro_off_eth0
    check "threaded NAPI on eth0 after the reboot" t_threaded_napi
    check "a device section with gro 1 turns GRO on ($WANDEV)" t_gro_on_by_section
fi

echo "Failed: $FAILS, skipped: $SKIPS" | tee -a "$RESULTS"

if [ "$SHELL_AFTER" = 1 ]; then
    echo "Shell in the LAN namespace; the router is 192.168.1.1 (ssh root@192.168.1.1). Exit to stop."
    nsx lan bash || true
fi

exit "$FAILS"
