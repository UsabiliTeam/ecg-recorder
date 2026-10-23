#!/usr/bin/env python3
"""Unpack an ECG Recorder schema-2 CSV into one row per ECG sample.

usage: unpack_ecg.py [--sync] session.csv > ecg_samples.csv
       columns: participant,device_id,unix_time_s,sensor_time_ns,uv[,unix_time_sync_s],label

Each ECG row holds one Bluetooth packet: `value` = microvolts separated by spaces, `sensor_time_ns` = first
sample, `note` = last sample. Samples are spaced evenly between the two, and unix_time_s is the first sample's
phone time. Other streams (HR, RR, CONTACT, EVENT, SYNC, MARKER, LABEL) are already one row per value.

label: the condition label running at the sample's unix_time_s, empty when none. LABEL rows mark the start of
a label (`note` = name); `flag` = end closes it, `flag` = undo takes back the latest start or end still in effect.
A label runs until the next start or end, or the end of the recording.

unix_time_s comes from the packet's arrival on the phone, so it carries Bluetooth latency (tens of ms, varying
packet to packet). --sync adds unix_time_sync_s: the device's own steady clock mapped onto phone time through
the least-delayed packets (lower envelope of arrival minus sensor time, per 30 s), which removes the jitter and
follows the sensor's clock drift. Use it to align several devices.
pandas:  df = pd.read_csv(path); ecg = df[df.stream == "ECG"] ; then explode as below.
"""
import bisect, csv, sys

CHUNK_S = 30.0      # envelope resolution: short enough to follow crystal drift, long enough to catch a fast packet
JUMP_S = 1.0        # a change in offset larger than this is a clock reset, not latency


def offsets(path):
    """Per device: list of segments, each a sorted list of (sensor_s, offset_s) envelope points."""
    raw = {}
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            if r["stream"] == "ECG":
                s = int(r["sensor_time_ns"]) / 1e9
                raw.setdefault(r["device_id"], []).append((s, float(r["unix_time_s"]) - s))
    env = {}
    for dev, pts in raw.items():
        segments, seg = [], [pts[0]]
        for prev, cur in zip(pts, pts[1:]):
            if cur[0] < prev[0] or abs(cur[1] - prev[1]) > JUMP_S:
                segments.append(seg)
                seg = []
            seg.append(cur)
        segments.append(seg)
        env[dev] = []
        for seg in segments:
            chunks = {}
            for s, d in seg:
                k = int((s - seg[0][0]) // CHUNK_S)
                if k not in chunks or d < chunks[k][1]:
                    chunks[k] = (s, d)
            env[dev].append(sorted(chunks.values()))
    return env


def label_spans(path):
    """[(start_s, end_s, name)] after undos, the same rules as the app's LabelTimeline."""
    events, last_t = [], None
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            last_t = float(r["unix_time_s"])
            if r["stream"] != "LABEL":
                continue
            if r["flag"] == "undo":
                if events:
                    events.pop()
            else:
                events.append((last_t, r["flag"], r["note"]))
    return [(t, events[i + 1][0] if i + 1 < len(events) else last_t, name)
            for i, (t, kind, name) in enumerate(events) if kind == ""]


def label_at(spans, starts, t):
    i = bisect.bisect_right(starts, t) - 1
    return spans[i][2] if i >= 0 and t < spans[i][1] else ""


def offset_at(env, dev, s):
    """Phone minus sensor seconds at sensor time `s`, from the envelope segment that covers it."""
    segs = env[dev]
    seg = next((g for g in reversed(segs) if g[0][0] <= s), segs[0])
    i = bisect.bisect_right(seg, (s, float("inf")))
    if i == 0:
        return seg[0][1]
    if i == len(seg):
        return seg[-1][1]
    (x0, d0), (x1, d1) = seg[i - 1], seg[i]
    return d0 + (d1 - d0) * (s - x0) / (x1 - x0)


def main(path, sync):
    env = offsets(path) if sync else None
    spans = label_spans(path)
    starts = [s[0] for s in spans]
    out = csv.writer(sys.stdout)
    out.writerow(["participant", "device_id", "unix_time_s", "sensor_time_ns", "uv"] + (["unix_time_sync_s"] if sync else []) + ["label"])
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            if r["stream"] != "ECG":
                continue
            uv = r["value"].split()
            first, last = int(r["sensor_time_ns"]), int(r["note"])
            step = (last - first) / max(len(uv) - 1, 1)
            d = offset_at(env, r["device_id"], first / 1e9) if sync else 0   # constant within one packet
            for i, v in enumerate(uv):
                ns = first + round(i * step)
                t = float(r["unix_time_s"]) + (ns - first) / 1e9
                row = [r["participant"], r["device_id"], f"{t:.6f}", ns, v]
                if sync:
                    row.append(f"{ns / 1e9 + d:.6f}")
                row.append(label_at(spans, starts, t))
                out.writerow(row)


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--sync"]
    if len(args) != 1:
        sys.exit(__doc__)
    main(args[0], "--sync" in sys.argv[1:])
