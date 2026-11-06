#!/usr/bin/env python3
"""Names the module samples of kprof (module offset count lines) with the unstripped .ko files.
The run-time address of every executable section comes from the global functions that
/proc/kallsyms of the router lists for the module (address - offset in its section), so the
layout of the module in memory need not be guessed. Sums the samples per function.
Usage: modsym.py <dump> <kallsyms+modules file> <dir with .ko files, searched recursively>
The kallsyms+modules file: the module lines of /proc/kallsyms of the router, a line "#modules", then
/proc/modules. Run it in the build container (pyelftools)."""
import os
import sys
from collections import defaultdict
from elftools.elf.elffile import ELFFile
from elftools.elf.sections import SymbolTableSection

SHF_ALLOC, SHF_EXECINSTR = 0x2, 0x4

ksyms = defaultdict(dict)      # module -> name -> address
bases = {}                     # module -> text base of /proc/modules
part = 0
for line in open(sys.argv[2]):
    if line.startswith("#modules"):
        part = 1
        continue
    f = line.split()
    if part == 0 and len(f) >= 4:
        ksyms[f[3].strip("[]")][f[2]] = int(f[0], 16)
    elif part == 1 and len(f) >= 6:
        bases[f[0]] = int(f[5], 16)


def table(mod, path):
    """(run-time start, end, name) of every function whose section has an anchor"""
    out = []
    with open(path, "rb") as fh:
        elf = ELFFile(fh)
        secs = {i: s for i, s in enumerate(elf.iter_sections())
                if s["sh_flags"] & SHF_ALLOC and s["sh_flags"] & SHF_EXECINSTR}
        funcs = []
        for st in elf.iter_sections():
            if isinstance(st, SymbolTableSection):
                for s in st.iter_symbols():
                    if s["st_info"]["type"] == "STT_FUNC" and s["st_shndx"] in secs:
                        funcs.append((s["st_shndx"], s["st_value"], s["st_size"], s.name))
        secbase = {}
        for shndx, value, size, name in funcs:
            if shndx not in secbase and name in ksyms[mod]:
                secbase[shndx] = ksyms[mod][name] - value
        for shndx, value, size, name in funcs:
            if shndx in secbase:
                out.append((secbase[shndx] + value, secbase[shndx] + value + max(size, 4), name))
    return sorted(out)


kos = {}
for root, _, files in os.walk(sys.argv[3]):
    for fn in files:
        if fn.endswith(".ko"):
            kos.setdefault(fn[:-3].replace("-", "_"), os.path.join(root, fn))
tables = {}
per = defaultdict(int)
total = 0
for line in open(sys.argv[1]):
    mod, off, n = line.split()
    n = int(n)
    total += n
    if mod not in tables:
        tables[mod] = table(mod, kos[mod]) if mod in kos else []
    ip = bases.get(mod, 0) + int(off, 16)
    name = "?"
    for a, b, nm in tables[mod]:
        if a <= ip < b:
            name = nm
            break
    per[(mod, name)] += n
for (mod, name), n in sorted(per.items(), key=lambda x: -x[1])[:int(os.environ.get("TOP", "30"))]:
    print(f"{n:6d} {100.0 * n / total:5.1f}%  {mod}:{name}")
print(f"{total} module samples")
