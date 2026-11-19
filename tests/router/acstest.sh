#!/bin/sh
# Automatic channel selection (ACS) and reference channel-load measurements (busybox ash).
# Saves /etc/config/wireless once to /tmp/acstest/wireless.orig, applies channel auto + ACS
# options to one radio, restarts only that radio (wifi up <radio>), records /proc/uptime and
# logread timestamps (ACS start, ACS-COMPLETED, AP-ENABLED, downtime, ACS: line count, errors),
# captures iw survey dump, and always restores the original config (verified with iw dev) via
# trap and a detached setsid watchdog. Also runs long passive reference scans (ref) and CSA
# dwell windows (r2). Writes only to /tmp/acstest/.
#
# Usage:
#   sh acstest.sh run <radio0|radio1> <label> [--channels "<list>"] [--opt "<k=v>"]...
#                 [--bias "<val>"] [--exclude-dfs <0|1>] [--timeout <sec>] [--no-restore]
#   sh acstest.sh ref <radio0|radio1> <repeats> <duration_tu> [label]
#   sh acstest.sh r2  <radio0|radio1> <dwell_sec> <channels_space_sep> [label]
#   sh acstest.sh restore [radio0|radio1]
#   sh acstest.sh clean
#   sh acstest.sh --test-parse <run_dir>

set -u

SELF="$0"
BASE="/tmp/acstest"
ORIG="$BASE/wireless.orig"
ORIG_STATE="$BASE/orig_state.env"
SUMMARY="$BASE/summary.tsv"
ACTIVE_LOCK="$BASE/active.lock"
ACTIVE_PID="$BASE/active.pid"

is_pidfile_alive() {
	pf="$1"
	[ -f "$pf" ] || return 1
	p=$(cat "$pf" 2>/dev/null)
	[ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

check_not_busy() {
	if is_pidfile_alive "$ACTIVE_PID"; then
		echo "ERROR: another acstest run is alive (pid $(cat "$ACTIVE_PID" 2>/dev/null))" >&2
		return 1
	fi
	if is_pidfile_alive "$BASE/watchdog.pid"; then
		echo "ERROR: an acstest watchdog is still alive (pid $(cat "$BASE/watchdog.pid" 2>/dev/null))" >&2
		return 1
	fi
	return 0
}

acquire_active_lock() {
	mkdir -p "$BASE"
	if is_pidfile_alive "$ACTIVE_PID" || is_pidfile_alive "$BASE/watchdog.pid"; then
		check_not_busy
		exit 1
	fi
	if ! mkdir "$ACTIVE_LOCK" 2>/dev/null; then
		if is_pidfile_alive "$ACTIVE_PID" || is_pidfile_alive "$BASE/watchdog.pid"; then
			check_not_busy
			exit 1
		fi
		# Stale lock from a dead process
		rmdir "$ACTIVE_LOCK" 2>/dev/null || true
		mkdir "$ACTIVE_LOCK" 2>/dev/null || { echo "ERROR: cannot acquire $ACTIVE_LOCK" >&2; exit 1; }
	fi
	echo "$$" > "$ACTIVE_PID"
}

release_active_lock() {
	if [ -f "$ACTIVE_PID" ] && [ "$(cat "$ACTIVE_PID" 2>/dev/null)" = "$$" ]; then
		rm -f "$ACTIVE_PID"
		rmdir "$ACTIVE_LOCK" 2>/dev/null || true
	fi
}

radio_to_ifname() {
	case "$1" in
		radio0) echo "phy0-ap0" ;;
		radio1) echo "phy1-ap0" ;;
		*) echo ""; return 1 ;;
	esac
}

uptime_s() {
	cut -d' ' -f1 /proc/uptime
}

ts_utc() {
	date -u +%Y-%m-%dT%H:%M:%SZ
}

fsub() {
	awk -v a="$1" -v b="$2" 'BEGIN {
		if (a == "" || b == "" || a == "-" || b == "-") { print "-"; exit }
		printf "%.2f", (a + 0) - (b + 0)
	}'
}

# Capture lines added after (line_count, last_line) safely across ring-buffer wraps.
lines_after_mark() {
	n0="$1"
	last="$2"
	awk -v n0="$n0" -v last="$last" '
	{
		all[NR] = $0
		if (last != "" && $0 == last) last_match = NR
	}
	END {
		if (n0 == 0) {
			for (i = 1; i <= NR; i++) print all[i]
			exit
		}
		if (NR >= n0 && all[n0] == last) {
			for (i = n0 + 1; i <= NR; i++) print all[i]
			exit
		}
		if (last_match > 0) {
			for (i = last_match + 1; i <= NR; i++) print all[i]
			exit
		}
		for (i = 1; i <= NR; i++) print all[i]
	}'
}

iw_chan_width() {
	iw dev "$1" info 2>/dev/null | awk '
	/channel / {
		c = $2
		w = ""
		for (i = 1; i <= NF; i++) {
			if ($i == "width:") w = $(i + 1)
		}
		printf "%s %s", c, w
		exit
	}'
}

save_orig_once() {
	mkdir -p "$BASE/runs" "$BASE/ref"
	[ -f "$ORIG" ] || cp /etc/config/wireless "$ORIG"
	if [ ! -f "$ORIG_STATE" ]; then
		cw0=$(iw_chan_width "phy0-ap0")
		cw1=$(iw_chan_width "phy1-ap0")
		cat <<EOF > "$ORIG_STATE"
ORIG_CHAN_radio0='${cw0%% *}'
ORIG_WIDTH_radio0='${cw0#* }'
ORIG_CHAN_radio1='${cw1%% *}'
ORIG_WIDTH_radio1='${cw1#* }'
EOF
	fi
}

orig_matches_radio() {
	r="$1"
	[ -f "$ORIG_STATE" ] || return 0
	. "$ORIG_STATE"
	ifname=$(radio_to_ifname "$r") || return 1
	eval "oc=\$ORIG_CHAN_$r; ow=\$ORIG_WIDTH_$r"
	[ -n "$oc" ] || return 0
	cur=$(iw_chan_width "$ifname")
	[ "$cur" = "$oc $ow" ]
}

hostapd_is_enabled() {
	ifname="$1"
	oc="$2"
	st=$(ubus call "hostapd.$ifname" get_status 2>/dev/null || true)
	echo "$st" | grep -q '"status": "ENABLED"' || return 1
	[ -z "$oc" ] || echo "$st" | grep -q "\"channel\": $oc," || return 1
	return 0
}

wait_radio_orig() {
	r="$1"
	lr_n0="${2:-}"
	lr_last="${3:-}"
	ifname=$(radio_to_ifname "$r") || return 1
	oc=""
	[ -f "$ORIG_STATE" ] && { . "$ORIG_STATE"; eval "oc=\$ORIG_CHAN_$r"; }
	i=0
	while [ "$i" -lt 45 ]; do
		if orig_matches_radio "$r" && hostapd_is_enabled "$ifname" "$oc"; then
			if [ -z "$lr_n0" ] || logread | lines_after_mark "$lr_n0" "$lr_last" | grep -q "$ifname: AP-ENABLED"; then
				return 0
			fi
		fi
		sleep 1
		i=$((i + 1))
	done
	return 1
}

force_restore_radio() {
	radios="${1:-radio0 radio1}"
	[ -f "$ORIG" ] || return 1
	cp "$ORIG" /etc/config/wireless
	for r in $radios; do
		lr_n0=$(logread | wc -l)
		lr_last=$(logread | tail -n 1)
		wifi up "$r" </dev/null >/dev/null 2>&1
		wait_radio_orig "$r" "$lr_n0" "$lr_last" || true
	done
}

start_watchdog() {
	parent_pid="$1"
	timeout_sec="$2"
	radios="$3"
	done_flag="$4"
	rm -f "$done_flag"
	setsid sh "$SELF" _watchdog "$parent_pid" "$timeout_sec" "$radios" "$done_flag" </dev/null >"$BASE/watchdog.log" 2>&1 &
	echo $! > "$BASE/watchdog.pid"
}

stop_watchdog() {
	done_flag="$1"
	touch "$done_flag"
	if [ -f "$BASE/watchdog.pid" ]; then
		wpid=$(cat "$BASE/watchdog.pid" 2>/dev/null)
		[ -n "$wpid" ] && kill "$wpid" 2>/dev/null || true
		rm -f "$BASE/watchdog.pid"
	fi
}

cmd_watchdog() {
	parent_pid="$1"
	timeout_sec="$2"
	radios="$3"
	done_flag="$4"
	elapsed=0
	while [ "$elapsed" -lt "$timeout_sec" ]; do
		[ -f "$done_flag" ] && exit 0
		kill -0 "$parent_pid" 2>/dev/null || break
		sleep 5
		elapsed=$((elapsed + 5))
	done
	[ -f "$done_flag" ] && exit 0
	echo "$(ts_utc) WATCHDOG TRIGGERED (parent=$parent_pid elapsed=${elapsed}s radios=$radios)"
	kill "$parent_pid" 2>/dev/null || true
	sleep 2
	kill -9 "$parent_pid" 2>/dev/null || true
	case "$radios" in
		scan:*)
			ifname="${radios#scan:}"
			if [ -f "$BASE/scan.pid" ]; then
				spid=$(cat "$BASE/scan.pid" 2>/dev/null)
				[ -n "$spid" ] && kill "$spid" 2>/dev/null || true
				rm -f "$BASE/scan.pid"
			fi
			iw dev "$ifname" scan abort 2>/dev/null || true
			echo "$(ts_utc) WATCHDOG SCAN ABORTED ($ifname)"
			;;
		*)
			force_restore_radio "$radios"
			echo "$(ts_utc) WATCHDOG RESTORE DONE: $(iw_chan_width phy0-ap0) | $(iw_chan_width phy1-ap0)"
			;;
	esac
	if [ -f "$ACTIVE_PID" ] && [ "$(cat "$ACTIVE_PID" 2>/dev/null)" = "$parent_pid" ]; then
		rm -f "$ACTIVE_PID"
		rmdir "$ACTIVE_LOCK" 2>/dev/null || true
	fi
	exit 0
}

# Parse hostapd logread lines and meta.env of a run directory; prints/writes parsed fields.
parse_run() {
	rdir="$1"
	[ -f "$rdir/meta.env" ] || { echo "ERROR: missing $rdir/meta.env"; return 1; }
	[ -f "$rdir/logread.txt" ] || { echo "ERROR: missing $rdir/logread.txt"; return 1; }
	. "$rdir/meta.env"

	# Extract timestamps & fields from logread.txt
	parsed=$(awk -v ifn="$IFNAME" '
	function wallts(line,    a) {
		# Example: Thu Nov 19 15:16:30 2026 daemon.info hostapd: ...
		if (match(line, /^[A-Z][a-z][a-z] [A-Z][a-z][a-z] [ 0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9] [0-9][0-9][0-9][0-9]/)) {
			return substr(line, RSTART, RLENGTH)
		}
		return ""
	}
	/ACS:/ { acs_lines++ }
	/ACS: Automatic channel selection started/ {
		if (ts_acs_start == "") ts_acs_start = wallts($0)
	}
	index($0, ifn ": ACS-COMPLETED") > 0 {
		ts_acs_done = wallts($0)
		if (match($0, /freq=[0-9]+/)) freq = substr($0, RSTART + 5, RLENGTH - 5)
		if (match($0, /channel=[0-9]+/)) chan = substr($0, RSTART + 8, RLENGTH - 8)
	}
	index($0, ifn ": AP-DISABLED") > 0 {
		if (ts_ap_dis == "") ts_ap_dis = wallts($0)
	}
	index($0, ifn ": AP-ENABLED") > 0 {
		ts_ap_en = wallts($0)
	}
	/ACS: Failed|ACS-DISABLED|Failed to start|Could not set channel|DFS.*failed|start_dfs_cac\(\) failed/ {
		err_lines++
	}
	END {
		printf "TS_AP_DIS='\''%s'\''\n", ts_ap_dis
		printf "TS_ACS_START='\''%s'\''\n", ts_acs_start
		printf "TS_ACS_DONE='\''%s'\''\n", ts_acs_done
		printf "TS_AP_EN='\''%s'\''\n", ts_ap_en
		printf "CHOSEN_FREQ='\''%s'\''\n", (freq != "" ? freq : "-")
		printf "CHOSEN_CHAN='\''%s'\''\n", (chan != "" ? chan : "-")
		printf "ACS_LINES=%d\n", acs_lines + 0
		printf "ERR_LINES=%d\n", err_lines + 0
	}' "$rdir/logread.txt")
	eval "$parsed"

	downtime_s=$(fsub "${UP_AP_EN:-}" "${UP_CMD:-}")
	acs_s=$(fsub "${UP_ACS_DONE:-}" "${UP_ACS_START:-}")

	cat <<EOF > "$rdir/parsed.env"
RUN_ID='$RUN_ID'
RADIO='$RADIO'
LABEL='$LABEL'
CHANNELS='$CHANNELS'
OPTS='$OPTS'
BIAS='$BIAS'
EX_DFS='$EX_DFS'
UP_CMD='$UP_CMD'
UP_ACS_START='$UP_ACS_START'
UP_ACS_DONE='$UP_ACS_DONE'
UP_AP_EN='$UP_AP_EN'
DOWNTIME_S='$downtime_s'
ACS_S='$acs_s'
CHOSEN_FREQ='$CHOSEN_FREQ'
CHOSEN_CHAN='$CHOSEN_CHAN'
ACS_LINES='$ACS_LINES'
ERR_LINES='$ERR_LINES'
STATUS='$STATUS'
TS_CMD='$TS_CMD'
TS_ACS_START='$TS_ACS_START'
TS_ACS_DONE='$TS_ACS_DONE'
TS_AP_EN='$TS_AP_EN'
EOF
	echo "run=$RUN_ID radio=$RADIO label=$LABEL status=$STATUS chan=$CHOSEN_CHAN freq=$CHOSEN_FREQ downtime=${downtime_s}s acs=${acs_s}s acs_lines=$ACS_LINES err=$ERR_LINES"
}

append_summary() {
	rdir="$1"
	. "$rdir/parsed.env"
	if [ ! -f "$SUMMARY" ]; then
		printf "run_id\tradio\tlabel\tchannels\topts\tbias\tex_dfs\tcmd_up\tacs_start_up\tacs_done_up\tap_en_up\tdowntime_s\tacs_s\tfreq\tchannel\tacs_lines\terr_lines\tstatus\tts_cmd\tts_acs_start\tts_acs_done\tts_ap_en\n" > "$SUMMARY"
	fi
	printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
		"$RUN_ID" "$RADIO" "$LABEL" "${CHANNELS:-all}" "${OPTS:-none}" "${BIAS:-default}" "${EX_DFS:-default}" \
		"$UP_CMD" "$UP_ACS_START" "$UP_ACS_DONE" "$UP_AP_EN" "$DOWNTIME_S" "$ACS_S" \
		"$CHOSEN_FREQ" "$CHOSEN_CHAN" "$ACS_LINES" "$ERR_LINES" "$STATUS" \
		"$TS_CMD" "$TS_ACS_START" "$TS_ACS_DONE" "$TS_AP_EN" >> "$SUMMARY"
}

cmd_run() {
	RADIO="${1:-}"
	LABEL="${2:-}"
	[ -n "$RADIO" ] && [ -n "$LABEL" ] || { echo "Usage: $SELF run <radio0|radio1> <label> [options]"; exit 1; }
	shift 2
	IFNAME=$(radio_to_ifname "$RADIO") || { echo "ERROR: unknown radio $RADIO"; exit 1; }

	CHANNELS=""
	OPTS=""
	BIAS=""
	EX_DFS=""
	TIMEOUT=""
	NO_RESTORE=0

	while [ $# -gt 0 ]; do
		case "$1" in
			--channels) CHANNELS="$2"; shift 2 ;;
			--opt) OPTS="${OPTS:+$OPTS }$2"; shift 2 ;;
			--bias) BIAS="$2"; shift 2 ;;
			--exclude-dfs) EX_DFS="$2"; shift 2 ;;
			--timeout) TIMEOUT="$2"; shift 2 ;;
			--no-restore) NO_RESTORE=1; shift ;;
			*) echo "ERROR: unknown arg $1"; exit 1 ;;
		esac
	done

	if [ -z "$TIMEOUT" ]; then
		[ "$RADIO" = "radio0" ] && TIMEOUT=180 || TIMEOUT=240
	fi

	acquire_active_lock
	save_orig_once
	RUN_ID="$(date -u +%Y%m%d-%H%M%S)-${RADIO}-${LABEL}"
	RDIR="$BASE/runs/$RUN_ID"
	mkdir -p "$RDIR"
	DONE_FLAG="$BASE/run.done"
	NEED_RESTORE=1

	cleanup_run() {
		rc=$?
		if [ "$NEED_RESTORE" = 1 ]; then
			force_restore_radio "$RADIO"
		fi
		stop_watchdog "$DONE_FLAG"
		iw dev "$IFNAME" info > "$RDIR/iw_restored.txt" 2>&1 || true
		release_active_lock
		exit "$rc"
	}
	trap cleanup_run EXIT INT TERM HUP

	start_watchdog "$$" "$((TIMEOUT + 60))" "$RADIO" "$DONE_FLAG"

	iw dev "$IFNAME" survey dump > "$RDIR/survey_before.txt" 2>&1 || true

	LR_N0=$(logread | wc -l)
	LR_LAST=$(logread | tail -n 1)
	DM_N0=$(dmesg | wc -l)
	DM_LAST=$(dmesg | tail -n 1)

	# Apply UCI wireless settings for this radio only
	uci set "wireless.$RADIO.channel=auto"
	uci -q delete "wireless.$RADIO.channels"
	for c in $CHANNELS; do
		uci add_list "wireless.$RADIO.channels=$c"
	done
	uci -q delete "wireless.$RADIO.hostapd_options"
	for o in $OPTS; do
		uci add_list "wireless.$RADIO.hostapd_options=$o"
	done
	if [ -n "$BIAS" ]; then
		uci set "wireless.$RADIO.acs_chan_bias=$BIAS"
	else
		uci -q delete "wireless.$RADIO.acs_chan_bias"
	fi
	if [ -n "$EX_DFS" ]; then
		uci set "wireless.$RADIO.acs_exclude_dfs=$EX_DFS"
	else
		uci -q delete "wireless.$RADIO.acs_exclude_dfs"
	fi
	uci commit wireless

	UP_CMD=$(uptime_s)
	TS_CMD=$(ts_utc)
	( wifi up "$RADIO" ) </dev/null >"$RDIR/wifi_up.log" 2>&1 &

	UP_ACS_START="-"
	UP_ACS_DONE="-"
	UP_AP_EN="-"
	SURVEY_SAVED=0
	STATUS="timeout"
	START_SEC=$(date +%s)

	while :; do
		sleep 1
		now_up=$(uptime_s)
		now_sec=$(date +%s)
		elapsed=$((now_sec - START_SEC))

		logread | lines_after_mark "$LR_N0" "$LR_LAST" > "$RDIR/logread.txt"
		dmesg | lines_after_mark "$DM_N0" "$DM_LAST" > "$RDIR/dmesg.txt"

		if [ "$UP_ACS_START" = "-" ] && grep -q "ACS: Automatic channel selection started" "$RDIR/logread.txt"; then
			UP_ACS_START="$now_up"
		fi
		if [ "$UP_ACS_DONE" = "-" ] && grep -q "$IFNAME: ACS-COMPLETED" "$RDIR/logread.txt"; then
			UP_ACS_DONE="$now_up"
			if [ "$SURVEY_SAVED" = 0 ]; then
				iw dev "$IFNAME" survey dump > "$RDIR/survey.txt" 2>&1 || true
				SURVEY_SAVED=1
			fi
		fi
		if [ "$UP_AP_EN" = "-" ] && grep -q "$IFNAME: AP-ENABLED" "$RDIR/logread.txt"; then
			UP_AP_EN="$now_up"
			STATUS="ok"
			break
		fi
		if grep -qE "ACS: Failed|ACS-DISABLED|start_dfs_cac\(\) failed" "$RDIR/logread.txt"; then
			STATUS="acs_error"
			break
		fi
		if [ "$RADIO" = "radio0" ] && grep -qi "timed out" "$RDIR/dmesg.txt"; then
			STATUS="mcu_timeout"
			dmesg > "$BASE/hang_dmesg_${RUN_ID}.txt" 2>&1 || true
			logread > "$BASE/hang_logread_${RUN_ID}.txt" 2>&1 || true
			break
		fi
		if [ "$elapsed" -ge "$TIMEOUT" ]; then
			STATUS="timeout"
			if [ "$RADIO" = "radio0" ]; then
				dmesg > "$BASE/hang_dmesg_${RUN_ID}.txt" 2>&1 || true
				logread > "$BASE/hang_logread_${RUN_ID}.txt" 2>&1 || true
			fi
			break
		fi
	done

	[ "$SURVEY_SAVED" = 1 ] || iw dev "$IFNAME" survey dump > "$RDIR/survey.txt" 2>&1 || true
	iw dev "$IFNAME" info > "$RDIR/iw_after.txt" 2>&1 || true

	phy="${IFNAME%%-*}"
	if [ -f "/var/run/hostapd-${phy}.conf" ]; then
		grep -E '^((hw_mode|channel|chanlist|country_code|ht_capab)=|acs_[^=]*=|vht_oper_[^=]*=)' "/var/run/hostapd-${phy}.conf" > "$RDIR/hostapd_acs.conf" 2>/dev/null || true
	fi

	cat <<EOF > "$RDIR/meta.env"
RUN_ID='$RUN_ID'
RADIO='$RADIO'
IFNAME='$IFNAME'
LABEL='$LABEL'
CHANNELS='$CHANNELS'
OPTS='$OPTS'
BIAS='$BIAS'
EX_DFS='$EX_DFS'
UP_CMD='$UP_CMD'
UP_ACS_START='$UP_ACS_START'
UP_ACS_DONE='$UP_ACS_DONE'
UP_AP_EN='$UP_AP_EN'
TS_CMD='$TS_CMD'
STATUS='$STATUS'
EOF

	parse_run "$RDIR"
	append_summary "$RDIR"

	if [ "$NO_RESTORE" = 1 ] && [ "$STATUS" = "ok" ]; then
		NEED_RESTORE=0
	fi
	if [ "$STATUS" = "mcu_timeout" ] || { [ "$RADIO" = "radio0" ] && [ "$STATUS" = "timeout" ]; }; then
		NEED_RESTORE=1
		exit 3
	fi
	[ "$STATUS" = "ok" ] || exit 2
	exit 0
}

cmd_ref() {
	RADIO="${1:-}"
	REPEATS="${2:-10}"
	DUR="${3:-500}"
	LABEL="${4:-ref}"
	[ -n "$RADIO" ] || { echo "Usage: $SELF ref <radio0|radio1> <repeats> <duration_tu> [label]"; exit 1; }
	IFNAME=$(radio_to_ifname "$RADIO") || { echo "ERROR: unknown radio $RADIO"; exit 1; }

	acquire_active_lock
	save_orig_once
	REF_ID="$(date -u +%Y%m%d-%H%M%S)-${RADIO}-${LABEL}"
	RDIR="$BASE/ref/$REF_ID"
	mkdir -p "$RDIR"
	DONE_FLAG="$BASE/ref.done"

	cleanup_ref() {
		rc=$?
		if [ -f "$BASE/scan.pid" ]; then
			spid=$(cat "$BASE/scan.pid" 2>/dev/null)
			[ -n "$spid" ] && kill "$spid" 2>/dev/null || true
			rm -f "$BASE/scan.pid"
		fi
		stop_watchdog "$DONE_FLAG"
		release_active_lock
		exit "$rc"
	}
	trap cleanup_ref EXIT INT TERM HUP
	start_watchdog "$$" "$((REPEATS * 25 + 60))" "scan:$IFNAME" "$DONE_FLAG"

	DM_N0=$(dmesg | wc -l)
	DM_LAST=$(dmesg | tail -n 1)
	TS_START=$(ts_utc)
	UP_START=$(uptime_s)
	iw dev "$IFNAME" survey dump > "$RDIR/survey_00.txt" 2>&1

	i=1
	while [ "$i" -le "$REPEATS" ]; do
		idx=$(printf "%02d" "$i")
		t0=$(uptime_s)
		iw dev "$IFNAME" scan duration "$DUR" ap-force passive > "$RDIR/scan_${idx}.txt" 2> "$RDIR/scan_${idx}.err" &
		spid=$!
		echo "$spid" > "$BASE/scan.pid"
		wait "$spid"
		rc=$?
		rm -f "$BASE/scan.pid"
		t1=$(uptime_s)
		iw dev "$IFNAME" survey dump > "$RDIR/survey_${idx}.txt" 2>&1
		dt=$(fsub "$t1" "$t0")
		echo "scan_${idx}: rc=$rc dur=${dt}s err=$(wc -c < "$RDIR/scan_${idx}.err")" >> "$RDIR/scans.log"
		if dmesg | lines_after_mark "$DM_N0" "$DM_LAST" | grep -qi "timed out"; then
			dmesg > "$BASE/hang_dmesg_${REF_ID}.txt" 2>&1 || true
			echo "ERROR: MCU timeout during ref scan $idx" >> "$RDIR/scans.log"
			exit 3
		fi
		[ "$i" -lt "$REPEATS" ] && sleep 2
		i=$((i + 1))
	done

	TS_END=$(ts_utc)
	UP_END=$(uptime_s)
	dmesg | lines_after_mark "$DM_N0" "$DM_LAST" > "$RDIR/dmesg.txt"
	cat <<EOF > "$RDIR/meta.env"
REF_ID='$REF_ID'
RADIO='$RADIO'
IFNAME='$IFNAME'
LABEL='$LABEL'
REPEATS='$REPEATS'
DUR_TU='$DUR'
TS_START='$TS_START'
TS_END='$TS_END'
UP_START='$UP_START'
UP_END='$UP_END'
EOF
	echo "ref_done: $RDIR ($(fsub "$UP_END" "$UP_START")s)"
}

# R2 fallback: dwell on each channel via hostapd switch_chan and measure operating survey delta.
cmd_r2() {
	RADIO="${1:-}"
	DWELL="${2:-60}"
	CHANS="${3:-}"
	LABEL="${4:-r2}"
	[ -n "$RADIO" ] && [ -n "$CHANS" ] || { echo "Usage: $SELF r2 <radio0|radio1> <dwell_sec> \"<ch list>\" [label]"; exit 1; }
	IFNAME=$(radio_to_ifname "$RADIO") || { echo "ERROR: unknown radio $RADIO"; exit 1; }

	acquire_active_lock
	save_orig_once
	. "$ORIG_STATE"
	REF_ID="$(date -u +%Y%m%d-%H%M%S)-${RADIO}-${LABEL}"
	RDIR="$BASE/ref/$REF_ID"
	mkdir -p "$RDIR"
	DONE_FLAG="$BASE/r2.done"

	cleanup_r2() {
		rc=$?
		force_restore_radio "$RADIO"
		stop_watchdog "$DONE_FLAG"
		release_active_lock
		exit "$rc"
	}
	trap cleanup_r2 EXIT INT TERM HUP

	nch=$(echo "$CHANS" | wc -w)
	start_watchdog "$$" "$((nch * (DWELL + 15) + 90))" "$RADIO" "$DONE_FLAG"

	for ch in $CHANS; do
		if [ "$RADIO" = "radio1" ]; then
			freq=$((5000 + ch * 5))
			case "$ch" in
				36|40|44|48) cf1=5210 ;;
				52|56|60|64) cf1=5290 ;;
				100|104|108|112) cf1=5530 ;;
				116|120|124|128) cf1=5610 ;;
				132|136|140|144) cf1=5690 ;;
				149|153|157|161) cf1=5775 ;;
				*) echo "ERROR: unsupported 5GHz VHT80 base channel $ch"; exit 1 ;;
			esac
			payload="{\"freq\":$freq,\"center_freq1\":$cf1,\"bandwidth\":80,\"sec_channel_offset\":1,\"ht\":true,\"vht\":true,\"bcn_count\":10}"
		else
			freq=$((2407 + ch * 5))
			payload="{\"freq\":$freq,\"bandwidth\":20,\"ht\":true,\"bcn_count\":10}"
		fi

		ubus call "hostapd.$IFNAME" switch_chan "$payload" > "$RDIR/csa_${ch}.out" 2>&1 || true
		sleep 3
		iw dev "$IFNAME" survey dump > "$RDIR/survey_${ch}_before.txt" 2>&1
		t0=$(uptime_s)
		sleep "$DWELL"
		t1=$(uptime_s)
		iw dev "$IFNAME" survey dump > "$RDIR/survey_${ch}_after.txt" 2>&1
		echo "ch=$ch freq=$freq dwell=$(fsub "$t1" "$t0")s" >> "$RDIR/r2.log"
	done

	# Restore original channel via switch_chan first, then verify in cleanup
	if [ "$RADIO" = "radio1" ]; then
		och="$ORIG_CHAN_radio1"
		ofreq=$((5000 + och * 5))
		case "$och" in
			36|40|44|48) ocf1=5210 ;;
			52|56|60|64) ocf1=5290 ;;
			100|104|108|112) ocf1=5530 ;;
			116|120|124|128) ocf1=5610 ;;
			132|136|140|144) ocf1=5690 ;;
			149|153|157|161) ocf1=5775 ;;
			*) ocf1=5290 ;;
		esac
		ubus call "hostapd.$IFNAME" switch_chan "{\"freq\":$ofreq,\"center_freq1\":$ocf1,\"bandwidth\":80,\"sec_channel_offset\":1,\"ht\":true,\"vht\":true,\"bcn_count\":10}" >/dev/null 2>&1 || true
	else
		och="$ORIG_CHAN_radio0"
		ofreq=$((2407 + och * 5))
		ubus call "hostapd.$IFNAME" switch_chan "{\"freq\":$ofreq,\"bandwidth\":20,\"ht\":true,\"bcn_count\":10}" >/dev/null 2>&1 || true
	fi
	sleep 3
	echo "r2_done: $RDIR"
}

cmd_restore() {
	check_not_busy || exit 1
	radios="${1:-radio0 radio1}"
	force_restore_radio "$radios"
	echo "restored: phy0-ap0=[$(iw_chan_width phy0-ap0)] phy1-ap0=[$(iw_chan_width phy1-ap0)]"
}

cmd_clean() {
	check_not_busy || exit 1
	rm -rf "$BASE"
	echo "cleaned: $BASE"
}

case "${1:-}" in
	run) shift; cmd_run "$@" ;;
	ref) shift; cmd_ref "$@" ;;
	r2) shift; cmd_r2 "$@" ;;
	restore) shift; cmd_restore "$@" ;;
	clean) shift; cmd_clean "$@" ;;
	_watchdog) shift; cmd_watchdog "$@" ;;
	--test-parse)
		shift
		parse_run "${1:-}"
		;;
	*)
		sed -n '2,18p' "$SELF"
		exit 1
		;;
esac
