# Legacy OPC DA Integration (Windows Satellite Bridge)

## Overview
Prism integrates with legacy Windows **OPC DA (Data Access 2.05a / 3.0)** servers through an isolated satellite service (`opc_da_bridge.exe`).

The satellite bridge runs exclusively on the Windows host running the legacy OPC DA server, converts COM/OLE data streams into standard **OPC UA**, and exposes a local secure endpoint (`opc.tcp://127.0.0.1:4840`). The cross-platform Prism Core connects to this endpoint using its standard, native OPC UA Client interface.

```mermaid
flowchart LR
    DA["Legacy OPC DA Server\n(Win32 COM/OLE)"] <-->|"Local COM VTable\n(No DCOM)"| Bridge["OPC DA Bridge\n(opc_da_bridge.exe)"]
    Bridge <-->|"OPC UA Protocol\n(opc.tcp://127.0.0.1:4840)"| Core["Prism Core\n(opc_client)"]
    Core <-->|"MQTT"| SCADA["PySide SCADA HMI"]
```

---

## 1. Architectural Highlights

- **Zero-DCOM Architecture:** The bridge service executes locally on the machine hosting the legacy OPC DA server. Network DCOM is entirely eliminated, removing RPC firewall blocks, authentication failures, and latency spikes.
- **Cross-Platform Core Safety:** On Linux or macOS installations, the `config/02_northbound/03_opc_da_bridge/` directory is automatically and safely ignored by the Prism Core runtime (the legacy `config/opc_da_bridge/` path is also resolved).
- **Licensing Compliance:** Tags declared in `config/02_northbound/03_opc_da_bridge/tags.toml` are counted toward the total active tag tally to enforce licensing tiers.

---

## 2. Configuration Specification

### 2.1. Server Connection: `config/02_northbound/03_opc_da_bridge/connection.toml`
Defines the target OPC DA server and the parameters of the local OPC UA server:

```toml
[opc_da]
prog_id = "Vendor.OPC.Server.1"   # Replace with the ProgID of your installed OPC DA server
# clsid = "{F8582CF2-88FB-11D0-B850-00C0F0104305}"   # optional fallback if the ProgID lookup fails
host = "localhost"
apartment_model = "MTA"           # MTA (Multi-Threaded) or STA (Single-Threaded)
update_rate_ms = 100              # Group poll rate
deadband_percent = 0.0
time_bias_minutes = 0             # Time bias relative to UTC (0 = UTC)
locale_id = 1033                  # 1033 = en-US, 1049 = ru-RU
keepalive_interval_ms = 2000
reconnect_backoff_initial_ms = 1000
reconnect_backoff_max_ms = 30000
shutdown_hook_enabled = true      # Auto-reconnect on IOPCShutdown

[opc_ua_server]
endpoint_url = "opc.tcp://127.0.0.1:4840/Prism/OPCDABridge"
server_name = "Prism Industrial OPC DA to UA Satellite Bridge"
namespace_uri = "urn:prism:industrial:opc-da-bridge"
security_policy = "None"
security_mode = "None"
max_connections = 4
max_subscriptions = 8
max_message_size_bytes = 4194304
publishing_interval_min_ms = 50

[buffers]
channel_capacity = 65536
write_queue_capacity = 4096
```

### 2.2. Tag Mapping: `config/02_northbound/03_opc_da_bridge/tags.toml`
Maps legacy OPC DA Item IDs to modern OPC UA NodeIds (illustrative example;
the file ships empty until tags are declared):

```toml
[[groups]]
name = "Stand"
update_rate_ms = 100
deadband = 0.0

  [[groups.tags]]
  item_id = "Stand.Hydraulics.Pressure_Feed"
  node_id = "ns=2;s=Bridge.Stand.Pressure_Feed"
  data_type = "Float"
  access_rights = "ReadOnly"

  [[groups.tags]]
  item_id = "Stand.Hydraulics.MainPump_Command"
  node_id = "ns=2;s=Bridge.Stand.MainPump_Command"
  data_type = "Boolean"
  access_rights = "ReadWrite"
```

### 2.3. Prism Core Integration: `config/02_northbound/02_opc_server/server.toml`
To consume data from the bridge, declare the bridge endpoint as an OPC UA
client device in the core device tree (`03_OPC_UA.md`, section 2):

```toml
[[device]]
name     = "opc_da_bridge_client"
protocol = "opcua"

[device.opcua]
endpoint        = "opc.tcp://127.0.0.1:4840/Prism/OPCDABridge"
application_uri = "urn:prism:client:opc_da_bridge"

[[device.tag]]
name      = "pressure_feed"
node_id   = "ns=2;s=Bridge.Stand.Pressure_Feed"
data_type = "real"
access    = "ro"

[[device.tag]]
name      = "main_pump_cmd"
node_id   = "ns=2;s=Bridge.Stand.MainPump_Command"
data_type = "bool"
access    = "rw"
```

---

## 3. Running and Monitoring

The system uses the standard zero-install model — no wrapper scripts required.

1. Validate configurations:
   ```cmd
   prism.exe --check-config
   ```
2. Run the core engine standalone (foreground):
   ```cmd
   prism.exe
   ```
3. Optional: register the gateway as an auto-restarting Windows service
   (Command Prompt / PowerShell **as Administrator**):
   ```cmd
   prism.exe service install
   prism.exe service start
   ```
4. Service management / full removal:
   ```cmd
   prism.exe service status
   prism.exe service stop
   prism.exe service uninstall
   ```
