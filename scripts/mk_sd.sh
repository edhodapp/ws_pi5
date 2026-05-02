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
#   config.txt            — kernel + dtoverlay=disable-bt. No
#                           kernel_address= directive: linker_hw.ld
#                           targets 0x80000 (the firmware default),
#                           so the firmware lands the kernel exactly
#                           where the linker expects it. (The earlier
#                           "VC agent owns 0x80000" claim was a
#                           misdiagnosis — see debug_log_0x80000.md.)
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
#   make PLATFORM=pi4 SHIP=1
#   scripts/mk_appliance.py kernel8.img public/ appliance.img
#   scripts/mk_sd.sh appliance.img sd_boot/
#   cp -r sd_boot/* /media/<user>/boot/
#
# End-to-end example (image mode):
#   make PLATFORM=pi4 SHIP=1
#   scripts/mk_appliance.py kernel8.img public/ appliance.img
#   scripts/mk_sd.sh --image appliance.img pi4_sd.img
#   # flash pi4_sd.img with any SD writer
#
# End-to-end example (build mode):
#   scripts/mk_sd.sh --build public/ pi4_sd.img
#   # flash pi4_sd.img with any SD writer

set -euo pipefail

MODE="dir"
TESTRIG=0
CHAINLOAD=0
# Parse leading flags. --testrig is dev-only: overwrites the default
# placeholder network.conf with the hw_test rig values
# (10.0.0.2 / 10.0.0.1 / wspi5) so dev iteration doesn't have to
# hand-edit the file every time. Release users never pass it.
# --chainload is dev-only: builds + ships chainload/chainload.img as
# kernel8.img and adds kernel_address=0x4000000 to config.txt, so the
# Pi boots into the UART chainloader and waits for hw_send.py to push
# a kernel built at LINK_ADDR=0x200000. Implies --testrig and --image
# (chainloader SDs are only meaningful as flashable images for the rig).
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --image)     MODE="image"; shift ;;
        --build)     MODE="build"; shift ;;
        --testrig)   TESTRIG=1; shift ;;
        --chainload) CHAINLOAD=1; TESTRIG=1; MODE="image"; shift ;;
        *)           echo "mk_sd: unknown flag $1" >&2; exit 2 ;;
    esac
done

# --chainload synthesizes its own "kernel" arg (the chainloader binary)
# so the user only passes the output image path.
if (( CHAINLOAD == 1 )); then
    if [[ $# -ne 1 ]]; then
        cat >&2 <<USAGE
usage:
  $(basename "$0") --chainload <output_image.img>

  Builds chainload/chainload.img if missing, then ships it as the
  kernel8.img on the SD bundle along with kernel_address=0x4000000
  in config.txt and the testrig network.conf. The Pi will boot into
  the chainloader and wait for hw_send.py to push a kernel built
  with the default 'make PLATFORM=pi4' (LINK_ADDR=0x200000).
USAGE
        exit 2
    fi
    SCRIPT_DIR_TMP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_DIR_TMP="$(cd "$SCRIPT_DIR_TMP/.." && pwd)"
    CHAIN_IMG="$PROJECT_DIR_TMP/chainload/chainload.img"
    if [[ ! -f "$CHAIN_IMG" ]]; then
        echo "mk_sd: building $CHAIN_IMG"
        make -C "$PROJECT_DIR_TMP/chainload" >&2
    fi
    set -- "$CHAIN_IMG" "$1"
fi

if [[ $# -ne 2 ]]; then
    cat >&2 <<USAGE
usage:
  $(basename "$0")             [--testrig] <packaged_kernel.img> <output_dir>
  $(basename "$0") --image     [--testrig] <packaged_kernel.img> <output_image.img>
  $(basename "$0") --build     <public_dir> <output_image.img>
  $(basename "$0") --chainload <output_image.img>

flags:
  --testrig    dev-only: overlay 10.0.0.2 / 10.0.0.1 / wspi5 onto the
               default network.conf so the SD boots straight to the
               standard hw_test wiring without manual edits.
  --chainload  dev-only: ship chainload.img as kernel8.img with
               kernel_address=0x4000000 so the Pi boots into the
               UART chainloader. Implies --testrig and --image.
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
    # SHIP=1 → kernel linked at 0x80000 to match firmware default
    # (no kernel_address= override needed in config.txt). The chainloader
    # path uses LINK_ADDR=0x200000 by default; SD-direct ship images
    # always need 0x80000.
    ( cd "$PROJECT_DIR" && make clean >/dev/null && make PLATFORM=pi4 SHIP=1 CONTENT_MAX="$CONTENT_MAX" >/dev/null )

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

# Soft sanity: warn if the kernel looks like a default-slab build
# (256 MiB CONTENT_MAX) and we're NOT in --build mode (which sized
# the slab deliberately from public/). Catches the dev-iteration
# trap of forgetting CONTENT_MAX. Doesn't abort — release users
# legitimately ship large kernels and we don't want a false-positive
# blocking them.
if [[ "$MODE" != "build" ]]; then
    KSIZE=$(stat -c '%s' "$BUNDLE_DIR/kernel8.img")
    if (( KSIZE > 50 * 1024 * 1024 )); then
        cat >&2 <<MKSDWARN
mk_sd: notice — kernel8.img is $((KSIZE / 1024 / 1024)) MiB.
       If this is a hardware test (mDNS / DHCP / L4) and you don't need the
       full appliance content, rebuild with:
           make pi4-test
       which uses CONTENT_MAX=65536 MAX_ROUTES=8 → ~150 KiB kernel.
       Continuing as-is.
MKSDWARN
    fi
fi

# overlays/disable-bt.dtbo is load-bearing: without it the firmware
# silently keeps PL011 routed to the BT chip and our kernel's UART
# debug output disappears (debug_log_0x80000.md attempt 38).
mkdir -p "$BUNDLE_DIR/overlays"
if [[ ! -f "$FW_DIR/overlays/disable-bt.dtbo" ]]; then
    echo "mk_sd: overlays/disable-bt.dtbo missing in $FW_DIR/ — aborting" >&2
    echo "       (re-run $FW_DIR/download_firmware.sh to fetch it)" >&2
    exit 1
fi
cp "$FW_DIR/overlays/disable-bt.dtbo" "$BUNDLE_DIR/overlays/disable-bt.dtbo"

# Read INITRAMFS_ADDR from the Makefile so config.txt's `initramfs`
# directive stays in sync with the address asm sees via --defsym.
# Single source of truth per D004; if the value ever moves, the
# asm parser and the firmware load both follow.
INITRAMFS_ADDR="$(make -s -C "$PROJECT_DIR" print-INITRAMFS_ADDR)"
if [ -z "$INITRAMFS_ADDR" ]; then
    echo "mk_sd: failed to read INITRAMFS_ADDR from Makefile" >&2
    exit 1
fi

cat > "$BUNDLE_DIR/config.txt" <<EOF
# Pi 4 boot config for the ws_pi5 appliance.
#
# linker_hw.ld targets 0x80000 (the firmware default kernel load
# address). No kernel_address= directive needed — the firmware lands
# kernel8.img exactly where the linker expects it. End-user SD-direct
# boot path verified at debug_log_0x80000.md attempt 40.
#
# dtoverlay=disable-bt frees PL011 from the Bluetooth chip so it
# routes to GPIO 14/15 (header pins 8/10). Our kernel writes debug
# output through PL011 at 0xFE201000; without this overlay (and the
# matching .dtbo file in overlays/), the firmware silently points
# PL011 at BT and serial output disappears even on a clean boot.
# Lost a whole-day session 1 to this one — see attempt 38.
#
# initramfs network.conf <addr>: tells the firmware to load the
# network configuration text file to physical address INITRAMFS_ADDR
# (read from the Makefile at SD-bundle build time so the kernel asm
# and this directive stay in sync — see D004). The kernel's boot.S
# saves the firmware-passed DTB pointer (in x0); config_parser
# uses the DTB's /chosen/linux,initrd-{start,end} properties to
# locate the loaded blob.

arm_64bit=1
kernel=kernel8.img
enable_uart=1
dtoverlay=disable-bt
initramfs network.conf $INITRAMFS_ADDR
EOF

# --chainload: append kernel_address=0x4000000 so firmware lands
# chainload.img at the address its linker script targets (chainload.ld
# sets `. = 0x4000000`). Without this the firmware lands kernel8.img
# at the default 0x80000 and the chainloader's literal-pool addresses
# resolve wrong — leading to silent wedge or cache-coherency garbage.
if (( CHAINLOAD == 1 )); then
    echo "kernel_address=0x4000000" >> "$BUNDLE_DIR/config.txt"
fi

# Default network.conf — placeholder values that pass the linter
# (D003 syntax) but won't bring up the network on most home LANs
# (gateway 0.0.0.0 → ARP fails → panic_g per D013). Failing loudly
# with the panic LED is the right behaviour: it tells the user to
# pop the SD out, edit network.conf, and re-flash. Defaults that
# happened to "work" by accident on the user's network would mask
# the user's failure-to-customize.
cat > "$BUNDLE_DIR/network.conf" <<'EOF'
# WSPI5CFG
#
# Edit these values for your home network, then save and reinsert
# the SD card. See README.md for details on each field, and
# docs/PANIC_PATTERNS.md for what the LED is telling you if the Pi
# halts during boot.

# Required: this Pi's static IPv4 address.
ip=0.0.0.0

# Required: subnet netmask. The runtime currently ignores this
# (D010 — stack uses always-via-gateway routing); it's recorded
# here for documentation. Use whatever your home router shows.
netmask=255.255.255.0

# Required: IPv4 of your router / default gateway. The Pi ARPs
# this at boot; if it doesn't answer, the kernel halts with panic
# pattern G (`——·`).
gateway=0.0.0.0

# Required: this Pi's hostname (1-63 LDH chars: letters, digits,
# hyphens; first char must be a letter or digit). Reachable as
# <hostname>.local once mDNS comes up.
hostname=wspi5

# Optional: NTP server IPv4 address. Comment out to skip NTP.
#ntp_server=216.239.35.0

# Optional: explicit MAC override. Comment out to use the factory
# MAC from the Pi 4 OTP fuses (mailbox tag 0x00010003). If the
# mailbox call fails AND no override is provided, the kernel
# halts with panic pattern M (`——`) — see D011.
#mac=de:ad:be:ef:ca:fe

# Optional: DHCP mode (per D017). Set "dhcp=yes" to have the kernel
# acquire its IP / netmask / gateway via DHCP at boot — the ip /
# netmask / gateway fields above become optional in that case
# (DHCP supplies them). On DHCP failure the kernel halts with
# panic pattern D (`─··`) so a misconfigured server is loud, not
# silent. The two modes are mutually exclusive — there is no
# static fallback. Default "no" preserves the static-only behavior
# this file shipped before the DHCP client landed.
dhcp=no
EOF

# --testrig: replace the placeholder ip / gateway with the standard
# hw_test wiring (Pi 4 at 10.0.0.2 on 10.0.0.0/24, laptop gateway
# at 10.0.0.1, hostname=wspi5). Hostname is already wspi5 in the
# default — no edit needed there. This keeps the dev iteration
# friction-free without affecting release SDs (no flag → placeholders
# fail loudly at boot per the original D013 design).
if (( TESTRIG == 1 )); then
    sed -i 's/^ip=0\.0\.0\.0/ip=10.0.0.2/' "$BUNDLE_DIR/network.conf"
    sed -i 's/^gateway=0\.0\.0\.0/gateway=10.0.0.1/' "$BUNDLE_DIR/network.conf"
    echo "mk_sd: --testrig applied (ip=10.0.0.2, gateway=10.0.0.1)"
fi

# Lint network.conf if one is present in the bundle (D012: linter is
# the executable spec). Today this is a no-op — the default
# network.conf isn't shipped yet (I3). Once it is, AND for any
# future flow that drops a user-supplied network.conf into the
# bundle dir before this line, the lint catches malformed configs
# at build time rather than at first boot. Hard-fail on lint
# error: shipping an SD image with an invalid config means a Pi
# that won't boot for the user.
if [[ -f "$BUNDLE_DIR/network.conf" ]]; then
    if [[ -x "$PROJECT_DIR/.venv/bin/python" ]]; then
        LINT_PY="$PROJECT_DIR/.venv/bin/python"
    else
        LINT_PY="python3"
    fi
    echo "mk_sd: linting $BUNDLE_DIR/network.conf"
    if ! "$LINT_PY" "$PROJECT_DIR/scripts/lint_network_conf.py" \
            --quiet "$BUNDLE_DIR/network.conf"; then
        echo "mk_sd: network.conf failed lint — refusing to ship the SD image" >&2
        echo "       (fix the file and re-run; see D003/D006 for format rules)" >&2
        exit 1
    fi
fi

if [[ "$MODE" == "image" ]]; then
    python3 "$PROJECT_DIR/scripts/mk_sd_image.py" "$BUNDLE_DIR" "$TARGET"
else
    echo "mk_sd: SD boot bundle in $TARGET/"
    ls -lh "$TARGET/"
    echo
    echo "Flash: mount the FAT32 boot partition of a fresh Pi 4 SD card and"
    echo "  cp -r $TARGET/* /media/<user>/boot/"
fi
