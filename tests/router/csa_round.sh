#!/bin/sh
# One round of the channel-switch test of the 5 GHz TX switches on the debug image (busybox sh):
# 70 s of UDP at 20 Mbit/s to the test phone, a CSA from channel 52 to 36 (VHT80) at +15 s and back
# at +45 s (hostapd's ubus switch_chan), then the accounting chain, the status and MCU counters, the
# CSA times, dmesg and the resets. For an access point on channel 52 under a country without DFS
# there; it does not touch the switches (set the state before the round). Writes only to
# /tmp/csa/<round>/.
#
#   PMAC=<phone mac> sh csa_round.sh <round name>
# Usage:
#   csa_round.sh <round_name>           (executes live round)
#   csa_round.sh --test-parse <dir>     (runs parser on saved/synthetic dir)

set -u

DBG="/sys/kernel/debug/ieee80211/phy1/mt76"
[ -d "$DBG" ] || {
    for p in /sys/kernel/debug/ieee80211/phy*/mt76; do
        if [ -f "$p/tx_skip_idle" ]; then
            DBG="$p"
            break
        fi
    done
}
PHY1_DEV="phy1-ap0"
PHY0_RESET="/sys/kernel/debug/ieee80211/phy0/mt76/reset"
PHONE_MAC="${PMAC:-}"

u32_delta() {
    awk -v c="$1" -v p="$2" 'BEGIN {
        c += 0; p += 0;
        if (c < 0) c += 4294967296;
        if (p < 0) p += 4294967296;
        d = c - p;
        if (d < 0) d += 4294967296;
        printf "%.0f", d;
    }'
}

disable_switches() {
    echo 0 > "$DBG/tx_skip_idle" 2>/dev/null
    echo 0 > "$DBG/tx_no_reread" 2>/dev/null
    echo 0 > "$DBG/tx_skip_complete_stat" 2>/dev/null
    echo 0 > "$DBG/tx_skip_napi_stat" 2>/dev/null
    echo 0 > "$DBG/tx_wb_mode" 2>/dev/null
}

read_tx_counter() {
    file="$1"
    key="$2"
    awk -v k="$key" '$1==k {print $2; found=1; exit} END{if(!found) print 0}' "$file" 2>/dev/null
}

sum_done_data() {
    file="$1"
    awk '$1 ~ /^clean_done_(be|bk|vi|vo)$/ {s+=$2} END{printf "%.0f", s+0}' "$file" 2>/dev/null
}

sum_xmit_q() {
    file="$1"
    awk -F"|" '/^[[:space:]]*[0-3][[:space:]]*\|/ {gsub(/[[:space:]]/,"",$2); s+=$2} END{printf "%.0f", s+0}' "$file" 2>/dev/null
}

sum_phy0_resets() {
    file="$1"
    awk -F: '{s+=$2} END{printf "%.0f", s+0}' "$file" 2>/dev/null
}

new_lines_after() {
    last="$1"
    awk -v last="$last" '
    BEGIN { found = (last == "") ? 1 : 0; n = 0 }
    $0 == last { found = 1; next }
    found { print; next }
    { all[n++] = $0 }
    END {
        if (!found) {
            for (i = 0; i < n; i++) print all[i]
        }
    }'
}

collect_snap() {
    tag="$1"
    dir="$2"

    cat "$DBG/tx_reads" > "$dir/tx_reads_${tag}.txt" 2>/dev/null
    cat "$DBG/xmit-queues" > "$dir/xmit_${tag}.txt" 2>/dev/null
    cat "$PHY0_RESET" > "$dir/phy0_reset_${tag}.txt" 2>/dev/null

    hang=$(cat "$DBG/tx_hang_reset" 2>/dev/null || echo 0)
    dmesg_cnt=$(dmesg | wc -l)

    sta_out=$(iw dev "$PHY1_DEV" station get "$PHONE_MAC" 2>/dev/null || true)
    conn_time=$(echo "$sta_out" | awk '/connected time:/{print $3}')
    [ -n "$conn_time" ] || conn_time=-1
    sta_tx=$(echo "$sta_out" | awk '/tx packets:/{print $3}')
    [ -n "$sta_tx" ] || sta_tx=0

    flags_file="/sys/kernel/debug/ieee80211/phy1/netdev:$PHY1_DEV/stations/$PHONE_MAC/flags"
    ps_sta=0
    grep -q "PS_STA" "$flags_file" 2>/dev/null && ps_sta=1

    nd_tx=$(cat "/sys/class/net/$PHY1_DEV/statistics/tx_packets" 2>/dev/null || echo 0)
    aqm_file="/sys/kernel/debug/ieee80211/phy1/netdev:$PHY1_DEV/stations/$PHONE_MAC/aqm"
    aqm_tx=$(awk 'NR>1 {p+=$11} END{printf "%.0f", p+0}' "$aqm_file" 2>/dev/null || echo 0)
    chan_info=$(iw dev "$PHY1_DEV" info 2>/dev/null | awk '/channel /{print $0; exit}')

    cat <<EOF > "$dir/snap_${tag}.env"
HANG_${tag}=$hang
DMESG_CNT_${tag}=$dmesg_cnt
CONN_TIME_${tag}=$conn_time
STA_TX_${tag}=$sta_tx
PS_STA_${tag}=$ps_sta
ND_TX_${tag}=$nd_tx
AQM_TX_${tag}=$aqm_tx
CHAN_${tag}='$chan_info'
EOF
}

# Parse and evaluate a completed round directory
parse_round() {
    dir="$1"
    [ -f "$dir/meta.env" ] || { echo "ERROR: missing $dir/meta.env"; return 1; }
    [ -f "$dir/snap_before.env" ] || { echo "ERROR: missing $dir/snap_before.env"; return 1; }
    [ -f "$dir/snap_after.env" ] || { echo "ERROR: missing $dir/snap_after.env"; return 1; }

    . "$dir/meta.env"
    . "$dir/snap_before.env"
    . "$dir/snap_after.env"

    sender_pkts=$(awk '/sent /{print $2; exit}' "$dir/udpblast.out" 2>/dev/null)
    [ -n "$sender_pkts" ] || sender_pkts=0

    d_nd=$(u32_delta "$ND_TX_after" "$ND_TX_before")
    d_aqm=$(u32_delta "$AQM_TX_after" "$AQM_TX_before")
    d_sta=$(u32_delta "$STA_TX_after" "$STA_TX_before")

    done0=$(sum_done_data "$dir/tx_reads_before.txt")
    done1=$(sum_done_data "$dir/tx_reads_after.txt")
    d_done=$(u32_delta "$done1" "$done0")

    req0=$(read_tx_counter "$dir/tx_reads_before.txt" "stat_skb_requested")
    req1=$(read_tx_counter "$dir/tx_reads_after.txt" "stat_skb_requested")
    d_req=$(u32_delta "$req1" "$req0")

    mat0=$(read_tx_counter "$dir/tx_reads_before.txt" "stat_skb_matched")
    mat1=$(read_tx_counter "$dir/tx_reads_after.txt" "stat_skb_matched")
    d_mat=$(u32_delta "$mat1" "$mat0")

    to0=$(read_tx_counter "$dir/tx_reads_before.txt" "stat_skb_timeouts")
    to1=$(read_tx_counter "$dir/tx_reads_after.txt" "stat_skb_timeouts")
    d_to=$(u32_delta "$to1" "$to0")

    mcu_d0=$(read_tx_counter "$dir/tx_reads_before.txt" "clean_done_mcu")
    mcu_d1=$(read_tx_counter "$dir/tx_reads_after.txt" "clean_done_mcu")
    d_mcu_done=$(u32_delta "$mcu_d1" "$mcu_d0")

    mcu_s0=$(read_tx_counter "$dir/tx_reads_before.txt" "clean_skipped_mcu")
    mcu_s1=$(read_tx_counter "$dir/tx_reads_after.txt" "clean_skipped_mcu")
    d_mcu_skip=$(u32_delta "$mcu_s1" "$mcu_s0")

    xq_after=$(sum_xmit_q "$dir/xmit_after.txt")
    p0_0=$(sum_phy0_resets "$dir/phy0_reset_before.txt")
    p0_1=$(sum_phy0_resets "$dir/phy0_reset_after.txt")
    d_phy0=$((p0_1 - p0_0))
    d_hang=$((HANG_after - HANG_before))

    dmesg_hits=$(grep -ciE "WARNING|Oops|BUG|stuck|timed out|MCU" "$dir/dmesg_new.txt" 2>/dev/null || true)
    [ -n "$dmesg_hits" ] || dmesg_hits=0

    csa1_started=$(grep -c "CTRL-EVENT-STARTED-CHANNEL-SWITCH" "$dir/hostapd_new.log" 2>/dev/null || true)
    [ -n "$csa1_started" ] || csa1_started=0
    csa_5180_done=$(grep -cE "AP-CSA-FINISHED.*5180" "$dir/hostapd_new.log" 2>/dev/null || true)
    [ -n "$csa_5180_done" ] || csa_5180_done=0
    csa_5260_done=$(grep -cE "AP-CSA-FINISHED.*5260" "$dir/hostapd_new.log" 2>/dev/null || true)
    [ -n "$csa_5260_done" ] || csa_5260_done=0
    sta_disc=$(grep -c "AP-STA-DISCONNECTED" "$dir/hostapd_new.log" 2>/dev/null || true)
    [ -n "$sta_disc" ] || sta_disc=0

    conn_grew=0
    if [ "$CONN_TIME_before" -ge 0 ] && [ "$CONN_TIME_after" -gt "$CONN_TIME_before" ]; then
        conn_grew=1
    fi

    chan_ok=0
    echo "$CHAN_after" | grep -q "channel 52 " && chan_ok=1

    loss_sta_done=$((d_sta - d_done))
    gap_snd_nd=$((sender_pkts - d_nd))
    gap_nd_aqm=$((d_nd - d_aqm))
    gap_aqm_sta=$((d_aqm - d_sta))

    stop_reason=""
    [ "$d_hang" -gt 0 ] && stop_reason="$stop_reason hang_reset+$d_hang;"
    [ "$d_phy0" -gt 0 ] && stop_reason="$stop_reason phy0_reset+$d_phy0;"
    [ "$dmesg_hits" -gt 0 ] && stop_reason="$stop_reason dmesg_hits=$dmesg_hits;"
    [ "$xq_after" -gt 0 ] && stop_reason="$stop_reason xmit_q_after=$xq_after;"
    [ "$CSA1_WAIT_OK" -ne 1 ] && stop_reason="$stop_reason csa1_timeout;"
    [ "$CSA2_WAIT_OK" -ne 1 ] && stop_reason="$stop_reason csa2_timeout;"
    [ "$sta_disc" -gt 0 ] && stop_reason="$stop_reason sta_disconnected=$sta_disc;"
    [ "$conn_grew" -ne 1 ] && stop_reason="$stop_reason conn_time_not_grown($CONN_TIME_before->$CONN_TIME_after);"
    [ "$chan_ok" -ne 1 ] && stop_reason="$stop_reason final_channel_not_52;"

    cat <<EOF | tee "$dir/summary.txt"
=== CSA ROUND SUMMARY: $ROUND_NAME ===
State: switches=[$SWITCHES_STR] PS_STA_before=$PS_STA_before PS_STA_after=$PS_STA_after
CSA1 (52->36, 5180): started_lines=$csa1_started finished_5180=$csa_5180_done ok=$CSA1_WAIT_OK time_s=$CSA1_SEC
CSA2 (36->52, 5260): finished_5260=$csa_5260_done ok=$CSA2_WAIT_OK time_s=$CSA2_SEC
Association: connected_time ${CONN_TIME_before}s -> ${CONN_TIME_after}s (grew=$conn_grew), AP-STA-DISCONNECTED=$sta_disc
Final channel: $CHAN_after (ok=$chan_ok)
Chain (+5s): sender=$sender_pkts -> netdev=$d_nd -> aqm=$d_aqm -> sta_tx=$d_sta -> clean_done_data=$d_done
Chain gaps: snd->nd=$gap_snd_nd, nd->aqm=$gap_nd_aqm, aqm->sta=$gap_aqm_sta, sta->done=$loss_sta_done
Status deltas: req=+$d_req matched=+$d_mat timeouts=+$d_to
MCU deltas: clean_done_mcu=+$d_mcu_done clean_skipped_mcu=+$d_mcu_skip
Safety: tx_hang_reset_delta=$d_hang phy0_reset_delta=$d_phy0 dmesg_new_lines=$(wc -l < "$dir/dmesg_new.txt" 2>/dev/null || echo 0) dmesg_err_hits=$dmesg_hits xq_after=$xq_after
Stop check: ${stop_reason:-PASS (no stop triggers)}
EOF
}

if [ "${1:-}" = "--test-parse" ]; then
    test_dir="${2:-}"
    [ -n "$test_dir" ] && [ -d "$test_dir" ] || { echo "Usage: $0 --test-parse <dir>"; exit 1; }
    parse_round "$test_dir"
    exit $?
fi

ROUND_NAME="${1:-}"
[ -n "$ROUND_NAME" ] || { echo "Usage: $0 <round_name> | --test-parse <dir>"; exit 1; }

OUT_DIR="/tmp/csa/$ROUND_NAME"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

[ -n "$PHONE_MAC" ] || { echo "ERROR: set PMAC=<phone mac>"; exit 1; }

# Verify phone is associated on 5 GHz
iw dev "$PHY1_DEV" station get "$PHONE_MAC" >/dev/null 2>&1 || {
    echo "ERROR: test phone $PHONE_MAC not associated on $PHY1_DEV"
    exit 1
}

# Resolve phone IPv4
PIP=$(ip neigh show | awk -v m="$PHONE_MAC" 'tolower($5)==tolower(m) && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $1; exit}')
[ -n "$PIP" ] || PIP=$(awk -v m="$PHONE_MAC" 'tolower($2)==tolower(m){print $3; exit}' /tmp/dhcp.leases)
[ -n "$PIP" ] || { echo "ERROR: no IPv4 address of the phone"; exit 1; }

sw_idle=$(cat "$DBG/tx_skip_idle" 2>/dev/null || echo "?")
sw_norr=$(cat "$DBG/tx_no_reread" 2>/dev/null || echo "?")
sw_cstat=$(cat "$DBG/tx_skip_complete_stat" 2>/dev/null || echo "?")
sw_nstat=$(cat "$DBG/tx_skip_napi_stat" 2>/dev/null || echo "?")
sw_wb=$(cat "$DBG/tx_wb_mode" 2>/dev/null || echo "?")
SWITCHES_STR="idle=$sw_idle,no_rr=$sw_norr,c_stat=$sw_cstat,n_stat=$sw_nstat,wb=$sw_wb"

LAST_DMESG_BEFORE=$(dmesg | tail -n 1)
LAST_LR_BEFORE=$(logread | tail -n 1)

collect_snap "before" "$OUT_DIR"

# Start 70 s @ 20 Mbit/s UDP load
T_START=$(date +%s)
/usr/sbin/udpblast "$PIP" 9 1472 70 20 > "$OUT_DIR/udpblast.out" 2>&1 &
UB_PID=$!

# Wait until +15 s, then CSA 52 -> 36
NOW=$(date +%s)
W1=$((T_START + 15 - NOW))
[ "$W1" -gt 0 ] && sleep "$W1"

LAST_LR_CSA1=$(logread | tail -n 1)
UP_CALL1=$(cut -d' ' -f1 /proc/uptime)
T_CALL1=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ubus call hostapd.phy1-ap0 switch_chan '{"freq":5180,"center_freq1":5210,"bandwidth":80,"sec_channel_offset":1,"ht":true,"vht":true,"bcn_count":10}' > "$OUT_DIR/ubus_csa1.out" 2>&1
CSA1_RC=$?

CSA1_WAIT_OK=0
CSA1_SEC=">10"
i=0
while [ "$i" -lt 10 ]; do
    sleep 1
    i=$((i + 1))
    if logread | new_lines_after "$LAST_LR_CSA1" | grep -qE "AP-CSA-FINISHED.*5180"; then
        UP_DONE1=$(cut -d' ' -f1 /proc/uptime)
        CSA1_WAIT_OK=1
        CSA1_SEC=$(awk -v a="$UP_DONE1" -v b="$UP_CALL1" 'BEGIN{printf "%.2f", a-b}')
        break
    fi
done

# Wait until +45 s from load start, then CSA 36 -> 52
NOW=$(date +%s)
W2=$((T_START + 45 - NOW))
[ "$W2" -gt 0 ] && sleep "$W2"

LAST_LR_CSA2=$(logread | tail -n 1)
UP_CALL2=$(cut -d' ' -f1 /proc/uptime)
T_CALL2=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ubus call hostapd.phy1-ap0 switch_chan '{"freq":5260,"center_freq1":5290,"bandwidth":80,"sec_channel_offset":1,"ht":true,"vht":true,"bcn_count":10}' > "$OUT_DIR/ubus_csa2.out" 2>&1
CSA2_RC=$?

CSA2_WAIT_OK=0
CSA2_SEC=">10"
i=0
while [ "$i" -lt 10 ]; do
    sleep 1
    i=$((i + 1))
    if logread | new_lines_after "$LAST_LR_CSA2" | grep -qE "AP-CSA-FINISHED.*5260"; then
        UP_DONE2=$(cut -d' ' -f1 /proc/uptime)
        CSA2_WAIT_OK=1
        CSA2_SEC=$(awk -v a="$UP_DONE2" -v b="$UP_CALL2" 'BEGIN{printf "%.2f", a-b}')
        break
    fi
done

# Wait for udpblast to finish, then +5 s drain
wait "$UB_PID"
sleep 5

collect_snap "after" "$OUT_DIR"

dmesg | new_lines_after "$LAST_DMESG_BEFORE" > "$OUT_DIR/dmesg_new.txt"
logread | new_lines_after "$LAST_LR_BEFORE" | grep -E "hostapd|CSA|CHANNEL-SWITCH|DFS|radar|CAC|mt76" > "$OUT_DIR/hostapd_new.log"

cat <<EOF > "$OUT_DIR/meta.env"
ROUND_NAME='$ROUND_NAME'
SWITCHES_STR='$SWITCHES_STR'
T_CALL1='$T_CALL1'
T_CALL2='$T_CALL2'
CSA1_RC=$CSA1_RC
CSA2_RC=$CSA2_RC
CSA1_WAIT_OK=$CSA1_WAIT_OK
CSA2_WAIT_OK=$CSA2_WAIT_OK
CSA1_SEC='$CSA1_SEC'
CSA2_SEC='$CSA2_SEC'
EOF

parse_round "$OUT_DIR"

# Enforce emergency switch-off if a stop condition triggered
. "$OUT_DIR/snap_before.env"
. "$OUT_DIR/snap_after.env"
d_hang=$((HANG_after - HANG_before))
p0_0=$(sum_phy0_resets "$OUT_DIR/phy0_reset_before.txt")
p0_1=$(sum_phy0_resets "$OUT_DIR/phy0_reset_after.txt")
d_phy0=$((p0_1 - p0_0))
xq_after=$(sum_xmit_q "$OUT_DIR/xmit_after.txt")
dmesg_hits=$(grep -iE "WARNING|Oops|BUG|stuck|timed out|MCU" "$OUT_DIR/dmesg_new.txt" 2>/dev/null | wc -l)

if [ "$d_hang" -gt 0 ] || [ "$d_phy0" -gt 0 ] || [ "$dmesg_hits" -gt 0 ] || [ "$xq_after" -gt 0 ] || [ "$CSA1_WAIT_OK" -ne 1 ] || [ "$CSA2_WAIT_OK" -ne 1 ]; then
    disable_switches
    echo "STOP TRIGGERED: switches set to 0!"
    exit 2
fi

exit 0
