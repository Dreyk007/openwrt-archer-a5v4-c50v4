#!/bin/sh
# Debug image, read-only: every $2 s for $1 rounds, the debugfs state of both radios and of every
# station (power save, filtered frames, rate control's best rates) plus the station counters.
N=${1:-288}; P=${2:-300}; D=/sys/kernel/debug/ieee80211
k=0; read x u n s i w q sq r < /proc/stat
while [ $k -lt $N ]; do
  k=$((k+1)); read x u2 n2 s2 i2 w2 q2 sq2 r2 < /proc/stat
  tot=$(( u2+n2+s2+i2+w2+q2+sq2 - u-n-s-i-w-q-sq )); [ $tot -gt 0 ] || tot=1
  t="$(date +%FT%T) $(cut -d' ' -f1 /proc/uptime)"
  echo "$t cpu idle=$(( (i2-i)*100/tot )) sys=$(( (s2-s)*100/tot )) sirq=$(( (sq2-sq)*100/tot )) memavail=$(awk '/MemAvailable/{print $2}' /proc/meminfo)"
  u=$u2; n=$n2; s=$s2; i=$i2; w=$w2; q=$q2; sq=$sq2
  echo "$t phy0 $(cat $D/phy0/mt76/radio | tr '\n' ' ') ampdu $(sed -n 2p $D/phy0/mt76/ampdu_stat | tr -s ' |')"
  echo "$t phy1 agc $(cat $D/phy1/mt76/agc 2>/dev/null | tr '\n' ' ' | tr -s ' ') temp $(cat $D/phy1/mt76/temperature 2>/dev/null) ampdu $(sed -n 2p $D/phy1/mt76/ampdu_stat 2>/dev/null | tr -s ' |')"
  for p in phy0 phy1; do
    for sd in $D/$p/netdev:*/stations/*; do
      [ -d "$sd" ] || continue; m=${sd##*/}; dev=${sd%/stations/*}; dev=${dev##*netdev:}
      c="$(iw dev $dev station get $m 2>/dev/null | awk '/tx packets/{p=$3}/tx retries/{r=$3}/tx failed/{f=$3}/^\tsignal:/{s=$2}/tx bitrate/{b=$3}/inactive/{a=$3}END{print "txp="p" retr="r" fail="f" sig="s" txr="b" inact="a}')"
      ps=$(grep -q PS_STA $sd/flags && echo 1 || echo 0)
      best="$(awk '$0 ~ /MCS|CCK|OFDM/ { f=substr($0,15,6); if (f ~ /[ABCDP]/) { gsub(/ /,"",f); printf "%s:%s/%s ", f, $(NF-9), $(NF-6) } }' $sd/rc_stats 2>/dev/null)"
      echo "$t sta $dev $m ps=$ps filt=$(cat $sd/tx_filtered) $c rc[$best]"
    done
  done
  sleep $P
done
