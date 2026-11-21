# macOS Deployment Guide

## Overview
This manual covers deployment of the pre-compiled **Prism Industrial Gateway** on macOS (Apple Silicon and Intel). The binary follows the same **zero-install model** as on other platforms: a single self-contained executable with service integration built in.

---

## 1. Distribution Setup

Extract the distribution archive, then copy the platform instance into
`/opt/prism`:

```bash
# 1. Unpack the release next to the target directory
unzip prism-<version>-macos.zip -d /tmp/prism-release

# 2. Verify the bundle before installing
(cd /tmp/prism-release && shasum -a 256 -c SHA256SUMS)

# 3. Create the installation directory and copy the platform instance
sudo mkdir -p /opt/prism
sudo cp -a /tmp/prism-release/prism/. /opt/prism/

# 4. Keep the guides and the ready example (optional but recommended)
sudo cp -a /tmp/prism-release/docs /tmp/prism-release/examples /opt/prism/
sudo cp /tmp/prism-release/README-*.md /tmp/prism-release/LICENSE \
    /tmp/prism-release/THIRD_PARTY_NOTICES.md /opt/prism/

# 5. Strip Apple quarantine attributes (applied to downloaded archives)
sudo xattr -dr com.apple.quarantine /opt/prism/prism
```

---

## 2. Serial Communication Interface Naming

On macOS, USB-to-Serial adapters (FTDI, CP210x, CH340) expose two device prefixes in `/dev/`:
- `/dev/tty.*` — dial-in interface; **blocks** when the Carrier Detect (DCD) line is unasserted.
- `/dev/cu.*` — call-out interface; **recommended** for industrial automation.

Always configure `config/01_southbound/01_modbus/devices.toml` using the `cu.*` device:

```toml
port = "/dev/cu.usbserial-1410"
```

---

## 3. Service Lifecycle via Built-in Commands

Service management (launchd) is performed by the executable itself with `sudo`:

```bash
cd /opt/prism

# 1. Validate configuration
./prism --check-config

# 2. Register as a launchd system daemon (RunAtLoad + KeepAlive on crash)
sudo ./prism service install

# 3. Start / stop / status
sudo ./prism service start
sudo ./prism service status
sudo ./prism service stop

# 4. Full removal — unloads the daemon and deletes the plist
sudo ./prism service uninstall
```

What `service install` does internally:
1. Generates `/Library/LaunchDaemons/com.prism.core.plist` with absolute paths to the current binary.
2. Runs `launchctl load -w` to activate the daemon.

Logs of the daemonized process are written to `data/prism.stdout.log` and `data/prism.stderr.log` as configured in the generated plist.

---

## 4. Manual / Foreground Execution

For commissioning and debugging:

```bash
cd /opt/prism
./prism
```

The process discovers `config/`, `scripts/`, and `data/` relative to its own location.

---

## 5. Privileged Ports

macOS has no `setcap` equivalent. If a protocol server must bind to ports below 1024, either:
- Run the foreground process with `sudo` (discouraged for production), or
- Redirect the low port to a high port using the built-in `pfctl` firewall (e.g., external 502 → internal 8502), and point clients accordingly.
