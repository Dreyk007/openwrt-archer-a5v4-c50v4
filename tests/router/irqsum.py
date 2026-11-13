#!/usr/bin/env python3
"""Summarise a log of tests/router/irqlab.sh or tests/router/autolab.sh.

For every run: the state, Mbit/s of the run's own interface, CPU idle, CPU busy per Mbit/s,
interrupts per second, the worst lateness of the 100 ms timer of kprof and, where the log has them
(autolab.sh), the retries per packet of the phone's station and the ping to it (avg/max ms). Then per
(run, state): the number of runs, the mean and the spread (min-max) of each value. Runs below
5 Mbit/s or with the phone gone do not count in the summary.

Usage: python3 irqsum.py <irqlab.log> [<more logs>]
"""
import collections
import re
import sys


def runs(path):
    """All runs of a log, in order, each a dict filled from the lines under its header."""
    out = []
    cycle = None
    cur = None
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.rstrip("\n")
        m = re.match(r"== cycle (\d+), state (\w+)", line)
        if m:
            cycle = int(m.group(1))
            continue
        m = re.match(r"-- (.*) \(state (\w+)\), (\S+)", line)
        if m:
            cur = {"log": path, "cycle": cycle, "run": m.group(1), "state": m.group(2)}
            out.append(cur)
            continue
        if cur is None:
            continue
        m = re.match(r"interrupts/s: eth0 (\d+), mt76x2e (\d+), mt7603e (\d+)", line)
        if m:
            cur["irq"] = tuple(int(x) for x in m.groups())
        m = re.match(r"CPU over [\d.]+ s: idle (\d+)%.*late by up to (\d+) ms", line)
        if m:
            cur["idle"] = int(m.group(1))
            cur["late"] = int(m.group(2))
        m = re.match(r"station: (\d+) packets, ([\d.]+) retries per packet, (\d+) failed", line)
        if m:
            cur["retry"] = float(m.group(2))
        m = re.match(r"ping: (\S+) loss, avg ([\d.]+) ms, max ([\d.]+) ms", line)
        if m:
            cur["ping"] = (float(m.group(2)), float(m.group(3)))
        if line.startswith("!! PHONE GONE"):
            cur["gone"] = True
        m = re.match(r"interface: ([\d.]+) Mbit/s", line)
        if m:
            cur["udp"] = float(m.group(1))
        if line.startswith("traffic"):
            cur["tr"] = {d: (float(rx), float(tx))
                         for d, rx, tx in re.findall(r"(\S+) rx ([\d.]+) tx ([\d.]+);", line)}
    return out


def mbit(r):
    """Throughput of the run on the interface it is about."""
    t = r.get("tr", {})
    name = r["run"]
    if name.startswith("UDP"):
        return r.get("udp", 0.0)
    if name.startswith("phone, download"):
        return max(t.get("phy1-ap0", (0, 0))[1], t.get("phy0-ap0", (0, 0))[1])
    if name.startswith("phone, upload"):
        return max(t.get("phy1-ap0", (0, 0))[0], t.get("phy0-ap0", (0, 0))[0])
    if name.startswith("PC cable, download"):
        return t.get("eth0.2", (0, 0))[0]
    if name.startswith("PC cable, upload"):
        return t.get("eth0.2", (0, 0))[1]
    if name.startswith("PC Wi-Fi, download"):
        return t.get("phy0-ap0", (0, 0))[1]
    if name.startswith("PC Wi-Fi, upload"):
        return t.get("phy0-ap0", (0, 0))[0]
    return 0.0


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    agg = collections.defaultdict(list)
    print(f"{'run':22} {'cyc':>3} {'state':5} {'Mbit/s':>7} {'idle%':>5} {'%/Mbit':>7} "
          f"{'eth0/s':>7} {'5GHz/s':>7} {'2.4/s':>6} {'late':>4} {'retry':>5} {'ping':>11}")
    for path in sys.argv[1:]:
        for r in runs(path):
            mb = mbit(r)
            idle = r.get("idle", 0)
            per = (100 - idle) / mb if mb > 1 else 0.0
            irq = r.get("irq", (0, 0, 0))
            pg = r.get("ping")
            print(f"{r['run'][:22]:22} {r['cycle'] or 0:>3} {r['state']:5} {mb:7.1f} {idle:5d} "
                  f"{per:7.3f} {irq[0]:7d} {irq[1]:7d} {irq[2]:6d} {r.get('late', 0):4d} "
                  f"{r.get('retry', 0):5.2f} {(f'{pg[0]:.1f}/{pg[1]:.1f}' if pg else '-'):>11}"
                  f"{'  PHONE GONE' if r.get('gone') else ''}")
            if mb > 5 and not r.get("gone"):  # a run without traffic (client gone) does not count
                agg[(r["run"], r["state"])].append((mb, idle, per, irq[0], irq[1], irq[2],
                                                    r.get("late", 0), r.get("retry", 0.0),
                                                    pg[0] if pg else 0.0))
    print()
    print("per run and state: n, mean (min-max)")
    for (run, state), v in sorted(agg.items()):
        def col(i, fmt):
            xs = [x[i] for x in v]
            return f"{fmt.format(sum(xs) / len(xs))} ({fmt.format(min(xs))}-{fmt.format(max(xs))})"
        print(f"{run[:22]:22} {state:5} n={len(v)}  Mbit/s {col(0, '{:.1f}')}  idle {col(1, '{:.0f}')}%  "
              f"%/Mbit {col(2, '{:.3f}')}  irq/s eth0 {col(3, '{:.0f}')} 5GHz {col(4, '{:.0f}')} "
              f"2.4GHz {col(5, '{:.0f}')}  late max {max(x[6] for x in v)} ms  "
              f"retries/packet {col(7, '{:.2f}')}  ping avg {col(8, '{:.1f}')} ms")


if __name__ == "__main__":
    main()
