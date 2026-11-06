#!/bin/sh
# Router side of the iperf3 tests (iperf-pc.ps1, iperf-phone.sh): in the 240 s cycle that the
# clients keep by the clock, the router sets one state per cycle in the free window at 190 s and
# profiles each client slot with kprof, which also counts the traffic of every interface and how
# late a process at normal priority gets the CPU. kprof starts 2 s before a run and samples 22 s,
# so that the run is covered whole: under a run that saturates the CPU this script itself may not
# get the CPU for many seconds, and a profile started after the run began would miss it or slide
# onto the next one. Slot times are absolute. States:
#   A = the default (GRO with fraglist, flow offloading)   B = GRO without fraglist
#   C = no GRO                                             D = the default without flow offloading
#   T = the default with threaded NAPI on eth0             U = no GRO, threaded NAPI on eth0
#   (GRO on eth0 and both radios)
# Flow offloading is turned off without a commit, so a reboot brings it back. Everything returns
# to A at the end. Samples of the modules go to /tmp/labtest-mod/<cycle>-<slot>.txt.
# Usage: sh labtest.sh <cycles> [states, default "A B C D"]   (log: /tmp/labtest.log)
N=${1:-12}; STATES=${2:-A B C D}; L=/tmp/labtest.log; M=/tmp/labtest-mod
E=$(command -v ethtool || echo /tmp/ethtool); KPROF=${KPROF:-$(command -v kprof || echo /tmp/kprof)}
mkdir -p $M
setstate() {
	case $1 in
		B) g=on; l=off ;;
		C|U) g=off; l=off ;;
		*) g=on; l=on ;;
	esac
	for d in eth0 phy0-ap0 phy1-ap0; do $E -K $d gro $g rx-gro-list $l 2>/dev/null; done
	case $1 in T|U) echo 1 ;; *) echo 0 ;; esac > /sys/class/net/eth0/threaded
	if [ "$1" = D ]; then
		uci set firewall.@defaults[0].flow_offloading=0; fw4 -q reload
	elif [ -n "$(uci -q changes firewall)" ]; then
		uci revert firewall; fw4 -q reload
	fi
}
# Sleeps until the absolute time $1; returns 1 when that time passed more than 5 s ago
until_t() { d=$(( $1 - $(date +%s) )); [ $d -lt -5 ] && return 1; [ $d -gt 0 ] && sleep $d; return 0; }
echo "start $(date +%T), $N cycles, states $STATES" >> $L
ns=$(echo $STATES | wc -w); c=0
# The first cycle starts at the next 0 s that leaves the window at 190 s ahead
base=$(( $(date +%s) / 240 * 240 + 240 )); [ $(( base - $(date +%s) )) -lt 50 ] && base=$((base + 240))
while [ $c -lt $N ]; do
	st=$(echo $STATES | cut -d' ' -f$((c % ns + 1))); c=$((c + 1))
	until_t $((base - 50)); setstate $st
	echo "== cycle $c, state $st, $(date +%T), flowtable $(nft list flowtables 2>/dev/null | grep -c 'flowtable ft'), eth0 threaded $(cat /sys/class/net/eth0/threaded)" >> $L
	for slot in 0 30 60 90 120 150; do
		case $slot in
			0) name="PC cable, download";; 30) name="PC cable, upload";;
			60) name="PC Wi-Fi, download";; 90) name="PC Wi-Fi, upload";;
			120) name="phone, download";; 150) name="phone, upload";;
		esac
		if ! until_t $((base + slot - 2)); then
			echo "-- $name (state $st): skipped, the script was late" >> $L
			continue
		fi
		{
			echo "-- $name (state $st), $(date +%T)"
			$KPROF 22 1000 12 $M/$c-$slot.txt 2>&1 | sed -n '1,3p;5,20p'
		} >> $L
	done
	base=$((base + 240))
done
until_t $((base - 50)); setstate A
echo "end $(date +%T)" >> $L
