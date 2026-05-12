# Downloads

Signed and notarized DMGs land here, one per release.

`scripts/release.sh` produces `dist/Batty-<sha>.dmg`. The release
workflow then copies (or renames) the DMG into this directory under a
version-stable path that the appcast entry can point at — usually
`Batty-<MARKETING_VERSION>.dmg`.

This directory is checked into the repo for the static host (GitHub
Pages / Netlify / S3) to serve. Avoid committing DMGs over a few tens
of MB if the hosting provider has size limits.

If/when the binaries grow past what the static repo can comfortably
hold, swap to a release-asset host (GitHub Releases via the `gh` CLI is
the easy answer) and point `appcast.xml`'s `<enclosure>` URLs there
instead.
