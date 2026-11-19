# Bench tools: overview

Five helper programs ship in every project folder. They let you run, inspect and
test a project **without real equipment**: the simulator imitates field devices,
the debugger shows and changes values, the scanner discovers devices, the sniffer
records bus traffic, and the configurator creates and checks configuration
files. All of them read the same `config/**` as the main program, so there is
nothing extra to keep in sync.

> **In the release pack** the project folder is `prism/`, next to `examples/` and
> `docs/`. All `devtools/...` paths below are relative to `prism/`.

| Binary | What it does | How it starts | Details |
|---|---|---|---|
| `prism-sim` | Simulated field: process image, physics, Modbus/OPC UA servers | **In a terminal: interactive panel.** Without a terminal (service, CI): serves headlessly. `check`, `run`, `tui` are optional. | [`02_SIMULATOR.md`](02_SIMULATOR.md) |
| `prism-dbg` | Debugger: live tags, writes, force/freeze, Modbus access | **No arguments: interactive panel** (a terminal is required). Headless `control`, `watch`, `tags`, `modbus` for scripts. | [`03_DEBUGGER.md`](03_DEBUGGER.md) |
| `prism-scan` | Read-only field discovery and config generation | **A `scan.toml` plan** (found automatically or passed with `--config`). No interactive mode. | [`04_SCANNER.md`](04_SCANNER.md) |
| `prism-sniff` | Passive bus sniffer and transparent relay | **A `sniff.toml` config**; a line console with Ctrl+R/F2/F3 hotkeys. No full-screen UI. | [`05_SNIFFER.md`](05_SNIFFER.md) |
| `prism-devtools` | Configurator: validate, generate, scaffold, import, inventory, migrate | **A CLI command**; `init`, `scaffold`, `generate …`, `import inventory`, `inventory …`, `validate rhai`, `migrate layout`. | [`06_DEVTOOLS.md`](06_DEVTOOLS.md) |

Every tool has its own `--help`. Only `prism-sim` and `prism-dbg` are
full-screen applications; `prism-scan`, `prism-sniff` and `prism-devtools`
print ordinary lines and can run in a service or CI.

## What ships and where it lives

```text
<project>/
  prism(.exe)                         # the main program
  config/                             # devices, tags, northbound, scripts
  devtools/
    simulator/
      prism-sim(.exe)
      sim.toml                        # bench settings: physics, pacing, Control API
    debugger/
      prism-dbg(.exe)                 # reads simulator/sim.toml by default
    scanner/
      prism-scan(.exe)
      scan.toml                       # discovery/generation plan
    sniffer/
      prism-sniff(.exe)
      sniff.toml                      # sources, protocols, recording
    tooling/
      prism-devtools(.exe)
      generators/                     # generator config templates
        mqtt.toml  opc_client.toml  opc_server.toml  tags.toml
```

- The helpers arrive ready to run; there is nothing to build or install. On
  Linux and macOS the `.exe` suffix is omitted.
- `sim.toml`, `scan.toml` and `sniff.toml` are starting files next to the tool
  that owns them. The release pack ships all three. In a project created by
  `prism-devtools init`, only `sim.toml` exists; run `prism-scan --init` and
  `prism-sniff --init` once to write the other two. **No tool creates a config
  on its own** and none overwrites an existing file without `--force`.
- `devtools/tooling/generators/` is written by `init` and shipped in the release
  pack, so `generate mqtt`, `generate opc-client`, `generate opc-server` and
  `generate tags` work without creating a config by hand.
- **Single source of truth: `config/**`.** The simulator and the debugger read
  the tag universe, register maps, declared types, initial values and device
  addresses from it. There is no generated copy to refresh.
- **The tools find their instance themselves**: from an explicit flag
  (`--config`, `--sim`, `--root`), the current directory or its ancestors, or
  the executable location (`<root>/devtools/<tool>/prism-*`).
- `prism-dbg --device <name>` resolves the Modbus device folder
  `config/01_southbound/01_modbus/<name>` for its transport, `host:port` and
  unit id. `--modbus <host:port>` bypasses the config entirely.

## Quick start without hardware

Terminal 1 — simulated field. With a terminal it opens the panel; close the
panel or run it as a service to serve headlessly:

```bash
cd prism
devtools/simulator/prism-sim
```

Terminal 2 — validate and start the core:

```bash
cd prism
./prism --check-config
./prism
```

Terminal 3 — inspect live values:

```bash
cd prism
devtools/debugger/prism-dbg
```

Useful non-interactive checks:

```bash
devtools/simulator/prism-sim check      # validate the simulated field, no ports
devtools/debugger/prism-dbg tags        # print the config tag universe
devtools/scanner/prism-scan --dry-run   # validate a scan plan without connecting
```

## Exit codes

| Tool | `0` | `1` | `2` |
|---|---|---|---|
| `prism-sim` | success / valid config | `check` found errors | usage or internal error |
| `prism-dbg` | success | command failed (API or Modbus exception) | usage or transport error |
| `prism-scan` | success (also: nothing found) | report/generation error | usage or plan/config error |
| `prism-sniff` | normal exit (also: some sources failed) | every selected source failed | usage or config error |
| `prism-devtools` | success / `--check` clean | findings, drift, failed check | usage or load error |

## Which tool for which job

| Task | Tool |
|---|---|
| Run a project with no hardware | `prism-sim` |
| See why a device is offline, force a test value, read raw Modbus | `prism-dbg` |
| Find devices, unit ids and register maps before writing config | `prism-scan` |
| Watch or record traffic on a live bus | `prism-sniff` |
| Create tags, a device, an alarm, northbound config or a whole project | `prism-devtools` |

## If something does not work

| Symptom | What to check |
|---|---|
| `cannot bind <ip:port> for device …` | The machine does not own the device address: assign it, or override the endpoint for a single-device stand with `[modbus] listen` in the bench file. |
| The core shows a device OFFLINE | The simulator is not running, serves a different address, or uses a different unit id. |
| `control api … offline` while Prism runs | Enable `[debug]` in `config/00_core/00_app.toml`; the debugger then uses `127.0.0.1:7200` instead of the simulator. |
| `pause` / `resume` / `shutdown` answer `unsupported` | These are simulator-only. The core debug API serves reload commands; `force`/`freeze`/`release` work against both. |
| `prism-sniff` cannot open a COM port | Windows COM ports are exclusive-use; use a listen-only adapter, a gateway monitor port, or an inline virtual pair. |
| `scan.toml` / `sniff.toml` not found | Run the tool's `--init` (or pass `--config`); configs are never created silently. |
| Reload stays `pending` | The change is staged: confirm with `prism-dbg control reload_confirm` or `y` in the panel. |

## Tool pages

- [`02_SIMULATOR.md`](02_SIMULATOR.md) — simulated field, tag behaviours, dtasm,
  several simulators, profile folders, duplicate-tag protection;
- [`03_DEBUGGER.md`](03_DEBUGGER.md) — CLI, endpoint discovery, control/watch/tags/
  Modbus, override lifetime, every panel screen and key;
- [`04_SCANNER.md`](04_SCANNER.md) — scan plans, discovery, register rules, type
  inference, generated config;
- [`05_SNIFFER.md`](05_SNIFFER.md) — serial taps, TCP proxy/connect, protocol
  decoding, recording and markers;
- [`06_DEVTOOLS.md`](06_DEVTOOLS.md) — `validate rhai`, generators, `generate tags`,
  `init`, `scaffold`, inventory import/export, `trim`, `migrate`.

Related material:

- Device tags and `[tag.fail]`: [`02_communication/01_DEVICES.md`](../02_communication/01_DEVICES.md)
- Rhai scripting and its validation: [`04_logic/01_RHAI.md`](../04_logic/01_RHAI.md)
- Alarm rules: [`04_logic/02_ALARMS.md`](../04_logic/02_ALARMS.md)
- Deployment and licensing: [`06_operations/01_LICENSING.md`](../06_operations/01_LICENSING.md)
