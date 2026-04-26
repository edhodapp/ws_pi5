#!/usr/bin/env bash
# scripts/mk_sd.sh — assemble a Pi 4 SD-card boot bundle.
#
# Two output modes:
#   scripts/mk_sd.sh            <kernel.img> <output_dir>
#   scripts/mk_sd.sh --image    <kernel.img> <output_image.img>
#
# Directory mode produces a staging directory the user copies onto the
# FAT32 boot partition of a pre-formatted Pi 4 SD card. Image mode
# produces a single raw disk image (MBR + FAT32 partition) the user
# flashes with Raspberry Pi Imager / balenaEtcher / dd — no manual
# formatting or mounting. --image requires mtools on PATH.
#
# Contents (either mode, same files):
#   config.txt            — kernel_address=0x200000 so the firmware
#                           loads the kernel at the same address
#                           linker_hw.ld targets. The firmware's VC
#                           agent owns 0x80000 and must not be stomped
#                           — otherwise UART dies mid-boot.
#   start4.elf            — Pi 4 GPU firmware.
#   fixup4.dat            — firmware fixups.
#   bcm2711-rpi-4-b.dtb   — device tree for the 4-B.
#   kernel8.img           — the packaged appliance kernel (first arg).
#
# Firmware blobs are NOT checked into the repo (they're upstream Pi
# Foundation files, 2.3 MB total). Expected in
# hw_test/uart_test/sdcard/ — auto-fetched on first use via the
# existing download_firmware.sh.
#
# Third mode: --build <public_dir> <output_image>
# One-command flow for developers: measure the public dir, rebuild the
# kernel with a CONTENT_MAX sized to that, package the site, and emit a
# raw SD image — all in one step. Produces an image sized to the site
# rather than the default 256 MiB default, so a small site fits on a
# small SD card.
#
# End-to-end example (directory mode):
#   make PLATFORM=pi4
#   scripts/mk_appliance.py kernel8.img public/ appliance.img
#   scripts/mk_sd.sh appliance.img sd_boot/
#   cp -r sd_boot/* /media/<user>/boot/
#
# End-to-end example (image mode):
#   make PLATFORM=pi4
#   scripts/mk_appliance.py kernel8.img public/ appliance.img
#   scripts/mk_sd.sh --image appliance.img pi4_sd.img
#   # flash pi4_sd.img with any SD writer
#
# End-to-end example (build mode):
#   scripts/mk_sd.sh --build public/ pi4_sd.img
#   # flash pi4_sd.img with any SD writer

set -euo pipefail

MODE="dir"
case "${1:-}" in
    --image) MODE="image"; shift ;;
    --build) MODE="build"; shift ;;
esac

if [[ $# -ne 2 ]]; then
    cat >&2 <<USAGE
usage:
  $(basename "$0")          <packaged_kernel.img> <output_dir>
  $(basename "$0") --image  <packaged_kernel.img> <output_image.img>
  $(basename "$0") --build  <public_dir> <output_image.img>
USAGE
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --build mode: bootstrap a sized kernel, package the site, then fall
# through to --image mode against the packaged output.
if [[ "$MODE" == "build" ]]; then
    PUBLIC_DIR="$1"
    SD_IMAGE="$2"
    if [[ ! -d "$PUBLIC_DIR" ]]; then
        echo "mk_sd: $PUBLIC_DIR is not a directory" >&2
        exit 1
    fi

    # Measure the public dir's on-disk size and round up to MiB with a
    # comfortable slack (larger of +1 MiB or +25 %). HTTP response
    # headers baked into content also take ~100 bytes per file; the
    # slack easily covers that.
    SITE_BYTES=$(du -sb "$PUBLIC_DIR" | cut -f1)
    SLACK_25=$(( SITE_BYTES / 4 ))
    SLACK_1MB=$(( 1024 * 1024 ))
    if (( SLACK_25 > SLACK_1MB )); then
        SLACK=$SLACK_25
    else
        SLACK=$SLACK_1MB
    fi
    # Round up to next 1 MiB.
    CONTENT_MAX=$(( (SITE_BYTES + SLACK + SLACK_1MB - 1) / SLACK_1MB * SLACK_1MB ))

    echo "mk_sd: site is $SITE_BYTES B; building kernel with CONTENT_MAX=$CONTENT_MAX B"
    ( cd "$PROJECT_DIR" && make clean >/dev/null && make PLATFORM=pi4 CONTENT_MAX="$CONTENT_MAX" >/dev/null )

    APPLIANCE_TMP=$(mktemp -u --suffix=.img)
    python3 "$PROJECT_DIR/scripts/mk_appliance.py" \
        --content-max "$CONTENT_MAX" \
        "$PROJECT_DIR/kernel8.img" "$PUBLIC_DIR" "$APPLIANCE_TMP"

    # Re-exec ourselves in --image mode against the packaged kernel so
    # the rest of the script (firmware fetch, staging dir, mk_sd_image)
    # runs without duplication.
    exec "$0" --image "$APPLIANCE_TMP" "$SD_IMAGE"
fi

KERNEL_IN="$1"
TARGET="$2"

if [[ ! -f "$KERNEL_IN" ]]; then
    echo "mk_sd: $KERNEL_IN not found" >&2
    exit 1
fi

# SCRIPT_DIR / PROJECT_DIR already resolved above (shared with --build
# mode's bootstrap path).

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

for f in "${FW_FILES[@]}"; do
    if [[ ! -f "$FW_DIR/$f" ]]; then
        echo "mk_sd: firmware file $f still missing after download — aborting" >&2
        exit 1
    fi
done

# Directory mode writes directly into TARGET; image mode stages into a
# tmpdir and then converts to a raw disk image via mk_sd_image.py.
if [[ "$MODE" == "image" ]]; then
    STAGING=$(mktemp -d)
    trap 'rm -rf "$STAGING"' EXIT
    BUNDLE_DIR="$STAGING"
else
    mkdir -p "$TARGET"
    BUNDLE_DIR="$TARGET"
fi

cp "$KERNEL_IN" "$BUNDLE_DIR/kernel8.img"
for f in "${FW_FILES[@]}"; do
    cp "$FW_DIR/$f" "$BUNDLE_DIR/$f"
done

cat > "$BUNDLE_DIR/config.txt" <<'EOF'
# Pi 4 boot config for the ws_pi5 appliance.
#
# The kernel is linked to 0x200000 (linker_hw.ld). The firmware's
# VC agent owns 0x80000, so we tell the firmware to load our kernel
# image at 0x200000 instead of the default 0x80000 — otherwise the
# VC agent gets stomped and UART dies during boot.
#
# dtoverlay=disable-bt frees PL011 from the Bluetooth chip so it
# routes to GPIO 14/15 (header pins 8/10). Our kernel writes debug
# output through PL011 at 0xFE201000; without this overlay, the
# firmware points PL011 at BT and GPIO 14/15 get the mini UART
# instead — serial output disappears even on a successfully-booted
# kernel. Same setting the known-good chainloader dev sdcard uses.

arm_64bit=1
kernel=kernel8.img
kernel_address=0x200000
enable_uart=1
dtoverlay=disable-bt
EOF

if [[ "$MODE" == "image" ]]; then
    python3 "$PROJECT_DIR/scripts/mk_sd_image.py" "$BUNDLE_DIR" "$TARGET"
else
    echo "mk_sd: SD boot bundle in $TARGET/"
    ls -lh "$TARGET/"
    echo
    echo "Flash: mount the FAT32 boot partition of a fresh Pi 4 SD card and"
    echo "  cp -r $TARGET/* /media/<user>/boot/"
fi
