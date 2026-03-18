# Hardware Test Plan

## Physical Setup

```
Chromebook
  └── USB hub
        ├── USB-to-Ethernet NIC → switch/hub → Pi 4 (Ethernet) + Pi 3 (Ethernet)
        └── USB-to-UART adapter → Pi 3 GPIO (TX/RX)

Pi 4 USB-A ←── USB cable ──→ Pi 3 micro-USB (CDC-ECM under test)
```

## Roles

### Chromebook (development host)
- Builds `kernel8.img` and Pi 4 test scripts
- Runs dnsmasq: DHCP + TFTP server for both Pis (different kernels by MAC)
- SSH to Pi 4 to run test commands
- UART console to Pi 3 for debug output (minicom/screen)

### Pi 4 — PiOS (test host)
- Network boots from Chromebook (PXE/TFTP)
- CDC-ECM peer: Pi 3 appears as `usb0` interface
- Runs test commands: `arping`, `ping`, `tcpdump`
- Accessible via SSH from Chromebook

### Pi 3 — bare-metal (device under test)
- Network boots from Chromebook (TFTP loads `kernel8.img`)
- Runs bare-metal kernel: UART, DWC2, CDC-ECM, net_loop
- UART TX/RX on GPIO for debug output
- micro-USB port is CDC-ECM device side

## Network Configuration

| Host | Interface | IP | Role |
|---|---|---|---|
| Chromebook | USB-to-Ethernet NIC | 10.0.2.1/24 | DHCP/TFTP server |
| Pi 4 | Ethernet (eth0) | DHCP from Chromebook | Network boot, SSH |
| Pi 4 | USB (usb0) | 10.0.2.2/24 (static) | CDC-ECM peer |
| Pi 3 | Ethernet | DHCP from Chromebook | Network boot only |
| Pi 3 | micro-USB (CDC-ECM) | 10.0.2.15 (hardcoded) | Device under test |

## Test Cycle

1. Edit code on Chromebook, `make`
2. Reboot Pi 3 — TFTP loads new `kernel8.img`
3. Watch UART for boot messages (`"CDC-ECM data interface active"`)
4. SSH to Pi 4, run test commands
5. Observe results

## Test Commands (on Pi 4)

```bash
# Configure CDC-ECM peer interface
sudo ip addr add 10.0.2.2/24 dev usb0
sudo ip link set usb0 up

# ARP validation
arping -c 1 -I usb0 10.0.2.15

# ICMP validation
ping -c 5 10.0.2.15

# Packet capture for debugging
sudo tcpdump -i usb0 -w capture.pcap
```

## Required Hardware

- Chromebook (development host)
- Raspberry Pi 4 running PiOS (test host)
- Raspberry Pi 3 (device under test)
- USB hub (for Chromebook)
- USB-to-Ethernet NIC
- USB-to-UART adapter (3.3V)
- Ethernet switch or hub
- USB-A to micro-USB cable (Pi 4 to Pi 3)
- 2x Ethernet cables
