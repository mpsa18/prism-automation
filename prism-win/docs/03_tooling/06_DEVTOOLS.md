# `prism-devtools` — configuration reference

`prism-devtools` is the configuration CLI for a Prism instance. It validates Rhai
scripts, generates northbound configuration from southbound tags, scaffolds
entities, imports and exports tag inventories, and migrates legacy folder
layouts.

It works on one **instance root**: the directory that contains `config/`. The
simulator, debugger, scanner and sniffer are separate tools covered in
[`01_BENCH_TOOLS.md`](01_BENCH_TOOLS.md).

## Command map

| Command | Purpose |
|---|---|
| `validate rhai` | Compile Rhai scripts and check script references from config. |
| `generate mqtt` | Write MQTT tag rules, channels/topics and payload seeds from southbound tags. |
| `generate opc-client` | Write OPC UA client endpoint config. |
| `generate opc-server` | Write the OPC UA server address space. |
| `generate tags` | Add a batch of southbound tags from a pattern or declarative spec. |
| `init` | Create a new project tree from a template preset. |
| `ml new` | Create a self-contained Rust ML plugin project and module config. |
| `scaffold` | Create one device, tag, virtual tag, alarm, history entry, script, poll or protocol defaults file. |
| `inventory update` | Refresh the tag ledger (`data/tag_inventory.csv`) from the current configuration. |
| `inventory export` | Write a filtered CSV/TSV/JSON view of the tag ledger. |
| `import inventory` | Rebuild southbound tag files from a TOML inventory or the CSV ledger. |
| `trim mqtt` | Report or remove MQTT rules that reference tags that no longer exist. |
| `migrate layout` | Move legacy role folders and files into the numbered layout. |

## Common conventions

### Instance root

Commands that operate on an instance accept `--root <dir>`. The default is the
discovered instance: the current directory or one of its ancestors, then the
executable location; if nothing is found, `.` is used. Relative paths are
resolved against the root unless a section below says otherwise. `init` is the
exception: it takes `--out` for the project location and has no `--root`.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Success; for `--check`, no differences were found. |
| `1` | Findings: validation errors, drift/missing generated files, `--check` failures, stale MQTT rules, migration conflicts, or an inventory write failure. |
| `2` | Usage error, missing required config, or a load/internal error. |

`validate rhai` exits `0` when only warnings are reported. `trim mqtt --apply`
exits `0` after a successful rewrite. `init` and `ml new` use `1` for a
scaffolding failure and `2` for bad arguments.

### Preview, check and overwrite

- `--dry-run` writes nothing and prints the files that would be produced.
- `--check` writes nothing and exits `1` when generated files are missing or
  differ from what would be generated. It is the mode to use in scripts and CI.
- `--force` means different things per command; the exact behavior is listed
  with each command. For the northbound generators it overwrites a generated
  file whose content was changed after the last run.
- `--apply-hand` (MQTT and OPC generators only) adopts or updates the
  hand-managed seed files. It is not the same as `--force`.

JSON reports are skipped in `--dry-run` and `--check` modes for the
northbound generators and for `generate tags`.

## Generator configuration and common options

Generator templates ship in `devtools/tooling/generators/`, next to the
`prism-devtools` binary. A project created by `init` contains this folder, so
the examples in this page run without creating generator configs by hand.

The templates are:

| Generator | Config file |
|---|---|
| `generate mqtt` | `mqtt.toml` |
| `generate opc-client` | `opc_client.toml` |
| `generate opc-server` | `opc_server.toml` |
| `generate tags` | `tags.toml` |

### Config lookup

A generator config is located in this order:

1. `--config <file>` (absolute, or relative to the instance root).
2. `<root>/generators/<name>.toml`.
3. `<root>/devtools/tooling/generators/<name>.toml`.
4. `<root>/devtools/generators/<name>.toml` (legacy location).

`generate mqtt`, `generate opc-client` and `generate opc-server` require a
config file; if none is found they exit `2` and list the paths they tried.
`generate tags` does not require one: the CLI flags are enough for a one-off
batch, and a missing `tags.toml` is allowed.

### Targets and layout

Each config declares the input directories in `[generator].targets`. Targets
are scanned recursively for `*.toml`; split tag files inside one device folder
are merged into one device before validation.

`[generator].layout` selects the output shape:

- `single` — one `tags.toml`/`channels.toml`/`endpoints.toml`/`nodes.toml`.
- `split` — one file per channel or device under `channels.d/`, `endpoints.d/`
  or `nodes.d/`.

Switching layouts retires files from the old layout to `<name>.bak`; with
`--check` they are reported as drift instead.

### Seeds and drift guard

Some files are hand-managed and are only created when missing:

- `generate mqtt`: `broker.toml` and `channels.toml`/`channels.d/` in the v4
  schema (or `{broker,topics}.toml` in v3). Payload templates
  (`payloads/*.json`) are seed-only and are never rewritten.
- `generate opc-client`: `defaults.toml`.
- `generate opc-server`: `server.toml`.

Without `--apply-hand` the broker/channel/defaults/server files are never
overwritten. With `--apply-hand` the generator writes the described content,
keeps a `.bak` on the first adoption, and from then on applies the same drift
guard as generated files. `--apply-hand --check` performs the comparison
without writing. Payload templates are not affected by `--apply-hand`.

Generated files are tracked in `data/.prism-devtools.manifest.json`. A manual
edit stops generation until the edit is folded back into the generator config
or `--force` is passed.

### Options shared by the northbound generators

| Option | Behavior |
|---|---|
| `--root <dir>` | Instance root. |
| `--config <file>` | Explicit generator config; overrides the lookup. |
| `--dry-run` | Print previews; write nothing. |
| `--check` | Write nothing; exit `1` on missing or drifting files. |
| `--force` | Overwrite generated files that contain manual edits. Does not adopt hand-managed files; use `--apply-hand` for those. |
| `--apply-hand` | Adopt/update hand-managed seed files; `.bak` on first adoption. |
| `--on-collision <mode>` | `error`, `skip` or `rename`; default `error`, or the value in `[generator].on_collision`. |
| `--output-dir <dir>` | Override the output directory (root-relative). |
| `--output-file <file>` | Write one unified file instead of split files. `generate mqtt` only. |
| `--report <file>` | Override the JSON report path. |

## `validate rhai`

```bash
prism-devtools validate rhai [--root <dir>] [--report <file.json>] [--no-color] [paths…]
```

The command compiles every `*.rhai` file under `config/scripts/` and
`scripts/`, compiles `expression = "..."` values from TOML, and checks that
functions named by `script_func` and `[[poll]].function` are declared. It also
checks that `[[poll]].file` and `[[script]].file` exist. Diagnostics include
source snippets and positions.

| Option | Default / behavior |
|---|---|
| `--root <dir>` | Discovered instance, else `.`. |
| `paths…` | Optional files or directories. Relative paths are resolved under the root. If omitted, `config/scripts/` and `scripts/` are used. |
| `--report <file.json>` | Write the JSON summary and diagnostics. The path is resolved from the current directory. |
| `--no-color` | Disable ANSI colors. Colors are otherwise used only on a terminal. |

Exit codes: `0` no errors (warnings allowed), `1` validation errors, `2`
usage or internal error.

Examples:

```bash
prism-devtools validate rhai --root .
prism-devtools validate rhai --root instances/stand-01 --report build/rhai.json
prism-devtools validate rhai --root . scripts/interlocks.rhai scripts/pumps/
```

## `generate mqtt`

```bash
prism-devtools generate mqtt [--root <dir>] [--config <file>] [--dry-run|--check]
    [--force] [--report <file.json>] [--on-collision error|skip|rename]
    [--output-dir <dir>] [--output-file <file>] [--apply-hand]
```

Reads southbound devices declared in `mqtt.toml` and writes the northbound MQTT
configuration:

| Output | Content |
|---|---|
| `config/02_northbound/01_mqtt/tags.toml` | `[[telemetry_group]]`, `[[telemetry_tag]]` and `[[command]]` rules. |
| `channels.toml` or `channels.d/<contract>/<id>.toml` | v4 channels: topic, payload template and fields. |
| `payloads/*.json` | Payload templates, seeded when missing. |
| `broker.toml` | Connection settings, seeded when missing. |
| `topics.toml` | v3 topics, seeded when missing. |

The default output directory is `config/02_northbound/01_mqtt/`;
`--output-dir` overrides it. `--output-file` is accepted only by this
generator and writes one unified file.

The default JSON report is `data/mqtt_generator_report.json`. `--check`
reports drift/missing files and exits `1`; `--force` overwrites generated files
with manual edits; `--apply-hand` adopts or updates `broker.toml` and the
channels (`channels.toml` or `channels.d/`). Payload templates remain
seed-only.

Examples:

```bash
# Generate tags and channels from devtools/tooling/generators/mqtt.toml
prism-devtools generate mqtt --root .

# Preview without writing
prism-devtools generate mqtt --root . --dry-run

# Fail when the files on disk are stale
prism-devtools generate mqtt --root . --check

# Adopt the existing hand-managed broker/channels/payloads
prism-devtools generate mqtt --root . --apply-hand

# Gate both generated and adopted files
prism-devtools generate mqtt --root . --apply-hand --check

# Use an explicit config
prism-devtools generate mqtt --root . --config generators/mqtt-site.toml
```

## `generate opc-client`

```bash
prism-devtools generate opc-client [--root <dir>] [--config <file>]
    [--dry-run|--check] [--force] [--report <file.json>]
    [--on-collision error|skip|rename] [--output-dir <dir>] [--apply-hand]
```

Reads the devices declared in `opc_client.toml` and writes:

- `config/02_northbound/04_opc_client/endpoints.toml`, or
  `endpoints.d/<device>.toml` with `[generator].layout = "split"`;
- `config/02_northbound/04_opc_client/defaults.toml` as a seed.

The default report is `data/opc_client_generator_report.json`.
`--output-file` is not supported by this generator and exits `2`.
`--apply-hand` adopts or updates an existing `defaults.toml` (`.bak` on first
adoption).

Examples:

```bash
prism-devtools generate opc-client --root .
prism-devtools generate opc-client --root . --check
prism-devtools generate opc-client --root . --apply-hand
```

## `generate opc-server`

```bash
prism-devtools generate opc-server [--root <dir>] [--config <file>]
    [--dry-run|--check] [--force] [--report <file.json>]
    [--on-collision error|skip|rename] [--output-dir <dir>] [--apply-hand]
```

Reads `opc_server.toml` and writes:

- `config/02_northbound/02_opc_server/nodes.toml`, or
  `nodes.d/<device>.toml` with `[generator].layout = "split"`;
- `config/02_northbound/02_opc_server/server.toml` as a seed.

The default report is `data/opc_server_generator_report.json`.
`--output-file` is not supported and exits `2`. `--apply-hand` adopts or
updates an existing `server.toml` (`.bak` on first adoption).

Read-only and read/write tags are exported; `wo` tags and tags without a
`data_type` are skipped with a warning because the server cannot serve them.

Examples:

```bash
prism-devtools generate opc-server --root .
prism-devtools generate opc-server --root . --dry-run
prism-devtools generate opc-server --root . --apply-hand --check
```

## `generate tags`

```bash
prism-devtools generate tags [--root <dir>] [--config <file>]
    [--dry-run|--check|--stdout] [--device <name>] [--dir <path>]
    [--file <name>] [--protocol modbus|s7comm|opc-client|virtual|wasm]
    [--name <pattern>] [--count <n>] [--address <base>] [--stride <n>]
    [--register <area>] [--type <data_type>] [--access ro|rw|wo]
    [--unit <text>] [--scale <f>] [--description <text>]
    [--mode full|delta|annotated] [--existing error|skip|overwrite]
    [--draft] [--report <file.json>] [--force]
```

`generate tags` writes southbound `[[device.tag]]` entries. A one-off batch
needs no generator config:

```bash
prism-devtools generate tags --device io_controller \
    --name 'pump_{i:02}_run' --count 4 --address 600 --stride 2 \
    --register coil --type bool --access rw
```

`--name` expands `{i}`, `{i:02}` and `{device}`. `--address` is the first
address; `--stride` is added for each following tag. `--count` is the number of
tags in the batch.

### Defaults

| Setting | Default |
|---|---|
| Target file | `10_tags.toml` inside the device directory. |
| `--count` | `1`. |
| `--stride` | `1`. |
| `--protocol` | `modbus`. |
| `--mode` | `annotated`. |
| `--existing` | `skip`. |
| Report | No report unless `[generator].report_path` is set or `--report` is passed. |

A `tags.toml` may override the mode, existing policy, protocol, file and count;
CLI flags win over the file. The defaults in the table apply to a one-off batch
without a config.

### Modes

| Mode | What is written |
|---|---|
| `full` | Every applicable key with its effective value. |
| `delta` | Only keys that differ from the protocol defaults. |
| `annotated` | `delta` plus inherited keys commented out with `# default` (default). |

### Existing tags

| `--existing` | Behavior |
|---|---|
| `skip` | Default. Tags already present anywhere in the device directory are skipped; missing tags are appended. Repeated runs are no-ops. |
| `error` | Stop with an error if a generated tag already exists. Exit code `2`. |
| `overwrite` | Rewrite the target file with the generated batch and keep a `.bak`. |

`--force` only changes the meaning of `--existing error`: it treats it as
`overwrite`. With the default `skip` it has no effect.

### Other options

- `--device <name>` sets the owning device and its directory. `--dir <path>`
  sets an explicit target directory and wins over `--device`. For a one-off
  batch, one of them is required; a config file can supply the device.
- `--file <name>` overrides the target file (default `10_tags.toml`).
- `--register`, `--type` (alias `--data-type`), `--access`, `--unit`,
  `--scale` and `--description` set tag keys. CLI values win over the config.
- `--check` writes nothing and exits `1` when tags from the spec are missing.
- `--stdout` prints the generated content instead of writing files and returns
  `0`.
- `--draft` writes `#<file>`; the runtime ignores that name until it is renamed.
- `--report <file.json>` writes a JSON summary on a normal generation run. It is
  skipped with `--check`, `--dry-run` and `--stdout`.

The generated file is hand-managed: after the first write the generator never
owns it and no drift guard is applied.

Examples:

```bash
# One batch, no config file
prism-devtools generate tags --device io_controller --name 'pump_{i:02}' \
    --count 4 --address 600 --stride 2 --register coil --type bool --access rw

# Use generators/tags.toml (or devtools/tooling/generators/tags.toml)
prism-devtools generate tags --root .

# Preview or gate a spec
prism-devtools generate tags --root . --dry-run
prism-devtools generate tags --root . --check

# Draft a file the runtime will ignore
prism-devtools generate tags --device io_controller --name flow --draft

# Print the generated block only
prism-devtools generate tags --device io_controller --name flow --stdout
```

## `init`

```bash
prism-devtools init [--project <name>] [--template empty|minimal|standard|full]
    [--out <dir>] [--repo <dir>]
```

| Preset | Content |
|---|---|
| `empty` | Canonical folder tree with commented examples; nothing active. |
| `minimal` | Data acquisition: Modbus TCP and MQTT telemetry. |
| `standard` | Closed-loop control: Modbus, compute block, Rhai and MQTT. Default. |
| `full` | Modbus, S7comm, compute, OPC UA, Rhai and MQTT. |

Options:

- `--project <name>` — project/instance name. Without it, a terminal runs the
  interactive wizard; a non-terminal stdin returns a usage error.
- `--template <preset>` — default `standard`.
- `--out <dir>` — target directory; default `projects/<name>`.
- `--repo <dir>` — folder containing `prism`/`prism.exe` for the convenience
  copy. The binary is looked up in that folder, `target/release` and
  `target/debug`. Without `--repo`, discovery is attempted only in a source
  tree.

The target must be absent or empty; a non-empty directory is rejected. On
success the project tree is written, including its `config/`, `scripts/`,
`devtools/simulator/sim.toml` and the generator templates in
`devtools/tooling/generators/`.

Examples:

```bash
prism-devtools init --project stand-01 --template standard
prism-devtools init --project demo --template minimal --out projects/demo
prism-devtools init --project site --template full --repo /opt/prism
```

Exit codes: `0` success, `1` scaffolding error, `2` usage error.

## `ml new`

```bash
prism-devtools ml new <name> [--root <dir>] [--force]
```

Creates a self-contained Rust ML plugin project and a matching module config:

```text
plugins/ml/<name>/
  Cargo.toml
  src/lib.rs
  wit/ml.wit
  README.md
  models/README.md
config/03_wasm/03_ml/<name>/<name>.toml
```

The project embeds the `prism:ml@0.1` WIT contract. The plugin name may use
ASCII letters, digits, `-` and `_`, must not start with `-`, and is limited to
64 characters.

`--force` replaces an existing project/config; no `.bak` is kept. Without it,
an existing project directory or config directory is an error.

Build with a Rust toolchain and the WASI target:

```bash
rustup target add wasm32-wasip2
cd plugins/ml/anomaly
cargo build --release --target wasm32-wasip2
```

Exit codes: `0` success, `1` scaffolding error, `2` usage error.

## `scaffold`

```bash
prism-devtools scaffold <device|tag|virtual-tag|alarm|history|script|poll|defaults> [args…]
```

`scaffold` creates one entity at the canonical path. Common flags are
`--root <dir>`, `--stdout`, `--draft` and, where supported, `--force`.

- `--stdout` prints the generated content instead of writing.
- `--draft` writes `#<file>`; the runtime ignores it until renamed.
- Existing files are not replaced silently. File writers return an error unless
  `--force` is passed; `--force` keeps a `.bak` for `device`, `alarm`, `script`
  and `defaults`.

| Entity | Positionals | Output | Key defaults | `--force` |
|---|---|---|---|---|
| `device` | `<name>` | `<protocol>/<name>/00_conn.toml` | Modbus TCP, `127.0.0.1:502`, unit id `1`; serial `COM1`, `9600`, `none`; S7 rack `0`, slot `1`; OPC endpoint `opc.tcp://127.0.0.1:4840/` | Overwrites with `.bak`. |
| `tag` | `<device> <name>` | `<protocol>/<device>/10_tags.toml` | Protocol `modbus`, mode `annotated`, existing tags skipped | Accepted but inert: the tag is still skipped under the default `skip`. |
| `virtual-tag` | `<device> <name>` | `04_virtual_tags/<device>/10_tags.toml` | Protocol forced to `virtual`, mode `annotated`, existing tags skipped | Accepted but inert under `skip`. |
| `alarm` | `<name>` | `05_alarms/NN_<slug>.toml` | Priority `warning`, `for_ms = 0`, `max = 100.0` when no limit is given | Overwrites with `.bak`. |
| `history` | `<tag>` | `06_history/history.toml` (append) | Depth `1000`, sample `100 ms` | Not accepted; `--force` is an unknown option. |
| `script` | `<name>` | `scripts/<name>.rhai` | Extra function `on_init`; `on_init`/`on_close` hooks included | Overwrites with `.bak`. |
| `poll` | `<name>` | `scripts/bindings.toml` (append) | Function `poll_<name>`, interval `1000 ms`, `run_on_start = true` | Accepted, but an existing `bindings.toml` is still appended to; no backup. |
| `defaults` | `<protocol>` | `<protocol>/defaults.toml` | Protocol defaults | Overwrites with `.bak`. |

### `scaffold device`

```bash
prism-devtools scaffold device <name>
    [--protocol modbus|s7comm|opc-client|virtual|wasm]
    [--transport tcp|rtu|ascii] [--ip <addr>] [--port <n>]
    [--unit-id <n>] [--serial-port <name>] [--baud <n>]
    [--parity none|even|odd] [--rack <n>] [--slot <n>]
    [--endpoint <url>] [--module <path>]
    [--dir <path>] [--file <name>] [--root <dir>]
    [--draft] [--stdout] [--force]
```

Writes the connection file `00_conn.toml` in the protocol/device directory.
`--protocol opc-client` selects the OPC UA client folder; `--endpoint` sets its
URL. `--module` is for a WASM device. `--dir` and `--file` override the target
directory and file name.

```bash
prism-devtools scaffold device io_controller
prism-devtools scaffold device plc --protocol s7comm --ip 10.0.0.20 --rack 0 --slot 1
prism-devtools scaffold device meter --protocol opc-client \
    --endpoint opc.tcp://10.0.0.7:4840/
```

### `scaffold tag` and `scaffold virtual-tag`

```bash
prism-devtools scaffold tag <device> <name>
    [--protocol <kind>] [--dir <path>] [--file <name>]
    [--address <n>] [--stride <n>] [--register <area>]
    [--type <data_type>] [--access ro|rw|wo] [--unit <text>]
    [--scale <f>] [--description <text>]
    [--mode full|delta|annotated]
    [--root <dir>] [--draft] [--stdout]

prism-devtools scaffold virtual-tag <device> <name>
    [--expression <rhai>] [--script-func <fn>] [--initial <f>]
    [--type <type>] [--access ro|rw|wo] [--unit <text>]
    [--dir <path>] [--file <name>] [--mode full|delta|annotated]
    [--root <dir>] [--draft] [--stdout]
```

Both commands write exactly one tag. They use the protocol `defaults.toml` and
the selected mode, but they do **not** read `generators/tags.toml` at all; use
`generate tags` for batches. Existing tags are skipped; `--force` does not
override that skip behavior.

```bash
prism-devtools scaffold tag io_controller level \
    --address 100 --register input --unit kPa
prism-devtools scaffold virtual-tag calc doubled \
    --expression 'read("io.level") * 2.0'
```

### `scaffold alarm`

```bash
prism-devtools scaffold alarm <name>
    [--tag <device.tag>] [--min <f>] [--max <f>]
    [--priority info|warning|critical|emergency]
    [--message <text>] [--for-ms <n>] [--hysteresis <f>]
    [--file <name>] [--root <dir>] [--draft] [--stdout] [--force]
```

The file is auto-numbered (`01_<name>.toml`, then the next free number) unless
`--file` is given. With no `--min`/`--max`, the limit defaults to `max = 100.0`.
The default source tag is `device.tag`, priority is `warning`, `for_ms` is `0`,
and the message is derived from the source tag.

```bash
prism-devtools scaffold alarm high_level --tag io.level --max 80
prism-devtools scaffold alarm filter_clogged --tag io.pressure --max 1800 \
    --priority critical --for-ms 5000
```

### `scaffold history`

```bash
prism-devtools scaffold history <tag>
    [--depth <n>] [--sample-ms <n>] [--root <dir>] [--draft] [--stdout]
```

Appends a `[[tag]]` block to
`config/01_southbound/06_history/history.toml`. Defaults are `depth = 1000` and
`sample_ms = 100`. There is no `--force` for this entity.

```bash
prism-devtools scaffold history io.level --depth 1000 --sample-ms 100
```

### `scaffold script` and `scaffold poll`

```bash
prism-devtools scaffold script <name>
    [--function <fn>] [--file <name>]
    [--root <dir>] [--draft] [--stdout] [--force]

prism-devtools scaffold poll <name>
    [--function <fn>] [--interval-ms <n>] [--file <name>]
    [--root <dir>] [--draft] [--stdout] [--force]
```

`script` writes `scripts/<name>.rhai` with `on_init` and `on_close` hooks; the
extra function stub defaults to `on_init`. `poll` appends a `[[poll]]` block to
`scripts/bindings.toml`; the function defaults to `poll_<name>` and the interval
to `1000 ms`. `run_on_start` is always written as `true`.

```bash
prism-devtools scaffold script interlocks
prism-devtools scaffold poll bms --interval-ms 2000 --file bms.rhai
```

### `scaffold defaults`

```bash
prism-devtools scaffold defaults <protocol>
    [--dir <path>] [--root <dir>] [--draft] [--stdout] [--force]
```

Writes the protocol `defaults.toml` and refuses to overwrite it without
`--force` (then keeps a `.bak`). `--dir` overrides the protocol directory.

```bash
prism-devtools scaffold defaults modbus
prism-devtools scaffold defaults opc-client --force
```

## `inventory update` and `inventory export`

### `inventory update`

```bash
prism-devtools inventory update [--root <dir>] [--out <file>]
```

Reads the current configuration and refreshes the tag ledger. The default
output is `<root>/data/tag_inventory.csv`.

The ledger is **not append-only**:

- rows for tags that still exist are refreshed in place and keep their `seq`
  and `batch`;
- new tags are appended with the next sequence numbers and a new `batch`;
- tags no longer present in the configuration are removed.

Each row names the single owner (`modbus:io_controller`, `virtual:stand`,
`alarm:<file>`) and its northbound exposures (`opcua:<node>`,
`mqtt:telemetry`, `mqtt:command`, `sparkplug`, `sql`).

Exit codes: `0` success, `1` write failure, `2` configuration load or usage
error.

```bash
prism-devtools inventory update --root .
prism-devtools inventory update --root . --out reports/tags.csv
```

### `inventory export`

```bash
prism-devtools inventory export [--root <dir>] [--file <master.csv>]
    [--out <file>] [--format csv|tsv|json]
    [--transport <kind>] [--direction <dir>] [--access ro|rw|wo]
    [--device <name>] [--match <glob>]
    [--delimiter comma|semicolon|tab] [--bom] [--crlf]
```

Reads the master ledger (default `<root>/data/tag_inventory.csv`) and writes a
filtered view. Without `--out`, the view is printed to stdout.

- `--transport` matches the owner transport or any northbound exposure.
- `--direction` accepts `southbound`, `northbound`, `both`, `internal` or
  `service`.
- `--match` is a glob over the full tag id.
- `--format` defaults to `csv`; `json` is intended for automation.
- `--delimiter` accepts `comma`, `semicolon`, `tab` or one character.
- `--bom` and `--crlf` are for Excel compatibility.

Exit codes: `0` success, `1` missing master file/render/write failure, `2` usage
error.

```bash
prism-devtools inventory export --root . --transport modbus --out reports/modbus.csv
prism-devtools inventory export --root . --format json --device io_controller
prism-devtools inventory export --root . --delimiter semicolon --bom --crlf
```

## `import inventory`

```bash
prism-devtools import inventory [--root <dir>] [--file <path>]
    [--format auto|toml|csv] [--batch <n>|--only-new]
    [--transport <kind>] [--device <name>] [--file-name <name>]
    [--dir <path>] [--protocol <kind>] [--mode full|delta|annotated]
    [--existing error|skip|overwrite] [--draft]
    [--dry-run|--check] [--report <file.json>]
```

Rebuilds southbound tag files from either:

- a TOML inventory with `[[tag]]` entries (`device`, `name`,
  `address`/`s7`/`node_id` and the usual tag keys);
- the master CSV ledger written by `inventory update`.

| Option | Behavior |
|---|---|
| `--file <path>` | Source file. Default: `data/tag_inventory.toml` when it exists, otherwise `data/tag_inventory.csv`. |
| `--format` | `auto` by extension, `toml` or `csv`. |
| `--batch <n>` | Import only that ledger batch. CSV only. |
| `--only-new` | Import only the newest ledger batch. CSV only; mutually exclusive with `--batch`. |
| `--transport <kind>` | Filter rows. CSV only. |
| `--device <name>` | Filter rows. CSV only. |
| `--file-name <name>` | Target TOML file inside each device directory; default `10_tags.toml`. |
| `--dir <path>` | Explicit target directory; requires `--device`. |
| `--protocol <kind>` | Force one protocol for every imported tag. |
| `--mode` | `full`, `delta` or `annotated`; default `delta`. |
| `--existing` | `error`, `skip` (default) or `overwrite`; duplicates are skipped by default. |
| `--draft` | Write `#<file>`: ignored by the runtime until renamed. |
| `--dry-run` | Print the result; write nothing. |
| `--check` | Write nothing; exit `1` when imported tags are missing. |
| `--report <file.json>` | Write a JSON summary. |

CSV rows reconstruct `register`/`address` from `location` (`holding:100`),
otherwise use `node_id`; report type names are normalized (`f32` → `float`,
`u16` → `word`, and the other integer aliases). The filtering flags apply only
to CSV input; TOML entries are imported as written.

Exit codes: `0` success, `1` `--check` finds missing tags, `2` source or target
error.

```bash
prism-devtools import inventory --root . --only-new
prism-devtools import inventory --root . --file data/tag_inventory.toml --dry-run
prism-devtools import inventory --root . --format csv --device io_controller \
    --file-name 20_imported.toml --check
```

## `trim mqtt`

```bash
prism-devtools trim mqtt [--root <dir>] [--apply] [--report <file.json>]
```

Scans the MQTT configuration and finds rules that reference tags absent from
the device configuration: `[[channel.field]]` (`for`/`from_tag`),
`[[telemetry_tag]]`, `[[command]]` and `[[telemetry_field]]`.

Without `--apply`, the command only reports. With `--apply`, it rewrites each
affected file and keeps a `.bak` copy. `--report` writes a JSON summary.

Exit codes: `0` clean or successfully applied, `1` stale rules found without
`--apply` (or no device tags found), `2` usage/scan error. When device tags
exist but the MQTT configuration directory is absent, the command exits `0`.

```bash
prism-devtools trim mqtt --root .
prism-devtools trim mqtt --root . --apply
prism-devtools trim mqtt --root . --report build/mqtt-trim.json
```

## `migrate layout`

```bash
prism-devtools migrate layout [--root <dir>] [--apply]
```

Prints a dry-run plan for moving legacy role folders and files to the canonical
numbered layout. With `--apply` it performs the moves. Existing canonical
targets are never overwritten: a conflict is reported and the legacy entry is
left in place. The command also moves `config/scripts/bindings.toml` to the
instance `scripts/` directory.

Exit codes: `0` success, `1` one or more conflicts, `2` usage error.

```bash
prism-devtools migrate layout --root .
prism-devtools migrate layout --root . --apply
```

## Scripting pattern

Use the check modes for repeatable gates:

```bash
prism-devtools validate rhai --root . --report build/rhai.json
prism-devtools generate mqtt --root . --check
prism-devtools generate opc-client --root . --check
prism-devtools generate opc-server --root . --check
prism-devtools generate tags --root . --check
prism-devtools import inventory --root . --only-new --check
prism-devtools trim mqtt --root .
```

Each of these returns `1` when the gate fails and `2` on a usage or
configuration error.
