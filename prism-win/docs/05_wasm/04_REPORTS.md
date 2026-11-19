# Declarative Excel Reports

Status: ABI `prism:report@0.1`, the Rust SDK (`crates/report-sdk`), the host
(`crates/report-host`), the XLSX renderer (`crates/report-plugin-xlsx`) and the
core runner (`config/03_wasm/04_report/<module>/`, `src/report/`) are ready.

A report is **declarative data + a sandboxed renderer**:

```text
config/03_wasm/04_report/<module>/*.toml
       │  button tag + tag templates + output path + layout
       ▼
[TagRegistry] ──snapshot()──► document JSON ──► report-host (WASM)
                                                      │ bytes
       <instance>/data/reports/*.xlsx ◄── host write ──┘
```

The core owns the data path: it reads the tags named in the config, decides
which measurement columns are present and assembles a neutral document. The
WASM plugin is a pure renderer: it has no tag, filesystem, network or clock
access, and its only import is `host.log`. This keeps reports configurable
without giving a plugin access to the whole tag registry.

The shipped example is
`instances/oil-fuel-stand/config/03_wasm/04_report/oil_protocol/01_report.toml`:
an oil-filter test protocol with particle counts, pressure delta and
efficiency.

## 1. Folder layout

Every subdirectory of `config/03_wasm/04_report/` is one module. All `*.toml`
files in it are parsed in file-name order and their `[[plugin]]`/`[[report]]`
entries are appended, so a module can contain several reports (and several
renderer artifacts). One report must be complete in a single file; to keep
files small, put each report in its own `.toml` file.
Names starting with `#` or `.` are ignored.

A missing directory is not an error. A module that fails to parse is logged
and skipped without hiding the others.

## 2. Config reference

### `[defaults]`

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `true` | Global switch; `false` starts no report workers. |
| `poll_ms` | `200` | Button poll period, ms (minimum 20). |

### `[[plugin]]`

| Key | Required | Meaning |
|---|---|---|
| `id` | yes | Identifier used by `[[report]].plugin`. |
| `path` | yes | `.wasm` path relative to `config/` (absolute paths allowed). |
| `enabled` | no | `false` disables the artifact without removing it. |
| `max_memory_mb` | no | Instance memory limit, default 64. |
| `fuel_per_call` | no | CPU fuel per render, default `2e9`; `0` = unlimited. |

The artifact is loaded once per report worker. The host checks
`get-info().abi == "0.1"` exactly.

### `[[report]]`

| Key | Required | Meaning |
|---|---|---|
| `name` | yes | Unique report name; also `{name}` in the file name. |
| `plugin` | yes | Renderer from `[[plugin]]`. |
| `enabled` | no | `false` disables the report. |
| `button_tag` | yes | Full trigger tag ID (`device.tag`). |
| `trigger_value` | no | Value that counts as a press, default `1.0`. |
| `interval_ms` | no | Periodic trigger in ms (counted from the previous attempt). |
| `reset_button` | no | Write `0` back after a generation attempt, default `false`. |
| `output_dir` | yes | Directory relative to `config/` or absolute. |
| `file_name` | yes | Template, see below; `.xlsx` is added when missing. |
| `on_exists` | no | `"suffix"` (default) or `"overwrite"`. |
| `title` | yes | Top row of the sheet. |
| `subtitle` | no | Second row, left. |
| `sheet_name` | no | Worksheet name, default `Protocol`. |
| `[report.columns]` | no | Measurement-column rules, see below. |
| `[[report.section]]` | yes | Document sections, see below. |

The trigger is a **rising edge**: the current value must be finite, good (or
uncertain) quality and equal to `trigger_value`, while the previous poll was
not. A button already pressed at startup does not fire; release it and press
again. With `reset_button = true` the host writes `0` through the normal write
queue after each attempt, so a momentary UI button works without extra logic.

`interval_ms` adds a **periodic** trigger for continuously running processes
(a digital twin in `prism-sim`, a long-running stand): the report is generated
every `interval_ms` counted from the previous attempt, independently of the
button edge. Both triggers share the same registry snapshot and file naming.

File-name placeholders:

| Placeholder | Replacement |
|---|---|
| `{date}` | Local date, `YYYY-MM-DD`. |
| `{time}` | Local time, `HH-MM-SS`. |
| `{datetime}` | `YYYY-MM-DD_HH-MM-SS`. |
| `{name}` | Report `name`, sanitized. |
| `{title}` | Report `title`, sanitized. |

Windows-forbidden characters (`<>:"/\|?*`) and control characters are
replaced with `_`; the file name cannot escape `output_dir`. With
`on_exists = "suffix"` a new file gets `_2`, `_3`, … instead of overwriting.

### `[report.columns]`

These rules decide which measurement numbers enter every matrix section.

| Key | Default | Meaning |
|---|---|---|
| `count_tag` | — | Tag with the selected count (e.g. `particle_select.oil_test_num`). |
| `count` | `1` | Fixed count when `count_tag` is absent or unreadable. |
| `max_columns` | `11` | Upper bound (hard limit 64). |
| `include` | `"completed"` | `"completed"`, `"count"` or `"all"`. |
| `status_before` | — | Status tag template for the "before" column. |
| `status_after` | — | Status tag template for the "after" column. |
| `before_label` | `Before` | Subcolumn header for before values. |
| `after_label` | `After` | Subcolumn header for after values. |
| `average` | `true` | Append an "Average" group. |
| `average_label` | `Average` | Average group header. |
| `label_template` | `Measurement {n}` | Measurement group header. |

`include` modes:

- `completed` — numbers `1..count` whose `status_before` and `status_after`
  both read exactly `1`. This is the normal mode for the oil stand: cancelled
  and unfinished columns are not printed. If the status templates are missing,
  the host logs a warning and falls back to `count`.
- `count` — every number `1..count`.
- `all` — every number `1..max_columns`.

If no column is selected in `completed` mode, the report is not generated
(the log explains why); the button is still reset.

### Sections

A matrix section is rows × measurements:

```toml
[[report.section]]
kind = "matrix"
title = "Fractional composition"   # optional
row_header = "Range"             # first column header

[[report.section.row]]
label = "2 µm"
before = "value_table.oil_before_2um_{n}"
after  = "value_table.oil_after_2um_{n}"
format = "int"

[[report.section.row]]
label = "Pressure drop"
value = "value_table.oil_pressure_delta_{n}"  # one cell per measurement
format = "float2"
```

- `before`/`after` produce two cells per selected measurement; `before` or
  `after` may be omitted (the cell stays blank).
- `value` produces one cell per measurement, merged across the group's
  before/after subcolumns. Use it for one-value rows such as pressure delta.
- `format` is `int`, `float0`, `float1`, `float2`, `float3`, `general`.
- `average = false` on a row disables its average cells (the average
  group itself remains).
- Only numeric tag values are printed; a missing tag or non-finite/bad-quality
  value becomes a blank cell.

A table section is rows × named value columns:

```toml
[[report.section]]
kind = "table"
title = "Efficiency (separation)"
row_header = "Metric"
headers = ["E, %"]

[[report.section.row]]
label = "2 µm"
tag = "value_table.oil_effectiveness_2"
format = "float1"
```

For multiple value columns use `headers = ["BEFORE", "AFTER"]` and a
`values = [{ tag = "...", format = "..." }, ...]` array. Table tags are not
expanded with `{n}`; they are global per report.

### `{n}` templates

`{n}` in `before`, `after`, `value`, `status_before`, `status_after` and
`label_template` is replaced with the measurement number. A template without
`{n}` is used as-is for every selected column.

This is the extension point for new metrics: add one `[[report.section.row]]`
with the tags already written by the instance. For example, flow and
temperature are present in the oil stand as `value_table.oil_flow_{n}` and
`value_table.oil_tank_temp_{n}` but are intentionally left commented out in the
shipped config.

## 3. The `prism:report@0.1` contract

Full WIT: `crates/report-wit/wit/report.wit`.

```wit
world report-plugin {
  import host;                       // host.log only
  export report;
}

interface report {
  get-info: func() -> plugin-info;
  render: func(document: string) -> result<list<u8>, string>;
}
```

The document is a JSON model (title, subtitle, timestamp, sections with
columns/rows/cells and number formats). The host builds it; the plugin only
lays it out and returns the file bytes. Host writes the file, so a renderer
cannot touch the filesystem.

## 4. Build and deploy a renderer

```sh
cargo build -p report-plugin-xlsx --target wasm32-wasip2 --profile wasm-plugin
cp target/wasm32-wasip2/wasm-plugin/report_plugin_xlsx.wasm \
   instances/oil-fuel-stand/plugins/report/report_plugin_xlsx.wasm
```

Config path relative to `config/`:

```toml
[[plugin]]
id = "xlsx"
path = "../plugins/report/report_plugin_xlsx.wasm"
```

The source of the shipped renderer is `crates/report-plugin-xlsx`; it is a
small OOXML writer with no external ZIP/Excel dependency, so it builds
offline and compiles natively for tests.

## 5. Operation and diagnostics

- Startup logs every configured report, its renderer, button tag and missing
  tags (`tag '...' is not registered (cell will be blank)`).
- Each generation logs the final path:
  `[report] 'oil_protocol': generated <instance>/data/reports/...`.
- A renderer error is logged with `generation failed`; the button is still
  reset (otherwise a failed attempt would look stuck).
- The tag snapshot is coherent (`TagRegistry::snapshot_ids`); under an
  extremely heavy write rate it may be best-effort and the log says so.

## 6. Limits

- XLSX only; the attached legacy `.xls` form is used as a layout reference,
  not as a template file.
- Charts, beta coefficients and other calculated series are not part of the
  engine; add them as rows/tables when the corresponding tags exist.
- Cells are numeric or blank; string values from tags are not supported in the
  current document model.
- The renderer runs on a dedicated report thread; a slow report never blocks
  device polling or control loops.
