#!/usr/bin/env python3
"""Signal quality of an ECG Recorder CSV, computed the way the app does.

usage: signal_quality.py session.csv

Per participant:
  - RR artifacts (Lipponen & Tarvainen 2019, as in Metrics/Artifacts.swift): which intervals are ectopic,
    missed, extra or long/short, and how many.
  - ECG kurtosis per 10 s (kSQI, Li, Clifford et al. 2008; as in Metrics/SignalQuality.swift): clean ECG has
    sharp QRS peaks and a kurtosis well above 5; noise and motion bring it towards 3.
Use it to check a recording against what the app showed, and to calibrate the noisy-signal thresholds.
No dependencies beyond the standard library.
"""
import csv, sys
from collections import defaultdict

ALPHA, C1, C2, WIDTH, MED_ORDER, MIN_TH = 5.2, 0.13, 0.17, 91, 11, 10.0
KSQI_CLEAN, ECG_HZ, MAX_SHARE, SHARE_BEATS = 5.0, 130, 0.2, 30

def quantile(sorted_vals, q):
    pos = q * (len(sorted_vals) - 1)
    lo = int(pos)
    hi = min(lo + 1, len(sorted_vals) - 1)
    return sorted_vals[lo] + (sorted_vals[hi] - sorted_vals[lo]) * (pos - lo)

def threshold(values):
    n, half, out = len(values), WIDTH // 2, []
    for i in range(n):
        w = sorted(abs(v) for v in values[max(0, i - half):min(n, i + half + 1)])
        out.append(max(MIN_TH, ALPHA * (quantile(w, 0.75) - quantile(w, 0.25)) / 2))
    return out

def median(vals):
    s = sorted(vals)
    m = len(s) // 2
    return s[m] if len(s) % 2 else (s[m - 1] + s[m]) / 2

def artifacts(rr):
    """One label (or None) per interval of an uninterrupted run."""
    n = len(rr)
    flags = [None] * n
    if n < 4:
        return flags
    drr = [0.0] + [rr[i] - rr[i - 1] for i in range(1, n)]
    th1 = threshold(drr)
    nd = [d / t for d, t in zip(drr, th1)]
    def at(i):  # reflect at the ends, like numpy's "reflect" padding
        if i < 0: i = -i
        if i >= n: i = 2 * (n - 1) - i
        return nd[i]
    s12 = [max(at(i - 1), at(i + 1)) if nd[i] > 0 else min(at(i - 1), at(i + 1)) if nd[i] < 0 else 0.0 for i in range(n)]
    s22 = [min(at(i + 1), at(i + 2)) if nd[i] >= 0 else max(at(i + 1), at(i + 2)) for i in range(n)]
    h = MED_ORDER // 2
    med = [median(rr[max(0, i - h):min(n, i + h + 1)]) for i in range(n)]
    mrr = [(r - m) * (2 if r < m else 1) for r, m in zip(rr, med)]
    th2 = threshold(mrr)
    nm = [m / t for m, t in zip(mrr, th2)]

    def mark(i, kind):
        if 0 <= i < n and (flags[i] is None or (flags[i] == "long_short" and kind == "ectopic")):
            flags[i] = kind

    for i in range(n - 2):
        if abs(nd[i]) <= 1:
            continue
        if (nd[i] > 1 and s12[i] < -C1 * nd[i] - C2) or (nd[i] < -1 and s12[i] > -C1 * nd[i] + C2):
            mark(i - 1, "ectopic"); mark(i, "ectopic")   # both intervals around the ectopic beat
            continue
        candidates = [i] + ([i + 1] if abs(nd[i + 1]) < abs(nd[i + 2]) else [])
        for j in candidates:
            long_ = nd[j] > 1 and s22[j] < -1
            short = nd[j] < -1 and s22[j] > 1
            if not (long_ or short or abs(nm[j]) > 3):
                continue
            if short and j + 1 < n and abs(rr[j] + rr[j + 1] - med[j]) < th2[j]:
                mark(j, "extra"); mark(j + 1, "extra")
            elif long_ and abs(rr[j] / 2 - med[j]) < th2[j]:
                mark(j, "missed")
            else:
                mark(j, "long_short")
    return flags

def kurtosis(x):
    # 1 s moving average removed first, so baseline wander doesn't hide the QRS peaks.
    half, n = ECG_HZ // 2, len(x)
    pre = [0.0]
    for v in x: pre.append(pre[-1] + v)
    y = [x[i] - (pre[min(n, i + half + 1)] - pre[max(0, i - half)]) / (min(n, i + half + 1) - max(0, i - half)) for i in range(n)]
    m = sum(y) / n
    var = sum((v - m) ** 2 for v in y) / n
    return sum((v - m) ** 4 for v in y) / n / var ** 2 if var > 0 else 0.0

def noisy_runs(runs):
    """How many beats sit at the end of a 30-beat stretch with more than MAX_SHARE flagged (whole-run flags)."""
    count = 0
    for run in runs:
        flags = artifacts(run)
        for i in range(SHARE_BEATS, len(flags) + 1):
            if sum(f is not None for f in flags[i - SHARE_BEATS:i]) / SHARE_BEATS > MAX_SHARE:
                count += 1
    return count

def main():
    rr_runs = defaultdict(lambda: [[]])
    ecg = defaultdict(list)
    last_t = {}
    for r in csv.DictReader(open(sys.argv[1], newline="")):
        p, s = r["participant"], r["stream"]
        if s == "ECG":
            ecg[p] += [int(v) for v in r["value"].split()]
        elif s == "RR":
            t = float(r["unix_time_s"])
            flag = r["flag"] if r["flag"] in ("no_contact", "implausible_rr") else ""
            if flag or t - last_t.get(p, t) > 5:
                rr_runs[p].append([])
            last_t[p] = t
            if not flag:
                rr_runs[p][-1].append(float(r["value"]))
        elif s == "EVENT" and r["note"] in ("disconnect", "no_data") or r["note"] == "session_resume":
            rr_runs[p].append([])
    for p in sorted(set(rr_runs) | set(ecg)):
        counts, total = defaultdict(int), 0
        for run in rr_runs[p]:
            total += len(run)
            for f in artifacts(run):
                if f: counts[f] += 1
        flagged = sum(counts.values())
        print(f"{p}: {total} clean-contact intervals, {flagged} artifacts ({100 * flagged / max(1, total):.1f}%) {dict(counts)}")
        x = ecg[p]
        ks = [kurtosis(x[i:i + 10 * ECG_HZ]) for i in range(0, len(x) - 10 * ECG_HZ + 1, 10 * ECG_HZ)]
        noisy = sum(k < KSQI_CLEAN for k in ks)
        print(f"  noisy (>{100 * MAX_SHARE:g}% of 30 beats flagged) in {noisy_runs(rr_runs[p])} of the beat positions checked")
        print(f"  ECG kurtosis per 10 s ({noisy} of {len(ks)} below {KSQI_CLEAN:g}): " + " ".join(f"{k:.1f}" for k in ks))

if __name__ == "__main__":
    main()
