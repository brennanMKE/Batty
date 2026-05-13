# Website screenshots

Tracked under `#0099`. Empty until v1.0.0 ship. The site renders fine
without them — references in `website/index.html` are deferred until
the files actually exist (avoid shipping 404s).

## Required for v1.0.0

| File | What it shows | Target size |
|---|---|---|
| `hero.png` | 3 sessions in sidebar, a 2×2 split, tab chips, subtle bell-feed badge. | 1600×1000 |
| `splits.png` | Tight shot of recursive splits with dividers. | 1200×800 |
| `tabs.png` | Close-up of the tab strip including `+` and an unseen-bell dot. | 1200×500 |
| `bell-feed.png` | Bell-feed popover with 2–3 entries. | 1000×800 |

## Capture procedure

1. Set Batty's theme to **Mocha** or **Tokyo Night** (anything but Default — looks more like a real product).
2. Open a real project under `~/Developer/<name>/` so the auto-derived session/tab names (`#0089`) show meaningfully.
3. Cmd-Shift-5 → "Capture Selected Portion" for each shot.
4. Save into this directory with the filenames above.
5. Resize for sane file sizes:
   ```bash
   for f in *.png; do
       sips -Z 1600 "$f"
       mv "$f" /tmp && pngcrush -rem alla -reduce -brute /tmp/$f $f
   done
   ```
   Goal: each file ≤ 600KB so the landing page stays snappy.
6. After landing, edit `website/index.html` to wire the `<img>` tags
   into the hero and feature sections.

## House rules

- No real credentials, hostnames, paths to private repos.
- Crop chrome that isn't relevant (no other windows visible behind Batty).
- Match the dark theme of the website (`bg: #0d0b14` violet-on-black).
