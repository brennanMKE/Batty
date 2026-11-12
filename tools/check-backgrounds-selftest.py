#!/usr/bin/env python3
"""Offline cases for tools/check-backgrounds.py.

    python3 -I tools/check-backgrounds-selftest.py [path/to/check-backgrounds.py]

Builds small PNG/JPEG fixtures and catalogs in temporary folders. No sips, no
git, no network.
"""

import contextlib
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


def build_root(d, *, ext_full="png", ext_thumb="png", override=None, files=None,
               full_size=(160, 100), thumb_size=(48, 30), mutate=None):
    """Two sets of two images. override(top, sets) edits the entries; files maps url -> bytes overrides."""
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
            images.append({"title": f"Pic {n}", "thumbnail": tu, "full": fu})
        sets.append({"name": s.title(), "images": images})
    if files:
        blobs.update(files)
    top = {}
    if override:
        override(top, sets)
    for url, b in blobs.items():
        if b is None:
            continue
        p = d / url
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b)
    dumps = cb.json.dumps
    if "sets" in top:
        body = dumps(top)
    else:
        lines = ["{"]
        for k, v in top.items():
            lines.append(f"  {dumps(k)}: {dumps(v)},")
        lines.append('  "sets": [')
        for si, st in enumerate(sets):
            head = ", ".join(f"{dumps(k)}: {dumps(v)}" for k, v in st.items() if k != "images")
            lines.append(f"    {{ {head}{', ' if head else ''}\"images\": [")
            for ii, im in enumerate(st["images"]):
                tail = "," if ii < len(st["images"]) - 1 else ""
                lines.append(f"      {dumps(im)}{tail}")
            lines.append("    ] }" + ("," if si < len(sets) - 1 else ""))
        lines += ["  ]", "}"]
        body = "\n".join(lines)
    cat = d / "catalog.json"
    cat.write_text(body + "\n", encoding="utf-8")
    if mutate:
        mutate(d)
    return cat


def run(args):
    out = io.StringIO()
    err = io.StringIO()
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cb.main(args)
    except SystemExit as e:
        return (e.code, out.getvalue() + err.getvalue())
    except Exception as e:  # a crash is a failure, never an exit code
        return ("raised", f"{type(e).__name__}: {e}")
    return (code, out.getvalue())


results = []


def case(name, want_code, want_text=None, **kw):
    setup = kw.pop("setup", None)
    check = kw.pop("check", None)
    args = kw.pop("args", [])
    with tempfile.TemporaryDirectory() as d:
        cat = build_root(d, **kw)
        if setup:
            setup(Path(d))
        code, out = run(args + [str(cat)])
        ok = code == want_code and (want_text is None or want_text in out)
        extra = ""
        if ok and check:
            extra = check(Path(d), out) or ""
            ok = not extra
        results.append((name, ok, f"got {code} {out.strip()[-300:]!r}{extra}; want {want_code} {want_text!r}"))


def img(si, ii, **kw):
    def override(top, sets):
        sets[si]["images"][ii].update(kw)
    return override


def drop(si, ii, key):
    def override(top, sets):
        sets[si]["images"][ii].pop(key)
    return override


case("good catalog passes", 0, "8 files, 0 remote")
case("good catalog with jpeg full and jpeg thumbnail passes", 0, "OK:", ext_full="jpg", ext_thumb="jpeg")
case("missing full-size file", 1, "(1 of 8 files missing)", setup=lambda d: (d / "alpha/01-pic.png").unlink())
case("missing thumbnail", 1, "missing file alpha/02-pic-thumb.png",
     setup=lambda d: (d / "alpha/02-pic-thumb.png").unlink())
case("png data with jpg extension", 1, "is PNG data, not JPEG", ext_full="jpg",
     files={"alpha/01-pic.jpg": make_png(160, 100)})
case("jpeg data with png extension", 1, "not PNG", files={"alpha/01-pic.png": make_jpeg(160, 100)})
case("not an image", 1, "not a PNG or JPEG", files={"alpha/01-pic.png": b"hello world, not an image"})
case("truncated jpeg has no SOF", 1, "not a PNG or JPEG", files={"alpha/01-pic.png": b"\xff\xd8\xff\xe0\x00"})


def outside_check(d, out):
    return " (outside file was named as missing/read)" if "missing file ../" in out else ""


case("dotdot url", 1, ".full: must not have empty, . or .. segments",
     override=img(0, 0, full="../outside.png"), check=outside_check)
case("absolute path url", 1, ".full: must be a relative path", override=img(0, 0, full="/etc/passwd.png"))
case("unsupported extension", 1, "must end in .png", override=img(0, 0, full="alpha/01-pic.gif"))
case("orphan png", 1, "orphan file alpha/extra.png", setup=lambda d: (d / "alpha/extra.png").write_bytes(make_png(4, 4)))
case("orphan non-image file", 1, "orphan file notes.txt", setup=lambda d: (d / "notes.txt").write_text("x"))
case("hidden file is not an orphan", 0, "OK:", setup=lambda d: (d / "alpha/.DS_Store").write_bytes(b"\x00"))
case("thumbnail aspect mismatch", 1, "aspect 48x48 does not match full 160x100", thumb_size=(48, 48))
case("thumbnail longer than 1024", 1, "over 1024", thumb_size=(1600, 1000), full_size=(1600, 1000))
case("full wider than 8192", 1, "over 8192", full_size=(9000, 5625), thumb_size=(48, 30),
     files={f"{s}/0{n}-pic.png": make_png_header(9000, 5625) for s in ("alpha", "beta") for n in (1, 2)})
case("full of 8192 pixels passes", 0, "OK:", full_size=(8192, 5120), thumb_size=(48, 30),
     files={f"{s}/0{n}-pic.png": make_png_header(8192, 5120) for s in ("alpha", "beta") for n in (1, 2)})

saved = cb.FULL_MAX_BYTES
cb.FULL_MAX_BYTES = 10
try:
    case("full over byte limit", 1, "byte limit")
finally:
    cb.FULL_MAX_BYTES = saved

case("invalid json", 1, "catalog:", mutate=lambda d: (d / "catalog.json").write_text("{ not json"))


def whole(cat):
    def m(d):
        (d / "catalog.json").write_text(cb.json.dumps(cat))
    return m


def set_override(fn):
    def override(top, sets):
        fn(sets)
    return override


case("missing sets", 1, "sets: must be a list", mutate=whole({"name": "x"}))
case("sets not a list", 1, "sets: must be a list", mutate=whole({"sets": {"a": 1}}))
case("missing set name", 1, "sets[0].name:", override=set_override(lambda s: s[0].pop("name")))
case("blank set name", 1, "sets[0].name:", override=set_override(lambda s: s[0].update(name="   ")))
case("set name over 100 characters", 1, "sets[1].name:", override=set_override(lambda s: s[1].update(name="n" * 101)))
case("missing image full", 1, "sets[0].images[0].full: must be a non-empty string", override=drop(0, 0, "full"))
case("missing image thumbnail", 1, "sets[0].images[1].thumbnail: must be a non-empty string",
     override=drop(0, 1, "thumbnail"))
case("non-string full", 1, "sets[0].images[0].full: must be a non-empty string", override=img(0, 0, full=3))
case("non-string title", 1, "sets[0].images[0].title:", override=img(0, 0, title=3))
case("title over 100 characters", 1, "sets[0].images[0].title:", override=img(0, 0, title="t" * 101))
case("title of 100 characters after trimming passes", 0, "OK:", override=img(0, 0, title="  " + "t" * 100 + "  "))
case("missing title passes", 0, "OK:", override=drop(0, 0, "title"))
case("null title passes", 0, "OK:", override=img(0, 0, title=None))
case("blank title passes", 0, "OK:", override=img(0, 0, title="  "))


def unknown(top, sets):
    top["extra"] = {"x": 1}
    sets[0]["extra"] = [1]
    sets[0]["images"][0]["extra"] = "y"


case("unknown fields pass", 0, "OK:", override=unknown)
case("duplicate set name passes", 0, "OK: 2 sets", override=set_override(lambda s: s[1].update(name="Alpha")))
case("empty sets pass", 0, "OK: 0 sets, 0 images", mutate=lambda d: (
    (d / "catalog.json").write_text('{"sets": []}'), [p.unlink() for p in d.rglob("*.png")]))
case("duplicate full", 1, "sets[1].images[0].full: duplicate full alpha/01-pic.png",
     override=img(1, 0, full="alpha/01-pic.png"))
case("duplicate thumbnail", 1, "duplicate thumbnail alpha/01-pic-thumb.png",
     override=img(0, 1, thumbnail="alpha/01-pic-thumb.png"))


def no_orphan(d, out):
    return " (orphan reported)" if "orphan" in out else ""


case("absolute https full is skipped and counted", 0, "7 files, 1 remote",
     override=img(0, 0, full="https://example.com/a.png"), setup=lambda d: (d / "alpha/01-pic.png").unlink(),
     check=no_orphan)
case("http url is rejected", 1, "must be relative or an absolute https URL",
     override=img(0, 0, full="http://example.com/a.png"))
case("scheme-less host url is rejected", 1, "must be relative or an absolute https URL",
     override=img(0, 0, full="//example.com/a.png"))
case("too many sets", 1, "sets: must be a list of at most 50 sets",
     mutate=whole({"sets": [{"name": f"S{i}", "images": []} for i in range(51)]}))
case("too many images in a set", 1, "sets[0].images: must be a list of at most 100 images",
     mutate=whole({"sets": [{"name": "S", "images": [
         {"full": f"{i}.png", "thumbnail": f"{i}-t.png"} for i in range(101)]}]}))
case("write option is rejected", 2, "unrecognized arguments", args=["--write"])

for given, want in (("01-skyline-fog.png", "01-skyline-fog"), ("a/b.c.jpg", "b.c"),
                    ("beta/02%20fourth.png", "02 fourth"), ("https://example.com/x/y.png?v=1", "y")):
    got = cb.fallback_title(given)
    results.append((f"fallback title of {given}", got == want, f"got {got!r}; want {want!r}"))

real = cb.check(REAL_CATALOG)
bad = [p for p in real if "missing file" not in p]
results.append(("real catalog parses and passes the schema", not bad, f"got {bad[:3]!r}; want no schema problems"))

passed = 0
for name, ok, detail in results:
    if ok:
        passed += 1
        print(f"ok   {name}")
    else:
        print(f"FAIL {name}: {detail}")
print(f"{passed}/{len(results)} passed")
sys.exit(0 if passed == len(results) else 1)
