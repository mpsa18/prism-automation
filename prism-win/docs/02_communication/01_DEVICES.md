# Device Communication & Field Protocols

## Overview

Prism talks to PLCs, remote I/O, meters and sensors through **southbound
protocol directories** — every device and its tags live together in
`config/01_southbound/`:

- `modbus/`: Modbus TCP, RTU (RS-485/RS-232) and ASCII;
- `s7comm/`: S7 PLCs over ISO-on-TCP (port 102);
- `virtual_tags/`: computed (Rhai) and scratch-pad tags with no physical I/O;
- `alarms/`: declarative alarm rules (`04_logic/02_ALARMS.md`).

WASM device drivers (`03_wasm/01_source/`) are covered in `05_wasm/02_DEVICE_DRIVERS.md`, the OPC UA
client (`02_northbound/04_opc_client/`) in `02_communication/03_OPC_UA.md`. The chapter is a complete
field reference: every key is listed with its type, requirement and default.

Legend used in the tables: **✅ = required**, **○ = optional** (default in the
last column); *filled* means the value is additionally filled from
`defaults.toml` when omitted.

### Modular Directory Architecture

To eliminate monolithic device files, Prism decouples device connection
settings from tag definitions and allows tags to be split across multiple
arbitrary TOML files per device:

```text
config/01_southbound/
├── modbus/
│   ├── defaults.toml            # Protocol-wide defaults (see §1.4)
│   ├── io_controller/           # One folder per device (TCP)
│   │   ├── plc.toml             # [[device]] + [device.tcp]
│   │   ├── control.toml         # [[device.tag]] files, split by purpose
│   │   └── telemetry.toml
│   ├── flow_meter/              # RTU device on RS-485
│   └── energy_meter/            # ASCII device
├── s7comm/
│   ├── defaults.toml
│   └── plc_s7/plc.toml          # [[device]] + [device.s7] + [[device.tag]]
├── opcua/
│   └── lab_instrument/meter.toml # [[device]] + [device.opcua] + node ids (03_OPC_UA.md)
└── virtual_tags/
    ├── defaults.toml            # Evaluation interval & type defaults
    └── calculations.toml        # Single-file device (also supported)
```

### File-Merging Rules & Resolution Semantics

When a protocol directory is loaded (`config/01_southbound/01_modbus/`, `s7comm/`,
`virtual_tags/`):

1. **Defaults loading.** `defaults.toml` in the protocol directory defines the
   defaults of **that directory's devices** (§1.4).
2. **Device directory discovery.** Each subdirectory is one device:
   - all `*.toml` files inside it (recursively, sorted by path) are gathered;
     directory symlinks are followed but cycle-safe (a loop is skipped);
   - connection tables and `[[device.tag]]` arrays are merged across the files
     in declaration order.
3. **Automatic identity resolution.** An omitted `name` defaults to the
   directory name; an omitted `protocol` — to the protocol directory
   (`modbus`, `s7comm`, `virtual`, or `wasm` in `03_wasm/01_source`).
4. **Standalone files** directly in a protocol directory (e.g.
   `virtual_tags/calculations.toml`) are parsed with the same rules.
5. The same layout and merging rules apply to every protocol.

The filtration stand used throughout this documentation has one Modbus TCP
controller (`io_controller`) plus the serial/S7 devices added in this chapter:

| Tag | Register | Address | Type | Unit | Access | Purpose |
|---|---|---|---|---|---|---|
| `io_controller.pressure_in` | input | 100 | word | Pa | ro | Filter inlet pressure |
| `io_controller.pressure_out` | input | 102 | word | Pa | ro | Filter outlet pressure |
| `io_controller.temperature` | input | 200 | word | C | ro | Liquid temperature in the loop |
| `io_controller.flow` | holding | 300 | word | l/h | ro | Flow meter reading |
| `io_controller.flow_sp` | holding | 302 | word | l/h | rw | Flow setpoint (operator / SCADA) |
| `io_controller.pump_speed` | holding | 304 | word | Hz | rw | Pump inverter frequency |
| `io_controller.tank_temperature` | holding | 500 | word | C | ro | Tank temperature |
| `io_controller.tank_temp_sp` | holding | 502 | word | C | rw | Tank temperature setpoint |
| `io_controller.tank_level` | holding | 504 | word | m | ro | Tank level (weighing scale) |
| `io_controller.valve_open` | coil | 600 | bool | – | rw | Filter loop isolation valve |
| `io_controller.pump_run` | coil | 608 | bool | – | rw | Main pump start/stop |
| `io_controller.heater_run` | coil | 610 | bool | – | rw | Tank heater (PWM output) |

---

## 1. Common Device & Tag Schema

The tables below apply to **every** protocol; protocol sections (§2, §3, §4)
add only their transport-specific parts.

### 1.1 `[[device]]`

| Field | Type | Required | Semantics |
|---|---|---|---|
| `name` | string | ✅ | Device id: non-empty, unique across the whole instance; `device.tag` ids are built from it |
| `protocol` | string | ○ | `modbus`, `s7comm`, `opcua`, `virtual`, `wasm`; inferred from the directory, or `modbus` when a `transport` is present, otherwise `virtual` |
| `transport` | `"tcp"` \| `"rtu"` \| `"ascii"` | ✅ for Modbus | Selects the Modbus transport; S7/virtual/WASM devices must not set it |
| `reconnect` | table | ○ | Retry/backoff policy (§1.5); filled from `[defaults.reconnect]` |
| `word_order` | `"be"` \| `"le"` | ○, be | Multi-register word order for the whole device; cascades into tags (§1.3) |
| `byte_order` | `"be"` \| `"le"` | ○, be | Byte order inside each 16-bit word; cascades into tags |
| `poll_interval_ms` | integer | ○, 500 | Pause between successful polling cycles; `0` is invalid; filled from `[defaults.device]` |
| `timeout_ms` | integer | ○, 2000 | Budget for connect, for one full read cycle (**per readable tag**), for every write and for disconnect; `0` is invalid; filled from `[defaults.device]` |
| `watchdog` | table | ○ | Poller stall supervision (§1.6) |
| `failover` | table | ○ | **Reserved**: `target` / `fail_value` / `restore_value` are parsed but not acted upon yet |
| `[[device.tag]]` | array | ○ | The device's tags (alias: top-level `[[tag]]`) |
| `[device.tcp]` | table | ✅ for `transport = "tcp"` | §2.1 |
| `[device.serial]` | table | ✅ for `transport = "rtu"`/`"ascii"` | §2.2 |
| `[device.s7]` | table | ✅ for `protocol = "s7comm"` | §3 |

### 1.2 `[[device.tag]]`

| Field                      | Type                                                   | Required           | Semantics                                                                                              |
| -------------------------- | ------------------------------------------------------ | ------------------ | ------------------------------------------------------------------------------------------------------ |
| `name`                     | string                                                 | ✅                  | Non-empty, unique within the device; the full tag id is `device.tag`                                   |
| `description`              | string                                                 | ○                  | Human-readable text; published by MQTT payload templates when enabled                                  |
| `address`                  | integer                                                | ✅ Modbus           | Register/coil address; 4xxxx/3xxxx/1xxxx conventions are normalized (§1.3)                             |
| `register`                 | `"holding"`/`"input"`/`"discrete"`/<br>`"coil"`        | ○, holding         | Modbus table: holding (FC3/FC16), input (FC4), discrete (FC2), coil (FC1/FC5)                          |
| `data_type`                | `bool`/`word`/`dword`/`int`/<br>`dint`/`real`/`string` | ✅ physical devices | Value encoding; aliases: `uint16`, `uint32`, `int16`, `int32`, `str`. `real` is the industrial wire type (Modbus/S7/OPC); virtual tags use `float` (`bool`/`int`/`float`/`string`), which is the same f32 without the protocol flavour |
| `unit`                     | string                                                 | ○                  | Engineering unit, published with telemetry                                                             |
| `access`                   | `"ro"`/`"rw"`/`"wo"`                                   | ○, ro              | `rw` enables writes; `wo` tags are not polled at all                                                   |
| `scale`                    | number                                                 | ○, 1.0             | `eng = raw × scale + offset` on reads; reverse on writes. `0` allowed only for `ro`                    |
| `offset`                   | number                                                 | ○, 0.0             | See `scale`                                                                                            |
| `eng_max`, `raw_max`       | number                                                 | ○                  | When both are set (>0) and `scale` is omitted (`1.0`), `scale = eng_max / raw_max` is computed at load |
| `min`, `max`                | number                                                 | ○                  | Engineering limits for **writes** only (MQTT/OPC/debug commands); reads are unaffected                 |
| `retentive`                 | boolean                                                | ○                  | Keep the last operator value across a restart (`[sql] restore_on_start`). Physical writable commands default to `false` (field is truth: a full-state reply reports the live value, not the saved row); virtual/UI tags default to `true`. See `02_MQTT.md` §8 |
| `word_order`               | `"be"`/`"le"`                                          | ○, be              | Overrides the device value for this tag (Dword/Dint/Real)                                              |
| `byte_order`               | `"be"`/`"le"`                                          | ○, be              | Overrides the device value for this tag                                                                |
| `byte_permutation`         | `[0..3; 4]`                                           | ○                  | Explicit 4-byte order for 32-bit Modbus values: canonical big-endian byte indices in wire order, e.g. `[2, 3, 0, 1]` = CDAB. Overrides `word_order`/`byte_order`; per-tag only |
| `byte_len`                 | integer                                                | ○, 32              | String length in bytes (`data_type = "string"`): the poller reads `ceil(byte_len/2)` registers         |
| `string_format`            | `"s7"` \| `"raw"`                                      | ○                  | S7 strings only (§3.2); `raw` (aliases `chars`, `bytes`) = CHAR array                                  |
| `mirror_to`                | string                                                 | ○                  | After every Good read the value is queued to `"device.tag"` (×`mirror_scale`)                          |
| `mirror_scale`             | number                                                 | ○, 1.0             | Multiplier for `mirror_to` (numeric tags)                                                              |
| `fail`                     | table                                                  | ○                  | Per-tag failure policy (§1.3); filled from `[defaults.tag.fail]`                                       |
| `expression`               | string                                                 | ○                  | Rhai expression — tags of virtual devices only (§4)                                                    |
| `script_func`              | string                                                 | ○                  | Rhai function name — tags of virtual devices only (§4)                                                 |
| `initial_value`            | number                                                 | ○                  | Start value of a scratch-pad tag in a virtual device before the first evaluation                       |
| `node_id`, `namespace_uri` | string                                                 | ○                  | OPC UA client tags only (03_OPC_UA.md); forbidden for Modbus                                           |
| `s7`                       | table                                                  | ✅ for S7 tags      | S7 address (§3.2); forbidden for Modbus                                                                |

Integer fields (`address`, `unit_id`, `baud_rate`, `port`, `byte_len`, `min`/`max`, …)
accept TOML 1.0 literals: decimal `24`, hexadecimal `0x18`, binary `0b11000`,
octal `0o30`, with optional `_` separators (`0x00_18`). String write payloads
(MQTT, scripts) use the same notation: `0x32` = `50`.

### 1.3 Value pipeline

**Address normalization** (Modbus): the wire address is `address − base`, where
the base applies only when the configured address is ≥ base:

| `register`             | Base  | Example                                |
| ---------------------- | ----- | -------------------------------------- |
| `holding` (or omitted) | 40001 | `40100 → 99`, `40001 → 0`; below the base the value is an already-raw wire address: `100 → 100` (the same register as `40101`) |
| `input`                | 30001 | `30001 → 0`, `30050 → 49`              |
| `discrete`             | 10001 | `10002 → 1`                            |
| `coil`                 | –     | used as is                             |

**Word / byte order** (default `be`/`be`):

- `word_order` swaps the 16-bit words of `dword`/`dint`/`real`;
- `byte_order` swaps the two bytes inside each 16-bit word (also inside every
  word of multi-word values and inside strings);
- `bool` ignores both; strings use `byte_order` only.

**Explicit 32-bit permutation.** `byte_permutation = [2, 3, 0, 1]` names the
canonical big-endian bytes (`A B C D`) in wire order and overrides both flags
for `dword`/`dint`/`real`. Any permutation of `[0, 1, 2, 3]` is accepted, so a
device with an unusual layout can be described without changing the driver.
The four conventional layouts are `[0,1,2,3]` (ABCD), `[2,3,0,1]` (CDAB),
`[1,0,3,2]` (BADC) and `[3,2,1,0]` (DCBA). The field is per-tag and does not
cascade from device/defaults.

The effective order of a tag is resolved in this precedence:
`tag` → `device` → `[device.tcp]`/`[device.serial]` → `[defaults.device]` →
`[defaults.tcp]`/`[defaults.rtu]`/`[defaults.ascii]` → `[defaults.tag]`.

**Bool:** `scale` must stay `1.0` and `offset` `0.0`; any non-zero register
reads as 1; writes accept only `0`/`1` (`0xFF00`/`0x0000` on the wire).

**Strings (Modbus):** read `ceil(byte_len/2)` registers, decode with
`byte_order`, cut at the first NUL and trim trailing spaces; writes are allowed
only to `holding` registers, pad with NUL and truncate to `byte_len`
(2 bytes per register, non-even length padded).

**Numeric writes** are validated before I/O: the raw value must be finite,
integral for integer types, inside the type range (`word` 0…65535,
`int` −32768…32767, …), inside the tag `min`/`max`; `real` must fit `f32`.
Scaled tags are quantized with rounding.

**Failure policy (`[device.tag.fail]`):**

| Field | Type | Default | Semantics |
|---|---|---|---|
| `fail_strategy` | `"last_known"` \| `"preset"` \| `"nan"` \| `"alarm"` | `last_known` | `last_known`: keep the last good value, quality Bad. `preset`: substitute `safe_value` (quality Uncertain) and write it to `preset_target`. `nan`: publish no data (NaN, quality Bad) — consumers must not act on a stale value. `alarm`: quality Bad plus a synthetic alarm in the reserved slot |
| `fail_message` | string | "Undefined tag communication error: {tag}…" | Published with the failure (`{tag}` is **not** substituted — unlike alarm rules) |
| `safe_value` | string | – | Value for `preset` (numeric text; `true`/`false` are accepted for bool tags) |
| `preset_target` | string | – | `"device.tag"` receiving `safe_value` (or `"0"`) on failure |

A directory-wide default for every tag is set in `[defaults.tag.fail]` (§1.4).

The strategies act on every `Bad` sample of a **polled** device: a failed
read, a connect failure while the controller is offline, or "no data" from a
WASM plugin. They do not apply to `wo` tags (never polled) or to virtual-tag
evaluation errors (the last value is kept with `Bad` quality). An unparsable
`safe_value` (e.g. text on a numeric tag) disables the substitution, which
falls back to the `last_known` behavior.

On the first Good value the failure state clears (quality returns to Good, the
synthetic alarm resets).

**Initial value (`initial_value`):** a writable tag (`rw`/`wo`) with an
`initial_value` receives it every time its device comes **online** — the first
data after connect or a recovery after an outage (at backend start the
equipment may still be off). Physical protocols queue a device write (sent on
the next poll cycle); virtual and WASM device tags are applied host-side.
`[defaults.tag].initial_value` fills tags that do not define their own. Init
runs before the `on_device_online` scripts
([`04_logic/01_RHAI.md`](../04_logic/01_RHAI.md) §3.1), so a hook can
override it. `ro` and string tags are skipped. The TOML literal `nan` means
"no value yet": host-side tags are seeded with NaN, while the preset of a
physical protocol is skipped — a register cannot carry NaN.

**`mirror_to`:** after a successful read with Good quality the (engineered)
value is queued to the target tag's device; string values are copied verbatim,
`mirror_scale` is applied to numbers only. A missing target or a target without
`device.tag` form is ignored.

### 1.4 `[defaults]` — per-protocol defaults

`defaults.toml` of a protocol directory applies to **that directory's devices**
and is applied before validation, so defaults may legally fill required fields
(like `[defaults.tcp].ip`).

| Section | Fields | Applies to |
|---|---|---|
| `[defaults.device]` | `poll_interval_ms`, `timeout_ms`, `word_order`, `byte_order` | every device of the group (omitted values only) |
| `[defaults.reconnect]` | whole retry table | every device without its own `[device.reconnect]` |
| `[defaults.tcp]` | `ip`, `port`, `word_order`, `byte_order` | `[device.tcp]` sections of the group |
| `[defaults.rtu]` | `unit_id`, `baud_rate`, `data_bits`, `stop_bits`, `parity` | `[device.serial]` of `transport = "rtu"` devices |
| `[defaults.ascii]` | same fields | `[device.serial]` of `transport = "ascii"` devices |
| `[defaults.tag]` | `word_order`, `byte_order`, `fail`, `initial_value` | tags without their own values |
| `[defaults.tag.fail]` | the fail table | tags without their own `[device.tag.fail]` |
| directory-local defaults file | the same sections + `devices` selector | devices named in `devices` (all devices of the directory when the selector is absent); file name is `defaults.toml` or a numbered alias like `00_defaults.toml`; used by device subdirectories and WASM source modules (`03_wasm/01_source/<module>/`) |
| virtual tags | `[defaults] eval_interval_ms`, `data_type`, `unit` | `virtual_tags/defaults.toml` only (§4) |

Notes:

- scalar options whose Rust default is a real value (`poll_interval_ms` 500,
  `timeout_ms` 2000, `port` 502, `unit_id` “unspecified”) are replaced by the
  defaults only when still at the Rust default — a literal `500`/`2000` in the
  device is indistinguishable from an omitted value;
- arrays/`Option` fields (`ip`, `baud_rate`, `parity`, orders, `fail`,
  `initial_value`) are filled only when absent;
- editing a file of one device module is applied on the fly: only the pollers
  of that module restart, and their last values, quality and alarms survive
  ([`04_logic/01_RHAI.md`](../04_logic/01_RHAI.md) §6). A changed tag list, a
  new device or a new tag does not restart anything by itself: the log asks
  for `r` + Enter, which rebuilds everything.

### 1.5 Reconnect & retry (`[device.reconnect]`, `[defaults.reconnect]`)

| Field | Type | Default | Semantics |
|---|---|---|---|
| `count` | `"infinite"` \| integer 0…255 | `infinite` | Consecutive session attempts before the poller loop ends (`0` = never connect) |
| `strategy` | `"stop"` \| `"sleep_then_reset"` \| `"hold_infinite"` | `hold_infinite` | `stop` ends the loop after a failed connect; the other two keep retrying. *`sleep_then_reset` currently behaves like `hold_infinite`* |
| `backoff` | `"none"` \| `"linear"` \| `"exponential"` | `none` | Delay multiplier by attempt number: 1 / attempt / 2^(attempt−1) |
| `base_delay_ms` | integer | 1000 | Base reconnect delay |
| `max_delay_ms` | integer | 30000 | Upper bound of the reconnect delay |

Practical semantics: the attempt counter grows after every failed connect or
failed read session and resets after a fully successful cycle; the delay before
attempt *n* is `min(base × factor, max)`, at least 1 ms; without a `reconnect`
section the delay is a fixed 1000 ms. A break out of the loop (`count`
exhausted, `strategy = "stop"`) stops the *poller task*, but the supervisor
restarts it after ~2 s — a permanently dead device keeps being retried.

### 1.6 Watchdog (`[device.watchdog]`)

| Field | Type | Default | Semantics |
|---|---|---|---|
| `enabled` | bool | true | `false` disables the stall check (the supervisor still restarts a panicked/crashed poller) |
| `timeout_ms` | integer | – | Stall threshold; `0`/absent = auto: `(timeout_ms × max(tags, 1) + poll_interval_ms) × 2`, at least 30 000 ms |

On trip the poller task is aborted, all device tags are set Bad and the poller
restarts after 2 s.

### 1.7 Device status

| Status | Transition |
|---|---|
| `error` | immediately after a failed connect (all tags get a Bad sample) |
| `offline` | initial state of a physical device; and after **2** consecutive failed read cycles |
| `online` | after the first fully successful read cycle (a device with no readable tags — right after connect) |

Events are emitted only on changes. Tag quality is derived from the sample
status: Good / Uncertain / Bad.

On every transition to `online` (the first connect and each recovery) the core
runs the `on_device_online(device)` Rhai hooks — the way to re-apply
initialisation writes for equipment that was powered off at backend start
(see [`04_logic/01_RHAI.md`](../04_logic/01_RHAI.md) §3.1).

---

## 2. Modbus (`config/01_southbound/01_modbus/`)

### 2.1 TCP devices — `[device.tcp]`

```toml
[[device]]
name      = "io_controller"
protocol  = "modbus"
transport = "tcp"

[device.tcp]
ip      = "127.0.0.1"
port    = 502
unit_id = 1

[[device.tag]]
name        = "flow"
address     = 300
register    = "holding"
data_type   = "word"
unit        = "l/h"
access      = "ro"
description = "Flow meter reading"
```

| Field | Type | Required | Default | Semantics |
|---|---|---|---|---|
| `ip` | string | ✅ (or `[defaults.tcp].ip`) | – | IPv4 address; digits and dots only |
| `port` | u16 | ○ | 502 | TCP port; `0` invalid |
| `unit_id` | u8 | ○ | 1 | Modbus slave address |
| `word_order`, `byte_order` | `"be"`/`"le"` | ○ | – | Fallback orders for the tags of this device (§1.3) |

### 2.2 Serial RTU — `[device.serial]`

```toml
[[device]]
name      = "flow_meter"
protocol  = "modbus"
transport = "rtu"

[device.serial]
serial_port = "COM10"     # Linux: "/dev/ttyUSB0" or /dev/serial/by-id/…
unit_id     = 2
baud_rate   = 19200
parity      = "even"
data_bits   = 8
stop_bits   = 1

[device.serial.rs485]
mode = "auto"
```

| Field | Type | Required | Default | Semantics |
|---|---|---|---|---|
| `unit_id` | 0…247 \| `"default_unspecified"` | ○ | unspecified → 1 | Modbus slave address; values >247 are rejected |
| `serial_port` | string | ✅ (exactly one of the two) | – | Explicit port name |
| `[device.serial.match]` | table | ✅ (exactly one of the two) | – | Pick the port by USB descriptors; resolved on every connect (survives COM renumbering) |
| `baud_rate` | integer | ○ | 9600 | Line speed; non-standard values only warn |
| `data_bits` | 5…8 | ○ | 8 | Frame bits |
| `stop_bits` | 1…2 | ○ | 1 | Stop bits |
| `parity` | `"none"`/`"odd"`/`"even"` | ○ | none | Parity |
| `word_order`, `byte_order` | `"be"`/`"le"` | ○ | – | Fallback orders (§1.3) |

`[device.serial.match]` (all fields optional, at least one required; every set
field must match the same port, non-USB ports never match; exactly one port
must hit, otherwise connect fails with the candidate list):

| Field | Type | Semantics |
|---|---|---|
| `usb_serial` | string | USB iSerialNumber, case-insensitive |
| `vid` / `pid` | integer (hex literal, e.g. `0x0403`) | USB vendor / product id |
| `product` | string | USB product string |
| `manufacturer` | string | USB manufacturer string |

`[device.serial.rs485]` (half-duplex line control; defaults in the table):

| Field | Type | Default | Semantics |
|---|---|---|---|
| `mode` | `"auto"`/`"kernel"`/`"rts"`/`"off"` | `auto` | `kernel` — Linux `TIOCSRS485`; `auto` — kernel when supported, otherwise nothing; `rts` — user-space RTS toggling on any OS; `off` — adapter handles direction |
| `rts_on_send` | bool | true | RTS level while transmitting |
| `rts_after_send` | bool | false | RTS level when idle |
| `delay_before_ms` | integer | 0 | Kernel mode: pause before transmission |
| `delay_after_ms` | integer | 0 | Kernel mode: pause before releasing the line |
| `rx_during_tx` | bool | false | Kernel mode: keep receiving while transmitting |
| `guard_ms` | number ≥ 0 | 1.0 | RTS mode: pause after the transmit queue drains |
| `echo` | `"off"`/`"strip"` | `off` | `strip` — drop the leading bytes that repeat our own frame (adapter/device echo) |

Two devices may not share a `serial_port` (trimmed, case-insensitive) — such a
configuration is rejected. On a bench the line is emulated: the core opens one
end of a virtual pair and `prism-sim` serves the other through a `[[serial]]`
block of the bench file
([`03_tooling/02_SIMULATOR.md`](../03_tooling/02_SIMULATOR.md)).

### 2.3 Serial ASCII — `transport = "ascii"`

Same `[device.serial]` table; the framing differs: every ADU is
`':' + hex(unit + PDU + LRC) + CRLF`, LRC is the two's-complement of the byte
sum. The client waits at most 1 s for a response, rejects foreign unit ids,
broken LRC and `function|0x80` exception frames.

```toml
[[device]]
name      = "energy_meter"
protocol  = "modbus"
transport = "ascii"

[device.serial]
serial_port = "COM12"
unit_id     = 3
baud_rate   = 9600

[[device.tag]]
name      = "active_power"
address   = 0
register  = "holding"
data_type = "word"
unit      = "kW"
scale     = 0.01
access    = "ro"
```

### 2.4 Modbus tag reference

`register` selects the function codes: `holding` — FC3 read / FC16 write;
`input` — FC4, read-only; `coil` — FC1 / FC5; `discrete` — FC2, read-only.
`data_type` defines the value size:

| `data_type` | Registers | Encoding |
|---|---|---|
| `bool` | 1 bit | coil/discrete, or a non-zero register |
| `word` / `int` | 1 | u16 / i16 |
| `dword` / `dint` | 2 | u32 / i32 |
| `real` | 2 | IEEE-754 f32 |
| `string` | `ceil(byte_len/2)` = 16 by default | bytes, `byte_order` inside each register |

Validation: `address` is required; `input`/`discrete`
must be `ro`; S7/OPC address fields are rejected.

### 2.5 Full `defaults.toml` example

```toml
# config/01_southbound/01_modbus/defaults.toml — applies to the devices of this
# directory only (see §1.4).
[defaults.device]
poll_interval_ms = 500
timeout_ms       = 2000

[defaults.reconnect]
count     = "infinite"
strategy  = "hold_infinite"
backoff   = "none"
base_delay_ms = 1000
max_delay_ms  = 30000

[defaults.tcp]
port = 502

[defaults.rtu]
baud_rate = 19200
parity    = "even"

[defaults.ascii]
baud_rate = 9600

[defaults.tag]
word_order = "be"
byte_order = "be"

[defaults.tag.fail]
fail_strategy = "last_known"
```

---

## 3. S7comm (`config/01_southbound/02_s7comm/`)

```toml
# config/01_southbound/02_s7comm/plc_s7/plc.toml
[[device]]
name     = "plc_s7"
protocol = "s7comm"

[device.s7]
host = "192.168.1.10"    # the stand bench uses 127.0.0.1
port = 102
rack = 0
slot = 1
request_gap_ms = 10

[[device.tag]]
name      = "motor_speed"
data_type = "word"
unit      = "rpm"
access    = "ro"

[device.tag.s7]
area   = "db"
db     = 1
offset = 0
```

### 3.1 `[device.s7]`

| Field | Type | Required | Default | Semantics |
|---|---|---|---|---|
| `host` | string | ✅ | – | PLC address (ISO-on-TCP) |
| `port` | u16 | ○ | 102 | TCP port; `0` invalid |
| `rack` | 0…7 | ○ | 0 | Rack number → remote TSAP |
| `slot` | 0…31 | ○ | 1 | Slot number → remote TSAP |
| `request_gap_ms` | integer ≤ 1000 | ○ | 0 | Minimum pause between two S7 jobs; classic S7-300 CPUs have a single PG resource and reject an overrun job queue |

A device with `protocol = "s7comm"` must **not** set `transport`,
`[device.tcp]`, `[device.serial]` or `[device.opcua]`.

### 3.2 S7 tag addressing — `[device.tag.s7]`

| Field | Type | Required | Default | Semantics |
|---|---|---|---|---|
| `area` | `"db"` \| `"mk"` \| `"pe"` \| `"pa"` | ○ | `db` | Data block / flag (merker) / inputs / outputs |
| `db` | u16 | only for `area = "db"`, > 0 | 0 | DB number; for `mk`/`pe`/`pa` it must be `0` |
| `offset` | u16 | ✅ | – | Byte offset inside the area |
| `bit` | 0…7 | only for `bool` | – | Bit inside the byte; `bool` requires it, other types must omit it |

Rules and notes:

- numbers are **big-endian** (S7 native): `word`/`int` 2 bytes,
  `dword`/`dint`/`real` 4 bytes;
- `pe` (inputs) is read-only; `pa`, `db`, `mk` are writable;
- strings: `data_type = "string"` plus `string_format = "s7"` (default) reads a
  Siemens `STRING[N]` with its 2-byte header (`byte_len` is the payload length,
  32 by default); `string_format = "raw"` (`chars`/`bytes`) reads a CHAR array
  without header;
- neighbouring tags are merged into larger S7 jobs (gap ≤ 4 bytes); a block the
  CPU rejects is re-read tag-by-tag so one bad address does not mute the rest;
- `address`, `register` and `node_id` are rejected on S7 tags.

---

## 4. Virtual Tags (`config/01_southbound/04_virtual_tags/`)

Virtual devices have no transport and never run a poller; an evaluator ticks
them with `eval_interval_ms`. A tag runs in one of three modes:

| Mode | Fields | Behaviour |
|---|---|---|
| expression | `expression` | Rhai expression (or statement block) evaluated every tick against the registry (`read("io_controller.flow")`) |
| script_func | `script_func` | Name of a Rhai function; the first enabled script that defines it is called |
| scratch-pad | none of the above (+ `initial_value`, `access = "rw"`) | Written from the outside (MQTT/OPC/Rhai); the evaluator re-publishes the stored value |

If both `expression` and `script_func` are set, the expression wins and the
function is the fallback for a non-finite/None result. Evaluation errors keep
the previous value and drop quality to Bad (the alarm tracker is reset). A
non-finite result reads as `NaN` (Bool coerces to 0). String tags are stored in
the alarm store and published as text; alarm rules apply to numeric values.

```toml
# config/01_southbound/04_virtual_tags/calculations.toml
[[device]]
name     = "calculations"
protocol = "virtual"

[[device.tag]]                 # expression
name       = "pressure_drop"
data_type  = "float"
unit       = "Pa"
expression = 'read("io_controller.pressure_in") - read("io_controller.pressure_out")'

[[device.tag]]                 # scratch-pad
name          = "system_ready"
data_type     = "bool"
access        = "rw"
initial_value = 0.0
```

`defaults.toml` of the directory fills `eval_interval_ms` (default 500) and,
for tags without their own `data_type`/`unit`, the `data_type` (default
`float`) and `unit`.

**Legacy flat format** (`scripts/bindings.toml` or `config/01_southbound/04_virtual_tags.toml`)
is still read: `[defaults]` + `[[virtual_tag]]` with `device` (namespace,
default `virtual`), `name`, `description`, `unit`, `expression`, `script_func`,
`initial_value`, `data_type` (`float`/`bool`/`int`/`string`). Legacy entries
have no `access` control (always writable) and ignore `[defaults].data_type`;
`depends_on` is accepted for compatibility and not used.

Virtual tags are still tags: they count toward the license quota
([`06_operations/01_LICENSING.md`](../06_operations/01_LICENSING.md)), can
carry alarm rules ([`04_logic/02_ALARMS.md`](../04_logic/02_ALARMS.md)) and are
exported to OPC UA/MQTT like physical ones.

---

## 5. Devtools Auto-generation & Downstream Artifacts

Prism provides an automated generator suite in `devtools/` that transparently aggregates modular device directories and decoupled tag files when producing downstream artifacts.

A new project can be scaffolded with `prism-devtools init`
([`03_tooling/06_DEVTOOLS.md`](../03_tooling/06_DEVTOOLS.md)). An existing
instance is initialized by `prism init` (or implicitly on first launch), which
unfolds the skeleton and writes only what is missing. The generators below
extend a live instance:
point them at the device directories, and they emit the northbound artifacts
from the same tags (`config/**` stays the single source of truth).

### 5.1. Target Discovery & Aggregation Semantics
All generators (`prism-devtools generate mqtt|opc-client|opc-server`) follow universal input discovery rules:
- **Directory Targets:** Specifying a directory target (e.g. `config/01_southbound/01_modbus`, `config/01_southbound/02_s7comm`, `config/01_southbound/04_virtual_tags`) causes the generator to recursively scan all `*.toml` files within that directory.
- **Device Folder Grouping:** Files within each device directory (e.g. `io_controller/`) are aggregated into a single unified device entity. Connection settings and tags declared across arbitrary split files (`plc.toml`, `control.toml`, `telemetry.toml`) are merged prior to validation.
- **Tag Syntax Freedom:** Both `[[device.tag]]` and top-level `[[tag]]` formats are parsed identically.
- **OPC DA Bridge Integration:** When `config/02_northbound/03_opc_da_bridge` is targeted, `[[groups]]` and `[[groups.tags]]` mappings are automatically parsed into first-class devices and tags for seamless MQTT and OPC UA publication.

### 5.2. Generator Workflows

Each generator is configured declaratively: `devtools/tooling/generators/<name>.toml`
declares `targets`, `[template]`, `[defaults.*]`, `[[group]]` patterns and
`[[tag]]` overrides. `prism-devtools` implements all of them
(`--check`/`--dry-run`/`--force`, a JSON report and a manual-edit drift guard).

Hand-managed files (seeds) are created from the described config only when
missing and never overwritten. `--apply-hand` applies the described content to
them: the first adoption keeps a `.bak` next to the file, afterwards it is
regenerated under the same drift guard as the generated files (manual edits
stop generation until folded into the generator config or `--force`);
`--apply-hand --check` performs the same comparison without writing. Without
the flag a run reports seeds that differ from the described config.

| Generator | Writes (drift-guarded) | Seeds only when missing (`--apply-hand` adopts) |
|---|---|---|
| `generate mqtt` | `config/02_northbound/01_mqtt/tags.toml` | `broker.toml`, `channels.toml`/`channels.d/`, `payloads/` |
| `generate opc-client` | `config/02_northbound/04_opc_client/endpoints.toml` | `defaults.toml` |
| `generate opc-server` | `config/02_northbound/02_opc_server/nodes.toml` | `server.toml` |

#### MQTT Telemetry & Channels Generator (`prism-devtools generate mqtt`)
Reads declarative rules from `devtools/tooling/generators/mqtt.toml`:
```bash
prism-devtools generate mqtt --root instances/stand-01 --dry-run
prism-devtools generate mqtt --root instances/stand-01 --check
prism-devtools generate mqtt --root instances/stand-01 --apply-hand
```
- Emits `[[telemetry_group]]`, `[[telemetry_tag]]` (publish rules) and `[[command]]` (write rules) into `config/02_northbound/01_mqtt/tags.toml`.
- Emits the described channels (`config/02_northbound/01_mqtt/channels.toml` — or, with `[generator].layout = "split"`, one file per channel in `channels.d/<contract>/<id>.toml` plus `channels.d/_meta.toml`: contracts, arbitrary topic paths, per-channel fields) and seeds missing payload templates (`payloads/*.json`: JSON with `{{marker}}` slots — mandatory `namespace`/`name`/`value` in flat forms, optional built-ins like `timestamp`, user fields bound to any tag); `broker.toml` keeps the connection and defaults.
- Payload/user fields (`[[channel.field]]`): exactly one source — `from_tag` (any tag) or `value` (literal); pre-validated (non-empty names, no reserved/duplicate names).
- Seeds `broker.toml`/channels (`channels.toml` or `channels.d/`) only when they are missing (never overwritten); payload templates are seed-only. `--apply-hand` applies the described channels/broker to existing files: `.bak` on first adoption, then they are drift-guarded like `tags.toml`; files of the other layout (e.g. the old `channels.toml` after switching to `layout = "split"`) are retired to `<name>.bak`, `--check` reports them as drift until then. `--apply-hand --check` performs the same comparison without writing. Without the flag a run reports hand files that differ from the described config.
- Performs cross-device tag collision detection and duplicate address verification, checks `data_type` values against the `config::DataType` schema, and warns about rules that reference missing tags/namespaces (`collect_reference_warnings`).
- Cascades group patterns and individual tag overrides onto aggregated field and virtual points.
- `--root <dir>` resolves relative `targets`/`output_dir`/`report_path` from the given project root.

#### OPC UA Client Generator (`prism-devtools generate opc-client`)
Reads input targets, `[template]` (`endpoint_url`, `node_id`, `application_uri`; `{host}` comes from `[device.tcp].ip`) and monitoring defaults from `devtools/tooling/generators/opc_client.toml`:
```bash
prism-devtools generate opc-client --root instances/stand-01
prism-devtools generate opc-client --root instances/stand-01 --apply-hand
```
- Generates `config/02_northbound/04_opc_client/endpoints.toml` (one `[[endpoint]]` per device with `[[endpoint.tag]]` entries) — or, with `[generator].layout = "split"`, one file per device in `endpoints.d/<device>.toml` (no `endpoints.toml`) — and seeds `config/02_northbound/04_opc_client/defaults.toml` (security policy, PKI, timeouts) only when missing.
- `defaults.toml` is described by `[defaults.security]`: any of its keys (`security_policy`, `security_mode`, `pki_dir`, `trust_server_certs`, `max_nodes_per_read`, `session_timeout_ms`, `reconnect_backoff_ms`) is emitted as-is, missing ones get the generator defaults; `--apply-hand` applies them to an existing file (`.bak` on first adoption, then the drift guard).
- Monitoring fields (`sampling_interval_ms`, `queue_size`, `discard_oldest`) cascade `[defaults.monitoring] -> [[group]] -> [[tag]]`; `unit` is copied from the tag when present.

#### OPC UA Server Address Space Generator (`prism-devtools generate opc-server`)
Reads node mapping rules from `devtools/tooling/generators/opc_server.toml`:
```bash
prism-devtools generate opc-server --root instances/stand-01 --apply-hand
```
- Generates `config/02_northbound/02_opc_server/nodes.toml` (`[defaults]` + one `[[node]]` per tag) — or, with `[generator].layout = "split"`, `nodes.toml` keeps only `[defaults]` and each device gets `nodes.d/<device>.toml` — and seeds `server.toml` (bind address, security, exposure flags) from `[defaults.server]` only when missing. The runtime merges `nodes.toml` and every `*.toml` under `nodes.d/` (recursively, sorted; the first entry of a tag wins) into the server exports at load (an explicit `[[server.tag]]` in `server.toml` wins); exports are cross-validated against the device tree by `--check-config` and at server start.
- `--apply-hand` applies the described `[defaults.server]` to an existing `server.toml` (`.bak` on first adoption, then the drift guard); `[[defaults.server.user]]`/`[[defaults.server.tag]]` arrays are emitted as runtime `[[server.user]]`/`[[server.tag]]`.
- Tags with `access = "rw"` become `writable = true`; a `[[tag]].writable` override wins over `access`. Write-only (`wo`) tags and tags without `data_type` are skipped with a warning (the runtime rejects such exports). The same monitoring cascade as the client generator applies.

#### Creating a project

`prism-devtools init` creates a new project from the `empty`, `minimal`,
`standard` or `full` preset and writes the generator configs next to the
tooling binary; see [`03_tooling/06_DEVTOOLS.md`](06_DEVTOOLS.md).

## 6. Tag History (`config/01_southbound/06_history/history.toml`)

History is an optional in-memory ring buffer per tag. It is not written to
disk; Rhai scripts (`history(tag, window_ms)`) and ML feature assembly read it.
Only accepted samples with good quality are stored.

```toml
[defaults]
enabled   = true
depth     = 600       # samples per tag (1..=100000)
sample_ms = 500       # at most one sample every 500 ms (0 = every update)

[[tag]]
id = "plc1.temperature"

[[tag]]
id = "calculations.temperature_f"
```

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `true` | Turn history collection on or off. |
| `depth` | `600` | Ring-buffer size per tag. Memory is roughly `depth * 32` bytes per tag. |
| `sample_ms` | `500` | Minimum interval between stored samples; `0` stores every accepted update. |

A missing file means history is disabled. The file may also live in the legacy
`config/history.toml` location.
