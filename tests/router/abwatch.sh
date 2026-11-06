#!/bin/sh
# Profiles of real traffic and an A/B of GRO on it, without anybody at the site. Every 5 s the
# CPU load is checked; when the CPU was over 50 % busy for 10 s and the last capture is 5 min old,
# the next GRO state is set on eth0 and both radios, and 20 s later kprof samples for 20 s while
# the traffic counters run. States in turn: A = GRO with fraglist (the default), B = GRO without
# fraglist, C = no GRO. Everything goes back to A at the end. Usage: sh abwatch.sh <hours> [max]
# (ethtool and kprof of the debug image, or in /tmp)
H=${1:-16}; MAX=${2:-60}; L=/tmp/abwatch.log
E=$(command -v ethtool || echo /tmp/ethtool); KPROF=$(command -v kprof || echo /tmp/kprof)
IFS_LIST="eth0 phy0-ap0 phy1-ap0"
setgro() {
  for d in $IFS_LIST; do
    case $1 in
      A) $E -K $d gro on rx-gro-list on ;;
      B) $E -K $d gro on rx-gro-list off ;;
      C) $E -K $d gro off rx-gro-list off ;;
    esac
  done 2>/dev/null
}
cpu() { awk 'NR==1{print $2+$3+$4+$6+$7+$8, $5}' /proc/stat; }
nd() { awk '{gsub(":",": ")} $1=="eth0.2:"||$1=="phy0-ap0:"||$1=="phy1-ap0:"{printf "%s %s %s ", $1, $2, $10}' /proc/net/dev; }
end=$(( $(cut -d. -f1 /proc/uptime) + H * 3600 )); n=0; last=0; st=0; hot=0
set -- $(cpu); pb=$1; pi=$2
echo "start $(date +%T), $H h" >> $L
while [ "$(cut -d. -f1 /proc/uptime)" -lt $end ] && [ $n -lt $MAX ]; do
  sleep 5
  set -- $(cpu); b=$1; i=$2; busy=$(( (b-pb)*100 / ((b-pb)+(i-pi)+1) )); pb=$b; pi=$i
  [ $busy -gt 50 ] && hot=$((hot+1)) || hot=0
  now=$(cut -d. -f1 /proc/uptime)
  [ $hot -ge 2 ] && [ $((now - last)) -ge 300 ] || continue
  n=$((n+1)); s=$(echo "A B C" | cut -d' ' -f$((st % 3 + 1))); st=$((st+1))
  setgro $s; sleep 20
  a="$(nd)"; set -- $(cpu); b0=$1; i0=$2
  read x u n0 sy id w q sq r < /proc/stat
  $KPROF 20 1000 25 > /tmp/abwatch.kprof 2>&1
  read x u2 n2 sy2 id2 w2 q2 sq2 r2 < /proc/stat
  b="$(nd)"; tot=$(( u2+n2+sy2+id2+w2+q2+sq2 - u-n0-sy-id-w-q-sq ))
  {
    echo "== capture $n, GRO state $s, $(date +%T), conntrack $(cat /proc/sys/net/netfilter/nf_conntrack_count)"
    echo "CPU: idle $(( (id2-id)*100/tot ))% sys $(( (sy2-sy)*100/tot ))% softirq $(( (sq2-sq)*100/tot ))% user $(( (u2-u+n2-n0)*100/tot ))%"
    echo "$a|$b" | awk -F'|' '{n=split($1,x," "); split($2,y," "); for(k=1;k<=n;k+=3) printf "%s rx %.1f tx %.1f Mbit/s  ", x[k], (y[k+1]-x[k+1])*8/20e6, (y[k+2]-x[k+2])*8/20e6; print ""}'
    head -n 30 /tmp/abwatch.kprof
  } >> $L
  setgro A; last=$(cut -d. -f1 /proc/uptime)
done
setgro A; echo "end $(date +%T), $n captures" >> $L
