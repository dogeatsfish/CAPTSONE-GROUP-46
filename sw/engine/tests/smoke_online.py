#!/usr/bin/env python3
"""Smoke test for the online (real-time) simulation.

Builds a tiny MBO stream, launches ./online_run, subscribes to the ITCH UDP
broadcast, and sends an OUCH order over TCP that lifts the resting ask. Verifies
that ITCH packets are received and that the run reports at least one trade.
"""
import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ENGINE_DIR = os.path.dirname(HERE)
BIN = os.path.join(ENGINE_DIR, "online_run")

MBO_FMT = struct.Struct("<QcQcdd")  # ts, type, id, side, price, size
ITCH_PORT = 26123
OUCH_PORT = 26124


# OUCH ENTER: type(1) order_id(8 BE) side(1) price(8 BE double) size(8 BE double)
def ouch_enter(order_id, side, price, size):
    return (
        b"O"
        + order_id.to_bytes(8, "big")
        + side
        + struct.pack(">d", price)
        + struct.pack(">d", size)
    )


def build_mbo(path):
    base = 1_000_000_000_000_000_000  # arbitrary ns epoch
    step = 300_000_000  # 300 ms between records
    ms = 1_000_000
    recs = [
        (base + 0 * ms, b"A", 1, b"B", 100.0, 100.0),  # resting bid
        (base + 300 * ms, b"A", 2, b"S", 101.0, 100.0),  # resting ask (rests ~2s)
        (base + 2300 * ms, b"C", 1, b"B", 100.0, 100.0),  # cancel -> end
    ]
    with open(path, "wb") as f:
        for r in recs:
            f.write(MBO_FMT.pack(*r))


def main():
    if not os.path.exists(BIN):
        print("FAIL: online_run not built; run `make online` first.")
        return 1

    tmp = tempfile.NamedTemporaryFile(suffix=".bin", delete=False)
    tmp.close()
    build_mbo(tmp.name)

    # ITCH subscriber (UDP) — bind before launching so we don't miss packets.
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    udp.bind(("127.0.0.1", ITCH_PORT))
    udp.settimeout(3.0)

    itch_packets = []

    def listen_itch():
        try:
            while True:
                data, _ = udp.recvfrom(2048)
                itch_packets.append(data)
        except socket.timeout:
            pass
        except OSError:
            pass

    t = threading.Thread(target=listen_itch, daemon=True)
    t.start()

    # time_scale 1.0 => ~1.5s replay; plenty of time to connect an OUCH client.
    proc = subprocess.Popen(
        [BIN, tmp.name, "1.0", str(ITCH_PORT), str(OUCH_PORT)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )

    # Wait until the resting ask is definitely in the book (added ~300ms into
    # the replay) but well before the 2.3s end-of-stream cancel.
    time.sleep(1.0)

    # OUCH client: send an aggressive buy that lifts the resting ask @101.
    try:
        tcp = socket.create_connection(("127.0.0.1", OUCH_PORT), timeout=2.0)
        tcp.sendall(ouch_enter(900_000_001, b"B", 101.0, 100.0))
        time.sleep(0.2)
        tcp.close()
    except OSError as e:
        print(f"WARN: OUCH client could not connect: {e}")

    out, _ = proc.communicate(timeout=15)
    udp.close()
    t.join(timeout=1.0)
    os.unlink(tmp.name)

    print("---- online_run output ----")
    print(out.strip())
    print("---------------------------")
    print(f"ITCH packets received: {len(itch_packets)}")

    ok = True
    if len(itch_packets) == 0:
        print("FAIL: no ITCH packets received over UDP.")
        ok = False
    # First ITCH packet should be an Add ('A').
    elif itch_packets[0][:1] != b"A":
        print(f"FAIL: unexpected first ITCH packet type: {itch_packets[0][:1]!r}")
        ok = False

    total_trades = None
    for line in out.splitlines():
        if "Total trades:" in line:
            total_trades = int(line.split(":")[1].strip())
    if total_trades is None:
        print("FAIL: could not parse trade count from output.")
        ok = False
    elif total_trades < 1:
        print("FAIL: expected at least one trade (OUCH order should have filled).")
        ok = False

    print("PASS" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
