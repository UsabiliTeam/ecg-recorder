# Building ECG Recorder and running it on your iPhone

For humans and LLM coding agents. Works the same whether you got the code from GitHub or as a zip. Follow the steps in order. If you are an LLM: run the commands yourself, and ask the human only for the steps marked **HUMAN**.

## What this is
An iOS app (iOS 17+, iPhone only, portrait) that records up to 6 Polar H10 heart-rate straps at once, shows live HR/RMSSD, and saves one CSV per session. The project is Swift/SwiftUI. The one dependency, the Polar BLE SDK 8.3.0, is downloaded automatically by Swift Package Manager.

## Requirements
- A Mac with **Xcode 16 or newer** (iOS 17 SDK), opened at least once so the license and components are installed.
- **XcodeGen**: `brew install xcodegen` (Homebrew: https://brew.sh).
- An **Apple ID** (a free account works). Add it in Xcode > Settings > Accounts. **HUMAN**
- An iPhone 13 or newer, iOS 17+, with a cable. For real data: Polar H10 straps. Bluetooth does not work in the Simulator, which uses simulated devices automatically.
- Internet on the first build (to fetch the Polar SDK; the first resolve is slow).

## Steps

1. **Get the code** and open a terminal in the folder containing `project.yml`.
   - From GitHub: `git clone https://github.com/UsabiliTeam/ecg-recorder.git && cd ecg-recorder`
   - From a zip: unzip it and `cd` into the folder.

2. **Make the bundle ID unique.** Apple rejects IDs that another developer already uses, and `com.example` is a placeholder. Pick a prefix, e.g. `com.yourname`, and run (keep the widget ID as the app ID plus `.widgets`):
   ```sh
   PREFIX=com.yourname
   sed -i '' "s/com\.example\.ecgrecorder/$PREFIX.ecgrecorder/g" project.yml
   sed -i '' "s/bundleIdPrefix: com.example/bundleIdPrefix: $PREFIX/" project.yml
   ```
   Also replace the placeholder in code that uses it for logging/identifiers: `grep -rn "com.example" ECGRecorder Shared ECGRecorderWidgets ECGRecorderTests` and apply the same replacement (`sed -i '' "s/com\.example/$PREFIX/g" <files>`).

3. **Set your signing team** in `project.yml`: add `DEVELOPMENT_TEAM: <YourTeamID>` under `settings: base:` of the `ECGRecorder` and `ECGRecorderWidgets` targets. Find the Team ID in Xcode > Settings > Accounts > your team (a 10-character code). Or skip this and choose the team in Xcode in step 5.

4. **Generate the Xcode project** (it is not in the repo or zip, it is derived from `project.yml`):
   ```sh
   xcodegen generate
   ```
   Re-run this whenever source files are added or removed.

5. **Open and sign.** **HUMAN**
   ```sh
   open ECGRecorder.xcodeproj
   ```
   Wait for "Resolving Package Dependencies" to finish (downloads Polar BLE SDK 8.3.0). For **both** targets, `ECGRecorder` and `ECGRecorderWidgets`, open Signing & Capabilities, tick "Automatically manage signing" and select your Team.

6. **Check that it compiles** (no phone needed):
   ```sh
   xcodebuild -project ECGRecorder.xcodeproj -scheme ECGRecorder \
     -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
   ```
   Expected: `BUILD SUCCEEDED`.

7. **Run on the iPhone.** **HUMAN**
   - Connect the iPhone by cable, unlock it, tap "Trust This Computer".
   - Turn on Developer Mode: iPhone Settings > Privacy & Security > Developer Mode, then restart the phone.
   - In Xcode pick the iPhone as the run destination (top bar) and press Run (Cmd+R).
   - First launch: iPhone Settings > General > VPN & Device Management > your Apple ID > Trust.
   - Allow Bluetooth when the app asks.

   Command-line alternative once signing is set: `xcodebuild -project ECGRecorder.xcodeproj -scheme ECGRecorder -destination 'id=<device-udid>' -allowProvisioningUpdates build` (list devices with `xcrun xctrace list devices`), then install via Xcode.

8. **Optional: run the tests.**
   ```sh
   tools/test.sh          # logic tests on the Mac, about 12 s
   tools/test.sh --sim    # same tests in the iOS Simulator (needs an "iPhone 17" simulator; edit the name in tools/test.sh if yours differs)
   ```

## Good to know
- **Free Apple account**: the app expires after 7 days; rebuild and Run again to refresh it. Live Activities and the widget extension need the team selected on both targets. A free account allows only a few App IDs per week; a paid account ($99/year) removes the limits.
- **Simulator**: Run with an iPhone simulator as destination to try the app without straps. It uses simulated sensors.
- **On a real iPhone with no straps**: Settings > Testing > "Use simulated devices".
- **Recordings** are CSV files in the app's Documents folder, visible in the Files app (On My iPhone > ECG Recorder) and shareable from the Recordings tab. Columns: participant, device_id, stream, unix_time_s, sensor_time_ns, value, flag, note (ECG is packed one row per Bluetooth packet; `tools/unpack_ecg.py` expands it to one row per sample). Helper scripts: `tools/unpack_ecg.py`, `tools/signal_quality.py` (Python 3).

## Troubleshooting
| Problem | Fix |
|---|---|
| `xcodegen: command not found` | `brew install xcodegen` |
| "Failed to register bundle identifier" | Choose a different `PREFIX` in step 2, re-run `xcodegen generate` |
| "Signing requires a development team" | Select a Team on both targets (step 5) |
| Package resolution fails or hangs | Check internet; Xcode > File > Packages > Reset Package Caches, then Resolve Package Versions |
| "Developer Mode disabled" on iPhone | See step 7 |
| "Untrusted Developer" on launch | iPhone Settings > General > VPN & Device Management > Trust |
| Simulator name not found in tests | Run `xcrun simctl list devices available` and use an existing name |
| Build error after you edit files | `xcodegen generate` again if files were added or removed |

## Notes for the LLM
- Do not edit `ECGRecorder.xcodeproj` directly; edit `project.yml` and regenerate.
- Swift 5 language mode. Do not upgrade the Polar SDK (pinned to 8.3.0).
- Do not invent a Team ID or Apple ID; ask the human for it, or leave the team selection to them in Xcode.
- Stop and report to the human at steps 5 and 7; those need their Apple account and phone.
