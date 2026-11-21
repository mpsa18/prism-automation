# `prism-scan` — read-only field discovery and config generation

`prism-scan` discovers field devices and register maps before a project is
written. It speaks Modbus TCP, Modbus RTU/ASCII, S7comm and OPC UA itself, sends
only read requests, and can turn the result into ordinary Prism device modules.

A scan is one TOML plan (`scan.toml`). There are no subcommands and no
interactive menu: every run reads a plan, performs the discovery and register
rules it declares, prints a summary, and optionally writes configuration.

## Running

```sh
prism-scan                                  # use scan.toml found automatically
prism-scan --config scan.toml               # explicit plan
prism-scan --config plans/                  # every *.toml below the folder
prism-scan --config a.toml b.toml           # extra plans as positional arguments
prism-scan --config scan.toml --dry-run     # validate and print, no connections
prism-scan --config scan.toml --no-generate # scan only; leave config alone
prism-scan --init                           # write scan.toml next to the tool
prism-scan --init my-scan.toml --force      # overwrite a specific file
```

- There is no `discover` or `register` command. The plan itself declares both
  discovery scopes and register rules; one run executes discovery first, then
  every `[[register]]` rule in file order.
- In a scan run (without `--init`), every non-option argument is treated as
  another plan file, exactly like `--config <file>`.
- `--config` may be repeated. A directory expands to every `*.toml` file below
  it, recursively and sorted; hidden names (`.name`) and commented names
  (`#name`) are skipped.
- Several plans run in the given order. The first failing plan stops the run;
  each plan keeps its own output and report settings.

### How the plan file is found

Without `--config` or a positional plan, `prism-scan` tries, in order:

1. `scan.toml` next to the tool;
2. `scan.toml` in the current directory and each of its ancestors;
3. a fallback copy embedded when the tool was built (normally only present in a
   development build, not in a release install).

If no plan is found, the tool prints an error with the `--init` hint and exits
with code 2. It never creates a plan by itself; only `--init` writes one.

### Options

| Option | Meaning |
|---|---|
| `-c, --config <path>` | Plan file, or a folder of plans. Repeatable. |
| `--root <dir>` | Output root override for every plan. |
| `--report <file>` | JSON report path. Only valid with a single plan. |
| `--export-map <file>` | Write the discovered map as canonical CSV. Only valid with a single plan. |
| `-n, --dry-run` | Resolve and print the plan and scopes; open no connection. |
| `--no-generate` | Scan without generating config; a configured report is still written. |
| `--init [<file>]` | Write the commented plan template. Default: next to the tool. |
| `--force` | Allow `--init` to overwrite an existing file. |
| `-h, --help` | Print usage. |
| `-V, --version` | Print the version. |

`--init` accepts at most one file, given as a positional argument or with
`--config`, and uses it as the template destination. It creates missing parent
folders, refuses to replace an existing file without `--force` (exit 2), and
reports a write failure with exit 1. The template is a complete working
example: it scans `127.0.0.1:502` and writes into the discovered instance's
`config/01_southbound`, so review it before the first run.

`--report` is deliberately limited to one plan. When `--config` expands to more
than one plan, use `[output] report` inside each plan instead; otherwise the tool
rejects the run with exit 2.

`--dry-run` prints the resolved discovery scopes, register rules and the config
destination (or `config generation: disabled`), without probes, without a report
and without generated files. Because loading a plan validates it, a dry run is
also the quickest way to check a plan.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Success. Also used when discovery finds no devices and generation therefore writes nothing. |
| `1` | Report, import or generation error (cannot read/write, validation failed, serial-port conflict, certificate/key missing). |
| `2` | Usage or plan/config error (unknown option, missing value, no plan found, parse/validation failure, `--report`/`--export-map` with several plans, `--init` without `--force`). |

Probe failures do not fail the process: they are printed in the summary, counted,
and stored in the JSON report. Import rows that cannot be mapped are warnings; a
missing or unreadable import file is a run error. Only report/import/generation
errors and plan/usage errors change the exit code.

## Plan file

A plan has an optional `[scan]` section, one or more discovery blocks, optional
`[[register]]` rules and an optional `[output]` section. Unknown keys are an
error.

### `[scan]`

```toml
[scan]
name = "line-1"          # report title; default: plan file name without .toml
timeout_ms = 500         # network connect/read timeout, 1..60000
serial_timeout_ms = 200  # serial response timeout, 1..60000
inter_frame_ms = 20      # serial inter-frame gap, 0..10000
concurrency = 16         # parallel Modbus TCP / S7 probes, 1..256
dedupe_units = true      # collapse unit ids that answer as one device
```

All values are optional and use the defaults shown. `concurrency` is used for
Modbus TCP and S7 probes; OPC UA discovery runs sequentially.

`dedupe_units` applies to Modbus TCP discovery. Units on the same `host:port`
are treated as one device when they return the same non-empty FC43 identity
(vendor/product/revision), or — when neither unit reports an identity — the
same first successful read. The lowest unit id is kept and the device note
lists the aliases (`units 1-5 answered identically; kept unit 1`). Set it to
`false` for a gateway that really exposes several devices on one endpoint.

### Discovery blocks

At least one discovery block is required. Host scopes accept a single string or
an array of strings: single addresses, comma/space lists, ranges
(`192.168.1.10-20`) and CIDR (`192.168.1.0/24`). Ports and unit ids also accept
bare integers and ranges. Unit ids are `1..247`.

```toml
[[modbus_tcp]]
hosts = "127.0.0.1,192.168.1.10-20"
ports = "502,15020-15023"     # default 502
units = "1-16"                # default 1

[[modbus_serial]]
ports = "COM3,COM4"           # omit = every serial port detected by the OS
units = "1-8"
bauds = "9600,19200,38400,57600,115200"
parities = "none,even,odd"
stop_bits = "1,2"
framing = "auto"              # auto | rtu | ascii
probe_addresses = "0"         # add the first valid coil/register if the device
                              # ignores a read of address 0, e.g. "0,300,600"

[[s7]]
hosts = "192.168.0.10"
ports = "102"                 # default 102
rack_slots = "0/1,0/2,0/3,0/0"

[[opcua]]
hosts = "127.0.0.1"
ports = "4840"                # default 4840
```

Every host is probed on every port, and every unit id is tried on every
endpoint. Modbus TCP discovery reports the reachable function codes. Serial
discovery tries every baud/parity/stop-bit combination and warns when valid
frames appear only after byte inversion (RS-485 A/B swapped). S7 reports the CPU
identity through SZL when the PLC allows it. OPC UA reports the application
name, application URI and advertised endpoint profiles.

On Modbus TCP a unit is reported only after at least one successful read. A
unit that answers only with a Modbus exception (for example `illegal data
address`) is listed in the summary as a **suspect** and is not written to
config: an exception proves that a Modbus stack answered, not that the unit is
a distinct device. Inspect a suspect directly with `prism-dbg --modbus
<host:port> --unit <n> modbus read 3 0 1` before adding it to a plan.

Discovery is read-only: no coil, holding register or OPC UA node is written.

Serial discovery finds only the line settings and unit ids. Register/tag
enumeration over RTU/ASCII is done by the `[[register]]` rules below, reusing
the discovered settings when the port is opened. Enable both a
`[[modbus_serial]]` block and a matching `[[register]]` rule, otherwise the scan
reports devices but produces no tags.

## Importing a PLC map

When the PLC project is available, import its map instead of guessing. Modbus
has no register-map introspection, and S7comm exposes addresses but not
symbols; the engineering project is the source of truth for ranges and types.

```toml
[[import]]
path = "symbols.csv"       # relative to the plan
format = "step7"           # step7 | csv | json
hosts = "192.168.0.10"
rack_slots = "0/1"
verify = true              # read every imported address once
```

### STEP 7 / TIA Portal symbol tables

Upload the station in STEP 7 (or open the project in TIA Portal), export the
symbol table or PLC tag table as CSV, and use `format = "step7"`. The importer
accepts `MW10`, `MD20`, `M0.0`, `I0.0`/`E0.0`, `Q0.0`/`A0.0`, `PE`/`PA` and
`DBn.DBX/DBB/DBW/DBD` addresses, and maps `BOOL`, `WORD`, `DWORD`, `INT`,
`DINT`, `REAL`, `CHAR`, `STRING[n]` and one-dimensional
`ARRAY[lo..hi] of TYPE`. `BYTE`, timers, counters, `TIME`, `STRUCT`/`UDT` and
multi-dimensional arrays are skipped with a warning.

The symbol table of an uploaded program contains the symbols declared in it.
DB fields that are not declared as symbols need the DB source or a TIA
Openness export. An S7-1200/1500 *optimized* DB has no absolute address; the
importer reports such rows and skips them. Uncheck *Optimized block access*,
export through TIA Openness, or use an OPC UA server.

Multi-dimensional arrays, `STRUCT`/`UDT`, `BYTE`, timers/counters and `TIME`
values are not imported. The scanner does not parse LAD/SCL/STL sources: use
the symbol table, a TIA Openness export or a hand-maintained canonical
CSV/JSON for those cases.

### Canonical CSV and JSON

`format = "csv"` accepts these headers (case-insensitive; custom names via
`[import.columns]`):

```text
name,area,address,data_type,word_order,byte_order,byte_permutation,
byte_len,string_format,access,scale,offset,unit,description,db,bit,count
```

- `area` is `holding`/`input`/`coil`/`discrete` for Modbus and
  `db`/`mk`/`pe`/`pa` for S7.
- `offset` is the engineering offset, not the S7 byte address. The S7 byte
  offset is `address`; `db` and `bit` are separate columns.
- `count` expands a range into `name_0..name_N` (STEP 7 arrays keep the PLC
  index: `name_1..name_N`).
- `byte_permutation` preserves a non-standard 32-bit layout (`a,b,c,d`); it
  applies to Modbus `dword`/`dint`/`real` only.
- `scale`, `offset`, `unit` and `description` are written as the corresponding
  Prism tag fields.

`format = "json"` accepts an array or `{"signals": [...]}` with the same
fields. This is the easy output contract for a small TIA Openness helper.
`delimiter` (`comma`/`semicolon`/`tab` or one character) and `encoding`
(`auto`/`utf-8`/`utf-16`/`windows-1251`) are optional; auto-detection covers
normal Excel and STEP 7 exports.

### Precedence and device selection

Imports are applied before `[[register]]` rules. An imported tag wins by name
and by the same `area + address` (plus `db`/`bit` for S7), so a later register
scan cannot overwrite the explicit map. The block filters discovered devices by
`hosts`/`ports`/`units` (Modbus) or `hosts`/`ports`/`rack_slots` (S7). Exactly
one match is required; if none matches and the block names one endpoint, the
scanner creates a synthetic device, so an import-only plan works without a
network. `verify = true` reads every imported address once and prints failures;
it never writes to the PLC.

### Exporting the map

`prism-scan --export-map out.csv` writes the discovered map in the canonical
CSV form, one row per tag, with `device`, `protocol`, `host`, `port`, `unit_id`,
`rack`, `slot`, `node_id` and `namespace_uri` columns. Review and edit the
types/scales, then import the file back. The `device`/`host`/`port` columns are
ignored by the import block, which uses its own filters. OPC UA rows are
included in the export but import supports Modbus and S7 only; OPC UA rows are
skipped with a warning.

## Register rules

`[[register]]` rules run after discovery, in file order. A rule targets one
protocol and may filter the discovered devices by `hosts`, `ports`, `units`,
`rack_slots` or `serial_ports`. Without filters it applies to every discovered
device of that protocol. A rule that matches nothing prints a message and is
skipped. `units` applies to Modbus, `rack_slots` to S7 and `serial_ports` to
Modbus; a filter that does not apply to the chosen protocol is an error.

| Key | Default | Notes |
|---|---|---|
| `protocol` | required | `modbus`, `s7` or `opcua` |
| `hosts`, `ports`, `units`, `rack_slots` | none | Optional device filters |
| `serial_ports` | none | Modbus only; filters discovered RTU/ASCII port names |
| `areas` | `coil,discrete,holding,input` (Modbus), `db` (S7) | Modbus or S7 area list |
| `start` | `0` | First address, register, byte offset or DB offset |
| `end` | `9` (Modbus), `15` (S7) | Last address to probe |
| `step` | type width; `1` for bit-only areas | Must be > 0 |
| `data_type` | `word` | `word`, `int`, `dword`, `dint`, `real`, `string`, `auto`; `bool` on bit areas |
| `infer_order` | `false` | Keep the declared type, infer only the order |
| `infer_samples` | `12` | Sampling rounds, clamped to 2..200 |
| `infer_interval_ms` | `250` | Delay between rounds, clamped to 10..60000 |
| `infer_min_confidence` | `0.85` | Below this — or on an ambiguous order — the tag is not written; it is listed in a comment, clamped to 0.3..0.99 |
| `byte_len` | `32` | String payload bytes, 1..240 |
| `string_format` | `s7` | S7 strings: `s7` (2-byte header) or `raw` (CHAR array) |
| `byte_permutation` | none | Explicit 4-byte order; Modbus 32-bit types only |
| `db` | `1` | S7 data block number |
| `bit` | `0` | S7 bool bit, 0..7 |
| `depth` | `4` | OPC UA browse depth, 0..20 |
| `max_nodes` | `500` | OPC UA node cap, 1..5000 |

Address rules:

- `word`/`int` occupy one register, `dword`/`dint`/`real` two. On Modbus,
  strings occupy `ceil(byte_len/2)` registers; S7 uses byte offsets. Without an
  explicit `step`, the step is the value width in registers (Modbus) or bytes
  (S7), or 1 when every selected area is a bit area.
- `data_type = "auto"` discovers on the word grid: Modbus requires `step = 1`;
  S7 requires `step = 2`, even `start`/`end` byte offsets, and infers the type
  only (S7 is big-endian).
- `infer_order = true` is rejected for S7, because S7 values are big-endian by
  protocol.
- `byte_len` is only valid with `data_type = "string"`; `string_format` is only
  valid with an S7 string.
- `byte_permutation` must be a permutation of `[0, 1, 2, 3]`, only applies to
  Modbus `dword`/`dint`/`real`, and cannot be combined with `infer_order`.
- Modbus `data_type = "bool"` is only valid for bit-only areas
  (`coil`/`discrete`). S7 `bool` uses `bit = 0..7` and scans one bit per byte.
- OPC UA rules reject all address/data-type keys and use `depth` and
  `max_nodes`; only the `hosts`/`ports` device filters apply.

### Modbus

```toml
[[register]]
protocol = "modbus"
ports = "502"
units = "1"
areas = "coil,discrete,holding,input"
start = 0
end = 199
data_type = "word"
step = 1
```

A sampled rule:

```toml
[[register]]
protocol = "modbus"
areas = "holding,input"
start = 0
end = 199
data_type = "auto"        # discovers on the word grid (step = 1)
infer_samples = 12
infer_interval_ms = 250
infer_min_confidence = 0.85
```

Coil and discrete tags are always emitted as `data_type = "bool"`, regardless
of the declared type.

### Modbus RTU / ASCII

The same rule runs over the serial link; `serial_ports` filters by the port name
reported by discovery. Omit `serial_ports` to match every discovered Modbus
device (TCP and serial).

```toml
[[register]]
protocol = "modbus"
serial_ports = "COM3"
units = "2"
areas = "holding,input"
start = 0
end = 20
step = 1
data_type = "word"
```

### S7comm

```toml
[[register]]
protocol = "s7"
areas = "db"              # db | mk | pe | pa
db = 1
start = 0
end = 15
step = 2
data_type = "word"
# data_type = "bool"
# bit = 0                 # then one bit per byte
```

### OPC UA

```toml
[[register]]
protocol = "opcua"
depth = 4                 # browse depth under Objects
max_nodes = 500
```

The rule browses `Objects`, skips namespace 0, arrays and unsupported data
types, and creates `node_id` tags with the mapped data type and access level.

## How ranges are probed

Modbus and S7 use a block/bisect probe: a successful block read marks every
address in the block as present; an "illegal data address/value" answer splits
the block until the valid addresses are isolated. Unsupported functions are
noted and skipped. The scanner sends only read requests: Modbus FC1–4, S7
read-variable/SZL and OPC UA GetEndpoints/Browse/Read.

Modbus has no register-map introspection. Many servers answer every read —
including unmapped addresses — with success and zeros, and only `illegal data
address/value` proves that an address is unmapped. Treat the discovered range
as a hypothesis: confirm it against the PLC program, HMI tags or the device
documentation. A narrow range with an explicit `data_type` is more reliable
than a wide `auto` scan. When the project is available, import its map instead
(above): the block/bisect probe is a fallback, not an authoritative map.

## Type and order inference

`data_type = "auto"` switches a rule to a sampled scan. The range is first
discovered on the word grid, then each contiguous run is read once per round
(split into read-size batches), with `infer_interval_ms` between rounds. The
sampled values are decoded as `word`/`int`/`dword`/`dint`/`real`:

- Modbus tries **all 24 byte permutations** for 32-bit values.
- S7 tries only the big-endian layout and infers the type, not the order.

Scoring is conservative:

- `real` must be finite, in a plausible magnitude band, and must move. A
  constant never becomes `real`.
- A 32-bit integer pair needs a carry: the low word wraps while the high word
  grows.
- A 32-bit tag is formed only when the 32-bit interpretation scores at least
  `0.6` and the samples show a carry (integer) or a plausible moving f32. With
  carry evidence it can win even when its raw score is below the 16-bit
  candidate; otherwise it must be within `0.1` of the 16-bit score. Two
  independently changing words stay two 16-bit tags.
- `signed` (`int`/`dint`) is preferred only for values clustered near `0xFFFF`;
  otherwise `word`/`dword` is the safe default.
- Below `infer_min_confidence`, or when the order is ambiguous, the tag is not
  written to the generated TOML. The end of the device block lists its address,
  type and score; the JSON report still contains the tag with `verify = true`.
  Set `data_type` explicitly when the address is known from the PLC program.

For Modbus, the four conventional layouts are `ABCD`, `CDAB`, `BADC` and
`DCBA`. They are preferred on a score tie and are written as
`word_order`/`byte_order`. The other twenty layouts are written as
`byte_permutation = [..]` and only win when the evidence supports them.
Low-byte permutations of a moving f32 are often indistinguishable from a
conventional layout: the scanner picks the conventional one, lists the close
alternatives in the note and marks the tag `verify`.

Strings are detected before numeric segmentation: a run of at least 8 bytes with
90% printable ASCII, at least one letter and a NUL or space terminator becomes
`data_type = "string"` with the inferred `byte_len`. The detector looks at a
window of up to 32 bytes. Explicit strings are always available:

```toml
[[register]]
protocol = "modbus"
areas = "holding"
data_type = "string"
byte_len = 32
```

`byte_len` is the payload in bytes (default 32, maximum 240); the scanner reads
`ceil(byte_len/2)` registers. On S7, `string_format = "raw"` selects a CHAR
array without the 2-byte Siemens header; the default `s7` format includes it.

To keep a known type but let the scanner choose the order:

```toml
data_type = "real"
infer_order = true
```

For an explicit 32-bit order, name a permutation (this is mutually exclusive
with `infer_order`):

```toml
[[register]]
protocol = "modbus"
areas = "holding"
data_type = "real"
byte_permutation = [2, 3, 0, 1]   # CDAB
```

`byte_permutation` is Modbus-only, requires `dword`, `dint` or `real`, and
cannot be combined with `infer_order`.

## Generated tags

A sampled tag looks like this:

```toml
[[device.tag]]
name       = "holding_100"
address    = 100
register   = "holding"
data_type  = "real"
word_order = "le"
byte_order = "be"
access     = "ro"
# prism-scan: confidence 0.94, 12 sample(s)
# candidates: real/cdab 0.94, dword/cdab 0.31
```

Emitted keys:

- every Modbus and S7 tag carries `name`, `address`, `register`, `data_type`
  and `access = "ro"`; OPC UA tags carry `name`, `node_id`, optional
  `namespace_uri`, `data_type` and `access` instead of `address`/`register`;
- `byte_len` for strings, and `string_format` for S7 strings;
- `word_order`/`byte_order` for inferred conventional 32-bit layouts; the
  default `ABCD` layout writes no order key;
- `byte_permutation` for an inferred non-conventional layout or an explicitly
  configured one;
- coil/discrete tags are `data_type = "bool"`; S7 bool tags also carry `bit`
  inside `[device.tag.s7]`.
- imported tags also carry `description`, `unit`, `scale` and `offset`
  (engineering) when the map provides them.

Explicit rules do not sample values and write no `word_order`/`byte_order` keys;
they write `byte_permutation` only when it was configured explicitly. Only
sampled rules add the `# prism-scan:`/`# candidates:`/`# note:` comments.
Low-confidence tags are not written; the end of the device block lists them in
a `# prism-scan: N low-confidence tag(s) not written` comment.

## Output

```toml
[output]
generate = true          # false = scan only
module = "discovered"
file = "01_scan.toml"
# root = "out/01_southbound"   # optional: keep the module out of config/
# report = "scan-report.json"  # optional: JSON copy for automation
# opcua_certificate = "../data/pki/client/cert.pem"
# opcua_private_key = "../data/pki/client/key.pem"
```

| Key | Default | Meaning |
|---|---|---|
| `generate` | `true` | Write Prism config from the scan result. |
| `module` | `discovered` | Module folder and first device name. |
| `file` | `01_scan.toml` | File name inside the protocol folder; `.toml` is appended if omitted. |
| `root` | discovered instance | Output root, equivalent to `config/01_southbound`. |
| `report` | none | JSON report path. |
| `opcua_certificate`, `opcua_private_key` | none | Client certificate/key for secure-only OPC UA servers; set both together. |

### Where files are written

Without `root`, the scanner looks for an existing `config/01_southbound` in the
current directory and the tool directory, plus their ancestors. If none exists,
it uses `config/01_southbound` below the current directory. Each protocol group
gets one file:

```text
config/01_southbound/
  01_modbus/<module>/<file>.toml       # Modbus TCP + RTU + ASCII
  02_s7comm/<module>/<file>.toml       # S7comm
  03_opc_client/<module>/<file>.toml   # OPC UA clients + browsed node_id tags
```

All discovered devices of one protocol group are written as multiple
`[[device]]` blocks in the same file. Device names are `<module>`,
`<module>_2`, `<module>_3`, and so on.

When several Modbus TCP unit ids share one `host:port`, generation prints a
warning and adds the same warning as a comment in the file: Prism polls the
endpoint once per written device. Keep only the real unit, or use a gateway
that maps each unit to a different device. `dedupe_units` normally prevents
this before generation.

Set `root` only when the result should stay outside `config/` (for example a
review copy in `out/`). For `root = "out/01_southbound"` the first file is
`out/01_southbound/01_modbus/<module>/<file>.toml`. A relative `root`/`report`
inside `[output]` is resolved from the plan file's directory. The CLI overrides
`--root`, `--report` and `--export-map` are resolved from the current
directory. Relative
certificate/key paths are checked from the directory above the output root
(normally `config/`) and are written unchanged into the generated device.

If the target file already exists, it is replaced only after validation:
`prism-scan` writes the result to a temporary file, validates it with the Prism
config loader, then moves an existing target to `<file>.bak` and renames the
temporary file into place. Validation errors abort the write and leave the
existing file untouched. Warnings from the loader are printed.

A JSON report is written only when `report` or `--report <file>` is set (and not
in `--dry-run`). It contains the discovery time, duration, every discovered
device and tag, the probe errors, the exception-only suspects and the row-level
import warnings (including failed `verify` reads). The generated TOML module is
the primary result.

### Serial ports

Prism uses one device per serial port; separate pollers cannot share a COM
handle. If a Modbus RTU/ASCII scan finds several unit ids on the same port,
generation stops with an explicit error instead of writing a config that Prism
would reject. Scan one unit per port or use one adapter per unit.

### OPC UA security

The generated device uses the security of the endpoint chosen at discovery.
When the server offers an unsecured endpoint, the scanner selects `None/None`.
When only encrypted endpoints exist, it prefers `Basic256Sha256/SignAndEncrypt`
(and otherwise keeps the first advertised endpoint) and writes the certificate
and private-key paths from `[output]`. If either certificate or key is set,
both must be set (a plan error otherwise) and both files must exist (generation
is aborted otherwise). If neither is set, the encrypted device block is still
generated but has no certificate paths. Browsing a secure-only server may fail
until a trusted certificate is available; the device block is still produced.

### Before using the config

Review the generated addresses, types and scaling before starting the core.
Discovery tells you what exists; it cannot know the engineering units or the
valid operating range of a tag.

## Recipes

Scan a local line and write it into the instance:

```sh
prism-scan --config scan.toml
```

Review the same plan without touching the network or the config tree:

```sh
prism-scan --config scan.toml --dry-run
```

Keep a review copy outside `config/`:

```toml
[output]
generate = true
module = "review"
file = "01_line_scan.toml"
root = "out/01_southbound"
report = "out/scan-report.json"
```

Produce tags for an RTU/ASCII device: keep the `[[modbus_serial]]` discovery
block and add a `[[register]]` rule with `serial_ports = "COM3"` (or omit the
filter to match every discovered Modbus device).

Browse an OPC UA server: add an `[[opcua]]` discovery block and an OPC UA
`[[register]]` rule with the desired `depth` and `max_nodes`.
