# Prism

> [!NOTE]
> **Early Development Preview:** Prism is in active early development. This release includes a **128-tag limit per instance** so you can evaluate the platform, test the bench tools, and share feedback before commercial tiers are introduced.

Prism is an industrial automation gateway. It reads equipment over Modbus,
S7comm, OPC UA and serial protocols, keeps every value in one tag registry,
and exposes it to SCADA and IT systems over MQTT, OPC UA, Sparkplug B,
SQL and Rhai scripts. Configuration is plain TOML: no installer, no database.

Logic that outgrows TOML and Rhai runs as sandboxed **WebAssembly components**:
custom device drivers, compute blocks, ML inference and report renderers.

## Download

Latest release: https://github.com/mpsa18/prism-automation/releases/latest

| OS | Archive | Architecture |
|---|---|---|
| Windows 10/11 | `prism-<version>-win.zip` | x86-64 |
| Linux | `prism-<version>-linux.zip` | x86-64 |
| macOS | `prism-<version>-macos.zip` | Apple Silicon (arm64) |

Every release ships `SHA256SUMS`.

```bash
# Linux / macOS
sha256sum -c SHA256SUMS
```

```powershell
# Windows PowerShell
Get-FileHash .\prism-<version>-win.zip -Algorithm SHA256
```

The repository also contains the unpacked trees (`prism-win/`, `prism-linux/`,
`prism-macos/`); the archives in Releases are the recommended download.

## Quick start

1. Unpack the archive.
2. Open `prism/config/00_core/00_app.toml` and set `instance_name`.
3. Validate and start:

```bash
cd prism
./prism --check-config
./prism
```

Windows:

```powershell
cd prism
.\prism.exe --check-config
.\prism.exe
```

No hardware? Run the bundled example:

```bash
cd examples/tour
./prism --check-config
./prism
```

and start the simulated field and debugger from two more terminals:

```bash
./devtools/simulator/prism-sim
./devtools/debugger/prism-dbg
```

## What is inside

```text
prism/                 working instance: core binary, config, scripts, devtools, plugins
examples/tour/         complete project that runs without hardware
docs/                  user guides
LICENSE                Prism Community edition license
THIRD_PARTY_NOTICES.md third-party license texts
SHA256SUMS             archive checksums
```

`prism/devtools/` contains `prism-sim`, `prism-dbg`, `prism-scan`,
`prism-sniff` and `prism-devtools`.

## Three entry points

- **Network and address analysis** — `prism-scan` and `prism-sniff` discover
  devices and observe bus traffic without writing to equipment.
- **Equipment configurator** — `prism-devtools` scaffolds projects, tags,
  alarms and northbound configuration.
- **Platform** — `prism` reads the field, evaluates scripts, runs WASM modules,
  raises alarms and serves MQTT / OPC UA.

## WASM: custom logic in a sandbox

Prism runs WebAssembly components on Wasmtime with the Component Model.
A module implements a WIT contract, so it can be written in Rust or any other
language with Component Model support. The core keeps ownership of the
dangerous parts: ports, sockets, files, the tag registry and licensing.

Four kinds of modules exist:

| Kind | ABI | What it owns | Config folder | Typical use |
|---|---|---|---|---|
| Device driver (`source`) | `prism:device@0.1` | devices and their tags; the core opens the serial port | `config/03_wasm/01_source/<module>/` | text protocols, checksums, line parsers, custom instruments |
| Compute | `prism:compute@0.2` | no tags of its own; reads and writes assigned tags | `config/03_wasm/02_compute/<module>/` | Kalman/FFT, soft sensors, calibration, MPC, SCADA logic |
| ML inference | `prism:ml@0.1` | no tags; receives a feature vector, returns outputs | `config/03_wasm/03_ml/<module>/` | ONNX models with Tract, anomaly detection |
| Report | `prism:report@0.1` | no tag, filesystem or network access | `config/03_wasm/04_report/<module>/` | XLSX protocol and shift reports |

Important properties:

- **Sandboxed.** Compute, ML and report modules have no filesystem or network
  access; the only host import is `host.log`. A device driver gets exactly one
  channel to the port already opened by the core and cannot open anything else.
- **Resource-limited.** Fuel, memory limits and an epoch watchdog stop runaway
  modules. Compute blocks have their own thread and period and do not block
  device polling.
- **No black boxes.** Inputs, outputs, parameters and devices are declared in
  the module TOML. A module sees only the tags and the device assigned to it.
- **Versioned separately.** A `.wasm` artifact and an ML model are ordinary
  files. Replacing them does not require rebuilding or restarting Prism;
  hot reloads are confirmation-gated.
- **ML is asynchronous by construction.** Inference runs off the control loop;
  it is not used as a synchronous controller.
- **Reports are data-first.** The core reads the tags named in the config and
  assembles the document; the WASM renderer only produces the XLSX bytes,
  written under `data/reports/`.

Rule of thumb: light logic, interlocks and computed tags belong in Rhai; heavy
processing or logic that must be a versioned artifact belongs in a WASM module.

The release ships `plugins/` and commented examples under `config/03_wasm/`.
`prism-devtools ml new <name>` scaffolds an ML plugin; `prism-devtools scaffold
device --protocol wasm` creates a device-plugin module. A device driver and a
compute block that need each other are two modules linked through the tag
registry — the driver owns tags, the compute block consumes them.

## Documentation

Start with `docs/01_getting_started/01_OVERVIEW.md`.

- Bench tools: `docs/03_tooling/01_BENCH_TOOLS.md`
- Configurator: `docs/03_tooling/06_DEVTOOLS.md`
- WASM compute modules: `docs/05_wasm/01_PLUGIN_SDK.md`
- WASM device drivers: `docs/05_wasm/02_DEVICE_DRIVERS.md`
- ML inference: `docs/05_wasm/03_ML.md`
- Excel reports: `docs/05_wasm/04_REPORTS.md`
- ADRC control module: `docs/05_wasm/05_ADRC.md`

The guides are in English; the release also contains `README-RU.md`.

## Licensing

Prism Community edition is free for up to **128 active tags per instance**
without a license file. Above that limit a 60-minute demo window runs.
Commercial keys are not sold yet. Details: `docs/06_operations/01_LICENSING.md`.

Device-plugin tags count toward the instance tag limit like any other device;
compute, ML and report modules do not add tags of their own.

## Releases

Each `v*` tag builds Windows, Linux and macOS archives and publishes them here.
This repository contains release artifacts only; the source code is private.
