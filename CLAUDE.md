# ECG Recorder

Also read `principles.md` before working on this project.

iPhone app (iOS 17+, portrait only, iPhone 13+) that records up to 6 Polar H10 devices at once, computes live HR and RMSSD, and stores one CSV per session locally. Users are physiological-computing researchers. English only, minimal Apple-style UI, light/dark follows iOS.

## Current state

In production: everything described here is in use, and no new features are under testing. Treat changes with care (see Reliability in `principles.md`). Built: Polar BLE SDK 8.3.0 (SPM) behind `SensorProvider`, a simulated provider for the Simulator, CSV writer, metrics pipeline, rebuildable JSON index, NTP query, persisted roster/settings, resume of interrupted recordings. The user confirmed it broadly works with real devices (auto-connect, live ECG, recording).

**Still unverified:** background/locked recording, multi-device limit, reconnect after real drops, resume after iOS termination. The real device limit and sync accuracy are still to be measured.

## Build, test, run

- The project is generated from `project.yml` with XcodeGen. Edit `project.yml`, not the derived `.xcodeproj`. After adding or removing a source file run `xcodegen generate` (and add the file to `Package.swift` if it is Foundation-only and tests need it).
- Build check: `xcodebuild -project ECGRecorder.xcodeproj -scheme ECGRecorder -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`
- Fast tests: `tools/test.sh` runs all logic tests on the Mac via `swift test` (root `Package.swift`, no simulator, about 12 s including the build; `tools/test.sh ReliabilityTests` for one class). The package compiles the same Foundation-only source files as the app (list in `Package.swift`). UI, Bluetooth and Live Activity code are not in it. `DeviceProviders` uses `canImport(PolarBleSdk)` so it compiles without the SDK on the Mac.
- Before finishing a change also run `tools/test.sh --sim` (iOS Simulator). Full equivalent: `xcodebuild test -project ECGRecorder.xcodeproj -scheme ECGRecorder -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO` (63 tests, incl. an end-to-end engine run with simulated devices). Tests wait on conditions (`waitUntil`), not fixed sleeps.
- Swift 5 language mode, `@Observable` state objects injected via `.environment(...)`.
- Installed via Xcode with a free account (re-sign every 7 days). The bundle ID is a placeholder (`com.example.ecgrecorder`); signing uses the user's personal team.
- The simulator uses `SimulatedSensor` automatically; on device, Settings > Testing > "Use simulated devices" switches to it. Long-press a live tile to inject faults (simulated only).

## Layout

`ECGRecorder/` (folders inside one target for now; the Swift package split is later)
- `App/`: entry point, dependency injection, 3-tab `RootView` (Record, Recordings, Settings). Launch runs `library.reload()` and `recording.resumeIfNeeded()`.
- `Core/`: models, `Validation` (all user text; strips control characters and leading `= + - @` against CSV formula injection), `CSV` (columns, escaping, `Stamp`, local time), `Format`, `ChartData`, `SessionFile` (share the CSV in place).
- `Devices/`: `Sensor`/`SensorProvider` protocols, `PolarSensor` (one shared SDK instance, retry, no-data watchdog, ECG-only stall watchdog that restarts ECG after 8 s without it while HR flows, stream restart), `SimulatedSensor`.
- `Metrics/`: `RRMetric` plug-ins (RMSSD, SDNN, pNN50), `MetricPipeline` (rolling window in beat time), `RRQuality` (device flags), `ArtifactDetector` (`Artifacts.swift`), `SignalQuality` (ECG kurtosis + artifact share -> noisy).
- `Recording/`: `SessionEngine` actor (routes streams, writes CSV first, computes metrics, publishes 1 Hz snapshots), `CSVSessionWriter`, `RowFormatter`, `LiveBuffer` (ECG ring buffer the UI reads).
- `Storage/`: `AppPaths` (CSVs in Documents, everything else in Application Support), `SessionIndexStore` + `IndexRebuilder`, `ActiveRecordingStore` (resume marker), `StorageMonitor`.
- `Time/`: `NTPClient` (SNTP over UDP, offset = server minus phone; replies must echo our transmit time, mode 4, stratum 1-15).
- `State/`: `@Observable` objects via environment: `Roster`, `SessionLibrary`, `AppSettings`, `DeviceProviders`, `RecordingController` (setup -> recording -> saving), `BluetoothMonitor`, `Notifier`, `LiveActivityController`.
- `UI/`, `Features/Record|Recordings|Settings/`: screens. `UI/Palette.swift` holds participant colours (split from `Theme.swift` so `Roster` compiles on the Mac).
- `ECGRecorderTests/`: unit and end-to-end tests.

Repo root
- `Shared/` and `ECGRecorderWidgets/`: Live Activity (attributes shared by app and widget extension).
- `Package.swift`: Mac-only test package over the Foundation-only files.
- `tools/`: `test.sh` (test runner), `unpack_ecg.py` (schema-2 CSV -> one row per ECG sample), `signal_quality.py` (artifacts and ECG kurtosis of a CSV, same algorithms as the app), `make_bell.py`, `feedback-bot/` (Telegram -> Google Sheet Apps Script, setup in its README).
- `media/`: source files for bundled media. `app-icon-1024.png` is the real file; `ECGRecorder/Assets.xcassets/AppIcon.appiconset/icon-1024.png` is a symlink to it. `bell.wav` (the default auto-stop chime) is a target source in `project.yml` (`path: media/bell.wav`); `EndSound` loads it from `Bundle.main`. Regenerate it with `tools/make_bell.py` (three strikes at C6, normalized loud; a low fundamental is inaudible on a phone speaker).
- `screenshots/`: captured by hand, not generated by tests. Update after a UI change worth showing.
- `FEATURE_REQUESTS.md` (the user adds requests; finished ones move to Done), `OPEN_QUESTIONS.md` (decisions to make together).

## Architecture

- Swift + SwiftUI, Swift concurrency (actors), Swift Charts. Intended feature packages: Devices, Recording, Metrics, Storage, UI (not split yet).
- Data path: sensor -> engine -> CSV (then metrics, index samples). The engine writes one ECG row per BLE packet. The UI only reads snapshots and `LiveBuffer`; the recorder and UI never share a path.
- One writer actor per session, buffered appends flushed about once per second, never holding a session in memory.
- Polar BLE SDK wrapped behind a protocol so it can be simulated. Intended: Core Bluetooth state restoration, Bluetooth central background mode, file protection "until first user authentication".
- Local index (JSON today; SwiftData or SQLite possible) of HR/RMSSD traces, rebuildable from the CSVs. The timeline reads from it, not from the CSVs. Changing a calculation: bump `SessionIndexStore.version`; the index is then dropped and rebuilt from the CSVs at launch.
- After a resume, stop rebuilds the saved entry from the whole CSV (the engine only saw the tail). Resume also cuts a torn last row (`CSVSessionWriter.dropTornRow`).
- Simulated H10 devices replay recorded data, for testing without hardware.

### Metrics and analysis

- Metrics are a plug-in pipeline over the H10's own RR intervals (no home-made R-peak detection). Implausible RR intervals are flagged, never dropped. RMSSD window default 60 s; it is stored in the `session_info` row (RMSSD itself is not written to the CSV).
- `RecordingAnalysis` (`Metrics.swift`) is the one place saved numbers come from. The engine and `IndexRebuilder` feed it identical input (rounded RR, device flags, row times, HR, gap events) and it computes only at the end (`finish()`), over the whole recording, because artifact detection needs the beats after each interval. `testSavedIndexEqualsIndexRebuiltFromTheFile` enforces that the saved index equals a rebuild.
- The engine keeps `live` (`LiveAnalyzer`, for the UI, from connection) and `recorded` (`RecordingAnalysis`, from file start). `LiveAnalyzer` runs the same detector over a trailing buffer; the newest 2 beats wait before they count.
- Artifacts: `ArtifactDetector` implements Lipponen & Tarvainen 2019 (Kubios' automatic method): adaptive thresholds from the quartile deviation of successive differences over 91 beats; labels ectopic (both intervals around the beat), missed, extra (both halves), long_short; runs are cut at gaps and device-flagged beats; threshold floor 10 ms. It replaced the "20% from the median of 5" rule on 2026-09-29, which flagged 11% of normal breathing-driven beats in a real high-HRV recording (now 1.4%). `tools/signal_quality.py` is the same algorithm in Python (checked to give identical flags and kurtosis).
- Artifact labels are NOT written to the CSV (only `no_contact` / `implausible_rr` are). They appear as counts in `session_stop`, and the rebuilder ignores old files' `ectopic` flags.
- Rules: RMSSD/pNN50 only over adjacent NN pairs (a flagged beat or gap breaks the pair). The window is in beat time including flagged beats, and resets on `disconnect`/`no_data` EVENT, `session_resume`, and more than 5 s between RR arrivals. Nothing is reported until min(30 s, window/2) of NN. Whole-recording totals are in `NNSummary` (mean HR = 60000 / mean NN, RMSSD over all adjacent pairs, nil under 30 s). Index traces are sampled at RR arrivals every 5 s.

## Product principles (from the spec)

- The participant is the central concept, not the device. Say "pseudonym" only in the create form, "participant" everywhere else. Pseudonyms are permanent; no other participant metadata.
- Devices are saved like phonebook entries and are not tied to a participant. Any device can pair with any participant per session.
- Recording starts only on Start and stops only on Stop. The live screen never scrolls.
- Deletion is whole-session only. Removing a participant keeps their past sessions.
- Fully offline. The only network use allowed is an optional, non-blocking NTP clock-offset query.

## Record flow

- One Record screen for setup and recording (no Preview). Each participant card: colour dot + participant menu, a tiny live ECG in the middle (flat when not streaming), device menu, and a status line. Problems (from `ConnectionAdvisor`) replace the status with a diagnosis and a hint. Tapping the mini ECG opens `PreviewSheet` (a `.full` `LiveTile`, nothing recorded).
- "Add participant" adds cards (max 6). Remove a card by swiping it or via the participant menu (not the last one). Devices are named "H10 1234"; simulated ones "simulated1".. (`Format.device`).
- Participant colours: `Participant.colorIndex` into `Palette.participants`; `Roster.color(for:)` is used by cards, tiles, chart lines and lists.
- Devices auto-connect while idle: `syncEngine()` rebuilds the idle `SessionEngine` only when devices, provider or engine settings change. No saved devices: the scan sheet opens automatically.
- The big button is `RecordReadiness`: "Record", "Record with n of m" (devices still connecting keep trying and log EVENT rows), "Connecting…", or the blocking reason ("Bluetooth is off", "Choose a device"). It becomes Stop; Stop confirms in an alert, always saves, then shows "Recording saved".
- Empty name defaults to "MoRe29/09" (day/month) for the day's first recording, then Tue01, Tue02, ... (`Format.defaultTag`; the file name gets "MoRe29-09").
- Live tiles: 1 participant = hero (ECG 150 pt tall, 6 s wide), 2-3 = stacked, 4-6 = 2-column grid with mini ECG + HR + RMSSD.
- Error prevention: `BluetoothMonitor` (state only, never scans) feeds `RecordingController.phoneProblem`; banner with Settings button. `ConnectionAdvisor` (pure, tested): no signal after 8 s, unreachable after 12 s, noisy signal for 5 s ("Moisten the electrodes and tighten the strap"; card status line and live tile header), low battery <= 10%. Noisy = ECG kurtosis over the last 10 s below 5, or over 20% of the last 30 intervals flagged (engine `tick`, `LiveSnapshot.noisy`, `Slot.noisySince`). Thresholds are first estimates; calibrate with `tools/signal_quality.py` on recordings made with a dry or loose strap.
- "Stop after" (auto-stop, default 6:00, preset dropdown up to 60 min) and "Skip first" (delays the actual CSV write, default 20 s, preset dropdown up to 120 s) sit below the name field, each its own row (label, dropdown, toggle) in `SetupContent`. Both are `RecordingController` properties, not persisted.
  - Skip-first keeps the UI in `.setup` (sensors streaming, nothing written) until the delay elapses, then flips to `.recording`; the button shows a live "Starting in Ns" countdown meanwhile.
  - Auto-stop schedules a `Task` from the actual recording start (after any skip), shown as "· m:ss left" next to the live clock. Firing it plays `EndSound.play(settings.endSound)` and `Haptics.autoStopped()` (three `kSystemSoundID_Vibrate` buzzes; gated on the Sound/Haptic alert channels) before calling `stop()`.
- "Predicted RMSSD" row (1-300 ms on a wheel popover, toggle; one participant only, `canPredict`), not persisted. Written as `predicted_rmssd_ms` in `session_info`, stored in `Session.predictedRMSSD`, shown next to the recorded whole-recording RMSSD in the saved alert as plain numbers, no verdict (`Format.predictionSummary`). It never enters any calculation.
- Event markers: while recording, `MarkerBar` (above Stop) shows the next event name ("event01", "event02", ...; tap the name to rename the next one) and a Mark button. The time is taken at the tap (`RecordingController.mark`), written as a session-level MARKER row, kept in `Session.markers` (rebuilt from the file), drawn as dashed lines on the recording's charts and listed under them.
- Live Activity: times are in `ContentState` (`startsAt` / `startedAt` / `autoStopAt`). It is requested at Record tap (iOS refuses requests from the background, e.g. when the phone locks during Skip first) and updated when recording starts. `stop()` ends it immediately; `end()` ends every activity of the app, and launch clears leftovers.

## Recordings and Settings

- Tab "Recordings" = Recordings | Participants switch. Rows: name, date, duration (seconds under a minute), participant dots. Detail: HR then RMSSD stacked (`MetricStack`, "Add graph" for more), x-axis in elapsed time, one coloured line per participant. Participants: same stack on a continuous zoomable time axis. Multi-select with Share and Delete.
- Charts: `MetricChart` (shared by session detail and participant timeline) supports tap-to-inspect. A `SpatialTapGesture` on a `chartOverlay` finds the nearest point in screen space (not just nearest x), shown via a `RuleMark` + `.annotation(overflowResolution: .fit(to: .chart))` so it never overflows the chart edges. Tapping the same point again, or the metric/domain changing, clears it. It coexists with the timeline's pinch-zoom/scroll since a tap claims no drag.
- Settings holds roster management, Recording (RMSSD window; the accelerometer is not collected (`StreamConfig.accEnabled = false`) and has no settings), Notifications, HR zones, Developer.
- Settings > Notifications (`NotificationSettings`): timer end sound (`EndSound`: bundled Bell, the iOS alert tones readable in /System/Library/Audio/UISounds (ringtones are not), or None; copied to Library/Sounds for lock-screen notifications), per-event toggles (`AlertEvent`, stored as `AppSettings.mutedEvents`; write failures and a resumed recording are always announced), and the channels (sound, haptic, on-screen, lock screen). `AppSettings.Stored` decodes every key optionally so older saved settings survive new keys.

## CSV format (schema 2)

- One long-format CSV per session, all participants. Name: `ECGRecorder_YYYYMMDD_HHMMSS[_tag].csv`. Files from before the rename from ECG Collector keep the `ECGCollector_` prefix and still show up in Recordings (`SessionLibrary` recognizes both).
- ECG is packed one row per Bluetooth packet (about 73 samples, about 5 bytes per sample; about 175 in schema 1). `tools/unpack_ecg.py` expands it to one row per sample. Flagged RR rows stay in the file.
- Columns (`CSVFormat.columns`): participant, device_id, stream, unix_time_s (3 decimals), sensor_time_ns, value, flag, note.
- Streams and `value`:
  - ECG: uV separated by spaces, 130 Hz. `sensor_time_ns` = first sample, `note` = last sample, spacing even in between; `unix_time_s` = first sample.
  - HR: bpm.
  - RR: ms at 0.1 ms, from the H10's 1/1024 s count. `flag` = `implausible_rr` / `no_contact`. Files from before 2026-09-29 may also say `ectopic`, which is ignored and recomputed.
  - CONTACT: 0/1, written only on change.
  - EVENT: `note` = disconnect / reconnect / no_data.
  - SYNC: `value` = NTP offset s, `note` = session_start / session_stop / session_resume / ntp label.
  - MARKER: session-level, no participant; `note` = event name, `unix_time_s` = moment of the tap.
- `session_stop` carries, per participant, `;mean_hr_bpm=..;rmssd_ms=..;rr_count=..;rr_flagged=..` then one `;rr_<flag>=n` per flag that occurred (e.g. `rr_ectopic=2;rr_no_contact=5`).
- Session constants are in one SYNC row, note `session_info;schema=2;id=...;rmssd_window_s=..;unix_s=..;mono_s=..;[predicted_rmssd_ms=..;]tag=...` (tag last; keys are only parsed before it).
- ECG `unix_time_s` = packet arrival minus packet span (includes Bluetooth latency, raw on purpose). `tools/unpack_ecg.py --sync` adds a clock-corrected time from the sensor clock (lower envelope of arrival minus sensor time, per 30 s; jitter about 40 ms SD down to under 1 ms on synthetic data).
- Not recorded: RMSSD (recompute from RR), HR zone, battery, accelerometer. `IndexRebuilder` still reads schema 1 files (header decides).

## Gotchas

- Polar SDK is pinned to exactly 8.3.0 (large repo, first resolve is slow). Heart rate still uses the deprecated `deviceHrObserver` (works; migrate to `startHrStreaming` on SDK upgrade). ECG/ACC streams retry every 2 s; errors log to Console (subsystem `com.example.ecgrecorder`, category `polar`).
- SwiftUI: a `Canvas` inside `TimelineView` must read `ctx.date` inside its closure or it won't redraw (live ECG). Keep view bodies small; large modifier chains hit "unable to type-check in reasonable time" (split into computed properties). Don't use `EditButton` in a toolbar for list selection; use your own button with explicit `editMode`.
- History: the app was renamed from ECG Collector to ECG Recorder (folder, target, module and bundle ID all moved to `ECGRecorder`/`ecgrecorder`). `AppPaths.support` moves an old install's Application Support folder to the new name on first launch so the roster and index survive.

## Open items

Tracked in `OPEN_QUESTIONS.md`. Deferred: more HRV metrics (SDNN, pNN50) as live metrics, GPS/phone sensors, iPad layout, Lab Streaming Layer, participant metadata, TestFlight.
