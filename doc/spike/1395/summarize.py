#!/usr/bin/env python3
"""summarize.py -- base#1395 slice 1: median / IQR / range per mode. SPIKE ONLY.

usage: summarize.py results/<file>.tsv...
Rows are measure.sh's TSV: mode temp run ms rc load1 load5.

Quartiles: statistics.quantiles(n=4), Python's default "exclusive" method.
Medians and quartiles are over rc == 0 rows only; failed rows are counted
in rc!=0 and their median time is shown separately (fail_median_ms).

For an interleaved file (every mode once per round, `run` = round), the
paired section prints, per pair of modes, the median of the per-round
difference (a - b) in ms and in percent of b, over rounds where both
succeeded, and in how many rounds a was the slower one.
"""
import collections
import statistics as st
import sys

PAIRS = [
    ("current-docker", "batch-docker"),          # batching, docker
    ("current-docker-fixed", "batch-docker"),    # batching, cold
    ("batch-docker", "go-docker"),               # language, same boundary
    ("go-docker", "go-native"),                  # container boundary, Go
    ("current-native", "batch-native"),          # batching, native
    ("batch-native", "go-native"),               # language, native
    ("batch-native", "floor"),                   # Python engine share
    ("go-native", "floor"),                      # Go engine share
]


def quart(v):
    if len(v) < 2:
        return v[0], v[0]
    qs = st.quantiles(v, n=4)
    return qs[0], qs[2]


for path in sys.argv[1:]:
    ok = collections.defaultdict(list)
    bad = collections.defaultdict(list)
    load = collections.defaultdict(list)
    by_round = collections.defaultdict(dict)
    order = []
    for line in open(path):
        mode, temp, run, t, rc, l1, _l5 = line.rstrip("\n").split("\t")[:7]
        key = (mode, temp)
        if key not in order:
            order.append(key)
        (ok if int(rc) == 0 else bad)[key].append(int(t))
        load[key].append(float(l1))
        if int(rc) == 0:
            by_round[run][mode] = int(t)
    print(f"# {path}")
    print("mode\ttemp\tn_ok\tmedian_ms\tp25\tp75\tmin\tmax\trc!=0"
          "\tfail_median_ms\tload1_min\tload1_max")
    for key in order:
        v = ok[key]
        if v:
            p25, p75 = quart(v)
            stats = (f"{st.median(v):.0f}\t{p25:.0f}\t{p75:.0f}\t"
                     f"{min(v)}\t{max(v)}")
        else:
            stats = "-\t-\t-\t-\t-"
        fm = f"{st.median(bad[key]):.0f}" if bad[key] else "-"
        print(f"{key[0]}\t{key[1]}\t{len(v)}\t{stats}\t{len(bad[key])}\t"
              f"{fm}\t{min(load[key]):.2f}\t{max(load[key]):.2f}")
    rows = []
    for a, b in PAIRS:
        both = [r for r in by_round.values() if a in r and b in r]
        if len(both) < 2:
            continue
        d = [r[a] - r[b] for r in both]
        pct = [100.0 * (r[a] - r[b]) / r[b] for r in both]
        d25, d75 = quart(d)
        rows.append(f"{a} - {b}\t{len(d)}\t{st.median(d):.0f}\t{d25:.0f}"
                    f"\t{d75:.0f}\t{st.median(pct):+.1f}%"
                    f"\t{sum(x > 0 for x in d)}/{len(d)}")
    if rows:
        print("paired (a - b)\tn\tmedian_ms\tp25\tp75\tmedian_pct_of_b"
              "\trounds_a_slower")
        print("\n".join(rows))
    print()
