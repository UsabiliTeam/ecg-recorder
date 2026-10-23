#!/usr/bin/env python3
"""Regenerates media/bell.wav, the auto-stop chime.

Three bell strikes pitched where iPhone speakers are loudest (about 1-4 kHz; a low fundamental is
inaudible on a phone speaker), soft-clipped and normalized to near full scale so it is loud at any
media volume. Stays well under the 30 s limit iOS puts on notification sounds.
"""
import array, math, wave, pathlib

RATE = 44100
FUNDAMENTAL = 1046.5                       # C6
PARTIALS = [(1.0, 1.0), (2.76, 0.6), (5.40, 0.35), (8.93, 0.2)]   # (ratio, amplitude), slightly inharmonic
DECAY = 3.0                                # 1/s
STRIKES = [0.0, 0.45, 0.9]                 # seconds
LENGTH = 2.4

n = int(RATE * LENGTH)
out = [0.0] * n
for t0 in STRIKES:
    start = int(t0 * RATE)
    for i in range(n - start):
        t = i / RATE
        attack = min(1.0, t / 0.003)        # 3 ms attack, no click
        env = attack * math.exp(-DECAY * t)
        out[start + i] += env * sum(a * math.sin(2 * math.pi * FUNDAMENTAL * r * t) for r, a in PARTIALS)

out = [math.tanh(1.8 * x) for x in out]    # soft clip: raises loudness without harsh distortion
peak = max(abs(x) for x in out)
fade = int(0.05 * RATE)
samples = array.array("h", (int(32000 * x / peak * min(1.0, (n - i) / fade)) for i, x in enumerate(out)))

path = pathlib.Path(__file__).resolve().parent.parent / "media" / "bell.wav"
with wave.open(str(path), "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(RATE)
    w.writeframes(samples.tobytes())
print(f"wrote {path}")
