#!/bin/sh
#
# Download Raspberry Pi 4 GPU firmware files for bare-metal boot.
#
# These files go on the FAT32 SD card alongside kernel8.img and config.txt.
# Source: https://github.com/raspberrypi/firmware/tree/master/boot
#
# Usage: ./download_firmware.sh

set -e

REPO="https://github.com/raspberrypi/firmware/raw/master/boot"
DIR="$(dirname "$0")"

echo "Downloading Pi 4 firmware to $DIR/"

curl -L -o "$DIR/start4.elf"              "$REPO/start4.elf"
curl -L -o "$DIR/fixup4.dat"              "$REPO/fixup4.dat"
curl -L -o "$DIR/bcm2711-rpi-4-b.dtb"     "$REPO/bcm2711-rpi-4-b.dtb"

echo "Done."
ls -lh "$DIR/start4.elf" "$DIR/fixup4.dat" "$DIR/bcm2711-rpi-4-b.dtb"
