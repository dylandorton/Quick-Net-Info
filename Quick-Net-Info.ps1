#Requires -Version 5.1
# Made by Dylan Dorton
# 06/04/2026
<#
.SYNOPSIS
    Performs a comprehensive network connectivity and configuration test on one or all Ethernet adapters.

.DESCRIPTION
    Runs the following checks and reports results with color-coded pass/warn/fail status:

    1. Link Detection
       - Adapter name, description, MAC address, link status, speed, duplex
       - RX/TX errors and discarded packets (flags bad cable or NIC)
       - 802.1X / Wired AutoConfig authentication state

    2. TCP/IP Configuration
       - IPv4 address, subnet mask, default gateway
       - IPv6 address and gateway
       - DNS servers, connection-specific suffix, global search list
       - DHCP status, server, and lease info
       - Proxy detection (reads current user registry settings)

    3. VLAN
       - Configured VLAN ID from adapter registry properties

    4. Switch Discovery (LLDP/CDP)
       - Passive capture via pktmon (requires -CaptureLLDP and admin rights)
       - Parses LLDP TLVs for switch name, port, and PVID (port VLAN ID)
       - Parses CDP frames for device ID and port ID
       - Default listen window: 30 seconds (one full broadcast cycle)

    5. Reachability
       - Gateway ping with RTT
       - DNS resolution test against configured DNS servers
       - Internet ping with RTT and packet loss % (5-ping sample)
       - Traceroute hop count to successful ping target
       - TCP port 443 (HTTPS) connectivity test
       - Captive portal detection via Microsoft NCSI endpoint

    6. System
       - NTP source, stratum, and last successful sync time

    7. Hardware-Only Tests (informational)
       - Notes tests that require dedicated hardware (PoE, TDR, port flash)

    Compatible with Windows PowerShell 5.1 and PowerShell 7+.

.PARAMETER AdapterName
    The name of the network adapter to test (e.g. "Ethernet", "Ethernet 2").
    If omitted, the script runs against all connected Ethernet adapters.

.PARAMETER GatewayTimeout
    Seconds to wait for each ping. Default: 2.

.PARAMETER PingTargets
    One or more IP addresses or hostnames for the internet reachability test.
    The first target that responds is used. Default: 8.8.8.8, 1.1.1.1, 208.67.222.222.

.PARAMETER LLDPTimeout
    Seconds to listen for LLDP/CDP frames when -CaptureLLDP is specified. Default: 30.
    Standard switches broadcast every 30 seconds; increase to 60 for slower intervals.

.PARAMETER CaptureLLDP
    Actively listen for LLDP and CDP frames to identify the connected switch and port.
    Requires Administrator privileges. Adds LLDPTimeout seconds to the run time.

.EXAMPLE
    .\Invoke-NetworkInfo.ps1
    Runs against all connected Ethernet adapters with default settings.

.EXAMPLE
    .\Invoke-NetworkInfo.ps1 -AdapterName "Ethernet 2" -CaptureLLDP
    Tests a specific adapter and captures LLDP/CDP for switch port identification.

.EXAMPLE
    .\Invoke-NetworkInfo.ps1 -PingTargets "10.0.0.1","8.8.8.8" -GatewayTimeout 5
    Uses custom ping targets and a longer timeout.

.EXAMPLE
    .\Invoke-NetworkInfo.ps1 -CaptureLLDP -LLDPTimeout 60
    Extends the LLDP/CDP listen window to 60 seconds for slow-interval switches.

.NOTES
    PoE voltage, cable TDR, and port flash tests require dedicated hardware and cannot be
    performed in software.

    LLDP/CDP capture uses pktmon (built into Windows 10 2004+). No third-party tools required.
    Must be run as Administrator for capture to work.

    Captive portal detection uses the Microsoft NCSI endpoint:
    http://www.msftconnecttest.com/connecttest.txt
#>
[CmdletBinding()]
param(
    [string]$AdapterName,
    [int]$GatewayTimeout = 2,
    [string[]]$PingTargets = @('8.8.8.8', '1.1.1.1', '208.67.222.222'),
    [int]$LLDPTimeout = 30,
    [switch]$CaptureLLDP
)

function Invoke-NetworkInfo {
    [CmdletBinding()]
    param(
        [string]$AdapterName,
        [int]$GatewayTimeout = 2,
        [string[]]$PingTargets = @('8.8.8.8', '1.1.1.1', '208.67.222.222'),
        [int]$LLDPTimeout = 30,
        [switch]$CaptureLLDP
    )

    #region ── Helpers ──────────────────────────────────────────────────────────
    function Write-Header ($text) {
        Write-Host "`n━━━ $text " -ForegroundColor Cyan -NoNewline
        Write-Host ("━" * [Math]::Max(0, 50 - $text.Length)) -ForegroundColor DarkCyan
    }

    function Write-Result ($label, $value, $status = 'OK') {
        $color = switch ($status) {
            'OK'      { 'Green'  }
            'WARN'    { 'Yellow' }
            'FAIL'    { 'Red'    }
            'INFO'    { 'Cyan'   }
            default   { 'White'  }
        }
        Write-Host ("  {0,-26}" -f "${label}:") -NoNewline -ForegroundColor DarkGray
        Write-Host $value -ForegroundColor $color
    }

    function Format-Speed ($speedBps) {
        if (-not $speedBps -or $speedBps -eq 0) { return "Unknown" }
        switch ($speedBps) {
            { $_ -ge 1e9 } { return "$([int]($_ / 1e9)) Gbps" }
            { $_ -ge 1e6 } { return "$([int]($_ / 1e6)) Mbps" }
            { $_ -ge 1e3 } { return "$([int]($_ / 1e3)) Kbps" }
            default         { return "$_ bps" }
        }
    }

    function Invoke-PingTest ($target, $count, $timeout) {
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            Test-Connection -ComputerName $target -Count $count -TimeoutSeconds $timeout -ErrorAction SilentlyContinue
        } else {
            Test-Connection -ComputerName $target -Count $count -ErrorAction SilentlyContinue
        }
    }

    function Get-PingRtt ($results) {
        if (-not $results) { return $null }
        $prop = if ($PSVersionTable.PSVersion.Major -ge 6) { 'Latency' } else { 'ResponseTime' }
        [int]($results.$prop | Measure-Object -Average).Average
    }
    #endregion

    $startTime = Get-Date
    Write-Host "`n  Network Information" -ForegroundColor White
    Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  |  Host: $env:COMPUTERNAME" -ForegroundColor DarkGray

    #region ── 1. Link Detection ─────────────────────────────────────────────────
    Write-Header "1. Link Detection"

    if ($AdapterName) {
        $adapter = Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue
    } else {
        $adapter = Get-NetAdapter |
            Where-Object {
                $_.Status -eq 'Up' -and
                $_.MediaType -match '802\.3' -and
                $_.PhysicalMediaType -notmatch 'Wireless|Native 802.11'
            } |
            Sort-Object Speed -Descending |
            Select-Object -First 1
    }

    if (-not $adapter) {
        Write-Result "Adapter" "No connected Ethernet adapter found." FAIL
        Write-Host "`n  [!] Connect an Ethernet cable and retry.`n" -ForegroundColor Red
        return
    }

    Write-Result "Adapter name"    $adapter.Name
    Write-Result "Description"     $adapter.InterfaceDescription
    Write-Result "MAC address"     $adapter.MacAddress
    Write-Result "Link status"     $adapter.Status $(if ($adapter.Status -eq 'Up') {'OK'} else {'FAIL'})

    $speedStr  = Format-Speed $adapter.Speed
    $linkSpeed = $adapter.Speed

    $duplex = 'Unknown'
    try {
        $adProp = Get-NetAdapterAdvancedProperty -Name $adapter.Name -ErrorAction Stop |
                  Where-Object { $_.RegistryKeyword -match 'SpeedDuplex|Speed_Duplex|LinkSpeed' } |
                  Select-Object -First 1
        if ($adProp) { $duplex = $adProp.DisplayValue }
    } catch {}
    if ($duplex -eq 'Unknown' -and $linkSpeed -ge 1e9) { $duplex = 'Full Duplex (inferred)' }

    $speedStatus = if ($linkSpeed -ge 1e9) { 'OK' } elseif ($linkSpeed -ge 1e8) { 'WARN' } else { 'FAIL' }
    Write-Result "Link speed"      $speedStr $speedStatus
    Write-Result "Duplex"          $duplex

    # Adapter error statistics
    $stats = Get-NetAdapterStatistics -Name $adapter.Name -ErrorAction SilentlyContinue
    if ($stats) {
        Write-Result "RX errors"     $stats.ReceivedPacketErrors     $(if ($stats.ReceivedPacketErrors   -eq 0) {'OK'} else {'WARN'})
        Write-Result "TX errors"     $stats.OutboundPacketErrors     $(if ($stats.OutboundPacketErrors   -eq 0) {'OK'} else {'WARN'})
        Write-Result "RX discards"   $stats.ReceivedDiscardedPackets $(if ($stats.ReceivedDiscardedPackets -eq 0) {'OK'} else {'WARN'})
    }

    # 802.1X / Wired AutoConfig status
    try {
        $dot3Output = netsh lan show interface name=`"$($adapter.Name)`" 2>$null
        if ($dot3Output) {
            $authLine = $dot3Output | Select-String 'Authentication|802\.1X|OneX' | Select-Object -First 1
            if ($authLine) {
                $parts = ($authLine -split ':\s+', 2)
                if ($parts.Count -eq 2) { Write-Result "802.1X" $parts[1].Trim() }
            } else {
                Write-Result "802.1X"        "Not configured"
            }
        }
    } catch {}
    #endregion

    #region ── 2. TCP/IP Configuration ───────────────────────────────────────────
    Write-Header "2. TCP/IP Configuration"

    $ipConfig  = Get-NetIPConfiguration -InterfaceAlias $adapter.Name -ErrorAction SilentlyContinue
    $ipAddress = ($ipConfig.IPv4Address | Select-Object -First 1)
    $gateway   = ($ipConfig.IPv4DefaultGateway | Select-Object -First 1)
    $prefixLen = $ipAddress.PrefixLength

    $subnetMask = if ($prefixLen) {
        # [Net.IPAddress](long) treats its argument as network byte order, which reverses
        # octets on little-endian Windows. Build the byte array directly to avoid this.
        $mask  = [uint32]([Math]::Pow(2,32) - [Math]::Pow(2, 32 - $prefixLen))
        $bytes = [BitConverter]::GetBytes($mask)
        [Array]::Reverse($bytes)
        $bytes -join '.'
    } else { 'N/A' }

    Write-Result "IPv4 address"    $(if ($ipAddress) { "$($ipAddress.IPAddress)/$prefixLen" } else { 'Not assigned' }) $(if ($ipAddress) {'OK'} else {'FAIL'})
    Write-Result "Subnet mask"     $subnetMask
    Write-Result "Default gateway" $(if ($gateway) { $gateway.NextHop } else { 'None' }) $(if ($gateway) {'OK'} else {'WARN'})

    # IPv6
    $ipv6Address = ($ipConfig.IPv6Address | Where-Object { $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -First 1)
    $ipv6Gateway = ($ipConfig.IPv6DefaultGateway | Select-Object -First 1)
    Write-Result "IPv6 address"    $(if ($ipv6Address) { "$($ipv6Address.IPAddress)/$($ipv6Address.PrefixLength)" } else { 'Not assigned' })
    if ($ipv6Gateway) { Write-Result "IPv6 gateway"   $ipv6Gateway.NextHop }

    # DNS
    $dnsServers = (Get-DnsClientServerAddress -InterfaceAlias $adapter.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
    Write-Result "DNS servers"     $(if ($dnsServers) { $dnsServers -join ', ' } else { 'None' }) $(if ($dnsServers) {'OK'} else {'WARN'})

    # DNS suffix / search list
    $dnsClient    = Get-DnsClient -InterfaceAlias $adapter.Name -ErrorAction SilentlyContinue
    $connSuffix   = $dnsClient.ConnectionSpecificSuffix
    $globalSearch = (Get-DnsClientGlobalSetting -ErrorAction SilentlyContinue).SuffixSearchList
    Write-Result "DNS suffix"      $(if ($connSuffix) { $connSuffix } else { 'None' })
    Write-Result "DNS search list" $(if ($globalSearch) { $globalSearch -join ', ' } else { 'None' })

    # DHCP
    $dhcpEnabled = $ipConfig.NetIPv4Interface.Dhcp -eq 'Enabled'
    Write-Result "DHCP"            $(if ($dhcpEnabled) { 'Enabled' } else { 'Disabled (static)' })

    if ($dhcpEnabled) {
        # Read DHCP server from the per-adapter CIM record — this is the server that issued
        # the lease, not an AD-wide list. Get-DhcpServerInDC was removed: it queries Active
        # Directory for all registered DHCP servers and has no relation to this adapter's lease.
        # The ipconfig /all fallback was also removed: it matched the first "DHCP Server" line
        # across all adapters rather than filtering to $adapter.Name.
        $dhcpServer = $null
        try {
            $nic = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration `
                       -Filter "InterfaceIndex=$($adapter.ifIndex)" -ErrorAction Stop
            if ($nic.DHCPServer -and $nic.DHCPServer -ne '255.255.255.255') {
                $dhcpServer = $nic.DHCPServer
            }
        } catch {}
        Write-Result "DHCP server"    $(if ($dhcpServer) { $dhcpServer } else { 'Not detected' })

        $leaseInfo = netsh interface ip show address name=`"$($adapter.Name)`" 2>$null |
                     Select-String "Lease (Obtained|Expires)"
        if ($leaseInfo) {
            $leaseInfo | ForEach-Object {
                $parts = ($_ -split ':\s+', 2)
                if ($parts.Count -eq 2) { Write-Result $parts[0].Trim() $parts[1].Trim() }
            }
        }
    }

    # Proxy detection
    try {
        $proxyReg = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        if ($proxyReg.ProxyEnable -eq 1 -and $proxyReg.ProxyServer) {
            Write-Result "Proxy"          $proxyReg.ProxyServer WARN
        } else {
            Write-Result "Proxy"          "Not configured" OK
        }
    } catch {
        Write-Result "Proxy"              "Unable to read" INFO
    }
    #endregion

    #region ── 3. VLAN ───────────────────────────────────────────────────────────
    Write-Header "3. VLAN"

    $vlanId = $null
    try {
        $vlanProp = Get-NetAdapterAdvancedProperty -Name $adapter.Name -ErrorAction Stop |
                    Where-Object { $_.RegistryKeyword -match 'VLAN|VlanID' }
        if ($vlanProp) { $vlanId = $vlanProp.RegistryValue }
    } catch {}

    Write-Result "VLAN ID"         $(if ($vlanId -and $vlanId -ne 0) { $vlanId } else { 'Not configured (access port or trunk)' })
    Write-Result "Note"            "Shows adapter-configured VLAN only. Switch-assigned VLAN appears in section 4 via -CaptureLLDP" INFO
    #endregion

    #region ── 4. Switch Discovery (LLDP/CDP) ────────────────────────────────────
    Write-Header "4. Switch Discovery (LLDP/CDP)"

    $lldpSwitch = $null; $lldpPort = $null; $lldpVlan = $null
    $cdpSwitch  = $null; $cdpPort  = $null

    if ($CaptureLLDP) {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)

        if (-not $isAdmin) {
            Write-Result "LLDP/CDP capture" "Skipped — requires Administrator" WARN
        } else {
            Write-Host "  Listening for LLDP/CDP frames for $LLDPTimeout seconds..." -ForegroundColor DarkGray
            $pktmonAvail = Get-Command pktmon -ErrorAction SilentlyContinue

            if ($pktmonAvail) {
                $etlFile  = "$env:TEMP\netinfo_capture.etl"
                $pcapFile = "$env:TEMP\netinfo_capture.pcapng"
                Remove-Item $etlFile,$pcapFile -ErrorAction SilentlyContinue

                try {
                    $f1 = pktmon filter add -e 0x88cc 2>&1
                    $f2 = pktmon filter add -m 01-00-0C-CC-CC-CC 2>&1
                    Write-Result "LLDP filter"   $(if ($f1 -match 'added') {'Added'} else {'Failed'}) $(if ($f1 -match 'added') {'OK'} else {'WARN'})
                    Write-Result "CDP filter"    $(if ($f2 -match 'added') {'Added'} else {'Failed'}) $(if ($f2 -match 'added') {'OK'} else {'WARN'})

                    $null = pktmon start --capture --pkt-size 512 -f $etlFile 2>&1
                    Start-Sleep -Seconds $LLDPTimeout
                    $stopOut    = pktmon stop 2>&1
                    $null       = pktmon filter remove 2>&1
                    $pcapOut    = pktmon pcapng $etlFile -o $pcapFile 2>&1

                    $pktTotal   = ($pcapOut | Select-String 'Packets total')     -replace '.*:\s*',''
                    $pktDropped = ($pcapOut | Select-String 'Packet drop count') -replace '.*:\s*',''
                    $eventsLost = $stopOut -match 'events lost'
                    if ($pktTotal)   { Write-Result "Packets captured" $pktTotal.Trim() }
                    if ($pktDropped) { Write-Result "Packets dropped"  $pktDropped.Trim() $(if ([int]($pktDropped.Trim() -replace '\D','') -eq 0) {'OK'} else {'WARN'}) }
                    if ($eventsLost) { Write-Result "Capture quality"  "Events lost — increase buffer or shorten capture" WARN }
                    else             { Write-Result "Capture quality"  "No events lost" OK }

                    if (Test-Path $pcapFile) {
                        $bytes = [IO.File]::ReadAllBytes($pcapFile)
                        $hex   = ($bytes | ForEach-Object { '{0:X2}' -f $_ }) -join ''

                        # LLDP: dst MAC 01:80:C2:00:00:0E, EtherType 88CC
                        $lldpIdx = $hex.IndexOf('0180C200000E')
                        if ($lldpIdx -ge 0) {
                            $pos = $lldpIdx + 28   # skip dst(12)+src(12)+etype(4)
                            while ($pos + 4 -le $hex.Length) {
                                $tlvHeader = [Convert]::ToUInt16($hex.Substring($pos, 4), 16)
                                $tlvType   = ($tlvHeader -shr 9) -band 0x7F
                                $tlvLen    = $tlvHeader -band 0x01FF
                                $valueHex  = $hex.Substring($pos + 4, [Math]::Min($tlvLen * 2, $hex.Length - $pos - 4))
                                $valueStr  = for ($i = 0; $i -lt $valueHex.Length; $i += 2) {
                                    [char][Convert]::ToByte($valueHex.Substring($i, 2), 16)
                                }
                                $valueStr = -join $valueStr
                                switch ($tlvType) {
                                    2   {
                                        # Port ID TLV value begins with a mandatory 1-byte subtype
                                        # (IEEE 802.1AB). Skip it explicitly (2 hex chars) rather than
                                        # relying on the printable-ASCII regex — the regex works by
                                        # accident for ASCII subtypes (0x05, 0x07) but drops binary
                                        # content for subtype 3 (MAC address), yielding empty output.
                                        $portHex = if ($valueHex.Length -gt 2) { $valueHex.Substring(2) } else { '' }
                                        $portStr = for ($j = 0; $j -lt $portHex.Length; $j += 2) {
                                            [char][Convert]::ToByte($portHex.Substring($j, 2), 16)
                                        }
                                        $lldpPort = (-join $portStr) -replace '[^\x20-\x7E]',''
                                    }
                                    4   { $lldpPort   = $valueStr -replace '[^\x20-\x7E]','' }  # Port Description (no subtype byte)
                                    5   { $lldpSwitch = $valueStr -replace '[^\x20-\x7E]','' }  # System Name
                                    127 {
                                        # Organizationally Specific: OUI(3B) + subtype(1B) + data
                                        # IEEE 802.1 OUI=0080C2, subtype 0x01 = Port VLAN ID
                                        if ($valueHex.Length -ge 12 -and $valueHex.Substring(0,6) -eq '0080C2' -and
                                            [Convert]::ToByte($valueHex.Substring(6,2),16) -eq 0x01) {
                                            $lldpVlan = [Convert]::ToUInt16($valueHex.Substring(8,4),16)
                                        }
                                    }
                                }
                                $pos += 4 + ($tlvLen * 2)
                                # 'break' inside a switch exits the switch, not this while loop.
                                # The loop termination lives here so it cannot be bypassed.
                                if ($tlvType -eq 0) { break }
                            }
                        }

                        # CDP: dst MAC 01:00:0C:CC:CC:CC, LLC/SNAP header, then ver+ttl+cksum+TLVs
                        # offset from dst MAC: dst(12)+src(12)+802.3len(4)+LLC(6)+OUI(6)+PID(4)+ver(2)+ttl(2)+cksum(4) = 52
                        $cdpIdx = $hex.IndexOf('01000CCCCCCC')
                        if ($cdpIdx -ge 0) {
                            $pos = $cdpIdx + 52
                            while ($pos + 8 -le $hex.Length) {
                                $cdpType = [Convert]::ToUInt16($hex.Substring($pos, 4), 16)
                                $cdpLen  = [Convert]::ToUInt16($hex.Substring($pos + 4, 4), 16)
                                if ($cdpLen -lt 4) { break }
                                $valHex = $hex.Substring($pos + 8, [Math]::Min(($cdpLen - 4) * 2, $hex.Length - $pos - 8))
                                $valStr = for ($i = 0; $i -lt $valHex.Length; $i += 2) {
                                    [char][Convert]::ToByte($valHex.Substring($i, 2), 16)
                                }
                                $valStr = -join $valStr
                                switch ($cdpType) {
                                    0x0001 { $cdpSwitch = $valStr -replace '[^\x20-\x7E]','' }  # Device ID
                                    0x0003 { $cdpPort   = $valStr -replace '[^\x20-\x7E]','' }  # Port ID
                                }
                                $pos += 8 + ($cdpLen - 4) * 2
                                if ($cdpType -eq 0) { break }
                            }
                        }

                        Remove-Item $etlFile,$pcapFile -ErrorAction SilentlyContinue
                    }
                } catch {
                    $null = pktmon stop 2>&1; $null = pktmon filter remove 2>&1
                    Write-Result "LLDP/CDP capture" "Capture failed: $($_.Exception.Message)" FAIL
                }
            } else {
                Write-Result "LLDP/CDP capture" "pktmon not available on this OS version" WARN
            }

            if ($lldpSwitch) {
                Write-Result "LLDP switch"    $lldpSwitch OK
                Write-Result "LLDP port"      $(if ($lldpPort) { $lldpPort } else { 'N/A' }) OK
                Write-Result "VLAN (LLDP)"    $(if ($lldpVlan) { $lldpVlan } else { 'Not advertised' })
            } else {
                Write-Result "LLDP result"    "No LLDP frames received" WARN
            }

            if ($cdpSwitch) {
                Write-Result "CDP switch"     $cdpSwitch OK
                Write-Result "CDP port"       $(if ($cdpPort) { $cdpPort } else { 'N/A' }) OK
            } else {
                Write-Result "CDP result"     "No CDP frames received" WARN
            }

            if (-not $lldpSwitch -and -not $cdpSwitch) {
                Write-Result "Tip" "Switch may not support LLDP/CDP, or is unmanaged" INFO
            }
        }
    } else {
        $lldpService = Get-Service -Name mslldp -ErrorAction SilentlyContinue
        if ($lldpService) { Write-Result "LLDP service" $lldpService.Status }
        Write-Result "Switch info"    "Use -CaptureLLDP switch for active LLDP/CDP discovery"
    }
    #endregion

    #region ── 5. Reachability ───────────────────────────────────────────────────
    Write-Header "5. Reachability"

    # Gateway ping
    if ($gateway) {
        $gwPing = Invoke-PingTest $gateway.NextHop 2 $GatewayTimeout
        $gwRtt  = if ($gwPing) { "$(Get-PingRtt $gwPing) ms" } else { 'Timeout' }
        Write-Result "Gateway ping"    $gwRtt $(if ($gwPing) {'OK'} else {'FAIL'})
    } else {
        Write-Result "Gateway ping"    "No gateway configured" WARN
    }

    # DNS resolution
    $dnsResolved = $false
    if ($dnsServers) {
        try {
            $dnsResult   = Resolve-DnsName -Name "www.google.com" -Server ($dnsServers | Select-Object -First 1) -Type A -ErrorAction Stop
            $dnsResolved = $true
            Write-Result "DNS resolution"  "OK (www.google.com → $($dnsResult.IPAddress | Select-Object -First 1))" OK
        } catch {
            Write-Result "DNS resolution"  "Failed" FAIL
        }
    } else {
        Write-Result "DNS resolution"  "No DNS servers configured" WARN
    }

    # Internet ping with packet loss
    $pingCount     = 5
    $internetOK    = $false
    $successTarget = $null
    foreach ($target in $PingTargets) {
        $pings = Invoke-PingTest $target $pingCount $GatewayTimeout
        # PS7 returns TimedOut-status objects instead of null for unreachable hosts;
        # filter to only successful replies so $rcv and RTT are never inflated by timeouts.
        $succeeded = if ($PSVersionTable.PSVersion.Major -ge 6) {
            @($pings | Where-Object { $_.Status -eq 'Success' })
        } else {
            @($pings)
        }
        if ($succeeded.Count -gt 0) {
            $rcv        = $succeeded.Count
            $loss       = [int](($pingCount - $rcv) / $pingCount * 100)
            $lossStatus = if ($loss -eq 0) {'OK'} elseif ($loss -le 20) {'WARN'} else {'FAIL'}
            Write-Result "Internet ($target)"  "$(Get-PingRtt $succeeded) ms" OK
            Write-Result "Packet loss"         "$loss%" $lossStatus
            $internetOK    = $true
            $successTarget = $target
            break
        }
    }
    if (-not $internetOK) {
        Write-Result "Internet ping"   "No response from $($PingTargets -join ', ')" FAIL
    }

    # Traceroute hop count
    if ($internetOK -and $successTarget) {
        try {
            $trace    = Test-NetConnection -ComputerName $successTarget -TraceRoute -WarningAction SilentlyContinue -ErrorAction Stop
            $hopCount = ($trace.TraceRoute | Where-Object { $_ -and $_ -ne '0.0.0.0' }).Count
            Write-Result "Hops to target"  $hopCount $(if ($hopCount -le 15) {'OK'} elseif ($hopCount -le 25) {'WARN'} else {'FAIL'})
        } catch {
            Write-Result "Traceroute"      "Failed" WARN
        }
    }

    # TCP/HTTPS
    try {
        $tcpTest = Test-NetConnection -ComputerName "www.google.com" -Port 443 -WarningAction SilentlyContinue -ErrorAction Stop
        Write-Result "TCP/HTTPS (443)"   $(if ($tcpTest.TcpTestSucceeded) { 'Open' } else { 'Blocked/Failed' }) $(if ($tcpTest.TcpTestSucceeded) {'OK'} else {'WARN'})
    } catch {
        Write-Result "TCP/HTTPS (443)"   "Test failed" WARN
    }

    # Captive portal (Microsoft NCSI endpoint)
    try {
        $ncsi = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        if ($ncsi.Content -match 'Microsoft Connect Test') {
            Write-Result "Captive portal"  "Not detected" OK
        } else {
            Write-Result "Captive portal"  "Detected — traffic is being intercepted" WARN
        }
    } catch {
        Write-Result "Captive portal"      "Check failed" WARN
    }
    #endregion

    #region ── 6. System ─────────────────────────────────────────────────────────
    Write-Header "6. System"

    # NTP / time sync
    try {
        $w32tmLines = w32tm /query /status 2>$null
        if ($w32tmLines) {
            foreach ($line in $w32tmLines) {
                if      ($line -match '^Source:\s+(.+)')                    { Write-Result "NTP source"     $Matches[1].Trim() $(if ($Matches[1] -notmatch 'Local CMOS|Free-running') {'OK'} else {'WARN'}) }
                elseif  ($line -match '^Stratum:\s+(.+)')                   { Write-Result "NTP stratum"    $Matches[1].Trim() }
                elseif  ($line -match '^Last Successful Sync Time:\s+(.+)') { Write-Result "Last time sync" $Matches[1].Trim() }
            }
        } else {
            Write-Result "NTP status"      "w32tm not available" WARN
        }
    } catch {
        Write-Result "NTP status"          "Query failed" WARN
    }
    #endregion

    #region ── 7. Hardware-Only Tests ────────────────────────────────────────────
    Write-Header "7. Hardware-Only Tests (not available in software)"

    Write-Result "PoE voltage"       "Requires dedicated hardware tester" WARN
    Write-Result "Cable TDR test"    "Requires dedicated hardware tester" WARN
    Write-Result "Flash switch port" "Requires dedicated hardware tester" WARN
    #endregion

    #region ── Summary ───────────────────────────────────────────────────────────
    $elapsed      = ((Get-Date) - $startTime).TotalSeconds
    Write-Header "Summary"

    $allOK        = $gateway -and $internetOK -and $dnsResolved -and $ipAddress
    $summaryColor = if ($allOK) { 'Green' } else { 'Yellow' }
    $summaryText  = if ($allOK) { 'PASS — Network connectivity confirmed' } else { 'WARN — One or more checks need attention' }

    Write-Host "  $summaryText" -ForegroundColor $summaryColor
    Write-Host "  Completed in $([Math]::Round($elapsed,1))s`n" -ForegroundColor DarkGray
    #endregion
}

if ($AdapterName) {
    Invoke-NetworkInfo @PSBoundParameters
} else {
    $allAdapters = Get-NetAdapter |
        Where-Object {
            $_.Status -eq 'Up' -and
            $_.MediaType -match '802\.3' -and
            $_.PhysicalMediaType -notmatch 'Wireless|Native 802.11'
        } |
        Sort-Object Speed -Descending

    if (-not $allAdapters) {
        Write-Host "`n  [!] No connected Ethernet adapters found.`n" -ForegroundColor Red
    } else {
        foreach ($a in $allAdapters) {
            Invoke-NetworkInfo -AdapterName $a.Name -GatewayTimeout $GatewayTimeout -PingTargets $PingTargets -LLDPTimeout $LLDPTimeout -CaptureLLDP:$CaptureLLDP
        }
    }
}
