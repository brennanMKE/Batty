# Batty website

The static site that backs [batty.sstools.co](https://batty.sstools.co/).
Serves three purposes:

1. Landing page (`index.html`) — what Batty is + download link.
2. Sparkle appcast endpoint (`appcast.xml`).
3. Direct DMG download (`downloads/`). The same DMG is also attached to
   the matching [GitHub release](https://github.com/brennanMKE/Batty/releases);
   users can download from either location.

No build step. Plain HTML + a single hand-written stylesheet.

## Preview locally

```bash
cd website
python3 -m http.server 8000
open http://localhost:8000/
```

Pages to spot-check:

- `/` — landing
- `/changelog.html`
- `/privacy.html`
- `/backgrounds.html` — the Background Sets page, generated from the catalog
- `/appcast.xml` — should parse as RSS
- `/backgrounds/catalog.json` — the built-in background catalog

## Deployment

Pick a static host. Easiest options:

- **GitHub Pages** off a `gh-pages` branch of this repo or a dedicated
  `batty-website` repo. Free TLS via custom-domain CNAME.
- **Netlify** with the repo connected; auto-deploy on push.
- **Static S3 + CloudFront** if you want full control over caching headers.

The `SUFeedURL` in the Batty app's Info.plist must match wherever
`appcast.xml` ends up — by default
`https://batty.sstools.co/appcast.xml`.

## Per-release workflow

When `scripts/release.sh` produces `dist/Batty-<sha>.dmg`:

1. Copy or symlink the DMG into `website/downloads/Batty-<version>.dmg`
   (or a stable path the appcast entry points at).
2. Append an `<item>` to `appcast.xml` per the schema documented inline
   in the file (and `scripts/SPARKLE.md`). Include EdDSA signature from
   `sign_update`.
3. Add a `<article>` to `changelog.html` summarising user-visible
   changes. Use the same id (`v0-1-0` etc.) the appcast's
   `<sparkle:releaseNotesLink>` references.
4. Push to the hosting destination.
5. Attach the same DMG, as `Batty-<version>.dmg`, to the GitHub release
   for the tag (`gh release create` / `gh release upload`; user-run or
   explicitly approved, see `scripts/RELEASE.md` step 10). The appcast
   enclosure keeps pointing at the website URL, not the GitHub asset.

Sparkle picks up the new entry on the next poll. Most users see the
update prompt within a few hours.

## Background images

`backgrounds/catalog.json` is the built-in background catalog (format: the "Make your own set" section of `backgrounds.html`). Its image URLs are relative: a file on another host wouldn't be deployed with the site, and `build-backgrounds-page.py` refuses one. It is in git. The images it lists, full-size and thumbnails, are **not**: `.gitignore` excludes `website/backgrounds/**/*.png`, `*.jpg` and `*.jpeg`. Your local `website/backgrounds/<set>/` folders and the server are the only copies, so keep a backup of the originals.

Adding an image:

1. Generate it from `docs/background-image-prompts.md`, saved at the path named there. PNG is preferred; JPEG is fine (use `.jpg` and change the catalog's `full` or `thumbnail` to match).
2. Make the thumbnail from it, never generate one: `sips -z 300 480 <full> --out <thumb>` (for a JPEG thumbnail add `-s format jpeg`).
3. Add `{ "title": …, "thumbnail": …, "full": … }` to its set in `catalog.json`.
4. Regenerate the page: `python3 -I tools/build-backgrounds-page.py`.
5. Commit `catalog.json` and `backgrounds.html` only. `git status` must show no image files.

A changed picture gets a new file name; never replace the bytes behind an existing path. Batty knows a downloaded image by its full-size URL.

`examples/background-catalog.json` is the example catalog that `backgrounds.html` shows and links for download. It lives outside `backgrounds/` so the check never sees it as an orphan, and `build-backgrounds-page.py` validates it on every run.

Before every deploy, both must exit 0: `python3 -I tools/check-backgrounds.py website/backgrounds/catalog.json` and `python3 -I tools/build-backgrounds-page.py --check`. Then, with the user's go-ahead each time:

```bash
rsync -avzn website/ photon:/var/www/vhosts/batty.sstools.co/   # dry run, read it
rsync -avz  website/ photon:/var/www/vhosts/batty.sstools.co/
```

Never add `--delete`: it would remove the older DMGs on the server. Because there's no `--delete`, removing an image from the catalog doesn't remove it from the server; delete it there by hand if needed.

After deploying, check with `curl -sI` that `https://batty.sstools.co/backgrounds/catalog.json` returns 200 with `Content-Type: application/json` and an `ETag` or `Last-Modified` header, and that one full-size and one thumbnail URL return 200 with the expected `Content-Length`.

## Assets

Pulled from the repo's `Artwork/` directory:

| `assets/`             | source |
|-----------------------|--------|
| `batty-icon.png`      | `Artwork/AppIcon.png` |
| `batty-icon-glow.png` | `Artwork/AppIcon-glow1.png` |
| `batty-logo.png`      | `Artwork/BattyLogo.png` |

Screenshots (`assets/screenshots/*.png`) are user-curated — capture
them with Cmd-Shift-4 against a real Batty window before each release.

## House rules

- No tracking. No analytics. No external JS.
- Validate HTML with `tidy -e -q website/*.html` before committing.
- Test in Safari and Firefox at minimum; everything else inherits.
- Keep the CSS in one file. Resist a build pipeline.
