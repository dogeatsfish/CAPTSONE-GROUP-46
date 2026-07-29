# Host ↔ FPGA Link Setup and Connection Test

This guide explains how to wire the host PC directly to the FPGA over Ethernet,
configure the host so packets actually reach the board, and verify the link
step by step. The helper scripts referenced here live in [`setup/`](../setup).

## Background: why this needs special setup

The FPGA is **not** a general-purpose networked host. Its receive path only
understands one thing: raw Ethernet → IPv4/UDP → MoldUDP64 → ITCH market data
(see `rtl/rx_mac/rx_mac_core.sv` and `rtl/parser/cut_through_parser.sv`). It has
**no ARP, no ICMP, and no TCP**. That has three practical consequences:

- **You cannot `ping` the board to check connectivity.** Ping needs ARP (to
  resolve the board's MAC) and ICMP (for the echo reply); the board answers
  neither. A failed ping says nothing about link health.
- **The host will not send to the board on its own.** Before the OS transmits a
  frame to `192.168.0.1`, it tries to ARP for that IP's MAC and gets no reply,
  so the packet is never sent. You must add a *static ARP entry* to break this
  deadlock.
- **The board only speaks UDP.** The software order-entry server must be in UDP
  mode (the default; see `sw/engine/simulation/include/online_simulation.h`).

## Addressing

These values are fixed in the RTL and the host config must match them:

| Role        | IP            | MAC                 | Source (RTL)                        |
|-------------|---------------|---------------------|-------------------------------------|
| FPGA (board)| `192.168.0.1` | `00:0a:35:01:02:03` | `SRC_IP`/`SRC_MAC`, tx modules      |
| Host (PC)   | `192.168.0.2` | your NIC's MAC      | `DST_IP` in `outbound_tx_generator` |
| OUCH UDP port | `50001`     | —                   | `DST_PORT` in `outbound_tx_generator` |

> The board's RX MAC does **not** filter on destination MAC, so the host may
> send to the board with any destination MAC. For the reverse direction (board
> → host), set `DST_MAC` in `rtl/ip/tx_mac/tx_mac_core.sv` to your host NIC's
> MAC or to broadcast (`FF:FF:FF:FF:FF:FF`), otherwise the host NIC filters the
> board's frames out before the kernel sees them.

## 1. Configure the host NIC

macOS wipes manual IP and static ARP settings whenever the USB Ethernet adapter
re-enumerates or the link flaps, so this must be re-run after every unplug.

### macOS / Linux

```bash
cd setup
sudo ./net_setup.sh            # defaults to interface en5
# or specify the interface:
sudo ./net_setup.sh en6
```

### Windows (Administrator PowerShell)

```powershell
cd setup
Get-NetAdapter                             # find the adapter's exact name
.\net_setup.ps1 -InterfaceAlias "Ethernet 2"
```

Both scripts assign `192.168.0.2/24` to the interface and pin the static ARP
(neighbor) entry for `192.168.0.1`, then print the result.

To make the IP persist across replugs on macOS, also set it in
**System Settings → Network → (USB LAN adapter) → Configure IPv4: Manually**.
The static ARP entry still has to be re-added by the script.

## 2. Verify the physical link

```bash
ifconfig en5 | grep -E 'inet |status'      # macOS/Linux
```

You want to see:

- an `inet 192.168.0.2` line — the host has an IP on the board's subnet
- `status: active` — a link is negotiated
- `media: ... 1000baseT <full-duplex>` — gigabit, which matches the RTL's
  125 MHz RGMII. (100baseT would indicate a clock-rate mismatch.)

On the board, a solid **link LED** confirms the PHYs negotiated a connection.
This happens even if the FPGA is not programmed, so it proves the cable and PHY
only, not that your design is running.

## 3. Prove the host is transmitting (raw wire activity)

Because of the static ARP entry, the host can now put frames on the wire even
though the board never replies. Flood the link and watch the board's
**activity LED**:

```bash
sudo ping -f 192.168.0.1          # macOS/Linux; Ctrl-C to stop
ping -t 192.168.0.1               # Windows (no flood mode)
```

**100% packet loss is expected and correct** — the board does not answer ICMP.
We are only checking whether frames reach the board.

- **Activity LED blinks** → frames are reaching the board's PHY. The host TX and
  the physical link are good; any remaining problem is inside the FPGA.
- **Activity LED does nothing** → either the host is not transmitting (re-check
  step 1; a missing `inet` line means no route and nothing is sent), or that LED
  is FPGA-driven rather than PHY-driven. Disambiguate by plugging the same cable
  into a normal switch and repeating: if the switch's activity light blinks, the
  host TX is fine.

## 4. End-to-end test with market data

Stream ITCH market data at the board and watch for OUCH orders coming back —
the only true proof the board received, parsed, and acted on the data.

Terminal A — watch for board-sourced frames (filters out host/OS noise):

```bash
sudo tcpdump -i en5 -e -n ether src 00:0a:35:01:02:03
```

Terminal B — stream market data (from `sw/engine`):

```bash
make run-online                                   # paced, real time
# or blast continuously for a strong, steady signal:
while true; do ./online_run ../data_pipeline/data/synthetic_mbo_stream.bin 0; done
```

If OUCH frames appear in Terminal A, the full chain works. If nothing returns
while the activity LED blinks under load, the issue is inside the FPGA:

1. Confirm the bitstream is loaded and running (a link LED does not require it).
2. Put an ILA on the RGMII RX (`rgmii_rxd`, `rgmii_rx_ctl`) or on
   `rx_mac_core`'s outputs (`m_axis_tvalid`, `rx_error`). Persistent `rx_error`
   points to the RGMII RX clock-delay issue noted in `tx_mac_core.sv`.
3. Confirm the replayed data actually triggers the strategy (the offline sim
   should report `total_trades > 0` on the same file).

## Important caveats

- **tcpdump taps before the wire.** Seeing packets leave in `tcpdump` proves the
  kernel queued them, not that they hit the copper. Only board-return traffic or
  the activity LED confirm delivery.
- **A browser cannot test this.** Browsers speak HTTP over TCP; the board speaks
  binary UDP. The page will hang forever by design.
- **The engine is POSIX-only.** `online_run` uses POSIX sockets and does not
  build natively on Windows. Run the streaming engine on macOS/Linux; use the
  Windows script only for configuring a Windows host's link.
