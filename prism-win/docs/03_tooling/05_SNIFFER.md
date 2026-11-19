# `prism-sniff` — passive bus sniffer and transparent relay

`prism-sniff` observes a field bus and decodes the traffic in the console
without linking the core. It understands Modbus RTU/ASCII/TCP, S7comm, OPC UA
and MQTT itself. A serial tap is read-only; a TCP proxy is a byte-for-byte relay
so Prism keeps working while every frame is decoded.

The sniffer is a **line console**, not a full-screen application. Each event is
one line, coloured with ANSI escapes when the output is a terminal, and raw hex
can be printed below it. Output can therefore be redirected, piped or captured
by a service manager.

## Running

```sh
prism-sniff                                      # use sniff.toml found automatically
prism-sniff --config sniff.toml                  # explicit config
prism-sniff --config sniff.toml --list           # print sources and exit
prism-sniff --config sniff.toml --check-config   # validate and exit
prism-sniff --config sniff.toml --source rs485-main
prism-sniff --config sniff.toml --record
prism-sniff --config sniff.toml --record-jsonl --marker-file steps.txt
prism-sniff --init                               # write sniff.toml next to the tool
prism-sniff --init --config sniff.toml --force   # overwrite a specific file
```

### How the config is found

Without `--config`, the tool tries:

1. `sniff.toml` next to the executable;
2. `sniff.toml` in the current directory.

It does not search parent directories. If neither file exists, it prints an
error with the `--init` hint and exits with code 2. The tool never creates a
config by itself; only `--init` writes one.

`--init` writes the built-in commented template (a serial tap placeholder on
`COM4`), creates missing parent folders, and refuses to replace an existing file
without `--force`. Edit the example source before the first real run.

### Options

| Option | Meaning |
|---|---|
| `-c, --config <file>` | Sniff config file. |
| `-s, --source <name>` | Run only this `[[source]]`; repeatable. Unknown names are an error. |
| `--list` | Print the configured sources and exit. |
| `--check-config` | Validate the config and exit. `--check` is an alias. |
| `--init` | Write the commented config template and exit. |
| `--force` | Allow `--init` to overwrite an existing file. |
| `--no-color` | Disable ANSI colours. `NO_COLOR` is also honoured and always wins. |
| `--record` | Start a recording immediately, using `[log] format` (`text` by default). |
| `--record-jsonl` | Start a JSONL recording immediately; implies `--record` and overrides `[log] format`. |
| `--record-dir <dir>` | Recording folder; does not start a recording by itself. |
| `--marker-file <file>` | Watch a file; every complete non-empty line becomes a marker event. |
| `--no-hotkeys` | Do not capture Ctrl+R/F2/F3/Ctrl+C/Ctrl+Q (services, pipes, scripts). |
| `-h, --help` | Print usage. |
| `-V, --version` | Print the version. |

`--list` and `--check-config` load and validate the config but open no port.
`--list` prints one row per selected source with `SOURCE`, `KIND`, `MODE`,
`PROTOCOL` and `ENDPOINT`; `--check-config` prints
`config ok: <n> source(s) in <path>`.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Normal exit, `--list`, `--check-config`, `--init`, and Ctrl+C/Ctrl+Q. Also used when some sources failed but at least one ran. |
| `1` | Every selected source failed to start or run. |
| `2` | Usage, config or `--init` error (unknown option, missing config, parse/validation failure, unknown `--source`, existing file without `--force`). |

## Configuration

```toml
[log]
timestamp = "local"   # local | utc | mono | none
hex = true            # print raw bytes under every decoded event
hex_limit = 64        # maximum bytes in that raw line (minimum 8)
color = "auto"        # auto | always | never (NO_COLOR is honoured)
raw = true            # print frames no decoder understood
record_dir = "log"    # relative to the prism-sniff binary directory
format = "text"       # text | jsonl
```

`timestamp = "local"` is the full local date and time with milliseconds;
`"utc"` uses UTC, `"mono"` seconds since start, `"none"` removes the prefix.
`color = "auto"` colours only a terminal; `--no-color` and `NO_COLOR` force
colours off. `raw = false` hides info-level unparsed frames from the console
(warnings and errors still print). `record_dir` must not be empty.

A config must contain at least one `[[source]]`; source names must be unique.
A blank name is replaced with `source-1`, `source-2`, and so on. Unknown keys are
rejected.

### Source keys

| Key | Default | Applies to |
|---|---|---|
| `name` | `source-N` | All; printed in every log line. |
| `kind` | required | `serial` or `tcp`. |
| `mode` | `tap` (serial), `proxy` (tcp; `connect` when only `address` is set) | `tap`, `proxy` or `connect`. |
| `protocol` | `auto` | `auto`, `modbus-rtu`, `modbus-ascii`, `modbus-tcp`, `s7`, `opc-ua`, `mqtt`, `raw`. |
| `port` | required (serial) | Serial port, e.g. `COM7` or `/dev/ttyUSB0`. |
| `baud` | `9600` | Serial, 1..4,000,000. |
| `data_bits` | `8` | Serial, 5..8. |
| `parity` | `none` | Serial: `none`, `even` or `odd`. |
| `stop_bits` | `1` | Serial: 1 or 2. |
| `flow` | `none` | Serial: `none`, `software` or `hardware`. |
| `peer` | none | Serial proxy, informational: the other end of the virtual pair, opened by Prism; ignored elsewhere. |
| `target` | none | Required for a serial proxy (real device port) and for a TCP proxy (real TCP endpoint). |
| `listen` | required (tcp proxy) | Local bind address, e.g. `127.0.0.1:1502`. |
| `address` | required (tcp connect) | Remote monitor endpoint, e.g. `192.168.0.50:4001`. |
| `idle_ms` | `20` | Frame gap to settle incomplete traffic; `"auto"` or `0` = derive from baud and adapt (TCP uses 20 ms). Maximum 10000. |
| `reconnect_ms` | `2000` | TCP connect retry delay; must be > 0. |
| `connect_timeout_ms` | `3000` | TCP connect timeout; must be > 0. |

Validation rules:

- serial requires `port`; a serial **tap** must not set `target`; a serial
  **proxy** requires `target` and it must differ from `port`;
- `kind = "tcp"` `mode = "proxy"` requires `listen` and `target` and rejects
  `address`;
- `kind = "tcp"` `mode = "connect"` requires `address` and rejects
  `listen`/`target`;
- `mode = "tap"` is only valid for serial, `mode = "connect"` only for TCP;
- a serial source accepts only `auto`, `modbus-rtu`, `modbus-ascii` or `raw`.

For `kind = "tcp"`, `port`, `baud`, `data_bits`, `parity`, `stop_bits`, `flow`
and `peer` are serial settings and have no effect. Use `listen`/`target` for a
proxy and `address` for a monitor connection.

The mode is inferred when omitted: serial is a tap; TCP with only `address` is a
connect (read-only monitor); any other TCP source is a proxy, which then needs
`listen` and `target`.

## Sources and modes

| Source | Mode | Behaviour |
|---|---|---|
| `kind = "serial"` | `tap` | Dedicated listen-only adapter on the same bus. The tap path only reads; it never writes a byte. |
| `kind = "serial"` | `proxy` | Inline relay through a virtual COM pair. The sniffer opens `port` (its side) and `target` (real device); Prism opens `peer`. Bytes are forwarded unchanged in both directions. |
| `kind = "tcp"` | `proxy` | Transparent relay. Prism connects to `listen`; the sniffer connects to `target`, accepts several clients (one worker per connection) and logs both directions. |
| `kind = "tcp"` | `connect` | Read-only connection to a serial-gateway monitor port or a switch SPAN stream. Reconnects every `reconnect_ms`. |

A minimal passive serial tap:

```toml
[[source]]
name = "rs485-main"
kind = "serial"
mode = "tap"
protocol = "auto"     # auto | modbus-rtu | modbus-ascii | raw
port = "COM7"
baud = 19200
parity = "even"
idle_ms = "auto"      # derive the gap from the line speed and adapt
# data_bits, stop_bits and flow use their defaults
```

A TCP proxy in front of a Modbus TCP PLC:

```toml
[[source]]
name = "plc"
kind = "tcp"
mode = "proxy"
protocol = "auto"     # auto | modbus-tcp | s7 | opc-ua | mqtt | raw
listen = "127.0.0.1:1502"
target = "192.168.0.10:502"
```

A serial-gateway monitor connection:

```toml
[[source]]
name = "plc-monitor"
kind = "tcp"
mode = "connect"
protocol = "modbus-rtu"   # the gateway forwards serial bytes
address = "192.168.0.50:4001"
reconnect_ms = 2000
```

An inline serial relay through a virtual COM pair:

```toml
[[source]]
name = "com-inline"
kind = "serial"
mode = "proxy"
protocol = "auto"
port = "COM5"          # sniffer side of the virtual pair
target = "COM3"        # real device port
peer = "COM4"          # Prism opens this end (informational)
baud = 9600
parity = "none"
```

The virtual pair is created with a tool such as com0com (Windows) or socat
(Linux). Both ends must use the same line settings. This mode is not passive:
the sniffer is in the path, but Prism keeps working.

### Protocol detection

`protocol = "auto"` detects the protocol from frame signatures and from
well-known ports: 102 S7comm, 502 Modbus TCP, 1883/8883 MQTT, 4840 OPC UA. A
port hint is only a fallback when the first bytes are ambiguous.

A serial source can only auto-detect Modbus RTU/ASCII. For a serial gateway that
carries Modbus RTU/ASCII over TCP, set `protocol = "modbus-rtu"` or
`"modbus-ascii"` explicitly: the frame boundary there is the idle gap, not a
length field. MQTT is decoded on TCP proxy/connect streams; it is rejected on a
serial source. The sniffer never subscribes to a broker — it observes an
existing MQTT connection.

Decoded out of the box:

- **Modbus RTU/ASCII/TCP** — unit, function, addresses/counts, register and bit
  values, CRC-16/LRC, exceptions;
- **S7comm** — TPKT/COTP, setup communication, read/write variable with DB/area
  addresses, response data values, upload/download, PI services;
- **OPC UA** — HEL/ACK/OPN/MSG/CLO/ERR, the secure-channel envelope,
  Read/Write/Browse, CreateSession, subscriptions, monitored items, Publish,
  Call, ServiceFault and common DataValue variants (bodies of
  `SecurityPolicy#None`);
- **MQTT 3.1/3.1.1/5** — CONNECT/CONNACK, PUBLISH with topic/QoS/payload,
  SUBSCRIBE/SUBACK, acknowledgements, PING and DISCONNECT;
- unknown protocols as printable `text` or `raw` hex; MQTT over TLS and
  encrypted OPC UA are shown as TLS records/envelopes without decryption.

### Windows COM ports

Windows COM ports are exclusive-use: an already-open port cannot be read by a
second process, even read-only. Use a second RS-485 listen-only adapter, the
monitor port of a serial gateway (`mode = "connect"`), or the inline
virtual-pair relay (`mode = "proxy"`). If opening the port fails, the error
message lists these alternatives.

## Console output

Every event is one line:

```text
2026-11-19 14:02:31.412 [rs485-main] REQ modbus-rtu unit=1 read_holding addr=10 count=4 crc=ok
    raw 01 03 00 0A 00 04 64 0B
2026-11-19 14:02:31.425 [rs485-main] RSP modbus-rtu unit=1 read_holding bytes=8 regs=[42, 100, 7, 0] crc=ok
    raw 01 03 08 00 2A 00 64 00 07 00 00 ...
```

- The source name in brackets comes from `[[source]].name`.
- Direction labels are `REQ`/`RSP` for serial frames (inferred from the frame
  shape), `C>S`/`S>C` for proxy directions, `BUS` for a monitor stream where
  the side is unknown, and `SYS` for system messages.
- Warnings and errors are prefixed with `!`; colours highlight source,
  direction and protocol.
- The `raw` line appears when `hex = true` and the event has bytes. It is
  truncated to `hex_limit` bytes in the console and in text recordings; only
  JSONL keeps the full frame.

The tool prints a start line with its version, the number of selected sources
and the config path. Several sources run in parallel threads and every line
carries its source name.

## Recording

| Hotkey / flag | Action |
|---|---|
| `Ctrl+R` or `F2` | Start/stop a recording. |
| `F3` | Write a marker event to the console and to the active recording. |
| `Ctrl+C` | Stop the recording and exit with code 0. |
| `Ctrl+Q` | Same as Ctrl+C. |
| `--record` | Start a recording immediately. |
| `--record-jsonl` | Start immediately in JSONL; implies `--record` and overrides `[log] format`. |
| `--record-dir <dir>` | Override the recording folder; does not start a recording. |
| `--marker-file <file>` | Watch a file and turn every complete non-empty line into a marker. |
| `--no-hotkeys` | Do not capture Ctrl+R/F2/F3/Ctrl+C/Ctrl+Q. |

Hotkeys are captured only when stdin is a terminal and in raw mode. If stdin is
not a terminal, the sniffer logs `stdin is not a terminal; Ctrl+R disabled (use
--record)` and leaves the keys alone. The terminal is restored on Ctrl+C/Ctrl+Q
and on the normal exit path. With `--no-hotkeys`, a service manager controls
the process; recordings are flushed line by line, so an abrupt stop loses
nothing already written.

### Folder and file names

The folder comes from `[log] record_dir` (default `log`) or `--record-dir`.
Relative paths are resolved from the directory of the `prism-sniff` binary, so
the default is `log/` next to the tool. The folder is created on the first
recording.

Each session creates:

```text
sniff-YYYYMMDD-HHMMSS.log     # text
sniff-YYYYMMDD-HHMMSS.jsonl   # JSONL
```

The timestamp is local time. If a name already exists, a suffix `-1`, `-2`, …
is added.

### Text recordings

Text mode writes a header, then the same lines as the console without ANSI
colours, and a final stop line:

```text
# prism-sniff <version>
# started: 2026-11-19T14:02:31.400+01:00
# sources: rs485-main

2026-11-19 14:02:31.412 [rs485-main] REQ modbus-rtu unit=1 read_holding ...
...
# stopped: 2026-11-19T14:03:10.120+01:00
```

Every line is flushed immediately. Text recordings mirror the **visible**
console: frames hidden by `raw = false` are not included.

### JSONL recordings

JSONL is machine-readable. The first line is a meta record:

```json
{"meta":{"tool":"prism-sniff","version":"<version>","started":"2026-11-19T14:02:31.400+01:00","format":"jsonl","sources":["rs485-main"]}}
```

Then one event per line:

```json
{"t_ms":1234,"dir":"tx","bytes":"4D 50 4E 0D","note":"","source":"counter","protocol":"text","severity":"info","dir_label":"C>S"}
{"t_ms":1500,"dir":"note","bytes":"","note":"scenario=volume value=20","source":"marker","protocol":"marker","severity":"info","dir_label":"SYS"}
```

- `t_ms` is milliseconds since the recording started.
- `dir` is `tx` (PC→device), `rx` (device→PC, also used for a passive `BUS`
  stream) or `note` (system/marker).
- `bytes` is the complete raw frame as uppercase hex, without `hex_limit`.
- `note` carries the text of system and marker events; it is empty for normal
  frames.
- `source`, `protocol`, `severity` (`info`, `warn`, `error`) and `dir_label`
  keep the console context.
- JSONL captures every event, including frames hidden from the console by
  `raw = false`.
- Stopping a JSONL recording writes a final note event with
  `"note":"recording stopped"` and source `record`.

### Markers

Markers come from `F3` or from `--marker-file`. UI automation appends one line
per step, for example
`scenario=volume param=setpoint value=20 phase=before`, and each complete line
becomes a `note` event with `protocol = "marker"`.

- The marker file may not exist when the sniffer starts; it is polled every
  100 ms.
- Partial lines are buffered until the newline; blank lines are ignored.
- If the file is truncated or replaced, reading restarts from the beginning.
- Markers are printed to the console even when no recording is active, but only
  events that occur while a recording is active are written to the file.
- An `F3` marker uses source `hotkey`; a file marker uses source `marker`.

## Recipes

**Tap an RS-485 bus with a second adapter.** Use the `rs485-main` example above;
set `port` to the listen-only adapter. Leave `idle_ms` at `"auto"` so the gap
follows the baud rate and adapts to the chunk sizes the driver delivers.

**Decode a PLC connection without touching the PC configuration.** Put the TCP
proxy source in `sniff.toml`, point Prism at `127.0.0.1:1502` instead of the PLC
and leave the proxy's `target` at the real PLC endpoint. The sniffer logs both
directions while forwarding bytes unchanged.

**Use a gateway monitor port.** Use `mode = "connect"` with the gateway's
monitor `address`. Set `protocol = "modbus-rtu"` (or `modbus-ascii`) when the
gateway forwards serial bytes, because the frame boundary is the idle gap.

**Record a reproducible test run.** Start with
`--record-jsonl --marker-file steps.txt`, let the UI automation append one line
per step, then analyse the `.jsonl` file. Every marker is a `note` event between
the frames that belong to that step.

**Validate before a long run.** `--check-config` reports syntax and semantic
errors without opening any port, and `--list` shows the effective source name,
kind, mode, protocol and endpoint after `--source` filtering.
