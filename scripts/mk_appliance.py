#!/usr/bin/env python3
"""Package a directory of static files into a ws_pi5 appliance kernel.

Takes a base kernel8.img (with an unpatched WSPINONE slab) and a
directory of HTML/CSS/image files, and emits a new kernel image whose
embedded appliance slab is populated with routes + content. The
running kernel's http_appliance_init detects the WSPIAPLI magic on
boot, walks the route entries patching offsets into absolute pointers,
and flips the route dispatcher to use the packaged routes.

Minimum-viable scope for this first landing:
  - static-only routes (ROUTE_FLAGS = 0, ROUTE_HANDLER = 0)
  - MIME type derived from file extension
  - GET + HEAD allowed on every route
  - index.html special-cased to also be served at "/"

Usage:
    python3 mk_appliance.py <base.img> <public_dir> <output.img>
"""

from __future__ import annotations

import argparse
import struct
import sys
from dataclasses import dataclass
from pathlib import Path

# ---------------------------------------------------------------------------
# Binary layout — mirror of include/http.inc. Any change to the runtime
# slab layout must be reflected here.
# ---------------------------------------------------------------------------

MAGIC_NONE = b"WSPINONE"
MAGIC_V1 = b"WSPIAPLI"
VERSION_V1 = 1

APPLIANCE_HDR_SIZE = 24
APPLIANCE_ROUTES_OFF = 24
APPLIANCE_MAX_ROUTES = 512
ROUTE_SIZE = 48
APPLIANCE_ROUTES_SIZE = APPLIANCE_MAX_ROUTES * ROUTE_SIZE
APPLIANCE_CONTENT_OFF = APPLIANCE_ROUTES_OFF + APPLIANCE_ROUTES_SIZE
APPLIANCE_CONTENT_MAX = 256 * 1024 * 1024
APPLIANCE_SLAB_SIZE = APPLIANCE_CONTENT_OFF + APPLIANCE_CONTENT_MAX

# Header field offsets
HDR_MAGIC = 0
HDR_VERSION = 8
HDR_RCOUNT = 12
HDR_CLEN = 16
HDR_KSIZE = 20    # u32 — kernel's compile-time APPLIANCE_SLAB_SIZE

# Route entry field offsets
ROUTE_PATH_LEN = 0
ROUTE_BODY_LEN = 4
ROUTE_PATH_PTR = 8
ROUTE_BODY_PTR = 16
ROUTE_HDR_PTR = 24
ROUTE_HDR_LEN = 32
ROUTE_FLAGS = 36
ROUTE_METHODS = 37
# bytes 38-39 pad
ROUTE_HANDLER = 40

# Method bitmask values
HM_GET = 0x01
HM_HEAD = 0x02

# Path length cap for a single route entry (u32 field; practical
# ceiling is far lower because long paths also consume content budget).
MAX_PATH_BYTES = 1024

# Extension → MIME type. Extensions not in this map fall back to the
# generic binary type rather than guessing.
MIME_TYPES: dict[str, str] = {
    ".html": "text/html; charset=utf-8",
    ".htm": "text/html; charset=utf-8",
    ".css": "text/css",
    ".js": "application/javascript",
    ".json": "application/json",
    ".txt": "text/plain; charset=utf-8",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".gif": "image/gif",
    ".svg": "image/svg+xml",
    ".ico": "image/x-icon",
    ".webp": "image/webp",
}


@dataclass(frozen=True)
class Route:
    """One packaged route ready for slab emission."""
    path: str
    body: bytes
    mime: str


def content_type_for(suffix: str) -> str:
    """MIME type for a file extension, octet-stream fallback."""
    return MIME_TYPES.get(suffix.lower(), "application/octet-stream")


def build_header(body_len: int, mime: str) -> bytes:
    """Construct a static HTTP/1.1 200 response header template.

    Embeds Content-Type and Content-Length for the body; no Date field
    because the packaged slab is immutable (the runtime can layer a
    Date-update step on top later if needed).
    """
    return (
        f"HTTP/1.1 200 OK\r\n"
        f"Server: ws_pi5\r\n"
        f"Content-Type: {mime}\r\n"
        f"Content-Length: {body_len}\r\n"
        f"\r\n"
    ).encode("ascii")


def collect_routes(public_dir: Path) -> list[Route]:
    """Walk public_dir and build a Route for every regular file.

    Paths are rooted at "/" with forward slashes regardless of host OS.
    A top-level index.html produces both /index.html and / so a site's
    landing page is reachable at the document root — nested index.html
    files are served at their literal path only.

    Symlinks are skipped: rglob otherwise follows them, and a symlink
    to /etc/passwd inside public_dir would end up packaged into the
    kernel image. Only regular files that live inside the tree are
    allowed. Hidden files (dotfiles) are also skipped to avoid
    accidentally publishing .git, .DS_Store, editor swap files, etc.
    """
    routes: list[Route] = []
    for path in sorted(public_dir.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        rel = path.relative_to(public_dir).as_posix()
        if any(part.startswith(".") for part in rel.split("/")):
            continue
        body = path.read_bytes()
        mime = content_type_for(path.suffix)
        routes.append(Route(path="/" + rel, body=body, mime=mime))
        if rel == "index.html":
            routes.append(Route(path="/", body=body, mime=mime))
    return routes


def _emit_route_entry(
    slab: bytearray, idx: int,
    path_off: int, path_len: int,
    body_off: int, body_len: int,
    hdr_off: int, hdr_len: int,
) -> None:
    """Write a 48-byte route entry at slot idx."""
    entry = APPLIANCE_ROUTES_OFF + idx * ROUTE_SIZE
    struct.pack_into("<II", slab, entry + ROUTE_PATH_LEN, path_len, body_len)
    struct.pack_into("<Q", slab, entry + ROUTE_PATH_PTR, path_off)
    struct.pack_into("<Q", slab, entry + ROUTE_BODY_PTR, body_off)
    struct.pack_into("<Q", slab, entry + ROUTE_HDR_PTR, hdr_off)
    struct.pack_into("<I", slab, entry + ROUTE_HDR_LEN, hdr_len)
    slab[entry + ROUTE_FLAGS] = 0
    slab[entry + ROUTE_METHODS] = HM_GET | HM_HEAD
    # ROUTE_HANDLER stays zero — static route, no handler function.


def build_slab(routes: list[Route]) -> bytes:
    """Serialize routes + content into a fixed-size slab.

    Raises ValueError if too many routes or content exceeds budget.
    """
    if len(routes) > APPLIANCE_MAX_ROUTES:
        raise ValueError(
            f"{len(routes)} routes exceeds APPLIANCE_MAX_ROUTES="
            f"{APPLIANCE_MAX_ROUTES}"
        )

    slab = bytearray(APPLIANCE_SLAB_SIZE)
    slab[HDR_MAGIC:HDR_MAGIC + 8] = MAGIC_V1
    struct.pack_into("<I", slab, HDR_VERSION, VERSION_V1)
    struct.pack_into("<I", slab, HDR_RCOUNT, len(routes))

    content = bytearray()
    for idx, route in enumerate(routes):
        path_bytes = route.path.encode("ascii")
        if len(path_bytes) > MAX_PATH_BYTES:
            raise ValueError(
                f"path {route.path!r} exceeds MAX_PATH_BYTES="
                f"{MAX_PATH_BYTES}"
            )
        hdr_bytes = build_header(len(route.body), route.mime)

        path_off = len(content)
        content.extend(path_bytes)
        hdr_off = len(content)
        content.extend(hdr_bytes)
        body_off = len(content)
        content.extend(route.body)

        _emit_route_entry(
            slab, idx,
            path_off, len(path_bytes),
            body_off, len(route.body),
            hdr_off, len(hdr_bytes),
        )

    if len(content) > APPLIANCE_CONTENT_MAX:
        raise ValueError(
            f"content region {len(content)} B exceeds "
            f"APPLIANCE_CONTENT_MAX={APPLIANCE_CONTENT_MAX}"
        )

    struct.pack_into("<I", slab, HDR_CLEN, len(content))
    slab[APPLIANCE_CONTENT_OFF:APPLIANCE_CONTENT_OFF + len(content)] = content
    return bytes(slab)


def find_slab_offset(image: bytes) -> int:
    """Locate the WSPINONE marker in a base kernel image.

    Raises ValueError if the marker is absent, appears more than once,
    or the full slab would not fit inside the image. Catching truncation
    here matters because bytearray slice assignment silently extends the
    container, turning a corrupt input into a corrupt output instead of
    a loud failure.
    """
    off = image.find(MAGIC_NONE)
    if off < 0:
        raise ValueError(
            "WSPINONE marker not found — is this the right kernel image?"
        )
    if image.find(MAGIC_NONE, off + 1) >= 0:
        raise ValueError("WSPINONE appears more than once — ambiguous slab")
    if off + APPLIANCE_SLAB_SIZE > len(image):
        raise ValueError(
            f"image truncated: slab starts at {off} but image is only "
            f"{len(image)} B (need {APPLIANCE_SLAB_SIZE})"
        )
    return off


def verify_kernel_ksize(image: bytes, slab_off: int) -> None:
    """Bail loudly if the packager's APPLIANCE_SLAB_SIZE doesn't match
    the kernel's.

    The kernel bakes its own APPLIANCE_SLAB_SIZE into the placeholder
    header's HDR_KSIZE u32 at build time. If this packager's Python
    constants drift from include/http.inc, we'd either write past the
    placeholder into adjacent kernel code (packager slab larger) or
    leave the tail of the placeholder full of whatever was there
    before (packager slab smaller, kernel reads uninitialized bytes
    as route entries at boot). Either failure mode is silent and ugly;
    catching it here turns mismatch into a clear error.
    """
    kernel_ksize = struct.unpack_from("<I", image, slab_off + HDR_KSIZE)[0]
    if kernel_ksize != APPLIANCE_SLAB_SIZE:
        raise ValueError(
            "kernel/packager slab-size mismatch — rebuild the kernel "
            "with matching include/http.inc, or update the Python "
            "constants in this script.\n"
            f"  kernel APPLIANCE_SLAB_SIZE  = {kernel_ksize} B\n"
            f"  packager APPLIANCE_SLAB_SIZE = {APPLIANCE_SLAB_SIZE} B"
        )


def package(
    kernel_path: Path, public_dir: Path, output_path: Path,
) -> int:
    """Produce a packaged appliance image. Returns 0 on success."""
    image = kernel_path.read_bytes()
    slab_off = find_slab_offset(image)
    verify_kernel_ksize(image, slab_off)
    routes = collect_routes(public_dir)
    if not routes:
        print(
            f"  warning: no files under {public_dir} — resulting image "
            "will have zero routes and serve only 404s",
            file=sys.stderr,
        )
    slab = build_slab(routes)

    new_image = bytearray(image)
    new_image[slab_off:slab_off + APPLIANCE_SLAB_SIZE] = slab
    output_path.write_bytes(bytes(new_image))

    print(f"  packaged {len(routes)} route(s) → {output_path}")
    for route in routes:
        print(f"    {route.path}  ({len(route.body)} B, {route.mime})")
    return 0


def main() -> int:
    """CLI entry point."""
    parser = argparse.ArgumentParser(
        description=(
            "Package static files into a ws_pi5 appliance kernel image."
        ),
    )
    parser.add_argument("kernel", type=Path, help="base kernel8.img")
    parser.add_argument(
        "public", type=Path,
        help="directory of HTML/CSS/image files to package",
    )
    parser.add_argument(
        "output", type=Path,
        help="path for the packaged appliance image",
    )
    parser.add_argument(
        "--content-max", type=int, default=None,
        help=(
            "override APPLIANCE_CONTENT_MAX in bytes — must match the "
            "`make CONTENT_MAX=<bytes>` value the kernel was built "
            "with. The HDR_KSIZE cross-check aborts the packager on "
            "mismatch so a forgotten flag fails loudly."
        ),
    )
    parser.add_argument(
        "--max-routes", type=int, default=None,
        help=(
            "override APPLIANCE_MAX_ROUTES — must match the kernel's "
            "`make MAX_ROUTES=<n>` value."
        ),
    )
    args = parser.parse_args()

    if not args.kernel.is_file():
        print(f"  error: {args.kernel} is not a file", file=sys.stderr)
        return 1
    if not args.public.is_dir():
        print(f"  error: {args.public} is not a directory", file=sys.stderr)
        return 1

    # Override sizing constants at runtime if the user passed values
    # that differ from the kernel's compiled-in defaults. The globals
    # feed the rest of the module (build_slab, collect_routes, etc.)
    # so touching them here is enough.
    global APPLIANCE_CONTENT_MAX, APPLIANCE_MAX_ROUTES  # noqa: PLW0603
    global APPLIANCE_ROUTES_SIZE, APPLIANCE_CONTENT_OFF, APPLIANCE_SLAB_SIZE
    if args.max_routes is not None:
        APPLIANCE_MAX_ROUTES = args.max_routes
        APPLIANCE_ROUTES_SIZE = APPLIANCE_MAX_ROUTES * ROUTE_SIZE
        APPLIANCE_CONTENT_OFF = APPLIANCE_ROUTES_OFF + APPLIANCE_ROUTES_SIZE
    if args.content_max is not None:
        APPLIANCE_CONTENT_MAX = args.content_max
    APPLIANCE_SLAB_SIZE = APPLIANCE_CONTENT_OFF + APPLIANCE_CONTENT_MAX

    return package(args.kernel, args.public, args.output)


if __name__ == "__main__":
    sys.exit(main())
