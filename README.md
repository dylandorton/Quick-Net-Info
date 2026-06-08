# Quick-Net-Info

A PowerShell script that performs a comprehensive network connectivity and configuration test on Ethernet adapters, reporting results with color-coded pass/warn/fail status.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- Windows 10 2004+ (for LLDP/CDP capture via `pktmon`)
- Administrator privileges (required only for `-CaptureLLDP`)

## Usage

```powershell
# Test all connected Ethernet adapters
.\Quick-Net-Info.ps1

# Test a specific adapter
.\Quick-Net-Info.ps1 -AdapterName "Ethernet 2"

# Test with LLDP/CDP switch discovery (requires Admin)
.\Quick-Net-Info.ps1 -CaptureLLDP

# Custom ping targets and longer gateway timeout
.\Quick-Net-Info.ps1 -PingTargets "10.0.0.1","8.8.8.8" -GatewayTimeout 5

# Extend LLDP/CDP listen window for slow-interval switches
.\Quick-Net-Info.ps1 -CaptureLLDP -LLDPTimeout 60
```

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-AdapterName` | string | *(all adapters)* | Name of the adapter to test (e.g. `"Ethernet"`, `"Ethernet 2"`) |
| `-GatewayTimeout` | int | `2` | Seconds to wait for each ping |
| `-PingTargets` | string[] | `8.8.8.8, 1.1.1.1, 208.67.222.222` | Internet reachability targets; first responding address is used |
| `-LLDPTimeout` | int | `30` | Seconds to listen for LLDP/CDP frames (only applies with `-CaptureLLDP`) |
| `-CaptureLLDP` | switch | — | Enable active LLDP/CDP capture for switch port identification |

## What It Checks

| Section | Checks |
|---|---|
| **1. Link Detection** | Adapter name, MAC, link status, speed, duplex, RX/TX errors, 802.1X auth state |
| **2. TCP/IP Configuration** | IPv4/IPv6 addresses, gateway, DNS servers, suffix/search list, DHCP lease info, proxy |
| **3. VLAN** | Adapter-configured VLAN ID |
| **4. Switch Discovery** | LLDP/CDP passive capture via `pktmon` — switch name, port, and PVID |
| **5. Reachability** | Gateway ping, DNS resolution, internet ping + packet loss %, traceroute hop count, TCP port 443, captive portal detection |
| **6. System** | NTP source, stratum, last successful sync time |
| **7. Hardware-Only Tests** | Notes tests requiring dedicated hardware (PoE, TDR, port flash) |

## Notes

- LLDP/CDP capture uses `pktmon` (built into Windows 10 2004+). No third-party tools required. Must be run as Administrator.
- Standard switches broadcast LLDP every 30 seconds. Use `-LLDPTimeout 60` for slower intervals.
- Captive portal detection uses the Microsoft NCSI endpoint: `http://www.msftconnecttest.com/connecttest.txt`
- PoE voltage, cable TDR, and port flash tests require dedicated hardware and cannot be performed in software.
