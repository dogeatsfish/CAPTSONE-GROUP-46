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

## Development environment (Dev Container)

The Linux C++ toolchain used to build and debug the engine is a VS Code Dev
Container. Its files live at [`sw/.devcontainer/`](../sw/.devcontainer) and are
**intentionally not moved here**: VS Code only auto-detects `.devcontainer/` at
the root of the folder you open, and this container is configured to open the
`sw/` workspace. Moving it would break the "Reopen in Container" workflow.

To use it: open the `sw/` folder in VS Code → **Reopen in Container**. See
[`sw/docs/README.md`](../sw/docs/README.md) for details on what the image
provides.
