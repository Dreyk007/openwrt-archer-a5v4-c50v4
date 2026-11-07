#!/bin/sh
# Moves a phone between the 2.4 GHz and the 5 GHz access point and records the time of each move
# and what hostapd logs on the way (authentication, SAE or PSK handshake, failures, DHCP).
# METHOD=down (default) takes the radio the phone is on down until the phone has joined its other
# saved network (or for 100 s), then brings it up again; every client of that radio loses it
# meanwhile. METHOD=ban deauthenticates the phone with a ban of BAN s on that access point
# instead; Android takes the rejections during the ban for a failing access point and stops
# trying it for minutes, so after two moves a phone with the screen off had no network it would
# join (2026-11-06). Android uses another random MAC on each network: give both. One move at 0 s
# of each 240 s cycle of iperf-phone.sh, so that its runs (120 and 150 s) take turns on the two
# bands; at 125 s the script logs where the phone is.
# Usage: sh bandswitch.sh <moves> <MAC on 2.4 GHz> <MAC on 5 GHz>   (log: /tmp/bandswitch.log)
N=${1:-12}; M2=$2; M5=$3; METHOD=${METHOD:-down}; BAN=${BAN:-40}; L=/tmp/bandswitch.log
on() { iw dev $1 station get $2 2>/dev/null | grep -q 'authorized:.*yes'; }
band() { on phy0-ap0 $M2 && echo 2; on phy1-ap0 $M5 && echo 5; }
sig() { iw dev $1 station get $2 2>/dev/null | awk '/signal:/{s=$2}/tx bitrate/{$1=$2="";t=$0}END{print s " dBm," t}'; }
until_t() { d=$(( $1 - $(date +%s) )); [ $d -gt 0 ] && sleep $d; }
echo "start $(date +%T), $N moves, method $METHOD" >> $L
k=0; base=$(( $(date +%s) / 240 * 240 + 240 ))
while [ $k -lt $N ]; do
	until_t $base; k=$((k + 1))
	b=$(band | head -1)
	case $b in
		2) f=phy0-ap0; r=radio0; m=$M2; t=phy1-ap0; tm=$M5; to=5 ;;
		5) f=phy1-ap0; r=radio1; m=$M5; t=phy0-ap0; tm=$M2; to=2 ;;
		*) echo "move $k ($(date +%T)): the phone is on neither band" >> $L; base=$((base + 240)); continue ;;
	esac
	n0=$(logread | wc -l); ts=$(date +%T); s0=$(sig $f $m)
	if [ $METHOD = ban ]; then
		ubus call hostapd.$f del_client "{\"addr\":\"$m\",\"reason\":5,\"deauth\":true,\"ban_time\":$((BAN * 1000))}"
	else
		wifi down $r
	fi
	s=0; got=""
	while [ $s -lt 100 ]; do
		sleep 1; s=$((s + 1))
		on $t $tm && { got=$to; break; }
		[ $METHOD = ban ] && [ $s -gt $BAN ] && on $f $m && { got="back to $b"; break; }
	done
	[ $METHOD = ban ] || { wifi up $r; sleep 20; }
	sleep 3
	echo "move $k ($ts): $b GHz ($s0) -> ${got:-nowhere} after $s s ($(sig $t $tm))" >> $L
	logread | tail -n +$((n0 + 1)) | grep -iE "$M2|$M5|sae|wpa|eapol|hostapd" | grep -v 'interface state' |
		awk '{t=$4; for (i=1; i<=6; i++) $i=""; sub(/^ +/, ""); print "   " t " " $0}' >> $L
	until_t $((base + 125))
	echo "   at 125 s ($(date +%T)): the phone is on $(band | head -1) GHz" >> $L
	base=$((base + 240))
done
echo "end $(date +%T); the phone is on $(band | head -1) GHz" >> $L
