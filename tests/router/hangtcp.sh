#!/bin/sh
# Width switches of the 2.4 GHz radio while a phone that runs iperf-phone.sh moves TCP through it
# (4 flows), the case of the hang of 2026-11-03: in each 240 s cycle one switch 8 s into the
# phone's download (the TX queues full) and one 8 s into its upload. The modes rotate as in
# hangload.sh (HT40 with the coexistence scan, HT20, HT40 noscan); the configuration file goes back
# to the original 5 s after each switch, so a reboot always comes back with it, and a last switch
# at the end puts the running radio back to the original too. A switch after which phy0-ap0 does
# not forward within 60 s, or an MCU timeout, stops the test: the evidence (tasks in D state with
# their stacks, SysRq w, dmesg) goes to /tmp/hang-evidence.log and /root/hang-evidence.log, and with
# REBOOT=1 the router reboots 3 minutes later (through SysRq if a plain reboot hangs). A switch is
# left out when the radio sends less than MIN Mbit/s (default 5) in the 3 s before it, so that only
# switches under load count; the test ends after <switches> of them or <cycles> cycles.
# Usage: sh hangtcp.sh <cycles> [switches]   (log: /tmp/hangtcp.log)
N=${1:-15}; MAXSW=${2:-1000}; MIN=${MIN:-5}; L=/tmp/hangtcp.log; ORIG=/tmp/wireless.orig
[ -f $ORIG ] || cp /etc/config/wireless $ORIG
dtasks() { for t in /proc/[0-9]*; do [ "$(awk '{print $3}' $t/stat 2>/dev/null)" = D ] && echo "${t#/proc/}:$(cat $t/comm)"; done; }
# dmesg lines start with "[ 1803.410440]"
fwd_after() { dmesg | awk -v t0="$1" '/phy0-ap0\) entered forwarding state/ { s = $0; sub(/^\[ */, "", s); sub(/\].*/, "", s); if (s + 0 > t0) f = 1 } END { exit !f }'; }
txb() { awk '{gsub(":",": ")} $1=="phy0-ap0:"{print $10}' /proc/net/dev; }
until_t() { d=$(( $1 - $(date +%s) )); [ $d -gt 0 ] && sleep $d; }
evidence() {
	echo "== HANG at switch $1 ($(date +%T))"; echo "-- D tasks: $(dtasks | tr '\n' ' ')"
	for p in $(dtasks | cut -d: -f1); do echo "-- stack of $p $(cat /proc/$p/comm) wchan $(cat /proc/$p/wchan)"; cat /proc/$p/stack; done
	echo w > /proc/sysrq-trigger; sleep 2
	echo "-- dmesg tail"; dmesg | tail -n 200
}
k=0
# $1 = mode, $2 = noscan or "", $3 = what the phone does
switch() {
	b0=$(txb); sleep 3; b1=$(txb); rate=$(( (b1 - b0) * 8 / 3000000 ))
	if [ "$1" != orig ] && [ $rate -lt $MIN ]; then echo "$(date +%T) the phone's $3: $rate Mbit/s, no switch" >> $L; return; fi
	k=$((k + 1)); to0=$(dmesg | grep -c 'timed out')
	if [ "$1" = orig ]; then cp $ORIG /etc/config/wireless; else
		uci set wireless.radio0.htmode=$1
		[ -n "$2" ] && uci set wireless.radio0.noscan=1 || uci -q delete wireless.radio0.noscan
		uci commit wireless
	fi
	t0=$(cut -d' ' -f1 /proc/uptime)
	( wifi up radio0 ) </dev/null >/dev/null 2>&1 &
	sleep 5; cp $ORIG /etc/config/wireless
	ok=0; s=5
	while [ $s -lt 60 ]; do sleep 2; s=$((s + 2)); fwd_after "$t0" && { ok=1; break; }; done
	to1=$(dmesg | grep -c 'timed out'); sleep 3
	w=""; [ $ok = 1 ] && [ -z "$(dtasks | grep -E 'hostapd|iw$')" ] &&
		w=$(iw dev phy0-ap0 info 2>/dev/null | sed -n 's/.*width: \([0-9]*\) MHz.*/\1/p')
	echo "switch $k ($(date +%T)) to $1${2:+ noscan} in the phone's $3 at $rate Mbit/s TX: up after ${s} s ok=$ok width=${w:-?} mcu_timeouts=$((to1 - to0)) D=[$(dtasks | tr '\n' ' ')]" >> $L
	if [ $ok = 0 ] || [ $((to1 - to0)) -gt 0 ]; then
		evidence $k > /tmp/hang-evidence.log 2>&1; cp /tmp/hang-evidence.log /root/hang-evidence.log; sync
		echo "stopped: see /tmp/hang-evidence.log" >> $L
		if [ "$REBOOT" = 1 ]; then
			sleep 180; echo "reboot $(date +%T)" >> /root/hang-evidence.log; sync; reboot; sleep 120
			echo s > /proc/sysrq-trigger; echo b > /proc/sysrq-trigger
		fi
		exit 1
	fi
}
mode() { case $((k % 3)) in 0) echo "HT40 -";; 1) echo "HT20 -";; 2) echo "HT40 noscan";; esac; }
echo "start $(date +%T), $N cycles" >> $L
base=$(( $(date +%s) / 240 * 240 + 240 )); [ $(( base - $(date +%s) )) -lt 135 ] && base=$((base + 240))
c=0
while [ $c -lt $N ] && [ $k -lt $MAXSW ]; do
	c=$((c + 1))
	until_t $((base + 125)); set -- $(mode); switch $1 "${2#-}" download
	[ $k -lt $MAXSW ] || break
	until_t $((base + 155)); set -- $(mode); switch $1 "${2#-}" upload
	base=$((base + 240))
done
until_t $((base + 20)); switch orig "" "pause (back to the original)"
echo "done $(date +%T), no hang" >> $L
