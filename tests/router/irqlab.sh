#!/bin/sh
# Router side of the A/B tests with clients at the site (iperf-pc.ps1, iperf-phone.sh): in their
# 240 s cycle one state per cycle, set at 190 s of the cycle before, and over each client slot the
# interrupts of eth0 and both radios with kprof (module samples in /tmp/irqlab-mod for modsym.py).
# Slot 0 sends UDP from the router to the phone (udptest.sh) when a phone is given, instead of the
# PC's cable download. States (edit setstate() for other switches; a switch that restarts a radio
# may lose a client, so prefer switches that apply at run time):
#   N = no interrupt moderation
#   E = delay interrupt of eth0 (ethtool -C, rx 200 us or 16 frames, tx 200 us or 32 frames)
#   W = E and the delay interrupts of the MT7612E (delay_int 0x9032880a, applied with wifi up radio1)
# Back to N at the end. Needs the debug image (kprof, ethtool, udptest.sh).
# Usage: sh irqlab.sh "<states>" [<phone ip> <phone mac>]   (log: /tmp/irqlab.log)
#   SLOTS="0 30 60 90 120 150" chooses the slots (default: all six)
STATES=${1:-N N N E E E W W W N N N}; PIP=$2; PMAC=$3
L=/tmp/irqlab.log; M=/tmp/irqlab-mod; mkdir -p $M
DLY=0x9032880a
setstate() {
	case $1 in
		N) ethtool -C eth0 rx-usecs 0 rx-frames 0 tx-usecs 0 tx-frames 0 2>/dev/null; want=0 ;;
		E) ethtool -C eth0 rx-usecs 200 rx-frames 16 tx-usecs 200 tx-frames 32 2>/dev/null; want=0 ;;
		W) ethtool -C eth0 rx-usecs 200 rx-frames 16 tx-usecs 200 tx-frames 32 2>/dev/null; want=$(printf %d $DLY) ;;
	esac
	if [ "$(cat /sys/module/mt76x02_lib/parameters/delay_int)" != "$want" ]; then
		echo $want > /sys/module/mt76x02_lib/parameters/delay_int
		wifi down radio1; sleep 3; wifi up radio1
		echo "-- radio1 restarted with delay_int $want, $(date +%T)" >> $L
	fi
}
irqs() { awk '/10100000.ethernet/{e=$2} /mt76x2e/{w=$2} /mt7603e/{v=$2} END{print e, w, v}' /proc/interrupts; }
until_t() { d=$(( $1 - $(date +%s) )); [ $d -lt -5 ] && return 1; [ $d -gt 0 ] && sleep $d; return 0; }
N=$(echo $STATES | wc -w); c=0
echo "start $(date +%T), states $STATES" >> $L
base=$(( $(date +%s) / 240 * 240 + 240 )); [ $(( base - $(date +%s) )) -lt 50 ] && base=$((base + 240))
while [ $c -lt $N ]; do
	c=$((c + 1)); st=$(echo $STATES | cut -d' ' -f$c)
	until_t $((base - 50)); setstate $st
	echo "== cycle $c, state $st, $(date +%T), eth0 $(ethtool -c eth0 | awk '/^rx-usecs:|^rx-frames:|^tx-usecs:|^tx-frames:/{printf "%s%s ", $1, $2}')delay_int $(cat /sys/module/mt76x02_lib/parameters/delay_int), threaded $(cat /sys/class/net/eth0/threaded)" >> $L
	for slot in ${SLOTS:-0 30 60 90 120 150}; do
		case $slot in
			0) name="PC cable, download"; [ -n "$PIP" ] && name="UDP to the phone" ;;
			30) name="PC cable, upload";;
			60) name="PC Wi-Fi, download";; 90) name="PC Wi-Fi, upload";;
			120) name="phone, download";; 150) name="phone, upload";;
		esac
		if ! until_t $((base + slot - 2)); then echo "-- $name (state $st): skipped, late" >> $L; continue; fi
		i0=$(irqs); t0=$(cut -d' ' -f1 /proc/uptime)
		if [ $slot = 0 ] && [ -n "$PIP" ]; then
			out=$(sh /usr/share/a5v4-diag/udptest.sh $PIP $PMAC 20 2>&1 | grep -v '^ *[0-9.]*% *<-' | head -24)
		else
			out=$(kprof 22 1000 12 $M/$c-$slot.txt 2>&1 | sed -n '1,3p;5,20p')
		fi
		i1=$(irqs); t1=$(cut -d' ' -f1 /proc/uptime)
		{
			echo "-- $name (state $st), $(date +%T)"
			echo "$i0 $i1 $t0 $t1" | awk '{d=$8-$7; printf "interrupts/s: eth0 %d, mt76x2e %d, mt7603e %d\n", ($4-$1)/d, ($5-$2)/d, ($6-$3)/d}'
			echo "$out"
		} >> $L
	done
	base=$((base + 240))
done
until_t $((base - 50)); setstate N
echo "end $(date +%T)" >> $L
