# Open Questions

Picked up together during discussions. Highest priority first.

1. Colour scheme: overall palette; colour of the "No data" state (currently orange).
2. HR zones: how max HR is obtained (age-based, data-derived, none). Mock uses a fixed 190.
3. Accelerometer default rate and range (currently 200 Hz, 8 g).
4. Timeline axis: continuous with zoom, or compressed between sessions.
5. CSV schema 2 (8 columns) is in; revisit after real H10 data (ECG is packed per packet).
6. Polar SDK: migrate heart rate from the deprecated `deviceHrObserver` to `startHrStreaming` when upgrading the SDK.
7. Time-sensitive notifications: needs a paid developer account entitlement; Focus may suppress alerts until then.
8. Bundle ID is `com.example.ecgrecorder`; pick the real one.
9. Auto-created participants ("P1", "P2", ...) become permanent phonebook entries; keep or make them temporary?
10. Real simultaneous-device limit and cross-device sync accuracy: measure on hardware.
11. HR zones: the "Max HR" picker (Age-based / Data-derived) changes nothing yet; zones always use 190 bpm. Hide the picker until a method is built, or collect age?
12. Live RMSSD now waits for 30 s of clean beats (shows "–" until then, also after a dropout). Show a small "warming up" hint instead of "–"?
13. Plausible RR range is 300-2000 ms (30-200 bpm). Widen for exercise studies (HR above 200)?
14. Measure on hardware: `rrs` (1/1024 s) vs `rrsMs` from Polar SDK 8.3.0 agree (the app falls back to `rrsMs` if not), and the ECG stall watchdog never fires on a healthy stream.
15. Noisy-signal thresholds (ECG kurtosis < 5 over 10 s, or > 20% of the last 30 intervals flagged, for 5 s) are first estimates: calibrate on a recording made with a dry or loose strap (`tools/signal_quality.py`).
16. Log noisy/clean periods in the CSV (EVENT rows) once the thresholds are calibrated, so analyses can exclude them?
