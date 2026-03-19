#!/usr/bin/env bash
# hw_test/deploy.sh — copy kernel8.img to TFTP directory (runs on Chromebook)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/config.sh"

KERNEL="$PROJECT_DIR/kernel8.img"

if [ ! -f "$KERNEL" ]; then
    echo "ERROR: $KERNEL not found. Run 'make' first."
    exit 1
fi

cp "$KERNEL" "$TFTP_DIR/kernel8.img"
echo "Deployed kernel8.img to $TFTP_DIR/kernel8.img at $(date '+%Y-%m-%d %H:%M:%S')"
