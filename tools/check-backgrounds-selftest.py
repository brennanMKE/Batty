#!/usr/bin/env python3
"""Offline cases for tools/check-backgrounds.py.

    python3 -I tools/check-backgrounds-selftest.py [path/to/check-backgrounds.py]

Builds small PNG/JPEG fixtures and catalogs in temporary folders. No sips, no
git, no network.
"""

import contextlib
import hashlib
import importlib.util
import io
import struct
import sys
import tempfile
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
target = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "check-backgrounds.py"
spec = importlib.util.spec_from_file_location("check_backgrounds", target)
cb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cb)

REAL_CATALOG = HERE.parent / "website" / "backgrounds" / "catalog.json"


def _chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def make_png_header(w, h):
    return cb.PNG_SIG + _chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0))


def make_png(w, h):
    raw = b"".join(b"\x00" + b"\x00" * w for _ in range(h))
    return make_png_header(w, h) + _chunk(b"IDAT", zlib.compress(raw)) + _chunk(b"IEND", b"")


def make_jpeg(w, h):
    app0 = b"\xff\xe0" + struct.pack(">H", 16) + b"JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
    sof = b"\xff\xc0" + struct.pack(">HBHHB", 11, 8, h, w, 1) + b"\x01\x11\x00"
    return b"\xff\xd8" + app0 + sof + b"\xff\xd9"


def build_root(d, *, ext_full="png", ext_thumb="png", hashes=True, override=None, files=None,
               full_size=(160, 100), thumb_size=(48, 30), mutate=None):
    """Two sets of two images. override(sets) edits the entries; files maps url -> bytes overrides."""
    d = Path(d)
    sets = []
    blobs = {}
    for s in ("alpha", "beta"):
        images = []
        for n in (1, 2):
            fu = f"{s}/0{n}-pic.{ext_full}"
            tu = f"{s}/0{n}-pic-thumb.{ext_thumb}"
            blobs[fu] = (make_png if ext_full == "png" else make_jpeg)(*full_size)
            blobs[tu] = (make_png if ext_thumb == "png" else make_jpeg)(*thumb_size)
            images.append({"id": f"{s}-0{n}", "title": f"Pic {n}",
                           "full": {"url": fu, "width": full_size[0], "height": full_size[1]},
                           "thumbnail": {"url": tu, "width": thumb_size[0], "height": thumb_size[1]}})
        sets.append({"id": s, "title": s.title(), "images": images})
    if files:
        blobs.update(files)
    if hashes:
        for st in sets:
            for im in st["images"]:
                for role in ("full", "thumbnail"):
                    b = blobs.get(im[role]["url"])
                    if b is not None:
                        im[role]["sha256"] = hashlib.sha256(b).hexdigest()
                        im[role]["bytes"] = len(b)
    top = {"schemaVersion": 1, "name": "Test Backgrounds", "updated": "2026-11-11"}
    if override:
        override(top, sets)
    for url, b in blobs.items():
        if b is None:
            continue
        p = d / url
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b)
    lines = ["{"]
    for k, v in top.items():
        lines.append(f'  {cb.json.dumps(k)}: {cb.json.dumps(v)},')
    lines.append('  "sets": [')
    for si, st in enumerate(sets):
        lines += ["    {", f'      "id": {cb.json.dumps(st["id"])},', f'      "title": {cb.json.dumps(st["title"])},',
                  '      "images": [']
        for ii, im in enumerate(st["images"]):
            lines.append(f'        {{ "id": {cb.json.dumps(im["id"])}, "title": {cb.json.dumps(im["title"])},')
            lines.append(f'          "full": {cb._render(im["full"])},')
            tail = " }" + ("," if ii < len(st["images"]) - 1 else "")
            lines.append(f'          "thumbnail": {cb._render(im["thumbnail"])}{tail}')
        lines += ["      ]", "    }" + ("," if si < len(sets) - 1 else "")]
    lines += ["  ]", "}"]
    cat = d / "catalog.json"
    cat.write_text("\n".join(lines) + "\n", encoding="utf-8")
    if mutate:
        mutate(d)
    return cat


def run(args):
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out):
            code = cb.main(args)
    except Exception as e:  # a crash is a failure, never an exit code
        return ("raised", f"{type(e).__name__}: {e}")
    return (code, out.getvalue())


results = []


def case(name, want_code, want_text=None, **kw):
    setup = kw.pop("setup", None)
    check = kw.pop("check", None)
    write = kw.pop("write", False)
    with tempfile.TemporaryDirectory() as d:
        cat = build_root(d, **kw)
        if setup:
            setup(Path(d))
        code, out = run((["--write"] if write else []) + [str(cat)])
        ok = code == want_code and (want_text is None or want_text in out)
        extra = ""
        if ok and check:
            extra = check(Path(d), out) or ""
            ok = not extra
        results.append((name, ok, f"got {code} {out.strip()[-300:]!r}{extra}; want {want_code} {want_text!r}"))


def set_field(fn):
    def override(top, sets):
        fn(top, sets)
    return override


def flip_byte(path):
    def m(d):
        p = d / path
        b = bytearray(p.read_bytes())
        b[-5] ^= 0xFF
        p.write_bytes(bytes(b))
    return m


case("good catalog passes", 0, "OK:")
case("good catalog with jpeg full and jpeg thumbnail passes", 0, "OK:", ext_full="jpg", ext_thumb="jpeg")
case("missing full-size file", 1, "(1 of 8 files missing)", setup=lambda d: (d / "alpha/01-pic.png").unlink())
case("missing thumbnail", 1, "missing file alpha/02-pic-thumb.png",
     setup=lambda d: (d / "alpha/02-pic-thumb.png").unlink())
case("wrong width in catalog", 1, "width 161 in catalog",
     override=set_field(lambda t, s: s[0]["images"][0]["full"].update(width=161, height=100)))
case("wrong height in file", 1, "height", files={"beta/01-pic.png": make_png(160, 99)}, hashes=True,
     thumb_size=(48, 30))
case("one byte changed in full-size image", 1, "sha256", mutate=flip_byte("alpha/01-pic.png"))
case("wrong bytes", 1, "bytes 1 in catalog",
     override=set_field(lambda t, s: s[0]["images"][0]["full"].update(bytes=1)))
case("sha256 missing without write", 1, "run with --write", hashes=False)
case("png data with jpg extension", 1, "not JPEG", ext_full="jpg", files={f"alpha/01-pic.jpg": make_png(160, 100)})
case("jpeg data with png extension", 1, "not PNG", files={"alpha/01-pic.png": make_jpeg(160, 100)})
case("not an image", 1, "not a PNG or JPEG", files={"alpha/01-pic.png": b"hello world, not an image"})
case("truncated jpeg has no SOF", 1, "not a PNG or JPEG", files={"alpha/01-pic.png": b"\xff\xd8\xff\xe0\x00"},
     ext_full="png")
case("duplicate set id", 1, "duplicate set id",
     override=set_field(lambda t, s: s[1].update(id="alpha")))
case("duplicate image id across sets", 1, "duplicate image id",
     override=set_field(lambda t, s: s[1]["images"][0].update(id="alpha-01")))
case("bad image id pattern", 1, ".id: must match",
     override=set_field(lambda t, s: s[0]["images"][0].update(id="Bad_ID")))


def outside_check(d, out):
    return " (outside file was named as missing/read)" if "secret" in out and "url" not in out else ""


case("dotdot url", 1, ".url: must not have empty, . or .. segments",
     override=set_field(lambda t, s: s[0]["images"][0]["full"].update(url="../outside.png")), check=outside_check)
case("absolute path url", 1, ".url:",
     override=set_field(lambda t, s: s[0]["images"][0]["full"].update(url="/etc/passwd.png")))
case("https url in built-in catalog", 1, "must be relative",
     override=set_field(lambda t, s: s[0]["images"][0]["full"].update(url="https://example.com/a.png")))
case("unsupported extension", 1, "must end in .png",
     override=set_field(lambda t, s: s[0]["images"][0]["full"].update(url="alpha/01-pic.gif")))
case("orphan png", 1, "orphan file alpha/extra.png", setup=lambda d: (d / "alpha/extra.png").write_bytes(make_png(4, 4)))
case("orphan non-image file", 1, "orphan file notes.txt", setup=lambda d: (d / "notes.txt").write_text("x"))
case("hidden file is not an orphan", 0, "OK:", setup=lambda d: (d / "alpha/.DS_Store").write_bytes(b"\x00"))
case("thumbnail aspect mismatch", 1, "aspect", thumb_size=(48, 48))
case("thumbnail longer than 1024", 1, "over 1024", thumb_size=(1600, 1000), full_size=(1600, 1000))
case("full wider than 4096", 1, "over 4096", full_size=(5000, 3125), thumb_size=(48, 30),
     files={f"{s}/0{n}-pic.png": make_png_header(5000, 3125) for s in ("alpha", "beta") for n in (1, 2)})

saved = cb.FULL_MAX_BYTES
cb.FULL_MAX_BYTES = 10
try:
    case("full over byte limit", 1, "byte limit")
finally:
    cb.FULL_MAX_BYTES = saved

case("schemaVersion 2", 1, "schemaVersion", override=set_field(lambda t, s: t.update(schemaVersion=2)))
case("bool width rejected", 1, "width: must be a positive integer",
     override=set_field(lambda t, s: s[0]["images"][0]["full"].update(width=True)))
case("missing name", 1, "name", override=set_field(lambda t, s: t.pop("name")))
case("invalid json", 1, "catalog:", mutate=lambda d: (d / "catalog.json").write_text("{ not json"))


def hashes_match(d, out):
    cat = cb.json.loads((d / "catalog.json").read_text())
    for st in cat["sets"]:
        for im in st["images"]:
            for role in ("full", "thumbnail"):
                f = im[role]
                b = (d / f["url"]).read_bytes()
                if f.get("sha256") != hashlib.sha256(b).hexdigest() or f.get("bytes") != len(b):
                    return f" (wrong values for {f['url']})"
    return ""


case("write fills sha256 and bytes then passes", 0, "OK:", hashes=False, write=True, check=hashes_match)

before_text = {}


def keep_format_check(d, out):
    after = (d / "catalog.json").read_text().splitlines()
    before = before_text["v"]
    if len(after) != len(before):
        return f" (line count {len(before)} -> {len(after)})"
    for a, b in zip(after, before):
        if '"url"' not in b and a != b:
            return f" (changed line {b!r} -> {a!r})"
    return ""


case("write keeps formatting", 0, "OK:", hashes=False, write=True,
     setup=lambda d: before_text.__setitem__("v", (d / "catalog.json").read_text().splitlines()),
     check=keep_format_check)
case("write corrects a wrong hash", 0, "OK:", write=True,
     override=set_field(lambda t, s: s[0]["images"][0]["full"].update(sha256="0" * 64, bytes=3)))


def idempotent_check(d, out):
    first = (d / "catalog.json").read_bytes()
    code, _ = run(["--write", str(d / "catalog.json")])
    return "" if code == 0 and (d / "catalog.json").read_bytes() == first else " (second write changed the file)"


case("write is idempotent", 0, "OK:", hashes=False, write=True, check=idempotent_check)


def rest_filled(d, out):
    cat = cb.json.loads((d / "catalog.json").read_text())
    others = [im[r] for st in cat["sets"] for im in st["images"] for r in ("full", "thumbnail")
              if im[r]["url"] != "alpha/01-pic.png"]
    return "" if all("sha256" in f and "bytes" in f for f in others) else " (others not filled)"


case("write with a missing file fills the rest", 1, "missing file alpha/01-pic.png", hashes=False, write=True,
     setup=lambda d: (d / "alpha/01-pic.png").unlink(), check=rest_filled)

invalid_before = {}


def invalid_setup(d):
    invalid_before["v"] = (d / "catalog.json").read_bytes()


case("write leaves an invalid catalog untouched", 1, "schemaVersion", hashes=False, write=True,
     override=set_field(lambda t, s: t.update(schemaVersion=2)), setup=invalid_setup,
     check=lambda d, out: "" if (d / "catalog.json").read_bytes() == invalid_before["v"] else " (file changed)")

real = cb.check(REAL_CATALOG)
bad = [p for p in real if "missing file" not in p]
results.append(("real catalog parses and passes the schema", not bad, f"got {bad[:3]!r}; want no schema or id problems"))

passed = 0
for name, ok, detail in results:
    if ok:
        passed += 1
        print(f"ok   {name}")
    else:
        print(f"FAIL {name}: {detail}")
print(f"{passed}/{len(results)} passed")
sys.exit(0 if passed == len(results) else 1)
