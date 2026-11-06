#!/bin/sh
# Server-side timing of LuCI on the router: the HTML of the Overview page, the ubus calls of the
# Overview, Wireless and Firewall pages, each page's calls in one JSON-RPC batch as LuCI sends them,
# and one static script. For the A/B of the build profiles (TODO.md); the numbers include uhttpd,
# ubusd, rpcd and its ucode plugins, not the browser or the network.
#
# Runs on the router itself (curl is in the image):
#   ssh root@192.168.1.1 sh -s [rounds] < tests/router/luci-bench.sh
# A temporary session with root's rights is created over ubus (no password needed) and destroyed
# at the end.

ROUNDS="${1:-20}"
URL=http://127.0.0.1
T=/tmp/luci-bench
rm -rf "$T"
mkdir -p "$T"

sid="$(ubus call session create '{"timeout":600}' | jsonfilter -e '@.ubus_rpc_session')"
[ -n "$sid" ] || { echo "no ubus session" >&2; exit 1; }
trap 'ubus call session destroy "{\"ubus_rpc_session\":\"$sid\"}" >/dev/null 2>&1; rm -rf "$T"' EXIT
# The rights of root's login: rpcd matches ubus, uci and file access with wildcards, but the LuCI
# dispatcher looks up the access groups of a page by name, so each group is granted by its name
groups="$(ucode -l fs -e 'let g = []; for (let f in fs.glob("/usr/share/rpcd/acl.d/*.json"))
	for (let k in keys(json(fs.readfile(f)) ?? {})) push(g, sprintf("[\"%s\",\"read\"],[\"%s\",\"write\"]", k, k));
	print(join(",", uniq(g)));')"
for grant in 'ubus:[["*","*"]]' 'uci:[["*","read"],["*","write"]]' 'file:[["*","*"]]' \
             'cgi-io:[["*","*"]]' "access-group:[$groups]"; do
	ubus call session grant "{\"ubus_rpc_session\":\"$sid\",\"scope\":\"${grant%%:*}\",\"objects\":${grant#*:}}" >/dev/null
done
token="$(tr -d '-' < /proc/sys/kernel/random/uuid)"
ubus call session set "{\"ubus_rpc_session\":\"$sid\",\"values\":{\"username\":\"root\",\"token\":\"$token\"}}"

# JSON-RPC batches: one line per call, "object method arguments"
devices="$(ubus call iwinfo devices | jsonfilter -e '@.devices[*]')"
{
	for c in "luci getVersion" "luci getUnixtime" "system board" "system info" "luci getMountPoints" \
	         "luci getBuiltinEthernetPorts" "network.device status" "network.interface dump" \
	         "luci-rpc getBoardJSON" "luci-rpc getNetworkDevices" "luci-rpc getWirelessDevices" \
	         "luci-rpc getHostHints" "luci-rpc getDHCPLeases" "luci getFeatures" "session access"; do
		echo "$c {}"
	done
	for c in network wireless dhcp firewall; do echo "uci get {\"config\":\"$c\"}"; done
	for d in $devices; do echo "iwinfo assoclist {\"device\":\"$d\"}"; done
} > "$T/overview.calls"
{
	echo "luci-rpc getWirelessDevices {}"
	echo "network.interface dump {}"
	echo "uci get {\"config\":\"wireless\"}"
	for d in $devices; do
		for m in freqlist txpowerlist countrylist assoclist; do echo "iwinfo $m {\"device\":\"$d\"}"; done
	done
} > "$T/wireless.calls"
{
	echo "luci getConntrackHelpers {}"
	echo "network.interface dump {}"
	echo "luci-rpc getNetworkDevices {}"
	for c in firewall network; do echo "uci get {\"config\":\"$c\"}"; done
} > "$T/firewall.calls"
for page in overview wireless firewall; do
	n=0
	while read -r obj method args; do
		n=$((n + 1))
		printf '%s{"jsonrpc":"2.0","id":%d,"method":"call","params":["%s","%s","%s",%s]}' \
			"$([ "$n" -gt 1 ] && echo ,)" "$n" "$sid" "$obj" "$method" "$args"
	done < "$T/$page.calls" | sed 's/^/[/; s/$/]/' > "$T/$page.json"
	n="$(wc -l < "$T/$page.calls")"
	# Every call of the batch has to succeed, or the timing means nothing
	curl -s -H 'Content-Type: application/json' --data-binary @"$T/$page.json" "$URL/ubus" > "$T/$page.out"
	ok="$(jsonfilter -i "$T/$page.out" -e '@[*].result[0]' | grep -c '^0$')"
	[ "$ok" = "$n" ] || echo "warning: $page: $ok of $n calls succeeded" >&2
done

stats() { # $1 = file of seconds, $2 = name
	sort -n "$1" | awk -v name="$2" '{ v[NR] = $1 * 1000 }
		END { printf "%-36s median %6.1f ms   p90 %6.1f ms   (n = %d)\n", name, v[int((NR + 1) / 2)], v[int(NR * 0.9 + 0.5)], NR }'
}
measure() { # $1 = name, then the arguments of curl for one request
	name="$1"
	shift
	: > "$T/times"
	r=0
	while [ "$r" -lt $((ROUNDS + 2)) ]; do
		# the first two rounds warm up the page cache and are not counted
		t="$(curl -s -o /dev/null -w '%{time_total}' "$@")"
		[ "$r" -ge 2 ] && echo "$t" >> "$T/times"
		r=$((r + 1))
	done
	stats "$T/times" "$name"
}

# Without a valid session the dispatcher answers with the login form instead of the page
code="$(curl -s -o "$T/page.html" -w '%{http_code}' -H "Cookie: sysauth_http=$sid" "$URL/cgi-bin/luci/admin/status/overview")"
if [ "$code" != 200 ] || grep -q 'luci_password' "$T/page.html"; then
	echo "warning: the Overview page did not render with the session (HTTP $code)" >&2
fi

echo "$(grep -E 'MemAvailable' /proc/meminfo | tr -s ' ') before; $ROUNDS rounds"
measure "Overview, HTML (ucode dispatcher)" -H "Cookie: sysauth_http=$sid" "$URL/cgi-bin/luci/admin/status/overview"
measure "Login page, HTML" "$URL/cgi-bin/luci/"
for page in overview wireless firewall; do
	measure "$page, ubus batch ($(wc -l < "$T/$page.calls") calls)" \
		-H 'Content-Type: application/json' --data-binary @"$T/$page.json" "$URL/ubus"
done
measure "luci.js (static file)" "$URL/luci-static/resources/luci.js"
echo "$(grep -E 'MemAvailable' /proc/meminfo | tr -s ' ') after"
for p in uhttpd rpcd; do
	for pid in $(pidof "$p"); do
		echo "$p: $(sed -n 's/^VmRSS:[[:space:]]*/resident /p; s/^RssAnon:[[:space:]]*/private /p' /proc/"$pid"/status | tr '\n' ' ')"
	done
done
