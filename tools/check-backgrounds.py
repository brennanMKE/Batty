#!/usr/bin/env python3
"""Check a hosted background catalog against the files beside it.

    python3 -I tools/check-backgrounds.py [--write] website/backgrounds/catalog.json

The catalog's folder is the root; every `url` must resolve inside it. Prints one
line per problem, `<json path>: <problem>`, then a summary line. Exit 0 when
there are no problems, 1 when there are any, 2 for a usage error.

--write fills in or corrects `sha256` and `bytes` only, editing the catalog's
text in place so its hand-formatted layout survives, then runs the check.
Standard library only, so it runs on Linux too. The format is #0574's.
"""

import argparse
import hashlib
import json
import os
import re
import struct
import sys
import tempfile
import urllib.parse
from pathlib import Path

# TerminalBackgroundImageImporter.maxPixelSize: Batty downscales anything larger.
FULL_MAX_PIXELS = 4096
# #0577's download limits table.
FULL_MAX_BYTES = 50 * 1024 * 1024
THUMB_MAX_BYTES = 2 * 1024 * 1024
# #0577's limits table: at most 1024 px on a thumbnail's longest side.
THUMB_MAX_PIXELS = 1024
# #0575 Work step 4: a thumbnail keeps its full-size image's aspect ratio, within 1%.
ASPECT_TOLERANCE = 0.01

ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
PNG_SIG = b"\x89PNG\r\n\x1a\n"
EXT_KIND = {".png": "png", ".jpg": "jpeg", ".jpeg": "jpeg"}
KIND_NAME = {"png": "PNG", "jpeg": "JPEG"}


def image_info(data):
    """(kind, width, height) for PNG or JPEG data, else None. Never raises."""
    if len(data) >= 24 and data[:8] == PNG_SIG:
        length = struct.unpack(">I", data[8:12])[0]
        if data[12:16] != b"IHDR" or length != 13:
            return None
        w, h = struct.unpack(">II", data[16:24])
        return ("png", w, h)
    if len(data) >= 3 and data[:3] == b"\xff\xd8\xff":
        i = 2
        n = len(data)
        while i < n:
            if data[i] != 0xFF:
                return None
            while i < n and data[i] == 0xFF:
                i += 1
            if i >= n:
                return None
            marker = data[i]
            i += 1
            if 0xD0 <= marker <= 0xD7 or marker == 0x01:
                continue
            if marker == 0xDA or marker == 0xD9:
                return None
            if i + 2 > n:
                return None
            seg_len = struct.unpack(">H", data[i:i + 2])[0]
            if seg_len < 2:
                return None
            if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
                if i + 7 > n:
                    return None
                h, w = struct.unpack(">HH", data[i + 3:i + 7])
                return ("jpeg", w, h)
            i += seg_len
        return None
    return None


def _is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def _text(v, lo, hi):
    return isinstance(v, str) and lo <= len(v.strip()) <= hi


def _schema_file(f, path):
    if not isinstance(f, dict):
        return f"{path}: must be an object"
    if not isinstance(f.get("url"), str):
        return f"{path}.url: must be a string"
    for k in ("width", "height"):
        if not _is_int(f.get(k)) or f[k] <= 0:
            return f"{path}.{k}: must be a positive integer"
    if "sha256" in f and not (isinstance(f["sha256"], str) and SHA_RE.match(f["sha256"])):
        return f"{path}.sha256: must be 64 lowercase hex digits"
    if "bytes" in f and not (_is_int(f["bytes"]) and f["bytes"] >= 0):
        return f"{path}.bytes: must be a non-negative integer"
    return None


def _schema(cat):
    """Problems, plus [(path, entry, image_path, role)] for every well-formed file entry."""
    problems, files = [], []
    if not isinstance(cat, dict):
        return ["catalog: top level must be an object"], files
    sv = cat.get("schemaVersion")
    top = None
    if not _is_int(sv) or sv != 1:
        top = "schemaVersion: must be the integer 1"
    elif not _text(cat.get("name"), 1, 100):
        top = "name: must be a string of 1-100 characters"
    elif "updated" in cat and not (isinstance(cat["updated"], str) and DATE_RE.match(cat["updated"])):
        top = "updated: must be YYYY-MM-DD"
    elif "homepage" in cat and not (isinstance(cat["homepage"], str) and cat["homepage"].startswith("https://")):
        top = "homepage: must start with https://"
    elif not isinstance(cat.get("sets"), list) or not 1 <= len(cat["sets"]) <= 50:
        top = "sets: must be a list of 1-50 sets"
    if top:
        problems.append(top)
    sets = cat.get("sets") if isinstance(cat.get("sets"), list) else []
    for si, s in enumerate(sets):
        sp = f"sets[{si}]"
        bad = None
        if not isinstance(s, dict):
            bad = f"{sp}: must be an object"
        elif not (isinstance(s.get("id"), str) and ID_RE.match(s["id"])):
            bad = f"{sp}.id: must match {ID_RE.pattern}"
        elif not _text(s.get("title"), 1, 100):
            bad = f"{sp}.title: must be a string of 1-100 characters"
        elif "description" in s and not (isinstance(s["description"], str) and len(s["description"]) <= 300):
            bad = f"{sp}.description: must be a string of at most 300 characters"
        elif not isinstance(s.get("images"), list) or not 1 <= len(s["images"]) <= 100:
            bad = f"{sp}.images: must be a list of 1-100 images"
        if bad:
            problems.append(bad)
        if not isinstance(s, dict) or not isinstance(s.get("images"), list):
            continue
        for ii, im in enumerate(s["images"]):
            ip = f"{sp}.images[{ii}]"
            bad = None
            if not isinstance(im, dict):
                problems.append(f"{ip}: must be an object")
                continue
            if not (isinstance(im.get("id"), str) and ID_RE.match(im["id"])):
                bad = f"{ip}.id: must match {ID_RE.pattern}"
            elif not _text(im.get("title"), 1, 100):
                bad = f"{ip}.title: must be a string of 1-100 characters"
            elif "credit" in im and not (isinstance(im["credit"], str) and len(im["credit"]) <= 200):
                bad = f"{ip}.credit: must be a string of at most 200 characters"
            if bad:
                problems.append(bad)
            for role in ("full", "thumbnail"):
                fp = f"{ip}.{role}"
                fbad = _schema_file(im.get(role), fp)
                if fbad:
                    problems.append(fbad)
                else:
                    files.append((fp, im[role], ip, role))
    return problems, files


def _unique(cat, files):
    problems = []
    seen_sets, seen_images, seen_urls = {}, {}, {}
    for si, s in enumerate(cat.get("sets") or []):
        if not isinstance(s, dict):
            continue
        sid = s.get("id")
        if isinstance(sid, str):
            if sid in seen_sets:
                problems.append(f"sets[{si}].id: duplicate set id {sid!r} (also {seen_sets[sid]})")
            else:
                seen_sets[sid] = f"sets[{si}]"
        for ii, im in enumerate(s.get("images") or [] if isinstance(s.get("images"), list) else []):
            if not isinstance(im, dict) or not isinstance(im.get("id"), str):
                continue
            iid, ip = im["id"], f"sets[{si}].images[{ii}]"
            if iid in seen_images:
                problems.append(f"{ip}.id: duplicate image id {iid!r} (also {seen_images[iid]})")
            else:
                seen_images[iid] = ip
    for fp, f, _, _ in files:
        u = f["url"]
        if u in seen_urls:
            problems.append(f"{fp}.url: duplicate url {u} (also {seen_urls[u]})")
        else:
            seen_urls[u] = fp
    return problems


def _url_problem(url, root):
    parts = urllib.parse.urlsplit(url)
    if parts.scheme or parts.netloc:
        return "must be relative, not an absolute URL"
    if parts.query or parts.fragment or "?" in url or "#" in url:
        return "must not have a query or fragment"
    if url.startswith("/") or "\\" in url:
        return "must be a relative path"
    segs = url.split("/")
    if any(seg in ("", ".", "..") for seg in segs):
        return "must not have empty, . or .. segments"
    if Path(url).suffix not in EXT_KIND:
        return "must end in .png, .jpg or .jpeg (lowercase)"
    try:
        (root / url).resolve().relative_to(root.resolve())
    except ValueError:
        return "resolves outside the catalog folder"
    return None


def _run(catalog_path):
    """(problems, missing, total) for the catalog at catalog_path."""
    catalog_path = Path(catalog_path)
    root = catalog_path.parent
    try:
        cat = json.loads(catalog_path.read_bytes().decode("utf-8"))
    except (OSError, UnicodeDecodeError, ValueError) as e:
        return [f"catalog: {e}"], 0, 0
    problems, files = _schema(cat)
    problems += _unique(cat, files) if isinstance(cat, dict) else []
    missing = 0
    valid_urls = set()
    for fp, f, ip, role in files:
        url = f["url"]
        up = _url_problem(url, root)
        if up:
            problems.append(f"{fp}.url: {up}")
            continue
        valid_urls.add(url)
        path = root / url
        if not path.is_file():
            problems.append(f"{fp}: missing file {url}")
            missing += 1
            continue
        data = path.read_bytes()
        got = image_info(data)
        want = EXT_KIND[Path(url).suffix]
        if got is None:
            problems.append(f"{fp}: {url} is not a PNG or JPEG image")
            continue
        if got[0] != want:
            problems.append(f"{fp}: {url} is {KIND_NAME[got[0]]} data, not {KIND_NAME[want]}")
            continue
        for k, v in (("width", got[1]), ("height", got[2])):
            if f[k] != v:
                problems.append(f"{fp}: {k} {f[k]} in catalog, {v} in file")
        digest = hashlib.sha256(data).hexdigest()
        if "sha256" not in f:
            problems.append(f"{fp}: sha256 missing (run with --write)")
        elif f["sha256"] != digest:
            problems.append(f"{fp}: sha256 {f['sha256']} in catalog, {digest} in file")
        if "bytes" not in f:
            problems.append(f"{fp}: bytes missing (run with --write)")
        elif f["bytes"] != len(data):
            problems.append(f"{fp}: bytes {f['bytes']} in catalog, {len(data)} in file")
        if role == "full":
            if f["width"] > FULL_MAX_PIXELS or f["height"] > FULL_MAX_PIXELS:
                problems.append(f"{fp}: {f['width']}x{f['height']} is over {FULL_MAX_PIXELS} pixels on a side")
            if len(data) > FULL_MAX_BYTES:
                problems.append(f"{fp}: {len(data)} bytes is over the {FULL_MAX_BYTES}-byte limit")
        else:
            if max(f["width"], f["height"]) > THUMB_MAX_PIXELS:
                problems.append(f"{fp}: longest side {max(f['width'], f['height'])} is over {THUMB_MAX_PIXELS}")
            if len(data) > THUMB_MAX_BYTES:
                problems.append(f"{fp}: {len(data)} bytes is over the {THUMB_MAX_BYTES}-byte limit")
    # Aspect uses catalog dimensions, so it runs for every pair that passed the schema.
    pairs = {}
    for fp, f, ip, role in files:
        pairs.setdefault(ip, {})[role] = f
    for ip, pair in pairs.items():
        if "full" in pair and "thumbnail" in pair:
            fu, th = pair["full"], pair["thumbnail"]
            fr, tr = fu["width"] / fu["height"], th["width"] / th["height"]
            if abs(tr - fr) / fr > ASPECT_TOLERANCE:
                problems.append(
                    f"{ip}.thumbnail: aspect {th['width']}x{th['height']} does not match full {fu['width']}x{fu['height']}")
    if root.is_dir():
        for p in sorted(root.rglob("*")):
            rel = p.relative_to(root)
            if any(part.startswith(".") for part in rel.parts) or not p.is_file():
                continue
            r = rel.as_posix()
            if p == catalog_path or r == "catalog.json" or r in valid_urls:
                continue
            problems.append(f"{r}: orphan file {r} (not in catalog; rsync would publish it)")
    return problems, missing, len(files)


def check(catalog_path):
    return _run(catalog_path)[0]


def _render(obj):
    return "{ " + ", ".join(f"{json.dumps(k)}: {json.dumps(v, ensure_ascii=False)}" for k, v in obj.items()) + " }"


def write(catalog_path):
    """Fill in sha256/bytes by editing the catalog's text, then check. Returns problems."""
    catalog_path = Path(catalog_path)
    root = catalog_path.parent
    try:
        text = catalog_path.read_bytes().decode("utf-8")
        cat = json.loads(text)
    except (OSError, UnicodeDecodeError, ValueError) as e:
        return [f"catalog: {e}"]
    problems, files = _schema(cat)
    if isinstance(cat, dict):
        problems += _unique(cat, files)
    if problems:
        return problems
    new = text
    for fp, f, _, _ in files:
        url = f["url"]
        if _url_problem(url, root):
            continue
        path = root / url
        if not path.is_file():
            continue
        data = path.read_bytes()
        got = image_info(data)
        if got is None or got[0] != EXT_KIND[Path(url).suffix]:
            continue
        matches = list(re.finditer(r'"url"\s*:\s*' + re.escape(json.dumps(url, ensure_ascii=False)), new))
        if len(matches) != 1:
            matches = list(re.finditer(r'"url"\s*:\s*' + re.escape(json.dumps(url)), new))
        if len(matches) != 1:
            return [f"{fp}: could not find a unique url {url} in the catalog text; nothing written"]
        m = matches[0]
        start = new.rfind("{", 0, m.start())
        end = new.find("}", m.end())
        try:
            span = json.loads(new[start:end + 1]) if start >= 0 and end >= 0 else None
        except ValueError:
            span = None
        if span != f:
            return [f"{fp}: catalog text for {url} does not match its parsed entry; nothing written"]
        updated = dict(span)
        updated["sha256"] = hashlib.sha256(data).hexdigest()
        updated["bytes"] = len(data)
        new = new[:start] + _render(updated) + new[end + 1:]
    if new != text:
        fd, tmp = tempfile.mkstemp(dir=root, prefix=".catalog-", suffix=".tmp")
        try:
            with os.fdopen(fd, "wb") as fh:
                fh.write(new.encode("utf-8"))
            os.replace(tmp, catalog_path)
        except BaseException:
            if os.path.exists(tmp):
                os.unlink(tmp)
            raise
    return check(catalog_path)


def main(argv):
    ap = argparse.ArgumentParser(description="Check a background catalog against its files.")
    ap.add_argument("--write", action="store_true", help="fill in or correct sha256 and bytes first")
    ap.add_argument("catalog", help="path to catalog.json")
    args = ap.parse_args(argv)
    if args.write:
        problems = write(args.catalog)
    else:
        problems = None
    full, missing, total = _run(args.catalog)
    if problems is None or not any(p.startswith("catalog:") or "nothing written" in p for p in problems):
        problems = full
    for p in problems:
        print(p)
    if problems:
        print(f"{len(problems)} problems ({missing} of {total} files missing)")
        return 1
    cat = json.loads(Path(args.catalog).read_text(encoding="utf-8"))
    images = sum(len(s["images"]) for s in cat["sets"])
    print(f"OK: {len(cat['sets'])} sets, {images} images, {total} files")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
