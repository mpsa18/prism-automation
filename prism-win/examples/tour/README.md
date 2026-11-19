# Prism tour — a small project that shows every part of Prism

Unzip the release, open a terminal in this folder and run:

```sh
# Linux / macOS
./devtools/simulator/prism-sim        # keep this window open
./prism --check-config
./prism
./devtools/debugger/prism-dbg         # in a third terminal
```

```bat
:: Windows
devtools\simulator\prism-sim.exe
prism.exe --check-config
prism.exe
devtools\debugger\prism-dbg.exe
```

The example covers:

| Folder | What it demonstrates |
|---|---|
| `config/00_core/` | program identity, logging, debug API, license paths |
| `config/01_southbound/01_modbus/` | one Modbus TCP device with four tags (registers, scaling, read/write) |
| `config/01_southbound/04_virtual_tags/` | a calculated tag (Rhai expression) and a scratch-pad tag |
| `config/01_southbound/05_alarms/` | an alarm rule with a limit and hysteresis |
| `config/01_southbound/06_history/` | an in-memory history buffer for two tags |
| `config/02_northbound/01_mqtt/` | broker settings, channel contracts and JSON payload templates |
| `config/02_northbound/02_opc_server/` | Prism as an OPC UA server with three exported tags |
| `config/03_wasm/` | commented examples of compute, ML and report modules |
| `scripts/` | lifecycle hooks and a background poll loop in Rhai |
| `devtools/simulator/sim.toml` | the simulated PLC that replaces the real device |

Every file starts with a header explaining what it does and which values are
safe to change. The ports are loopback-only, so the tour runs without a network.

What to try:

1. In `prism-dbg`, find `tour_plc.temperature`; the simulator moves it towards
   `tour_plc.setpoint` (60 °C by default).
2. Write a new setpoint: `control set tour_plc.setpoint 75`.
3. Raise the temperature above 80 °C and watch `alarm.temperature_high` appear.
4. Point an MQTT client at `localhost:1883` and watch `prism/telemetry`.
5. Connect an OPC UA client to `opc.tcp://127.0.0.1:4840` and read
   `ns=2;s=tour_plc.temperature`.
