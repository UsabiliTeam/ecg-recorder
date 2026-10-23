# Recording file format (schema 2)

Each recording is one CSV file with all participants in it. It is saved in the app's Documents folder (Files app > On My iPhone > ECG Recorder) and can be shared from the Recordings tab.

File name: `ECGRecorder_YYYYMMDD_HHMMSS[_tag].csv`, in the phone's local time. Older files may start with `ECGCollector_`.

## Long format

The file is "long": every row is one measurement from one stream, and the `stream` column says what it is. Filter on `stream` to get the signal you want (e.g. all `RR` rows for one participant).

| Column | Meaning |
|---|---|
| `participant` | Participant name. Empty for session-level rows (`MARKER`, session-wide `SYNC`). |
| `device_id` | Polar H10 id, e.g. `1496B436`. |
| `stream` | `ECG`, `HR`, `RR`, `CONTACT`, `EVENT`, `SYNC` or `MARKER`. |
| `unix_time_s` | Phone clock, Unix seconds, 3 decimals. |
| `sensor_time_ns` | The strap's own clock in nanoseconds (ECG only). |
| `value` | The measurement. Depends on the stream, see below. |
| `flag` | Quality flag, mostly for `RR`. Empty when fine. |
| `note` | Extra text. Depends on the stream. |

## Streams

| Stream | `value` | Notes |
|---|---|---|
| `ECG` | Samples in µV, separated by spaces. 130 Hz. | One row per Bluetooth packet (about 73 samples). `unix_time_s` and `sensor_time_ns` are for the **first** sample, `note` is the sensor time of the **last** sample. Samples are evenly spaced in between. |
| `HR` | Heart rate in bpm. | About once per second. |
| `RR` | Beat-to-beat interval in ms (0.1 ms resolution). | From the H10's own beat detection. `flag` is `implausible_rr` or `no_contact` when the interval is doubtful. Flagged rows are kept in the file, not dropped. |
| `CONTACT` | `1` skin contact, `0` no contact. | Written only when it changes. |
| `EVENT` | Empty. | `note` is `disconnect`, `reconnect` or `no_data`. |
| `SYNC` | Clock offset to an NTP server in seconds (phone clock vs. server, if reachable). | `note` is `session_start`, `session_stop`, `session_resume` or an NTP label. |
| `MARKER` | Empty. | Event button taps. `note` is the event name, `unix_time_s` is the moment of the tap. |

## Special rows

- **Session constants:** one `SYNC` row whose note looks like `session_info;schema=2;id=...;rmssd_window_s=60;unix_s=...;mono_s=...;[predicted_rmssd_ms=...;]tag=...`. The `tag` (the recording name) is last.
- **Summary:** the `session_stop` row carries per participant `;mean_hr_bpm=..;rmssd_ms=..;rr_count=..;rr_flagged=..`, then one `;rr_<flag>=n` for each flag that occurred.
- **Resumed recordings:** if the app was interrupted and the recording continued, a `session_resume` row marks the gap.

## Example

Simplified, with only a few ECG samples shown:

```csv
participant,device_id,stream,unix_time_s,sensor_time_ns,value,flag,note
,,SYNC,1792600833.120,,0.012,,session_info;schema=2;id=...;rmssd_window_s=60;...;tag=Tue01
Alice,1496B436,HR,1792600834.002,,72,,
Alice,1496B436,RR,1792600834.310,,832.0,,
Alice,1496B436,ECG,1792600834.100,845923231385422592,-74 -74 -67 -70 ...,,845923231945000000
,,MARKER,1792600840.500,,,,event01
```

## Things to know

- **Not stored:** RMSSD (compute it from `RR`), HR zones, battery level, accelerometer data. The summary row has the whole-recording mean HR and RMSSD.
- **ECG time includes Bluetooth latency.** `unix_time_s` is the packet's arrival time minus its duration, kept raw on purpose. `tools/unpack_ecg.py --sync` adds a clock-corrected time based on the strap's clock.
- **Artifacts** (ectopic, missed or extra beats) are detected by the app but not labelled in the CSV. Only `no_contact` and `implausible_rr` are written. Counts are in the `session_stop` row. `tools/signal_quality.py` runs the same detection on a file.
- **Spreadsheets:** free-text fields (participant names, tags, event names) have leading `= + - @` removed so Excel or Sheets never run them as formulas.

## Helper scripts

```sh
python3 tools/unpack_ecg.py recording.csv > ecg_samples.csv         # one row per ECG sample
python3 tools/unpack_ecg.py --sync recording.csv > ecg_samples.csv  # plus clock-corrected time
python3 tools/signal_quality.py recording.csv                       # artifacts and ECG quality
```
