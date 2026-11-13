#!/bin/sh
# Unattended and human-assisted A/B sessions on the router for site tests (T2, T4, T3).
#
# Hardware & Environment:
#   SoC MediaTek MT7628AN, 5 GHz MT7612E on PCIe.
#   Dynamic debugfs and phy discovery (no hard-coded phy1).
#   5 runtime switches controlled via setstate():
#     A: all 0
#     B: T2 (tx_skip_idle=1, tx_no_reread=1)
#     C: T4 (tx_skip_complete_stat=1, tx_skip_napi_stat=1)
#     D: T3 over T2 (T2=1, tx_wb_mode=2)
#     E: T3 verify mode (T2=1, tx_wb_mode=3)
#     F: All on (T2=1, T4=1, tx_wb_mode=2)
#
# Usage: PMAC=<phone mac> PCMAC=<PC cable mac> [SLOTS="0 120 150"] [LOAD24="<mac> <Mbit/s>"]
#        [TXPOWER=<mBm>] [KEEP=1]
#        sh autolab.sh "<states>"                                        (log: /tmp/ab.log)
#        sh autolab.sh serve [minutes]    serves /tmp/autolab/www on port 5299 for the set-up

L=/tmp/ab.log; M=/tmp/ab-mod; RCDIR=/tmp/ab-rc; A=/tmp/autolab
mkdir -p $M $RCDIR $A/www
LAN=$(uci -q get network.lan.ipaddr | cut -d/ -f1)
log() { echo "$*" >> $L; }

# Dynamic discovery of 5 GHz debugfs directory and interface
DBG=""
for p in /sys/kernel/debug/ieee80211/phy*/mt76; do
	if [ -f "$p/tx_wb_mode" ] || [ -f "$p/tx_skip_idle" ]; then
		DBG="$p"
		break
	fi
done
[ -n "$DBG" ] || { echo "5 GHz mt76 debugfs directory not found"; exit 1; }
PHY=$(basename $(dirname "$DBG"))

DEV=""
for d in /sys/class/net/*; do
	dn=$(basename "$d")
	if [ -d "/sys/kernel/debug/ieee80211/$PHY/netdev:$dn" ]; then
		DEV="$dn"
		break
	fi
done
[ -n "$DEV" ] || DEV="${PHY}-ap0"

STA_DIR_PREFIX="/sys/kernel/debug/ieee80211/$PHY"
PHY_AQM="$STA_DIR_PREFIX/aqm"
XMIT_Q="$DBG/xmit-queues"
COUNTERS="$DBG/tx_reads"
RESET="$DBG/tx_reads"
HANG="$DBG/tx_hang_reset"

TRACE_DIR="/sys/kernel/debug/tracing"
TRACE_BUF="$TRACE_DIR/buffer_size_kb"
TRACE_ENABLE="$TRACE_DIR/events/skb/kfree_skb/enable"
TRACE_MARKER="$TRACE_DIR/trace_marker"
TRACE_FILE="$TRACE_DIR/trace"
TRACE_STATS="$TRACE_DIR/per_cpu/cpu0/stats"

if [ "$1" = serve ]; then
	cp "$0" $A/www/autolab.sh 2>/dev/null
	[ -f /tmp/iperf-phone-auto.sh ] && cp /tmp/iperf-phone-auto.sh $A/www/
	[ -f /tmp/iperf3-server.cmd ] && cp /tmp/iperf3-server.cmd $A/www/
	[ -f /tmp/udptest.sh ] && cp /tmp/udptest.sh $A/www/
	uhttpd -f -p 0.0.0.0:5299 -h $A/www -D < /dev/null > /dev/null 2>&1 &
	p=$!; echo "serving $A/www at port 5299 (LAN $LAN) for ${2:-30} min (pid $p)"
	( sleep $(( ${2:-30} * 60 )); kill $p ) < /dev/null > /dev/null 2>&1 &
	exit 0
fi

STATES=${1:-A B A B A B}
[ -f /tmp/site.env ] && . /tmp/site.env
[ -n "$PMAC" ] || { echo "PMAC=<phone mac> is needed"; exit 1; }
[ -f $A/pid ] && kill -0 "$(cat $A/pid)" 2>/dev/null && { echo "a session runs already (pid $(cat $A/pid))"; exit 1; }
echo $$ > $A/pid
SLOTS=${SLOTS:-0 120 150}

STA_DIR="$STA_DIR_PREFIX/netdev:$DEV/stations/$PMAC"
STA_AQM="$STA_DIR/aqm"
STA_RC="$STA_DIR/rc_stats"

ipof() {
	m=$(echo "$1" | tr 'A-F' 'a-f')
	ip=$(awk -v m="$m" '$2 == m {print $3; exit}' /tmp/dhcp.leases)
	[ -n "$ip" ] || ip=$(ip -4 neigh | awk -v m="$m" '$5 == m {print $1; exit}')
	echo "$ip"
}

setstate() {
	case $1 in
		A)
			echo 0 > "$DBG/tx_skip_idle"
			echo 0 > "$DBG/tx_no_reread"
			echo 0 > "$DBG/tx_skip_complete_stat"
			echo 0 > "$DBG/tx_skip_napi_stat"
			echo 0 > "$DBG/tx_wb_mode"
			;;
		B)
			echo 1 > "$DBG/tx_skip_idle"
			echo 1 > "$DBG/tx_no_reread"
			echo 0 > "$DBG/tx_skip_complete_stat"
			echo 0 > "$DBG/tx_skip_napi_stat"
			echo 0 > "$DBG/tx_wb_mode"
			;;
		C)
			echo 0 > "$DBG/tx_skip_idle"
			echo 0 > "$DBG/tx_no_reread"
			echo 1 > "$DBG/tx_skip_complete_stat"
			echo 1 > "$DBG/tx_skip_napi_stat"
			echo 0 > "$DBG/tx_wb_mode"
			;;
		D)
			echo 1 > "$DBG/tx_skip_idle"
			echo 1 > "$DBG/tx_no_reread"
			echo 0 > "$DBG/tx_skip_complete_stat"
			echo 0 > "$DBG/tx_skip_napi_stat"
			echo 2 > "$DBG/tx_wb_mode"
			;;
		E)
			echo 1 > "$DBG/tx_skip_idle"
			echo 1 > "$DBG/tx_no_reread"
			echo 0 > "$DBG/tx_skip_complete_stat"
			echo 0 > "$DBG/tx_skip_napi_stat"
			echo 3 > "$DBG/tx_wb_mode"
			;;
		F)
			echo 1 > "$DBG/tx_skip_idle"
			echo 1 > "$DBG/tx_no_reread"
			echo 1 > "$DBG/tx_skip_complete_stat"
			echo 1 > "$DBG/tx_skip_napi_stat"
			echo 2 > "$DBG/tx_wb_mode"
			;;
		*) log "!! unknown state $1, switches unchanged" ;;
	esac
}

sw_state_str() {
	printf "idle=%s no_reread=%s complete_stat=%s napi_stat=%s wb_mode=%s" \
		"$(cat "$DBG/tx_skip_idle" 2>/dev/null)" \
		"$(cat "$DBG/tx_no_reread" 2>/dev/null)" \
		"$(cat "$DBG/tx_skip_complete_stat" 2>/dev/null)" \
		"$(cat "$DBG/tx_skip_napi_stat" 2>/dev/null)" \
		"$(cat "$DBG/tx_wb_mode" 2>/dev/null)"
}

irqs() { awk '/10100000.ethernet/{e=$2} /mt76x2e/{w=$2} /mt7603e/{v=$2} END{print e, w, v}' /proc/interrupts; }
sta() { iw dev $DEV station get $PMAC 2>/dev/null | awk '/tx packets/{p=$3}/tx retries/{r=$3}/tx failed/{f=$3}END{print p+0, r+0, f+0}'; }
until_t() { d=$(( $1 - $(date +%s) )); [ $d -lt -15 ] && return 1; [ $d -gt 0 ] && sleep $d; return 0; }
hangs() { cat "$HANG" 2>/dev/null || echo 0; }
warns() { dmesg | grep -ciE 'warning|oops|bug:|soft lockup|hung task|unable to handle'; }

chain_snap() {
	nd_tx=$(cat /sys/class/net/$DEV/statistics/tx_packets 2>/dev/null || echo 0)
	nd_dr=$(cat /sys/class/net/$DEV/statistics/tx_dropped 2>/dev/null || echo 0)
	aqm_tot=$(awk 'NR>1 {b+=$4; d+=$6; o+=$8; by+=$10; p+=$11} END{printf "%d %d %d %d %d", b, d, o, by, p}' "$STA_AQM" 2>/dev/null || echo "0 0 0 0 0")
	aqm_tids=$(awk 'NR>1 && ($4>0 || $6>0 || $8>0 || $11>0) {printf "tid%s[b=%d,d=%d,o=%d,p=%d] ", $1, $4, $6, $8, $11}' "$STA_AQM" 2>/dev/null)
	mac_aqm=$(awk '$2 ~ /^fq_(backlog|overlimit|overmemory)/ {printf "%s=%s ", $2, $3}' "$PHY_AQM" 2>/dev/null)
	sta_tx=$(iw dev $DEV station get $PMAC 2>/dev/null | awk '/tx packets/{p=$3}/tx failed/{f=$3}END{printf "%d %d", p, f}')
	done_be=$(awk '$1=="clean_done_be"{print $2}' "$COUNTERS" 2>/dev/null || echo 0)
	done_bk=$(awk '$1=="clean_done_bk"{print $2}' "$COUNTERS" 2>/dev/null || echo 0)
	done_vi=$(awk '$1=="clean_done_vi"{print $2}' "$COUNTERS" 2>/dev/null || echo 0)
	done_vo=$(awk '$1=="clean_done_vo"{print $2}' "$COUNTERS" 2>/dev/null || echo 0)
	done_tot=$((done_be + done_bk + done_vi + done_vo))
	tid0_tx=$(awk '$1=="0"{print $11}' "$STA_AQM" 2>/dev/null || echo 0)
	tid4_tx=$(awk '$1=="4"{print $11}' "$STA_AQM" 2>/dev/null || echo 0)
	dtkn=$(awk '/^next dialog_token:/{n=$3} $1=="00"{t=$6} END{printf "%s %s", n, t}' "$STA_DIR_PREFIX/netdev:$DEV/stations/$PMAC/agg_status" 2>/dev/null || echo "0 0")
	xq=$(awk -F"|" '/^[[:space:]]*[0-3][[:space:]]*\|/{gsub(/[[:space:]]/,"",$2); sum+=$2} END{print sum+0}' "$XMIT_Q" 2>/dev/null || echo 0)
	echo "$nd_tx|$nd_dr|$aqm_tot|$sta_tx|$done_be|$dtkn|$xq|$mac_aqm|$aqm_tids|$done_tot|$done_vi|$tid0_tx|$tid4_tx"
}

chain_diff() {
	awk -v b="$1" -v a="$2" -v p="$3" -v dg="$4" '
	BEGIN {
		split(b, sb, "|"); split(a, sa, "|"); split(p, sp, "|");
		split(sb[3], aqm_b, " "); split(sa[3], aqm_a, " "); split(sp[3], aqm_p, " ");
		split(sb[4], sta_b, " "); split(sa[4], sta_a, " "); split(sp[4], sta_p, " ");
		split(sb[6], dt_b, " "); split(sa[6], dt_a, " "); split(sp[6], dt_p, " ");

		nd_tx = sa[1] - sb[1]; nd_dr = sa[2] - sb[2];
		aqm_bklg = aqm_a[1]; aqm_drop = aqm_a[2] - aqm_b[2]; aqm_ovr = aqm_a[3] - aqm_b[3];
		aqm_bytes = aqm_a[4] - aqm_b[4]; aqm_pkts = aqm_a[5] - aqm_b[5];
		sta_pkts = sta_a[1] - sta_b[1]; sta_fail = sta_a[2] - sta_b[2];
		be_done = sa[5] - sb[5];

		# +5s metrics
		sta_pkts_5s = sta_p[1] - sta_b[1];
		tot_done_5s = sp[10] - sb[10];
		be_done_5s = sp[5] - sb[5];
		vi_done_5s = sp[11] - sb[11];
		tid0_5s = sp[12] - sb[12];
		tid4_5s = sp[13] - sb[13];
		xq_end = sa[7]; xq_5s = sp[7];
		aqm_bklg_5s = aqm_p[1];

		# Gaps
		d_snd_nd = dg - nd_tx;
		d_nd_aqm = nd_tx - aqm_pkts;
		d_aqm_sta = aqm_pkts - sta_pkts;
		d_sta_be = sta_pkts - be_done;

		# Driver loss (+5s): sta_tx vs all completions, and tid0 vs be
		d_sta_all_5s = sta_pkts_5s - tot_done_5s;
		d_tid0_be_5s = tid0_5s - be_done_5s;

		printf "chain deltas: sender %d -> netdev %d (dr %d) -> aqm %d (dr %d ovr %d bklg %d) -> sta_tx %d (fail %d) -> clean_be %d\n", dg, nd_tx, nd_dr, aqm_pkts, aqm_drop, aqm_ovr, aqm_bklg, sta_pkts, sta_fail, be_done;
		printf "chain gaps: [sender->netdev: %d] [netdev->aqm: %d] [aqm->sta: %d] [sta->driver: %d]\n", d_snd_nd, d_nd_aqm, d_aqm_sta, d_sta_be;
		printf "chain driver(+5s): sta_tx_5s %d, tot_done_5s %d, gap %d | tid0_5s %d, be_done_5s %d, tid0_be_gap %d | tid4_5s %d, vi_done_5s %d | xq_end/+5s: %d/%d, bklg_5s %d\n", sta_tx_5s, tot_done_5s, d_sta_all_5s, tid0_5s, be_done_5s, d_tid0_be_5s, tid4_5s, vi_done_5s, xq_end, xq_5s, aqm_bklg_5s;
		printf "mac80211 aqm: %s\n", sa[8];
		printf "sta aqm tids: %s\n", sa[9];
	}'
}

txpower_back() {
	[ -n "$TXPOWER" ] || return 0
	t=$(uci -q get wireless.radio1.txpower)
	case $t in
		'' | *[!0-9]*) iw dev $DEV set txpower auto ;;
		*) iw dev $DEV set txpower fixed $((t * 100)) ;;
	esac
}

cleanup() {
	rm -f $A/www/session /tmp/ab-ping
	[ -f $A/uhttpd.pid ] && kill "$(cat $A/uhttpd.pid)" 2>/dev/null
	rm -f $A/uhttpd.pid
	echo 0 > "$TRACE_ENABLE" 2>/dev/null
	echo 0 > "$TRACE_DIR/events/skb/kfree_skb/filter" 2>/dev/null
	echo > "$TRACE_FILE" 2>/dev/null
	echo 1411 > "$TRACE_BUF" 2>/dev/null
	setstate A; txpower_back
	log "end $(date +%T): $1"
	rm -f $A/pid
}

abort() {
	log "!! abort $(date +%T): $1"
	cleanup "aborted"
	exit 1
}

trap 'abort "stopped by a signal"' INT TERM

# Before: the phone on 5 GHz with an address, the PC's iperf3 server answering
PIP=$(ipof $PMAC)
iw dev $DEV station get $PMAC > /dev/null 2>&1 || abort "phone $PMAC is not on $DEV"
[ -n "$PIP" ] || abort "no address for the phone $PMAC"
for sw_f in tx_skip_idle tx_no_reread tx_skip_complete_stat tx_skip_napi_stat tx_wb_mode; do
	[ -w "$DBG/$sw_f" ] || abort "switch $DBG/$sw_f not writable"
done

PH=""
for s in $SLOTS; do
	case $s in
		120) PH="$PH dl" ;;
		150) PH="$PH ul" ;;
	esac
done
PH=$(echo $PH)
if [ -n "$PH" ]; then
	[ -n "$PCMAC" ] || abort "PCMAC=<PC mac> is needed for the phone's slots"
	PCIP=$(ipof $PCMAC)
	[ -n "$PCIP" ] || abort "no address for the PC $PCMAC"
	iperf3 -c $PCIP -p 5203 -t 1 > /dev/null 2>&1 || abort "the iperf3 server of the PC ($PCIP:5203) does not answer"
fi

if [ -n "$LOAD24" ]; then
	set -- $LOAD24; IP24=$(ipof $1); R24=$2
	iw dev phy0-ap0 station get $1 > /dev/null 2>&1 && [ -n "$IP24" ] || abort "2.4 GHz client $1 is not on phy0-ap0"
fi
[ -n "$TXPOWER" ] && { iw dev $DEV set txpower fixed $TXPOWER || abort "cannot set txpower $TXPOWER"; }

# Tracing configuration: disabled by default, or filtered if TRACE_FILTER is set
if [ -n "$TRACE_FILTER" ]; then
	echo 0 > "$TRACE_ENABLE" 2>/dev/null
	echo "$TRACE_FILTER" > "$TRACE_DIR/events/skb/kfree_skb/filter"
	echo 1411 > "$TRACE_BUF" 2>/dev/null
	echo > "$TRACE_FILE" 2>/dev/null
	echo 1 > "$TRACE_ENABLE" 2>/dev/null
	log "tracing: enabled with filter: $TRACE_FILTER"
else
	echo 0 > "$TRACE_ENABLE" 2>/dev/null
	echo 0 > "$TRACE_DIR/events/skb/kfree_skb/filter" 2>/dev/null
	echo > "$TRACE_FILE" 2>/dev/null
	echo 1411 > "$TRACE_BUF" 2>/dev/null
fi

N=$(echo $STATES | wc -w); c=0
base=$(( $(date +%s) / 240 * 240 + 240 )); [ $(( base - $(date +%s) )) -lt 60 ] && base=$((base + 240))
cat > $A/www/session <<EOF
id=$(date +%Y%m%d-%H%M)
pc=$PCIP
port=5203
phone=$PH
until=$((base + N * 240))
EOF
uhttpd -f -p 0.0.0.0:5299 -h $A/www -D < /dev/null > /dev/null 2>&1 &
echo $! > $A/uhttpd.pid
log "start $(date +%T), dev $DEV, states $STATES, slots $SLOTS (phone: ${PH:-none}), txpower ${TXPOWER:-as configured}, load24 ${LOAD24:-none}, phone $PIP, PC ${PCIP:-none}"
h0=$(hangs); w0=$(warns); gone=0

while [ $c -lt $N ]; do
	c=$((c + 1)); st=$(echo $STATES | cut -d' ' -f$c)
	until_t $((base - 50)); setstate $st
	log "== cycle $c, state $st, $(date +%T), switches: $(sw_state_str), delay_int $(cat /sys/module/mt76x02_lib/parameters/delay_int 2>/dev/null), tx bitrate $(iw dev $DEV station get $PMAC 2>/dev/null | awk -F'\t' '/tx bitrate/{print $NF}')"
	log "free: $(free | awk '/Mem:/{printf "total %d, used %d, free %d, buff/cache %d, avail %d", $2, $3, $4, $6, $7}')"
	cgone=0
	for slot in $SLOTS; do
		case $slot in
			0) name="UDP to the phone" ;;
			120) name="phone, download" ;;
			150) name="phone, upload" ;;
			*) log "!! unknown slot $slot"; continue ;;
		esac
		if ! until_t $((base + slot - 2)); then log "-- $name (state $st): skipped, late"; continue; fi
		[ -n "$RESET" ] && echo 0 > "$RESET"
		[ -n "$TRACE_FILTER" ] && echo > "$TRACE_FILE" 2>/dev/null

		i0=$(irqs); s0=$(sta); t0=$(cut -d' ' -f1 /proc/uptime); pg=""
		snap0=$(chain_snap)
		if [ $slot = 0 ]; then
			UDPTEST=/tmp/udptest.sh; [ -f $UDPTEST ] || UDPTEST=/usr/share/a5v4-diag/udptest.sh
			out=$(sh $UDPTEST $PIP $PMAC 20 0 $M/$c-$slot.txt 2>&1 | grep -v '^ *[0-9.]*% *<-' | head -24)
		else
			ub=""; [ -n "$IP24" ] && { udpblast $IP24 9 1472 20 $R24 > /dev/null 2>&1 & ub=$!; }
			ping -c 18 -W 1 $PIP > /tmp/ab-ping 2>&1 &
			pp=$!
			out=$(kprof 20 1000 12 $M/$c-$slot.txt 2>&1 | sed -n '1,3p;5,20p')
			wait $pp; [ -n "$ub" ] && wait $ub
			pg=$(awk -F'[/ ]+' '/packet loss/{for (i = 1; i <= NF; i++) if ($i ~ /%$/) l = $i}
				/round-trip/{a = $(NF-2); m = $(NF-1)}
				END{printf "ping: %s loss, avg %s ms, max %s ms", l, a, m}' /tmp/ab-ping)
			rm -f /tmp/ab-ping
		fi
		snap1=$(chain_snap)

		i1=$(irqs); s1=$(sta); t1=$(cut -d' ' -f1 /proc/uptime)
		[ -f "$STA_RC" ] && cp "$STA_RC" "$RCDIR/$c-$slot.txt"

		aqm_tid0() { [ -f "$STA_AQM" ] && awk '$1 == 0 {printf "backlog-bytes %s, backlog-pkts %s, drops %s, overlimit %s, tx-bytes %s, tx-pkts %s", $3, $4, $6, $8, $10, $11}' "$STA_AQM" || echo "aqm: n/a"; }
		sta_tx() { iw dev $DEV station get $PMAC 2>/dev/null | awk '/tx packets/{p=$3}/tx failed/{f=$3}END{printf "tx_packets %s, tx_failed %s", p, f}'; }
		xq_dump() { awk -F'|' '/^[[:space:]]*[0-3][[:space:]]*\|/{gsub(/[[:space:]]/,"",$2); sum+=$2} END{print sum+0}' "$XMIT_Q"; }
		aqm0=$(aqm_tid0); stx0=$(sta_tx); xq0=$(xq_dump)

		sleep 5
		snap2=$(chain_snap)
		aqm5=$(aqm_tid0); stx5=$(sta_tx); xq5=$(xq_dump)

		dgrams=$(echo "$out" | awk '/^sent /{print $2}')
		cdiff=$(chain_diff "$snap0" "$snap1" "$snap2" "${dgrams:-0}")

		# Walk and fallback counters
		wb_val=$(awk '$1=="walk_behind"{print $2}' "$COUNTERS" 2>/dev/null || echo 0)
		wa_val=$(awk '$1=="walk_ahead"{print $2}' "$COUNTERS" 2>/dev/null || echo 0)
		ib_val=$(awk '$1=="index_behind"{print $2}' "$COUNTERS" 2>/dev/null || echo 0)
		ia_val=$(awk '$1=="index_ambiguous"{print $2}' "$COUNTERS" 2>/dev/null || echo 0)
		wmb_val=$(awk '$1=="walk_max_behind"{print $2}' "$COUNTERS" 2>/dev/null || echo 0)
		wma_val=$(awk '$1=="walk_max_ahead"{print $2}' "$COUNTERS" 2>/dev/null || echo 0)

		# Check phone iperf report if received
		phone_report=$(tail -n 4 "$A/phone-iperf.log" 2>/dev/null | tr '\n' ' | ')

		drops_2214=0; total_ev=0
		if [ -n "$TRACE_FILTER" ]; then
			drops_2214=$(grep -c "0x82c47268" "$TRACE_FILE" 2>/dev/null || echo 0)
			total_ev=$(wc -l < "$TRACE_FILE" 2>/dev/null || echo 0)
			[ -d "$A/trace" ] || mkdir -p "$A/trace"
			cp "$TRACE_FILE" "$A/trace/$c-$slot.txt" 2>/dev/null
			echo > "$TRACE_FILE" 2>/dev/null
		fi

		here=1; iw dev $DEV station get $PMAC > /dev/null 2>&1 || { here=0; cgone=1; }
		{
			echo "-- $name (state $st), $(date +%T)"
			[ $here = 1 ] || echo "!! PHONE GONE from $DEV"
			echo "$i0 $i1 $t0 $t1" | awk '{d=$8-$7; if (d <= 0) d = 1; printf "interrupts/s: eth0 %d, mt76x2e %d, mt7603e %d\n", ($4-$1)/d, ($5-$2)/d, ($6-$3)/d}'
			[ $slot != 0 ] && echo "$s0 $s1" | awk '{pk=$4-$1; printf "station: %d packets, %.2f retries per packet, %d failed\n", pk, (pk > 0 ? ($5-$2)/pk : 0), $6-$3}'
			[ -n "$pg" ] && echo "$pg"
			echo "$out"
			echo "$cdiff"
			echo "walk: walk_behind $wb_val (max $wmb_val), walk_ahead $wa_val (max $wma_val), index_behind $ib_val, index_ambiguous $ia_val"
			[ -n "$phone_report" ] && echo "phone iperf3: $phone_report"
			[ -n "$TRACE_FILTER" ] && echo "trace: drops at 0x82c47268 (+0x2214): $drops_2214 (total matching events: $total_ev)"
			echo "aqm at end: $aqm0, sta: $stx0, xmit-q: $xq0"
			echo "aqm after 5s: $aqm5, sta: $stx5, xmit-q: $xq5"
			[ -n "$COUNTERS" ] && sed 's/^/cnt /' "$COUNTERS"
		} >> $L

		# Invariant Stop Rules (Section 1 of SITE-people-2.md):
		# 1. TX hang reset
		[ "$(hangs)" = "$h0" ] || abort "STOP RULE: TX hang reset of 5 GHz radio ($(hangs)) in state $st"
		# 2. Kernel warning / oops
		[ "$(warns)" -gt "$w0" ] && { dmesg | tail -40 > $A/dmesg-$(date +%H%M%S).txt; abort "STOP RULE: kernel warning in state $st (dmesg in $A)"; }
		# 3. index_behind or index_ambiguous > 0
		[ "$ib_val" -gt 0 ] && abort "STOP RULE: index_behind ($ib_val) > 0 in state $st"
		[ "$ia_val" -gt 0 ] && abort "STOP RULE: index_ambiguous ($ia_val) > 0 in state $st"
		# 4. Driver-stage real loss with switch on (state != A): >100 frames missing after +5s with empty HW queues
		if [ "$st" != "A" ]; then
			d_loss_5s=$(echo "$cdiff" | awk -F'gap ' 'NF>1 {split($2, a, " "); print a[1]+0}')
			xq_5s_val=$(echo "$cdiff" | awk -F'xq_end/[+]5s: ' 'NF>1 {split($2, a, "/"); split(a[2], b, ","); print b[1]+0}')
			if [ "$d_loss_5s" -gt 100 ] && [ "$xq_5s_val" -le 0 ]; then
				abort "STOP RULE: driver-stage loss ($d_loss_5s pkts after +5s, xq=$xq_5s_val) in state $st"
			fi
		fi
		# 5. MemAvailable check: must stay >= 8 MB (8192 kB)
		avail_kb=$(awk '/MemAvailable:/{print $2; exit}' /proc/meminfo 2>/dev/null || free | awk '/Mem:/{print $7}')
		if [ -n "$avail_kb" ] && [ "$avail_kb" -lt 8192 ]; then
			abort "STOP RULE: MemAvailable ($avail_kb kB) fell below 8 MB in state $st"
		fi
		# 6. /tmp size monitoring (keep <= 4 MB)
		tmp_kb=$(df -k /tmp | awk 'NR==2{print $3}')
		if [ -n "$tmp_kb" ] && [ "$tmp_kb" -gt 4096 ]; then
			log "!! warning: /tmp size is $tmp_kb kB (>4096 kB)"
		fi

		# The phone's own slot without traffic in first cycle
		if [ $c = 1 ] && [ $slot != 0 ] && [ "$KEEP" != 1 ]; then
			mb=$(echo "$out" | awk -v s=$slot -v d="$DEV" '/^traffic/{for (i = 1; i <= NF; i++) if ($i == d) print (s == 120 ? $(i+4) : $(i+2)) + 0}')
			[ "${mb%.*}" -ge 5 ] 2>/dev/null || abort "no traffic of the phone in slot $slot (${mb:-0} Mbit/s): is iperf-phone-auto.sh running?"
		fi
	done
	if [ $cgone = 1 ]; then gone=$((gone + 1)); else gone=0; fi
	[ $gone -ge 2 ] && [ "$KEEP" != 1 ] && abort "phone gone in two cycles in a row"
	base=$((base + 240))
done
until_t $((base - 50))
cleanup "done"
