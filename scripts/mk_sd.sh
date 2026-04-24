#!/usr/bin/env bash
# scripts/mk_sd.sh — assemble a Pi 4 SD-card boot bundle.
#
# Produces a directory that the user copies onto the FAT32 boot
# partition of a Pi 4 SD card. Boots straight into the packaged
# appliance kernel — no UART chainloader needed.
#
# Contents of the output directory:
#   config.txt            — Pi 4 firmware config. kernel_address=0x200000
#                           so the firmware loads our kernel at the same
#                           address the linker script targets (chainloader
#                           used to do this hand-off via UART).
#   start4.elf            — Pi 4 GPU firmware.
#   fixup4.dat            — firmware fixups.
#   bcm2711-rpi-4-b.dtb   — device tree for the 4-B model.
#   kernel8.img           — the packaged appliance kernel (first arg).
#
# Firmware blobs are NOT checked into the repo (they're upstream
# Raspberry Pi Foundation files, 2.3 MB total). They're expected in
# hw_test/uart_test/sdcard/ — if any are missing, the script invokes
# the existing download_firmware.sh to pull them from
# github.com/raspberrypi/firmware.
#
# Usage:
#   scripts/mk_sd.sh <packaged_kernel.img> <output_dir>
#
# End-to-end example:
#   make PLATFORM=pi4
#   scripts/mk_appliance.py kernel8.img public/ appliance.img
#   scripts/mk_sd.sh appliance.img sd_boot/
#   # then: cp -r sd_boot/* /media/<user>/boot/

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $(basename "$0") <packaged_kernel.img> <output_dir>" >&2
    exit 2
fi

KERNEL_IN="$1"
OUTDIR="$2"

if [[ ! -f "$KERNEL_IN" ]]; then
    echo "mk_sd: $KERNEL_IN not found" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

FW_DIR="$PROJECT_DIR/hw_test/uart_test/sdcard"
FW_FILES=("start4.elf" "fixup4.dat" "bcm2711-rpi-4-b.dtb")

# Ensure firmware blobs are present. If any are missing, pull all of
# them via the existing downloader — fresh clones work without manual
# setup.
missing=0
for f in "${FW_FILES[@]}"; do
    if [[ ! -f "$FW_DIR/$f" ]]; then
        missing=1
        break
    fi
done

if [[ "$missing" -eq 1 ]]; then
    echo "mk_sd: firmware blobs missing in $FW_DIR/ — fetching"
    bash "$FW_DIR/download_firmware.sh"
fi

# Re-check after download; bail loudly if still missing rather than
# producing a half-complete bundle.
for f in "${FW_FILES[@]}"; do
    if [[ ! -f "$FW_DIR/$f" ]]; then
        echo "mk_sd: firmware file $f still missing after download — aborting" >&2
        exit 1
    fi
done

mkdir -p "$OUTDIR"

# Copy kernel + firmware into the bundle.
cp "$KERNEL_IN" "$OUTDIR/kernel8.img"
for f in "${FW_FILES[@]}"; do
    cp "$FW_DIR/$f" "$OUTDIR/$f"
done

# Write config.txt. The kernel_address value is non-negotiable: the
# linker script (linker_hw.ld) targets 0x200000, and the firmware's
# VC agent lives at 0x80000. If the firmware loaded our kernel at the
# default 0x80000 address it would stomp the VC agent and UART would
# die during boot.
cat > "$OUTDIR/config.txt" <<'EOF'
# Pi 4 boot config for the ws_pi5 appliance.
#
# The kernel is linked to 0x200000 (linker_hw.ld). The firmware's
# VC agent owns 0x80000, so we tell the firmware to load our kernel
# image at 0x200000 instead of the default 0x80000 — otherwise the
# VC agent gets stomped and UART dies during boot.

arm_64bit=1
kernel=kernel8.img
kernel_address=0x200000
enable_uart=1
EOF

echo "mk_sd: SD boot bundle in $OUTDIR/"
ls -lh "$OUTDIR/"
echo
echo "Flash: mount the FAT32 boot partition of a fresh Pi 4 SD card and"
echo "  cp -r $OUTDIR/* /media/<user>/boot/"
