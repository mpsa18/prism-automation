# `prism-dbg` — debugger and live panel

`prism-dbg` is the operator/debugger side of the bench. It reads the instance
`config/**`, connects to the Prism debug API (`[debug]`) or to a simulator
Control API, and shows live tags, alarms, device counters, the log ring and the
alarm journal. The same binary provides the headless `control`, `watch`, `tags`
and `modbus` commands for scripts and repeatable checks.

> **Terminal required for the panel.** Running `prism-dbg` without a command, or
> with `tui`, opens the interactive panel only when stdin **and** stdout are
> terminals. Without a terminal it exits with code `2` and a message pointing at
> the headless commands; there is no "serve instead" fallback. Double-clicking
> the binary in a desktop session works because it has a terminal.
>
> Run the panel maximized. The tag table adds or drops its optional columns with
> the available width, and the selected-tag line and bottom status/hint lines are
> clipped on a narrow console, so important diagnostics such as the force author,
> the alarm owner or the reload banner can disappear.

## CLI synopsis

```sh
prism-dbg                                     # panel (TTY required; same as `tui`)
prism-dbg tui [--period <sec>]
prism-dbg control list
prism-dbg control get <tag>
prism-dbg control set <tag> <value>
prism-dbg control force <tag> <value>
prism-dbg control freeze <tag>
prism-dbg control release <tag>
prism-dbg control release_all
prism-dbg control stats
prism-dbg control pause
prism-dbg control resume
prism-dbg control shutdown
prism-dbg control reload_status
prism-dbg control reload_confirm
prism-dbg control reload_reject
prism-dbg watch <tag> [<tag> ...] [--period <sec>] [--duration <sec>]
prism-dbg tags [--report <file>]
prism-dbg --device <name|toml|dir> modbus read <1|2|3|4> <address> <count>
prism-dbg --device <name|toml|dir> modbus write <5|6> <address> <value>
prism-dbg --modbus <host:port> [--unit <1..=247>] modbus write <15|16> <address> <value> [...]
prism-dbg --help
prism-dbg --version
```

Flags may appear before or after the command.

| Flag | Meaning |
|---|---|
| `--sim <file>` | Bench file. Default: `<instance>/devtools/simulator/sim.toml` when that file exists. |
| `--control <host:port>` | Use only this Control API endpoint; overrides `--sim` and the instance `[debug]` discovery. With `--control`, only `--token` supplies a token. |
| `--token <token>` | Token sent in every request; overrides the token from the bench `[control]` section or the core `[debug]` section. |
| `--modbus <host:port>` | Modbus TCP endpoint directly; overrides `--device`. Unit defaults to `1` unless `--unit` is given. |
| `--device <name or path>` | Device from the instance Modbus configuration, or an explicit device config file/folder. Transport, `host:port` and unit id come from its `[[device]]` blocks. |
| `--unit <1..=247>` | Modbus unit id override. Without it, the device's unit id, the bench `[modbus].unit_id`, or `1` for `--modbus` is used. |
| `--report <file>` | Machine-readable output. Format depends on the command (see below). |
| `--period <sec>` | Poll period for `watch` and the panel. Default `0.5`. The panel raises values below `0.05` to 50 ms. |
| `--duration <sec>` | `watch` only: stop after this wall-clock time. |
| `--help`, `--version` | Print help/version and exit `0`. |

## Connection and endpoint discovery

Candidates are built in this order and deduplicated by address:

1. `--control <host:port>`, when given (the only candidate in that case);
2. the core's native debug API, when `config/00_core/00_app.toml` has
   `[debug] enabled = true` (listen defaults to `127.0.0.1:7200`);
3. the bench file `[control]` section (listen defaults to `127.0.0.1:7100` when
   the section is present without a `listen` key).

The core comes first when it is enabled; the bench file is the fallback. The
core endpoint also carries the process metrics shown on the top line.

Behavior differs between headless commands and the panel:

- Headless `control` and `watch` probe the candidates and use the first one that
  accepts a connection. If none is reachable they abort with an error naming
  `--control`/`--sim`.
- Endpoint polling connects in the background: the panel starts immediately,
  retries the current candidate about once a second, rotates through the
  candidates on connection failures, and retries the preferred endpoint in the
  background about every 5 seconds while running on a fallback. Both configured
  services stay visible in the title even when only one is connected.
- `tags` needs no endpoint at all.

### Title and link state

The title has this shape:

```text
prism-dbg · LINK <services> · <state> · prism CPU … · RAM … · handles … · <endpoints> · t=… · tick … · N live · N forced
```

`LINK` is `PRISM`, `SIM`, `PRISM+SIM`, `API` (explicit `--control` endpoint) or
`none`. `<state>` is `RUNNING`, `PAUSED`, `offline`, or `no control api`. With
candidates configured, the endpoint part lists every one with its label and
address, for example `PRISM 127.0.0.1:7200 · SIM 127.0.0.1:7100`. There is no
`(1/2)` position counter.

On a Prism connection the top line carries CPU/RAM/handle metrics; a simulator
endpoint does not publish them, so the metrics show `-`.

### Catalog and offline panel modes

- **Catalog mode** (no candidates at all: no `--control`, `[debug]` disabled or
  absent, and no bench `[control]`): the panel still opens. It shows every tag
  and alarm rule of `config/**` with its passport and keeps configured Modbus
  registers live by polling the devices directly. The status line says
  `catalog: no control api — showing config/** only (use --control/--sim for live
  values)`. In this mode `s` writes writable holding/coil registers over Modbus;
  `f`, `x` and `r` need a Control API and report so.
- **Offline mode** (candidates configured but unreachable): the panel keeps the
  last snapshot when one exists, retries, and continues to fill configured
  Modbus registers directly. It does not switch to catalog mode.
- **No instance discovered**: the status line says
  `no config/** discovered — run from the instance root or pass --sim`; the
  endpoint logic is unchanged.

Headless `control` and `watch` do not have a catalog mode: without a reachable
candidate they fail.

## Headless commands

### `control`

| Command | Behavior |
|---|---|
| `control list` | Prints `tag`, `role`, value, plus `[no data]` for a bad sample and `[forced=…, computed …]` when an override is active. It does **not** print register metadata; use `tags` or the panel's selected-tag line for the config passport. |
| `control get <tag>` | One line `tag = value` with the same flags. |
| `control set <tag> <value>` | Real write through the endpoint's write path. Prints `tag = value (external)`. |
| `control force <tag> <value>` | Debug override: every reader sees the value while the override is active. |
| `control freeze <tag>` | Override at the tag's current effective value. |
| `control release <tag>` | Remove one override; prints whether it was forced. |
| `control release_all` | Remove the overrides owned by this connection and print the count. |
| `control stats` | Simulator: simulated time/tick, objects, tags, speed, paused. Prism: also uptime, MQTT published/dropped, accepted/rejected commands, read/write counters, RAM/CPU/handles and per-device counters. |
| `control pause`, `resume`, `shutdown` | Served by the simulator. The Prism debug API answers `unsupported`; the command exits `1`. |
| `control reload_status`, `reload_confirm`, `reload_reject` | Read, apply or discard the staged configuration change. Served by both endpoints. |

`control` with no operation, or with an unknown operation, is a usage error.

Capability matrix for the two endpoints:

| Operation | Prism core `[debug]` | Simulator `[control]` |
|---|---|---|
| `list`, `get`, `set`, `force`, `freeze`, `release`, `release_all`, `stats` | yes | yes |
| `pause`, `resume`, `shutdown` | `unsupported` | yes |
| `reload_status`, `reload_confirm`, `reload_reject` | yes | yes |
| `reload_full` (API operation) | yes | no |
| `logs` (used by the panel) | yes | no |

`reload_full` is an API operation on the core; `prism-dbg` has no
`control reload_full` subcommand. The panel's `r` key uses a different path (see
[Reload screen](#reload-screen)).

Error responses carry a code: both APIs use `bad_request`, `unauthorized`,
`unknown_tag`, `read_only`, `wrong_type`, `internal` and `busy`; the core also
uses `unsupported`, `protected`, `no_value` and `alarm_hold`. Any error response
makes the command exit `1`.

### `watch`

```sh
prism-dbg watch io_controller.flow_sp io_controller.temperature_pv --period 0.2
prism-dbg watch io_controller.flow_sp --duration 30 --report samples.jsonl
```

`watch` polls `list` once per period and prints one line per tag:

```text
[t=12.500] plc1.temperature = 153.2 (+0.5) [forced=150, computed 153.2]
```

A bad sample prints `[no data]`; a string tag prints its text. With
`--duration` the command stops after that wall-clock time; without it, it runs
until interrupted. Unknown tags abort the command. `--report` writes JSON Lines,
one object per sample per tag, with `t`, `tick`, `tag`, `role`, `value`, `raw`,
`quality`, `computed` and `forced`.

### `tags`

`prism-dbg tags` prints the configuration tag universe without any transport:
every configured tag with its protocol/passport note, every alarm rule as an
`alarm` row, and a summary line. It works without a simulator or Control API.
With `--report <file>` it writes a JSON catalog containing `tags`, `alarms` and
config `findings`.

### `modbus`

`modbus` gives raw register/bit access over the transport the SUT uses.

Endpoint selection:

- `--modbus <host:port>` wins; unit id is `--unit` or `1`.
- `--device <name|path>` resolves a device from the instance Modbus
  configuration (numbered or legacy layout) or uses an explicit file/folder.
  Its `[[device]]` blocks supply transport, `host:port` and unit id; Prism
  defaults are port `502` and unit `1`. Tag-only files are skipped, and the
  selected path must describe exactly one TCP device.
- With neither flag, a bench `[modbus] listen` override wins when set;
  otherwise the command targets the only device of the Modbus configuration.
  Several devices are an error naming them. Wildcard listen hosts are mapped to
  loopback (`0.0.0.0` → `127.0.0.1`, `[::]` → `[::1]`).

Functions and values:

```sh
prism-dbg --device plc1 modbus read  1 0 8        # coils
prism-dbg --device plc1 modbus read  2 300 4      # discrete inputs
prism-dbg --device plc1 modbus read  3 0x10 8     # holding registers
prism-dbg --device plc1 modbus write 5 200 1      # one coil
prism-dbg --device plc1 modbus write 6 102 250    # one register
prism-dbg --modbus 127.0.0.1:502 --unit 3 modbus write 16 100 10,20,30
```

- `read 1|2` reads bits; `read 3|4` reads registers.
- `write 5|6` writes one coil or one register; `write 15|16` writes several
  coils/registers. Values may be space- or comma-separated.
- Coil values accept `0`/`1`, `true`/`false` and `on`/`off`.
- Register values accept the raw `u16` range and negative two's-complement
  values (`-32768..=65535`).
- Addresses and numeric values accept decimal, hexadecimal (`0x18`), binary
  (`0b11000`) and octal (`0o30`) literals, with optional `_` separators.

### `--report` formats

| Command | Report |
|---|---|
| `control <op>` | Pretty-printed JSON object with `ok`, `command` and the operation's data. |
| `modbus read/write` | Pretty-printed JSON with command, endpoint, unit id, function, address and registers or bits. |
| `tags` | Pretty-printed JSON catalog: tags, alarms, findings. |
| `watch` | JSON Lines, one sample object per tag per poll. |

A command that fails does not produce a report for `control`, `modbus` or
`tags`; those commands write the file only after a successful operation.
`watch` creates its file at start and appends samples as they arrive, so a run
that fails later keeps the samples already written. The interactive panel
ignores `--report`.

## Force, freeze, set and release

`set` is a real write: scale and limits are applied, and the confirmation
arrives after the physical write on a Prism core; a simulator or virtual tag
applies it immediately. `force` replaces the value readers see without touching
the hardware: on a Prism core that includes scripts, alarms, compute blocks, the
OPC UA server and MQTT telemetry; on a simulator it changes the process image,
so the core reads the forced value over its normal device transport. `freeze`
is a force at the current effective value. `release` restores real samples.

```sh
prism-dbg control force io_controller.tank_level 9.5
prism-dbg control freeze io_controller.tank_temperature
prism-dbg control release io_controller.tank_level
prism-dbg control release_all
```

For headless commands, read the lifetime warning below: a CLI override does not
survive the process that created it. Use the interactive panel when the
override must stay active while you observe or operate the stand.

### Override ownership and lifetime

- Every Control API connection has one author: **`tcp:<peer>`** on both the
  Prism `[debug]` API and the simulator `[control]` API. Ownership is per
  connection, not per process id; reconnecting creates a new author.
- One connection owns a tag at a time. A second client that tries to force or
  freeze it gets
  `tag '<id>' is forced by another debugger (<owner>); release it there first`.
  The simulator's freeze message says "frozen"; the core uses the same "forced"
  wording for freeze and release. `release` by a non-owner is refused the same
  way.
- `release_all` releases only the caller's overrides, never another
  connection's.
- When a connection closes, the endpoint releases every override still owned by
  it. This applies to both APIs and covers a crashed panel as well as a normal
  quit.

**Headless `force`/`freeze` is connection-scoped.** Each
`prism-dbg control force …` invocation opens a TCP connection, performs the
override, prints the result and exits; the endpoint then releases the override
because the connection is gone. The override therefore does not persist after
the command returns, and a later `prism-dbg control release` (a new connection)
normally reports "not forced"; `release_all` in a fresh process releases `0`.
Use the interactive panel to hold an override while you inspect or actuate the
stand.

### Core-only override settings

Against a Prism core, `[debug]` controls override behaviour:

- overrides expire after `override_ttl_ms` unless released first (`0` = until
  released);
- every force/freeze/release is journaled to `audit_path`;
- with `stub_mode = true`, a command aimed at an overridden physical tag is
  acknowledged without a physical write.

The simulator has no TTL, audit journal or stub mode for overrides; its
overrides last for the connection and disappear at disconnect.

### Validation and alarm holds

- Boolean tags accept `0`/`1`; `prism-dbg` also accepts `true`/`false` and
  passes them as `1`/`0`. Other values are `wrong_type` for a bool tag.
- Values must be finite. Freeze on a tag with no numeric value fails.
- String tags cannot be forced on the core.
- License status tags are refused locally by the panel and by the core.
- On the core, an active alarm is above the debug tier: while an alarm holds a
  tag, force and freeze are refused with
  `tag '<id>' is held by active alarm '<rule>'; alarms outrank debug
  overrides`.

## Interactive panel

### Screens

`v` moves forward through the screen cycle and `Shift+V` moves back:

```text
Tags → Diagnostics → Simulators → Reload → History → Log → Tags
```

On SIMULATORS, `Shift+V` returns to Tags rather than to Diagnostics.

`Esc` returns to Tags from Diagnostics, Simulators, Reload, History and Log (on
History, `Esc` clears an active journal filter first). `q` and `Ctrl+C` quit
everywhere.

There are no named presets or views, including a separate health view; the table
is one adaptive layout whose columns depend on the terminal width.

### Tags screen

Fixed columns: marker, `TAG`, `ROLE`, `VALUE` (with per-frame delta), `QUALITY`,
`AGE` and `FORCED`. As the console widens the table adds `TYPE` (from 90
columns), `ADDRESS` (110), `UNIT` (125), `ACCESS` (140), `OUT` (OPC/MQTT/SQL
sinks, 150) and `BINDINGS` (alarm rules that read or write the tag, 170).

There is no `NOTE` column. The description and note details are shown on the
`selected:` line below the table and are searchable with `/`. They include the
config passport (`modbus input@10 word x0.1 ro`, `opc ns=2;s=…`, `virtual rw
float`), `calc <value>` for the value the engine computes under an override,
`held by <author>` for an active override, `= <text>` for a string value,
`not in sim: <reason>` / `awaiting sim` for configured tags, and `sim only` for
image tags absent from the configuration.

#### Filter

`/` opens the filter prompt; `Enter` applies, `Esc` cancels. Tokens are
case-insensitive and whitespace-separated; all must match.

| Token | Matches |
|---|---|
| plain text | substring of the tag name, role or note |
| `dev:<text>` | device part of the tag id (before the first `.`) |
| `tag:<text>` | tag part (after the first `.`), also the text value |
| `proto:<text>` | transport/protocol or role column |
| `role:<text>` | role column |
| `type:<text>` | declared data type or note |
| `unit:<text>` | engineering unit or note |
| `access:<text>` | access mode (`ro`, `rw`, `wo`) |
| `qual:<text>`, `quality:<text>` | quality column |
| `src:<text>`, `source:<text>` | value source |
| `opc:<text>`, `node:<text>` | published OPC UA node or note |
| `note:<text>` | any note text |
| `val:<expr>`, `value:<expr>` | value comparison |

`val:` accepts `>N`, `>=N`, `<N`, `<=N`, `=N`, `N`, `N..M`, `..M`, `N..`, `nan`
(no value) and `num` (any value). An unknown `key:` falls back to a plain
substring, so text such as `ns=2;...` stays searchable.

`Space` marks the selected tag (`*`); marks survive filtering and row rebuilds.
`a` marks every visible tag and `A` clears the marks. `f`, `s`, `x` and `r` act
on all marked tags, or on the selected tag when nothing is marked.

#### Tag-screen keys

| Key | Action |
|---|---|
| `↑`/`↓`, `j`/`k`, `PgUp`/`PgDn`, `Home`/`End` | Move the selection |
| `Space` | Mark/unmark the selected tag |
| `a` / `A` | Mark every visible tag / clear marks |
| `/` | Filter |
| `f` | Force the selected/marked tags to a finite number (`Enter` applies) |
| `s` | Set the selected/marked tags; the write route is chosen per tag |
| `x` | Freeze the selected/marked tags at their current values |
| `r` / `R` | Release the selected/marked tags / release all overrides owned by this panel |
| `p` | Pause/resume the scan loop (simulator; the Prism API answers `unsupported`) |
| `y` / `n` | Confirm / dismiss a staged configuration change |
| `v` / `Shift+V` | Next / previous screen |

`Enter` is not bound on the Tags screen; there is no tag action menu. `Enter`
connects on the Simulators screen and drills down on the History screen.

`f` needs a Control API; it does nothing useful in catalog mode or while the
configured endpoint is offline. `s` chooses its route per tag:

- the current Control API image knows the tag and its role is not
  `output`/`link` → `set` on that endpoint;
- an engine-produced tag (`output`/`link`) → the status line suggests `f`;
- a writable holding/coil register whose config access is not `ro` → native
  Modbus write;
- a configured virtual tag → the candidate that reports it as `virtual` (the
  bench only holds a copy);
- another tag missing from the current image → the first other candidate whose
  image knows it, and the panel switches to that endpoint.

With several marked tags, `s` parses the value for each tag's declared type,
picks the route per tag, and reports partial failures.

### Diagnostics screen

Shows the endpoint's observability data: uptime, MQTT published/dropped,
accepted/rejected commands, per-device reads/writes/timeouts and online state.
The alarm list has `STATE`, `PRIORITY`, `RULE`, `SOURCE TAG`, `VALUE`, `QUAL`,
`ACK` and `AGE` columns. On a Prism connection the screen also shows process
memory (working set, commit, active private) and OS handles; a simulator endpoint
shows `core metrics: not available (simulator endpoint)`. Configured alarm rules
and active runtime-only alarms are listed together; the `RUNTIME` separator is
not selectable.

`Tab` toggles the focus between the ALARMS and DEVICES lists. The other list
keeps its cursor and position. `Esc` or `Shift+V` returns to Tags.

| Key | Action |
|---|---|
| `Tab` | Switch ALARMS ↔ DEVICES |
| `↑`/`↓`, `j`/`k`, `PgUp`/`PgDn`, `Home`/`End` | Move the cursor in the focused list |
| `Esc`, `Shift+V` | Back to Tags |

### Simulators screen

`prism-sim` processes that own a Control API write presence files to
`<instance>/data/simulators/sim-<name>-<pid>.json`. The debugger reads them,
probes each endpoint with a `stats` request and lists the result. There is no
refresh key: presence is re-read and probed every 2 seconds.

| Column | Meaning |
|---|---|
| `STATUS` | `online` (Control API answered `stats`) or `offline` |
| `SIMULATOR` | `[sim].name` of the bench profile |
| `ROLE` | `[sim].description`, falling back to the name |
| `CONTROL API` | Endpoint the debugger talks to |
| `DEVICES` | Device modules served by that process |
| `TAGS` | Size of its process image |
| `MODBUS` | Modbus endpoint(s) it serves |

Columns adapt to the width: 120+ columns show all seven; 90–119 drop `DEVICES`;
below 90 only `STATUS`, `SIMULATOR`, `ROLE` and `TAGS` remain. Long values are
cut with `…` so a cell cannot push the next column out of line.

The line under the table describes the selected row: full role, endpoint,
`unreachable: <error>` when offline, pid, uptime, and the last three path
components of the profile. `Enter` on an online row reconnects the panel to that
simulator; the candidate list becomes the online simulators and `v`/`Shift+V`
keep cycling screens. On an offline row the status line shows the probe error.

| Key | Action |
|---|---|
| `↑`/`↓`, `j`/`k`, `Home`/`End` | Select a row |
| `Enter` | Connect to the selected online simulator |
| `Esc`, `Shift+V` | Back to Tags |

### Reload screen

Shows the staged configuration plan or the last reload result reported by the
current endpoint: changed files, steps, and whether a full rebuild is required.
The bottom banner on the Tags screen also announces a pending or failed change.
Keys:

| Key | Action |
|---|---|
| `p` | Re-poll the endpoint and refresh the plan |
| `a` | Apply the plan (`reload_confirm`); granular where possible, full rebuild when required |
| `r` | Request a full reload (Prism only, see below) |
| `c` | Discard the pending plan (`reload_reject`); the running system keeps working |
| `↑`/`↓`, `PgUp`/`PgDn`, `Home`/`End` | Scroll the plan |
| `Esc` | Back to Tags |
| `Shift+V` | Previous screen |

`a` and `c` work against both endpoints. `r` writes the Prism service command
`system.reload = 1`, which schedules a full reload on the core. The simulator
image has no `system.reload` tag and its Control API has no `reload_full`
operation, so `r` reports an error there. On a Prism connection the core debug
API also accepts a direct `reload_full` operation, but `prism-dbg` does not
expose it as a CLI command.

### History screen

The alarm journal is the CSV file configured by `[alarms] history_path`
(`config/00_core/00_app.toml`). The path is resolved from the `config/`
directory; the standard instance uses `../data/alarms.csv`. If the key is
absent, the core default `alarms.csv` next to `config/` applies; without an
`app.toml`, `data/alarms.csv` is tried, then `config/alarms.csv`. If the key is
empty, the journal is disabled; if the file does not exist yet, the screen says
so and waits for the first transition.

Each record is `timestamp_ms,device,tag,active,value,priority,message`. The
panel reads the file when its size or modification time changes, keeps the
newest 2 000 transitions in memory, and follows rotation. Only **RAISE** and
**CLEAR** transitions are journaled; acknowledgements are not written to this
file.

The screen opens in **summary** mode: one row per source with the latest event,
priority, transition count, last time and message. `a` switches to the full
timeline (newest first: time, event, priority, source, value, message).

| Key | Action |
|---|---|
| `↑`/`↓`, `j`/`k`, `PgUp`/`PgDn`, `Home`/`End` | Move the highlighted row |
| `a` | Toggle summary / full timeline |
| `/` | Filter: `source:`/`dev:`/`tag:`, `priority:`, `event:raise`/`event:clear`, or plain text over source, priority, event and message |
| `Enter` | Drill into the selected source: sets `source:<device.tag>` and switches to the full timeline |
| `c` | Truncate the live journal after confirmation; rotated `alarms.csv.N` archives are left untouched |
| `Esc` | Clear the filter; with no filter, return to Tags |

### Log screen

The Log screen prefers the in-memory ring served by the Prism debug API
(`logs`: newest 2 000 records / 1 MiB, incremental by sequence). No log file is
needed; a flash-based stand can set `[logging] file_enabled = false`. For a
simulator endpoint or an older core without the `logs` operation, the screen
falls back to the file tail configured by `[logging] file_path` (default
`logs/prism.log`; an older core's newest `logs/app_*.log`). File tails are read
from the end in 256 KB chunks and pick up rotation.

Long records wrap under the message column. Levels use the console palette
(`ERROR` red, `WARN` yellow, `INFO` green, `DEBUG` cyan, `TRACE` magenta).

| Key | Action |
|---|---|
| `↑`/`↓`, `j`/`k`, `PgUp`/`PgDn` | Scroll |
| `Home` | Oldest retained record |
| `End` | Return to the live tail |
| `v` / `Shift+V` | Next / previous screen |
| `Esc` | Back to Tags |

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success, including `--help` and `--version`. |
| `1` | A command failed: Control API error response, or a Modbus exception response. |
| `2` | Usage, transport or local error: unknown command/option, missing argument, unreachable endpoint, no terminal for the panel, unreadable report path. |

Option and argument parse errors print the full help to stderr. Command-level
usage errors print a one-line usage message. `--help` prints the help to stdout
and exits `0`.
