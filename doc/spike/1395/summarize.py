#!/usr/bin/env python3
"""summarize.py -- base#1395 slice 1: median / IQR / range per mode. SPIKE ONLY.

usage: summarize.py results/<file>.tsv...
Rows are measure.sh's TSV: mode temp run ms rc load1 load5.
"""
import collections
import statistics as st
import sys

for path in sys.argv[1:]:
    ms = collections.defaultdict(list)
    fails = collections.Counter()
    load = collections.defaultdict(list)
    for line in open(path):
        mode, temp, _run, t, rc, l1, _l5 = line.rstrip("\n").split("\t")
        key = (mode, temp)
        ms[key].append(int(t))
        fails[key] += int(rc) != 0
        load[key].append(float(l1))
    print(f"# {path}")
    print("mode\ttemp\tn\tmedian_ms\tp25\tp75\tmin\tmax\trc!=0\tload1_min\tload1_max")
    for key, v in ms.items():
        q = st.quantiles(v, n=4)
        print(f"{key[0]}\t{key[1]}\t{len(v)}\t{st.median(v):.0f}\t{q[0]:.0f}\t"
              f"{q[2]:.0f}\t{min(v)}\t{max(v)}\t{fails[key]}\t"
              f"{min(load[key]):.2f}\t{max(load[key]):.2f}")
