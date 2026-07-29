#!/usr/bin/env bash
#
# Re-establish the direct FPGA link config on the host NIC.
#
# macOS drops manual ifconfig IPs and static ARP entries whenever the USB
# Ethernet adapter re-enumerates or the link flaps, so this has to be re-run
# after every unplug/replug. Values match the FPGA RTL:
#   host IP   = DST_IP  in outbound_tx_generator.sv (192.168.0.2)
#   board IP  = SRC_IP  in outbound_tx_generator.sv (192.168.0.1)
#   board MAC = SRC_MAC in tx_mac_core.sv           (00:0a:35:01:02:03)
#
# Usage:  sudo ./net_setup.sh [interface]
#   interface defaults to en5 (the USB 10/100/1000 LAN adapter).

set -euo pipefail

IFACE="${1:-en5}"
HOST_IP="192.168.0.2"
NETMASK="255.255.255.0"
BOARD_IP="192.168.0.1"
BOARD_MAC="00:0a:35:01:02:03"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "This script configures the NIC and ARP table; re-run with sudo:" >&2
  echo "  sudo $0 $IFACE" >&2
  exit 1
fi

echo "Configuring $IFACE -> $HOST_IP/$NETMASK, static ARP $BOARD_IP -> $BOARD_MAC"

# Assign the host IP on the board's subnet.
ifconfig "$IFACE" inet "$HOST_IP" netmask "$NETMASK"

# Pin the board's MAC so the (ARP-less) FPGA is reachable without resolution.
arp -s "$BOARD_IP" "$BOARD_MAC"

echo
echo "--- Result ---"
ifconfig "$IFACE" | grep -E 'inet |status' || true
arp -n "$BOARD_IP" || true

echo
echo "Link config applied. If 'status' is not 'active', check the cable."
echo "Test raw wire activity with:  sudo ping -f $BOARD_IP"
echo "(100% packet loss is expected -- the FPGA does not answer ICMP.)"
