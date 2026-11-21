# Prism 0.1.1 — getting started

This is a ready-to-use bundle. Nothing needs to be installed: every program is
already built and sits next to this file. There are three entry points, from
the simplest to the most advanced.

## What is where

```text
prism-win/
├── README-RU.md — this guide in Russian
├── README-EN.md — this guide in English
├── LICENSE — the Prism Community edition license
├── THIRD_PARTY_NOTICES.md — third-party license texts
├── SHA256SUMS — checksums of every shipped file
├── docs/ — user guides (English)
├── examples/tour/ — a complete project that runs without hardware
└── prism/ — the platform working folder (instance)
    ├── prism.exe — the main program
    ├── config/ — devices, tags, MQTT, OPC UA
    ├── scripts/ — Rhai scripts
    └── devtools/ — scanner, sniffer, configurator, simulator, debugger
```

`prism/` is the instance. You can rename it or copy it as a whole; every path in
the configuration is resolved from this folder.

Verify the bundle with `SHA256SUMS`: on Linux/macOS run
`sha256sum -c SHA256SUMS` (on macOS `shasum -a 256 -c SHA256SUMS`), in Git Bash
on Windows the same `sha256sum -c SHA256SUMS` works.

## 1. Network and address analysis tools

The simplest entry point. No project setup is needed and the equipment is
polled read-only.

### Address scanner — `prism-scan`

`prism-scan` (in `prism/devtools/scanner/`) walks addresses and ports, shows
which devices answer, which registers are readable and which data types they
hold. It can turn the result into a starting Prism configuration.

```text
cd prism
.\devtools\scanner\prism-scan.exe --init      # write scan.toml next to the program
.\devtools\scanner\prism-scan.exe             # run the scan plan
```

`scan.toml` is a plain text file: address ranges, ports, unit ids and what to
read. Every field is described in comments.

### Sniffer — `prism-sniff`

`prism-sniff` (in `prism/devtools/sniffer/`) passively listens to a bus or port
and shows Modbus, S7comm, OPC UA and MQTT frames. It never writes to the
equipment; it can record a log and place markers.

```text
cd prism
.\devtools\sniffer\prism-sniff.exe --init     # write sniff.toml
.\devtools\sniffer\prism-sniff.exe            # run the sniffer
```

More: `docs/03_tooling/01_BENCH_TOOLS.md`, `docs/03_tooling/04_SCANNER.md` and
`docs/03_tooling/05_SNIFFER.md`. Configurator: `docs/03_tooling/06_DEVTOOLS.md`.

## 2. Equipment configurator — `prism-devtools`

`prism-devtools` (in `prism/devtools/tooling/`) is the configuration tool. It
removes manual copy-paste:

- `init` — create a whole project (`empty`, `minimal`, `standard`, `full`);
- `scaffold` — add one device, tag, virtual tag, alarm, history entry, script
  or poll;
- `generate tags` — generate a batch of tags from a pattern: addresses, types,
  scales, `full`/`delta`/`annotated` modes, `--draft` for a disabled draft;
- `generate mqtt` — build `tags.toml`, channels and payload templates;
- `generate opc-server` / `generate opc-client` — OPC UA nodes and endpoints;
- `import inventory` and `inventory export` — exchange tag lists as TOML/CSV:
  between projects and into a report for engineers;
- `validate rhai` — check scripts before start;
- `trim mqtt` — remove rules for tags that no longer exist.

The key point: generated TOML files contain comments with every available
option, not only the ones you chose. They stay editable without memorising the
schema.

```text
cd prism
.\devtools\tooling\prism-devtools.exe --help
.\devtools\tooling\prism-devtools.exe scaffold --help
.\devtools\tooling\prism-devtools.exe generate tags --help
```

More: `docs/03_tooling/06_DEVTOOLS.md`.

## 3. Platform — `prism`

### Set the instance name first

Open `prism/config/00_core/00_app.toml` and set:

```toml
[system]
instance_name = "stand-01"
```

Do this **before the first start**. The name appears in logs, MQTT statuses,
the instance lock, the debug API and the license. It can be changed later, but
then every place that uses it must be updated. If you leave `prism`, every
unpacked copy looks identical.

### Check and start

```text
cd prism
.\prism.exe --check-config
.\prism.exe
```

`--check-config` validates syntax, required fields, addresses and tag
references and starts nothing. A healthy configuration ends with
`Configuration OK`.

### The debugger is the main troubleshooting tool

`prism-dbg` (in `prism/devtools/debugger/`) shows live tags with quality and
timestamps, lets you write and read values, force/freeze them, inspect logs,
diagnostics, the alarm journal and confirm a configuration reload.

**If something does not work, open the debugger first.** It shows whether a
value arrives from the device, with what quality, and what the platform sees —
instead of reading logs at random.

```text
cd prism
.\devtools\debugger\prism-dbg.exe
```

### Without hardware

`prism-sim` (in `prism/devtools/simulator/`) replaces real devices: it reads
addresses and register maps from `config/` and serves Modbus/OPC UA where the
platform expects them. In a terminal the command opens the panel; without a
terminal (service, CI) it serves the devices headlessly.

```text
cd prism
.\devtools\simulator\prism-sim.exe
```

## Quick start on the ready example

`examples/tour/` contains a complete project: Modbus, virtual tags,
alarms, history, MQTT, OPC UA and Rhai. It needs no hardware and changes
nothing outside its folder.

```text
cd examples/tour

# terminal 1: simulated field
.\devtools\simulator\prism-sim.exe

# terminal 2
.\prism.exe --check-config
.\prism.exe

# terminal 3: live tag tree
.\devtools\debugger\prism-dbg.exe
```

What to try: raise `setpoint`, watch the temperature, trip the alarm, inspect
MQTT and OPC UA. Details in `examples/tour/README.md`.

## Licensing

This is Prism Community edition: up to **128 active tags** per instance without
a license file. Above the limit a 60-minute demo window runs; commercial keys
are not sold yet. Details: `docs/06_operations/01_LICENSING.md`.

## Documentation

Start with `docs/01_getting_started/01_OVERVIEW.md`. Then pick by task:

- `docs/02_communication/01_DEVICES.md` — protocols and tags;
- `docs/04_logic/02_ALARMS.md` — alarms;
- `docs/04_logic/01_RHAI.md` — scripts and virtual tags;
- `docs/02_communication/02_MQTT.md` and `docs/02_communication/03_OPC_UA.md` — northbound;
- `docs/03_tooling/01_BENCH_TOOLS.md` — the whole toolset and debugging without hardware;
- `docs/03_tooling/06_DEVTOOLS.md` — the configurator: generators, scaffold, import.

The guides in `docs/` are in English.
