#!/data/data/com.termux/files/usr/bin/bash
# Phone side of the unattended router tests (autolab.sh on the router), for Termux on Android
# (pkg install iperf3 curl netcat-openbsd). Idle until the router announces a session at
# http://<router>:5299/session; then, in each 240 s cycle by the clock, runs the phone's slots that
# the session lists against the iperf3 server of the PC it names: "dl" downloads at 120 s, "ul"
# uploads at 150 s, 4 TCP streams for 20 s after 2 s of warm-up. Between sessions one HTTP request
# every 10 s and nothing else. Log: ~/autolab-phone.log. Keep the phone on the charger with the
# screen on (Developer options: Stay awake), so that its Wi-Fi does not go to power save.
#
#   bash iperf-phone-auto.sh <router address>
RT=${1:?usage: bash iperf-phone-auto.sh <router address>}
LOG=$HOME/autolab-phone.log
termux-wake-lock 2>/dev/null
S=""
log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }
fetch() { S=$(curl -s -m 3 "http://$RT:5299/session" 2>/dev/null); }
val() { printf '%s\n' "$S" | sed -n "s/^$1=//p" | head -n 1; }
active() { fetch; local u; u=$(val until); [[ $u =~ ^[0-9]+$ ]] && (( u > $(date +%s) )); }
wait_second() { while (( $(date +%s) % 240 != $1 )); do sleep 0.3; done; }
run() {
	local pc port r=""
	pc=$(val pc); port=$(val port)
	[[ $1 == dl ]] && r=-R
	log "session $(val id): $1 with $pc:${port:-5203}"
	res=$(iperf3 -c "$pc" -p "${port:-5203}" $r -P 4 -t 20 -O 2 --connect-timeout 3000 2>&1 |
		grep -E 'SUM.*(sender|receiver)|error' | tee -a "$LOG")
	printf '%s\n' "$res"
	# Send result to router report port 5298 if reachable
	echo "PHONE $1: $(echo "$res" | tr '\n' ' ')" | nc -w 2 "$RT" 5298 2>/dev/null || true
}
log "started, router $RT"
while true; do
	if ! active; then sleep 10; continue; fi
	now=$(( $(date +%s) % 240 ))
	if (( now >= 115 )); then sleep $(( 240 - now )); continue; fi
	(( now < 110 )) && sleep $(( 110 - now ))
	active || continue
	phone=$(val phone)
	if [[ $phone == *dl* ]]; then wait_second 120; run dl; fi
	if [[ $phone == *ul* ]]; then wait_second 150; active && run ul; fi
	sleep 5
done
