# Hardware Test Fixture

Automated hardware tests for the bare-metal Pi 3 kernel, run from a Pi 4 test host.

See [test_plan.md](../test_plan.md) for the full physical setup.

**One-time tool setup:** see [TOOLS_SETUP.md](TOOLS_SETUP.md) for granting
`tcpdump`, `tshark`, `ethtool`, `arping`, and the venv's Python the minimum
capabilities needed to run without `sudo`.

## Prerequisites

- **Chromebook** with TFTP server (`dnsmasq`) serving `/srv/tftp`
- **Pi 4** running PiOS, connected to Pi 3 via USB-A to micro-USB cable
- **Pi 3** configured to network boot from Chromebook

## Quick Start

On the Chromebook:

```bash
make && hw_test/deploy.sh
```

Reboot the Pi 3 (power cycle).

On the Pi 4 (via SSH from Chromebook):

```bash
bash hw_test/run_tests.sh
```

The script waits for the Pi 3 to boot, then runs ARP and ICMP tests.

## Configuration

All settings live in `config.sh` and can be overridden via environment:

```bash
PI3_IP=10.0.2.15        # Pi 3 CDC-ECM address (hardcoded in kernel)
PI4_USB_IP=10.0.2.2     # Pi 4 usb0 address
PI4_USB_PREFIX=24        # Subnet prefix length
USB_IFACE=usb0           # Pi 4 interface name for CDC-ECM link
BOOT_TIMEOUT=30          # Seconds to wait for Pi 3 ARP response
TFTP_DIR=/srv/tftp       # TFTP root on Chromebook
```

Example: `BOOT_TIMEOUT=60 bash hw_test/run_tests.sh`

## Troubleshooting

- **UART debug**: connect USB-to-UART adapter to Pi 3 GPIO, `minicom -D /dev/ttyUSB0 -b 115200`
- **Packet capture**: `sudo tcpdump -i usb0 -w capture.pcap` on Pi 4
- **No usb0**: check USB cable is connected and Pi 3 has booted past CDC-ECM activation
