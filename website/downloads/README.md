# Downloads

Signed and notarized DMGs land here, one per release.

`scripts/release.sh` produces `dist/Batty-<sha>.dmg`. The release
workflow then copies (or renames) the DMG into this directory under a
version-stable path that the appcast entry can point at — usually
`Batty-<MARKETING_VERSION>.dmg`.

This directory is checked into the repo for the static host (GitHub
Pages / Netlify / S3) to serve. Avoid committing DMGs over a few tens
of MB if the hosting provider has size limits.

The same DMG, under the same `Batty-<MARKETING_VERSION>.dmg` name, is
also attached as an asset to the GitHub release for the tag (repo
`brennanMKE/Batty`, e.g. `v1.1.0`). Users can download from either
location; see `scripts/RELEASE.md` step 10 for the user-run `gh`
command. The appcast `<enclosure>` URLs stay on the website copy.

If/when the binaries grow past what the static repo can comfortably
hold, drop the copies here and point `appcast.xml`'s `<enclosure>` URLs there
instead.
