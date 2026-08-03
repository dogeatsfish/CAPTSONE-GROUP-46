# Testing the Board From Scratch

The exact order to go from a cold start (bitstream not built, host never
configured) to seeing live trades against the real FPGA in the UI. Each step
links to the doc that actually explains it — this page is just the sequence.

**Assumes:** Vivado 2025.2 installed and licensed, the board cabled via
Ethernet (direct to the host, or a switch) and JTAG, and — for step 4
onward — a macOS/Linux/WSL2 machine (native Windows can't build
online/hardware support; see
[`sw/docs/build-and-test.md`](../sw/docs/build-and-test.md)).

## 1. Build and program the bitstream

One-time, or after any RTL change.

1. Synthesis → Implementation → Generate Bitstream, following
   [`vivado/synthesis_implementation.md`](../vivado/synthesis_implementation.md)
   — check the timing/CDC/utilization reports at each stage, don't skip
   straight to bitstream.
2. **Hardware Manager** → connect (JTAG) → **Program Device**.
3. Confirm the PHY link comes up at gigabit and the RX clock is present
   (`synthesis_implementation.md` § 4).

## 2. Configure the host ↔ FPGA network link

Per-session — macOS wipes this on every USB Ethernet re-enumeration, so
re-run it if the board was ever unplugged.

```bash
cd setup
sudo ./net_setup.sh            # macOS/Linux, defaults to interface en5
```
```powershell
cd setup
.\net_setup.ps1 -InterfaceAlias "Ethernet 2"   # Windows
```

Details: [`setup/README.md`](../setup/README.md).

## 3. Verify the physical link

Following [`docs/connection-test.md`](connection-test.md) steps 2–3:

1. Confirm the host has `inet 192.168.0.2` and `status: active` on the
   configured interface.
2. Confirm the board's link LED is solid.
3. Flood-ping to confirm frames actually reach the board (100% loss is
   expected — the board doesn't answer ICMP; you're just checking the
   **activity LED** blinks):
   ```bash
   sudo ping -f 192.168.0.1          # macOS/Linux
   ```
   ```powershell
   ping -t 192.168.0.1               # Windows (no flood mode)
   ```

If the activity LED doesn't blink, stop here — that's a cabling/PHY/host-TX
problem, not a software one. See `connection-test.md`'s disambiguation steps.

## 4. Confirm the board actually replies (protocol level)

This is the first point that proves the FPGA received, parsed, and acted on
real market data — everything before this only proved the wire works.

```bash
cd sw/engine
make hw-smoke-test
```

Streams a short order book at the board over UDP and expects OUCH responses
back (`tests/config/hardware_smoke.ini`). Alternatively, the manual two-terminal
version (`tcpdump` + `make run-online`) is in
[`docs/connection-test.md`](connection-test.md#4-end-to-end-test-with-market-data)
step 4 if you want to watch the raw frames yourself.

If this doesn't come back but the activity LED blinked in step 3, the
problem is inside the FPGA (bitstream/RTL) — see
[`docs/board_bringup_issues.md`](board_bringup_issues.md) and put an ILA on
`rx_mac_core`'s outputs.

## 5. Bring up the software stack against the board

Only once step 4 actually returns OUCH responses.

```bash
cd sw
./dev-hardware.sh
```

Rebuilds `engine_sim` fresh, starts the FastAPI backend natively (not
Docker — Docker's networking can't reach the board; see
[`docs/connection-test.md`](connection-test.md#running-the-backend-against-real-hardware)),
and starts the UI. Then in the browser:

1. **Mode** → `Online`
2. **Target** → `Real Board`
3. **Run Simulation**

Ctrl-C in the terminal stops both the backend and the UI together.

## Troubleshooting

| Symptom | Where to look |
|---|---|
| Board never leaves reset / looks dead | [`docs/board_bringup_issues.md`](board_bringup_issues.md) |
| Link LED on, activity LED never blinks | [`docs/connection-test.md`](connection-test.md) § 3 — likely host-side (no `inet` line, wrong interface) |
| Activity LED blinks, `hw-smoke-test`/`tcpdump` sees nothing back | [`docs/board_bringup_issues.md`](board_bringup_issues.md) + [`docs/hw_sw_transport_gaps.md`](hw_sw_transport_gaps.md) — FPGA-side (RTL/bitstream) |
| UI's "Real Board" run completes but shows zero trades | Expected today — `OnlineSimulation` doesn't auto-connect a strategy to send orders; see the note in [`sw/docs/run-dashboard.md`](../sw/docs/run-dashboard.md) |
| `dev-hardware.sh` refuses to run | You're on native Windows — use WSL2 (mirrored networking mode) or a macOS/Linux box instead |
