#!/bin/sh
# Frees a phone whose iperf3 client hangs after a failed run: when the server gives up on a run
# ("unable to receive results") and closes the control connection, the phone keeps retransmitting
# into it, the router tracks those packets as a new connection that gets no reply, and the client
# never returns to its loop (seen twice on 2026-11-06). For each such connection (ESTABLISHED and
# UNREPLIED in conntrack) a rule answers the phone's next retransmission with a TCP reset, so the
# client fails and the loop goes on; the rule goes once it has fired. The rules live in a table of
# their own, which a reboot or `nft delete table inet unstick` removes.
# Usage: sh unstick.sh <phone ip> [server port, 5203] [interval s, 30]   (log: /tmp/unstick.log)
P=$1; PORT=${2:-5203}; I=${3:-30}; L=/tmp/unstick.log
nft add table inet unstick
nft add chain inet unstick resets '{ type filter hook forward priority -10; }'
echo "start $(date +%T), phone $P, port $PORT; conntrack stats (hex) $(awk 'NR==2' /proc/net/stat/nf_conntrack)" >> $L
while :; do
	for sp in $(grep "src=$P " /proc/net/nf_conntrack | grep "dport=$PORT " | grep ESTABLISHED | grep UNREPLIED |
			sed -n "s/.* src=$P dst=[0-9.]* sport=\([0-9]*\) dport=$PORT .*/\1/p"); do
		nft list chain inet unstick resets | grep -q "sport $sp " && continue
		nft add rule inet unstick resets ip saddr $P tcp sport $sp tcp dport $PORT counter reject with tcp reset
		echo "$(date +%T) a reset armed for the phone's port $sp" >> $L
	done
	nft -a list chain inet unstick resets | awk '/counter packets [1-9]/{print $NF}' | while read h; do
		nft delete rule inet unstick resets handle $h
		echo "$(date +%T) reset sent, rule $h removed" >> $L
	done
	sleep $I
done
