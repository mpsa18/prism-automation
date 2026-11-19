# WASM device drivers (device plugins)

Date: 2026-10-08
Status: implemented (ABI `prism:device@0.1`).
Related documents: [`05_wasm/01_PLUGIN_SDK.md`](01_PLUGIN_SDK.md) (compute
modules), [`02_communication/01_DEVICES.md`](../02_communication/01_DEVICES.md)
(transports and `[device.serial]`), and
[`03_tooling/01_BENCH_TOOLS.md`](../03_tooling/01_BENCH_TOOLS.md) (testing without hardware).

A device plugin is the half of WASM extensions that **owns devices and their
tags** and lives in `config/03_wasm/01_source/<module>/`.
The other half is compute modules (`config/03_wasm/02_compute/`,
[`05_wasm/01_PLUGIN_SDK.md`](01_PLUGIN_SDK.md)): they do not declare their own
tags and work with already existing ones. The criterion is simple: if a module
declares devices and tags, it is `source`; if it only reads and writes tags
owned by others, it is `compute`.

## 1. Why

Low-level instruments with a text protocol on a COM port (particle counters,
vacuum pumps, analyzers) are not described by the built-in
transports: they have their own dialog, checksums and line parsing. Such a
driver is implemented as a **device plugin** — a WASM component to which the
host **itself** gives a ready channel to the port:

```
config/[device.serial] ──► core opens the port ──► host imports (bytes)
                                                        │
                              device-plugin (WASM): protocol, parser
                                                        │
                       poll() -> tag updates ──► core: validation,
                       registry / MQTT / OPC UA / alarms / license
```

Key boundaries:

* port, baud/parity, reconnect, offline semantics and watchdog — in the core;
* protocol and line parsing — in the plugin;
* the plugin cannot choose another port, open a file or a socket: imports
  work only with a channel already opened by the host (the same sandbox as
  compute: no FS and no network).

**No black boxes.** The plugin returns updates only for its own tags — those
declared for its device in the module config — and cannot read or create a
foreign tag. If a module needs both its own tags and existing ones, that is a
`source` + `compute` composition
([`05_wasm/01_PLUGIN_SDK.md`](01_PLUGIN_SDK.md)), not a single artifact with a
dual role.

The `source`/`compute` criterion is **who owns the tag**, not "whether there is
math inside": calibration, filtering, aggregation and any other processing of
one's own data are a normal part of a device plugin. How the dialog with the
device is arranged and which host imports are involved is decided by the
module author.

## 2. The `prism:device@0.1` contract

WIT: `crates/device-wit/wit/device.wit`; host runtime —
`crates/device-host`; Rust SDK — `crates/device-sdk`.
One WASM instance serves **one** device: a module may declare
several devices, but for each of them the host creates its own plugin
instance.

Exports (implemented by the plugin):

| Function | Meaning |
|---|---|
| `get-info() -> plugin-info` | identity: name, version, `abi = "0.1"` (exact match) |
| `configure(config: string)` | config `[device.wasm].options` (usually JSON; `"{}"` if not set) |
| `poll() -> list<tag-update>` | one driver cycle; an empty list means "no new data", an error means reconnection |

Tag update: `{ tag, value, text?, timestamp-ms?, quality }`, where `tag` is a
short name without the device name. Values are validated by the host (tag type,
finite, limits) and published along the regular device path (`Sample` →
registry, MQTT, OPC UA, alarms, `mirror_to`).

Host imports (the only ones): `log`, `now-ms`, `sleep-ms` (clamped),
`serial-write`, `serial-read-until(delim, timeout)` (timeout — `Ok(None)`,
line error — `Err`), `serial-available`, `serial-clear-input`.

## 3. Quick start (Rust SDK)

The plugin crate has this shape:

```toml
[lib]
crate-type = ["cdylib", "rlib"]   # rlib — so pure logic can be tested natively

[dependencies]
device-sdk = { path = "../device-sdk" }
```

```rust
#[derive(Default)]
struct Reader;

impl device_sdk::DevicePlugin for Reader {
    fn configure(&mut self, _config: &str) -> Result<(), String> { Ok(()) }

    fn poll(&mut self) -> Result<Vec<device_sdk::TagUpdate>, String> {
        device_sdk::serial_write(b"MPN\r")?;
        match device_sdk::serial_read_until(b'\r', 2000)? {
            Some(bytes) => { /* parsing ... */ }
            None => return Ok(vec![]),          // the instrument is silent — not a line error
        }
        Ok(vec![device_sdk::tag_value("count", 42.0)])
    }
}

device_sdk::export_plugin!(Reader);
```

Build and install:

```sh
cargo build -p my-device-plugin --target wasm32-wasip2 --release
# vendor deployment: plugins/counter/device_plugin_counter.wasm next to config/
```

Move the algorithm (parser, checksums) into a separate module without WASM
dependencies — like a separate `protocol` module — and cover
it with native tests; an end-to-end run through the real host follows the
pattern of an end-to-end host test (mock link instead of a port).

## 4. Device configuration

Module layout: the directory `config/03_wasm/01_source/<module>/`, inside — files
by meaning (for example `01_device.toml` with the device and its transport and
`02_channels.toml` with tags; file names are free-form, read in order).
Tags do not exist apart from a device: they are written as `device.tag` and, if
there are several devices in the module, `[[device]]` with the name of the
required device is repeated before the tags. The default device name is the
module directory name.

```toml
# config/03_wasm/01_source/counter/01_device.toml
[[device]]
name = "counter"
protocol = "wasm"
poll_interval_ms = 2000
timeout_ms = 10000

[device.reconnect]
count = "infinite"
strategy = "hold_infinite"
backoff = "none"

[device.serial]              # the port is opened by the core (as with Modbus RTU)
serial_port = "COM3"
baud_rate = 9600

[device.wasm]
module = "../plugins/counter/device_plugin_counter.wasm"   # relative to the config/ directory
# options = '{"…"}'          # arbitrary JSON for configure()
# max_memory_mb = 64
# fuel_per_call = 500000000
```

```toml
# config/03_wasm/01_source/counter/02_channels.toml — tags of the same device
[[device.tag]]
name = "count"
data_type = "dword"
access = "ro"
```

Source modules are not mixed with virtual tags: each kind has its own folder
(`source/` and `01_southbound/04_virtual_tags/`), and protocol attributes are not
overwritten by the loader.

A module folder may also contain a defaults file — `defaults.toml` or a
numbered alias like `00_defaults.toml` — with the usual `[defaults.tag]` /
`[defaults.tag.fail]` sections
([`02_communication/01_DEVICES.md`](../02_communication/01_DEVICES.md) §1.4).
The optional `devices` selector
narrows the block to the named devices (`devices = "counter"` or a list);
without it the defaults apply to every device of the folder. Example:
`[defaults.tag] initial_value = nan` marks every writable tag as "no data"
when the instrument comes online, without repeating the field on each tag (a
physical preset of NaN is skipped; `0.0` or any number works too).

## 5. Behavior in the core

* The plugin runs on a **dedicated worker thread** per device
  (`device-host` is synchronous, the port is blocking); the core polling loop
  communicates with it through channels and does not block tokio.
* Polling loop (like built-in drivers): `connect` → periodic `read`
  every `poll_interval_ms` → `disconnect` on error → reconnect per
  `[device.reconnect]` with complete re-creation of the instance (repeated
  `configure`). The port is resolved on every connection (USB matching survives
  COM name reassignment).
* The plugin sends updates only when there is new data; tags that received no
  update keep their last value (`Sample` for each tag of the cycle).
  Before the first value, tags are `Bad` ("no data") — the honest status of an
  empty instrument memory.
* Writes: the ABI has no write channel, so writes are never forwarded to the
  plugin. Tags marked `rw`/`wo` are applied **host-side** (store + registry +
  MQTT) like virtual scratch pads — handy to initialize/reset values between
  measurements — and the plugin overwrites them with fresh data on its next
  poll. `ro` tags reject writes (`tag is read-only`).
* Debug surfaces: tags of a `wasm` device carry the role `wasm` (the protocol
  name, not a register area like `holding`), so the debugger shows the same
  role in the configuration catalog and from the live debug API. Host-side
  `rw`/`wo` writes above are keyed on that role.
* License: device modules are not gated — they work in the free version too;
  device tags count toward the overall tag count
  ([`06_operations/01_LICENSING.md`](../06_operations/01_LICENSING.md)).

## 6. Reference: a text-protocol particle counter

The dialog follows the instrument's serial protocol:

1. `MPN` (without checksum) → the number of records in memory;
2. the first count after startup is only remembered as a baseline: the plugin
   never opens a download session on its own at program start, so the
   instrument does not show its "download results" prompt;
3. if the count grew — `DL M<0253>` → handshake `!` → `!<0033>`;
4. measurement lines are accepted with an acknowledgment `!` up to the line `!mea`;
5. the **last three records** (the runs of one sample) are averaged per channel
   and written to the tags (GOST 17216 class and time too);
6. with `{"clear_after_download": true}` in `[device.wasm].options` the records
   are then deleted from the instrument: `ME<0146>` (the vendor "Delete data in
   memory" command), the `!<0033>` answer is mirrored as in the handshake, so
   the memory keeps only the fresh sample and grows from zero.

Measurement line (wire format, from a real test-bench trace):

```
07/23/2026	09:27:15	55427	29691	…	0
   date        time   16 counters >2.00…>200.00 µm
```

The instrument does not send the class over the line; the `-> 11` column in the
vendor `Result.txt` is appended by the vendor software. The plugin reads the
block header `MeasVolume: 10.0` (sample volume, ml) and computes the class
itself from the averaged counters and that volume, exactly like the vendor
software (table 1 of GOST 17216-2001): for each size
band (2,5], (5,10], (10,25], (25,50], (50,100], (100,200] µm the
differential counter is scaled to 100 ml, the first table row whose limit is
not exceeded is looked up, and the maximum over the bands becomes the class.

Parsing is tolerant of separators (tabs/spaces) and of the trailing checksum
`<dddd>`; header and device messages are discarded. The instrument does three
runs per sample and groups them under `Block N Number of Measurements 3`
(the header is only logged for diagnostics). The plugin averages the last
three records per channel (rounded to the nearest integer; the timestamp is
the last run). Tags: 16 channels `2um…200um` (per-channel mean of the runs),
`class` (integer: 0…17 =
GOST class, "00" is stored as 0, 18 = ">17" beyond the scale), `timestamp`
(unix seconds by the instrument clock — the clock is read as UTC plus the
optional `tz_offset_min` from `[device.wasm].options`).

## 7. Errors, limits, debugging

| Symptom | Cause / action |
|---|---|
| `artifact not found` | wrong `wasm.module` (path relative to the `config/` directory) |
| `plugin ABI mismatch` | `get-info().abi` is not equal to `"0.1"` (exact match) |
| `configure failed: …` | error in your `configure` |
| `no connection: cannot open serial port …` | port busy/not found; check `prism serial list` |
| the device reconnects cyclically | `poll()` returned a line error; device timeouts (`Ok(None)`) should not be treated as an error |
| `poll failed: …` in the log | plugin error; `[device_plugin]` — logs from `host.log` |
| tags "no data" until the first measurement | empty instrument memory is a correct state |

Host limits: instance memory (`max_memory_mb`, default 64), fuel per call
(`fuel_per_call`), clamps for `sleep-ms` (60 s) and `serial-read-until` (120 s)
per call.

## 8. What's next (roadmap)

* signing of device module manifests and protection against artifact substitution;
* module hot-reload with staging and confirmation, as with compute: today a
  changed `.wasm` artifact restarts that device's poller immediately (only that
  device — [`04_logic/01_RHAI.md`](../04_logic/01_RHAI.md) §6) and there is no
  staging window yet;
* TCP link (`link.kind = "tcp"`) for instruments with an Ethernet gateway;
* choosing the writability policy for measurement channels: keep `rw`
  (host-side reset writes; OPC/MQTT nodes stay writable) or switch to `ro`
  together with regenerating the OPC/MQTT exports
  (`config/02_northbound/02_opc_server/nodes.d/counter.toml` is `writable = true`
  today).
