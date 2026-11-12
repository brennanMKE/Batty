#!/usr/bin/env python3
"""Check a hosted background catalog against the files beside it.

    python3 -I tools/check-backgrounds.py website/backgrounds/catalog.json

The format is in website/backgrounds.html, "Make your own set". The catalog's
folder is the root; every relative `full` and `thumbnail` must resolve inside
it. Absolute https URLs are allowed and counted as remote, but never fetched.
Prints one line per problem, `<json path>: <problem>`, then a summary line, or
`OK: N sets, N images, N files, N remote`. Exit 0 when there are no problems,
1 when there are any, 2 for a usage error. Standard library only, so it runs
on Linux too.
"""

import argparse
import json
import struct
import sys
import urllib.parse
from pathlib import Path

# BackgroundCatalogLimits in BattyKit: the app rejects anything over these.
FULL_MAX_PIXELS = 8192
FULL_MAX_BYTES = 50_000_000
THUMB_MAX_BYTES = 2_000_000
THUMB_MAX_PIXELS = 1024
MAX_SETS = 50
MAX_IMAGES_PER_SET = 100
MAX_IMAGES = 1000
MAX_TEXT = 100
# #0575 Work step 4: a thumbnail keeps its full-size image's aspect ratio, within 1%.
ASPECT_TOLERANCE = 0.01

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


def _is_remote(url):
    parts = urllib.parse.urlsplit(url)
    return parts.scheme.lower() == "https" and bool(parts.netloc)


def _schema(cat):
    """Problems, plus [(path, url, image_path, role)] for every well-formed file entry."""
    problems, files = [], []
    if not isinstance(cat, dict):
        return ["catalog: top level must be an object"], files
    sets = cat.get("sets")
    if not isinstance(sets, list):
        return ["sets: must be a list"], files
    if len(sets) > MAX_SETS:
        problems.append(f"sets: must be a list of at most {MAX_SETS} sets")
    total = 0
    for si, s in enumerate(sets):
        sp = f"sets[{si}]"
        if not isinstance(s, dict):
            problems.append(f"{sp}: must be an object")
            continue
        name = s.get("name")
        if not (isinstance(name, str) and 1 <= len(name.strip()) <= MAX_TEXT):
            problems.append(f"{sp}.name: must be a non-blank string of at most {MAX_TEXT} characters")
        images = s.get("images")
        if not isinstance(images, list):
            problems.append(f"{sp}.images: must be a list")
            continue
        total += len(images)
        if len(images) > MAX_IMAGES_PER_SET:
            problems.append(f"{sp}.images: must be a list of at most {MAX_IMAGES_PER_SET} images")
        elif total > MAX_IMAGES:
            problems.append(f"{sp}.images: the catalog has more than {MAX_IMAGES} images")
        for ii, im in enumerate(images):
            ip = f"{sp}.images[{ii}]"
            if not isinstance(im, dict):
                problems.append(f"{ip}: must be an object")
                continue
            for role in ("full", "thumbnail"):
                u = im.get(role)
                if not (isinstance(u, str) and u.strip()):
                    problems.append(f"{ip}.{role}: must be a non-empty string")
                else:
                    files.append((f"{ip}.{role}", u, ip, role))
            t = im.get("title")
            if not (isinstance(t, str) and 1 <= len(t.strip()) <= MAX_TEXT):
                problems.append(f"{ip}.title: must be a non-empty string of at most {MAX_TEXT} characters")
    return problems, files


def _unique(cat, files):
    problems, seen = [], {"full": {}, "thumbnail": {}}
    for fp, u, _, role in files:
        if u in seen[role]:
            problems.append(f"{fp}: duplicate {role} {u} (also {seen[role][u]})")
        else:
            seen[role][u] = fp
    return problems


def _url_problem(url, root):
    parts = urllib.parse.urlsplit(url)
    if parts.scheme or parts.netloc:
        return "must be relative or an absolute https URL"
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
    """(problems, missing, local, remote, catalog) for the catalog at catalog_path."""
    catalog_path = Path(catalog_path)
    root = catalog_path.parent
    try:
        cat = json.loads(catalog_path.read_bytes().decode("utf-8"))
    except (OSError, UnicodeDecodeError, ValueError) as e:
        return [f"catalog: {e}"], 0, 0, 0, None
    problems, files = _schema(cat)
    problems += _unique(cat, files)
    missing = local = remote = 0
    valid_urls = set()
    dims = {}
    for fp, url, ip, role in files:
        if _is_remote(url):
            remote += 1
            continue
        local += 1
        up = _url_problem(url, root)
        if up:
            problems.append(f"{fp}: {up}")
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
        w, h = got[1], got[2]
        dims[(ip, role)] = (w, h)
        if role == "full":
            if w > FULL_MAX_PIXELS or h > FULL_MAX_PIXELS:
                problems.append(f"{fp}: {w}x{h} is over {FULL_MAX_PIXELS} pixels on a side")
            if len(data) > FULL_MAX_BYTES:
                problems.append(f"{fp}: {len(data)} bytes is over the {FULL_MAX_BYTES}-byte limit")
        else:
            if max(w, h) > THUMB_MAX_PIXELS:
                problems.append(f"{fp}: longest side {max(w, h)} is over {THUMB_MAX_PIXELS}")
            if len(data) > THUMB_MAX_BYTES:
                problems.append(f"{fp}: {len(data)} bytes is over the {THUMB_MAX_BYTES}-byte limit")
    for (ip, role), (fw, fh) in dims.items():
        if role != "full" or (ip, "thumbnail") not in dims or not fw or not fh:
            continue
        tw, th = dims[(ip, "thumbnail")]
        if not th or abs(tw / th - fw / fh) / (fw / fh) > ASPECT_TOLERANCE:
            problems.append(f"{ip}.thumbnail: aspect {tw}x{th} does not match full {fw}x{fh}")
    if root.is_dir():
        for p in sorted(root.rglob("*")):
            rel = p.relative_to(root)
            if any(part.startswith(".") for part in rel.parts) or not p.is_file():
                continue
            r = rel.as_posix()
            if p == catalog_path or r == "catalog.json" or r in valid_urls:
                continue
            problems.append(f"{r}: orphan file {r} (not in catalog; rsync would publish it)")
    return problems, missing, local, remote, cat


def check(catalog_path):
    return _run(catalog_path)[0]


def main(argv):
    ap = argparse.ArgumentParser(description="Check a background catalog against its files.")
    ap.add_argument("catalog", help="path to catalog.json")
    args = ap.parse_args(argv)
    problems, missing, local, remote, cat = _run(args.catalog)
    for p in problems:
        print(p)
    if problems:
        print(f"{len(problems)} problems ({missing} of {local} files missing)")
        return 1
    images = sum(len(s["images"]) for s in cat["sets"])
    print(f"OK: {len(cat['sets'])} sets, {images} images, {local} files, {remote} remote")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
