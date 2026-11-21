# Service Tags (`system.*`)

A reserved pseudo-device `system` exposes the runtime itself: counters,
license state, alarm controls, maintenance switches. Service tags are virtual
tags that are **not bound to hardware and not counted by the license** — neither
in a commercial tier nor in the 128-tag Community edition (`TagInventory` skips
them, including their `alarm.*` signals). They are a control surface, not
process points.

They are addressed like any other tag — `<device>.<tag>` → `system.<name>` — so
they work everywhere the platform already works: MQTT commands, OPC UA reads and
writes, Rhai (`read`/`write`), the native debug API (`prism-dbg`), and the
console.

---

## 1. Two kinds

| Kind | Access | Behaviour |
|---|---|---|
| **command** | `rw` when allowed, `ro` otherwise | a write executes an action; the result is acknowledged through the regular write-outcome channel (MQTT ack / OPC status / debug API reply). The tag is a **pulse**: it reads back `0` (or empty text) after the command |
| **status** | `ro` | refreshed by the core every `[service_tags] update_ms` (default 1 s) |

Service tags are virtual: their numeric types are `int` / `float` / `bool`, never
`real` (that name belongs to industrial wire formats — Modbus, S7, OPC).

Every accepted command publishes:

| Tag | Meaning |
|---|---|
| `system.command_result` | text result of the last command (`restarted: press`, `acknowledged 3 alarm(s)`, an error, …) |
| `system.command_ts` | when it ran, ms since epoch |
| `system.command_author` | source authority (`command`, `script`, `debug`, …) |

A rejected command returns an error to the writer **and** is written to
`system.command_result`, so a SCADA operator sees why nothing happened.
Until the first command runs the three outcome tags are published empty
(`command_result`/`command_author` empty text, `command_ts = 0`), so a
fresh core does not expose them as `NaN`/`bad`.

`prism-dbg` labels the two kinds in the `ROLE` column (`command` / `status`)
and sorts statuses before commands, so the tag table does not read as if the
pulses were state; `/role:command` and `/role:status` filter them. A status
that is legitimately unset (`command_result` before the first command,
`self_test_result` before the first self-test) is shown as `-`, not as bad
data; `rss_mb` is Linux-only and is shown as `n/a` on Windows.

---

## 2. Command reference

| Tag | Payload | Action |
|---|---|---|
| `reload` | bool | full reload of all configuration and scripts (same as `r`) |
| `reload_module` | string | hot-reload one device module: `modbus/press`, `01_southbound/01_modbus/press`, `counter`, or `modbus` (the whole group) |
| `scripts_reload` | bool | rebuild the Rhai engine and its poll scheduler; pollers keep running |
| `confirm` / `reject` | bool | answer a staged WASM module update (same as `y` / `n`) |
| `device_restart` | string | restart one device poller (resumes it if paused) |
| `device_pause` ⚠️ | string | stop polling a device for maintenance; its status becomes offline |
| `device_resume` | string | resume a paused device |
| `alarm_ack` | string | acknowledge `device.tag` (all its active alarms) or a rule id |
| `alarm_ack_all` | bool | acknowledge every active alarm |
| `alarm_clear_all` | bool | clear every active alarm (same as `c`) |
| `alarm_shelve` | string | suppress a source tag: `plc.press` (30 min) or `{"tag":"plc.press","minutes":30}` (`0` = until unshelved) |
| `alarm_unshelve` | string | remove a shelve: a source tag, or `*` for all |
| `alarm_test` | string | raise a synthetic alarm: `{"priority":"critical","message":"...","seconds":10}`; it clears itself |
| `alarm_rule_disable` ⚠️ | string | maintenance bypass of one rule by id (`speed_low` or `alarm.speed_low`): the rule resets like a gated-out one and does not raise |
| `alarm_rule_enable` | string | re-enable a bypassed rule |
| `log_rotate` | bool | rotate the log file now |
| `snapshot` | string | write a diagnostic JSON snapshot; empty = `data/snapshots/service-<timestamp>.json` |
| `self_test` | bool | run the consistency self-test; the text also lands in `system.self_test_result` |
| `shutdown` ⚠️ | bool | graceful stop of the instance |
| `force` ⚠️ | string | `{"tag":"plc.press","value":1.0}` — force a value (requires `[debug] enabled`) |
| `release` ⚠️ | string | release a forced tag (requires `[debug] enabled`) |
| `stub_mode` ⚠️ | bool | acknowledge writes to forced tags without transmitting them (requires `[debug] enabled`) |

⚠️ = dangerous: not writable unless listed in `[service_tags] allow`
(see §4). A `ro` command tag rejects the write with "tag is read-only".

### Alarm semantics

* **shelve** — the rule is evaluated but forced to a normal reset while the
  shelve is active: an active alarm clears and no new one is raised. The
  evaluation keeps running, so after `alarm_unshelve` the next fresh sample
  re-trips the condition. Shelves are time-limited (`minutes`, default 30) or
  last until unshelved (`0`).
* **rule bypass** (`alarm_rule_disable`) — a rule-id mute without a deadline.
  Rule mutes are cleared by a full reload (the rule ids belong to the previous
  catalog); shelves keep their own deadline.
* **test alarm** — raises a synthetic alarm on `system.alarm_probe` with the
  requested priority and message, then clears it after `seconds` (1…3600,
  default 10). It travels the whole chain (store → MQTT alarm contract →
  history), which is the point: verify that the operator station really sees an
  alarm.
* Statuses can carry **ordinary alarm rules**: `system.mqtt_connected = false`
  is the classic "SCADA link lost" alarm, `system.license_state` can be watched
  for `grace`/`demo`.

---

## 3. Status reference

| Tag | Type | Meaning |
|---|---|---|
| `devices_online` / `devices_total` | int | devices that report online / configured polled devices |
| `devices_paused` | int | devices stopped for maintenance |
| `alarm_count` / `alarm_unacked` | int | active alarms / active unacknowledged |
| `alarm_highest` | text | `info` \| `warning` \| `critical` \| `emergency` (empty when idle) |
| `alarm_last` | text | message of the last alarm transition |
| `alarm_last_ts` | float | time of the last transition, ms since epoch (`0` = none yet) |
| `alarm_last_active` | bool | last transition raised (`1`) or cleared (`0`) the alarm |
| `alarm_muted` | int | shelved sources + bypassed rules |
| `license_state` | text | `normal` \| `free` \| `demo` \| `grace` \| `awaiting` \| `blocked` |
| `license_tag_used` | int | tags counted against the license |
| `license_tag_limit` | int | licensed limit (`0` = unlimited) |
| `license_addon_tags` | int | extra tags from add-on files |
| `license_days_left` | float | days before expiry (`-1` = unlimited) |
| `instance` / `version` | text | instance name / Prism version |
| `uptime_s` | float | process uptime |
| `rss_mb` | float | resident memory; **Linux only** — elsewhere the tag is `bad` ("no data") |
| `mqtt_connected` | bool | broker link state |
| `mqtt_queue` / `mqtt_dropped` | int | queued outbound events / events dropped on backpressure |
| `scripts_loaded` | int | loaded Rhai scripts |
| `compute_blocks` | int | configured compute blocks |
| `stub_mode_state` | bool | current `[debug] stub_mode` |
| `last_reload_ts` / `last_reload_ok` | float / bool | last reload attempt |
| `command_result` / `command_ts` / `command_author` | text / float / text | last command outcome |
| `self_test_result` | text | last self-test text (empty until `system.self_test` runs) |
| `alarm_probe` | float | carrier of `alarm_test` alarms |

`alarm_last` keeps the message of the latest transition even after the alarm
clears, so it can stay non-empty while `alarm_count` is `0`.
`alarm_last_active` says whether that transition raised (`1`) or cleared (`0`)
the alarm, and `alarm_last_ts` is its time in ms since epoch (`0` = no
transition since startup). The live state is `alarm_count` / `alarm_highest`.

License values reflect the **startup** decision; a new `license.key` is picked
up on the next process start or full reload.

---

## 4. Configuration

```toml
# config/00_core/00_app.toml
[service_tags]
enabled = true          # register the system.* tags at all
update_ms = 1000        # status refresh period
allow = ["shutdown"]    # extra commands on top of the safe set; "*" allows all
```

* `enabled = false` removes the namespace entirely (and it disappears from the
  license inventory as well, since it never was part of it).
* The safe set is: `reload`, `reload_module`, `scripts_reload`, `confirm`,
  `reject`, `device_restart`, `device_resume`, `alarm_ack`, `alarm_ack_all`,
  `alarm_clear_all`, `alarm_shelve`, `alarm_unshelve`, `alarm_test`,
  `alarm_rule_enable`, `log_rotate`, `snapshot`, `self_test`.
* Dangerous commands (`shutdown`, `device_pause`, `alarm_rule_disable`,
  `force`, `release`, `stub_mode`) require an explicit entry in `allow`.
* A user device named `system` is rejected by the config loader: the name is
  reserved.

Changes to `[service_tags]` are applied at startup (the section is part of the
application config, not of the reloaded device tree).

---

## 5. Exposure

Nothing is exported automatically: service tags appear in MQTT/OPC UA only when
the project lists them.

**MQTT** — add a channel:

```toml
# config/02_northbound/01_mqtt/channels.d/service.toml
[[channel]]
id = "service"
contract = "telemetry"
topic = "prism/service/{name}"
namespace = "system"
```

Commands arrive through the regular command contract (`prism/command/system/<name>/set`
with `{"v": ...}`) as soon as the command tag is `rw`.

**OPC UA** — add the nodes you need to the server export, exactly like device
tags (`system.reload_module`, `system.alarm_ack_all`, …). Writable nodes need
`writable = true`; the write is acknowledged with the command result.

**Rhai** — service tags are ordinary tags:

```rhai
// Interlock: stop the line when SCADA is gone for a minute
if read("system.mqtt_connected") == 0.0 { write("system.device_pause", "press"); }
```

**Console** — single-key shortcuts while the runtime is running:

| Key | Action |
|---|---|
| `r` | full reload |
| `c` | clear all alarms |
| `y` / `n` | confirm / reject a staged module update |
| `a` | acknowledge all active alarms |
| `t` | raise a critical test alarm for 10 s |
| `d` | diagnostic snapshot |
| `l` | rotate the log |
| `s` | print `system.*` statuses |
| `h` / `?` | help |

---

## 6. Limits and notes

* A full reload clears maintenance pauses, rule bypasses and the `paused`
  counter; shelters keep their deadline.
* `rss_mb` reports `bad` where the platform has no cheap RSS source (Windows,
  macOS): the tag says "no data" instead of a misleading zero.
* `force`/`release`/`stub_mode` are refused while `[debug] enabled = false`.
* Commands run on the main control loop: a command that triggers a reload is
  acknowledged first, then the reload starts. A full command queue (64 entries)
  rejects new commands with "service command queue is full".
* Service tags do not appear in `TagInventory` and do not count toward the
  licensed tag quota; their alarm signals do not count either.
