# prism-adrc — Vendored Control Module (compute API)

> **A separate product.** This document is not part of the numbered series of
> platform documentation (the user documentation under `docs/`): `prism-adrc`
> is installed into a project as an ordinary compute module and evolves
> together with its own toolset.

`prism-adrc` is a compute module of the Prism platform: a full-fledged control
loop (ADRC/PID) on the common ABI `prism:compute@0.2`, just like any
user filters/observers. The module is installed, updated, and
rolled back by the common compute mechanism, with mandatory hot-reload
confirmation.

```
pollers → TagRegistry → compute-runtime (blocks on schedule)
                              │ TickFrame: pv/sp/enable/… + params
                              ▼
                        prism-adrc (adrc-core)
                              │ ResultFrame: output_value, z1…z3, mode, events
                              ▼
                      [[block.output]] → tags (and the tag's alarm section)
```

Inside is a deterministic `adrc-core` kernel (TD → ESO → NLSEF, FSM,
stagnation, PWM, protections): the same math as in the native parity tests.

## 1. Build and Installation

```sh
# the crate is excluded from the platform workspace (Cargo.toml, exclude) — a build directory of its own;
# in the product's separate repository, `cargo build --target wasm32-wasip2 --release` will remain
cargo build --manifest-path crates/compute-plugin-adrc/Cargo.toml \
    --target wasm32-wasip2 --release --target-dir target
# target/wasm32-wasip2/release/compute_plugin_adrc.wasm
```

The artifact is placed in the project's `plugins/prism-adrc/`, and the path is written
in the module config — the folder `config/03_wasm/02_compute/<module>/` (for example,
`config/03_wasm/02_compute/control_loops/01_plugin.toml`):

```toml
[[plugin]]
id = "prism-adrc"
path = "../plugins/prism-adrc/compute_plugin_adrc.wasm"
max_memory_mb = 64
confirm_timeout_secs = 120    # hot-reload confirmation window
auto_rollback = true          # rollback after a series of host errors
auto_rollback_after = 3
```

When the `.wasm` changes, the new version is staged, passes a smoke tick, and
**waits for confirmation** (`y`/`n` in the console or MQTT `plugin_confirm`);
timeout = rejection. Loop state is carried over by a snapshot (see §8).

## 2. Minimal Block

```toml
[[block]]
name = "flow_control"
plugin = "prism-adrc"
period_ms = 100
config = '{"inputs":{"pv":0,"sp":1}}'

[[block.input]]
tag = "plc.flow"
[[block.input]]
tag = "plc.flow_sp"

[[block.output]]
tag = "plc.pump_speed"
scale = 0.01
```

One block = one loop. `config` is JSON, described below; by default
the inputs are `pv = 0`, `sp = 1`, and there is a single output — `output_value` (control in EU).

## 3. Block JSON Configuration

All fields are optional; an unknown field is a block configuration error
(a clear error is better than a silently ignored parameter).

```json
{
  "strategy": "adrc",
  "enabled": true,
  "tick_period_ms": 100,
  "adrc": {
    "mode": "bandwidth",
    "r0": 100.0, "h0": 0.01, "b0": 1.0, "delta": 0.01,
    "wo": 20.0, "wc": 5.0,
    "alpha1": 0.75, "alpha2": 1.5
  },
  "pid": { "kp": 1.0, "ki": 0.0, "kd": 0.0, "td": 0.0,
           "integral_min": -1.0, "integral_max": 1.0 },
  "fsm": { "coarse_threshold": 5.0, "fine_threshold": 1.0,
           "stagnation_window_ticks": 5, "stagnation_delta_threshold": 0.1,
           "boost_step": 0.02, "boost_max": 0.3 },
  "pwm": { "period_ms": 1000, "min_on_ms": 50, "min_off_ms": 50 },
  "safety": { "watchdog_timeout_ms": 5000, "safe_output": 0.0,
              "output_limit_low": 0.0, "output_limit_high": 1.0 },
  "scaling": { "eu_min": 0.0, "eu_max": 100.0 },
  "channels": {
    "selector_mode": "max",
    "selector_deadband": 0.0,
    "feedforward": [ { "gain": 0.2, "bias": 0.0, "invert": false, "action": "additive" } ],
    "overrides": [ { "engage_above": 1150.0, "limit_high": 0.2 } ]
  },
  "inputs": { "pv": 0, "sp": 1, "enable": 2, "manual": 3,
              "selector": [4, 5], "feedforward": [6], "overrides": [7] },
  "outputs": ["output_value", "u_raw", "z1", "z2", "z3", "mode", "fault"]
}
```

### 3.1 `adrc`

| Field | Meaning |
|---|---|
| `mode` | `bandwidth` — `wo`/`wc` are expanded into beta (`beta01=3·wo`, `beta02=3·wo²`, `beta03=wo³`, `beta1=wc²`, `beta2=2·wc`); `explicit` — beta are set explicitly (by default: a ready-to-use working set) |
| `r0`, `h0` | TD: setpoint profiling rate and filtering period (> 0) |
| `b0`, `delta` | ESO input gain and width of the `fal()` linear zone; `b0 ≠ 0` |
| `beta01..beta03`, `beta1`, `beta2` | ESO and NLSEF coefficients (`explicit` mode) |
| `alpha1`, `alpha2` | orders of the `fal()` nonlinearity (default 0.75 / 1.5) |

Module defaults: `r0=100`, `h0=0.01`, `b0=1`, `delta=0.01`,
`beta01/02/03 = 100/300/1000`, `beta1/beta2 = 0.75/0.25`.

### 3.2 Other Sections

* `strategy`: `adrc` (default) or `pid` (in which case the `pid` section is required).
* `fsm`: Coarse/Fine thresholds and the stagnation detector (+`boost` forcing).
* `pwm`: no section — direct analog output (`scaling`
  to EU); section present — software PWM (0/1 at the output).
* `safety.output_limit_*` — limits of the internal `u ∈ [0,1]` (and the ceiling
  of override channels); `watchdog_timeout_ms` — how long to tolerate no fresh PV
  before a fault; `safe_output` — reserved for emergency reset.
* `scaling`: `u ∈ [0,1] → [eu_min, eu_max]` for `output_value`.

## 4. Inputs

The indices in `inputs` address the `tick` frame (the order of `[[block.input]]`):

| Field | Purpose |
|---|---|
| `pv`, `sp` | required PV/SP indices (default 0 and 1) |
| `enable` | a number or an array of indices: the loop is enabled when **all** values are `≠ 0` and finite; absent — always enabled |
| `manual` | manual output index: a finite value puts the loop into Manual and sets `u ∈ [0,1]` (the operator "drives" the loop). Return to auto — with the `set_auto` command |
| `selector` | indices of additional PV sensors; mode/hysteresis — in `channels` |
| `feedforward` | indices of feedforward channels (in the order of `channels.feedforward`) |
| `overrides` | indices of limiter channels (in the order of `channels.overrides`) |

Quality and timestamps are taken from the tags; the host converts the pollers'
Unix timestamps into monotonic time, so the PV watchdog runs in the background and does not
depend on the block period. A missing/unknown tag arrives as `NaN`/`Bad` —
the loop goes into hold and does not write its output.

## 5. Outputs

The `outputs` list defines the names **and the order** of values in the result frame;
`[[block.output]]` binds them to tags in the same order. For the control
output, specify a `scale` equal to the `scale` of the output tag in the devices config
(`value / scale` is written to the register; the driver encodes the type/byte order).

| Name | Meaning |
|---|---|
| `output_value` (or `u`) | control in EU (after `scaling`) |
| `u_raw` | effective control before scaling |
| `v1`, `v2` | TD setpoint profile and its derivative |
| `z1`, `z2`, `z3` | ESO estimates: output, velocity, disturbance |
| `boost` | forcing from the stagnation detector |
| `mode` | 0 Coarse, 1 Fine, 2 StagnationBoost, 3 Manual, 4 Fault |
| `saturation` | 255 — no saturation, 0 — low, 100 — high |
| `fault` | 0 none, 1 `sensor_fault`, 2 `nan_guard` |
| `pv`, `sp`, `error` | effective PV (after the selector), setpoint, error |
| `ff_total`, `ff_hold` | feedforward contribution and whether the output is frozen by a hold channel |
| `direct`, `transition` | EU-output flag and mode change on this tick |

It is convenient to write telemetry (`z1..z3`, `mode`, …) to **virtual tags**: this
does not create bus traffic.

## 6. Events and Alarms

The module sends a level event `fault` (while it is active, the host keeps
an alarm raised; when it clears, it clears one): `value` = the cause code (1 `sensor_fault`,
2 `nan_guard`). The binding is to the alarm section of any tag:

```toml
[[block.event]]
code = "fault"
tag = "plc.pump_speed"
priority = "critical"          # info | warning | critical | emergency
message = "{block}: fault (code {value})"
```

The alarm lives in the module's service slot (it does not overwrite the tag's
fail/script alarms), and the events are visible in MQTT diagnostic (`category = "wasm_compute"`).

> **NaN setpoint.** `nan_guard` does not reset the TD/ESO state automatically:
> the proper way out of the fault is the `emergency_stop` → `recover` commands (or
> restarting the block). This way the loop does not "come back to life" on its own after garbage in SP.

## 7. Commands and Runtime Parameters

The module accepts commands in two ways (both are part of the common ABI):

```toml
[[block.command_tag]]          # any source that writes tags: SCADA/MQTT/OPC UA/Rhai
name = "set_manual"            # - the tag's value is passed as value
tag = "hmi.flow_manual"
[[block.command_tag]]
name = "enable"
tag = "hmi.flow_enable"
```

Programmatically — via `ComputeCommandHandle` (MPC/supervisor).

| Command | Value | Action |
|---|---|---|
| `enable` / `disable` | — | operator enable/disable of the loop |
| `set_manual` | `u ∈ [0,1]` | Manual mode with the specified output |
| `set_auto` | — | return from Manual |
| `recover` | — | exit from Fault |
| `emergency_stop` | — | emergency stop: Fault, output 0, control law reset |
| `set_b0`, `set_wo`, `set_wc` | number | update the base parameters (beta are recalculated) |

Runtime parameters from tags (`[[block.param_tag]]`) are applied on every tick:
`b0`, `wo`, `wc` and the direct `r0`, `h0`, `delta`, `beta01..beta03`, `beta1`,
`beta2`, `alpha1`, `alpha2`. Invalid values are ignored — the loop
keeps running on the previous ones.

## 8. State, Hot-Reload, Rollback

`snapshot`/`restore` delegate to the core: on a confirmed hot-reload, the new
instance receives the full loop state (TD/ESO/PID, FSM, stagnation window,
PWM phase, counters) and continues without interruption. An incompatible snapshot (a different
format version, a foreign block, a change of law type) rejects the version application.

The rules are common to all compute modules:

* a new version is **not applied** without `y`/`n` (console) or MQTT
  `plugin_confirm` within `confirm_timeout_secs`;
* `auto_rollback` restores the previous working version after a series of host errors
  (`auto_rollback_after`); the `compute_staged/applied/rejected/rollback` events
  go to MQTT diagnostic;
* one unconfirmed stage per system.

## 9. Tests and Validation

```sh
# build the artifact (see §1)
cargo build --manifest-path crates/compute-plugin-adrc/Cargo.toml \
    --target wasm32-wasip2 --release --target-dir target

# core: deterministic TD/ESO/NLSEF scenarios, FSM, stagnation, PWM, protections
cargo test --manifest-path crates/adrc-core/Cargo.toml --target-dir target

# compute runtime and hot-reload from the platform side
cargo test --test compute_runner --test compute_hot_reload
```

## 10. What's Next

* signing of compute module manifests and downgrade protection;
* a telemetry bridge into the SHM slot `AdrcSlot` for external MPCs reading shared
  memory (by design, tags are the single source of truth; the bridge is an option);
* the `prism plugin` CLI for installing/signing/verifying modules;
* module templates in Python/C.
