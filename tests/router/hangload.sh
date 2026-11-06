#!/bin/sh
# Width switches of the 2.4 GHz radio under load: a UDP stream to a client keeps the TX queues full
# while the radio is reconfigured N times (HT40 with the coexistence scan, HT20, HT40 noscan, ...).
# The radio is up again when the kernel logs phy0-ap0 forwarding after the switch; a switch that
# takes over 60 s, or an MCU timeout, stops the test with the evidence. The config file goes back
# to the original after each switch. Usage: sh hangload.sh <client ip> <cycles>
IP=$1; N=${2:-12}; L=/tmp/hangload.log; ORIG=/tmp/wireless.orig
UDPBLAST=$(command -v udpblast || echo /tmp/udpblast)
[ -f $ORIG ] || cp /etc/config/wireless $ORIG
dtasks() { for t in /proc/[0-9]*; do [ "$(awk '{print $3}' $t/stat 2>/dev/null)" = D ] && echo "${t#/proc/}:$(cat $t/comm)"; done; }
# dmesg lines start with "[ 1803.410440]"
fwd_after() { dmesg | awk -v t0="$1" '/phy0-ap0\) entered forwarding state/ { s = $0; sub(/^\[ */, "", s); sub(/\].*/, "", s); if (s + 0 > t0) f = 1 } END { exit !f }'; }
evidence() {
  echo "== HANG at cycle $1 ($(date +%T))"; echo "-- D tasks: $(dtasks | tr '\n' ' ')"
  for p in $(dtasks | cut -d: -f1); do echo "-- stack of $p $(cat /proc/$p/comm) wchan $(cat /proc/$p/wchan)"; cat /proc/$p/stack; done
  echo w > /proc/sysrq-trigger; sleep 2
  echo "-- dmesg tail"; dmesg | tail -n 200
}
echo "start $(date +%T), $N cycles, UDP to $IP" > $L
$UDPBLAST $IP 9 1472 $((N * 90)) 0 > /tmp/hangload-udp.log 2>&1 &
UDP=$!
sleep 5
c=0
while [ $c -lt $N ]; do
  c=$((c+1))
  case $((c % 3)) in 1) m=HT40; ns="";; 2) m=HT20; ns="";; 0) m=HT40; ns=1;; esac
  to0=$(dmesg | grep -c 'timed out')
  tx0=$(awk '{gsub(":",": ")} $1=="phy0-ap0:"{print $10}' /proc/net/dev)
  uci set wireless.radio0.htmode=$m; [ -n "$ns" ] && uci set wireless.radio0.noscan=1 || uci -q delete wireless.radio0.noscan; uci commit wireless
  t0=$(cut -d' ' -f1 /proc/uptime)
  ( wifi up radio0 ) </dev/null >/dev/null 2>&1 &
  sleep 5; cp $ORIG /etc/config/wireless
  ok=0; k=5
  while [ $k -lt 60 ]; do
    sleep 2; k=$((k+2))
    fwd_after "$t0" && { ok=1; break; }
  done
  to1=$(dmesg | grep -c 'timed out')
  w=""; [ $ok = 1 ] && [ -z "$(dtasks | grep -E 'hostapd|iw$')" ] && w=$(iw dev phy0-ap0 info 2>/dev/null | sed -n 's/.*width: \([0-9]*\) MHz.*/\1/p')
  sleep 15
  tx1=$(awk '{gsub(":",": ")} $1=="phy0-ap0:"{print $10}' /proc/net/dev)
  echo "cycle $c $m${ns:+ noscan}: up after ${k}s ok=$ok width=${w:-?} mcu_timeouts=$((to1-to0)) tx=$(( (tx1-tx0)*8/1000000 )) Mbit since switch D=[$(dtasks | tr '\n' ' ')]" >> $L
  if [ $ok = 0 ] || [ $((to1-to0)) -gt 0 ]; then
    evidence $c > /tmp/hang-evidence.log 2>&1; echo "stopped: see /tmp/hang-evidence.log" >> $L; kill $UDP; exit 1
  fi
done
kill $UDP 2>/dev/null; cat /tmp/hangload-udp.log >> $L
echo "done $(date +%T), no hang" >> $L
