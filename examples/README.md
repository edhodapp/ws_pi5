# examples/public/ — starter site

A minimal static site you can package into a bootable appliance image
to verify the end-to-end flow on a real Pi 4 before putting your own
content in.

## Contents

- `index.html` — landing page the appliance serves at `/` and
  `/index.html` (the packager aliases top-level index.html to the
  document root).
- `about.html` — served at `/about.html`.
- `style.css` — served at `/style.css` with `Content-Type: text/css`.

## Package and boot

From the repo root:

```
make PLATFORM=pi4
scripts/mk_appliance.py kernel8.img examples/public/ appliance.img
scripts/mk_sd.sh appliance.img sd_boot/
# Flash sd_boot/ onto a FAT32 Pi 4 SD card, boot the Pi.
```

Or build a full disk image for one-shot SD flashing (requires mtools):

```
scripts/mk_sd.sh --image appliance.img out.img
# Flash out.img with Raspberry Pi Imager / balenaEtcher / dd.
```

Your own site drops straight into the same flow — swap
`examples/public/` for any directory of static files.
