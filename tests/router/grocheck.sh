#!/bin/sh
# Does netifd's `gro` device option reach the Wi-Fi interfaces? Adds device sections with gro 0
# for eth0, phy0-ap0 and phy1-ap0, restarts the network (as at a boot), reads the GRO of each
# interface, once more after `wifi up radio0` (one radio rebuilt alone, as by a change in LuCI),
# then restores the original configuration with another restart. If the router has neither the
# internet nor the tunnel 5 minutes after a restart, it puts the original back and reboots.
# Usage: [PEER=<address of a tunnel peer>] sh grocheck.sh   (log: /tmp/grocheck.log; PEER also counts
# as reachable, for a router reached through a tunnel)
L=/tmp/grocheck.log; O=/tmp/network.orig
E=$(command -v ethtool || echo /tmp/ethtool)
cp /etc/config/network $O
gro() {
	for d in eth0 eth0.1 eth0.2 br-lan phy0-ap0 phy1-ap0; do
		printf '%s %s; ' $d "$($E -k $d 2>/dev/null | awk '/^generic-receive-offload/{print $2}')"
	done
}
net_ok() { ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 || { [ -n "$PEER" ] && ping -c1 -W3 "$PEER" >/dev/null 2>&1; }; }
waitnet() { k=0; while [ $k -lt 300 ]; do sleep 10; k=$((k + 10)); net_ok && return 0; done; return 1; }
wifi_ok() {
	k=0
	while [ $k -lt 120 ]; do
		sleep 5; k=$((k + 5))
		[ "$(cat /sys/class/net/phy0-ap0/operstate 2>/dev/null)" = up ] &&
			[ "$(cat /sys/class/net/phy1-ap0/operstate 2>/dev/null)" = up ] && return 0
	done
	return 1
}
rescue() {
	echo "no network after $1, $(date +%T): the original configuration back, reboot" >> $L
	cp $O /etc/config/network; sync; reboot; sleep 120
	echo s > /proc/sysrq-trigger; echo b > /proc/sysrq-trigger
}
echo "start $(date +%T); before: $(gro)" >> $L
for d in eth0 phy0-ap0 phy1-ap0; do
	s=$(uci add network device); uci set network.$s.name=$d; uci set network.$s.gro=0
done
uci commit network
/etc/init.d/network restart
waitnet || rescue "the restart with gro 0"
wifi_ok || echo "Wi-Fi not up 120 s after the restart" >> $L
sleep 10
echo "after the restart with gro 0, $(date +%T): $(gro)" >> $L
for d in eth0 phy0-ap0; do
	echo "netifd status of $d: $(ubus call network.device status "{\"name\":\"$d\"}" | grep -E '"gro"' | tr -d ' \t')" >> $L
done
wifi up radio0
sleep 15; wifi_ok || echo "Wi-Fi not up 120 s after wifi up radio0" >> $L
sleep 10
echo "after wifi up radio0, $(date +%T): $(gro)" >> $L
cp $O /etc/config/network
/etc/init.d/network restart
waitnet || rescue "the restore"
wifi_ok || echo "Wi-Fi not up 120 s after the restore" >> $L
sleep 10
echo "restored, $(date +%T): $(gro)" >> $L
