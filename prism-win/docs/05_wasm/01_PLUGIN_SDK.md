# SDK for custom WASM compute modules (`compute`)

Status: ABI `prism:compute@0.2`, Rust SDK `crates/compute-sdk`, example
(Kalman filter) `crates/compute-plugin-example`, host `crates/compute-host`,
and core integration (`config/03_wasm/02_compute/<module>/`, `src/compute/`) —
ready. Module hot-reload is strictly confirmation-gated.

This chapter is about custom compute modules. Vendor modules are supplied as
ready-made artifacts and use the same ABI; they are covered in separate
chapters, and their number grows as development proceeds.

## 1. Why compute modules

A compute module is **arbitrary programmable logic bound to already existing
Prism tags**. Math is a frequent but not the only case: ML inference, SCADA
functions, scripted automation, any state machines — anything that is
expressed in code and works on tags:

```text
[[input]].tag   ──read──►  tick-frame  ──►  WASM component (prism:compute)
                                                │
[[output]].tag  ◄──write── result-frame ◄───────┘
[[param_tag]].tag ──override──► params
```

A compute module **does not declare** tags of its own: inputs, outputs, and
parameters are references to tags declared by devices (`config/01_southbound/`,
`config/03_wasm/01_source/`) or by virtual tags. If you need your own devices and
their tags, that is a different kind of module, `source`
(`02_DEVICE_DRIVERS.md`).

**No black boxes.** A module's contract lies entirely in its config: the module
sees and touches exactly the tags assigned to it
(`input`/`output`/`param_tag`/`command_tag`/`event`), and nothing more — the
plugin's only import is `host.log`. From inside WASM you can neither create a
tag nor access someone else's: the config always shows who creates a tag and
who uses it.

Hence the combined case: a module needs both its own tags and existing ones —
these are **two modules** linked through the registry, not one artifact with a
dual role:

```text
config/03_wasm/01_source/counter/    # owner: the device and its tags
config/03_wasm/02_compute/counter_math/  # consumer: blocks on counter.* and any other tags
```

Both contracts sit side by side in the config, and intermediate values are
visible to OPC UA/MQTT/alarms without dissecting the artifact.

Examples: the Kalman filter and other observers, FFT/spectral analysis,
soft sensors (virtual sensors), nonlinear calibration, MPC/optimization,
ML inference, SCADA logic, and scripted automation — the list is open.
Blocks run in **separate threads with their own period** and do not block
device polling or other blocks.

| | Rhai script (`../04_logic/01_RHAI.md`) | Compute module |
|---|---|---|
| Entry barrier | low | Rust/any language with the Component Model |
| Speed | interpreter | compiled WASM + fuel |
| Isolation | Rhai sandbox | WASM sandbox, memory limit |
| State | tags only | own + snapshot/restore |
| Purpose | logic, interlocks, polling | any programmable tag processing |
| Config | `scripts/bindings.toml` | `config/03_wasm/02_compute/<module>/` |

Selection rule: if the processing is heavy or must be a versioned artifact —
use a custom compute module; everything else (logic, interlocks, computed
tags) — Rhai.

> **Not to be confused with device plugins.** Instrument drivers on a COM port
> are a separate ABI `prism:device@0.1` with serial imports and their own tags
> (guide `05_wasm/02_DEVICE_DRIVERS.md`, folders
> `config/03_wasm/01_source/<module>/`): compute modules have no port access and
> never will — this is part of their sandbox.
>
> **Not to be confused with report plugins.** Reports are a separate ABI
> `prism:report@0.1` (`05_wasm/04_REPORTS.md`, folders
> `config/03_wasm/04_report/<module>/`): the host reads the tags declared in the
> report config, assembles a document and passes it to the renderer; the plugin
> has no tag or filesystem access and returns the XLSX bytes.
>
> **Not to be confused with ML plugins.** Inference is a separate ABI
> `prism:ml@0.1` (`05_wasm/03_ML.md`, folders
> `config/03_wasm/03_ml/<module>/`): an ML plugin exports `infer(features)` and
> has no access to tags at all — the feature vector is collected by the host
> (`snapshot`/`history`), the host owns the schedule, and the model is stored
> as a separate artifact.

## 2. The `prism:compute@0.2` contract

Full WIT: `crates/compute-wit/wit/compute.wit`. Key points:

- `get-info() -> plugin-info` — descriptor (name, version, `abi = "0.2"`,
  `max-blocks`); the host verifies the ABI exactly;
- `configure(list<block-spec>) -> result<_, config-error>` — create blocks
  (an error rejects the whole set);
- `apply-config(specs) -> list<config-error>`, `remove-blocks(ids)` — change
  the set without a restart;
- `tick(list<tick-frame>) -> list<result-frame>` — batch tick of all blocks
  in the instance; the result frame carries outputs, `skip-write`, `message`,
  and `events`;
- `command(block-id, block-command)` — universal command: name + optional
  value; the sources are set by the host config (tags, MPC, SCADA/MQTT via
  tags);
- `snapshot(block-id) -> option<list<f64>>`,
  `restore(block-id, state) -> bool` — state transfer (hot-reload);
- `host.log(level, message)` — the only side effect.

An event (`block-event`) is a **level**, not a pulse: the plugin sends it on
every tick while it is active, and once with `active = false` when it clears.
The host turns transitions into tag alarms (see §4).

Data is flat only: `f64`, `u32/u64`, `bool`, enum, record, list,
`option<string>` (free-form configuration and diagnostics). The plugin has no
clock, network, or files: time comes in the frame (`now-ms`, `dt-ms`).

## 3. Quick start (Rust SDK)

### 3.1 Plugin crate

```toml
# Cargo.toml
[package]
name = "my-filter"
version = "0.1.0"
edition = "2024"

[lib]
crate-type = ["cdylib"]

[dependencies]
compute-sdk = { path = "../compute-sdk" }   # or git/registry, once published
```

```rust
// src/lib.rs
#![cfg(target_family = "wasm")]

use compute_sdk::{export_plugin, ComputePlugin, BlockSpec, ResultFrame, TickFrame};

#[derive(Default)]
struct Scale {
    factor: f64,
}

impl ComputePlugin for Scale {
    fn configure(&mut self, spec: &BlockSpec) -> Result<(), String> {
        // Parameters arrive by name; the block also has a free-form config.
        self.factor = spec
            .params
            .iter()
            .find(|p| p.name == "factor")
            .map(|p| p.value)
            .unwrap_or(1.0);
        if !self.factor.is_finite() {
            return Err("factor must be finite".into());
        }
        Ok(())
    }

    fn tick(&mut self, frame: &TickFrame) -> ResultFrame {
        let value = frame.input(0) * self.factor;
        ResultFrame::new(frame.block_id).with_output(value)
    }
}

export_plugin!(Scale);
```

`export_plugin!` is called once per component and generates the WIT world
exports; the author does not write converters.

### 3.2 Build

```sh
rustup target add wasm32-wasip2        # once
cargo build -p my-filter --target wasm32-wasip2 --release
# target/wasm32-wasip2/release/my_filter.wasm
```

### 3.3 Installation

1. Copy the `.wasm` into the project, for example `plugins/my-filter/my_filter.wasm`.
2. Create the module folder `config/03_wasm/02_compute/temp_scale/`: each
   subdirectory of `compute/` is one module, and its `*.toml` files are
   fragments of one config (read in name order).

`01_module.toml` — the plugin and common settings:

```toml
[defaults]
enabled = true
error_policy = "log_and_hold"     # log_and_hold | disable_block | backoff

[[plugin]]
id = "my-filter"
path = "../plugins/my-filter/my_filter.wasm"   # relative to the config/ directory
max_memory_mb = 64
fuel_per_call = 500000000
```

`02_blocks.toml` — blocks and their binding to already existing tags:

```toml
[[block]]
name = "temp_scale"
plugin = "my-filter"
period_ms = 100

[block.params]
factor = 1.8

[[block.input]]
tag = "io_controller.tank_temp"

[[block.output]]
tag = "calculations.tank_temp_f"
scale = 1.0                     # value / scale goes to the tag

# Alarms: a plugin event lives in the tag's alarm section.
# [[block.event]]
# code = "sensor_fault"
# tag = "io_controller.tank_temp"
# priority = "critical"         # info | warning | critical | emergency
# message = "{block}: {code} ({value})"

# Commands: tag change → block-command to the plugin.
# [[block.command_tag]]
# name = "reset"
# tag = "calculations.scale_reset"
```

3. Restart Prism or press `r` in the console: device modules and scripts are
   reloaded automatically, but a **compute module's TOML** is not — a granular
   reload leaves `03_wasm/02_compute/**` alone (only the `.wasm` artifact itself
   is staged, §7). Input/output tags must exist — they are declared by
   devices (`config/01_southbound/`, `config/03_wasm/01_source/`) or by virtual
   tags; otherwise the block starts with `NaN`/`Bad` at the input, and a
   write to an unknown output is skipped (with a warning in the log).

License: WASM modules are not licensed separately — there is no feature gate
or module-count limit; everything works in the free version as well. The only
license limit is the number of tags (`../06_operations/01_LICENSING.md`).

## 4. Reference for `config/03_wasm/02_compute/<module>/*.toml`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `defaults.enabled` | bool | `true` | global switch for compute blocks |
| `defaults.error_policy` | string | `log_and_hold` | reaction to a WASM call error |
| `plugin[].id` | string | — | identifier for references from blocks |
| `plugin[].path` | string | — | path to the `.wasm` relative to the `config/` directory |
| `plugin[].enabled` | bool | `true` | disable the module without removing it |
| `plugin[].max_memory_mb` | int | `64` | instance memory limit |
| `plugin[].fuel_per_call` | int | `500000000` | CPU fuel per call |
| `plugin[].confirm_timeout_secs` | int | `120` | hot-reload confirmation window; after expiry the version is not applied |
| `plugin[].auto_rollback` | bool | `true` | auto-rollback to the previous version after a series of host errors |
| `plugin[].auto_rollback_after` | int | `3` | threshold of consecutive host errors for rollback |
| `block[].plugin` | string | — | module id |
| `block[].period_ms` | int | `100` | tick period (minimum 1 ms) |
| `block[].enabled` | bool | `true` | disable the block |
| `block[].name` | string | — | block name for logs |
| `block[].error_policy` | string | defaults | policy override |
| `block[].config` | string | — | free-form plugin configuration (usually JSON) |
| `[block.params]` | map | — | static numeric parameters |
| `[[block.input]] tag` | string | — | input tag; order = order in the frame |
| `[[block.output]] tag` | string | — | output tag; order = order of values |
| `[[block.output]] scale` | float | `1.0` | divisor before writing: `value / scale` goes to the tag |
| `[[block.event]] code/tag` | string | — | event → the tag's alarm section (the module's service slot) |
| `[[block.event]] priority` | string | `warning` | `info` / `warning` / `critical` / `emergency` |
| `[[block.event]] message` | string | — | template: `{block}`, `{code}`, `{value}` |
| `[[block.command_tag]] name/tag` | string | — | universal command: tag change → `block-command` |
| `[[block.param_tag]] name/tag` | string | — | runtime override of a parameter from a tag |

Semantics:

- Each subdirectory of `03_wasm/02_compute/` is one module; `[defaults]`
  applies to the whole instance (the first explicit value among the modules
  wins); plugin ids and block names are unique within the instance.
- Blocks of one module run in a single WASM instance, but in batch mode: the
  host gathers frames from all blocks that are due and calls `tick` once per
  cycle.
- `param_tag` overrides a static parameter when the tag has `good` quality
  and a finite value; otherwise the static value applies. The last value with
  the same name wins, so the plugin sees the current override.
- `[[block.output]] scale` divides the value before writing (register = EU/scale),
  like `out_scale` on control loops.
- **Alarms.** Module events are bound to a tag (`[[block.event]]`) and live
  in its **plugin service slot** — alongside config rules, synthetic-fail, and
  Rhai alarms. The `active: false → true` transition raises an alarm with the
  given priority and message; the reverse one clears it. The alarm is visible
  in MQTT/history/SCADA as an ordinary tag alarm.
- **Commands are fully universal.** Any source that can write tags
  (SCADA/MQTT, OPC UA, Rhai, MPC) can command a block:
  `[[block.command_tag]]` sends `block-command { name, value }` when the tag
  value changes (including the first reliable one — the operator's intent is
  restored after a restart). For in-process sources there is
  `ComputeRunner::command_handle()` with `send(block_name, cmd)`.
- Outputs are written to tags as is (EU, respecting `scale`), with 3 decimal
  places, through the same path as Rhai writes: virtual tags are published
  immediately, physical ones — through the poller queue (for integer registers
  the queue rounds the value to the tag's `data_type`). Writing **does not block the tick**:
  the worker puts the value into a non-blocking queue, a separate runtime task
  delivers it to the store.
- `NaN`/`Inf` at the output is not written: a log line + skip.
- `skip-write = true` in `result-frame` skips writing all outputs of the tick.

## 5. Example: Kalman filter

Full source — `crates/compute-plugin-example/src/lib.rs`. A scalar
filter (model `x' = x + w`, `z = x + v`) with parameters `q` (process noise)
and `r` (measurement noise):

```rust
fn tick(&mut self, frame: &TickFrame) -> ResultFrame {
    let z = frame.input(0);
    let quality = frame.input_quality(0);
    let valid = quality == Quality::Good && z.is_finite();

    if !self.initialized && valid {
        self.x = z;
        self.p = 1.0;
        self.initialized = true;
    }

    self.p += self.q;                    // predict

    let mut message = None;
    if valid {
        let k = self.p / (self.p + self.r);   // update
        self.x += k * (z - self.x);
        self.p *= 1.0 - k;
    } else {
        message = Some("measurement rejected: bad quality");
    }

    let mut out = ResultFrame::new(frame.block_id).with_output(self.x);
    if let Some(m) = message { out = out.with_message(m); }
    out
}
```

What the example demonstrates: the `q`/`r` parameters, input quality handling
(an unreliable measurement → prediction without correction + a message),
validation in `configure`, `apply_config` without resetting state,
snapshot/restore (`[version, x, p, q, r, initialized]`).

Build the module and install it:

```sh
cargo build --target wasm32-wasip2 --release
```

Copy the resulting `.wasm` into `plugins/` of the project and reference it in
the module configuration (section 3.3). `prism --check-config` validates the
configuration; load errors appear in `logs/prism.log`.

## 6. The `ComputePlugin` trait

| Method | When called | Required |
|---|---|---|
| `info()` | when the module is loaded | no (default) |
| `configure(&mut self, &BlockSpec)` | block creation (startup, new block-id, hot-reload) | **yes** |
| `apply_config(&mut self, &BlockSpec)` | config change without recreation | no (default — error) |
| `tick(&mut self, &TickFrame) -> ResultFrame` | every block period | **yes** |
| `snapshot(&self) -> Vec<f64>` | hot-reload/state transfer | no (default — empty) |
| `restore(&mut self, &[f64]) -> bool` | restore | no (default — empty) |

Conventions:

- `Default` is required: the host creates blocks itself (`P::default()`), no
  constructor is called; one instance of the type = one block with its own state.
- A `configure` error → the host logs `config-error` and does not start the
  block; it is better to fail at startup than to compute garbage.
- `snapshot`/`restore` — your format; version it with the first element and
  return `false` on incompatibility.
- `max-blocks = 0` in `plugin-info` — "no limit" (limits are set by the host).

### 6.1 `TickFrame`: what comes in

| Field/method | Meaning |
|---|---|
| `block_id`, `now_ms`, `dt_ms` | block id and monotonic time/period from the host |
| `inputs: list<channel-value>` | input values in `[[block.input]]` order |
| `frame.input(i)` | `f64` (NaN if the channel is missing) |
| `frame.input_quality(i)` | `good/uncertain/bad` (Bad if the channel is missing) |
| `frame.input_timestamp_ms(i)` | value timestamp |
| `params: list<param>` | statics + overrides from `param_tag` |
| `frame.param(name)` | `Option<f64>` — the last value with this name |

### 6.2 `ResultFrame`: what to return

| Field/helper | Default | Meaning |
|---|---|---|
| `outputs` | empty | output values in `[[block.output]]` order |
| `.with_output(v)` / `.with_outputs(iter)` | — | add values |
| `skip_write` / `.skip_write(true)` | `false` | do not write outputs on this tick |
| `message` / `.with_message(s)` | `None` | a message change is logged once |
| `ResultFrame::hold(id, msg)` | — | `skip_write = true` + message |

If the plugin returns fewer values than there are bound outputs, the host
warns and writes only the ones provided; extra values are ignored.

## 7. Module hot-reload (strictly confirmation-gated)

A worker thread watches the `.wasm` timestamp (mtime + size). On change,
the new version is **staged**, but **not applied automatically**: by default
(and always in this implementation) explicit operator confirmation is
required.

Sequence:

1. **500 ms debounce** — protection against a partially written artifact.
2. **Staging**: the `staging_gate` is taken only if there is no other
   unconfirmed stage in the system; then the new version is loaded, its ABI
   and unchanged name are checked, `configure` runs with the current blocks,
   state is transferred via `snapshot` → `restore`, and a smoke tick runs
   against the live registry (state after the smoke tick is rolled back).
   A crashing or garbage-producing build is filtered out here and is never
   applied.
3. **Waiting for the operator**: the old module keeps computing; the name,
   versions, and `sha256` are written to the log and MQTT
   (`diagnostic`, target `compute`, code `compute_staged`); confirmation is
   `y`/`n` in the console or MQTT `plugin_confirm` (`{"apply": true|false}`) —
   a shared channel for all WASM modules (user and vendor), with a shared
   confirmation epoch.
4. **Application** — only on `y`; `n` or expiry of
   `confirm_timeout_secs` — the version is not applied (events
   `compute_applied` / `compute_rejected` / `compute_confirm_timeout`).
5. **Auto-rollback**: after `auto_rollback_after` consecutive host errors
   (trap/fuel) the module reverts to the previous working version (kept in
   memory until the next successful upgrade); event `compute_rollback`.
   Blocks disabled by the error policy are brought back into service.

Important: one unconfirmed stage per system — two "confirmation arrows"
cannot cross.

## 8. Errors, limits, sandbox

- WASM instance: no network/filesystem, memory limit (`max_memory_mb`), fuel
  (`fuel_per_call`) per call, the only import is `host.log`.
- A `tick` error (trap, fuel, panic) is handled by the block policy:
  `log_and_hold` — continue on schedule; `backoff` — pause with
  doubling (up to 60 s), success resets it; `disable_block` — the block
  is disabled until the configuration is reloaded.
- An error in one block does not affect other blocks or device polling:
  each module lives in its own thread.
- Plugin messages (`message`) are logged on value change — handy
  for "measurement rejected"/"converged".

## 9. Debugging and testing

1. Test the algorithm as ordinary Rust code outside WASM (the SDK is a thin
   wrapper; move the math into a separate module).
2. Run it through the real host — like `crates/compute-host/tests/kalman_example.rs`:
   `configure`, a series of `tick`s, convergence check, and `snapshot/restore`.
3. End-to-end run of the core runtime — `prism/tests/compute_runner.rs`:
   input tag → block → output tag in the registry. Staging/confirmation —
   `prism/tests/compute_hot_reload.rs` (a corrupted artifact is not applied,
   a valid one waits for explicit confirmation).
4. Logs: `[compute]` (runtime) and `compute_plugin` (from `host.log`).

| Symptom | Cause / action |
|---|---|
| `artifact not found` | wrong `path` (it is relative to the `config/` directory) |
| `plugin ABI mismatch` | `get-info().abi` is not equal to `0.2` (exact match) |
| `configure failed: …` | your `Err` from `configure`; check the `block-spec` |
| `non-finite output … skipped` | `NaN/Inf` output; return `skip_write` or fix the math |
| `input tag … not found` | the tag is not declared by devices (`01_southbound/`, `03_wasm/01_source/`) or virtual tags |
| block does not tick | `enabled = false` or an unknown `plugin` |
| `unknown block id` in a message | a result for a block that is not in the instance (config desync) |

## 10. What's next (roadmap)

Already done: events → tag alarms, universal commands (tags + handle),
output scaling, non-blocking writes.

- signing of compute module manifests and downgrade protection;
- publishing block diagnostics as separate telemetry channels;
- additional language templates and the `prism plugin …` CLI.
