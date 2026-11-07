#!/bin/sh
# Router side of the tests with a phone that runs iperf-phone.sh, in the 240 s cycle that the phone
# keeps by the clock: UDP from the router to the phone at 0 s (udptest.sh), iperf3 through the
# WireGuard tunnel to a server on its other side, upload at 30 s and download at 60 s, and kprof
# over the phone's download (120 s) and upload (150 s), with the phone's TX retries and failures.
# The state of each cycle (A, C, T, U of labtest.sh) is set at 190 s of the cycle before; the
# router goes back to A at the end. iperf3 on the router takes CPU of its own, so the WireGuard
# numbers are those of the router's own traffic, a bound for traffic it forwards into the tunnel.
# Usage: sh wifitest.sh <cycles> <states> <phone ip> <phone mac> <iperf3 server ip> [port, 5210]
#   (log: /tmp/wifitest.log; SLOTS="30 60 120 150" leaves out the UDP to the phone; KPROF=none
#   counts only the CPU and the traffic, from /proc, without sampling; REVIVE=1 takes both radios
#   down for 45 s after a cycle in which the phone's download moved less than 5 MB, which frees an
#   iperf3 client that hangs, and waits for the phone to come back; only while the phone is on the
#   router)
N=${1:-10}; STATES=${2:-A U}; PIP=$3; PMAC=$4; WG=$5; WP=${6:-5210}; L=/tmp/wifitest.log
D=$(dirname "$0"); E=$(command -v ethtool || echo /tmp/ethtool)
KPROF=${KPROF:-$(command -v kprof || echo /tmp/kprof)}
UDPTEST=$( [ -f $D/udptest.sh ] && echo $D/udptest.sh || echo /usr/share/a5v4-diag/udptest.sh)
setstate() {
	case $1 in
		B) g=on; l=off ;;
		C|U) g=off; l=off ;;
		*) g=on; l=on ;;
	esac
	for d in eth0 phy0-ap0 phy1-ap0; do $E -K $d gro $g rx-gro-list $l 2>/dev/null; done
	case $1 in T|U) echo 1 ;; *) echo 0 ;; esac > /sys/class/net/eth0/threaded
}
until_t() { d=$(( $1 - $(date +%s) )); [ $d -lt -5 ] && return 1; [ $d -gt 0 ] && sleep $d; return 0; }
# The phone's station counters: tx packets, retries, failed
sta() {
	for d in phy0-ap0 phy1-ap0; do
		iw dev $d station get $PMAC 2>/dev/null | awk -v d=$d '/tx packets/{p=$3}/tx retries/{r=$3}/tx failed/{f=$3}
			/signal:/{s=$2}/tx bitrate/{$1=$2="";t=$0}END{if(p!="")print d,p,r,f,s,t}'
	done
}
stad() {
	echo "$1|$2" | awk -F'|' '{split($1,a," "); m=split($2,b," ");
		if (m < 5) {print "phone: not connected"; exit}
		if (a[1] != b[1]) {print "phone: moved to " b[1]; exit}
		p=b[2]-a[2]; t=""; for (i=6; i<=m; i++) t=t " " b[i];
		printf "phone on %s: %d packets sent, %.2f retries per packet, %d failed, signal %s dBm, tx%s\n",
			b[1], p, (p ? (b[3]-a[3])/p : 0), b[4]-a[4], b[5], t}'
}
# The CPU and the traffic over $1 s from /proc, for KPROF=none
light() {
	c0=$(head -1 /proc/stat); n0=$(cat /proc/net/dev); sleep $1; c1=$(head -1 /proc/stat); n1=$(cat /proc/net/dev)
	echo "$c0 $c1" | awk -v t=$1 '{u=$13+$14-$2-$3; s=$15-$4; i=$16-$5; q=$18+$19-$7-$8; a=u+s+i+q+$17-$6;
		printf "CPU over %d s: idle %d%%, system %d%%, softirq+irq %d%%, user %d%%\n", t, i*100/a, s*100/a, q*100/a, u*100/a}'
	printf 'traffic (Mbit/s):'
	{ echo "$n0"; echo "==="; echo "$n1"; } | awk -v t=$1 '{gsub(":", ": ")} /^===/{x=1; next}
		$1 ~ /^(eth0|phy0-ap0|phy1-ap0):$/ {if (!x) {r[$1]=$2; s[$1]=$10} else printf " %s rx %.1f tx %.1f;", $1, ($2-r[$1])*8/t/1e6, ($10-s[$1])*8/t/1e6}'
	echo
}
prof() { if [ "$KPROF" = none ]; then light $1; else $KPROF $1 1000 12 2>&1 | sed -n '1,3p;5,16p'; fi; }
wtx() { awk '{gsub(":", ": ")} $1 == "phy0-ap0:" || $1 == "phy1-ap0:" {t += $10} END {print t}' /proc/net/dev; }
revive() {
	wifi down; sleep 45; wifi up; k=0
	while [ $k -lt 300 ]; do sleep 10; k=$((k + 10)); [ -n "$(sta)" ] && break; done
	echo "-- revived $(date +%T): both radios down 45 s, the phone back after $k s" >> $L
}
wgrun() { # $1 = "" upload, "-R" download
	iperf3 -c $WG -p $WP $1 -t 20 -O 2 2>&1 | grep -E 'sender|receiver|error' | sed 's/^/   /' &
	sleep 1; prof 20; wait
}
echo "start $(date +%T), $N cycles, states $STATES" >> $L
ns=$(echo $STATES | wc -w); c=0
base=$(( $(date +%s) / 240 * 240 + 240 )); [ $(( base - $(date +%s) )) -lt 55 ] && base=$((base + 240))
while [ $c -lt $N ]; do
	st=$(echo $STATES | cut -d' ' -f$((c % ns + 1))); c=$((c + 1))
	until_t $((base - 50)); setstate $st
	echo "== cycle $c, state $st, $(date +%T), eth0 threaded $(cat /sys/class/net/eth0/threaded), gro $($E -k eth0 | awk '/generic-receive-offload/{print $2}')" >> $L
	for slot in ${SLOTS:-0 30 60 120 150}; do
		if ! until_t $((base + slot - 2)); then echo "-- slot $slot (state $st): skipped, late" >> $L; continue; fi
		{
			case $slot in
				0) echo "-- UDP to the phone (state $st), $(date +%T)"; sleep 2; sh $UDPTEST $PIP $PMAC 20 2>&1 | grep -v '^ *[0-9.]*% *<-' | head -30 ;;
				30) echo "-- WireGuard upload (state $st), $(date +%T)"; sleep 2; wgrun "" ;;
				60) echo "-- WireGuard download (state $st), $(date +%T)"; sleep 2; wgrun -R ;;
				120|150) [ $slot = 120 ] && n=download || n=upload
					echo "-- phone $n (state $st), $(date +%T)"; a=$(sta); w0=$(wtx)
					prof 22; stad "$a" "$(sta)"
					[ $slot = 120 ] && dl=$(( $(wtx) - w0 )) ;;
			esac
		} >> $L 2>&1
	done
	# Only with the phone on the router (without it a restart frees nothing and only disturbs the
	# other clients), after its upload has ended (150 s + 22 s + the exchange of results)
	[ "$REVIVE" = 1 ] && [ -n "$dl" ] && [ "$dl" -lt 5000000 ] && [ -n "$(sta)" ] && { until_t $((base + 185)); revive; }
	dl=""; base=$((base + 240))
done
until_t $((base - 50)); setstate A
echo "end $(date +%T)" >> $L
