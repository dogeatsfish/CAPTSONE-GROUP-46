<#
    Re-establish the direct FPGA link config on a Windows host NIC.

    Windows equivalent of net_setup.sh. Assigns the host IP on the board's
    subnet and pins a static ARP (neighbor) entry, so the ARP-less FPGA is
    reachable without address resolution. Values match the FPGA RTL:
      host IP   = DST_IP  in outbound_tx_generator.sv (192.168.0.2)
      board IP  = SRC_IP  in outbound_tx_generator.sv (192.168.0.1)
      board MAC = SRC_MAC in tx_mac_core.sv           (00-0a-35-01-02-03)

    NOTE: Windows writes MAC addresses with DASHES, not colons.

    Usage (in an ADMINISTRATOR PowerShell):
      Set-ExecutionPolicy -Scope Process Bypass -Force   # if scripts are blocked
      .\net_setup.ps1 -InterfaceAlias "Ethernet 2"

    Find your adapter name with:  Get-NetAdapter
#>

param(
    [string]$InterfaceAlias = "Ethernet",
    [string]$HostIP         = "192.168.0.2",
    [int]   $PrefixLength   = 24,                 # 24 = 255.255.255.0
    [string]$BoardIP        = "192.168.0.1",
    [string]$BoardMAC       = "00-0a-35-01-02-03"
)

$ErrorActionPreference = "Stop"

# Require Administrator.
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "Run this in an Administrator PowerShell (right-click -> Run as administrator)."
    exit 1
}

Write-Host "Configuring '$InterfaceAlias' -> $HostIP/$PrefixLength, static ARP $BoardIP -> $BoardMAC"

# Remove any existing IPv4 addresses/routes on the interface so the set is clean.
Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue

# Assign the host IP on the board's subnet.
New-NetIPAddress -InterfaceAlias $InterfaceAlias `
    -IPAddress $HostIP -PrefixLength $PrefixLength | Out-Null

# Pin the board's MAC (modern replacement for `arp -s`). Clear any stale entry first.
Remove-NetNeighbor -InterfaceAlias $InterfaceAlias -IPAddress $BoardIP `
    -Confirm:$false -ErrorAction SilentlyContinue
New-NetNeighbor -InterfaceAlias $InterfaceAlias `
    -IPAddress $BoardIP -LinkLayerAddress $BoardMAC -State Permanent | Out-Null

Write-Host ""
Write-Host "--- Result ---"
Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 |
    Select-Object InterfaceAlias, IPAddress, PrefixLength | Format-Table -AutoSize
Get-NetNeighbor -InterfaceAlias $InterfaceAlias -IPAddress $BoardIP |
    Select-Object InterfaceAlias, IPAddress, LinkLayerAddress, State | Format-Table -AutoSize

Write-Host "Link config applied."
Write-Host "Test raw wire activity with:  ping -t $BoardIP"
Write-Host "(100% packet loss / 'Request timed out' is expected -- the FPGA does not answer ICMP.)"
