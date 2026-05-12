# Batty website

The static site that backs [batty.sstools.co](https://batty.sstools.co/).
Serves three purposes:

1. Landing page (`index.html`) — what Batty is + download link.
2. Sparkle appcast endpoint (`appcast.xml`).
3. Direct DMG download (`downloads/`).

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
- `/appcast.xml` — should parse as RSS

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

Sparkle picks up the new entry on the next poll. Most users see the
update prompt within a few hours.

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
