# Core Configuration (`config/00_core/00_app.toml`)

## Purpose
`config/00_core/00_app.toml` defines the host environment, logging policies, licensing file references, tag inventory accounting, alarm logging, and engineering debug facilities.

For the filtration stand project this file identifies the instance as `stand-01`:

```toml
schema_version = 2

[system]
instance_name        = "stand-01"
hide_console         = false

[logging]
level                = "info"
format               = "text"
stdout               = true
file_enabled         = true
file_path            = "logs/prism.log"
rotation             = "daily"
max_files            = 14
max_size_mb          = 64

[license]
key_path             = "../licensing/license.key"
state_path           = "../licensing/license_state.json"

[inventory]
emit_report_path     = "../data/tag_inventory.json"

[alarms]
history_path         = "../data/alarms.csv"
max_size_mb          = 4
max_files            = 4

[debug]
# Enabled for the bench (../03_tooling/03_DEBUGGER.md): prism-dbg discovers
# the endpoint and connects without flags. Keep false in production.
enabled              = true
listen               = "127.0.0.1:7200" # loopback is served without a token
token                = ""               # required for non-loopback addresses (PRISM_DEBUG_TOKEN wins)
override_ttl_ms      = 60000
override_quality     = "uncertain"
stub_mode            = true
audit_path           = "logs/override_audit.log"
audit_max_size_mb    = 4     # rotate the journal at 4 MiB (0 = never)
audit_max_files      = 4     # rotated copies kept (override_audit.log.1 …)
```

---

## Section Reference

### `[system]`
- `instance_name`: String identifier of the gateway instance reported in telemetry and logs.
- `hide_console`: When `true`, hides the Windows console window in production background mode. Overridden automatically by the License FSM during demo countdown or when awaiting license activation.

### `[logging]`
- `level`: Default log filter level (`trace`, `debug`, `info`, `warn`, `error`) — the single filter for the whole process.
- `format`: `text` (human-readable) or `json`. With `json` the file log becomes one JSON object per line (`ts` in UTC RFC 3339, `level`, `target`, `message`; message escaping is handled by the serializer) — the format centralized log collectors expect (Elasticsearch, Graylog, `journald`), so shipping logs off the stand needs no custom parser. The console output stays human-readable either way.
- `stdout`: Enable terminal stdout logging.
- `file_enabled`: Enable persistent rotating file logging. The core always keeps a bounded in-memory ring of recent records (2 000 entries / 1 MiB) served by the debug API `logs` op, so a flash-based industrial PC (eMMC/CF wear) can set this to `false` and `prism-dbg` still shows the live LOG screen. `true` is kept for stands that archive logs.
- `file_path`: Relative or absolute path to the log file.
- `rotation`: `daily`, `hourly`, `size`, or `never`. Rotated files are kept as numbered copies next to the live one (`prism.log.1`, `prism.log.2`, …).
- `max_files`: How many rotated copies are kept; `0` drops the old file on every rotation. Total disk usage is bounded by this and `max_size_mb`.
- `max_size_mb`: Hard cap per file in every mode (`0` disables the cap): even `rotation = "never"` cannot grow without bound.

The filter never hides license-blocking states from the operator: they are
also printed as a console banner (stderr), which is independent of `level`.

### `[license]`
- `key_path`: Path to the signed Ed25519 `license.key`. Lookup order: (1) `license.key` next to the executable (the delivery layout used by the customer), (2) this configured path resolved from `config/`, (3) `./license.key` in the working directory. The chosen source is logged; a second copy found elsewhere produces a warning. The standard instance layout points it to `../licensing/license.key`.
- `state_path`: Location of the tamper-resistant persistent countdown record, resolved from the `config/` directory (`../licensing/license_state.json` in the standard instance layout).

The **one-time grace** for a hardware change is not a configuration knob; two
internal journals next to `state_path` drive it:

- `.license_uptime.bin` — a ledger of the runtime accumulated **under a valid
  license** (only while the key is accepted; it is never credited for free-tier
  or demo operation).
- `.license_grace.bin` — the grace window itself, bound to the machine and
  usable once.

When the license is rejected because the machine changed (PC HWID mismatch),
the runtime looks at the ledger: after **100 licensed hours** the full **7-day
grace** starts automatically; below the threshold only a **60-minute transfer
window** opens (a key copied onto a stand that never did the work is a
migration, not a transfer). Both keep the process polling while an updated
`license.key` is issued — no activation step on site is needed. A burned,
corrupted or foreign grace state blocks instead of extending, and a shorter
licence term is never invented: an **expired key grants no grace** — licenses
are perpetual, so an expired key is a broken delivery and only a replacement
key restores operation.

### `[inventory]`
- `emit_report_path`: Destination file for the JSON tag inventory report, resolved from the `config/` directory (the standard instance layout uses `../data/tag_inventory.json`); the report lists every point with its category.

Every kind of point counts toward the licensed tag quota: field I/O tags,
virtual (computed and scratch-pad) tags, WASM module tags, alarm signalling
tags (`alarm.<id>`, one per declarative rule) and script binding tags. The tag
quota is the only licensed limit — protocols, alarms and WASM modules are not
separately gated (see `06_operations/01_LICENSING.md`).

### `[alarms]`
- `history_path`: CSV log of alarm transitions (timestamp, device, tag, active, value, priority, message), resolved from the `config/` directory (the standard instance layout uses `../data/alarms.csv`). An empty value keeps the history in memory only.
- `max_size_mb`: Rotate the journal when it reaches this size (`0` disables rotation). Rotated copies are kept as `alarms.csv.1`, `alarms.csv.2`, … next to the live file, so the journal can never fill the disk of a small industrial PC.
- `max_files`: How many rotated copies are kept (`0` drops the old file on rotation).

The in-memory history served to clients (alarms API, MQTT state sync) keeps the last 200 transitions; the CSV is the durable journal read by the `prism-dbg` HISTORY screen.

### `[debug]`
- `enabled`: Global switch for the engineering debug channel. Must be `false` in production.
- `listen`: Listen address of the native debug API (JSON Lines,
  protocol-compatible with the simulator Control API, so `prism-dbg control ...`
  and the interactive panel work against a running Prism unchanged), default
  `127.0.0.1:7200`. Served without authentication only on loopback; a
  non-loopback address requires `token` and otherwise refuses to start.
- `token`: Shared secret checked in every request (`"auth": "..."`). The
  `PRISM_DEBUG_TOKEN` environment variable wins over the file; an empty value
  means "no token" (loopback only).
- Operations: `list` (every registered tag with value and register metadata),
  `get`, `set`, `stats` and the override group `force`/`freeze`/`release`/
  `release_all`. `pause`/`resume`/`shutdown` return `unsupported`: they have
  no defined meaning in the core yet (the simulator serves them).
- `force`/`freeze` replace the value every reader sees (compute, virtual tags,
  alarms, OPC UA, MQTT telemetry) until `release` or the TTL deadline; the real
  samples keep flowing underneath and are visible again immediately after the
  release. `list`/`get` report the effective value and add the `forced` field.
  String tags cannot be forced; bool accepts `0/1`.
- `set` validates strictly and answers with an explicit `wrong_type` error
  instead of coercing: bool accepts only `0/1` (or `true`/`false`), numeric
  values must be whole in the raw range of the declared type (`word`,
  `int`, `dword`, `dint`) and inside the tag `min`/`max`, and string tags
  (`data_type = "string"`) take text (echoed as `text` in the response); the
  write confirmation arrives after the actual device write, as for MQTT
  commands and OPC UA writes.
- `override_ttl_ms`: Default time-to-live for force overrides before automatic
  release (`0` = keep until explicitly released).
- `override_quality`: Quality flag assigned to forced tags (`uncertain`, `bad`, or `good`).
- `stub_mode`: When `true`, a command to an overridden tag is acknowledged back
  to SCADA without a physical write — the stand is not actuated.
- `audit_path`: Append-only JSON Lines journal (relative paths resolve from the
  instance directory, like the log file) recording every override action, tag,
  value, author and timestamp.
- `audit_max_size_mb`: Rotate the audit journal when it reaches this size
  (`0` disables rotation). Rotated copies are kept as `override_audit.log.1`,
  `.2`, … next to the live file.
- `audit_max_files`: How many rotated audit copies are kept (`0` drops the old
  file on rotation).

### `[service_tags]`
The reserved `system.*` namespace (full reference: `../04_logic/03_SERVICE_TAGS.md`).
- `enabled` (default `true`): register the service tags. They are virtual,
  hardware-free, **not counted by the license** (neither in a commercial tier
  nor in the 128-tag Community edition) and can be exposed like any other tag
  (MQTT channel, OPC UA node, Rhai).
- `update_ms` (default `1000`): status refresh period. Commands are executed
  immediately.
- `allow` (default empty): extra commands made writable on top of the safe set.
  `"shutdown"`, `"device_pause"`, `"alarm_rule_disable"`, `"force"`,
  `"release"`, `"stub_mode"` are dangerous and stay `ro` until listed here;
  `allow = ["*"]` opens everything.

Applied at startup: the section belongs to the application config, not to the
reloaded device tree.

#### Remote debugging (token on a non-loopback address)

The debug API is served without authentication only on loopback. To debug a
stand from an engineer's laptop over the plant network, both sides share one
secret:

1. Bind the API to a reachable interface and set a token in `app.toml` — any
   long random string, it is a password, not a certificate:
   ```toml
   [debug]
   enabled = true
   listen  = "0.0.0.0:7200"                          # or one interface, e.g. "10.0.0.5:7200"
   token   = "8f2c9d41b7a0e5f3c6d8a1b4e7f0c3d6"     # example: 32 hex characters
   ```
   A non-loopback `listen` with an empty token makes the debug API refuse to
   start — the gateway itself keeps running, only the debug channel stays
   unavailable. The service environment can override the token with
   `PRISM_DEBUG_TOKEN` (it wins over the file; keep secrets out of committed
   configs).
2. Open the port only for the engineering subnet on the stand:
   `netsh advfirewall firewall add rule name="prism-debug" dir=in action=allow
   protocol=TCP localport=7200 remoteip=10.0.0.0/24` (Linux: the analogous
   `ufw`/`nftables` rule).
3. From the laptop, pass the endpoint and the same token to `prism-dbg`:
   ```bash
   devtools/debugger/prism-dbg --control 10.0.0.5:7200 --token 8f2c9d41b7a0e5f3c6d8a1b4e7f0c3d6 control list
   devtools/debugger/prism-dbg --control 10.0.0.5:7200 --token 8f2c9d41b7a0e5f3c6d8a1b4e7f0c3d6 control force io_controller.tank_level 1.2
   devtools/debugger/prism-dbg --control 10.0.0.5:7200 --token 8f2c9d41b7a0e5f3c6d8a1b4e7f0c3d6   # interactive panel
   ```
   The token travels in every request (`"auth": "..."`); a wrong or missing
   token answers `{"ok":false,"error":{"code":"unauthorized"}}`. Running the
   debugger on the stand itself needs no flags: `prism-dbg` discovers the
   endpoint and the token from the instance's `config/00_core/00_app.toml`, and
   `--token` is only needed to override them.

The debug API can write tags and force values — never expose it to the
internet. The least-privilege alternative is an SSH tunnel: keep `listen` on
loopback and forward the port (`ssh -L 7200:127.0.0.1:7200 user@stand`), then
connect to `127.0.0.1:7200`; with the tunnel the loopback rule applies and a
token is optional.
