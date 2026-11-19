#!/usr/bin/env python3
"""Summarise reference scans and ACS runs from tests/router/acstest.sh.

Parses:
  - ref directories (R1: scan_XX.txt + survey_XX.txt; R2: survey_<ch>_before/after.txt),
    computing active-time-weighted foreign busy % per channel (subtracting BSS RX and TX
    time on the operating channel), 2.4 GHz hostapd and 20 MHz spectral-overlap scores,
    5 GHz VHT80 block means, and unique BSSID counts/signals.
  - summary.tsv from acstest.sh runs, joining chosen channel/block against the
    reference to report overlap regret and hostapd-score regret (in percentage points).

Usage:
  python3 acssum.py ref <ref_dir> [<more ref_dirs>]
  python3 acssum.py runs <summary.tsv> [--ref2g <ref_dir>] [--ref5g <ref_dir>]
"""
import collections
import csv
import glob
import os
import re
import sys

VHT80_BLOCKS = [
    (36, 48, [36, 40, 44, 48]),
    (52, 64, [52, 56, 60, 64]),
    (100, 112, [100, 104, 108, 112]),
    (116, 128, [116, 120, 124, 128]),
    (132, 144, [132, 136, 140, 144]),
    (149, 161, [149, 153, 157, 161]),
]

HOSTAPD_WEIGHTS = {0: 1.0, 1: 0.85, 2: 0.55}
OVERLAP_WEIGHTS = {0: 1.0, 1: 0.75, 2: 0.50, 3: 0.25}


def freq_to_chan(freq):
    if 2412 <= freq <= 2472:
        return (freq - 2407) // 5
    if freq == 2484:
        return 14
    if 5000 < freq < 5900:
        return (freq - 5000) // 5
    return None


def block_of_chan(ch):
    for lo, hi, chans in VHT80_BLOCKS:
        if ch in chans:
            return f"{lo}-{hi}"
    return f"{ch}"


def parse_survey(path):
    """Return {freq: {'in_use': bool, 'active': int, 'busy': int, 'bss_rx': int, 'tx': int}}."""
    out = {}
    cur_freq = None
    for line in open(path, encoding="utf-8", errors="replace"):
        m = re.search(r"frequency:\s+(\d+)\s+MHz(\s+\[in use\])?", line)
        if m:
            cur_freq = int(m.group(1))
            out[cur_freq] = {
                "in_use": bool(m.group(2)),
                "active": 0,
                "busy": 0,
                "bss_rx": 0,
                "tx": 0,
            }
            continue
        if cur_freq is None:
            continue
        for key, pat in [
            ("active", r"channel active time:\s+(\d+)\s+ms"),
            ("busy", r"channel busy time:\s+(\d+)\s+ms"),
            ("bss_rx", r"channel BSS receive time:\s+(\d+)\s+ms"),
            ("tx", r"channel transmit time:\s+(\d+)\s+ms"),
        ]:
            m = re.search(pat, line)
            if m:
                out[cur_freq][key] = int(m.group(1))
    return out


def parse_scan_bsses(path):
    """Return list of {'bssid': str, 'freq': int, 'chan': int, 'signal': float}."""
    bsses = []
    cur = None
    for line in open(path, encoding="utf-8", errors="replace"):
        m = re.match(r"^BSS\s+([0-9a-f:]{17})", line)
        if m:
            if cur and cur.get("freq"):
                bsses.append(cur)
            cur = {"bssid": m.group(1), "freq": None, "chan": None, "signal": None}
            continue
        if cur is None:
            continue
        m = re.match(r"^\s*freq:\s+(\d+)", line)
        if m:
            cur["freq"] = int(m.group(1))
            cur["chan"] = freq_to_chan(cur["freq"])
        m = re.match(r"^\s*signal:\s+(-?[\d.]+)\s+dBm", line)
        if m:
            cur["signal"] = float(m.group(1))
        m = re.match(r"^\s*\* primary channel:\s+(\d+)", line)
        if m:
            cur["chan"] = int(m.group(1))
    if cur and cur.get("freq"):
        bsses.append(cur)
    return bsses


def foreign_busy(cur_d, prev_d):
    """Return (da, foreign_busy_ms) for one survey interval."""
    if cur_d["in_use"]:
        if prev_d is not None:
            da = cur_d["active"] - prev_d["active"]
            db = cur_d["busy"] - prev_d["busy"]
            drx = cur_d["bss_rx"] - prev_d["bss_rx"]
            dtx = cur_d["tx"] - prev_d["tx"]
            dfb = max(0, db - drx - dtx)
            return da, dfb
        # With 0334, mt76_sw_scan() clears the operating channel at scan start.
        dfb = max(0, cur_d["busy"] - cur_d["bss_rx"] - cur_d["tx"])
        return cur_d["active"], dfb
    return cur_d["active"], cur_d["busy"]


def analyse_ref_r1(ref_dirs):
    """Aggregate R1 ref directories."""
    chan_samples = collections.defaultdict(list)  # ch -> list of (da, dfb)
    bsses_by_ch = collections.defaultdict(dict)     # ch -> {bssid: max_signal}
    all_bsses = {}                                # bssid -> (ch, max_signal)
    band = None
    cleared_dirs = 0

    for rdir in ref_dirs:
        surveys = sorted(glob.glob(os.path.join(rdir, "survey_*.txt")))
        scans = sorted(glob.glob(os.path.join(rdir, "scan_*.txt")))
        if not surveys:
            continue
        parsed = [parse_survey(p) for p in surveys]
        in_use_acts = [d["active"] for sv in parsed for d in sv.values() if d["in_use"]]
        cleared = any(in_use_acts[i] < in_use_acts[i - 1] for i in range(1, len(in_use_acts)))
        if cleared:
            cleared_dirs += 1
        prev = parsed[0]
        for cur in parsed[1:]:
            for freq, d in cur.items():
                ch = freq_to_chan(freq)
                if ch is None:
                    continue
                if band is None:
                    band = "2g" if ch <= 14 else "5g"
                da, dfb = foreign_busy(d, None if cleared else prev.get(freq))
                if da > 0:
                    chan_samples[ch].append((da, dfb))
            prev = cur

        for scpath in scans:
            for b in parse_scan_bsses(scpath):
                ch = b["chan"]
                if ch is None or b["signal"] is None:
                    continue
                old = bsses_by_ch[ch].get(b["bssid"])
                if old is None or b["signal"] > old:
                    bsses_by_ch[ch][b["bssid"]] = b["signal"]
                old_all = all_bsses.get(b["bssid"])
                if old_all is None or b["signal"] > old_all[1]:
                    all_bsses[b["bssid"]] = (ch, b["signal"])

    return band, chan_samples, bsses_by_ch, all_bsses, cleared_dirs > 0


def analyse_ref_r2(ref_dirs):
    """Aggregate R2 ref directories (survey_<ch>_before/after.txt)."""
    chan_samples = collections.defaultdict(list)
    band = None
    for rdir in ref_dirs:
        for bpath in sorted(glob.glob(os.path.join(rdir, "survey_*_before.txt"))):
            apath = bpath.replace("_before.txt", "_after.txt")
            if not os.path.exists(apath):
                continue
            m = re.search(r"survey_(\d+)_before\.txt$", bpath)
            if not m:
                continue
            ch = int(m.group(1))
            if band is None:
                band = "2g" if ch <= 14 else "5g"
            sb = parse_survey(bpath)
            sa = parse_survey(apath)
            freq = (2407 + ch * 5) if ch <= 14 else (5000 + ch * 5)
            if freq in sb and freq in sa:
                da, dfb = foreign_busy(sa[freq], sb[freq])
                if da > 0:
                    chan_samples[ch].append((da, dfb))
    return band, chan_samples, {}, {}, False


def weighted_score(chan_mean, ch, weights):
    num = 0.0
    den = 0.0
    for d, w in weights.items():
        for c in ([ch] if d == 0 else [ch - d, ch + d]):
            if c in chan_mean:
                num += w * chan_mean[c]
                den += w
    return (num / den) if den > 0 else None


def parse_bias(bias_str):
    """Parse acs_chan_bias string (e.g. '1:0.8 6:0.8 11:0.8') or None for default."""
    if not bias_str or bias_str == "default":
        return {1: 0.8, 6: 0.8, 11: 0.8}
    out = {}
    for tok in bias_str.split():
        if ":" in tok:
            k, v = tok.split(":", 1)
            if k.isdigit():
                out[int(k)] = float(v)
    return out


def hostapd_2g_scores(chan_mean, bias_str="default"):
    bias = parse_bias(bias_str)
    scores = {}
    for ch in chan_mean:
        sc = weighted_score(chan_mean, ch, HOSTAPD_WEIGHTS)
        if sc is not None:
            scores[ch] = sc * bias.get(ch, 1.0)
    return scores


def overlap_2g_scores(chan_mean):
    scores = {}
    for ch in chan_mean:
        sc = weighted_score(chan_mean, ch, OVERLAP_WEIGHTS)
        if sc is not None:
            scores[ch] = sc
    return scores


def compute_ref_stats(ref_dirs):
    """Return dict with weighted per-channel stats, 2G scores, 5G block means, and BSSIDs."""
    has_r1 = any(glob.glob(os.path.join(d, "survey_0*.txt")) for d in ref_dirs)
    if has_r1:
        band, samples, bsses_by_ch, all_bsses, cleared_0334 = analyse_ref_r1(ref_dirs)
    else:
        band, samples, bsses_by_ch, all_bsses, cleared_0334 = analyse_ref_r2(ref_dirs)

    chan_mean = {}
    chan_mm = {}
    for ch, pairs in sorted(samples.items()):
        tot_da = sum(da for da, _ in pairs)
        tot_dfb = sum(dfb for _, dfb in pairs)
        pcts = [100.0 * dfb / da for da, dfb in pairs]
        chan_mean[ch] = 100.0 * tot_dfb / tot_da
        chan_mm[ch] = (min(pcts), max(pcts), len(pairs), tot_da / len(pairs))

    hostapd_sc = hostapd_2g_scores(chan_mean) if band == "2g" else {}
    overlap_sc = overlap_2g_scores(chan_mean) if band == "2g" else {}

    block_mean = {}
    block_mm = {}
    if band == "5g":
        for lo, hi, chans in VHT80_BLOCKS:
            bname = f"{lo}-{hi}"
            present = [ch for ch in chans if ch in samples]
            if not present:
                continue
            block_mean[bname] = sum(chan_mean[ch] for ch in present) / len(present)
            nrep = min(len(samples[ch]) for ch in present)
            rep_means = [
                sum(100.0 * samples[ch][i][1] / samples[ch][i][0] for ch in present) / len(present)
                for i in range(nrep)
            ]
            block_mm[bname] = (min(rep_means), max(rep_means), len(rep_means))

    return {
        "band": band,
        "chan_mean": chan_mean,
        "chan_mm": chan_mm,
        "hostapd_sc": hostapd_sc,
        "overlap_sc": overlap_sc,
        "block_mean": block_mean,
        "block_mm": block_mm,
        "bsses_by_ch": bsses_by_ch,
        "all_bsses": all_bsses,
        "cleared_0334": cleared_0334,
    }


def print_ref(ref_dirs):
    st = compute_ref_stats(ref_dirs)
    band = st["band"]
    chan_mean = st["chan_mean"]
    chan_mm = st["chan_mm"]
    bsses_by_ch = st["bsses_by_ch"]
    all_bsses = st["all_bsses"]

    print(f"=== Reference ({band or '?'}, dirs={len(ref_dirs)}, unique_bssid={len(all_bsses)}, cleared_0334={st['cleared_0334']}) ===")
    if all_bsses:
        top = sorted(all_bsses.items(), key=lambda x: -x[1][1])[:5]
        top_s = ", ".join(f"ch{ch}:{sig:.0f}dBm" for _, (ch, sig) in top)
        print(f"Strongest networks: {top_s}")

    if band == "2g":
        print(f"{'ch':>3}  {'n':>2}  {'act_ms':>6}  {'busy%':>6}  {'min-max%':>13}  {'h_sc':>6}  {'ovlp':>6}  {'bss':>3}  {'max_dBm':>7}  {'ovlp_bss':>8}  {'ovlp_max':>8}")
        for ch in sorted(chan_mean):
            lo, hi, n, act = chan_mm[ch]
            hsc = st["hostapd_sc"].get(ch, 0.0)
            osc = st["overlap_sc"].get(ch, 0.0)
            nb = len(bsses_by_ch.get(ch, {}))
            max_sig = max(bsses_by_ch[ch].values()) if nb else None
            ovlp = []
            for och in range(max(1, ch - 2), min(14, ch + 3)):
                ovlp.extend(bsses_by_ch.get(och, {}).values())
            ov_n = len(ovlp)
            ov_max = max(ovlp) if ov_n else None
            ms = f"{max_sig:7.1f}" if max_sig is not None else "      -"
            oms = f"{ov_max:8.1f}" if ov_max is not None else "       -"
            print(f"{ch:>3}  {n:>2}  {act:>6.0f}  {chan_mean[ch]:>6.2f}  {lo:5.2f}-{hi:5.2f}  {hsc:>6.2f}  {osc:>6.2f}  {nb:>3}  {ms}  {ov_n:>8}  {oms}")
    else:
        print(f"{'ch':>3}  {'block':>7}  {'n':>2}  {'act_ms':>6}  {'busy%':>6}  {'min-max%':>13}  {'bss':>3}  {'max_dBm':>7}")
        for ch in sorted(chan_mean):
            lo, hi, n, act = chan_mm[ch]
            nb = len(bsses_by_ch.get(ch, {}))
            max_sig = max(bsses_by_ch[ch].values()) if nb else None
            ms = f"{max_sig:7.1f}" if max_sig is not None else "      -"
            print(f"{ch:>3}  {block_of_chan(ch):>7}  {n:>2}  {act:>6.0f}  {chan_mean[ch]:>6.2f}  {lo:5.2f}-{hi:5.2f}  {nb:>3}  {ms}")
        if st["block_mean"]:
            print()
            print(f"{'VHT80 block':>11}  {'n':>2}  {'busy%':>6}  {'min-max%':>13}")
            for bname, bm in st["block_mean"].items():
                lo, hi, n = st["block_mm"][bname]
                print(f"{bname:>11}  {n:>2}  {bm:>6.2f}  {lo:5.2f}-{hi:5.2f}")


def print_runs(tsv_path, ref2g_dirs, ref5g_dirs):
    ref2 = compute_ref_stats(ref2g_dirs) if ref2g_dirs else None
    ref5 = compute_ref_stats(ref5g_dirs) if ref5g_dirs else None
    best2_ovlp = min(ref2["overlap_sc"].values()) if ref2 and ref2["overlap_sc"] else None
    best5 = min(ref5["block_mean"].values()) if ref5 and ref5["block_mean"] else None

    rows = list(csv.DictReader(open(tsv_path, encoding="utf-8", errors="replace"), delimiter="\t"))
    agg = collections.defaultdict(list)
    print(f"{'run_id':26} {'radio':6} {'label':14} {'st':4} {'ch':>4} {'blk':>7} {'down_s':>6} {'acs_s':>6} {'lines':>5} {'err':>3} {'score':>6} {'reg_ov':>7} {'reg_ha':>7}")
    for r in rows:
        ch_s = r["channel"]
        ch = int(ch_s) if ch_s.isdigit() else None
        blk = block_of_chan(ch) if (ch and r["radio"] == "radio1") else "-"
        score = None
        reg_ov = None
        reg_ha = None
        if ch is not None:
            if r["radio"] == "radio0" and ref2 and ch in ref2["overlap_sc"]:
                score = ref2["overlap_sc"][ch]
                reg_ov = score - best2_ovlp if best2_ovlp is not None else None
                hsc_map = hostapd_2g_scores(ref2["chan_mean"], r.get("bias", "default"))
                if ch in hsc_map:
                    reg_ha = hsc_map[ch] - min(hsc_map.values())
            elif r["radio"] == "radio1" and ref5 and blk in ref5["block_mean"]:
                score = ref5["block_mean"][blk]
                reg_ov = score - best5 if best5 is not None else None
        ss = f"{score:6.2f}" if score is not None else "     -"
        ro = f"{reg_ov:+7.2f}" if reg_ov is not None else "      -"
        rh = f"{reg_ha:+7.2f}" if reg_ha is not None else "      -"
        print(f"{r['run_id'][:26]:26} {r['radio']:6} {r['label'][:14]:14} {r['status'][:4]:4} {ch_s:>4} {blk:>7} "
              f"{r['downtime_s']:>6} {r['acs_s']:>6} {r['acs_lines']:>5} {r['err_lines']:>3} {ss} {ro} {rh}")
        agg[(r["radio"], r["label"])].append((r, ch, blk, score, reg_ov, reg_ha))

    print("\n=== Summary by (radio, label) ===")
    for (radio, label), items in sorted(agg.items()):
        ok_items = [x for x in items if x[0]["status"] == "ok"]
        downs = [float(x[0]["downtime_s"]) for x in ok_items if x[0]["downtime_s"] != "-"]
        acss = [float(x[0]["acs_s"]) for x in ok_items if x[0]["acs_s"] != "-"]
        rovs = [x[4] for x in ok_items if x[4] is not None]
        rhas = [x[5] for x in ok_items if x[5] is not None]
        chans = [x[0]["channel"] for x in ok_items]

        def stat(xs, fmt="{:.2f}"):
            if not xs:
                return "-"
            return f"{fmt.format(sum(xs)/len(xs))} ({fmt.format(min(xs))}-{fmt.format(max(xs))})"

        ha_s = f"  reg_ha={stat(rhas)}pp" if rhas else ""
        print(f"{radio} {label:16} n={len(ok_items)}/{len(items)}  down={stat(downs)}s  acs={stat(acss)}s  "
              f"reg_ovlp={stat(rovs)}pp{ha_s}  chans={','.join(chans)}")


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    mode = sys.argv[1]
    if mode == "ref":
        print_ref(sys.argv[2:])
    elif mode == "runs":
        tsv = sys.argv[2]
        ref2g, ref5g = [], []
        i = 3
        while i < len(sys.argv):
            if sys.argv[i] == "--ref2g" and i + 1 < len(sys.argv):
                ref2g.append(sys.argv[i + 1]); i += 2
            elif sys.argv[i] == "--ref5g" and i + 1 < len(sys.argv):
                ref5g.append(sys.argv[i + 1]); i += 2
            else:
                sys.exit(__doc__)
        print_runs(tsv, ref2g, ref5g)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
