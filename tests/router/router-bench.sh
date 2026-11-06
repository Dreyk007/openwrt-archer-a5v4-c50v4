#!/bin/sh
# Measurements on the router for the A/B of the build profiles (TODO.md): memory, idle CPU, the
# speed of the programs (busybox, ucode, jsonfilter, ubus, uci, wg, dnsmasq) and the timeline of the
# last boot. The forwarding path is the kernel's and the same in both profiles; tests/router/
# luci-bench.sh measures LuCI.
#
#   ssh root@192.168.1.1 sh -s < tests/router/router-bench.sh
#
# Each program test runs three times; the median counts. Times come from /proc/uptime (10 ms), so
# the tests are sized to take seconds. Inputs are the same in both profiles.

T=/tmp/router-bench
rm -rf "$T"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

now() { cut -d' ' -f1 /proc/uptime; }

# $1 = name, $2 = shell command; prints the three times and their median in seconds
bench() {
	: > "$T/t"
	for r in 1 2 3; do
		a="$(now)"
		sh -c "$2" > /dev/null 2>&1
		b="$(now)"
		awk -v a="$a" -v b="$b" 'BEGIN { printf "%.2f\n", b - a }' >> "$T/t"
	done
	sort -n "$T/t" | awk -v n="$1" '{ v[NR] = $1 } END { printf "%-34s %6.2f s   (%s %s %s)\n", n, v[2], v[1], v[2], v[3] }'
}

echo "== system"
echo "firmware   $(sed -n 's/^DISTRIB_DESCRIPTION=//p' /etc/openwrt_release | tr -d "'"), kernel $(uname -v)"
echo "busybox    $(wc -c < /bin/busybox) bytes, wpad $(wc -c < /usr/sbin/wpad) bytes"
echo "uptime     $(cut -d' ' -f1 /proc/uptime) s, load $(cut -d' ' -f1-3 /proc/loadavg)"

echo "== memory (kB)"
grep -E '^(MemTotal|MemFree|MemAvailable|Cached|Slab|SReclaimable|SUnreclaim|Shmem):' /proc/meminfo | tr -s ' '
for p in procd ubusd netifd hostapd wpa_supplicant dnsmasq uhttpd rpcd dropbear logd ntpd odhcpd udhcpc; do
	for pid in $(pidof "$p"); do
		awk -v p="$p" '/^VmRSS/ { r = $2 } /^RssAnon/ { a = $2 } END { printf "%-15s resident %5d  private %5d\n", p, r, a }' /proc/"$pid"/status
	done
done | sort -u

echo "== idle CPU over 30 s (%)"
s1="$(head -n 1 /proc/stat)"
sleep 30
s2="$(head -n 1 /proc/stat)"
echo "$s1
$s2" | awk 'NR == 1 { for (i = 2; i <= 9; i++) a[i] = $i } NR == 2 { for (i = 2; i <= 9; i++) { d[i] = $i - a[i]; t += d[i] }
	printf "user %.1f  system %.1f  softirq %.1f  irq %.1f  idle %.1f\n", 100 * d[2] / t, 100 * d[4] / t, 100 * d[8] / t, 100 * d[7] / t, 100 * d[5] / t }'

echo "== programs (median of 3)"
# The same input in both profiles: the scripts and translations of LuCI
cat /www/luci-static/resources/*.js /www/luci-static/resources/view/*/*.js /usr/lib/lua/luci/i18n/*.lmo 2> /dev/null > "$T/blob"
cat "$T/blob" "$T/blob" "$T/blob" "$T/blob" > "$T/blob4"
echo "input      $(wc -c < "$T/blob4") bytes of LuCI scripts and translations"
ubus call network.interface dump > "$T/if.json"
bench "busybox ash loop, 20000 rounds" 'i=0; while [ $i -lt 20000 ]; do i=$((i + 1)); done'
bench "exec busybox, 200 times" 'for i in $(seq 200); do /bin/true; done'
bench "busybox gzip, input" "gzip -c $T/blob4"
bench "busybox sha256sum, input x3" "sha256sum $T/blob4 $T/blob4 $T/blob4"
bench "ucode loop, 200000 rounds" "ucode -e 'let s = 0; for (let i = 0; i < 200000; i++) s += i % 7;'"
bench "ucode JSON, 3000 objects x5" "ucode -e 'let o = []; for (let i = 0; i < 3000; i++) push(o, { a: i, b: \"x\" + i, c: [ i, i * 2 ] }); let j = sprintf(\"%J\", o); for (let k = 0; k < 5; k++) json(j);'"
bench "jsonfilter, 200 times" "for i in \$(seq 200); do jsonfilter -i $T/if.json -e '@.interface[*].interface'; done"
bench "ubus call system board, 150 times" 'for i in $(seq 150); do ubus call system board; done'
bench "uci show network, 200 times" 'for i in $(seq 200); do uci show network; done'
bench "wg genkey | wg pubkey, 100 times" 'for i in $(seq 100); do wg genkey | wg pubkey; done'
bench "nslookup via dnsmasq, 200 times" 'for i in $(seq 200); do nslookup openwrt.org 127.0.0.1; done'

echo "== last boot (s after the kernel started)"
dmesg | awk '
	/init: - preinit -/ && !p { printf "preinit                %7.1f\n", t($0); p = 1 }
	/procd: - init -/ && !i { printf "procd init             %7.1f\n", t($0); i = 1 }
	/kmodloader: done loading kernel modules from \/etc\/modules.d/ && !k { printf "modules loaded         %7.1f\n", t($0); k = 1 }
	/rt3050-esw.*port 0 link up/ && !w { printf "WAN port link up       %7.1f\n", t($0); w = 1 }
	/br-lan: port .*\(eth0\.1\) entered forwarding/ && !l { printf "LAN bridge forwarding  %7.1f\n", t($0); l = 1 }
	/\(phy0-ap0\) entered forwarding/ && !a { printf "2.4 GHz AP forwarding  %7.1f\n", t($0); a = 1 }
	/\(phy1-ap0\) entered forwarding/ && !b { printf "5 GHz AP forwarding    %7.1f\n", t($0); b = 1 }
	function t(s) { sub(/^\[ */, "", s); sub(/\].*/, "", s); return s + 0 }'
# Daemon events have the wall clock of logd only: map it to the uptime with a kernel line logged
# after logd started (before NTP corrects the clock)
logread | awk '
	function sec(s,  a) { split(s, a, ":"); return a[1] * 3600 + a[2] * 60 + a[3] }
	/kernel: \[ *[0-9.]+\] br-lan: port .* entered forwarding/ && !base {
		u = $0; sub(/.*kernel: \[ */, "", u); sub(/\].*/, "", u); base = sec($4) - u }
	{ lines[NR] = $0; w[NR] = sec($4) }
	END { for (n = 1; n <= NR; n++) {
		if (lines[n] ~ /Interface .wan. is now up/ && !wan) { printf "WAN up                 %7.0f\n", w[n] - base; wan = 1 }
		if (lines[n] ~ /Interface .wg0. is now up/ && !wg) { printf "wg0 up                 %7.0f\n", w[n] - base; wg = 1 } } }'
