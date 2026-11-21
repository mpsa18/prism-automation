# Prism 0.1.1 — creating a new instance

An **instance** is one self-contained project folder: the Prism binary, its
`config/`, `scripts/`, `plugins/`, `licensing/` and runtime `data/`/`logs/`.
Prism resolves these paths **relative to the binary**, so every project lives in
its own folder and several instances can run side by side.

```
my-project/
  prism(.exe)          core binary for this instance
  config/              project configuration (TOML only)
  scripts/             Rhai scripts and bindings.toml
  plugins/             WASM modules (device drivers, compute, ML, reports)
  licensing/           license.key and runtime license state
  devtools/            prism-sim, prism-dbg, prism-scan, prism-sniff, prism-devtools
  data/, logs/         runtime output
```

The release archive already contains a working empty instance in `prism/` and a
complete hardware-free example in `examples/tour/`.

## 1. Download the archive for your platform

| Platform | Archive |
|---|---|
| Windows 10/11 x86-64 | `prism-0.1.1-win.zip` |
| Linux x86-64 | `prism-0.1.1-linux.zip` |
| Linux ARM64 (Raspberry Pi, arm64 SBC) | `prism-0.1.1-linux-aarch64.zip` |
| Linux ARMv7 glibc (Ubuntu on Cortex-A7) | `prism-0.1.1-linux-armv7.zip` |
| Linux ARMv7 static musl (Buildroot/uclibc, Luckfox Pico) | `prism-0.1.1-linux-armv7-musl.zip` |
| macOS Apple Silicon | `prism-0.1.1-macos.zip` |
| macOS Intel | `prism-0.1.1-macos-x86_64.zip` |

Verify the archive with the release `SHA256SUMS` before unpacking.

## 2. Create the project folder

### Option A — copy the bundled empty instance (recommended)

The `prism/` folder in the archive is already a valid instance.

```bash
# Linux / macOS
cp -R prism my-project
cd my-project
```

```powershell
# Windows PowerShell
Copy-Item -Recurse prism my-project
cd my-project
```

### Option B — start from a bare folder

Copy the binary and `devtools/` into an empty folder and let Prism scaffold the
minimal configuration next to the binary:

```bash
mkdir my-project
cp prism.exe my-project/          # Linux/macOS: prism
cp -R devtools my-project/
cd my-project
./prism init                      # writes config/ with commented examples
```

`prism init` never overwrites existing files; it prints `[+] created` and
`[=] kept` for every path. On Windows use `.\prism.exe init`.

### Option C — scaffold a template project

`prism-devtools` can create a project skeleton with a chosen template
(`empty`, `minimal`, `standard`, `full`) and a project name:

```bash
devtools/tooling/prism-devtools init --project my-project --template standard --out my-project
cp prism.exe my-project/          # the scaffold contains config/scripts only
cp -R devtools my-project/
cd my-project
```

Available templates are documented in `docs/03_tooling/06_DEVTOOLS.md`. Use
`empty` for production, `standard` to get a working example with commented
sections.

## 3. First configuration

Open `config/00_core/00_app.toml` and set at least:

```toml
[system]
instance_name = "my-project"     # unique on this machine
locale        = "en"             # or "ru"

[logging]
level = "info"
file_enabled = true
file_path = "logs/prism.log"

[debug]
enabled = true
listen  = "127.0.0.1:7200"       # change for the second instance
```

`instance_name` is part of the run lock (hardware id + instance name): two
instances with the same name cannot run at the same time. Use a distinct name
and ports for every project.

Then validate and start:

```bash
./prism --check-config
./prism
```

Windows: `.\prism.exe --check-config`, then `.\prism.exe`.

The first start on a licensed edition opens the activation wizard; the
Community edition runs up to 128 active tags without a key. Put `license.key`
next to the binary or into `licensing/` (see
`docs/06_operations/01_LICENSING.md`).

## 4. Add devices, tags and northbound

Configuration is plain TOML under `config/`:

```
config/00_core/                  app, license, logging
config/01_southbound/
  01_modbus/                     Modbus TCP/RTU/ASCII devices
  02_s7comm/                     S7comm devices
  03_opc_client/                 OPC UA client devices
  04_virtual_tags/               virtual tags and tables
  05_alarms/                     alarm rules
  06_history/                    tag history
config/02_northbound/
  01_mqtt/                       MQTT contract and channels
  02_opc_server/                 OPC UA server
  03_opc_da_bridge/              OPC DA bridge (Windows)
  04_opc_client/                 OPC UA client generator workspace
config/03_wasm/
  01_source/                     WASM device drivers
  02_compute/                    compute blocks
  03_ml/                         ML inference
  04_report/                     report renderers
```

Ways to fill it:

- **By hand** — start with a device file from `docs/02_communication/01_DEVICES.md`
  and add `[[device.tag]]` entries.
- **Generators** — `devtools/tooling/prism-devtools generate mqtt|opc-client|opc-server|tags`
  writes the matching config from the current tag registry; `--dry-run` /
  `--check` show the result without touching files.
- **Scanner** — `devtools/scanner/prism-scan` discovers Modbus TCP devices and
  writes a device map (see `docs/03_tooling/04_SCANNER.md`).
- **Simulator** — `devtools/simulator/prism-sim` serves the configured Modbus
  devices without hardware; `devtools/debugger/prism-dbg` shows the live tag
  table, writes, forces and the log (see `docs/03_tooling/01_BENCH_TOOLS.md`).

Every change should be validated with `prism --check-config` before a restart.
Tag lists are loaded at start: after adding/removing tags press `r` + Enter in
`prism-dbg` or restart Prism.

## 5. Run without hardware

The archive contains `examples/tour/` — a complete project that runs as is.
Start the core, the simulated field and the debugger in three terminals:

```bash
cd examples/tour
./prism --check-config
./prism
```

```bash
cd examples/tour
./devtools/simulator/prism-sim
```

```bash
cd examples/tour
./devtools/debugger/prism-dbg
```

Use the same layout for your own project: `prism-sim` reads the Modbus devices
from `config/01_southbound/01_modbus/**`, and `prism-dbg` reads the simulator
profile from `devtools/simulator/sim.toml`.

## 6. Several instances on one machine

- Use a separate folder per project; never share `config/` or `data/`.
- Give each instance a unique `[system].instance_name`.
- Change `[debug].listen` (default `127.0.0.1:7200`) for every instance.
- Change the OPC UA server endpoint in
  `config/02_northbound/02_opc_server/**` if it is enabled.
- MQTT clients may share one broker; keep client ids/topics distinct.
- Runtime data (`logs/`, `data/`, `licensing/`, `.build.json`) is per instance.

## 7. Upgrading an instance

Keep the project data, replace the program:

1. Stop the instance.
2. Back up `config/`, `scripts/`, `plugins/` and `licensing/`.
3. Replace `prism(.exe)` and `devtools/` with the new release.
4. Compare your config with the new `config/` examples; do not overwrite your
   files blindly.
5. Run `prism --check-config`, then start the instance.

New tags, devices and northbound features are usually additive. Alarm and MQTT
behavior changes are listed in `CHANGELOG.md` in the release root.

## 8. Troubleshooting

| Symptom | Check |
|---|---|
| `Configuration validation error` | The message names the file and line; fix and run `--check-config` again |
| Instance does not start twice | `[system].instance_name` must be unique per machine |
| `Address already in use` | Another instance uses the debug port or the same OPC UA endpoint |
| Device stays offline | `prism-dbg` → tag quality/passport; serial port, host, unit id |
| No data in SCADA | MQTT topic/channel and broker, or OPC UA endpoint and node ids |
| `Tag limit exceeded` | Community edition counts active tags (128); remove tags or install a license |
| Nothing in the log file | `[logging].file_enabled` and `file_path`; the folder is created on start |
| License not found | `license.key` next to the binary or in `licensing/`; run `prism license` |

Further reading: `docs/01_getting_started/01_OVERVIEW.md`,
`docs/01_getting_started/03_APP_CONFIG.md`,
`docs/02_communication/01_DEVICES.md`,
`docs/03_tooling/01_BENCH_TOOLS.md`, `docs/03_tooling/06_DEVTOOLS.md`.
