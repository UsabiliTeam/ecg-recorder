# Feature Requests

Running list. Add new items under **Inbox**; triage later into Planned / Deferred.

Format: `- [ ] Short title: details (area: Record / Participants / Sessions / Timeline / Settings / Data / Other)`

## Inbox

## Planned
Types manually:
1. For feature request collection and bug reporting, let's create a telegram bot where users can communicate in simple chat format, and we connect it with a script in google sheet. Let me know what you need from me? Users might also send images in chat, is it possible to collect images on google sheet and which can be read by claude?
2. [Macro task] Let us work on accuracy of metrics.`
2a Are we measuring HRV from raw ECG voltage or from RR intervals received from Polar device? Can we compare both? 
2b How are we detecting and removing artifacts from the recordings? Is this the optimal way of detecting articfacts? 
2c Can we utilize accelerometer data to improve accuracy? Are there standard methods around this? Don't create something out of thin air. Build this only if there is standard research around this.
2d Is there a accurate way to detect if the polar chest strap worn is fit well or if it is loose? Incase it is not positioned correctly, can we identify it accuractely? or can we identify if the data is too noisy? If yes, let us build a system to identify this state and how can we subtly let the user know. 
3.eIn settings, create a section for notifications. From here user should be able to select the sound of bell at end of recording. User should be able to select from all the pre-loaded notification sounds available on iphone. User should also be able to enable and disable most notifications we give.
4. For predicted RMSSD, does it have any effect on actual calculation of RMSSD? Check the logic and code? It should not have any connection with anything else at all. Also, just show the recorded RMSSD and predicted RMSSD at end of recording, don't need to give any motivational messages on correct or incorrect predictions. 
5. Build a feature to record events during the recording. For eg. in an expirement, after the recording has started, user should be able to mark events which would be timestamped, like start and end of a activity, etc. This data should also be recorded on the csv output file. Give it default names like event01, event02, etc. with the option to change the name of each event. Ideally it should be a small rown on the live recording screen with <event name> <action button>.
6. The first recording of the day is unique. For that, the name should be MoRe<Date><Month>. For eg. MoRe29/09. After which follow the exisiting naming convention.
7. For a 5min ECG recording, The RMSSD graph always goes from very high values like 300-400 down to 100. And then the sessions average RMSSD is around 80-90. How is this possible? Is there a bug?
## Done

Research-grade review (2026-09-26):

- [x] RMSSD/pNN50 over adjacent NN pairs only; window resets on dropouts; no value from under 30 s of clean beats; whole-recording RMSSD and mean HR (60000 / mean NN) in O(1); saved index provably equals a rebuild from the CSV; index rebuilt when calculations change (Data)
- [x] RR at the H10's full 1/1024 s resolution; rebuild uses the recording's own RMSSD window; ECG stall watchdog; torn last row cut on resume; resumed recordings saved from the whole file; prediction survives a resume (Data)
- [x] CSV formula-injection and line-break protection for names; NTP replies validated; `unpack_ecg.py --sync` for clock-corrected ECG timing (Data / Other)

Feature request batch (2026-09-26):

- [x] Ectopic beats: an RR interval more than 20% away from the median of the last 5 is flagged `ectopic` (kept in the file, excluded from metrics); catches the premature beat and its compensatory pause; tests for detection, normal variability, real HR change, and the file (Data)
- [x] "Predicted RMSSD" row below "Skip first" (label, value 1-300 ms on a wheel, toggle); saved as `predicted_rmssd_ms` in `session_info`, shown in the Recordings row and compared with the actual average in "Recording saved"; offered only with one participant (Record)
- [x] Live Activity: shown the moment Record is tapped (with "Starting in" during Skip first), ended the moment Stop runs, left-over activities from a killed run cleared at launch, countdowns stop at 0:00 (Record)
- [x] End-of-timer alert: three real vibrations instead of a faint haptic tap; new bell (three strikes at C6, about 15 dB louder, pitched for the phone speaker), follows media volume and ducks music (Record)
- [x] Tap the small ECG on a setup card for a large live preview (ECG + HR + RMSSD), nothing recorded (Record)

Feature request batch (2026-09-22):

- [x] Auto-stop timer ("Stop after", default 6:00) and skip-warm-up ("Skip first", default 20 s) on Record, each a single row (label, preset dropdown, toggle) below the recording name; auto-stop plays a soft synthesized bell + short haptic once, then stops and saves (Record)
- [x] Tap a point on the HR/RMSSD graphs (session detail and participant timeline) for a time + value tooltip; touch-target is the whole chart, not the point itself (View)
- [x] App renamed ECG Collector -> ECG Recorder everywhere: folder, Xcode target/scheme, Swift module, bundle ID, docs; existing installs migrate their Application Support data and keep reading old-prefixed CSVs (Other)
- [x] App icon added (heart on a blue-to-navy gradient); source lives in `media/`, symlinked into the asset catalog (Other)

Feature request batch (2026-09-21):

- [x] Reliability tests: `ReliabilityTests` records scripted device events and checks the CSV (every ECG sample present, in order, constant sensor-time step; flagged RR kept but excluded; RMSSD against hand calculation; disconnect/reconnect events) plus a random-data check of the rolling window against a naive reference. Real-device gap checks still need hardware (Data)
- [x] Accelerometer removed from Settings: it was not used: collection is already switched off in code (`StreamConfig.accEnabled = false`), so no ACC rows are written (Settings)
- [x] Live timer top left, smaller, ":06" then "1:06" then "1:02:06"; red dot removed (Record)
- [x] Smaller live numbers; zone coloured green (1-2), yellow (3), red (4-5) (Record)
- [x] "Recording name" label; default name Sun01 style, count restarts each day (Record)
- [x] Recording detail: HR then RMSSD stacked, "Add graph" for SDNN; Participants: same, with SDNN and pNN50 addable (View)
- [x] Participant timeline: continuous time axis, opens fitted to the data, pinch to zoom, drag to move, Fit/Day/Week/Month buttons (View)
- [x] Haptics and alerts: haptic on start and on saved; permission requested at launch; foreground notification banners; "Send test alert" in Settings > Alerts shows when iOS has notifications off (Record / Settings)
- [x] Live Activity while recording: name, running timer, connected/total (green when complete, red otherwise); widget extension `ECGRecorderWidgets` (Record)
- [x] "Device" everywhere instead of "strap": UI, code, docs (Other)
- [x] Simulated devices named simulated1, simulated2, ... (Record / Settings)
- [x] Swipe-to-remove restored on the Record screen (list rows again; not offered for the last pair) (Record)
- [x] Recordings selection bar: own bottom bar with Share, full "n selected" count, Delete (View)

- [x] Design rethink (2026-09-21): Preview removed, live mini ECG per participant, Bluetooth and connection advice, participant colours, Record with n of m, View renamed Recordings, default names test1/test2, chart axis and duration fixes

Implemented in the front-end rebuild (2026-09-21). "Reduce to three tabs" resolved as: View tab = Sessions | Participants (timeline) switch; devices and tags moved to Settings > Roster.

- [x] Remove include toggle from setup rows: unneeded participants are removed by swiping the row horizontally and tapping a remove icon, same pattern as the Participants and Devices lists (Record)
- [x] Connect goes straight to the live stream screen: after Connect, show the live data page. Start recording is on that page and turns into Stop once recording begins (Record)
- [x] Stop confirmation as a screen-level popup: currently the dialog appears next to the button. Make it a separate screen-level popup (Record)
- [x] Stop always saves: no discard path. After stopping completes, show a confirmation that the recording is saved (Record)
- [x] Remove Participants/Timeline redundancy: tapping a participant in the Participants tab shows the same view as the Timeline tab. Keep one (Participants / Timeline)
- [x] Add participant from the Record tab: creating a participant is already possible there; make it a first-class action (Record / Participants)
- [x] Move participant deletion to Settings: deleting participants is rare, so it lives in Settings (Settings / Participants)
- [x] Session detail view: tapping a session shows graphs for all its participants, with a metric filter (RMSSD, SDNN, etc.) (View)
- [x] Rename Sessions tab to "View" (View)
- [x] Reduce to three tabs: Record, View, Settings. Participants and Timeline tabs go away, so their remaining functions (device management, per-participant timeline) need a new home. To be decided (Navigation)
- [x] Settings tab expansion: more to be specified later (Settings)
- [x] Rename "Tag (optional)" to "Meta": section label in session setup (Record)
- [x] Tag as primary in session list: show the tag as the main title of each row, and move date/time into subtle secondary text alongside participants and duration (View)

Later requests, implemented:

- [x] Always show a first participant/device pair (default P1, saved device; first run with no devices opens scan) and an "Add participant" row below the last pair (Record)
- [x] Status shown as a single dot between the dropdowns: red disconnected, yellow connecting/connected, green streaming (Record)
- [x] Auto-connect on app open; "Connect" renamed "Preview", Start records (Record)
- [x] Live ECG graph animates (Record)
- [x] Multi-select sessions to share or delete (View)
