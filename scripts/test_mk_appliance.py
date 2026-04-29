"""Unit tests for scripts/mk_appliance.py."""

from __future__ import annotations

import struct
import sys
from pathlib import Path

import pytest

import mk_appliance as M


def test_content_type_known_extensions() -> None:
    assert M.content_type_for(".html") == "text/html; charset=utf-8"
    assert M.content_type_for(".css") == "text/css"
    assert M.content_type_for(".png") == "image/png"


def test_content_type_case_insensitive() -> None:
    assert M.content_type_for(".HTML") == "text/html; charset=utf-8"


def test_content_type_unknown_fallback() -> None:
    assert M.content_type_for(".xyz") == "application/octet-stream"


def test_build_header_structure() -> None:
    hdr = M.build_header(42, "text/plain")
    assert hdr.startswith(b"HTTP/1.1 200 OK\r\n")
    assert b"Content-Type: text/plain\r\n" in hdr
    assert b"Content-Length: 42\r\n" in hdr
    assert hdr.endswith(b"\r\n\r\n")


def test_find_slab_offset_happy() -> None:
    prefix = b"prefix-bytes"
    suffix_pad = b"\x00" * M.APPLIANCE_SLAB_SIZE
    image = prefix + M.MAGIC_NONE + suffix_pad
    assert M.find_slab_offset(image) == len(prefix)


def test_find_slab_offset_missing() -> None:
    with pytest.raises(ValueError, match="not found"):
        M.find_slab_offset(b"no marker here")


def test_find_slab_offset_duplicate() -> None:
    # Embed both markers in an image large enough that truncation isn't
    # what trips — we want the duplicate check, not the size check.
    image = (
        M.MAGIC_NONE
        + b"\x00" * M.APPLIANCE_SLAB_SIZE
        + M.MAGIC_NONE
        + b"\x00" * M.APPLIANCE_SLAB_SIZE
    )
    with pytest.raises(ValueError, match="more than once"):
        M.find_slab_offset(image)


def test_find_slab_offset_truncated() -> None:
    # Marker is present but the remaining image is too short to hold
    # the full slab — silent bytearray-extension would corrupt the
    # output; we want a loud ValueError instead.
    image = b"pad" + M.MAGIC_NONE + b"\x00" * 16
    with pytest.raises(ValueError, match="truncated"):
        M.find_slab_offset(image)


def _make_route(path: str, body: bytes, mime: str = "text/html") -> M.Route:
    return M.Route(path=path, body=body, mime=mime)


def test_build_slab_single_route_layout() -> None:
    route = _make_route("/hello", b"Hi!", mime="text/plain")
    slab = M.build_slab([route])
    assert len(slab) == M.APPLIANCE_SLAB_SIZE
    assert slab[:8] == M.MAGIC_V1
    assert struct.unpack_from("<I", slab, M.HDR_VERSION)[0] == M.VERSION_V1
    assert struct.unpack_from("<I", slab, M.HDR_RCOUNT)[0] == 1
    # Route entry fields
    entry = M.APPLIANCE_ROUTES_OFF
    assert struct.unpack_from(
        "<I", slab, entry + M.ROUTE_PATH_LEN)[0] == len(b"/hello")
    assert struct.unpack_from(
        "<I", slab, entry + M.ROUTE_BODY_LEN)[0] == len(b"Hi!")
    assert slab[entry + M.ROUTE_FLAGS] == 0
    assert slab[entry + M.ROUTE_METHODS] == M.HM_GET | M.HM_HEAD
    # ROUTE_HANDLER must be zero for static routes
    assert struct.unpack_from("<Q", slab, entry + M.ROUTE_HANDLER)[0] == 0
    # HDR_PTR / HDR_LEN must point at a valid response header in content
    hdr_off = struct.unpack_from("<Q", slab, entry + M.ROUTE_HDR_PTR)[0]
    hdr_len = struct.unpack_from("<I", slab, entry + M.ROUTE_HDR_LEN)[0]
    cbase = M.APPLIANCE_CONTENT_OFF
    hdr_bytes = slab[cbase + hdr_off:cbase + hdr_off + hdr_len]
    assert hdr_bytes == M.build_header(len(b"Hi!"), "text/plain")


def test_build_slab_path_and_body_land_in_content() -> None:
    route = _make_route("/page", b"<html></html>", mime="text/html")
    slab = M.build_slab([route])
    entry = M.APPLIANCE_ROUTES_OFF
    path_off = struct.unpack_from("<Q", slab, entry + M.ROUTE_PATH_PTR)[0]
    body_off = struct.unpack_from("<Q", slab, entry + M.ROUTE_BODY_PTR)[0]
    path_len = struct.unpack_from("<I", slab, entry + M.ROUTE_PATH_LEN)[0]
    body_len = struct.unpack_from("<I", slab, entry + M.ROUTE_BODY_LEN)[0]
    cbase = M.APPLIANCE_CONTENT_OFF
    assert slab[cbase + path_off:cbase + path_off + path_len] == b"/page"
    body_bytes = slab[cbase + body_off:cbase + body_off + body_len]
    assert body_bytes == b"<html></html>"


def test_build_slab_too_many_routes() -> None:
    routes = [
        _make_route(f"/r{i}", b"x")
        for i in range(M.APPLIANCE_MAX_ROUTES + 1)
    ]
    with pytest.raises(ValueError, match="APPLIANCE_MAX_ROUTES"):
        M.build_slab(routes)


def test_build_slab_content_overflow() -> None:
    # Each route contributes path + header + body. A single huge body
    # that exceeds APPLIANCE_CONTENT_MAX must be rejected.
    big = b"x" * (M.APPLIANCE_CONTENT_MAX + 1)
    with pytest.raises(ValueError, match="content region"):
        M.build_slab([_make_route("/big", big)])


def test_build_slab_path_too_long() -> None:
    # Path length > MAX_PATH_BYTES must raise, regardless of content
    # budget. Pin the exact branch so an off-by-one (> vs >=) is caught.
    long_path = "/" + "a" * M.MAX_PATH_BYTES
    with pytest.raises(ValueError, match="MAX_PATH_BYTES"):
        M.build_slab([_make_route(long_path, b"x")])


def test_collect_routes_skips_symlinks(tmp_path: Path) -> None:
    """A symlink to a file outside public_dir must NOT end up packaged."""
    outside = tmp_path / "secret.txt"
    outside.write_bytes(b"SECRET")
    public = tmp_path / "public"
    public.mkdir()
    (public / "index.html").write_bytes(b"hi")
    (public / "leak.txt").symlink_to(outside)
    routes = M.collect_routes(public)
    paths = {r.path for r in routes}
    assert "/leak.txt" not in paths
    assert all(b"SECRET" not in r.body for r in routes)


def test_collect_routes_skips_dotfiles(tmp_path: Path) -> None:
    """Dotfiles like .DS_Store / .git contents must not get packaged."""
    (tmp_path / ".DS_Store").write_bytes(b"junk")
    git_dir = tmp_path / ".git"
    git_dir.mkdir()
    (git_dir / "HEAD").write_bytes(b"ref: refs/heads/main")
    (tmp_path / "page.html").write_bytes(b"<p>ok</p>")
    routes = M.collect_routes(tmp_path)
    paths = {r.path for r in routes}
    assert paths == {"/page.html"}


def _make_placeholder_slab(ksize: int = M.APPLIANCE_SLAB_SIZE) -> bytes:
    """Build an unpackaged WSPINONE slab with the HDR_KSIZE field
    populated. Tests use this to stand in for a linked kernel's
    placeholder when they don't care about any other header bytes."""
    slab = bytearray(M.APPLIANCE_SLAB_SIZE)
    slab[:8] = M.MAGIC_NONE
    struct.pack_into("<I", slab, M.HDR_KSIZE, ksize)
    return bytes(slab)


def test_package_empty_dir_warns(
    tmp_path: Path, capsys: pytest.CaptureFixture[str],
) -> None:
    """Empty public_dir must still produce rc=0 and warn on stderr."""
    kernel_path = tmp_path / "kernel.img"
    kernel_path.write_bytes(_make_placeholder_slab())
    public = tmp_path / "empty"
    public.mkdir()
    output = tmp_path / "out.img"
    rc = M.package(kernel_path, public, output)
    assert rc == 0
    assert "zero routes" in capsys.readouterr().err
    # Slab still activates (rcount=0) — routes list is empty but the
    # image is fully valid for the kernel to consume.
    slab = output.read_bytes()[:M.APPLIANCE_SLAB_SIZE]
    assert slab[:8] == M.MAGIC_V1
    assert struct.unpack_from("<I", slab, M.HDR_RCOUNT)[0] == 0


def test_collect_routes_basic(tmp_path: Path) -> None:
    (tmp_path / "index.html").write_bytes(b"<h1>home</h1>")
    (tmp_path / "style.css").write_bytes(b"body{color:red}")
    routes = M.collect_routes(tmp_path)
    paths = {r.path for r in routes}
    # index.html expands to both /index.html AND /
    assert "/index.html" in paths
    assert "/" in paths
    assert "/style.css" in paths
    # CSS MIME type applied
    css = next(r for r in routes if r.path == "/style.css")
    assert css.mime == "text/css"


def test_package_end_to_end(tmp_path: Path) -> None:
    """Stub a kernel image with the marker, package, verify slab lands.

    package() truncates the output after the last used content byte
    (firmware only loads what's there; the unused slab tail is dead
    weight on disk). So pre-slab bytes survive but post-slab filler
    does NOT — leaving `post` in the input image is the test for
    "truncation actually happened."
    """
    kernel_path = tmp_path / "kernel.img"
    # Pre-marker filler, marker-padded slab region, post-marker filler.
    pre = b"\xAA" * 128
    post = b"\xBB" * 128
    kernel_path.write_bytes(pre + _make_placeholder_slab() + post)

    public = tmp_path / "public"
    public.mkdir()
    (public / "index.html").write_bytes(b"<html>hi</html>")

    output = tmp_path / "out.img"
    rc = M.package(kernel_path, public, output)
    assert rc == 0

    out_bytes = output.read_bytes()
    # Pre-slab bytes survive verbatim.
    assert out_bytes[:128] == pre
    # Post-slab filler must NOT survive — and the output as a whole
    # must be shorter than the full pre+slab+post input, proving
    # truncation occurred. With a 256 MiB slab cap and only ~25 KiB
    # of real routes, the output should be vastly smaller than
    # 128 + APPLIANCE_SLAB_SIZE + 128.
    assert len(out_bytes) < 128 + M.APPLIANCE_SLAB_SIZE
    # Slab region runs from offset 128 to end of file (truncated).
    slab_out = out_bytes[128:]
    assert slab_out[:8] == M.MAGIC_V1
    # rcount should be 2 (/index.html + /)
    rcount = struct.unpack_from("<I", slab_out, M.HDR_RCOUNT)[0]
    assert rcount == 2
    # Route bodies must be reachable via the packaged offsets — a bug
    # that zeroed pointers during write would pass an rcount check but
    # fail this one.
    cbase = M.APPLIANCE_CONTENT_OFF
    expected_paths = set()
    for idx in range(rcount):
        entry = M.APPLIANCE_ROUTES_OFF + idx * M.ROUTE_SIZE
        p_off = struct.unpack_from(
            "<Q", slab_out, entry + M.ROUTE_PATH_PTR)[0]
        p_len = struct.unpack_from(
            "<I", slab_out, entry + M.ROUTE_PATH_LEN)[0]
        b_off = struct.unpack_from(
            "<Q", slab_out, entry + M.ROUTE_BODY_PTR)[0]
        b_len = struct.unpack_from(
            "<I", slab_out, entry + M.ROUTE_BODY_LEN)[0]
        path_bytes = slab_out[cbase + p_off:cbase + p_off + p_len]
        body_bytes = slab_out[cbase + b_off:cbase + b_off + b_len]
        expected_paths.add(path_bytes.decode("ascii"))
        assert body_bytes == b"<html>hi</html>"
    assert expected_paths == {"/index.html", "/"}


def test_main_rejects_missing_kernel(
    tmp_path: Path, capsys: pytest.CaptureFixture[str],
) -> None:
    argv = sys.argv
    sys.argv = [
        "mk_appliance",
        str(tmp_path / "nonexistent.img"),
        str(tmp_path),
        str(tmp_path / "out.img"),
    ]
    try:
        rc = M.main()
    finally:
        sys.argv = argv
    assert rc == 1
    assert "not a file" in capsys.readouterr().err


def test_main_rejects_missing_public(
    tmp_path: Path, capsys: pytest.CaptureFixture[str],
) -> None:
    kernel = tmp_path / "kernel.img"
    kernel.write_bytes(M.MAGIC_NONE + b"\x00" * (M.APPLIANCE_SLAB_SIZE - 8))
    argv = sys.argv
    sys.argv = [
        "mk_appliance",
        str(kernel),
        str(tmp_path / "nonexistent_dir"),
        str(tmp_path / "out.img"),
    ]
    try:
        rc = M.main()
    finally:
        sys.argv = argv
    assert rc == 1
    assert "not a directory" in capsys.readouterr().err


def test_package_rejects_ksize_mismatch(tmp_path: Path) -> None:
    """If the kernel's HDR_KSIZE doesn't match the packager's
    APPLIANCE_SLAB_SIZE, package() must refuse to write — otherwise a
    packager with drifted constants would over-write adjacent kernel
    code or leave the placeholder tail uninitialized."""
    kernel_path = tmp_path / "kernel.img"
    # Write a placeholder claiming a kernel slab 8 bytes smaller than
    # the packager's expected size. Any value != APPLIANCE_SLAB_SIZE
    # should trip the check; the exact delta doesn't matter.
    bogus_ksize = M.APPLIANCE_SLAB_SIZE - 8
    kernel_path.write_bytes(_make_placeholder_slab(ksize=bogus_ksize))
    public = tmp_path / "public"
    public.mkdir()
    output = tmp_path / "out.img"
    with pytest.raises(ValueError, match="slab-size mismatch"):
        M.package(kernel_path, public, output)
    assert not output.exists()
