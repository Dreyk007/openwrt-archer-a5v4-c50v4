#!/data/data/com.termux/files/usr/bin/sh
# iperf3 client loop of the router tests on an Android phone in Termux (pkg install iperf3): the
# phone's slots of the 240 s cycle that the PC shares by the clock (iperf-pc.ps1), download at
# 120 s and upload at 150 s, 4 TCP streams for 20 s after 2 s of warm-up, to port 5203 of the
# iperf3 server. Keep the phone on the charger; the wake lock keeps Termux running.
#
#   sh iperf-phone.sh <address>
S=${1:?usage: sh iperf-phone.sh <server address>}
termux-wake-lock 2>/dev/null
slot() { while [ $(( $(date +%s) % 240 )) -ne "$1" ]; do sleep 0.3; done; }
while true; do
	slot 120; echo "$(date +%T) download"; iperf3 -c "$S" -p 5203 -R -P 4 -t 20 -O 2 | grep -E 'SUM.*(sender|receiver)|error'
	slot 150; echo "$(date +%T) upload"; iperf3 -c "$S" -p 5203 -P 4 -t 20 -O 2 | grep -E 'SUM.*(sender|receiver)|error'
done
