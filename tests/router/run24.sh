#!/bin/sh
# 24-hour guard of the 5 GHz TX switches on the debug image (busybox sh; needs the debugfs switches
# and the counters of the debug series in tests/mt76-debug). Logs to /tmp/run24/, never writes to
# the flash, never sets a switch to 1: on a stop rule (a TX hang or mt7603 reset, a kernel warning,
# a timeout of the MCU, more than 60 status timeouts in an hour or more than 1 % of at least 500
# requests, MemAvailable below 6 MB) it sets them all to 0 and goes on logging. Every 5 minutes a
# line of counter deltas and the new hostapd lines; every 4 hours (6 times) a 20 s UDP burst of
# 20 Mbit/s to the test phone with its accounting chain (only if PMAC is set and the phone is on
# 5 GHz).
#
#   PMAC=<phone mac> nohup sh run24.sh > /dev/null 2>&1 &      (sh run24.sh --test: one dry line)

DIR="/tmp/run24"
mkdir -p "$DIR"
PIDFILE="$DIR/run24.pid"
LOGFILE="$DIR/run24.log"
HOSTAPD_LOG="$DIR/hostapd.log"
TO_HIST="$DIR/to_history.txt"
LAST_LOGREAD="$DIR/.last_logread"

echo "$$" > "$PIDFILE"

# Discover debugfs paths
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

# Stop rule tracking baselines
STOPPED=0
STOP_REASON=""

get_hang_reset() {
    cat "$DBG/tx_hang_reset" 2>/dev/null || echo 0
}

get_phy0_resets() {
    awk -F: '{sum+=$2} END{print sum+0}' "$PHY0_RESET" 2>/dev/null || echo 0
}

START_HANG=$(get_hang_reset)
START_PHY0_RESETS=$(get_phy0_resets)
PREV_LAST_DMESG=$(dmesg | tail -n 1)

# Rotator function to ensure files stay <= 1 MB total in /tmp/run24/
rotate_file() {
    f="$1"
    max_k="$2"
    if [ -f "$f" ]; then
        sz=$(ls -sk "$f" 2>/dev/null | awk '{print $1}')
        if [ "$sz" -gt "$max_k" ]; then
            mv -f "$f" "${f}.1" 2>/dev/null
        fi
    fi
}

disable_switches() {
    echo 0 > "$DBG/tx_skip_idle" 2>/dev/null
    echo 0 > "$DBG/tx_no_reread" 2>/dev/null
    echo 0 > "$DBG/tx_skip_complete_stat" 2>/dev/null
    echo 0 > "$DBG/tx_skip_napi_stat" 2>/dev/null
    echo 0 > "$DBG/tx_wb_mode" 2>/dev/null
}

trigger_stop() {
    reason="$1"
    if [ "$STOPPED" -eq 0 ]; then
        STOPPED=1
        STOP_REASON="$reason"
        disable_switches
        ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        echo "$ts STOP: $reason" >> "$LOGFILE"
    fi
}

# Snapshot helper for 5-minute counter parsing
# Outputs: requested matched timeouts vreads napi irq skip reread tx_pkts
snap_counters() {
    awk '
    BEGIN {
        req=0; mat=0; to=0; vr=0; napi=0; irq=0; skip=0; rr=0;
    }
    $1=="stat_skb_requested" { req=$2 }
    $1=="stat_skb_matched"   { mat=$2 }
    $1=="stat_skb_timeouts"  { to=$2 }
    $1=="stat_valid_reads"   { vr=$2 }
    $1=="tx_napi_polls"      { napi=$2 }
    $1=="irq_handled"        { irq=$2 }
    $1 ~ /^clean_skipped_/   { skip+=$2 }
    $1 ~ /^clean_re_reads_/  { rr+=$2 }
    END {
        printf "%s %s %s %s %s %s %s %s\n", req, mat, to, vr, napi, irq, skip, rr
    }' "$DBG/tx_reads" 2>/dev/null
}

get_tx_packets() {
    cat "/sys/class/net/$PHY1_DEV/statistics/tx_packets" 2>/dev/null || echo 0
}

# Initial counter values
PREV_SNAP=$(snap_counters)
PREV_TX_PKTS=$(get_tx_packets)

# Hostapd log harvester
harvest_hostapd() {
    TMP_LR="$DIR/.tmp_lr"
    logread | grep -E "hostapd|DFS|radar|CAC|channel switch" > "$TMP_LR" 2>/dev/null
    if [ ! -f "$LAST_LOGREAD" ]; then
        cat "$TMP_LR" >> "$HOSTAPD_LOG"
    else
        LAST_LINE=$(cat "$LAST_LOGREAD" 2>/dev/null)
        awk -v last="$LAST_LINE" '
        BEGIN { found = (last == "") ? 1 : 0; n = 0 }
        $0 == last { found = 1; next }
        found { print; next }
        { all[n++] = $0 }
        END {
            if (!found) {
                for (i = 0; i < n; i++) print all[i]
            }
        }' "$TMP_LR" >> "$HOSTAPD_LOG"
    fi
    tail -n 1 "$TMP_LR" > "$LAST_LOGREAD" 2>/dev/null
    rm -f "$TMP_LR"
    rotate_file "$HOSTAPD_LOG" 200
}

# 5-minute status logger
log_status() {
    harvest_hostapd

    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    up=$(awk '{d=int($1/86400); h=int(($1%86400)/3600); m=int(($1%3600)/60); printf "%dd%dh%dm", d, h, m}' /proc/uptime)

    sw_idle=$(cat "$DBG/tx_skip_idle" 2>/dev/null || echo "?")
    sw_norr=$(cat "$DBG/tx_no_reread" 2>/dev/null || echo "?")
    sw_cstat=$(cat "$DBG/tx_skip_complete_stat" 2>/dev/null || echo "?")
    sw_nstat=$(cat "$DBG/tx_skip_napi_stat" 2>/dev/null || echo "?")
    sw_wb=$(cat "$DBG/tx_wb_mode" 2>/dev/null || echo "?")

    mem_info=$(awk '/MemAvailable:/{a=$2/1024} /Slab:/{s=$2/1024} END{printf "avail=%.1fM,slab=%.1fM", a, s}' /proc/meminfo)
    load_info=$(awk '{printf "%s,%s,%s", $1, $2, $3}' /proc/loadavg)

    sta_5g=$(iw dev "$PHY1_DEV" station dump 2>/dev/null | grep -c Station)
    sta_24g=$(iw dev "phy0-ap0" station dump 2>/dev/null | grep -c Station)

    CURR_SNAP=$(snap_counters)
    CURR_TX_PKTS=$(get_tx_packets)

    deltas_str=$(echo "$PREV_SNAP $CURR_SNAP $PREV_TX_PKTS $CURR_TX_PKTS" | awk '
    function u32_d(curr, prev) {
        c = curr + 0; p = prev + 0;
        if (c < 0) c += 4294967296;
        if (p < 0) p += 4294967296;
        d = c - p;
        if (d < 0) d += 4294967296;
        return d;
    }
    {
        d_req  = u32_d($9,  $1);
        d_mat  = u32_d($10, $2);
        d_to   = u32_d($11, $3);
        d_vr   = u32_d($12, $4);
        d_napi = u32_d($13, $5);
        d_irq  = u32_d($14, $6);
        d_skip = u32_d($15, $7);
        d_rr   = u32_d($16, $8);
        d_tx   = u32_d($18, $17);
        printf "req=+%d,mat=+%d,to=+%d,vreads=+%d,napi=+%d,irq=+%d,skip=+%d,reread=+%d,tx_pkts=+%d",
               d_req, d_mat, d_to, d_vr, d_napi, d_irq, d_skip, d_rr, d_tx;
    }')

    PREV_SNAP="$CURR_SNAP"
    PREV_TX_PKTS="$CURR_TX_PKTS"
    hang_val=$(get_hang_reset)

    echo "$ts up $up switches[idle=$sw_idle,no_rr=$sw_norr,c_stat=$sw_cstat,n_stat=$sw_nstat,wb=$sw_wb] mem[$mem_info] load[$load_info] sta[5G=$sta_5g,2.4G=$sta_24g] deltas[$deltas_str] hang_reset=$hang_val" >> "$LOGFILE"
    rotate_file "$LOGFILE" 250
}

# Burst executor (every 4 hours, i.e. 240 minutes)
execute_burst() {
    burst_num="$1"
    [ -n "$PHONE_MAC" ] || {
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) BURST $burst_num: no PMAC, skipped" >> "$LOGFILE"
        return 0
    }
    # Check if test phone is on 5 GHz
    if ! iw dev "$PHY1_DEV" station get "$PHONE_MAC" >/dev/null 2>&1; then
        ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        echo "$ts BURST $burst_num: test phone ($PHONE_MAC) not associated on $PHY1_DEV, skipped" >> "$LOGFILE"
        return 0
    fi

    # Find phone IPv4
    PIP=$(ip neigh show | awk -v m="$PHONE_MAC" 'tolower($5)==tolower(m) && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $1; exit}')
    [ -n "$PIP" ] || PIP=$(awk -v m="$PHONE_MAC" 'tolower($2)==tolower(m){print $3; exit}' /tmp/dhcp.leases)
    [ -n "$PIP" ] || {
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) BURST $burst_num: no IPv4 address of the phone, skipped" >> "$LOGFILE"
        return 0
    }

    # Check PS_STA flag
    FLAGS_FILE="/sys/kernel/debug/ieee80211/phy1/netdev:$PHY1_DEV/stations/$PHONE_MAC/flags"
    PS_ACTIVE=0
    grep -q "PS_STA" "$FLAGS_FILE" 2>/dev/null && PS_ACTIVE=1

    # Snapshot pre-burst
    nd0=$(cat "/sys/class/net/$PHY1_DEV/statistics/tx_packets" 2>/dev/null || echo 0)
    aqm0=$(awk 'NR>1 {p+=$11} END{print p+0}' "/sys/kernel/debug/ieee80211/phy1/netdev:$PHY1_DEV/stations/$PHONE_MAC/aqm" 2>/dev/null || echo 0)
    sta0=$(iw dev "$PHY1_DEV" station get "$PHONE_MAC" 2>/dev/null | awk '/tx packets/{print $3}')
    done0=$(awk '$1 ~ /^clean_done_(be|bk|vi|vo)$/{sum+=$2} END{print sum+0}' "$DBG/tx_reads" 2>/dev/null || echo 0)

    # 20 s UDP burst at 20 Mbit/s
    UB_OUT=$(/usr/sbin/udpblast "$PIP" 9 1472 20 20 2>&1)
    snd_pkts=$(echo "$UB_OUT" | awk '/sent/{print $2}')
    [ -n "$snd_pkts" ] || snd_pkts=0

    # Snapshot immediately post-burst
    nd1=$(cat "/sys/class/net/$PHY1_DEV/statistics/tx_packets" 2>/dev/null || echo 0)
    aqm1=$(awk 'NR>1 {p+=$11} END{print p+0}' "/sys/kernel/debug/ieee80211/phy1/netdev:$PHY1_DEV/stations/$PHONE_MAC/aqm" 2>/dev/null || echo 0)
    sta1=$(iw dev "$PHY1_DEV" station get "$PHONE_MAC" 2>/dev/null | awk '/tx packets/{print $3}')

    # Wait +5 s drain
    sleep 5
    sta_5s=$(iw dev "$PHY1_DEV" station get "$PHONE_MAC" 2>/dev/null | awk '/tx packets/{print $3}')
    done_5s=$(awk '$1 ~ /^clean_done_(be|bk|vi|vo)$/{sum+=$2} END{print sum+0}' "$DBG/tx_reads" 2>/dev/null || echo 0)
    xq_5s=$(awk -F"|" '/^[[:space:]]*[0-3][[:space:]]*\|/{gsub(/[[:space:]]/,"",$2); sum+=$2} END{print sum+0}' "$DBG/xmit-queues" 2>/dev/null || echo 0)

    # Calculate metrics
    d_nd=$((nd1 - nd0))
    d_aqm=$((aqm1 - aqm0))
    d_sta=$((sta1 - sta0))
    d_sta_5s=$((sta_5s - sta0))
    d_done_5s=$((done_5s - done0))
    ps_gap=$((d_nd - d_aqm))
    driver_loss=$((d_sta_5s - d_done_5s))

    ps_drop_pct="0.0"
    if [ "$d_nd" -gt 0 ]; then
        ps_drop_pct=$(awk -v gap="$ps_gap" -v tot="$d_nd" 'BEGIN {printf "%.1f", (gap*100.0)/tot}')
    fi

    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "$ts BURST $burst_num: PS_STA=$PS_ACTIVE sender=$snd_pkts netdev=$d_nd aqm=$d_aqm sta_tx=$d_sta done_5s=$d_done_5s ps_buffer_drop=$ps_gap (${ps_drop_pct}%) driver_loss=$driver_loss xq_5s=$xq_5s" >> "$LOGFILE"

    # Stop rule check: driver loss > 100 with hardware queues empty
    if [ "$driver_loss" -gt 100 ] && [ "$xq_5s" -eq 0 ]; then
        trigger_stop "BURST $burst_num: driver-stage loss $driver_loss > 100 with empty queues"
    fi
}

MINUTE=0
BURST_COUNT=0

if [ "$1" = "--test" ] || [ "$1" = "--dry-run" ]; then
    echo "Running run24.sh in dry-run test mode..."
    CURR_HANG=$(get_hang_reset)
    echo "tx_hang_reset: start=$START_HANG, curr=$CURR_HANG"
    CURR_PHY0_RESETS=$(get_phy0_resets)
    echo "phy0 reset counters: start=$START_PHY0_RESETS, curr=$CURR_PHY0_RESETS"
    CURR_LAST_DMESG=$(dmesg | tail -n 1)
    echo "dmesg last line: $CURR_LAST_DMESG"
    MEM_AVAIL_KB=$(awk '/MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    echo "MemAvailable: ${MEM_AVAIL_KB} kB"
    log_status
    echo "Sample log line generated in $LOGFILE:"
    tail -n 1 "$LOGFILE"
    echo "Hostapd lines harvested: $(wc -l < "$HOSTAPD_LOG")"
    echo "Dry-run test complete."
    exit 0
fi

# Log initial baseline line (minute 0)
log_status

# Main loop running every 60 s
while true; do
    sleep 60
    MINUTE=$((MINUTE + 1))
    NOW_EPOCH=$(date +%s)

    # =========================================================================
    # 1. STOP RULES (Checked every 60 s)
    # =========================================================================

    # Check 1: tx_hang_reset growth on phy1
    CURR_HANG=$(get_hang_reset)
    if [ "$CURR_HANG" -gt "$START_HANG" ]; then
        trigger_stop "tx_hang_reset grew from $START_HANG to $CURR_HANG"
    fi

    # Check 2: phy0 mt76/reset counter growth
    CURR_PHY0_RESETS=$(get_phy0_resets)
    if [ "$CURR_PHY0_RESETS" -gt "$START_PHY0_RESETS" ]; then
        trigger_stop "phy0 reset counters grew from $START_PHY0_RESETS to $CURR_PHY0_RESETS"
    fi

    # Check 3: new dmesg errors
    CURR_LAST_DMESG=$(dmesg | tail -n 1)
    if [ "$CURR_LAST_DMESG" != "$PREV_LAST_DMESG" ]; then
        ERR_LINE=$(dmesg | awk -v last="$PREV_LAST_DMESG" '
        BEGIN { found = (last == "") ? 1 : 0; n = 0 }
        $0 == last { found = 1; next }
        found { print; next }
        { all[n++] = $0 }
        END {
            if (!found) {
                for (i = 0; i < n; i++) print all[i]
            }
        }' | grep -iE "WARNING|Oops|BUG|stuck|timed out|MCU" | head -n 1)
        if [ -n "$ERR_LINE" ]; then
            trigger_stop "dmesg error detected: $ERR_LINE"
        fi
        PREV_LAST_DMESG="$CURR_LAST_DMESG"
    fi

    # Check 4: status timeouts in the last 60 minutes
    # Read current requested and timeouts
    CURR_REQ=$(awk '$1=="stat_skb_requested"{print $2}' "$DBG/tx_reads" 2>/dev/null || echo 0)
    CURR_TO=$(awk '$1=="stat_skb_timeouts"{print $2}' "$DBG/tx_reads" 2>/dev/null || echo 0)
    echo "$NOW_EPOCH $CURR_REQ $CURR_TO" >> "$TO_HIST"

    # Prune lines older than 3600 seconds
    CUTOFF=$((NOW_EPOCH - 3600))
    awk -v cut="$CUTOFF" '$1 >= cut' "$TO_HIST" > "$TO_HIST.tmp" 2>/dev/null && mv -f "$TO_HIST.tmp" "$TO_HIST"

    # Evaluate 60m window
    OLD_SAMPLE=$(head -n 1 "$TO_HIST")
    if [ -n "$OLD_SAMPLE" ]; then
        ALERT_INFO=$(echo "$OLD_SAMPLE $CURR_REQ $CURR_TO" | awk '
        function u32_d(curr, prev) {
            c = curr + 0; p = prev + 0;
            if (c < 0) c += 4294967296;
            if (p < 0) p += 4294967296;
            d = c - p;
            if (d < 0) d += 4294967296;
            return d;
        }
        {
            old_ts=$1; old_req=$2; old_to=$3; now_req=$4; now_to=$5;
            d_req = u32_d(now_req, old_req);
            d_to  = u32_d(now_to, old_to);
            if (d_to > 60) {
                printf "STOP_TO_EXCEEDED %d %d\n", d_to, d_req;
            } else if (d_req >= 500 && (d_to * 100 > d_req * 1)) {
                printf "STOP_TO_RATE_EXCEEDED %d %d\n", d_to, d_req;
            }
        }')
        if [ -n "$ALERT_INFO" ]; then
            alert=$(echo "$ALERT_INFO" | awk '{print $1}')
            to_val=$(echo "$ALERT_INFO" | awk '{print $2}')
            req_val=$(echo "$ALERT_INFO" | awk '{print $3}')
            if [ "$alert" = "STOP_TO_EXCEEDED" ]; then
                trigger_stop "Status timeouts in last 60m: $to_val > 60 (requests: $req_val)"
            elif [ "$alert" = "STOP_TO_RATE_EXCEEDED" ]; then
                trigger_stop "Status timeouts in last 60m: $to_val of $req_val (> 1.0%)"
            fi
        fi
    fi

    # Check 5: MemAvailable below 6 MB (6144 kB)
    MEM_AVAIL_KB=$(awk '/MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    if [ "$MEM_AVAIL_KB" -gt 0 ] && [ "$MEM_AVAIL_KB" -lt 6144 ]; then
        trigger_stop "MemAvailable below 6MB (${MEM_AVAIL_KB} kB)"
    fi

    # =========================================================================
    # 2. EVERY 5 MINUTES LOGGING
    # =========================================================================
    if [ $((MINUTE % 5)) -eq 0 ]; then
        log_status
    fi

    # =========================================================================
    # 3. EVERY 4 HOURS BURST (240, 480, 720, 960, 1200, 1440 min)
    # =========================================================================
    if [ $((MINUTE % 240)) -eq 0 ] && [ "$BURST_COUNT" -lt 6 ]; then
        BURST_COUNT=$((BURST_COUNT + 1))
        execute_burst "$BURST_COUNT"
    fi
done
