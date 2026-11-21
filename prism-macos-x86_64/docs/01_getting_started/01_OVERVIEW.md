# Getting Started

Prism is a program that connects industrial equipment to the systems above it.

It reads values from controllers, meters and sensors (**southbound**), keeps
them in one list of named values called **tags**, and passes those values on to
SCADA, MQTT, OPC UA or your own scripts (**northbound**). Everything is set up
with plain text files. There is no installer, no database and no programming
required for a normal project.

| What you want | What Prism does |
|---|---|
| Read a PLC or a meter | Modbus TCP/RTU/ASCII, S7comm, OPC UA client devices |
| Collect all values in one place | one tag registry with value, quality and timestamp for every tag |
| Show values in SCADA | MQTT channels or an OPC UA server |
| Calculate or transform values | virtual tags and small Rhai scripts |
| Raise and record alarms | declarative alarm rules, alarm journal and MQTT events |
| Connect custom logic | WASM modules for drivers, computation, ML and reports |

Prism is **not** a SCADA screen builder: the operator interface is a separate
program that reads Prism over MQTT, OPC UA or a WASM module. Prism is also not a
library: you run it as a program and configure it with files.

> The documentation uses one running example: a liquid filtration test stand
> with a Modbus TCP controller, virtual tags, MQTT telemetry and an OPC UA
> gateway. Every chapter adds another piece to the same project.

---

## 1. Before you start

You need:

- a folder for the project (called an **instance** in this documentation);
- the Prism program for your operating system;
- for most projects: the IP addresses and register maps of the field devices,
  or the serial port settings;
- Administrator rights on Windows, or `sudo` on Linux/macOS, only if you want
  Prism to run as a background service.

A license is **not** required to start. Prism Community edition works with up
to **128 tags** and starts without an activation prompt. Above that limit it
gives a 60-minute demo window and then waits for a license; the wizard is also
offered when an existing license file is rejected — see
[`06_operations/01_LICENSING.md`](../06_operations/01_LICENSING.md).

> **What is a tag?** A tag is one named value, for example
> `io_controller.oil_temp`. The part before the dot is the device, the part
> after it is the value name. Every tag also has a quality (good, bad,
> uncertain, uninitialized) and a timestamp.

### 1.1 Name the instance before the first start

An **instance** is one project folder: the program, its `config/`, scripts,
data and logs. The instance has a name that identifies it.

Open `config/00_core/00_app.toml` and set it first:

```toml
[system]
instance_name = "stand-01"
```

Use a short, unique name (`stand-01`, `line-2`, `boiler-room`). Do this **before
the first start**, because the name is used in several places at once:

- it appears in logs and runtime messages, so two projects are distinguishable;
- it is published in MQTT status and shown by the debugger;
- the inter-process lock tells instances apart by hardware id **plus** instance
  name, so two copies with the same name behave like one instance;
- the license request records it; after a rename the request must be repeated.

Renaming later is possible, but then every external system that keys on the name
must be updated too. If you leave the default `prism`, every unpacked copy of
the release looks the same.

> **Where is the instance in the release pack?** The pack contains the platform
> in `prism/`, a ready project in `examples/tour/` and these guides in `docs/`.
> All paths in this chapter are relative to the instance folder — in the pack
> that is `prism/`.

---

## 2. First start

Start the program from the instance folder. In the release pack that is the
`prism/` folder:

- **Windows:** open a command prompt in `prism\`, then run `prism.exe` (or
  double-click it in Explorer).
- **Linux / macOS:** `cd prism` and run `./prism` in a terminal.

On the **first start** Prism creates the starting configuration and the full
folder structure, prints what it created, and then starts working. Nothing is
downloaded and no other program is needed.

You can do the same step explicitly, without starting the runtime:

```bash
prism init
```

`prism init` only writes what is missing. It never overwrites your files, so it
is safe to run again at any time. On a fresh folder it creates:

- `config/00_core/00_app.toml` — the main settings file;
- `config/01_southbound/04_virtual_tags/defaults.toml` — defaults for
  calculated tags;
- all `config/` folders of the numbered layout (section 3);
- `scripts/`, `plugins/`, `user/`, `data/`, `logs/`, `licensing/` (with
  `licensing/addons/`) and `devtools/`.

Expect output like this:

```text
Prism init: instance 'stand-01' in C:\prism\stand-01
  [+] created C:\prism\stand-01\config
  [+] created C:\prism\stand-01\config\00_core
  ...
  [+] created C:\prism\stand-01\config\00_core\00_app.toml
Done. Next: `prism --check-config`, then `prism`.
```

---

## 3. What is inside the folder

```text
stand-01/
├── prism.exe                 the program (prism on Linux/macOS)
├── config/                   all settings, text files only
│   ├── 00_core/
│   │   └── 00_app.toml       identity, logging, license paths, debug API
│   ├── 01_southbound/        what Prism reads: devices and their tags
│   │   ├── 01_modbus/        Modbus TCP / RTU / ASCII devices
│   │   ├── 02_s7comm/        Siemens S7 PLCs
│   │   ├── 03_opc_client/    external OPC UA servers Prism reads
│   │   ├── 04_virtual_tags/  calculated and scratch-pad tags
│   │   ├── 05_alarms/        alarm rules
│   │   └── 06_history/       history buffers for tags
│   ├── 02_northbound/        what Prism offers to other systems
│   │   ├── 01_mqtt/          broker, channels and payload templates
│   │   ├── 02_opc_server/    Prism as an OPC UA server
│   │   ├── 03_opc_da_bridge/ classic OPC DA bridge (Windows)
│   │   └── 04_opc_client/    generator workspace for OPC UA client endpoints
│   └── 03_wasm/              optional extension modules
│       ├── 01_source/        modules that own devices and their tags
│       ├── 02_compute/       modules that calculate over existing tags
│       ├── 03_ml/            machine-learning modules
│       └── 04_report/        document/report renderers
├── scripts/                  Rhai scripts and bindings.toml
├── plugins/                  WASM module files
├── user/                     your own files; Prism never reads this folder
├── data/                     runtime reports, alarm journal, generated state
├── logs/                     log files
├── licensing/                license.key and license state
└── devtools/                 helper programs (simulator, debugger, tools)
```

The numbered groups read in layers:

- **00 — system:** settings of the program itself;
- **01 — field:** what is controlled or measured; the source of truth for tags;
- **02 — outward:** what other systems see;
- **03 — computation:** optional WASM modules.

A reports folder `config/03_wasm/04_report/` is created with the skeleton; add
a module there when you configure reports (see
[`05_wasm/04_REPORTS.md`](../05_wasm/04_REPORTS.md)).

**Disabling without deleting.** A file or folder whose name starts with `#` is
ignored completely. To switch off a device module temporarily, rename its folder
from `pump2` to `#pump2`. Names starting with `.` are ignored too.

**TOML files.** A configuration file is ordinary text:

```toml
[section]          # a section groups related settings
key = "text"       # text value
number = 10        # integer
flag = true        # yes/no
```

Edit it with Notepad, Notepad++ or any other text editor. Keep the file inside
`config/`: Prism reads every `.toml` file below that folder on start.

### 3.1 The tooling that removes the pain

The release ships `devtools/tooling/prism-devtools` (`.exe` on Windows). It is
not needed to run Prism, but it removes the most tedious part of a project:

- **Dozens of similar tags copied by hand.** `generate tags --count N` writes a
  batch with addresses, types, scales and access modes. The `full`, `delta` and
  `annotated` modes decide how much is spelled out, so a tag can be as short as
  "address 10, holding, word" or contain every available key as a reference.
- **MQTT topics, payloads and routing kept in sync.** `generate mqtt` writes
  `tags.toml` and describes the channels and payload templates.
- **OPC UA node lists maintained separately.** `generate opc-server` writes
  `nodes.toml`; `generate opc-client` writes `endpoints.toml`.
- **One more device, alarm, script or poll.** `scaffold <entity>` adds a single
  block in the right folder instead of editing a large file by hand.
- **A broken script found only at runtime.** `validate rhai` checks syntax and
  function references before start.
- **A tag list for a colleague or a SCADA engineer.** `inventory export` writes a
  filtered CSV/TSV/JSON report; `import inventory` rebuilds tag files from a
  TOML/CSV list.
- **MQTT rules that point to removed tags.** `trim mqtt` reports them and can
  remove them.
- **A new project from nothing.** `init` offers four starting presets: `empty`,
  `minimal`, `standard` and `full`.

Two details make the tooling safe to use every day:

- generated tag files and the generator templates contain **comments with the
  available options**, not only the chosen ones, so the file stays editable
  without knowing the schema;
- generation is guarded: an existing hand-edited file is not overwritten by
  accident (`--check`, `--dry-run`, `--existing skip`).

Run `prism-devtools --help` for the command list; every command has its own
`--help`. The configurator is described in
[`03_tooling/06_DEVTOOLS.md`](../03_tooling/06_DEVTOOLS.md); the other bench
tools are in [`03_tooling/01_BENCH_TOOLS.md`](../03_tooling/01_BENCH_TOOLS.md).

---

## 4. Check the configuration

Before connecting equipment, validate the files:

```bash
prism --check-config
```

Prism checks the file syntax, required fields, register addresses and tag
references, prints a short summary, then exits without starting the runtime.
A healthy configuration ends with:

```text
Configuration OK
```

If something is wrong, the last line explains the problem, for example:

```text
Configuration validation error: invalid TOML in config/01_southbound/01_modbus/stand/plc.toml: ...
```

Fix the file and run the check again. On an empty folder the check writes the
starting configuration first (the same action as `prism init`), then validates
it.

---

## 5. Start Prism

```bash
prism                 # normal start
prism --verbose       # same, with detailed log messages for troubleshooting
```

On Windows, `prism --hide-console` (or `--no-console`) hides the console window;
this is useful when the program is started automatically. Stop the program with
`Ctrl+C` in the console, or by stopping the service (section 6).

While Prism runs it watches its configuration. Scripts and most device settings
are reloaded automatically; changes that add or remove tags need a **full
reload**. In the console the reload plan is confirmed with `y`/`n`; in the
debugger panel the same actions are available. See
[`04_logic/01_RHAI.md`](../04_logic/01_RHAI.md) §6
and [`03_tooling/01_BENCH_TOOLS.md`](../03_tooling/01_BENCH_TOOLS.md).

Logs are written to `logs/prism.log`. The alarm journal is `data/alarms.csv`.

### 5.1 The debugger is the first tool to open

`devtools/debugger/prism-dbg` (`.exe` on Windows) is the most important
troubleshooting tool. Run it without arguments to open the interactive panel:

```text
# Windows (from the instance folder)
devtools\debugger\prism-dbg.exe

# Linux / macOS
./devtools/debugger/prism-dbg
```

It reads the same configuration as the platform and, when the platform is
running, its local debug API. The panel shows:

- every tag with its value, quality and timestamp — so you can see whether a
  device value actually arrives and when it was last updated;
- writes, `force` and `freeze` — to test a logic branch without waiting for the
  field device;
- logs and diagnostics next to the tag tree, without switching windows;
- the alarm journal and the pending reload plan — the same `y`/`n` confirmation
  as in the console.

If a device stays offline, open the debugger **before** reading log files: the
tag passport tells you whether the tag exists, whether it is bound to the right
register and what quality the last read produced. If a value is wrong, `watch`
it or freeze it and compare the behaviour. The panel also opens without a
running platform (catalog mode) and lists the tags and alarms declared in
`config/**`.

More: [`03_tooling/01_BENCH_TOOLS.md`](../03_tooling/01_BENCH_TOOLS.md) and
[`03_tooling/03_DEBUGGER.md`](../03_tooling/03_DEBUGGER.md).

---

## 6. Run as a service

A service starts with the operating system and restarts after a failure. The
commands are built into the program, so no separate installer is needed.

**Windows** (run the command prompt as Administrator):

```cmd
prism.exe service install
prism.exe service start
```

**Linux / macOS** (with `sudo`):

```bash
sudo ./prism service install
sudo ./prism service start
```

The full set of commands is the same on every platform:

```bash
prism service install     # register the service (admin/sudo)
prism service start       # start it
prism service stop        # stop it gracefully
prism service status      # show the current state
prism service uninstall   # stop and remove it completely
```

`service status` exits with code 0 when the service is running, 3 when it is
not running (or not installed), and 1 when the system query itself failed. This
makes it usable in monitoring scripts.

On Linux the service is a `systemd` unit, on macOS a `launchd` agent, on
Windows a service named `PrismCoreService`.

---

## 7. Command reference

| Command | What it does |
|---|---|
| `prism` | start the runtime |
| `prism --check-config` | validate the configuration and exit |
| `prism --verbose` | start with detailed logging |
| `prism --hide-console` / `--no-console` | hide the Windows console window |
| `prism init` | write the starting files and folders, do not start |
| `prism activate` / `--activate` | open the license activation helper |
| `prism license status` | show the license state, limits and binding |
| `prism license request` | create a license request file to send to the vendor |
| `prism --print-hwid` | print the machine fingerprint used for licensing |
| `prism serial list` | list serial ports and how the configuration matches them |
| `prism service install` / `start` / `stop` / `status` / `uninstall` | background service control |

There is no `prism --help`; this table and the numbered chapters are the
reference. Helper programs in `devtools/` have their own `--help`; see
[`03_tooling/01_BENCH_TOOLS.md`](../03_tooling/01_BENCH_TOOLS.md).

---

## 8. Key terms

| Term | Meaning |
|---|---|
| **Instance** | one project folder: the program, its `config/`, scripts, data and logs |
| **Tag** | one named value, `device.name`, with value, quality and timestamp |
| **Device** | one controller, meter or module in `config/01_southbound/`; owns its tags |
| **Southbound** | the field side: Prism reads from devices and writes commands to them |
| **Northbound** | the upper side: MQTT, OPC UA, OPC DA and reports |
| **Register** | a numbered memory cell in a Modbus device (holding, input, coil, discrete) |
| **Poll cycle** | how often Prism reads a device or recalculates a virtual tag |
| **Quality** | how much a value can be trusted: good, bad, uncertain, uninitialized |
| **TOML** | the text format of all configuration files |
| **Virtual tag** | a tag calculated by Prism itself (expression or script) |
| **WASM module** | an optional compiled extension for custom drivers, math, ML or reports |
| **Service tag** | a built-in `system.*` tag for control and status; not counted by the license |

---

## 9. If something goes wrong

| Symptom | What to check |
|---|---|
| `Configuration validation error` | read the file and line in the message; run `prism --check-config` again after the fix |
| `Address already in use` on start | another Prism or another program already uses the port; stop it or change the listen address |
| A device stays offline | open `prism-dbg` first and read the tag passport and quality; then check address, port, unit id and register map (`03_tooling/01_BENCH_TOOLS.md`) |
| A value is wrong or jumps | open `prism-dbg`, `watch` the tag (or `force` a test value), then check scaling and the device map |
| No data in SCADA | MQTT broker address and channel topics (`02_communication/02_MQTT.md`); OPC UA endpoint (`02_communication/03_OPC_UA.md`) |
| `Tag limit exceeded` / demo countdown | the project uses more tags than the license allows; see `06_operations/01_LICENSING.md` |
| Service does not start | install/start the service as Administrator or with `sudo`; check `prism service status` |
| Nothing in the log file | check `[logging] file_enabled` and `file_path` in `config/00_core/00_app.toml` |

---

## 10. Where to go next

1. [`01_getting_started/02_ARCHITECTURE.md`](02_ARCHITECTURE.md) — how the parts fit together.
2. [`03_tooling/01_BENCH_TOOLS.md`](../03_tooling/01_BENCH_TOOLS.md) — run, inspect and debug a project without hardware.
3. [`01_getting_started/03_APP_CONFIG.md`](03_APP_CONFIG.md) — every setting in `00_app.toml`.
4. [`02_communication/01_DEVICES.md`](../02_communication/01_DEVICES.md) — field protocols and tag fields.
5. [`04_logic/02_ALARMS.md`](../04_logic/02_ALARMS.md) — alarm rules, acknowledgement, journal.
6. [`04_logic/01_RHAI.md`](../04_logic/01_RHAI.md) — calculated tags and logic.
7. [`02_communication/02_MQTT.md`](../02_communication/02_MQTT.md) and [`02_communication/03_OPC_UA.md`](../02_communication/03_OPC_UA.md) — northbound interfaces.
8. [`06_operations/01_LICENSING.md`](../06_operations/01_LICENSING.md), [`06_operations/02_LINUX_DEPLOYMENT.md`](../06_operations/02_LINUX_DEPLOYMENT.md), [`06_operations/03_MACOS_DEPLOYMENT.md`](../06_operations/03_MACOS_DEPLOYMENT.md) — licensing and production deployment.
