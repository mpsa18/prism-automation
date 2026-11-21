# `prism-sim` — simulated field

`prism-sim` serves the instance field without hardware: Modbus TCP/RTU/ASCII
devices, OPC UA servers for configured OPC UA client devices, and an optional
serial pair. It derives tags, addresses and types from `config/**`; the bench
file `devtools/simulator/sim.toml` describes only what the project config cannot
express — pacing, physics, the Control API, serial pairs, dtasm models and tag
overrides.

## Command line

```sh
prism-sim [--config <file|dir>] [--instance <name>] [--headless|--tui]
                                                # terminal: panel; otherwise serve
prism-sim [--config <file|dir>] check [--report <file.json>]
prism-sim [--config <file|dir>] run [--duration <sec>] [--trace <sel>] [--trace-period <sec>]
prism-sim [--config <file|dir>] tui
prism-sim init [--root <dir>] [--force]
```

| Command | Behavior |
|---|---|
| none | With a terminal on stdin **and** stdout: the interactive panel. Without a terminal (service, CI, redirected output): serves headlessly with tracing off. |
| `check` | Validates the resolved plan, prints devices, tags and problems. Exit `1` on errors. `--report` writes a JSON report. |
| `run` | Serves without the panel and prints a CSV trace. `--trace` is `outputs` (default), `all`, `none` or a comma-separated tag list; `--trace-period` is in simulated seconds. |
| `tui` | The interactive panel; requires a terminal (exit `2` otherwise). |
| `init` | Writes only `devtools/simulator/sim.toml`; never touches `config/**`. Starts with `all_tags = true`. `--force` overwrites an existing file. |

Explicit mode flags override the terminal heuristic: `--headless` serves
without the panel (the mode to use from `spawn_managed`/`sim_start`),
`--tui` forces the panel and exits `2` without a terminal. `--instance <name>`
overrides `[sim].name` for the running process (presence, reports, `stats`,
TUI title) without editing the bench file.

`prism-sim init` writes the instance folder name into `[sim].name` (not a
shared `bench`), and `[sim].all_tags`/`[sim].tags` control which config tags
are served. Keep names unique when several simulators run in one instance:
the name identifies the bench in `prism-dbg`, in the presence file and in
`control stats` (`"instance"`), which is how ML/AI tooling binds a dataset to
a specific simulator. A duplicate live name is reported as a warning.

The core's Rhai engine exposes the same lifecycle by name:
`sim_start(name)`, `sim_stop(name)` and `sim_status(name)` (`running`,
`offline`, `missing`). `sim_start` resolves `devtools/simulator/sim-<name>.toml`,
`<name>.toml`, `<name>/` or a TOML whose `[sim].name` matches, launches it as a
managed child with `--headless --instance <name>`, and `sim_stop` first stops a
managed child, otherwise sends `shutdown` through the presence Control API.
Both are safe to call from `on_init`/`on_close`; managed children are also
stopped by the runtime's shutdown net.

`--config` points to a bench file or to a folder of flat `*.toml` fragments
(see [Profile folder next to the binary](#simulator-profile-folder-next-to-the-binary)).
Without `--config`, the instance is found from the current directory, the
executable location, or `devtools/simulator/sim.toml`.

Exit codes: `0` success, `1` `check` findings, `2` usage or internal error.

> **Open the TUI full screen.** The panel shows `TAG / ROLE / VALUE / FORCED`
> and the config passport (`TYPE / ADDRESS / UNIT / ACCESS`) as the terminal
> widens, plus the behaviour/producer notes. Unlike `prism-dbg` there is no
> `QUALITY` or `AGE` column: the simulator *is* the source of the process
> image, so those cells would only ever repeat a fabricated value. The
> selected-tag line adds the config description, active override, producer and
> consumers. A narrow terminal hides the passport/behaviour columns and the
> reload banner — exactly the information needed while simulating a stand.

## Two sides of the same panel

With a terminal attached, `prism-sim` (no arguments) and `prism-sim tui` open the
interactive panel; without a terminal (service, CI, redirected output) the same
command serves the devices headlessly. The panel layout follows `prism-dbg`:
title/status line, live table with colours, selected-tag detail line, status
and key hints, plus a `dtasm:` line with every digital twin (model, simulated
time, status, input/output counts).

The simulator panel is the mirror of `prism-dbg` from the **field side**:

- **FIELD** (title line) — values the PLC/core will read, with the declared
  register/NodeId, producer (`out:`), consumers (`in:`), generator and the
  declared behaviour (`sensor`, `temperature`, `process on …`);
- **TOP** — the same tags as northbound protocols see them (Modbus/OPC UA
  address and served endpoint in the note; the core debugger shows the
  northbound view side by side).

The panel keys are: `↑/↓` move, `Space` mark/unmark, `a` mark all visible,
`A` clear marks, `v` field/top, `Enter` action menu, `s` set, `f` force,
`x` freeze, `r` release, `R` release all, `p` pause, `y`/`n` hot-reload,
`/` filter.

`Space` marks tags; actions then apply to every marked tag, or to the selected
row when nothing is marked. Marks survive filtering and row rebuilds. The
detail line shows the marked count.

`Enter` opens the action menu. The menu is compact
(`1 Set · 2 Force · 3 Freeze · 4 Release · 5 Restore`): digits pick and apply
an action immediately, `↑/↓` + `Enter` does the same. The line under it
explains the highlighted action. Both the menu and the key hint wrap on narrow
terminals, and the layout reserves their lines, so the last key never
disappears. `Set` and `Force` ask for one number and apply it to every target;
the other actions apply at once. Without the menu, `s` / `f` open the same
prompts directly.

| Action | Meaning |
|---|---|
| Set | external write; a writable/constant tag stays at the value |
| Force | hold the effective value for readers/Modbus/OPC UA |
| Freeze | force the current effective value |
| Release | drop the override; produced tags return to their model |
| Restore | release + return a writable tag to its configured value |

`Restore` is the restore path: a forced output goes back to its
producer/behaviour, a writable actuator returns to the configured value, and
the TUI shows the result in the status line.

## Bench file (`devtools/simulator/sim.toml`)

The bench file adds only what `config/**` cannot express:

```toml
[sim]
name     = "plc1-bench"  # unique instance name; defaults to the instance folder
tick_ms  = 50            # scan period
speed    = 1.0           # 1.0 = real time, 1000 = a day in ~86 s
seed     = 1             # deterministic sensor noise
all_tags = true          # false + tags = [...] simulates only that subset

[control]                # Control API endpoint for prism-dbg
listen  = "127.0.0.1:7100"
# token = "secret"       # optional, required in every request when set

# [modbus]               # escape hatch for a single-device stand:
# listen  = "0.0.0.0:502"
# unit_id = 3

[[objects]]              # process object: input tag -> model -> output tag
id     = "heater"
input  = "plc1.heater_pwm"
output = "plc1.temperature_pv"

[objects.model]
kind    = "thermal_1st"  # pwm | thermal_1st | thermal_2nd | pump_flow
gain    = 30.0
tau     = 30.0
ambient = 20.0
```

`[[objects]]` model kinds: `pwm` (duty → power), `thermal_1st`/`thermal_2nd`
(inertia and dead time) and `pump_flow` (threshold, saturation). Objects
support `input_delay`, a sensor chain (`[objects.sensor]`: delay, lag, drift,
noise, quantization, min/max) and input/load disturbances.

### Derived from `config/**`

Register maps, the tag universe, declared types, initial values and device
addresses are re-read from `config/**` on every start:

- every `[[device.tag]]` of `config/01_southbound/01_modbus/**` becomes a
  register entry of its device (area/type/scale from `register`/`data_type`/
  `scale`; 32-bit values span two registers);
- every TCP device gets its own listener at the configured `ip:port` with its
  own unit id;
- RTU/ASCII devices keep their real address (`COM7@9600`) and are served over a
  virtual port pair (`[[serial]]`, see below); without that block `check`
  says `not served` and the rest of the stand keeps running;
- every `protocol = "opcua"` device of
  `config/01_southbound/03_opc_client/**` gets an OPC UA server at its
  `[device.opcua].endpoint` (see below);
- virtual tags of `config/01_southbound/04_virtual_tags/**` are held at their
  `initial_value`; the simulator never evaluates Rhai (the SUT does). A write
  to a virtual tag from the panel changes only the bench copy — the core owns
  the real tag. The panel says so (`bench copy only`) instead of implying the
  SUT accepted the value; use `prism-dbg` or the SCADA to exercise the core.
  The simulator also does not apply the core's `min`/`max` write limits to
  virtual tags: those are validated by the SUT write path.

Bench overrides are explicit and never edit the project config:

```toml
[[modbus.map]]          # replace the derived map with a manual one
tag         = "plc1.temperature_sp"
area        = "holding"
address     = 100
type        = "f32"
scale       = 1.0
data_type   = "real"

[[tags]]                # add a bench-only tag or patch a derived one
name      = "plc1.temperature_sp"
value     = 40.0        # image seed in engineering units
data_type = "real"      # optional explicit type
# [tags.disturbance]    # optional generator: kind/amplitude/period/noise
```

The image is seeded with `initial_value` from the core config (mapped and
virtual tags alike); a bench `[[tags]].value` overrides that seed.
`initial_value = nan` (the "no data" init) seeds `0.0` silently; other
non-finite values are reported as mistakes.

Optional `data_type` (`bool`, `word`, `dword`, `int`, `dint`, `real`) is
validated on every write: Control API `set`/`force` answer `wrong_type`,
Modbus FC 6/16 answer exception 3. `bool` accepts only 0/1, integer types only
whole raw counts (`value / scale`), `real` only finite f32-range values. Bit
areas (`coil`/`discrete`) are boolean without the key. TUI prompts also accept
`true`/`false`.

### Tag values and overrides

Every tag holds `external`, `computed` and `forced` values; the **effective**
value is `forced` → `computed` (produced tags) → `external`. Roles: `input`
(consumed by objects), `output` (produced), `link` (both), `aux` (free).

- `set` writes the external value (only for non-produced tags);
- `force`/`freeze` override the effective value until `release` — this is how
the debugger substitutes a sensor;
- every transport sees the same image at once; **produced tags are read-only
  over Modbus** (exception 2 — use the Control API instead).

Derivation findings (unsupported types, non-big-endian word order, register
overlaps, virtual/mapped collisions) are warnings: `prism-sim check` prints
them and keeps going.

## Tag behaviours

Any tag from `config/**` is picked up automatically. Without an explicit
override it gets an inferred `auto` behaviour:

| Tag kind | Inferred behaviour |
|---|---|
| writable actuator (`holding`/`coil`, `rw`/`wo`) | `constant` |
| boolean/integer/counter | `constant` (register encoding stays valid) |
| name contains `temp`/`tt_` | `temperature` (slow drift around the initial value) |
| flow/pressure/level/speed/… | `sensor` (bounded noise + slow periodic component) |
| other read-only tag | `sensor` (small noise) |

Explicit scenarios in `sim.toml`:

```toml
[[tags]]
name = "plc1.oil_temp"
behavior = { kind = "temperature", ambient = 20.0, setpoint = 70.0, tau = 180.0, noise = 0.2 }

[[tags]]
name = "plc1.flow"
behavior = "random"          # shorthand; bounds from min/max

[[tags]]
name = "plc1.flow"
behavior = { kind = "sensor", noise = 0.2, drift = 0.001, period_ms = 60000, amplitude = 0.5, min = 0.0, max = 50.0 }
```

### Regulated process for control-loop debugging

`process` (and `temperature` with `input`) is a real plant: first-order gain,
lag and dead time plus an optional sensor chain. The output tag becomes
**produced**; force it only with `f` (a plain `set` is refused).

```toml
[[tags]]
name = "heater.temperature"        # PV
behavior = { kind = "temperature", input = "heater.duty", gain = 120.0, tau = 90.0, ambient = 20.0, delay_ms = 2000, noise = 0.05, min = 0.0, max = 200.0 }
```

Drive `heater.duty` from the core (a control loop) and watch the PV in
`prism-dbg`: the loop closes through the same Modbus/OPC UA address the real
stand uses.

## Serial lab (RTU / ASCII)

Serial devices are emulated over a **virtual port pair**: the simulator opens
one end (`[[serial]].peer`), the core opens the other
(`[device.serial].serial_port` in `config/01_southbound/01_modbus/**`). The core
configuration never changes — the pair just has to exist before the stand
starts.

Create the pair once — a com0com pair on Windows, a `socat` PTY pair on
Linux/macOS:

```text
# Windows: install com0com and add e.g. COM10 <-> COM11
# Linux/macOS:
socat -d -d pty,raw,echo=0,link=/tmp/prism-sim pty,raw,echo=0,link=/tmp/prism-sut
```

Declare one block per serial device; `baud_rate`/`parity`/`data_bits`/
`stop_bits` must match the core's `[device.serial]` settings:

```toml
[[serial]]
device    = "flow_meter"   # transport = "rtu"; framing follows the config
peer      = "COM11"        # simulator side; the core opens COM10
baud_rate = 19200
parity    = "even"

[[serial]]
device    = "energy_meter" # transport = "ascii"
peer      = "COM13"        # the core opens COM12
```

- `device` and `peer` are required; the line defaults are `9600 8N1`, parity
  `none`.
- Exactly one block per device and one port per block: a duplicate device or
  peer is a validation error; a block for a TCP device is rejected.
- The simulator opens the peer at startup. If the pair is missing, `prism-sim`
  stops with the platform hint — create the pair, or comment the block out to
  run the TCP part of the stand alone (`check` then reports the device as
  `not served`).

## OPC UA server (`config/01_southbound/03_opc_client/**`)

For every `protocol = "opcua"` device the simulator runs an OPC UA server at
exactly the endpoint from `[device.opcua].endpoint`
(`opc.tcp://host:port/…`): the declared `node_id`s become variables with the
declared data types, so the core's OPC UA client connects with no bridge tools
(UaExpert/asyncua work for inspection too). Values come from the process
image — `force` and writes from any transport are visible at once — and writes
to `rw` tags land in the image after the same type/range validation as the
Control API.

Scope: the bench endpoint is SecurityPolicy `None` / anonymous only — a device
with encryption or a username is reported as `not served`. Served nodes live
in `ns=2`; a tag whose `node_id` uses another namespace is skipped with a
warning. `string` tags and `namespace_uri` overrides are not served yet —
`check` warns about each of them. The address space is built once at startup:
adding or removing nodes needs a `prism-sim` restart (values, writes and
hot-reloaded tag values apply live), and devices sharing one endpoint share
one server.

## Modbus TCP server

One listener per TCP device of `config/01_southbound/01_modbus/**`, bound at
exactly the configured `ip:port` with the device's unit id (foreign units are
ignored). FC 1/2/3/4 (read) and 5/6/15/16 (write); exceptions 1 (function), 2
(address), 3 (value). Values are big-endian with saturation by type; reads of
unmapped addresses return 0; writes are accepted only to holding registers and
coils, must cover whole mapped values and are rejected for produced tags.

A bind failure names the device and suggests assigning the address to a local
interface or overriding the endpoint in the bench file (`[modbus] listen`).

## Control API (the debugger channel)

JSON Lines over TCP (`[control].listen`), ops: `list`, `get`, `set`, `force`,
`freeze`, `release`, `release_all`, `stats`, `pause`, `resume`, `shutdown`,
`reload_status`, `reload_confirm`, `reload_reject`. `pause` freezes the scan
loop; `resume` continues without catch-up. This is the only channel that can
`force` tags; protocol registers stay "native". `stats` includes the
hot-reload state (`reload`).

Prism itself serves the same protocol over its native debug API (`[debug]`,
default `127.0.0.1:7200`), including `force`/`freeze`/`release`; see
[`03_DEBUGGER.md`](03_DEBUGGER.md). `pause`/`resume`/`shutdown` remain
simulator-only.

## Hot reload scope

The watcher re-resolves `config/01_southbound/01_modbus/**`,
`config/01_southbound/04_virtual_tags/**` and the bench file every 500 ms and
stages a plan. A change is **never applied quietly**:

```bash
prism-dbg control reload_status    # idle | pending | failed, with change counts
prism-dbg control reload_confirm   # apply the staged plan at the next tick
prism-dbg control reload_reject    # dismiss it
```

`y`/`n` in the panel and on the stdin of a headless `run` do the same. While
`pending`, the running plan keeps working; an edit that does not parse becomes
`failed` with the error in `reload_status`, and the old plan is untouched.

On apply the register map, tags, types, physics and generators are re-derived;
**live state survives by tag name**: external writes and active overrides keep
their values, produced tags restart from their models, and a new register entry
is served over Modbus immediately. Listen-address changes (`control.listen`,
`modbus.listen`, serial/OPC UA servers) are reported as restart-required. A
change of one address inside one device module is a `~1 tag` diff applied to
that module; modules that did not change keep running. If nothing is confirmed
before the run ends, the change is dropped with a note.

The Prism core has its own watcher and the same confirm/reject model; its
reload scopes are described in [`04_logic/01_RHAI.md`](../04_logic/01_RHAI.md).

## Digital twins: Siemens dtasm modules

`prism-sim` can host external **dtasm** (Digital Twin Assembly) modules instead
of the built-in first-order models. dtasm is a Wasm ABI for executable numerical
simulators (not an S7/PLC protocol); the runtime lives in
`testbench/dtasm-host`.

```toml
[[dtasm]]
id = "furnace"
module = "plugins/digital_twin/furnace.wasm"   # relative to config/
# Initial values of parameters/local variables, by dtasm name
[dtasm.init]
"T_amb" = 20.0

[[dtasm.input]]
tag = "heater.duty"        # Prism tag written by the core (control loop)
variable = "u"             # dtasm input variable

[[dtasm.output]]
tag = "furnace.temp"       # produced tag, visible to the core (and through it
                           # to Modbus/OPC UA/MQTT consumers)
variable = "T"
```

At start the simulator calls `getModelDescription`, checks variable names and
causality (`input`/`output`), then runs `init`. Every scan tick: inputs are read
from the process image, `setValues`/`doStep`/`getValues` are called, and the
outputs are published as produced tags. `Discard` is reset via `resetStep`; the
error is reported in the panel/log and the last good outputs stay visible.
Bindings are validated at startup: an unknown variable, wrong causality or a
tag produced twice is a configuration error, not a silent zero.

Outputs are ordinary tags: the core polls them over Modbus/OPC UA, reports
snapshot them, `prism-dbg` can force/freeze them, and alarms can bind to them.
For a **continuous** report add `interval_ms` to the `[[report]]` of the core
(see `05_wasm/04_REPORTS.md`); for an operator-triggered report keep `button_tag`.

Create the module with the upstream [`siemens/dtasm`](https://github.com/siemens/dtasm)
Rust/C++ templates (`dpend_rs`, `add_rs`) and put the resulting `.wasm` under
`instances/<name>/plugins/`.

## Several simulators in one instance

Yes: run one `prism-sim` process per simulated area. Each bench file selects
its own devices/tags and its own Control API port; the processes serve the real
Modbus/OPC UA addresses of their subset, so one core still sees all devices.

`devtools/simulator/sim-plc1.toml`:

```toml
[sim]
name = "plc1"
devices = ["plc1"]          # only this device module
all_tags = false           # use the allowlist below
# tags = ["plc1.*"]         # optional narrower allowlist (globs)
# exclude_tags = ["plc1.debug_*"]

[control]
listen = "127.0.0.1:7101"   # distinct for every simulator process
```

`devtools/simulator/sim-plc2.toml`:

```toml
[sim]
name = "plc2"
devices = ["plc2"]

[control]
listen = "127.0.0.1:7102"
```

Start them separately (add `run` after the config path to serve headlessly):

```powershell
instances\stand-01\devtools\simulator\prism-sim.exe --config instances\stand-01\devtools\simulator\sim-plc1.toml
instances\stand-01\devtools\simulator\prism-sim.exe --config instances\stand-01\devtools\simulator\sim-plc2.toml
```

Rules:

- `devices` is an allowlist of device-module prefixes (`plc1`, `flow_meter`,
  `virtual`, ...). Empty means every device.
- `exclude_devices` removes devices even when `devices` is empty.
- `all_tags` (default `true`) takes every tag of the selected devices from
  `config/**`. With `all_tags = true`, a non-empty `tags` list is ignored with
  a warning.
- With `all_tags = false`, `tags` is the allowlist of globs (`*`, `?`); an
  empty list selects no tags (also warned).
- `exclude_tags` removes globs after the allowlist.
- The filter applies to the image, Modbus maps and OPC UA nodes. A process
  without `plc2` in `devices` does not create `plc2.*` tags at all.
- Every process needs a distinct `[control].listen`; two simulators cannot
  serve the same Modbus endpoint at once. Disjoint device subsets at their real
  addresses are the normal setup.
- If a bench file adds `[[tags]]`/`[[objects]]`/`[[dtasm]]` explicitly, those
  are intentional additions and stay; use `exclude_tags` to keep a tag out of
  the derived universe.

The same instance can mix `prism-sim` processes (simulated field) and real
devices: the core polls configured addresses, and only the devices with a
running simulator answer.

## Simulator profile folder next to the binary

A simulator can live in its own folder with a set of flat TOML fragments. If
`prism-sim.exe` has any `*.toml` next to it, the folder is used as the bench
(no `--config` needed); `--config <dir>` works explicitly too. All flat `*.toml`
files are merged in name order:

```text
devtools/simulator/plc1/
  prism-sim.exe
  00_sim.toml          # [sim] devices/tags, [control] port, [modbus]
  10_selection.toml    # additional [sim] tags/devices or [[tags]] overrides
  20_behaviour.toml    # [[tags]] behaviour = "temperature" / process / ...
  30_twins.toml        # [[dtasm]] models and bindings
  40_objects.toml      # [[objects]] physics, if needed
```

`00_sim.toml`:

```toml
[sim]
name = "plc1"
devices = ["plc1"]
all_tags = false
tags = ["plc1.*"]
exclude_tags = ["plc1.debug_*"]

[control]
listen = "127.0.0.1:7101"
```

Nested subdirectories are **not** merged into the parent profile (so a
`profiles/` tree cannot leak into `devtools/simulator`). Arrays such as
`[[tags]]`, `[[objects]]`, `[[dtasm]]` and `[[serial]]` append across fragments;
single values are overridden by the later file.

## Duplicate-tag protection

Every selected tag is leased with an OS file lock under
`<instance>/data/simulator-locks/`. A second simulator that selects the same tag
fails at startup:

```
tag 'plc1.temp' is already simulated by another prism-sim
(lock .../data/simulator-locks/tag-plc1_temp.lock: ...);
exclude it in one of the profiles
```

The lock is released automatically on exit/crash. This catches the semantic
conflict even when two profiles use different Control API ports or different
Modbus listen addresses; the OS still catches two processes binding the same
endpoint.
