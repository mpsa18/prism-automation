# PAMAS S40 — Prism WASM device driver

Version: 0.1.0  
Plugin ABI: `prism:device@0.1`  
Prism: 0.1.1 or newer  
Artifact: `device_plugin_pamas.wasm` (wasm32-wasip2, one file for Windows,
Linux and macOS, x86_64 and ARM)

Reads new measurements from a PAMAS S40 particle counter over a serial port.
The plugin polls the number of records in the instrument memory (`MPN`), and
only when the memory changes it downloads the new data, averages the last
measurement block and publishes the counters, the GOST 17216 purity class and
the measurement time as ordinary Prism tags.

## Package contents

```
plugins/pamas_s40/device_plugin_pamas.wasm
config/03_wasm/01_source/pamas_s40/01_device.toml
config/03_wasm/01_source/pamas_s40/02_channels.toml
README.md
SHA256SUMS
```

## Install

1. Copy `plugins/pamas_s40/` to `<instance>/plugins/pamas_s40/`.
2. Copy `config/03_wasm/01_source/pamas_s40/` to
   `<instance>/config/03_wasm/01_source/pamas_s40/` (or merge the files into
   an existing source module; the folder name becomes the device name).
3. Set `[device.serial].serial_port` in `01_device.toml`; on Linux/macOS use
   `/dev/ttyUSB0` or a stable `/dev/serial/by-id/...` path.
4. Optionally set `tz_offset_min` and the memory-clear options in
   `[device.wasm].options`.
5. Validate and start:

```sh
prism --check-config
prism-dbg                     # tags appear after the first new measurement
```

The plugin path in `[device.wasm].module` is relative to the `config/`
directory; `../plugins/pamas_s40/...` resolves to the instance root.

## Configuration

`01_device.toml`:

| Key | Default | Meaning |
|---|---|---|
| `poll_interval_ms` | `2000` | How often the plugin asks for the record count |
| `timeout_ms` | `10000` | Device timeout |
| `[device.serial].serial_port` | — | Port opened by the core (`COM3`, `/dev/ttyUSB0`, ...) |
| `[device.serial].baud_rate` | `9600` | Instrument baud rate |
| `[device.serial].parity` | `"none"` | `none`, `"even"`, `"odd"` |
| `[device.wasm].options` | `{}` | JSON options below |

`[device.wasm].options`:

| Key | Default | Meaning |
|---|---|---|
| `tz_offset_min` | `0` | Offset of the instrument clock from UTC, minutes (e.g. `180` for UTC+3). Added to the published `timestamp` |
| `clear_after_download` | `false` | Delete the instrument memory after every successful download |
| `clear_when_records_above` | absent | Delete the memory when the current download contains at least N records |

Both clear options send the vendor “Delete data in memory” command. They are
off by default: they erase data on the instrument and cannot be undone.

## Tags (what to read in SCADA / scripts)

All tags are read-only. The device name in the example is `pamas_s40`; full
tag ids are `pamas_s40.<name>`.

| Tag | Type | Unit | Meaning |
|---|---|---|---|
| `2um` | dword | pcs | Particles > 2.00 µm |
| `3um` | dword | pcs | Particles > 3.00 µm |
| `4um` | dword | pcs | Particles > 4.00 µm |
| `5um` | dword | pcs | Particles > 5.00 µm |
| `6um` | dword | pcs | Particles > 6.00 µm |
| `7um` | dword | pcs | Particles > 7.00 µm |
| `8um` | dword | pcs | Particles > 8.00 µm |
| `10um` | dword | pcs | Particles > 10.00 µm |
| `15um` | dword | pcs | Particles > 15.00 µm |
| `20um` | dword | pcs | Particles > 20.00 µm |
| `25um` | dword | pcs | Particles > 25.00 µm |
| `30um` | dword | pcs | Particles > 30.00 µm |
| `50um` | dword | pcs | Particles > 50.00 µm |
| `100um` | dword | pcs | Particles > 100.00 µm |
| `150um` | dword | pcs | Particles > 150.00 µm |
| `200um` | dword | pcs | Particles > 200.00 µm |
| `class` | int | — | GOST 17216 purity class: `0..17`, `18` means `>17` |
| `timestamp` | dword | s | Unix time of the last run (instrument clock + `tz_offset_min`) |

Values are the arithmetic mean of the last measurement block (the instrument
usually makes three runs per sample). The block size is taken from the
`Block N Number of Measurements K` header; the last three rows are a fallback
when the header is absent.

`class` is computed from the averaged counters and the sample volume from the
`MeasVolume` header (GOST 17216-2001). If the vendor line already contains a
class (`-> 11`) it is used as-is. If there is no volume or the class is
undefined, the tag is skipped with a warning and the counters are still
published.

## Integration

- **No control tags in this version.** ABI `prism:device@0.1` has no write
  channel: the plugin only reads. There is no “start measurement”, “stop” or
  “delete memory” tag; memory clearing is configured in
  `[device.wasm].options` and happens automatically after a download.
- Tags are normal Prism device tags: add them to MQTT telemetry, the OPC UA
  server, alarms and history exactly like Modbus/S7 tags. Use
  `pamas_s40.2um`, `pamas_s40.class`, `pamas_s40.timestamp` in rules and
  `mirror_to`.
- `access = "ro"` rejects writes. A write to an `rw` tag would be applied
  host-side and overwritten by the next measurement; these tags are declared
  `ro` deliberately.
- Empty instrument memory is an honest “no data” state: the tags stay `Bad`
  until the first new measurement, they are not zeroed.
- The port is exclusive: PAMAS Software and Prism cannot use the same serial
  port at the same time.

## Behaviour details

- On start the plugin only remembers the current record count. It never opens
  a download session on its own, so the instrument does not show its
  “download results” prompt in idle.
- A download starts only when the record count changes; identical counts and
  a cleared memory produce no traffic.
- If the instrument is silent for a long time (for example, during a
  measurement or after USB sleep), the host reconnects the port and calls
  `configure` again.
- `timestamp` is Unix seconds from the instrument clock. The instrument clock
  is read as UTC plus `tz_offset_min`.

## Safety

- `clear_after_download` and `clear_when_records_above` erase the instrument
  memory. Keep them off until you have a backup of the measurement data.
- Do not run PAMAS Software against the same port while Prism is running.
- The plugin does not change calibration or the sensor file.

## Troubleshooting

| Symptom | Check |
|---|---|
| `artifact not found` | `[device.wasm].module` path relative to `config/` |
| `plugin ABI mismatch` | Plugin ABI is `0.1`; use Prism 0.1.1+ |
| Device stays offline / `cannot open serial port` | Port busy or wrong name; `prism serial list` |
| Tags show “no data” | Memory is empty or no new measurement has arrived yet |
| Reconnects cyclically | The port is open but the instrument does not answer `MPN` |
| No `class` tag | The download had no `MeasVolume` or the class is undefined; see the log |
| Log shows `no block header` | The instrument firmware does not send the block header; the plugin falls back to the last three rows |

## Checksums

See `SHA256SUMS` in the package root. Verify with
`sha256sum -c SHA256SUMS` (Linux/macOS) or `Get-FileHash` (Windows).
