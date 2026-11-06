#!/usr/bin/env python3
"""Source lines of the kprof samples in one function of one module (build tree, debug image):
the run-time base of the module's .text comes from a global function that /proc/kallsyms of the
router lists, the samples are mapped to offsets in .text and named with addr2line of the toolchain
(the innermost inlined function and its line). Run it in the build container (pyelftools).
Usage: modlines.py <dump> <kallsyms+modules file> <module .ko> <module> <function>"""
import glob
import subprocess
import sys
from collections import defaultdict
from elftools.elf.elffile import ELFFile
from elftools.elf.sections import SymbolTableSection

dump, ks, ko, mod, fn = sys.argv[1:6]
anchors, base, part = {}, 0, 0
for line in open(ks):
    if line.startswith("#modules"):
        part = 1
        continue
    f = line.split()
    if part == 0 and len(f) >= 4 and f[3] == "[" + mod + "]":
        anchors[f[2]] = int(f[0], 16)
    elif part == 1 and f and f[0] == mod:
        base = int(f[5], 16)

elf = ELFFile(open(ko, "rb"))
text = [s.name for s in elf.iter_sections()].index(".text")
textbase, lo, hi = None, None, None
for st in elf.iter_sections():
    if not isinstance(st, SymbolTableSection):
        continue
    for s in st.iter_symbols():
        if s["st_shndx"] != text or s["st_info"]["type"] != "STT_FUNC":
            continue
        if textbase is None and s.name in anchors:
            textbase = anchors[s.name] - s["st_value"]
        if s.name == fn:
            lo, hi = s["st_value"], s["st_value"] + s["st_size"]
if textbase is None or lo is None:
    sys.exit("no anchor in .text or no such function")

offsets, total = defaultdict(int), 0
for line in open(dump):
    m, off, n = line.split()
    o = base + int(off, 16) - textbase
    if m == mod and lo <= o < hi:
        offsets[o] += int(n)
        total += int(n)
addr2line = glob.glob("/work/staging_dir/toolchain-*/bin/*-addr2line")[0]
items = sorted(offsets.items())
out = subprocess.run([addr2line, "-e", ko, "-f"] + [hex(o) for o, _ in items],
                     capture_output=True, text=True).stdout.split("\n")
lines = defaultdict(int)
for i, (o, n) in enumerate(items):
    lines[(out[2 * i], out[2 * i + 1].split("/")[-1])] += n
for (func, loc), n in sorted(lines.items(), key=lambda x: -x[1])[:15]:
    print(f"{n:5d} {100.0 * n / total:5.1f}%  {func}  {loc}")
print(f"{total} samples in {fn}")
