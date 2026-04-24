"""Build a bootable Pi 4 SD disk image from an assembled SD bundle dir.

Input: a directory produced by `scripts/mk_sd.sh` (config.txt,
kernel8.img, start4.elf, fixup4.dat, bcm2711-rpi-4-b.dtb).

Output: a raw disk image with an MBR + a single FAT32 partition
containing those files. Users flash the raw image with any standard
SD-writing tool (Raspberry Pi Imager, balenaEtcher, dd).

Cross-platform requirements: `mformat` and `mcopy` from the mtools
package (Linux: apt install mtools; macOS: brew install mtools;
Windows: WSL or chocolatey). The MBR + partition table is written
directly in Python so no disk-level utilities (fdisk, parted,
losetup, sudo) are needed.

Usage::

    python3 scripts/mk_sd_image.py <bundle_dir> <output_image>
"""

from __future__ import annotations

import os
import shutil
import struct
import subprocess
import sys
from pathlib import Path

# MBR / partition-table layout. Standard values — 512-byte sectors,
# 63 sectors per track, 255 heads (legacy CHS geometry).
SECTOR = 512
PART_OFFSET_SECTORS = 2048      # 1 MiB aligned; universal convention
# 8 MiB is plenty for the bundle (~2.4 MB today). Round up in
# computed_image_size() based on actual bundle size.
MIN_PART_MB = 8
SLACK_MB = 4
PART_TYPE_FAT32_LBA = 0x0C
MBR_BOOT_SIG = 0xAA55


def die(msg: str) -> None:
    print(f"mk_sd_image: {msg}", file=sys.stderr)
    sys.exit(1)


def check_mtools() -> None:
    for tool in ("mformat", "mcopy"):
        if shutil.which(tool) is None:
            die(
                f"{tool} not found on PATH — install mtools "
                "(apt install mtools / brew install mtools / etc.)"
            )


def bundle_size_bytes(bundle_dir: Path) -> int:
    """Sum of bundle file sizes. Rough — doesn't account for FAT
    overhead, but the MIN_PART_MB + SLACK_MB padding covers it."""
    total = 0
    for path in bundle_dir.iterdir():
        if path.is_file():
            total += path.stat().st_size
    return total


def computed_image_size_mb(bundle_dir: Path) -> int:
    """Pick an image size with enough slack for FAT overhead."""
    content_mb = (bundle_size_bytes(bundle_dir) + (1 << 20) - 1) // (1 << 20)
    return max(MIN_PART_MB, content_mb + SLACK_MB)


def write_mbr(
    image_path: Path, part_offset_sectors: int, part_size_sectors: int,
) -> None:
    """Overwrite bytes 0..512 of the image with an MBR containing one
    active FAT32 partition. Pure struct — no fdisk needed."""
    # Partition entry layout (16 bytes), little-endian:
    #   status (u8), start_chs (3 bytes), type (u8), end_chs (3 bytes),
    #   start_lba (u32), num_sectors (u32)
    # CHS fields are obsolete for modern firmware but fdisk-style
    # tools still sanity-check them. Use 0xFE,0xFF,0xFF (the
    # "unknown, use LBA" convention) to keep them happy.
    entry = struct.pack(
        "<B3sB3sII",
        0x80,                                # active/bootable
        bytes([0xFE, 0xFF, 0xFF]),
        PART_TYPE_FAT32_LBA,
        bytes([0xFE, 0xFF, 0xFF]),
        part_offset_sectors,
        part_size_sectors,
    )

    mbr = bytearray(SECTOR)
    # Bootstrap area (0..445) stays zero — no boot code; Pi firmware
    # only cares about the partition table.
    mbr[446:462] = entry
    # Slots 2, 3, 4 zero. Boot signature at 510-511.
    struct.pack_into("<H", mbr, 510, MBR_BOOT_SIG)

    with open(image_path, "r+b") as handle:
        handle.seek(0)
        handle.write(mbr)


def create_image(image_path: Path, size_mb: int) -> None:
    """Create a sparse image file of the requested size (bytes zeroed
    by truncate; filesystem writes allocate real blocks lazily)."""
    with open(image_path, "wb") as handle:
        handle.truncate(size_mb * (1 << 20))


def mformat_partition(image_path: Path, part_offset_sectors: int) -> None:
    """Format the partition inside the image as FAT32 via mtools."""
    target = f"{image_path}@@{part_offset_sectors * SECTOR}"
    # -F forces FAT32 regardless of auto-detection heuristics;
    # -v "boot" gives a recognizable volume label; -h/-s/-t zero
    # lets mformat compute geometry from the image size.
    subprocess.run(
        ["mformat", "-i", target, "-F", "-v", "BOOT", "::"],
        check=True,
    )


def mcopy_files(
    image_path: Path, part_offset_sectors: int, bundle_dir: Path,
) -> None:
    """Copy every regular file from bundle_dir into the FAT32 root."""
    target = f"{image_path}@@{part_offset_sectors * SECTOR}"
    files = sorted(
        str(p) for p in bundle_dir.iterdir() if p.is_file()
    )
    if not files:
        die(f"bundle dir {bundle_dir} is empty")
    # mcopy -s is recursive; -i selects the image. Pass each file as
    # a separate arg followed by the FAT destination ::.
    subprocess.run(
        ["mcopy", "-i", target, *files, "::"],
        check=True,
    )


def main() -> int:
    if len(sys.argv) != 3:
        print(
            f"usage: {sys.argv[0]} <bundle_dir> <output_image>",
            file=sys.stderr,
        )
        return 2

    bundle = Path(sys.argv[1])
    image = Path(sys.argv[2])

    if not bundle.is_dir():
        die(f"{bundle} is not a directory")

    check_mtools()

    size_mb = computed_image_size_mb(bundle)
    create_image(image, size_mb)

    # Partition spans from PART_OFFSET_SECTORS to end of image.
    total_sectors = size_mb * (1 << 20) // SECTOR
    part_sectors = total_sectors - PART_OFFSET_SECTORS
    if part_sectors <= 0:
        die("computed partition has 0 sectors — bundle too large?")

    mformat_partition(image, PART_OFFSET_SECTORS)
    mcopy_files(image, PART_OFFSET_SECTORS, bundle)
    write_mbr(image, PART_OFFSET_SECTORS, part_sectors)

    print(
        f"mk_sd_image: wrote {size_mb} MiB SD image to {image}"
        f" ({os.path.getsize(image)} B)"
    )
    print(
        "  flash with: Raspberry Pi Imager (Use custom) /"
        " balenaEtcher / `dd if=<image> of=/dev/sdX bs=4M conv=fsync`"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
