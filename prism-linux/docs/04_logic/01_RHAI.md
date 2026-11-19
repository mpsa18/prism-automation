# Embedded Rhai Scripting: Complete Guide

> **Language reference.** This chapter covers the **Prism integration** —
> lifecycle hooks, poll loops, the runtime API and the configuration. The language itself (syntax,
> types, operators, standard library) is documented in
> [The Rhai Book](https://rhai.rs/book/) and the
> [crate API docs](https://docs.rs/rhai/latest/rhai/).

## Contents

1. [Execution model](#1-execution-model)
2. [Configuration file](#2-configuration-file-configscripts-bindingstoml)
3. [Usage scenarios](#3-usage-scenarios)
   - [3.1 Lifecycle hooks (on_init / on_close / on_device_online)](#31-lifecycle-hooks-on_init--on_close--on_device_online)
   - [3.2 Cyclic logic: asynchronous poll loops](#32-cyclic-logic-asynchronous-poll-loops)
   - [3.3 Virtual (calculated) tags](#33-virtual-calculated-tags)
   - [3.4 Alarms from scripts](#34-alarms-from-scripts)
   - [3.5 Calibration and data transforms](#35-calibration-and-data-transforms)
   - [3.6 External processes](#36-external-processes)
4. [Runtime API reference](#4-runtime-api-reference)
5. [Limits, error policy, diagnostics](#5-limits-error-policy-diagnostics)
6. [Hot reload](#6-hot-reload)
7. [Pre-flight validation](#7-pre-flight-validation)
8. [Troubleshooting](#8-troubleshooting)

---

## 1. Execution model

Prism embeds [Rhai](https://rhai.rs), a sandboxed scripting language for Rust.
Scripts live in `scripts/` next to the executable (`config/scripts/` remains a
legacy fallback) and are loaded automatically at boot. All `.rhai` files share one engine
instance; a named function may live in any file.

Script code runs in one of two contexts:

```text
┌───────────────────────────── control loop (async runtime) ─────────────────┐
│                                                                            │
│  on_init()      once after the tag registry/store are populated            │
│  on_device_online(device)  a device became available: first data or a      │
│                 reconnect after an outage; carries the device name         │
│  on_close()     once per runtime session: graceful shutdown and before a   │
│                 full hot reload                                            │
│  script_func    virtual tags (calculated points)                           │
│                                                                            │
└────────────────────────────────────────────────────────────────────────────┘

┌───────────────────── ScriptScheduler (dedicated OS threads) ───────────────┐
│                                                                            │
│  [[poll]].function   each poll gets its own thread and interval;           │
│                      interlocks, watchdogs, slow sources:                  │
│                      nobody waits for anybody                              │
│                                                                            │
└────────────────────────────────────────────────────────────────────────────┘
```

Important consequences:

- **Polls are asynchronous with respect to control.** A poll that waits for an
  external process for two seconds does not delay the control loop or other
  polls. A poll slower than its interval simply starts the next run later.
- **Scripts are stateless between calls.** Rhai functions cannot keep mutable
  global variables: every call evaluates the file top-level again and calls the
  function with a fresh scope. Use scratch-pad tags (section 3.3) or
  `extras`/registry tags to remember state. `const` values are fine.
- **Everything shares one tag registry and one alarm store**, so scripts always
  see the same values that MQTT/OPC UA/SCADA see.
- **Load order is alphabetical by file name.** Do not rely on functions defined
  in other files' top-level statements; rely on named functions only.

---

## 2. Configuration file (`scripts/bindings.toml`)

The file combines script scheduling with the legacy `[[virtual_tag]]` section
(doc `04`, section 3). Each parser ignores keys it does not know.

```toml
# ─── Global script limits ────────────────────────────────────────────────────
[defaults]
enabled        = true               # global kill switch for all Rhai code
error_policy   = "log_and_hold"     # log_and_hold | disable_script | backoff
op_budget_tick = 100000             # Rhai operations per call
timeout_ms     = 5                  # soft deadline per control-loop call, ms (0 = off)

# ─── Per-file lifecycle hooks ────────────────────────────────────────────────
# Without a [[script]] entry a file runs every hook it declares
# (on_init / on_close / on_device_online)
[[script]]
file     = "main.rhai"
triggers = ["on_init"]          # any subset of on_init, on_close,
                                # on_device_online (or "*")
# enabled   = false              # disable this file only
# op_budget = 200000             # per-file override
# timeout_ms = 10                # per-file override
# error_policy = "backoff"       # per-file override

# ─── Asynchronous poll loops ─────────────────────────────────────────────────
[[poll]]
name         = "bms_poll"       # label for logs, defaults to function
file         = "bms.rhai"       # optional: search only this file
function     = "poll_bms"       # Rhai function, no arguments
interval_ms  = 2000
run_on_start = true             # call immediately at start (default true)
timeout_ms   = 0                # 0 = no wall-clock deadline (default)
# op_budget  = 100000           # defaults.op_budget_tick
# error_policy = "backoff"      # defaults.error_policy
# enabled    = true
```

Field reference:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `defaults.enabled` | bool | `true` | `false` disables all scripts and polls |
| `defaults.error_policy` | string | `log_and_hold` | reaction to script errors/timeouts, see section 5 |
| `defaults.op_budget_tick` | int | `100000` | Rhai operation limit per call |
| `defaults.timeout_ms` | int | `0` | soft deadline for control-loop calls, `0` = unlimited |
| `script[].file` | string | — | file name inside `scripts/` |
| `script[].triggers` | array | all | `on_init`, `on_close`, `on_device_online`; empty = all |
| `poll[].function` | string | — | Rhai function to call, no arguments |
| `poll[].interval_ms` | int | `1000` | period between calls (minimum 1 ms) |
| `poll[].run_on_start` | bool | `true` | first call at start instead of after one interval |
| `poll[].file` | string | unset | restrict function lookup to one file |
| `poll[].timeout_ms` | int | `0` | per-call soft deadline, `0` = unlimited |
| `poll[].op_budget` | int | defaults | per-call operation limit |
| `poll[].error_policy` | string | defaults | per-poll policy |

Boot-time validation logs every problem it can see (`warnings()`):
unknown triggers, `[[script]]` entries with no hook enabled, empty
function names, duplicate poll names, zero intervals.

---

## 3. Usage scenarios

### 3.1 Lifecycle hooks (`on_init` / `on_close` / `on_device_online`)

`on_init()` runs once per session: after the tag registry and the tag
metadata (store) are populated, before device pollers and compute blocks
start, so the hook can already read and write every tag — virtual ones
included. Typical uses: initialise scratch-pad tags, log a banner, start
a companion application.

```rhai
// scripts/10_startup.rhai
fn on_init() {
    // Mark the process as "booting" for SCADA.
    write("calculations.system_state", 1.0);
    log_info("Startup complete");
}
```

`PRISM_SKIP_ON_INIT=1` skips all `on_init` hooks (used by diagnostics).

`on_device_online(device)` runs when a device transitions to **available**:
the first values after connect or a reconnect after an outage (the device was
`error`/`offline` and came back). It receives the device name, so one hook can
serve several devices. On startup it also fires for every device that comes
online, so a device that was powered off at boot still gets initialised —
`on_init` alone would have written into a dead link.

```rhai
// scripts/04_particle_counter.rhai — reset the counter channels
fn on_device_online(device) {
    if device == "counter" {
        write_batch(#{ "counter.2um": 0.0, "counter.3um": 0.0 });
    }
}
```

`on_close()` runs once per **runtime session**: on graceful shutdown (Ctrl+C,
service stop) and before a full hot reload (`reload`). It is the cleanup hook —
stop a companion app started by `on_init`, write a final state, flush logs.
There is no skip switch: cleanup must run. A hard kill (task manager, `kill -9`)
runs nothing — register the companion as managed (section 3.6) so the runtime
stops it even then, and let the OS/user stop anything the core cannot.

```rhai
// scripts/00_session.rhai — the companion panel lives exactly as long as Prism.
fn on_init() {
    start_app_managed("user/panel/panel.exe");   // runtime owns the child
    log_info("Panel started");
}

fn on_close() {
    stop_app("user/panel/panel.exe");            // idempotent: no-op when absent
    log_info("Panel stopped, session closed");
}
```

> `on_close` is **not** the place for process-critical writes: by the time it
> runs the pollers are about to stop and physical commands may not reach the
> wire. Park outputs and stop companions — do not rely on a final Modbus write.

### 3.2 Cyclic logic: asynchronous poll loops

Interlocks, watchdogs, state machines and periodic collection are **polls**:
each `[[poll]]` entry runs a named function in a dedicated background thread
with its own interval. A poll that waits for an external process for two
seconds does not delay the control loop or other polls; a poll slower than its
interval simply starts the next run later.

```rhai
// scripts/40_interlocks.rhai
// Runs once a second as an asynchronous poll loop (bindings.toml below).

fn poll_interlocks() {
    // Constants live inside the function: script-level constants are not
    // visible to functions under the scheduler's call convention.
    const MAX_DROP_PA = 300000.0;

    if !read_bool("io_controller.pump_run") {
        return;
    }
    let drop = read("calculations.pressure_drop");
    if drop > MAX_DROP_PA || !read_bool("io_controller.valve_open") {
        write("io_controller.pump_run", 0.0);
        raise_alarm("io_controller.pump_run", "critical", "Pump interlock tripped");
    }
}
```

```toml
# scripts/bindings.toml
[[poll]]
name         = "interlocks"
function     = "poll_interlocks"
file         = "interlocks.rhai"
interval_ms  = 1000
run_on_start = true
```

Use polls for anything that must not block the control loop:

- interlocks, watchdogs and state machines;
- waiting for an external helper program (`spawn_wait`);
- slow data sources and statistics;
- staggered housekeeping: heartbeat tags, log rotation, stale-data alarms;
- periodic mirroring/reconciliation between Prism and a side system.

The function must not take arguments; its return value is ignored — write results
through `write()`/`raise_alarm()`.

```toml
# scripts/bindings.toml
[[poll]]
name         = "read_analyzer"
file         = "analyzer.rhai"
function     = "poll_analyzer"
interval_ms  = 5000
run_on_start = true
error_policy = "backoff"       # external device may be offline for a while
```

```rhai
// scripts/analyzer.rhai

// Reads the gas analyzer through a small helper program.
// The helper prints a single float ("nan" if unavailable).
fn poll_analyzer() {
    let out = spawn_wait("tools/read_analyzer.exe", ["--once"], 1500);
    if out == "" || out == "nan" {
        log_warn("Analyzer: no data");
        return;
    }
    write("analyzer.ch4_ppm", parse_float(out));
}
```

**Poll + watchdog pattern.** Scratch-pad tags make liveness visible to SCADA:

```rhai
// scripts/heartbeat.rhai
fn poll_heartbeat() {
    let beat = read("calculations.script_heartbeat");
    if !beat.is_finite() { beat = 0.0; }
    write("calculations.script_heartbeat", beat + 1.0);

    // The external link is expected to refresh this tag at least every 30 s.
    // The raised state is latched in a scratch tag, so the alarm is raised
    // once and cleared when the source comes back.
    let stale = now_ms() - read("calc.external_last_seen_ms") > 30000.0;
    let raised = read_bool("calculations.external_stale_raised");
    if stale && !raised {
        raise_alarm("calc.external_last_seen_ms", "warning", "External source is stale");
        write("calculations.external_stale_raised", 1.0);
    } else if !stale && raised {
        clear_alarm("calc.external_last_seen_ms");
        write("calculations.external_stale_raised", 0.0);
    }
}
```

Practical notes:

- Polls start after `on_init`, registry and alarm store are ready.
- Any full reload recreates poll threads together with the script engine
  (section 6), so configuration changes always take effect.
- A poll has no soft deadline by default (`timeout_ms = 0`;
  `[defaults].timeout_ms` does not apply to polls): a slow run simply delays
  that poll's next run. Two safeties still hold: runaway in-script loops hit
  the Rhai operation budget, and a blocking `spawn_wait` — which neither the
  budget nor a deadline can interrupt — waits at most 300 s (then returns an
  empty string; the child process keeps running).

### 3.3 Virtual (calculated) tags

Virtual tags are declared in `config/01_southbound/04_virtual_tags/` (modern) or as
`[[virtual_tag]]` in `bindings.toml` (legacy). Two flavours:

**Inline expression** — evaluated every `eval_interval_ms` (default 500 ms):

```toml
[[device.tag]]
name       = "pressure_drop"
unit       = "Pa"
expression = 'read("io_controller.pressure_in") - read("io_controller.pressure_out")'
```

**Named function** — `script_func` calls a Rhai function that must return a
number (`f64`), or a string for `data_type = "string"` tags:

```toml
[[device.tag]]
name        = "temp_fahrenheit"
script_func = "calc_temp_f"
```

```rhai
// scripts/30_transforms.rhai
fn calc_temp_f() {
    let c = read("io_controller.tank_temp");
    if !c.is_finite() {
        return 0.0 / 0.0;   // NaN: tag quality becomes Bad
    }
    (c * 1.8) + 32.0
}
```

**Text values** — `data_type = "string"`: the result of the expression or
`script_func` is projected to text (a string is used as is, numbers/bools are
rendered) and published as `string_value` in telemetry. String tags work in
every transport: MQTT commands and OPC UA writes carry text, `read_string()`
returns it in Rhai.

```toml
[[device.tag]]
name        = "batch_code"
data_type   = "string"
script_func = "make_batch_code"
```

```rhai
fn make_batch_code() {
    if read_bool("particle_select.stand_select") {
        "AB-" + read_string("io_controller.batch_no")
    } else {
        "AB-none"
    }
}
```

A string tag with neither `expression` nor `script_func` is a string
**scratch-pad**: it is not computed, its text is written externally (MQTT
command, OPC UA, Rhai) and kept in the store. The registry keeps only a numeric
projection (NaN) for text tags — use `read_string()` instead of `read()`.

A virtual tag with neither `expression` nor `script_func` is a **scratch-pad**:
nothing computes it, but scripts, MQTT, OPC UA and SCADA can read and write it.
Scratch-pads are the recommended way to keep state between script calls.

### 3.4 Alarms from scripts

Scripts own a reserved alarm slot per tag, so script alarms never collide with
configuration rules or the synthetic communication-failure alarm.

```rhai
fn poll_oil_temp() {
    let t = read("io_controller.oil_temp");
    if t > 95.0 {
        raise_alarm("io_controller.oil_temp", "critical", "Oil temperature critical");
    } else {
        clear_alarm("io_controller.oil_temp");
    }
}
```

`raise_alarm` is idempotent while the alarm is already active (no repeated
events), and `clear_alarm` on an inactive slot is a no-op — the calls above are
safe to run on every poll iteration.

Priorities: `"info"`, `"warning"`, `"critical"`, `"emergency"`.
`is_tag_failed(tag_id)` checks the communication-failure state.
`clear_all_alarms()` resets every alarm and the alarm history (the same as the
MQTT `clear_alarms` command).

These are **manual latched** alarms: `raise_alarm` holds the state until
`clear_alarm`. Threshold/rate/frozen detection belongs to the declarative rules
in `config/01_southbound/05_alarms/` (`04_logic/02_ALARMS.md`), which expose held signal tags
`alarm.<id>` readable with `read`/`read_bool` and can call Rhai handlers on
transitions.

### 3.5 Calibration and data transforms

Transforms are plain Rhai functions. A no-argument function is bound to a
virtual tag with `script_func`; helpers that take parameters are called from
other scripts (a poll, another transform):

```rhai
// scripts/30_transforms.rhai

// Cubic polynomial calibration helper.
fn calibrate_pressure(raw_adc) {
    let c0 = -10.5;
    let c1 = 0.0452;
    let c2 = -0.0000031;
    clamp(c0 + c1 * raw_adc + c2 * raw_adc * raw_adc, -40.0, 150.0)
}
```

Write-on-change pattern — avoid rewriting a Modbus register twice a second:

```rhai
fn conversate_setpoint() {
    let percent = read("pump_values.oil_set_pump_frequency");
    if !percent.is_finite() { return 0.0 / 0.0; }

    let raw = (clamp(percent, 0.0, 100.0) * 100.0).round();
    if raw != read("pump_values.oil_set_pump_frequency_raw") {
        write("plc1.oil_pump_frequency_setpoint", raw);
    }
    raw
}
```

### 3.6 External processes

The helpers launch an external **program directly, without a shell**:

- `cmd` (in the signatures below) is the program to run: a bare name is looked
  up in `PATH` (`"ping"`), otherwise it is a path to the executable
  (`"C:/tools/analyzer.exe"`, `"./user/panel.exe"`);
- `args` is a Rhai **array of strings**: every element becomes exactly one
  command-line argument, in order. Nothing is split, quoted or expanded —
  spaces and metacharacters inside one element are safe.

`spawn_wait("ping", ["-n", "1", "127.0.0.1"], 2000)` is the command line
`ping -n 1 127.0.0.1`: here `"ping"` is `cmd`, and the three array elements are
its arguments. An argument may itself contain spaces — pass it as one element:

```rhai
// argv: report.exe --out "report 1.csv"
spawn_wait("C:/tools/report.exe", ["--out", "data/report 1.csv"], 5000);
```

There is no shell, so `>`, `|`, `&&`, `%VAR%` and `$VAR` are **not**
interpreted. When shell syntax is genuinely needed, call the shell as the
program — the whole command becomes a single argument (you own its quoting):

```rhai
// Windows:
spawn_wait("cmd", ["/C", "dir data > data/dir.txt"], 5000);
// Linux/macOS:
spawn_wait("sh", ["-c", "ls -l data | wc -l"], 5000);
```

Relative paths — both the program and paths inside `args` — resolve against
the **working directory of the Prism process** (the instance folder). For
per-OS flags use `os_name()`:

```rhai
// One ping, portable across OSes (the "one packet" flag differs).
let out = if os_name() == "windows" {
    spawn_wait("ping", ["-n", "1", "127.0.0.1"], 2000)
} else {
    spawn_wait("ping", ["-c", "1", "127.0.0.1"], 2000)
};
```

Four lifecycle modes:

**Run and read (`spawn_wait`)** — waits for the program to finish and returns
its **stdout** (trimmed). `stderr` is discarded. An empty string comes back
when the program cannot start, exits non-zero or exceeds `timeout_ms` (spawn
errors and timeouts are logged). The wait is clamped to 300 s, and the process
is **not killed** on timeout — it keeps running on its own.

```rhai
// The helper prints a single float; parse it and publish the tag.
let out = spawn_wait("tools/read_analyzer.exe", ["--once"], 1500);
if out != "" {
    write("analyzer.ch4_ppm", parse_float(out));
}
```

**Fire-and-forget (`spawn_detach`, `start_app`)** — starts the program and
returns at once; stdio is discarded. A duplicate launch (same command, args and
mode) is skipped for the lifetime of the Prism process
(`spawn skipped (already started)` in the log), so a periodic script cannot
accumulate copies — while the detached child is still alive, nothing starts a
second one, reloads included.

```rhai
// One collector per session, however often the script runs.
spawn_detach("tools/collector.exe", []);
```

**Child-as-master (`spawn_until_closed`, `start_app_until_closed`)** — Prism
shuts down gracefully when the child exits. Use it when the companion *is* the
operator UI.

```rhai
start_app_until_closed("user/panel/panel.exe");
```

**Managed (`spawn_managed`, `start_app_managed` + `stop_app`)** — the runtime
owns the child: `stop_app` stops it, and a safety net stops everything managed
on graceful shutdown and before a full reload.

```rhai
// scripts/00_session.rhai
fn on_init()  { start_app_managed("user/panel/panel.exe"); }
fn on_close() { stop_app("user/panel/panel.exe"); }
```

| Function | Behaviour |
|---|---|
| `spawn_wait(cmd, args, timeout_ms) -> string` | runs; returns trimmed stdout, `""` on spawn failure / non-zero exit / timeout |
| `spawn_detach(cmd, args)` | fire-and-forget; duplicate launch (command+args+mode) skipped process-wide |
| `start_app(path)` | same, without arguments |
| `spawn_until_closed(cmd, args)` | child-as-master: Prism shuts down when the child exits |
| `start_app_until_closed(path)` | same, without arguments |
| `spawn_managed(cmd, args)` | runtime-owned: `stop_app` + automatic stop on shutdown/reload |
| `start_app_managed(path)` | same, without arguments |
| `stop_app(cmd)` | stop every managed child started with this command string, any arguments; safe no-op |

Managed mode notes:

- the lookup key is the **command string + arguments**: one executable may back
  several managed children as long as the arguments differ
  (`spawn_managed("C:/tools/panel.exe", ["db"])` and
  `spawn_managed("C:/tools/panel.exe", ["frontend"])` are two separately tracked
  companions), while `stop_app("C:/tools/panel.exe")` stops all of them;
- a managed child never outlives the runtime: a safety net stops every managed
  process on graceful shutdown and before a full reload, then releases the
  duplicate-launch guard so `on_init` can start it again;
- `stop_app` is idempotent: an already-exited child is reaped, unknown ones are
  logged and ignored;
- a **hard kill** of Prism (task manager, `kill -9`) skips the net — the child
  stays, as with any unsaved process state.

---

## 4. Runtime API reference

### Tag I/O

| Function | Returns | Notes |
|---|---|---|
| `read(tag_id)` | `f64` | last value; `NaN` if unknown/uninitialised |
| `read_bool(tag_id)` | `bool` | `true` when the value is finite and non-zero |
| `read_quality(tag_id)` | `string` | `"good"`, `"bad"`, `"uncertain"`, `"uninitialized"`, `"unknown"` |
| `device_online(device)` | `bool` | `true` while the core reports the device as online (the same state as `[Status] Devices: …`); offline/error/paused → `false` |
| `read_string(tag_id)` | `string` | last raw string value (AlarmStore) |
| `write(tag_id, value)` | — | virtual tags are published immediately; physical tags go to the device poller queue |
| `write(tag_id, text)` / `write_string(tag_id, text)` | — | string write; for `data_type = "string"` tags the text goes to the device as is; for virtual tags `read_string()` is updated immediately |
| `write_batch(map)` | `i64` | map of `tag_id → number`, only writable (rw/wo) tags; returns count |
| `write_batch_holding(map)` | `i64` | as above, Modbus holding registers only |
| `write_batch_coil(map)` | `i64` | as above, Modbus coils only |

```rhai
// Batch write example: only tags present in the map and writable are queued.
let queued = write_batch(#{
    "io_controller.valve_open": 1.0,
    "io_controller.pump_run": 1.0,
});
log_info(`queued ${queued} writes`);
```

#### Range and pattern writes

`write_batch` takes a fully built map — a range or a wildcard set is assembled
in the script itself (loops + string interpolation) and still reaches the
devices as **one batch**. Values are numbers (`int`/`float`); tags that are not
writable are skipped silently, the count of queued writes is returned.

```rhai
// value_table: 2..200 µm cells of one column (measurements of one run).
const RADII = [2, 3, 4, 5, 6, 7, 8, 10, 15, 20, 25, 30, 50, 100, 150, 200];

fn write_column(prefix, index, values) {
    let batch = #{};
    let n = values.len();
    if n > RADII.len() {
        n = RADII.len();
    }
    for k in 0..n {
        batch[`value_table.${prefix}_${RADII[k]}um_${index}`] = values[k];
    }
    write_batch(batch)
}
```

```rhai
// One value over a cross-product of ranges: prefixes × columns × radii
// (e.g. reset all table cells before a new test run).
fn clear_ranges(value) {
    let batch = #{};
    for prefix in ["oil_before", "oil_after", "fuel_before", "fuel_after"] {
        for i in 1..=11 {
            for r in RADII {
                batch[`value_table.${prefix}_${r}um_${i}`] = value;
            }
        }
    }
    write_batch(batch)
}
```

Nested loops with interpolated tag names are supported in both build profiles
(debug and release).

#### Write paths and authority

`write()` is a **command**, not a sample:

- a physical tag is queued to its device poller and executed in queue order;
  the tag then shows the poller readback — telemetry stays true to the device;
- a virtual tag is published immediately (scratch-pads keep the written value
  until the next write).

Script writes are published under the `script` authority — the lowest level of
the same-millisecond tie-break
([`01_getting_started/02_ARCHITECTURE.md`](../01_getting_started/02_ARCHITECTURE.md) §2):
an alarm action or an operator command wins a same-instant collision
**by design**, while any newer write (including the next evaluation tick)
always passes. The arbiter is a same-millisecond tie-break, not ownership.

Practical rules for auxiliary logic:

- an interlock that must **hold** an output writes it on every tick (or latches
  a scratch-pad tag and lets the actuator logic follow it);
- never write a compute loop's output tag to "override" the loop — change its
  setpoint or enable condition instead;
- a write to a physical **input** tag does not stick: the next poll publishes
  the real value, which is the point.

### Math and utilities

| Function | Returns | Notes |
|---|---|---|
| `scale(raw, eng_max, raw_max)` | `f64` | `raw * eng_max / raw_max`; returns `raw` when `raw_max == 0` |
| `clamp(value, min, max)` | `f64` | clamps into the range |
| `now_ms()` | `f64` | Unix epoch wall-clock time, ms (not monotonic) |
| `os_name()` | `string` | host OS as Rust names it: `windows`, `linux`, `macos` |

### Batch snapshot and tag history

| Function | Returns | Notes |
|---|---|---|
| `snapshot([tag_id, ...])` | `f64[]` | coherent batch read: all values in one pass, no accepted write in between (`NaN` for unknown tags) |
| `snapshot_quality([tag_id, ...])` | `string[]` | quality of the same batch |
| `history(tag_id, window_ms)` | `f64[]` | samples recorded within the window, oldest first; empty when history is not enabled |
| `history_samples(tag_id, window_ms)` | `Array` | maps `{value, ts_ms, mono_ms, quality}` |

History is opt-in per tag (`config/01_southbound/06_history/history.toml`,
`depth`/`sample_ms`); only real accepted samples are recorded. See
`05_wasm/03_ML.md` for time-series feature assembly.

### ML inference

| Function | Returns | Notes |
|---|---|---|
| `ml_submit(plugin, features)` | `i64` | non-blocking; job id, `-1` when rejected (unknown plugin/full queue) |
| `ml_done(id)` | `bool` | the job finished (successfully or with an error) |
| `ml_result(id)` | `f64[]` | model outputs; empty while pending or after an error |
| `ml_error(id)` | `string` | error message (empty on success) |
| `ml_infer(plugin, features)` | `f64[]` | synchronous, bounded wait; **only in `[[poll]]` functions** — refused in virtual tags and alarm hooks |
| `ml_metrics()` / `ml_metrics(plugin)` | `Array`/`Map` | calls, errors, timeouts, latency p50/p95/p99, model version |

```rhai
// Async orchestration from a poll loop: submit now, collect when ready.
fn ml_watchdog() {
    if is_tag_failed("motor1.vib") { return; }
    let vib = history("motor1.vib", 1000);          // last second of samples
    if vib.len() < 32 { return; }
    let features = [];
    for i in 0..32 { features.push(vib[vib.len() - 32 + i]); }
    let id = ml_submit("anomaly", features);
    if id < 0 { return; }
    write("ml.pending_id", id);
}

fn ml_collect() {
    let id = read("ml.pending_id");
    if id < 0 || !ml_done(id) { return; }
    let err = ml_error(id);
    if err != "" { log_warn(`ml: ${err}`); return; }
    let out = ml_result(id);
    if out.len() > 0 {
        write("ml.anomaly_score", out[0]);
        if out[0] > 0.8 { raise_alarm("ml.anomaly", "high anomaly score"); }
    }
}
```

The full ML architecture (plugin ABI, scheduled jobs, model hot swap,
replay) is in `05_wasm/03_ML.md`.

### Alarms

| Function | Returns | Notes |
|---|---|---|
| `get_alarm_priority(tag_id)` | `string` | priority of first active alarm |
| `get_alarms_by_priority(priority)` | `Array` | maps `{device, tag, message, value, acknowledged}` |
| `is_tag_failed(tag_id)` | `bool` | communication failure is active |
| `raise_alarm(tag_id, priority, message)` | — | reserved script slot; state is held until cleared |
| `clear_alarm(tag_id)` | — | clears the script slot |
| `clear_all_alarms()` | — | clears every alarm and the alarm history |

### Logging

`log_info(msg)`, `log_warn(msg)`, `log_error(msg)` — prefixed with `[rhai]` in
the Prism log.

---

## 5. Limits, error policy, diagnostics

Every script call is bounded by:

1. **Operation budget** (`op_budget_tick` / `op_budget`). Enforcement uses the
   Rhai progress callback; exceeding the budget aborts the call.
2. **Soft deadline** (`timeout_ms`). Checked by the same callback between Rhai
   operations. A blocking native call (`spawn_wait`) cannot be preempted; the
   abort happens after it returns.

On violation or script error the configured policy applies:

| Policy | `[[poll]]` |
|---|---|
| `log_and_hold` | log the error; run again at the next interval |
| `backoff` | delay doubles per consecutive error (max 60 s); a success resets it |
| `disable_script` | stop the poll until the next reload |

`on_init` and `on_close` run **once per session**: a violation is logged and the
remaining scripts still run (there is no next interval to back off).

Diagnostics to look for in the log:

```text
[scripts] Loaded: main.rhai (enabled=true, on_init=true, on_close=true)
[scripts] Engine ready: 3 script(s) (3 enabled), 2 poll(s)
[scripts] Poll 'read_analyzer' started: fn poll_analyzer() every 5000 ms
[scripts] Poll 'interlocks' (poll_interlocks) failed: script timeout exceeded (policy=LogAndHold)
[scripts] Poll 'bms_poll' disabled until reload (error_policy=disable_script)
[scripts] Poll 'bms_poll': function 'poll_bms' not found in 'bms.rhai'
[rhai] started pid=4212: user/panel/panel.exe [] (managed)
[rhai] stopped managed app 'user/panel/panel.exe' (shutdown)
```

---

## 6. Hot reload

The runtime watches `scripts/**/*.rhai` (and `bindings.toml`), every `*.toml`
under `config/`, and the WASM artifacts that running devices reference (a
device plugin may live outside `config/`, e.g. `plugins/<module>/`).

A batch of changes is debounced for one second and then becomes a **pending
plan**. Nothing restarts on save: the console prints the plan and the runtime
waits for a decision — `p` preview, `a` apply, `r` full reload, `c` cancel.
Applying uses the narrowest scope that can absorb the change:

| Change | What is rebuilt on apply |
|---|---|
| `scripts/*.rhai`, `scripts/bindings.toml` | the script engine and its `[[poll]]` scheduler; device pollers keep running |
| one device module (`01_southbound/<proto>/<module>/…`, `03_wasm/01_source/<module>/…`) | the pollers of that module only |
| a WASM artifact | the device pollers that reference it (compute and ML artifacts are staged by their own runners, doc `16` §7) |
| the tag list of a device, a new device, a removed device | the plan reports `full rebuild required`; `a` applies it as a full reload |
| core / MQTT / OPC / alarm / virtual-tag config | the plan reports `full rebuild required`; `a` applies it as a full reload |

The plan is identical in the console and in `prism-dbg` (the `RELOAD` screen):
both list the affected files and the steps that would run. `r` rebuilds
everything even when the plan is granular.

A device restart keeps the live view intact:

1. The poller task is aborted and awaited, so its socket or serial port is
   released before the replacement connects.
2. Commands that were queued for the equipment are reported as failed instead
   of disappearing.
3. The store keeps the last value, quality, device status and the live alarm
   state of the tags that survived the edit (`reregister_device`): SCADA sees
   neither a blank value nor an offline flap.
4. A module that does not parse is **rejected**: nothing is restarted, the
   running system keeps working until the file is fixed. The same applies when
   a whole config reload fails validation, and to any edit that reshapes the tag
   registry (the tag list, a new or removed device): it is valid but needs an
   explicit `r` + Enter, so a save never restarts the runtime unexpectedly.

A script reload does not touch the pollers (they resolve the engine through
`ScriptHandle` on every call):

1. The new engine is compiled **before** the swap — on a compile error the
   running session stays in service.
2. `on_close()` of the previous session runs first (companions are also stopped
   by the managed-app safety net), then `bindings.toml` is re-read and the poll
   threads are recreated.
3. `on_init()` runs on the new session. Put idempotent logic there, or guard it
   with a scratch-pad tag. `PRISM_SKIP_ON_INIT=1` skips it entirely.

A **full reload** rebuilds everything: every poller, MQTT, virtual tags, the OPC
UA server, compute and ML modules. It runs only on demand — `r` + Enter or the
MQTT `control.reload` topic — never as a side effect of saving a file. The tag
registry is rebuilt, but its state is **carried over**: the last stored value,
timestamp and quality of every tag are seeded into the new registry, so scripts
do not read `NaN` in the reload window and the write arbitration continues as if
nothing happened. Live sources overwrite the seeds with their first fresh
sample; a configured `initial_value` preset is applied only to tags that never
held a value. A force override is *not* carried over — the override layer
releases its forces on reload.

The same operations are available as service tags for SCADA and scripts:
`system.reload`, `system.reload_module` and `system.scripts_reload` (`04_logic/03_SERVICE_TAGS.md`).

---

## 7. Pre-flight validation

```bash
prism-devtools validate rhai --root .
```

`prism-devtools` is the maintenance CLI shipped with every instance
(`devtools/tooling/prism-devtools`) and described in
[`03_tooling/06_DEVTOOLS.md`](../03_tooling/06_DEVTOOLS.md). It compiles every script with the same Rhai engine as the core
and verifies config references (`script_func`, `[[poll]]`, `[[script]]`);
diagnostics are rendered with source snippets and exact
positions. It complements the runtime compile log but does not replace it:
functions are resolved at call time, so a typo in `bindings.toml` shows up as a
boot warning (“function not found”) or a poll log line.

Recommended flow:

1. `prism-devtools validate rhai --root .`
2. `prism.exe --check-config`
3. Start Prism and watch the first `[scripts]` lines.

---

## 8. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Poll never fires | Function name typo (`Poll '…': function not found`), file filter mismatch, `enabled = false`, or `run_on_start = false` + long interval |
| Poll runs slower than `interval_ms` | Expected under overrun: the next run starts after the previous one finishes; slow work belongs in its own poll |
| `write()` seems to do nothing from a poll | The tag is physical and no device poller owns it, or the tag is not `rw`; virtual tags are published immediately |
| Script state resets each call | Expected: use scratch-pad tags instead of module-level `let` |
| `Variable not found` for a script-level `const` | Rhai functions cannot see script-level constants: declare the constant inside the function (or inline the literal) |
| Values lost after reload | They live only in a Rhai variable; persist them in tags |
| Poll aborts with timeout | Explicit `timeout_ms` too small for the blocking work; set `0` or increase it |
| CPU spikes after an edit | An accidental infinite loop; the operation budget aborts at `op_budget_tick`, check the error policy log |
| Custom payload field is missing | `[[channel.field]]`: the source tag has no good value, or the `for` pattern matches nothing (doc `07` §6) |
| `on_close` never runs | It only runs on graceful shutdown and before a full reload (hard kill runs nothing); check the `[scripts] Loaded: … on_close=true` line and the trigger list |
| `stop_app` says “is not running” | The argument must be exactly the command string passed to `start_app_managed`/`spawn_managed` (the executable path, not the pid) |
| A companion app outlives Prism | It was started with `start_app`/`spawn_detach` (fire-and-forget): use `start_app_managed`/`spawn_managed` + `stop_app`, or accept the child outliving the core |
| `Expression exceeds maximum complexity` at script load | The Rhai parser depth limit (older builds halved it in debug): nested loops with interpolated tag names are supported since the limits are pinned in both profiles — rebuild Prism if the error persists |
