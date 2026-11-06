#!/bin/sh
# UDP from the router to one Wi-Fi client while kprof samples the whole system.
# Usage: sh udptest.sh <ip> <mac> <seconds> [Mbit/s] (kprof and udpblast of the debug image, or in /tmp)
KPROF=$(command -v kprof || echo /tmp/kprof); UDPBLAST=$(command -v udpblast || echo /tmp/udpblast)
IP=$1; MAC=$2; T=${3:-15}; R=${4:-0}
dev=$(for d in phy0-ap0 phy1-ap0; do iw dev $d station get $MAC >/dev/null 2>&1 && echo $d; done)
[ -n "$dev" ] || { echo "no station $MAC"; exit 1; }
nd() { awk -v n="$dev:" '{gsub(":",": ")} $1==n{print $10, $11}' /proc/net/dev; }
st() { iw dev $dev station get $MAC | awk '/tx packets/{p=$3}/tx retries/{r=$3}/tx failed/{f=$3}END{print p,r,f}'; }
sv() { iw dev $dev survey dump | grep -A5 'in use' | awk '/active/{a=$4}/busy/{b=$4}/transmit/{t=$4}END{print a,b,t}'; }
echo "== $dev $MAC $IP, ${T} s, rate ${R:-max} Mbit/s"
iw dev $dev station get $MAC | grep -E 'signal:|tx bitrate|rx bitrate'
fl() { echo "$(awk '$3=="mtdblock4"{print $6}' /proc/diskstats) $(awk '/^workingset_refault_file /{print $2}' /proc/vmstat)"; }
a="$(nd)"; sa="$(st)"; va="$(sv)"; fa="$(fl)"; read x u n s i w q sq r < /proc/stat; t0=$(cut -d' ' -f1 /proc/uptime)
$KPROF $((T + 1)) 1000 35 > /tmp/kprof.out 2>&1 &
$UDPBLAST $IP 9 1472 $T $R
wait
b="$(nd)"; sb="$(st)"; vb="$(sv)"; fb="$(fl)"; read x u2 n2 s2 i2 w2 q2 sq2 r2 < /proc/stat; t1=$(cut -d' ' -f1 /proc/uptime)
tot=$(( u2+n2+s2+i2+w2+q2+sq2 - u-n-s-i-w-q-sq ))
echo "$a|$b|$sa|$sb|$va|$vb|$t0 $t1" | awk -F'|' '{split($1,x," ");split($2,y," ");split($3,p," ");split($4,q," ");split($5,v," ");split($6,z," ");split($7,tt," "); d=tt[2]-tt[1]; da=z[1]-v[1];
  printf "interface: %.1f Mbit/s, %d packets sent; channel busy %d%%, own TX %d%%\n", (y[1]-x[1])*8/d/1e6, y[2]-x[2], (z[2]-v[2])*100/da, (z[3]-v[3])*100/da;
  pk=q[1]-p[1]; printf "station: %d packets, %.2f retries per packet, %d failed\n", pk, (pk?(q[2]-p[2])/pk:0), q[3]-p[3]}'
echo "$fa $fb" | awk '{printf "flash: %.1f MiB read, %d page refaults\n", ($3-$1)*512/1048576, $4-$2}'
echo "CPU: idle $(( (i2-i)*100/tot ))%, sys $(( (s2-s)*100/tot ))%, softirq $(( (sq2-sq)*100/tot ))%, user $(( (u2-u+n2-n)*100/tot ))%"
cat /tmp/kprof.out; rm -f /tmp/kprof.out
