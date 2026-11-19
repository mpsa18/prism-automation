	# Linux Production Deployment Guide

## Overview
This operational manual provides step-by-step instructions for deploying and supervising the pre-compiled **Prism Industrial Gateway** on enterprise Linux systems (Debian, Ubuntu, RHEL, Rocky Linux, Alpine).

The binary follows a **zero-install model**: a single self-contained executable with no external runtime dependencies, no wrapper scripts, and no installer. All optional OS integration (service registration) is built into the binary itself.

---

## 1. Distribution Layout & Installation

Extract the distribution archive, then copy the platform instance from `prism/`
into the standard enterprise software directory `/opt/prism`:

```bash
# 1. Unpack the release next to the target directory
unzip prism-<version>-linux.zip -d /tmp/prism-release

# 2. Verify the bundle before installing
(cd /tmp/prism-release && sha256sum -c SHA256SUMS)

# 3. Create the installation directory and copy the platform instance
sudo mkdir -p /opt/prism
sudo cp -a /tmp/prism-release/prism/. /opt/prism/

# 4. Keep the guides and the ready example (optional but recommended)
sudo cp -a /tmp/prism-release/docs /tmp/prism-release/examples /opt/prism/
sudo cp /tmp/prism-release/README-*.md /tmp/prism-release/LICENSE \
    /tmp/prism-release/THIRD_PARTY_NOTICES.md /opt/prism/

# 5. Verify directory contents
ls /opt/prism
```

Expected directory tree:
```text
/opt/prism/
├── prism                           # Self-contained executable (statically linked)
├── config/                         # Production TOML configuration directory
├── scripts/                        # Operational Rhai scripts
├── devtools/                       # simulator, debugger, scanner, sniffer, tooling
├── data/                           # Logs, alarms, and persistent runtime state
├── udev/
│   └── 99-industrial-serial.rules  # Optional RS-485 persistence rules
├── docs/                           # Numbered user guides
├── examples/tour/                  # Complete project, runs without hardware
├── README-RU.md                    # Quick start (Russian)
├── README-EN.md                    # Quick start (English)
├── LICENSE                         # Prism Community edition license
└── THIRD_PARTY_NOTICES.md          # Third-party license texts
```

> **Note:** No `run.sh`, service manifests, or helper scripts are packaged — they are not required. The binary discovers `config/`, `scripts/`, and `data/` automatically relative to its own location.

---

## 2. Hardware Access Permissions

If the gateway runs in the foreground under a regular user (not as a system service), grant serial port access:

```bash
# Add runtime user to the serial group (dialout on Debian/Ubuntu, uucp on RHEL)
sudo usermod -aG dialout $USER
newgrp dialout
```

> When running via the built-in service commands (Section 4), the process runs as root by default; adjust the generated unit file `/etc/systemd/system/prism.service` if a restricted service account is required by your security policy.

---

## 3. Privileged Port Binding

If the gateway hosts server protocols on privileged ports (< 1024), such as standard Modbus TCP (port 502), grant the capability once:

```bash
sudo setcap 'cap_net_bind_service=+ep' /opt/prism/prism
```

> The capability flag survives reboots but is reset if the binary is replaced — re-apply after upgrades.

---

## 4. Service Lifecycle via Built-in Commands

All service management is performed by the executable itself. Commands require `sudo` (they write to `/etc/systemd/system/`).

```bash
cd /opt/prism

# 1. Validate configuration before going live
./prism --check-config

# 2. Register the gateway as an auto-starting systemd service
sudo ./prism service install

# 3. Start the service
sudo ./prism service start

# 4. Check operational status
sudo ./prism service status

# 5. Stop the service (graceful: systemd sends SIGTERM,
#    which triggers the built-in shutdown flush)
sudo ./prism service stop

# 6. Full removal — stops, disables, and deletes the unit file
sudo ./prism service uninstall
```

What `service install` does internally:
1. Generates `/etc/systemd/system/prism.service` with absolute paths to the current binary (`Restart=always`, `RestartSec=5`).
2. Runs `systemctl daemon-reload` and `systemctl enable prism.service`.

Because the gateway natively handles SIGTERM (graceful shutdown of device polling and `on_close` scripts), `systemctl restart` / `service stop` perform a clean stop without data loss.

---

## 5. Deterministic Serial Ports (Modbus RTU / RS-485 via udev)

USB-to-RS485 adapters may swap device node indices (`/dev/ttyUSB0` vs `/dev/ttyUSB1`) across reboots. Install the bundled rules to pin persistent symbolic links:

```bash
# 1. Inspect converter attributes (replace with your vendor/product IDs)
udevadm info -a -n /dev/ttyUSB0 | grep -E 'idVendor|idProduct'

# 2. Install and edit the rules accordingly
sudo cp /opt/prism/udev/99-industrial-serial.rules /etc/udev/rules.d/
sudo nano /etc/udev/rules.d/99-industrial-serial.rules

# 3. Reload udev subsystem
sudo udevadm control --reload-rules
sudo udevadm trigger
```

Then reference the persistent link (e.g., `/dev/tty_modbus_field`) in `config/01_southbound/01_modbus/devices.toml`.

An alternative that needs no udev rules and also works on Windows (where COM
numbers change after replug) is the USB descriptor matcher
`[device.serial.match]` (`usb_serial` / `vid` / `pid` / `product`), see
`02_communication/01_DEVICES.md`. The port is re-resolved on every connect:

```bash
# Which adapters are present and how the configured devices resolve to them
./prism serial list --config-dir /opt/prism/config
```

---

## 6. Firewall Configuration

Permit traffic strictly on ports defined by your active pipeline:

```bash
# UFW (Debian/Ubuntu)
sudo ufw allow 1883/tcp comment "MQTT broker"
sudo ufw allow 4840/tcp comment "OPC UA server"
sudo ufw allow 502/tcp  comment "Modbus TCP server"
sudo ufw reload

# FirewallD (RHEL/Rocky)
sudo firewall-cmd --permanent --add-port={1883,4840,502}/tcp
sudo firewall-cmd --reload
```

---

## 7. Troubleshooting

| Symptom | Diagnosis |
| :--- | :--- |
| `service install` fails with permission error | Run with `sudo`; deployment user must be root |
| Service starts, then restarts continuously | Run `./prism --check-config`; inspect logs with `journalctl -u prism -n 100` |
| Serial port permission denied (foreground mode) | User is not in `dialout`/`uucp` group (Section 2) |
| Ports below 1024 refuse to bind | Apply `setcap` (Section 3) |
