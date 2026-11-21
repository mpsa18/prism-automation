# Prism Quick Reference Cheat Sheet

This page collects the commands and configuration pieces you need most often.
Every chapter referenced here explains the details.

Windows examples use `prism.exe` and the `.exe` suffix; on Linux and macOS the
same commands work without the suffix (`./prism`, `devtools/simulator/prism-sim`).

---

## 1. Essential commands

### Runtime

```bash
prism --check-config          # validate the configuration, do not start
prism                         # start
prism --verbose               # start with detailed logs
prism --hide-console          # Windows: start without a console window
```

### License

```bash
prism license status          # state, limit, days left, binding
prism license request         # write licensing/license_request.toml
prism --print-hwid            # machine fingerprint for support
```

### Background service

```bash
prism service install         # Windows: Administrator, Linux/macOS: sudo
prism service start
prism service stop
prism service status          # exit 0 = running, 3 = not running, 1 = query error
prism service uninstall
```

### Serial ports

```bash
prism serial list             # ports, USB descriptors, matcher results
```

### Bench helpers

The helpers live in `devtools/` inside the project folder and need no hardware.
They find the project themselves; see [`03_tooling/01_BENCH_TOOLS.md`](../03_tooling/01_BENCH_TOOLS.md).

```bash
# Simulated field: serve every configured device at its real address
devtools/simulator/prism-sim
# In a terminal, no arguments opens the panel; without a terminal it serves directly.
devtools/simulator/prism-sim check        # validate the plan without binding
devtools/simulator/prism-sim tui          # interactive panel

# Debugger: panel with the configuration catalog and live values
devtools/debugger/prism-dbg
devtools/debugger/prism-dbg control list
devtools/debugger/prism-dbg control set io_controller.pump_run 1
devtools/debugger/prism-dbg control force io_controller.pressure_in 120
devtools/debugger/prism-dbg control release io_controller.pressure_in
devtools/debugger/prism-dbg control stats
devtools/debugger/prism-dbg --device io_controller modbus read 4 100 2

# Scanner: read-only field discovery, writes the config from scan.toml
devtools/scanner/prism-scan --config devtools/scanner/scan.toml
devtools/scanner/prism-scan --config devtools/scanner/scan.toml --dry-run

# Sniffer: passive bus capture; Ctrl+R/F2 records, F3 marker, Ctrl+C exits
devtools/sniffer/prism-sniff --config devtools/sniffer/sniff.toml
devtools/sniffer/prism-sniff --config devtools/sniffer/sniff.toml --record-jsonl
```

### Tooling (`prism-devtools`)

`devtools/tooling/prism-devtools` creates and checks configuration files.

```bash
# Check scripts and their references
prism-devtools validate rhai --root .

# Generate northbound configuration from the tags
prism-devtools generate opc-server --root .
prism-devtools generate opc-client --root .
prism-devtools generate mqtt --root .
prism-devtools generate mqtt --root . --apply-hand   # adopt hand-managed files (.bak kept)
prism-devtools generate opc-server --root . --check  # report drift, write nothing

# Generate a batch of tags (annotated by default; existing tags are never duplicated)
prism-devtools generate tags --root . --device io_controller \
    --name 'pump_{i:02}_run' --count 4 --address 600 --stride 2 \
    --register coil --type bool --access rw

# Scaffold one entity
prism-devtools scaffold device io_controller --root .
prism-devtools scaffold alarm high_level --tag io_controller.pressure_in --max 4000 --root .
prism-devtools scaffold script interlocks --root .

# Import tags from an inventory ledger (only missing tags by default)
prism-devtools import inventory --root . --only-new

# Remove MQTT rules that reference tags absent from the devices
prism-devtools trim mqtt --root .            # report, exit 1 on findings
prism-devtools trim mqtt --root . --apply    # rewrite, .bak copies kept
```

`--dry-run` prints what would change, `--check` writes nothing and fails when
generated files are stale, `--force` overwrites generated files with manual
edits, `--stdout` prints a single entity instead of writing it, `--draft`
writes the file with a `#` prefix so the runtime ignores it until renamed.

---

## 2. Configuration snippets

### Modbus input

`config/01_southbound/01_modbus/io_controller/plc.toml`

```toml
[[device]]
name      = "io_controller"
transport = "tcp"

[device.tcp]
ip        = "192.168.1.5"
unit_id   = 1

[[device.tag]]
name      = "pressure_in"
address   = 100
register  = "input"
data_type = "word"
scale     = 1.0
access    = "ro"
unit      = "Pa"
```

### Siemens S7 tag

`config/01_southbound/02_s7comm/plc_s7/plc.toml` (inside a file that already
declares its `[[device]]` header)

```toml
[[device.tag]]
name      = "tank_level"
data_type = "real"
access    = "ro"
unit      = "m"

[device.tag.s7]
area      = "db"
db        = 10
offset    = 4
```

### Virtual (calculated) tag

`config/01_southbound/04_virtual_tags/calculations.toml`

```toml
[[device]]
name     = "calculations"
protocol = "virtual"

[[device.tag]]
name       = "pressure_drop"
unit       = "Pa"
expression = 'read("io_controller.pressure_in") - read("io_controller.pressure_out")'
```

### Alarm rule

`config/01_southbound/05_alarms/01_temperature.toml`

One rule = one condition = one signalling tag `alarm.<id>`. The signalling tag
is held while the condition is true, so scripts and MQTT can react to it.

```toml
[[alarm]]
id          = "alarm.oil_temp_high"
tag         = "io_controller.oil_temp"   # source value
value       = 1.0                         # written to alarm.oil_temp_high on trip
reset_value = 0.0                         # ... and on reset
priority    = "critical"                  # info | warning | critical | emergency
message     = "Temperature {value} > {limit} ({tag})"
for_ms      = 500                         # condition must hold this long

[[alarm.write]]                            # one-shot write on transitions
tag = "io_controller.oil_light"
on  = 1
off = 0

[alarm.limit]                              # strictly beyond the bound, reset with hysteresis
max        = 120.0
hysteresis = 2.0
```

Other condition blocks: `[alarm.rate]` (`max` in units/s, `min_change` for a
"frozen" signal, `window_ms`) and `[alarm.switching]` (`min_hz`/`max_hz`/
`min_duty`/`max_duty` for encoders and PWM). An optional `[alarm.enable]` gate
(`tag`/`expression`/`script_func`, non-zero = enabled) freezes the rule and
resets it when it drops. `rhai = "on_oil_temp_high"` calls a user function on
every transition with the map `#{id, tag, value, active, priority}`.
Full reference: [`04_logic/02_ALARMS.md`](../04_logic/02_ALARMS.md).

---

## 3. Rhai API

Full guide and scenarios: [`04_logic/01_RHAI.md`](../04_logic/01_RHAI.md).

```rhai
// ── Lifecycle & scheduling (scripts/bindings.toml) ───────────────────────────
// [[script]] file="main.rhai" triggers=["on_init","on_close"]
// [[poll]]   function="poll_bms" interval_ms=1000 error_policy="backoff"
fn on_init() { log_info("startup"); }
fn on_close() { stop_app("/path/to/helper"); }  // graceful shutdown / before full reload
fn poll_bms() { /* own background thread with its own interval:
                   interlocks, watchdogs, slow sources */ }

// ── Read values ───────────────────────────────────────────────────────────────
let val  = read("io_controller.flow");          // f64, NaN if unknown
let flag = read_bool("io_controller.pump_run"); // != 0 -> true
let q    = read_quality("io_controller.flow");  // "good"/"bad"/"uncertain"/"uninitialized"
let s    = read_string("io_controller.label");  // last raw string
let on   = device_online("io_controller");      // device poller state

// ── Write values ─────────────────────────────────────────────────────────────
// Virtual tags: published to the registry and MQTT immediately.
// Physical tags: queued for the device poller (Modbus/S7/OPC).
write("io_controller.tank_temp_sp", 55.0);
write_string("io_controller.recipe", "batch-42");
let queued = write_batch(#{ "io_controller.valve_open": 1.0,
                            "io_controller.pump_run": 1.0 });
write_batch_holding(#{ "plc1.setpoint": 3333.0 });
write_batch_coil(#{ "plc1.enable": 1.0 });

// ── Math & utilities ─────────────────────────────────────────────────────────
let out    = clamp(val, 0.0, 100.0);
let scaled = scale(raw, 10.0, 1023.0);   // raw * eng_max / raw_max
let now    = now_ms();                   // Unix epoch ms (wall clock)
let os     = os_name();                  // platform name

// ── Batch snapshot & history (config/01_southbound/06_history/history.toml) ──
let pair = snapshot(["motor1.vib", "motor1.temp"]);  // coherent batch read
let vib  = history("motor1.vib", 1000);              // samples of the last second
let det  = history_samples("motor1.vib", 1000);      // {value, ts_ms, mono_ms, quality}
let qs   = snapshot_quality(["motor1.vib"]);         // quality of a coherent batch

// ── ML inference (05_wasm/03_ML.md) ───────────────────────────────────
// Async (safe everywhere); results are collected from a [[poll]] function:
let id = ml_submit("anomaly", features);   // -1 when the plugin/queue is busy
if ml_done(id) {
    let err = ml_error(id);
    if err == "" {
        let out = ml_result(id);
        if out.len() > 0 { write("ml.anomaly_score", out[0]); }
    }
}
// Synchronous (only in [[poll]] functions; refused in virtual tags/alarm hooks):
let score = ml_infer("anomaly", features);
let m     = ml_metrics("anomaly");         // p50/p95/p99, calls, errors, version

// ── Alarms (tag_id = "device.tag") ───────────────────────────────────────────
raise_alarm("io_controller.pump_run", "critical", "Pressure surge");
clear_alarm("io_controller.pump_run");
clear_all_alarms();

// ── External helpers (no shell; arguments as an array) ──────────────────────
let out = spawn_wait("/path/to/helper", ["--once"], 1500);
spawn_detach("/path/to/helper", ["--watch"]);
spawn_managed("/path/to/helper", ["--serve"]);  // runtime-owned companion;
                                                // stop_app("/path/to/helper") stops it,
                                                // shutdown/reload stops managed helpers too

// ── Logging ─────────────────────────────────────────────────────────────────
log_info("Process cycle started");
log_warn("Approaching high temperature limit");
log_error("Sensor disconnection detected");
```

Limits and error policy (`[defaults]`): `op_budget_tick` (Rhai operations per
call), `timeout_ms` (soft deadline, 0 = off), `error_policy` =
`log_and_hold` | `backoff` | `disable_script`.

---

## 4. MQTT channels

The defaults below are configurable per project; the full contract is in
[`02_communication/02_MQTT.md`](../02_communication/02_MQTT.md).

| Channel | Direction | Format | Purpose |
|---|---|---|---|
| `prism/telemetry` | Prism to SCADA | `{"timestamp", "data": [{"ns_name", "name", "value"}]}` | batch telemetry on one topic (QoS 0) |
| `prism/status` | Prism to SCADA | `{"name", "value", "device"}` | binary device states |
| `prism/command/set` | SCADA to Prism | `{"ns_name", "name", "value"}` | operator commands: buttons, pumps, setpoints, text (QoS 1) |
| `prism/command/ack` | Prism to SCADA | `[{"ns_name", "name", "value", "disabled"?}]` | command echo in its original type |
| `prism/event/alarm/{severity}` | Prism to SCADA | alarm JSON | alarm events |

> **Debug access without MQTT.** The native debug API is configured in
> `config/00_core/00_app.toml` (`[debug]`, default `127.0.0.1:7200`, JSON Lines:
> `list`/`get`/`set`/`stats` plus `force`/`freeze`/`release`/`release_all`).
> `prism-dbg` finds it automatically; from another machine use
> `--control <addr> --token <token>` (see
> [`01_getting_started/03_APP_CONFIG.md`](03_APP_CONFIG.md), "Remote debugging").

> The old `prism/command` topic (`{"name", "value"}`) was removed: every
> command, telemetry item and acknowledgement carries `namespace` (device) and
> `name` (tag).
>
> Payloads are described by JSON templates in `payloads/*.json`: whatever the
> template contains is in the message; the required `namespace`/`name`/`value`
> cannot be removed.
>
> Extra fields (`[[channel.field]]`): `for` (an id or a glob), exactly one
> source — `value` (a literal) or `from_tag` (another tag; compute the dynamics
> in a virtual tag). Order: template, then fields, then publication.
>
> Strings work everywhere: `data_type = "string"` on a virtual tag, text
> commands (written as is, the acknowledgement echoes the type), telemetry in
> `value`, OPC UA `Variant::String`; in Rhai use `read_string()`/`write_string()`.
> In the numeric registry a string tag has only a NaN projection.

Channels (`[[channel]]` in `channels.toml` or `channels.d/`) define topics and
payloads. `contract` comes from a closed list (`telemetry`, `command`, `ack`,
`alarm`, `fail`, `status`, `tag_status`, `diagnostic`, `control.alarm_ack`,
`control.clear_alarms`, `control.reload`, `control.plugin_confirm`, `sql.get`,
`sql.read`, `sql.write`, `sql.data`). `topic` is a template with the
placeholders `{namespace}`, `{name}`, `{device}`, `{priority}`, `{severity}`
(aliases `{ns}`, `{dev}`, `{prio}`, `{sev}` are normalized on load). `id` is
optional: empty gives `<contract>-<index>`, a value must be unique. Each
contract fills only its own placeholders; in the `alarm` topic
`{severity}` and `{priority}` are synonyms. Flat topics use the flat templates
above; when placeholders are added, the channel switches to a per-tag contract
(`prism/command/{namespace}/{name}/set` with `{"v", "req_id"}`, and so on).
Incoming subscriptions are derived from the channel topics automatically.

---

## 5. WASM modules

Two kinds of extension:

- **Compute** (`prism:compute@0.2.0`) — modules over existing tags: filters,
  observers, FFT, control loops. Guide:
  [`05_wasm/01_PLUGIN_SDK.md`](../05_wasm/01_PLUGIN_SDK.md).
- **Source** (`prism:device@0.1`) — driver modules that own their devices and
  tags (`config/03_wasm/01_source/<module>/`). Guide:
  [`05_wasm/02_DEVICE_DRIVERS.md`](../05_wasm/02_DEVICE_DRIVERS.md).

```rust
// Compute plugin: crates/my-filter/src/lib.rs
#![cfg(target_family = "wasm")]
use compute_sdk::{export_plugin, ComputePlugin, BlockSpec, ResultFrame, TickFrame};

#[derive(Default)]
struct MyFilter { gain: f64 }

impl ComputePlugin for MyFilter {
    fn configure(&mut self, spec: &BlockSpec) -> Result<(), String> {
        self.gain = spec.params.iter().find(|p| p.name == "gain").map(|p| p.value).unwrap_or(1.0);
        Ok(())
    }
    fn tick(&mut self, frame: &TickFrame) -> ResultFrame {
        ResultFrame::new(frame.block_id).with_output(frame.input(0) * self.gain)
    }
}

export_plugin!(MyFilter);   // once per component
```

```bash
cargo build -p my-filter --target wasm32-wasip2 --release
```

```toml
# config/03_wasm/02_compute/my_filter/01_module.toml
[defaults]
error_policy = "log_and_hold"   # log_and_hold | disable_block | backoff

[[plugin]]
id = "my-filter"
path = "../plugins/my-filter/my_filter.wasm"   # relative to the config/ directory
max_memory_mb = 64

[[block]]
name = "temp_scale"
plugin = "my-filter"
period_ms = 100
[block.params]
gain = 1.8
[[block.input]]
tag = "io_controller.tank_temp"
[[block.output]]
tag = "calculations.tank_temp_f"
scale = 1.0                     # value / scale goes into the tag
# [[block.param_tag]]           # runtime parameter from a tag: name = "gain", tag = "..."
# [[block.event]]               # plugin event -> tag alarm: code = "sensor_fault"
# [[block.command_tag]]         # command to the block via a tag: name = "reset", tag = "..."
```

`prism --check-config` validates the module configuration; load errors and host
errors appear in `logs/prism.log`. WASM modules are not licensed separately:
the only license limit is the number of tags ([`06_operations/01_LICENSING.md`](../06_operations/01_LICENSING.md)).

Hot reload of a `.wasm` file is **strictly confirmed**: the new version is
staged and waits for `y`/`n` in the console or the MQTT `plugin_confirm`
contract. Without confirmation it is not applied. Settings:
`confirm_timeout_secs`, `auto_rollback`, `auto_rollback_after` (roll back after
a series of host errors). Details: [`05_wasm/01_PLUGIN_SDK.md`](../05_wasm/01_PLUGIN_SDK.md) §7.

---

## 6. Configuration and script hot reload

Prism watches `scripts/**/*.rhai`, `config/**/*.toml` and the `.wasm` files of
running devices. A debounced batch is applied at the narrowest scope that can
absorb it:

| Change | Applied as |
|---|---|
| `scripts/*.rhai`, `scripts/bindings.toml` | script engine and `[[poll]]` scheduler rebuilt; device pollers untouched |
| one device module (`config/01_southbound/<protocol>/<module>/`, `config/03_wasm/01_source/<module>/`) | that module's pollers restart; values, quality, status and live alarms are kept |
| a device WASM file (inside or outside `config/`) | only the devices that reference it restart |
| tag list changed, a device added or removed | **not automatic** — press `r` + Enter (the tag registry cannot change shape in place) |
| `00_core`, `02_northbound`, alarms, virtual tags, compute/ML TOML | **not automatic** — press `r` + Enter |

A module that does not parse is rejected and the running system keeps working.
An edit that reshapes the tag registry is rejected too, with a hint to press
`r`. A **full reload** (`r` + Enter, or MQTT `control.reload`) rebuilds
everything and carries the tag state over. Guide:
[`04_logic/01_RHAI.md`](../04_logic/01_RHAI.md) §6.

Console keys: `p` preview the pending plan, `a` apply it (or acknowledge all
alarms), `r` full reload, `c` cancel (or clear all alarms), `y`/`n` confirm or
reject a staged module update, `t` test alarm, `d` diagnostic snapshot,
`l` rotate the log, `s` status, `h` help, `Ctrl+C` stop.

---

## 7. Service tags (`system.*`)

The reserved `system` pseudo-device is a control surface, not a process point:
its tags are virtual and **not counted by the license**. Commands are pulses
(write, action, then read back `0`; the result is in `system.command_result`).

| Command | Payload | Action |
|---|---|---|
| `system.reload` | bool | full reload (= `r`) |
| `system.reload_module` | `modbus/press` | hot-reload one module |
| `system.scripts_reload` | bool | rebuild Rhai only |
| `system.reload_apply` / `reload_cancel` | bool | apply or cancel the pending reload plan (`a`/`c`) |
| `system.confirm` / `reject` | bool | confirm or reject a staged module update (`y`/`n`) |
| `system.device_restart` / `device_pause` / `device_resume` | device name | poller control (`pause` requires `allow`) |
| `system.alarm_ack` / `alarm_ack_all` / `alarm_clear_all` | `device.tag` / bool | acknowledgement and clearing |
| `system.alarm_shelve` / `alarm_unshelve` | `device.tag`, JSON with `minutes` | maintenance suppression |
| `system.alarm_rule_disable` / `alarm_rule_enable` | rule id | per-rule bypass (cleared by a full reload) |
| `system.alarm_test` | `{"priority","message","seconds"}` | synthetic alarm through the whole chain |
| `system.log_rotate` / `snapshot` / `self_test` | bool / path / bool | diagnostics |
| `system.shutdown` | bool | graceful stop (`allow` required) |
| `system.force` / `release` / `stub_mode` | JSON / tag / bool | debug overrides; need `[debug] enabled` |

Statuses (read-only): `devices_online/total/paused`, `alarm_count/unacked/
highest/last/last_ts/last_active/muted`, `license_state/tag_used/tag_limit/
addon_tags/days_left`, `instance`, `version`, `uptime_s`, `rss_mb` (Linux;
`n/a` on Windows), `mqtt_connected/queue/dropped`, `scripts_loaded`,
`compute_blocks`, `stub_mode_state`, `last_reload_ts/ok`, `command_result/ts/
author`, `self_test_result`.

In `prism-dbg` the `ROLE` column labels them `command` / `status` (statuses
first); `/role:command` filters the pulses. An unset command outcome shows `-`.

```toml
# config/00_core/00_app.toml
[service_tags]
enabled = true
update_ms = 1000
allow = ["shutdown"]     # dangerous commands stay read-only until listed; "*" = all
```

Guide: [`04_logic/03_SERVICE_TAGS.md`](../04_logic/03_SERVICE_TAGS.md).
