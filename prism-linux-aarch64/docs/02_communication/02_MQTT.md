# MQTT Broker & SCADA Client Integration

## Overview

The gateway uses MQTT (v5/v3.1.1) as its primary integration bus for operator
HMIs, historical archiving, and external supervisory systems.

Configuration lives in `config/02_northbound/01_mqtt/` and is split into files with clearly
separated responsibilities:

| File | Managed by | Contents |
|---|---|---|
| `config/02_northbound/01_mqtt/broker.toml` | hand | Broker connection and defaults |
| `config/02_northbound/01_mqtt/channels.toml` (or `channels.d/<contract>/<id>.toml`) | hand | Channels: contracts, arbitrary topic paths, payload template refs, per-channel fields |
| `config/02_northbound/01_mqtt/payloads/*.json` | hand | JSON payload templates: plain JSON with `{{marker}}` slots |
| `config/02_northbound/01_mqtt/tags.toml` | generator | Tag rules: `[[telemetry_group]]`, `[[telemetry_tag]]`, `[[command]]` |

The model is split in two:

- **A contract** is a fixed internal vocabulary item: it defines *what* the
  data is and *when* it flows (direction, trigger, marker vocabulary, code
  path). The contract set is closed — you bind to contracts, you do not invent
  them.
- **A channel** is an external binding: an arbitrary topic plus an arbitrary
  JSON payload template (`payloads/*.json`). There can be any number of
  channels per contract: a second telemetry channel feeds an MES over its own
  topic with its own payload — the shipped channel set is just the default
  materialization. An absent channel is a disabled channel (no silent
  fallback to a built-in topic).

| Contract | Direction | Trigger |
|---|---|---|
| `telemetry` | out | `batch` / `on_change` / `periodic` / `hybrid` |
| `command` | in | incoming message (operator writes, the usual write-path) |
| `ack` | out | write result (command confirmations) |
| `alarm` | out | alarm transition (+ `alarm_heartbeat_ms` while active) |
| `fail` | out | bad sample (+ `fail_heartbeat_ms` while active) |
| `status` | out | device availability transition (retained) |
| `tag_status` | out | every Good sample of a discrete (bool) tag |
| `diagnostic` | out | core service events |
| `control.alarm_ack` | in | operator alarm acknowledgement |
| `control.clear_alarms` | in | clear all alarms |
| `control.reload` | in | config reload |
| `control.plugin_confirm` | in | WASM plugin hot-reload confirmation |
| `sql.get` | in | SCADA state request (state bridge, doc `07` §8) |
| `sql.read` | out | state DB read request (forwarded from `sql.get`) |
| `sql.write` | out | state capture: every applied command, plus mirrored telemetry |
| `sql.data` | in | rows answered by the state DB (forwarded to `ack`) |

The generator (`prism-devtools generate mqtt`) creates
`tags.toml` from your device configuration and emits the described channels
and seeds missing `payloads/*.json`; hand-managed files
(`broker.toml`, the channel files, payloads) are synchronized with
`generate mqtt --apply-hand` and drift-guarded like every generated file.
Two layouts are supported (`layout` in `generators/mqtt.toml`):
`single` — one `channels.toml`; `split` — one file per channel in
`channels.d/<contract>/<id>.toml` plus `channels.d/_meta.toml` (the schema
header); a dotted contract nests (`channels.d/control/alarm_ack/<id>.toml`).
The loader merges every `*.toml` under `config/02_northbound/01_mqtt/`, so both
layouts are equivalent at runtime; on a layout switch the files of the old
layout are retired to `<name>.bak` by `--apply-hand`.

Two concepts are configured separately:

- **Telemetry (ro, gateway → client):** publishing rules for read-only data.
- **Commands (rw, client → gateway):** which tags accept operator writes.

A tag can appear in both sections — then it is published *and* writable.

---

## 1. Broker Configuration (`config/02_northbound/01_mqtt/broker.toml`)

```toml
[broker]
host              = "localhost"
port              = 1883
client_id         = "stand-01"   # optional; auto-generated when absent
# username        = "prism"      # optional credentials
# password        = "secret"     # inline secret (prefer password_env)
# password_env    = "PRISM_MQTT_PASSWORD"   # password from the environment
keep_alive_sec    = 60
clean_session     = true
inflight          = 100
# tls             = false
# tls_ca_file            = "data/pki/ca.pem"          # custom CA (self-signed brokers)
# tls_client_cert_file   = "data/pki/client.pem"      # mTLS
# tls_client_key_file    = "data/pki/client.key"      # mTLS
```

| Key | Default | Meaning |
|---|---|---|
| `host` | `""` | Broker host (IP or DNS) |
| `port` | 1883 | TCP port (`8883` for MQTTS) |
| `client_id` | auto | MQTT Client ID |
| `username` | – | Broker user name (optional) |
| `password` / `password_env` | – | Password: inline value or the name of an environment variable; set exactly one, and only together with `username` |
| `keep_alive_sec` | 60 | Keep-alive interval |
| `clean_session` | true | Clean session (MQTT 3.1.1) / Clean Start (MQTT 5) |
| `inflight` | 100 | Maximum in-flight messages |
| `tls` | false | Enable MQTTS (system CA store by default) |
| `tls_ca_file` | – | PEM CA file for private/self-signed brokers |
| `tls_client_cert_file` / `tls_client_key_file` | – | mTLS client certificate pair (set both; requires `tls_ca_file`) |

### Securing the broker link

Plain TCP is acceptable only for a local broker on a trusted network. For a
broker reachable over the wire:

- **TLS (MQTTS).** `tls = true` switches the same `host`/`port` to TLS (use
  8883). The system CA store is trusted by default; for a private CA set
  `tls_ca_file` (PEM). If a TLS file cannot be read, the MQTT transport fails
  to start — there is no silent fallback to plain TCP.
- **Client certificates (mTLS).** `tls_client_cert_file` +
  `tls_client_key_file` (PEM, both or none); client auth requires a CA file.
  This is the strongest option: the broker authenticates the gateway itself
  and not just the password.
- **Credentials.** `username` requires exactly one password source:
  `password_env` (recommended — the secret stays out of TOML) or the inline
  `password`. The pairing is validated at load: `--check-config` fails on a
  missing or empty environment variable, and credentials without TLS raise a
  startup warning. At runtime a broker misconfiguration never crashes the
  core: the MQTT transport stays disabled and the reason is logged explicitly
  (`[Main] Cannot load MQTT config, using defaults: …`).
- Relative TLS paths are used as given, i.e. relative to the working
  directory of `prism.exe` (the instance root in the standard layout).

```toml
[broker]
host            = "mqtts.plant.example"
port            = 8883
tls             = true
tls_ca_file     = "data/pki/ca.pem"           # private CA
username        = "prism-stand-01"
password_env    = "PRISM_MQTT_PASSWORD"
# optional mTLS:
# tls_client_cert_file = "data/pki/client.pem"
# tls_client_key_file  = "data/pki/client.key"
```

Broker-side measures (per-client ACLs, `require_certificate`, TLS version
floors, password files) remain the broker's responsibility — the gateway
settings above only control how *it* connects.

`[defaults]` carries the floors for both flows — `[defaults.telemetry]` and
`[defaults.commands]` (section 3), the event heartbeats, and the transport QoS
knobs:

```toml
[defaults]
qos_subscribe         = 1     # inbound subscriptions (command/control channels)
qos_publish           = 1     # fallback publish QoS for outbound channels
alarm_heartbeat_ms    = 0     # republish active alarms every N ms (0 = transitions only)
critical_heartbeat_ms = 0     # optional dedicated cadence for critical/emergency (0 = off)
fail_heartbeat_ms     = 0     # republish active fails every N ms (0 = transitions only)
```

To disable the MQTT transport entirely, put `enabled = false` at the root of
any file in the MQTT config directory.

---

## 2. Channels & Topic Schema (`channels.toml` / `channels.d/`)

Every topic belongs to a channel: a contract, a topic template and a payload
template. Channels are listed in `channels.toml` — or, with the split layout
(`layout = "split"` in the generator config), one channel per file in
`channels.d/<contract>/<id>.toml` next to `channels.d/_meta.toml`
(`schema_version`/`contract_id`); a dotted contract nests
(`channels.d/control/alarm_ack/<id>.toml`). The loader merges both layouts:

```toml
schema_version = 4

[[channel]]
id       = "telemetry"            # optional label; empty -> "<contract>-<index>"
contract = "telemetry"
topic    = "prism/telemetry"      # placeholders as below
envelope = "payloads/telemetry.envelope.json"
item     = "payloads/telemetry.item.json"

# Second consumer: own topic, own payload, own tag selection.
[[channel]]
id       = "report.mes"           # a set id must be unique
contract = "telemetry"
topic    = "myplant/report/{name}"
item     = "payloads/mes.item.json"

# Custom field: the {{disabled}} marker in the item template.
[[channel.field]]
name     = "disabled"
for      = "plc1.oil_probe_*"
from_tag = "particle_select.oil_probe_disabled"

[[channel]]
id       = "command"
contract = "command"
topic    = "prism/command/set"
```

The shipped default channel set:

| id | Contract | Topic | Payload |
|---|---|---|---|
| `telemetry` | `telemetry` | `prism/telemetry` | envelope + item |
| `command` | `command` | `prism/command/set` | implicit mapping (below) |
| `command_ack` | `ack` | `prism/command/ack` | item |
| `alarm` | `alarm` | `prism/event/alarm/{severity}` | item |
| `fail` | `fail` | `prism/event/fail/{device}` | item |
| `status` | `status` | `prism/status` | item |
| `tag_status` | `tag_status` | `prism/status` | item |
| `diagnostic` | `diagnostic` | `prism/event/diag/{severity}` | item |
| `alarm_ack` | `control.alarm_ack` | `prism/event/alarm/ack/{namespace}/{name}` | — (fixed `{"ack": true}`) |
| `clear_alarms` | `control.clear_alarms` | `prism/command/clear_alarms` | — |
| `reload` | `control.reload` | `prism/command/reload` | — |
| `plugin_confirm` | `control.plugin_confirm` | `prism/control/plugin/confirm` | — |

Rules that apply to every channel:

- **Contracts are a closed vocabulary** (the 16 listed in the Overview): they
  define the direction, the trigger, the marker vocabulary and the code path.
  The number of channels per contract is not limited.
- **`id` is an optional label.** An empty id derives `<contract>-<index>`
  (declaration order); a set id must be unique.
- **An absent channel is disabled.** There is no silent fallback to a built-in
  topic: delete a channel — its topic is gone.
- **Form follows the config:** with `envelope` + `item` the channel is flat
  (one topic, `{{items}}` carries the item array; `mode = "batch"` accumulates
  a full state snapshot and flushes it every 500 ms);
  with `item` only the message body is the rendered item and the topic must
  contain `{namespace}`/`{name}` (per-tag) — request-style bodies like
  `sql.read` are the exception; a topic-only channel (no payload) is allowed
  for inbound contracts (`sql.get`, `sql.data`).
- **Identity is mandatory** in flat forms: `namespace`/`name`/`value` markers
  must exist in the item template (a message stays self-describing); per-tag
  forms take the identity from the topic placeholders.
- **Command payload mapping is implicit** when no `item` is given: a flat topic
  reads `{"ns_name", "name", "value"}`, a topic with `{namespace}/{name}` reads
  `{"v", "req_id"}`. Acks mirror the shape: a per-tag topic gets
  `{"req_id", "ok", "v", "error"}`, a flat topic the `ns_name/name/value/disabled`
  list item.
- **Command channels** (and only they) accept writes; they share the single
  write-path: tag exists, `access != ro`, `[[command]]` rule enabled, value
  scale/min-max validation, ack after the actual device write.
- **Telemetry modes:** `batch` | `on_change` | `periodic` | `hybrid` (per
  channel, overridden by `[[telemetry_group]]`/`[[telemetry_tag]]` rules;
  a rule without `channel = "..."` belongs to the default `telemetry`
  channel). `command`/`ack` and the event contracts have no modes: they are
  event-driven.

Placeholders: `{namespace}` (device), `{name}` (tag), `{device}`, `{priority}`,
`{severity}`. Short aliases `{ns}`, `{dev}`, `{prio}`, `{sev}` are accepted and
normalized automatically. The shipped standard keeps the *identity*
(`namespace`/`name`) in the JSON payload and only puts `{severity}`/`{device}`
into the default event topics; placeholders are an optional customization —
use the ones your topic needs.

Only the placeholders listed for a contract are meaningful; any other renders
as an empty segment (a load-time warning), so use this map:

| Contract | Direction | Filled placeholders |
|---|---|---|
| `telemetry` (batch) | out | `{namespace}` |
| telemetry (`on_change`/`periodic`/`hybrid`) | out | `{namespace}`, `{name}` |
| `command` | in | `{namespace}`, `{name}` |
| `ack` | out | `{namespace}`, `{name}`, `{device}` |
| `alarm` | out | `{device}`, and `{priority}` = `{severity}` (the alarm priority) |
| `fail` / `status` | out | `{device}` |
| `tag_status` | out | — (flat; the tag name is in the payload) |
| `diagnostic` | out | `{device}` (= target), `{severity}` |
| `control.alarm_ack` | in | `{namespace}`, `{name}` (matched from the incoming topic) |
| `control.clear_alarms` / `control.reload` / `control.plugin_confirm` | in | none — exact match |
| `sql.get` / `sql.data` | in | none — exact match (topic-only channels) |
| `sql.read` / `sql.write` | out | none (flat topics) |

Incoming subscriptions are derived from the channel topics (every `{...}`
becomes a `+` wildcard), so an edited channel file re-subscribes on hot
reload (`r` in the console, `prism/command/reload`) or on restart.

**The shape of a topic selects its payload envelope:**

| Topic style | Telemetry | Command | Ack |
|---|---|---|---|
| Flat (no placeholders) | `{timestamp, data: [{ns_name, name, value, ...}]}` on one shared topic | `{ns_name, name, value}` | list `[{ns_name, name, value, disabled?}]` |
| Per-tag (with `{namespace}/{name}`) | `{v, q, ts, u}` per tag | `{v, req_id}` | `{req_id, ok, v, error}` |

Every flat telemetry item, command and ack carries the namespace (device) and
the tag name — a message is always self-describing.

> The examples above show the **default** payload names (`ns_name`, `value`,
> `v/q/ts/u`, ...) coming from the shipped `payloads/*.json`: the wire contract
> is the template, edit the files to rename or restructure anything.

### Namespace model: device identity vs SCADA contract

A namespace is the **device** name: it identifies where a tag comes from
(field protocol, plugin, or virtual group). It is not necessarily the name
the SCADA should see.

The recommended model keeps these concerns separate:

- raw field tags stay in their device namespace and are not published to the
  SCADA unless a consumer really needs them;
- operator-facing and computed tags live under one logical namespace (an
  asset name), typically a virtual device;
- table-like high-volume data may stay in its own external namespace so
  consumers can subscribe to it separately.

The current configuration supports this by consolidating the SCADA-facing
model in a virtual device and disabling telemetry for the raw namespaces:

```toml
[[device]]
name = "stand"
protocol = "virtual"

[[telemetry_group]]
pattern = "plc.*"
enabled = false
```

A virtual copy of every raw tag is **not** recommended: it doubles the tag
inventory (and the licensed tag count), and the copy does not automatically
carry quality, fail state, timestamps or `disabled` fields. Virtual tags are
for derived values (scaling, filtering, aggregation, computation), not for
renaming.

When raw tags must stay in their device namespaces, use the planned
namespace-projection extension: one registry tag is rendered under the
logical namespace in outbound payloads/topics, and inbound commands are
resolved back to the real device by tag name. Projection does not duplicate
tags and preserves quality/metadata. The configuration surface, validation
rules and migration steps will be documented with the extension.

Rules for any external model:

- bare tag names must be unique inside an external namespace;
- a projection/alias mapping must be validated at load time — an ambiguous
  name is a configuration error, not "first match wins";
- publish only the namespaces the consumer actually needs.

---

## 3. Telemetry & Command Rules (`config/02_northbound/01_mqtt/tags.toml`)

### Defaults (`broker.toml`)

```toml
[defaults.telemetry]          # ro: gateway → client
enabled         = true
mode            = "batch"     # "on_change" | "periodic" | "hybrid" | "batch"
qos             = 0
retain          = true
min_interval_ms = 50          # throttle: min time between publishes
min_delta       = 0.01        # min value change to publish in on_change mode

[defaults.commands]           # rw: client → gateway
enabled    = true             # accept incoming MQTT write commands
qos        = 1
timeout_ms = 5000             # timeout waiting for the device write
```

Publish modes:
- `on_change`: Publish when the value changes by at least `min_delta`.
- `periodic`: Publish on a fixed cadence, even when the value has not changed.
- `hybrid`: Periodic heartbeat plus immediate publish on significant changes.
- `batch`: Accumulate a full state snapshot — unchanged values are re-sent on
  purpose — and flush one JSON array on the shared topic every 500 ms;
  `min_delta` does not apply.

`min_interval_ms` throttles `periodic`/`hybrid`; `min_delta` is the threshold
for `on_change`/`hybrid`. `periodic`/`hybrid` have their own publisher timer:
no new sample is needed for a heartbeat, so a SCADA freshness/age indicator
does not turn an idle value red while the tag still holds a good sample.
`on_change` stays silent until the value actually changes. The heartbeat is
sent only on the channel that is due, so a `batch` channel of the same tag
does not accumulate duplicates.

### Group Rules (`[[telemetry_group]]`)

Glob patterns overriding telemetry defaults for whole groups of tags:

```toml
[[telemetry_group]]
pattern         = "io_controller.*"
mode            = "hybrid"
qos             = 0
retain          = true
min_interval_ms = 100
min_delta       = 1.0
enabled         = true
```

Resolution cascade: `[defaults.telemetry]` → first matching
`[[telemetry_group]]` → exact `[[telemetry_tag]]`; each later stage wins. A
writable setpoint tag (value editor in the SCADA) should get `mode =
"on_change"` as a per-tag override so it leaves the periodic snapshot — the
generator emits such an override for command tags by default.

### Per-Tag Telemetry Overrides (`[[telemetry_tag]]`)

```toml
[[telemetry_tag]]
tag             = "io_controller.flow_speed"
mode            = "on_change"
qos             = 1
min_interval_ms = 50
```

### Command Rules (`[[command]]`)

Which tags accept writes from the client — a separate, explicit section:

```toml
[[command]]
tag        = "io_controller.pump_run"
enabled    = true
qos        = 1
timeout_ms = 5000
```

Resolution cascade: `[defaults.commands]` → exact `[[command]]`. A writable
tag that has **no** `[[command]]` entry still accepts commands if
`[defaults.commands].enabled = true`; add `[[command]]` with `enabled = false`
to forbid a specific tag.

---

## 4. JSON Payloads (`config/02_northbound/01_mqtt/payloads/*.json`)

Payloads are plain JSON files with `{{marker}}` slots; a
string that consists of exactly one marker is substituted with a typed value
(number, bool, string, null), a missing value omits the object key (or the
array element) entirely.

```json
// payloads/telemetry.envelope.json (flat telemetry: one topic)
{ "timestamp": "{{timestamp}}", "data": "{{items}}" }

// payloads/telemetry.item.json (one item per tag)
{ "ns_name": "{{namespace}}", "name": "{{name}}", "value": "{{value}}" }

// payloads/alarm.json
{ "device": "{{namespace}}", "tag": "{{name}}", "ts": "{{timestamp}}",
  "alarm_type": "{{type}}", "active": "{{active}}", "value": "{{value}}",
  "limit": "{{limit}}", "message": "{{message}}", "priority": "{{priority}}",
  "acknowledged": "{{acknowledged}}" }
```

Marker vocabulary per contract (the loader rejects unknown markers):

| Role / form | Markers |
|---|---|
| telemetry envelope | `timestamp`, `items` (the item array, exactly once) |
| telemetry item | `namespace`, `name`, `value`, `timestamp`, `quality`, `unit`, `description`, `data_type` |
| command | `namespace`, `name`, `value`, `req_id`, `timestamp` |
| ack | `namespace`, `name`, `value`, `ok`, `error`, `req_id`, `disabled`, `timestamp` |
| alarm | `namespace`, `name`, `timestamp`, `type`, `active`, `value`, `limit`, `message`, `priority`, `acknowledged` |
| `fail` | `namespace`, `name`, `timestamp`, `strategy`, `message` |
| `status` | `namespace`, `timestamp`, `status` |
| `tag_status` | `namespace`, `name`, `timestamp`, `value` |
| `diagnostic` | `target`, `timestamp`, `event_id`, `category`, `code`, `severity`, `message`, `active`, `data` |

The templates are compiled once at config load: the load fails on an unknown
marker, a missing mandatory identity marker, a second `{{items}}`, or
`{{items}}` inside an item template. Declared `[[channel.field]]` names are
allowed in addition to the contract vocabulary; a declared field that is never
used in the template is reported as a warning.

User fields (`[[channel.field]]`) resolve at publish time — a constant
(`value`) or the current value of any tag (`from_tag`, typically a virtual/
compute tag). Exactly one source per field. A change in a field value is a
publication trigger of its own: an `on_change` channel re-sends the tag even
when its value is unchanged, so a `disabled` flag sourced from the PLC link
state does not stay stale after the link recovers.

Render order: `template → fields → publish`.

---

## 5. SCADA Client Contract (flat topics)

With the flat topics shipped in `channels.toml` (default payloads), the wire
contract is:

### Telemetry (`prism/telemetry`)

```json
{
  "timestamp": 1726000000000,
  "data": [
    {"ns_name": "io_controller", "name": "pressure_in", "value": 101325.0},
    {"ns_name": "io_controller", "name": "pump_run", "value": true},
    {"ns_name": "calc", "name": "batch_code", "value": "AB-42"}
  ]
}
```

`value` carries the text for `data_type = "string"` tags (JSON string). In
`mode = "on_change"` text tags are compared as strings, so a changed text is
republished even though the numeric projection never changes.

### Operator Commands (`prism/command/set`)

Published by the client with QoS 1 when the operator toggles controls or
enters setpoints. `ns_name` (**mandatory**) is the device (namespace):

```json
{"ns_name": "io_controller", "name": "pump_run", "value": true}
{"ns_name": "calc", "name": "batch_code", "value": "AB-42"}
```

`value` may be a boolean, number, or string. For numeric tags, numeric strings
are parsed to a number; for `data_type = "string"` tags the value is written as
text (numbers and booleans are rendered, no scale/limits are applied). A `null`
value is ignored: it is a client-side marker without a device write.

The desktop frontend reuses its telemetry envelope for outgoing commands, so
the same command may arrive wrapped — as a single object or a batch list:

```json
{"timestamp": null, "data": {"ns_name": "io_controller", "name": "pump_run", "value": true}}
{"timestamp": null, "data": [{"ns_name": "io_controller", "name": "pump_run", "value": true}]}
```

Both forms are accepted; the envelope item key is the one in the telemetry
channel's envelope template (`data` in the shipped
`payloads/telemetry.envelope.json`).
Every item — in the bare form and in the batch list — must carry `ns_name`:
commands without a namespace are rejected.

### Command Acknowledgement (`prism/command/ack`)

Published by the gateway after the device write completes. The response
mirrors the command as a list; `disabled: true` means this tag cannot be
written (its `[[command]]` rule is disabled) and the client should grey out
the control:

```json
[
  {"ns_name": "io_controller", "name": "pump_run", "value": true},
  {"ns_name": "io_controller", "name": "heater_pwm", "value": 0, "disabled": true},
  {"ns_name": "calc", "name": "batch_code", "value": "AB-42"}
]
```

The ack echoes the command value in its original type: bool stays `true/false`,
text commands echo the string, a failed write returns the *actual* tag value
(current text for string tags) rather than the requested one.

### Discrete Status (`prism/status`)

Emitted immediately when discrete hardware or virtual states transition:

```json
{"name": "pump_run", "value": true, "device": "io_controller"}
```

### Alarm Events (`prism/event/alarm/{severity}`)

Emitted on alarm transitions (and periodically while active when
`alarm_heartbeat_ms > 0`; heartbeats add `"heartbeat": true`):

```json
{
  "device": "plc1",
  "tag": "oil_temperature",
  "alarm_type": "high",
  "active": true,
  "value": 71.5,
  "limit": 70.0,
  "message": "Oil temperature high: 71.5 > 70",
  "priority": "critical",
  "acknowledged": false,
  "ts": 1726000000000
}
```

`{severity}` is the alarm priority (`warning`/`critical`/...); `{priority}` in
this topic is a synonym filled with the same value. Acknowledgements
are published by the client to `prism/event/alarm/ack/{namespace}/{name}` as
`{"ack": true}` (optionally `"alarm_type": "<rule id>"` to ack a single rule of
the tag); on every broker reconnect the gateway re-announces active alarms and
fails with `"resync": true` plus the clears missed since the previous sync.
Fail events (`prism/event/fail/{device}`) and diagnostics
(`prism/event/diag/{severity}`) follow the same template rules
(`payloads/fail.json`, `payloads/diagnostic.json`).

---

## 6. Custom Payload Fields (`[[channel.field]]`)

A field is declared where its template lives: `[[channel.field]]` in the
channel file. Entries are merged into the payload of the listed tags before
the payload is rendered. `for` is an exact id or a `*` glob pattern
(like `[[telemetry_tag]]`), so one entry can decorate a whole group. The marker
must be referenced by the channel's item template (`{{disabled}}`), and the
value is substituted at publish time:

```toml
# channels.toml: a constant field.
[[channel.field]]
name  = "src"
for   = "plc1.oil_probe_before_6ka3"
value = "prism"

# A field sourced from another tag (device + tag).
[[channel.field]]
name     = "disabled"
for      = "plc1.oil_probe_after_6ka4"
from_tag = "particle_select.oil_probe_disabled"

# A glob pattern: the same field on every matching tag.
[[channel.field]]
name  = "group"
for   = "plc1.oil_probe_*"
value = "probe"
```

Exactly one of `value` or `from_tag` is required per entry.

References are cross-validated by `--check-config` (and at start): a `for`
pattern must match at least one configured tag (an exact id must exist) and
`from_tag` must resolve — a dead field is an error (`[[channel.field]] …
refers to missing tag …`), since it would silently do nothing. The generator
additionally warns about dead references at generation time, and
`prism-devtools trim mqtt` removes the dead blocks.

`from_tag` reads the source tag at publish time: numbers and bools from the
registry, text from the store (`last_raw_value`) for `data_type = "string"`
sources. The recommended source of dynamic values is a virtual/compute tag (Rhai
`script_func` or a WASM module), so the value has quality/timestamp and is
visible to OPC UA, alarms and scripts — see `04_logic/01_RHAI.md`
§3.3. If the source tag is missing, `Bad`/`Uninitialized` or `NaN`, the field
is omitted (the payload is still published).

```rhai
// config/01_southbound/04_virtual_tags: a bool tag feeding the field above
fn probe_disabled() {
    if read("particle_select.stand_select") != 1.0 { 1.0 } else { 0.0 }
}
```

Anything more complex (bundle several fields, transform `value`, drop the
message) is also a virtual tag: compute it in Rhai or a WASM module and bind it
with `from_tag` — unlike ad-hoc per-field code, the value then has quality and
timestamp and is visible to OPC UA, alarms and scripts.

Fields run on every publish attempt, and an attempt happens only
when the tag is due: on its own change (`on_change`), on the channel timer
(`periodic`), or both (`hybrid`). The `periodic`/`hybrid` timer fires even
when the tag value is unchanged, so the fields are re-read on every heartbeat.
`mode = "batch"` re-sends the whole snapshot every 500 ms, so a field value is
re-read with every flush; a change of the *source* tag of a field alone does
not republish an `on_change` payload — use `periodic`/`hybrid` for state-like
fields that must refresh on their own timer.

---

## 7. Declarative Generator Tooling

The generator turns the description in `devtools/tooling/generators/mqtt.toml` into
instance config: tag rules (`tags.toml`), channels (`channels.toml`: contracts,
topics, fields) and payload templates (`payloads/*.json`); `broker.toml` keeps
the connection and defaults.

```bash
# Configuration generator (checks produce no writes):
prism-devtools generate mqtt --root .
prism-devtools generate mqtt --root . --dry-run           # preview
prism-devtools generate mqtt --root . --check             # report drift, exit 1
prism-devtools generate mqtt --root . --apply-hand        # apply channels/payloads/broker
prism-devtools generate mqtt --root . --apply-hand --check # gate for both
```

- Reads `devtools/tooling/generators/mqtt.toml` and scans the configured targets
  (`config/01_southbound/01_modbus/`, `config/01_southbound/02_s7comm/`, `config/01_southbound/04_virtual_tags/`).
- Pre-validates tag naming collisions, duplicate Modbus addresses, and access
  modes; aborts on errors. Declared fields (`[[channel.field]]`) are
  pre-validated too: exactly one of `value`/`from_tag`, non-empty names; dead
  references (`from_tag`, glob `for`) are warnings.
- Emits `config/02_northbound/01_mqtt/tags.toml` with `[[telemetry_group]]`,
  `[[telemetry_tag]]`, and `[[command]]` rules. Writable tags (`access =
  "rw"`/"wo") and scratch-pad virtual tags get `[[command]]` entries. A
  writable tag also gets a per-tag `[[telemetry_tag]]` override with `mode =
  "on_change"` unless the config explicitly sets another mode (an explicit
  non-`on_change` mode warns: the SCADA value editor is reset while typing);
  this keeps setpoints out of the periodic batch snapshot.
- **Creates the described channels**: the channel files are written from the
  `[[channel]]`/`[[channel.field]]` entries (contracts, topics, payload refs):
  one `channels.toml` with `layout = "single"` (default) or
  `channels.d/_meta.toml` + one file per channel
  (`channels.d/<contract>/<id>.toml`, dotted contracts nest) with
  `layout = "split"`; the loader merges
  every `*.toml` under `config/02_northbound/01_mqtt/`, so both are equivalent at runtime. The
  generator also **seeds missing payload templates** in `payloads/*.json`
  (plain JSON with `{{marker}}` slots, mandatory `namespace`/`name`/`value` in
  flat forms, optional built-ins filled by the program, user fields bound to
  any program tag — see section 6). An existing `topics.toml` is reported as
  unused.
- Default behaviour keeps hand files safe: `broker.toml` and the channel files
  (`channels.toml` or `channels.d/**`) are seeded only when missing and are
  never overwritten (a run reports when they differ from the described
  config); payload templates are seed-only (no drift guard — they are authored
  artefacts). `--apply-hand` applies the described channels/broker to the hand
  files: the first adoption keeps a `.bak` next to the file, and from then on
  they are regenerated under the same drift guard as `tags.toml` (manual edits
  stop generation until folded into the generator config or `--force`). On a
  `layout` switch the files of the old layout are retired to `<name>.bak`
  (`--check` reports them as drift until then).
- Writes a validation and inventory report to `data/mqtt_generator_report.json`;
  the manifest `data/.prism-devtools.manifest.json` tracks generated/adopted
  files (`tags.toml`, and `broker.toml`/`channels.toml` after adoption).

---

## 8. SCADA State Bridge (`sql/*` contract)

Some SCADA frontends keep their widget state (table cells, switch positions,
setpoints) in a database and restore it after a restart. Prism plays the server
half of that contract; the database itself is an external service that talks
MQTT (a reference pair for the oil-fuel stand lives in
`instances/oil-fuel-stand/user/frontend` and `.../user/db`, see the frontend
`readme.MD`).

The transport is described by four regular channels — declare them in
`devtools/tooling/generators/mqtt.toml` like any other binding:

| Contract | Direction | Default topic | Payload |
|---|---|---|---|
| `sql.get` | in (SCADA → Prism) | `sql/get` | `{"timestamp": null, "data": null \| [names]}`; topic-only channel |
| `sql.read` | out (Prism → DB) | `sql/read` | the request forwarded as is; the body template renders the startup request |
| `sql.write` | out (Prism → DB) | `sql/write` | `{"timestamp", "data": [{"ns_name", "name", "value"}]}` — flat, `envelope` + `item` |
| `sql.data` | in (DB → Prism) | `sql/data` | rows in ack shape; forwarded to the ack channel |

Behaviour is configured by the `[sql]` section of the MQTT config (a dedicated
`sql.toml` next to `broker.toml` keeps it tidy):

```toml
[sql]
enabled = true

# Command channels (by id) whose items are persisted to the DB — including
# `value = null`. Items without `ns_name` get the device resolved by the tag
# name; nulls and unknown tags are acknowledged by the bridge itself (the core
# write-path rejects them).
store_channels = ["command", "setlist"]

# Telemetry of these namespaces is mirrored to `sql/write` — table cells that
# measurements are written into survive a restart.
track_namespaces = ["value_table"]

# Tags (`device.tag` or a bare `tag`) excluded from persistence and restore:
# their acks are still published to the SCADA, but they are not mirrored to
# `sql/write`, telemetry of them is not mirrored, and saved rows are dropped
# from `sql/data` replies. A full-state reply reports their live value instead,
# so a restarted SCADA still shows the current state. For operator actions that
# must start from a known state — pump start buttons stay off until pressed.
skip_tags = ["plc1.pump_start"]

# Retention is per tag (`retentive = true/false` in [[device.tag]]). Physical
# writable commands default to false: after a restart the field is the truth,
# and a stale row must not re-energize a valve. Virtual/UI tags default to
# true (table cells, modes, aliases). Explicit `retentive` overrides either
# default. Non-retentive rows are dropped from restore; a full-state reply
# reports their live value instead of the saved row.

# On the first full-state reply of the process the saved rows of the tracked
# namespaces are also written back into the tag registry (once per start):
# the UI converges from the DB over `prism/ack`, but scripts and logic read
# the registry — a restart must not lose the measurement mode / table index.
restore_on_start = true

# Initial values merged into full-state replies when the DB has no row for
# them yet (a fresh DB must report the table size, otherwise the SCADA table
# never renders). Saved rows always win.
[[sql.default]]
name = "oil_test_num"
ns_name = "particle_select"
value = 11

# At startup request the full state (retried for ~15 s) so an already-open
# SCADA converges even while the DB service is still booting.
push_on_start = true
```

The loop:

1. **SCADA request** — `sql/get` is forwarded to `sql/read` unchanged;
   topic-only requests with `data: null` are remembered as full-state ones.
2. **DB answer** — rows from `sql/data` are forwarded to the ack channel; the
   UI is expected to update only from acks. The contract carries `ns_name` on
   every item, so rows whose bare tag name the configuration recognizes get it
   added on the way; unknown or ambiguous names pass through unchanged. Rows
   of `[sql] skip_tags` and non-retentive command tags are dropped here: a
   saved value of a non-persisted control must not restore it on the SCADA
   side. A full-state reply then adds the **live** registry value of those
   tags instead (when initialized and not `Bad`), so a restarted SCADA
   initializes buttons and tables from the running process rather than waiting
   for the next change; the saved row itself never reaches the UI. The ack
   contract and the DB key rows by bare name, so a live row is only added when
   the bare name is unambiguous or the tag belongs to a tracked namespace: an
   untracked raw PLC setpoint cannot shadow the engineering tag of the same
   name (33.0 % must not become the raw 3300).
   Full-state replies additionally get the `[[sql.default]]` rows merged in
   and, with `[sql] init_fallback`, a fallback row for every tag of the tracked
   namespaces the DB has nothing for (its configured `initial_value` — the
   restart's init telemetry replay happens once, before the SCADA is
   connected). Saved rows always win. With `[sql] restore_on_start` the first
   full reply of the process also applies the saved rows of the tracked
   namespaces to the tag registry (the command write path, no extra acks):
   scripts and logic read the registry, the UI — the acks.
3. **State capture** — every applied command is mirrored to `sql/write` (the
   same row the ack carries), so a restart restores switches and table state;
   `value = null` resets are persisted too. Tags of `[sql] skip_tags` and
   non-retentive command tags are acknowledged to the SCADA but never mirrored.
4. **Measurement mirror** — telemetry of `track_namespaces` is mirrored to
   `sql/write` as it is published (batch snapshots are flushed wholesale),
   keeping cell values written by scripts, the debugger or the devices in the
   DB — not only the ones sent by the SCADA itself. Mirroring is armed only
   after the startup full read is answered (or its retries are exhausted): a
   restart replays the configured `initial_value` seeds as telemetry, and
   those must not be written over the saved state. Commands are mirrored
   immediately. Non-finite values (`nan`, the "no data" init,
   `01_DEVICES.md` §1.3) are never mirrored: they would overwrite a saved cell
   with `null`.

`prism --check-config` fails when `[sql]` is enabled but one of the four
channels is missing. Do not run the reference `mock` gateway together with
Prism: both forward `sql/get`/`sql/data`, and the SCADA would receive duplicate
acks.

### Retention: state vs. momentary command (`retentive`)

After a restart the bridge has to answer one question per writable tag: is the
saved row the operator's **intended state**, or just a command that happened to
be true at the time?

- restoring every writable tag from the DB can re-energize a pump or valve
  that the PLC has since switched off;
- restoring nothing loses modes, table indexes and latching valves that must
  survive a restart.

`[[device.tag]].retentive` makes the answer explicit:

| Value | Meaning | Startup behavior |
|---|---|---|
| `true` | Persistent operator state / latching command | The saved row is restored, queued as a normal command, and confirmed by the ack / next poll. |
| `false` | Momentary command; the field is the truth | The saved row is not restored and not mirrored again. A full-state reply carries the current live value instead, so the SCADA shows the field state without replaying a stale button. |
| absent | Protocol default | Physical writable commands: `false`; virtual/UI tags: `true`. |

```toml
# latching valve: keep it open across a restart
[[device.tag]]
name      = "oil_main_valve"
access    = "rw"
retentive = true

# momentary pump start: never replay it
[[device.tag]]
name      = "oil_main_pump_start"
access    = "rw"
retentive = false
```

Why not one global switch?

- always restoring is unsafe: a stale row can switch equipment on;
- always skipping loses legitimate UI state (table cells, modes, aliases);
- a global `skip_tags` blacklist is easy to forget and does not say **why** a
  tag is excluded. `retentive` is the per-tag contract; `skip_tags` remains for
  tags that must not appear in the DB at all (for example a one-shot pulse).

`retentive = true` is **not** a safety bypass: the restored write is an ordinary
`command`-authority write. An active alarm interlock, a read-only tag or a bad
ack still rejects it, and the failure is reported to the SCADA. Before the
first Good field sample, the tag is shown as `Bad`/`Uncertain`; the SCADA must
not treat its own cached button as confirmed state. The live-value row of a
non-retentive tag is omitted while the tag is uninitialized or `Bad`, so a
missing row means "not confirmed yet", not "false".

## 9. Eclipse Sparkplug B Northbound (`[sparkplug]`)

For foreign SCADA/IIoT stacks (Ignition, HiveMQ, EMQX, AWS IoT) Prism can
publish the same tag values as an Eclipse Sparkplug B edge node. The contract is
protobuf on MQTT; no extra channel declarations are needed.

```toml
# config/02_northbound/01_mqtt/sparkplug.toml (or any file of the MQTT config directory)
[sparkplug]
enabled = true
group_id = "plant"
edge_node_id = "prism-stand-01"
# Optional: with a device id metrics are published as DBIRTH/DDATA
# (sparkplug topic .../prism-stand-01/stand); without it as NBIRTH/NDATA.
device_id = "stand"
qos = 0
aliases = true          # NBIRTH defines aliases; NDATA uses them
alias_base = 1
```

Topics follow the specification:

| Message | Topic | When |
|---|---|---|
| `NBIRTH` | `spBv1.0/<group>/NBIRTH/<node>` | broker connect (retained) |
| `NDATA` | `spBv1.0/<group>/NDATA/<node>` | every telemetry sample |
| `NDEATH` | `spBv1.0/<group>/NDEATH/<node>` | graceful publisher shutdown |
| `DBIRTH` / `DDATA` / `DDEATH` | `.../<node>/<device>` | when `device_id` is set |

The birth carries `bdSeq`, `Node Control/Rebirth`, and every registered tag
with its declared type (`bool` → Boolean, `string` → String, numeric → Double);
data messages carry `seq`, `timestamp` and the metric value (alias when
enabled). A reconnect republishes the birth with an incremented `bdSeq`, so a
SCADA that missed updates converges. The end-to-end check is the same as for
JSON channels: run `prism-sim`, start Prism, subscribe with a Sparkplug client
(`spBv1.0/plant/#`) and verify the virtual/northbound tag in `prism-dbg`.
