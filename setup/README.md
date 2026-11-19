# Setup

Everything needed to get a development machine and the host ↔ FPGA link ready.

## Host ↔ FPGA network link

Scripts to configure the host NIC for a direct Ethernet link to the board
(static IP on the board's subnet + static ARP entry, since the FPGA has no ARP).

| Script            | Platform        | Run as        |
|-------------------|-----------------|---------------|
| `net_setup.sh`    | macOS / Linux   | `sudo`        |
| `net_setup.ps1`   | Windows         | Administrator |

```bash
# macOS / Linux
sudo ./net_setup.sh [interface]        # default interface: en5
```

```powershell
# Windows (Administrator PowerShell)
.\net_setup.ps1 -InterfaceAlias "Ethernet 2"
```

Full walkthrough and connection tests:
[`docs/connection-test.md`](../docs/connection-test.md).
