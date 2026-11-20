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
- `/docs/cli/index.html` — the CLI reference, generated from `docs/cli/capabilities.json`
- `/docs/cli/capabilities.json` — expect `Content-Type: application/json`

## Deployment

The site is served from `photon:/var/www/vhosts/batty.sstools.co/`. Deploying is user-run, or done with the user's go-ahead each time.

**Pre-deploy checks.** Run from the repo root; all must exit 0:

```bash
python3 -I tools/check-backgrounds.py website/backgrounds/catalog.json
python3 -I tools/build-backgrounds-page.py --check
python3 -I tools/build-docs-page.py --check
python3 -I tools/check-website-hold.py
python3 -I tools/build-cli-reference.py --check
python3 -I tools/build-cli-reference-selftest.py
python3 -I tools/build-agent-downloads.py --check   # on release day, once the skill zips are committed
tidy -e -q website/*.html
tidy -e -q website/docs/cli/index.html
git lfs ls-files        # must list the background images, not pointer stubs
```

Later generators add their `--check` here.

**Held files.** `website/.deploy-hold` lists files that are on `main` but must not reach the server until the release that ships them. It is in rsync `--exclude-from` format: one entry per line, each anchored with a leading `/` relative to `website/` (`/docs/` means `website/docs/` only), a trailing `/` for a directory, no wildcards. Today it holds `/docs/`, `/llms.txt` and `/llms-full.txt` until 1.5.0 (#0680; #0688 empties it). A file on `main` under a held path never reaches the server, and no deployable page (`website/*.html`, `sitemap.xml`, `robots.txt`) may link a held path; `tools/check-website-hold.py` enforces that.

**Deploy**, from the repo root:

```bash
rsync -avzn --exclude-from=website/.deploy-hold --exclude=README.md --exclude=.deploy-hold \
    website/ photon:/var/www/vhosts/batty.sstools.co/   # dry run: read it; no held path, no README.md
rsync -avz  --exclude-from=website/.deploy-hold --exclude=README.md --exclude=.deploy-hold \
    website/ photon:/var/www/vhosts/batty.sstools.co/
```

Never add `--delete`: older DMGs and catalog images exist only on the server, and it would remove them. A file removed from `website/` stays on the server until deleted there by hand.

**Post-deploy checks**, with `curl -sI`:

- `https://batty.sstools.co/`, `/appcast.xml` and `/changelog.html` return 200.
- `/backgrounds/catalog.json` returns 200 with `Content-Type: application/json` and an `ETag` or `Last-Modified` header; one full-size and one thumbnail URL return 200 with the expected `Content-Length`; `/backgrounds.html` returns 200. A 403 usually means a file was deployed without world read (`stat -f %Lp website/backgrounds.html` should print `644`).
- A held path, e.g. `/docs/index.html`, returns 404 while held.

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
4. Regenerate the CLI reference from the release's Prod build:
   `python3 -I tools/build-cli-reference.py --refresh-json --cli /Applications/Batty.app/Contents/Resources/bin/batty`
   (the installed release build), then commit `website/docs/cli/`.
5. Package the skill: `python3 -I tools/build-agent-downloads.py`, then
   commit `website/docs/skill/batty-cli-skill-<version>.zip` and
   `batty-cli-skill-latest.zip`. `--check` confirms them.
6. Update the Claude Code marketplace (user-run): in your clone of
   `brennanMKE/batty-plugins`, run `tools/sync-claude-marketplace.sh <clone>`,
   review the diff, then commit, tag `v<version>` and push it yourself.
7. Deploy the site as described in [Deployment](#deployment) (pre-deploy
   checks, dry run, real run, `curl -sI` checks).
8. Attach the same DMG, as `Batty-<version>.dmg`, to the GitHub release
   for the tag (`gh release create` / `gh release upload`; user-run or
   explicitly approved, see `scripts/RELEASE.md` step 10). The appcast
   enclosure keeps pointing at the website URL, not the GitHub asset.

Sparkle picks up the new entry on the next poll. Most users see the
update prompt within a few hours.

## Background images

`backgrounds/catalog.json` is the built-in background catalog (format: the "Make your own set" section of `backgrounds.html`). Its image URLs are relative: a file on another host wouldn't be deployed with the site, and `build-backgrounds-page.py` refuses one. It is in git, and so are the images it lists, full-size and thumbnails: they are the official sets, stored in Git LFS (`.gitattributes` routes `website/backgrounds/**/*.png`, `*.jpg` and `*.jpeg` to LFS). A clone needs `git lfs` installed to get the real files rather than pointer stubs; check with `git lfs ls-files` before deploying.

Adding an image:

1. Generate it from `docs/background-image-prompts.md`, saved at the path named there. PNG is preferred; JPEG is fine (use `.jpg` and change the catalog's `full` or `thumbnail` to match).
2. Make the thumbnail from it, never generate one: `sips -z 300 480 <full> --out <thumb>` (for a JPEG thumbnail add `-s format jpeg`).
3. Add `{ "title": …, "thumbnail": …, "full": … }` to its set in `catalog.json`.
4. Regenerate the page: `python3 -I tools/build-backgrounds-page.py`.
5. Commit `catalog.json` and `backgrounds.html` only. `git status` must show no image files.

A changed picture gets a new file name; never replace the bytes behind an existing path. Batty knows a downloaded image by its full-size URL.

`examples/background-catalog.json` is the example catalog that `backgrounds.html` shows and links for download. It lives outside `backgrounds/` so the check never sees it as an orphan, and `build-backgrounds-page.py` validates it on every run.

Deploy as described in [Deployment](#deployment); its checks include the two background checks. Because the deploy never uses `--delete`, removing an image from the catalog doesn't remove it from the server; delete it there by hand if needed.

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
