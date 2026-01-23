# macOS Hardening Utilities (PF Firewall + Services/Sharing Lockdown)

![image](https://github.com/user-attachments/assets/7f9ddf93-990a-4c70-a636-9cd4fffa2be9)


Two root-required utilities for macOS security hardening:

- **pfFW.sh** – Installs and manages a hardened Packet Filter (PF) firewall baseline using a dedicated PF anchor and a LaunchDaemon.
- **macSrvOff.sh** – Disables common macOS sharing services and network advertising features with automatic backups, logs, and rollback support.

These tools are intended for administrators and power users who want deterministic, scriptable macOS hardening without relying on third-party software.

---

## What is PF on macOS?

PF (Packet Filter) is the native BSD firewall built into macOS. It filters network traffic using rules defined in `/etc/pf.conf` and optional *anchors* (separate rule files).

Key concepts:
- Rules are evaluated top-to-bottom.
- PF is stateful by default (`keep state`).
- Anchors allow clean separation of custom rules from system configuration.
- PF is controlled using `pfctl`.

macOS ships with PF available but usually disabled unless explicitly configured.

---

## Repository Contents

- `pfFW.sh`  
  Hardened PF firewall installer/uninstaller.

- `macSrvOff.sh`  
  macOS services and sharing hardening tool (internally named `mac_harden_services.sh`).

---

## Requirements

- macOS 14 (Sonoma) or newer (15 supported)
- Administrator privileges
- `sudo` access
- Local Terminal access

---

## Quick Start

```bash
chmod +x pfFW.sh macSrvOff.sh

# Install hardened PF firewall
sudo ./pfFW.sh install

# Preview service hardening (dry-run)
sudo ./macSrvOff.sh plan --verify

# Apply service hardening
sudo ./macSrvOff.sh apply --verify
```

Rollback service changes:
```bash
sudo ./macSrvOff.sh rollback
```

Uninstall PF hardening:
```bash
sudo ./pfFW.sh uninstall
```

---

## Tool 1: PF Firewall Hardening (`pfFW.sh`)

### What It Does

On install, the script:

1. Creates a hardened PF anchor:
   - `/etc/pf.anchors/com.local.harden_pf`
2. Inserts a managed anchor block into `/etc/pf.conf`.
3. Validates all PF rules before loading.
4. Enables PF.
5. Installs a LaunchDaemon to ensure PF loads on boot:
   - `/Library/LaunchDaemons/com.local.harden_pf.plist`
6. Creates timestamped backups of `/etc/pf.conf`.

On uninstall, it cleanly removes all of the above and restores PF to its prior state.

### Installed Firewall Policy

- Default deny inbound traffic
- Stateful outbound traffic allowed
- Loopback traffic skipped
- DHCP allowed
- ICMP / ICMPv6 allowed (required for networking)
- QUIC (UDP/443) blocked to force TCP fallback

### Install

```bash
sudo ./pfFW.sh install
```

### Uninstall

```bash
sudo ./pfFW.sh uninstall
```

### Verify PF

```bash
sudo pfctl -s info
sudo pfctl -sr
sudo pfctl -sa
```

### Reset PF to Default

**Recommended reset:**

```bash
sudo ./pfFW.sh uninstall
sudo pfctl -d
```

**Restore from backup:**

```bash
ls /etc/pf.conf.bak.*
sudo cp /etc/pf.conf.bak.TIMESTAMP /etc/pf.conf
sudo pfctl -f /etc/pf.conf
```

### Customizing Rules

Edit the anchor directly:

```bash
sudo nano /etc/pf.anchors/com.local.harden_pf
sudo pfctl -n -f /etc/pf.anchors/com.local.harden_pf
sudo pfctl -f /etc/pf.conf
```

Do not edit the managed block in `/etc/pf.conf`.

---

## Tool 2: Services & Sharing Hardening (`macSrvOff.sh`)

### What It Does

Disables or reduces exposure of:

- AirDrop UI
- Handoff / Continuity advertising
- Printer sharing (CUPS)
- Remote Login (SSH)
- Remote Management (ARD)
- SMB, AFP, NetBIOS
- Internet Sharing
- Bluetooth PAN services
- AirPlay Receiver
- Multicast advertisements (mDNS)

All changes are logged and reversible.

### Modes

```bash
sudo ./macSrvOff.sh plan
sudo ./macSrvOff.sh apply
sudo ./macSrvOff.sh rollback
```

### Options

- `--verify` – Reads settings back and reports PASS/FAIL
- `--dry-run` – Log only, no changes
- `--no-sharing` – Skip service shutdowns
- `--id <backup_id>` – Roll back a specific run
- `--strict-os` – Fail if macOS version is unsupported

### Backups & Logs

- State: `/var/db/mac_harden_services/`
- Logs: `/var/log/mac_harden_services/mac_harden_services.log`
- Each run creates:
  - `CHANGELOG.txt`
  - `UNDO.sh`
  - `compatibility_report.tsv`

### Rollback

```bash
sudo ./macSrvOff.sh rollback
```

Rollback is best-effort and restores settings recorded at runtime.

---

## Operational Notes

- Always review `CHANGELOG.txt` before and after applying changes.
- Test on non-production machines first.
- These scripts are suitable for local admin use or integration into MDM workflows.

---

## Disclaimer

These scripts modify system configuration and services. Use only on systems you own or administer. No warranty is provided.
