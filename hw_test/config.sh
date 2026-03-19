# hw_test/config.sh — shared configuration for hardware test scripts
# All values overridable via environment variables.

PI3_IP="${PI3_IP:-10.0.2.15}"
PI4_USB_IP="${PI4_USB_IP:-10.0.2.2}"
PI4_USB_PREFIX="${PI4_USB_PREFIX:-24}"
USB_IFACE="${USB_IFACE:-usb0}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-30}"
TFTP_DIR="${TFTP_DIR:-/srv/tftp}"
