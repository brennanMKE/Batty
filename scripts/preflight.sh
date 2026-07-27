#!/usr/bin/env zsh
# Walk the release-readiness gates. Read-only — never mutates anything.
#
# Each gate prints one line:
#   [✓] description           — passing
#   [✗] description           — failing (causes non-zero exit)
#   [!] description           — warning (zero exit unless --strict)
#
# Flags:
#   --strict             warnings become failures
#   --allow-dirty        skip the "working tree clean" failure
#   --allow-no-sparkle   skip the SUFeedURL plist check
#   --skip-ssh-check     don't actually SSH to the EC2 host
#   --skip-build         don't re-run xcodebuild / tests (faster ad-hoc check)
#   -h | --help          this help

set -uo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h}"
XCCONFIG="$REPO_ROOT/Configuration/Build.xcconfig"
APP_XCCONFIG="$REPO_ROOT/Configuration/App.xcconfig"
INFO_PLIST_SRC="$REPO_ROOT/Configuration/Info.plist"
PBXPROJ="$REPO_ROOT/Batty.xcodeproj/project.pbxproj"
PACKAGE_SWIFT="$REPO_ROOT/BattyKit/Package.swift"

STRICT=0
ALLOW_DIRTY=0
ALLOW_NO_SPARKLE=0
SKIP_SSH=0
SKIP_BUILD=0

for arg in "$@"; do
    case "$arg" in
        --strict) STRICT=1 ;;
        --allow-dirty) ALLOW_DIRTY=1 ;;
        --allow-no-sparkle) ALLOW_NO_SPARKLE=1 ;;
        --skip-ssh-check) SKIP_SSH=1 ;;
        --skip-build) SKIP_BUILD=1 ;;
        -h|--help)
            sed -n '2,/^set -uo/p' "$0" | sed '/^set -uo/d' | sed 's/^# *//'
            exit 0
            ;;
        *) print -u2 "preflight: unknown flag $arg"; exit 2 ;;
    esac
done

FAILS=0
WARNS=0

pass() { print "  [✓] $1"; }
fail() { print "  [✗] $1"; FAILS=$((FAILS + 1)); }
warn() {
    if (( STRICT )); then
        print "  [✗] $1 (strict)"; FAILS=$((FAILS + 1))
    else
        print "  [!] $1"; WARNS=$((WARNS + 1))
    fi
}

section() { print ""; print "$1"; }

# Compare two dotted versions (X.Y.Z, prerelease suffix ignored).
# Echoes 1 if $1 > $2, -1 if $1 < $2, 0 if equal. BSD sort lacks -V, so
# compare component-wise.
ver_cmp() {
    local a=${1%%-*} b=${2%%-*}
    local -a A B
    A=(${(s:.:)a}); B=(${(s:.:)b})
    local i x y
    for i in 1 2 3; do
        x=${A[i]:-0}; y=${B[i]:-0}
        (( x > y )) && { print 1; return }
        (( x < y )) && { print -- -1; return }
    done
    print 0
}

# First (newest) attribute value of a given name in the appcast. The appcast
# convention is newest-item-first, so head -1 is the newest release. XML
# comments are stripped first so placeholder text in the authoring comment
# (e.g. length="...") can't be mistaken for a real attribute.
appcast_newest_attr() {
    perl -0777 -pe 's/<!--.*?-->//gs' "$APPCAST" 2>/dev/null \
        | grep -oE "$1=\"[^\"]+\"" | head -1 | sed -E 's/.*="([^"]+)"/\1/'
}

# --- Build gates -------------------------------------------------------------

section "Build gates"

if (( SKIP_BUILD )); then
    pass "build/test skipped (--skip-build)"
else
    if DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
        xcodebuild -scheme 'Batty (Prod)' -destination 'platform=macOS' \
        CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
        build >/tmp/batty-preflight-build.log 2>&1; then
        pass "xcodebuild build"
    else
        fail "xcodebuild build (see /tmp/batty-preflight-build.log)"
    fi

    if DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
        xcrun swift test --package-path "$REPO_ROOT/BattyKit" \
        >/tmp/batty-preflight-test.log 2>&1; then
        local count
        count=$(grep -E "Test run with [0-9]+ tests" /tmp/batty-preflight-test.log | tail -1 | grep -oE "[0-9]+ tests" | head -1)
        pass "swift test (${count:-passed})"
    else
        fail "swift test (see /tmp/batty-preflight-test.log)"
    fi
fi

# Sentinel from #0003: terminfo bundled. Skip Index.noindex copies — those
# are the indexer's product without the Run Script build phase outputs.
# Multiple DerivedData dirs can coexist (Batty-<hash>) after Xcode reshuffles;
# pick the most recently modified Batty.app so a stale one doesn't fail the
# check.
#
# This is deliberately pinned to the literal name "Batty.app" — this is a
# Prod-release preflight (Sparkle feed, notarization, MARKETING_VERSION),
# so it must only ever match a Prod build. Before #0279 gave Beta a
# distinct PRODUCT_NAME ("Batty Beta"), both variants produced "Batty.app"
# and this glob could silently pick up a Beta build instead of Prod's
# (most-recently-modified wins) -- #0026's stray-copy hazard in
# scripts/release.sh is the same class of bug. After #0279, the product
# name follows the *resolved variant* (Configuration/Active.xcconfig at
# settings-evaluation time), not the scheme name used to invoke
# xcodebuild -- a stray "Batty (Prod)" build with Active.xcconfig left on
# Beta (the exact bug review round 1 caught in scripts/build-beta.sh)
# still produces "Batty Beta.app", never a literal "Batty.app" with Beta's
# contents. So this glob only ever matches a Prod-configured product; no
# logic change needed here, the rename alone fixes the original ambiguity.
BUILT_APP=$(find ~/Library/Developer/Xcode/DerivedData/Batty-* \
    -type d -name "Batty.app" -path "*/Build/Products/Debug/*" \
    ! -path "*Index.noindex*" -print0 2>/dev/null \
    | xargs -0 stat -f '%m %N' 2>/dev/null \
    | sort -rn | awk '{print $2; exit}')
if [[ -n "$BUILT_APP" && -f "$BUILT_APP/Contents/Resources/terminfo/78/xterm-ghostty" ]]; then
    pass "terminfo sentinel present in built app"
elif [[ -z "$BUILT_APP" ]]; then
    warn "no built Batty.app found in DerivedData — run a build first"
else
    fail "Batty.app/Contents/Resources/terminfo/78/xterm-ghostty missing (#0003)"
fi

# --- Version gates -----------------------------------------------------------

section "Version gates"

VERSION=$(grep -E '^MARKETING_VERSION' "$APP_XCCONFIG" 2>/dev/null | head -1 | awk -F= '{print $2}' | tr -d ' ')

if [[ -z "$VERSION" ]]; then
    fail "MARKETING_VERSION missing from $APP_XCCONFIG"
else
    pass "MARKETING_VERSION = $VERSION (App.xcconfig)"
fi

# Convention since xcconfig-as-source-of-truth: MARKETING_VERSION must
# NOT appear in pbxproj — the xcconfig provides it. Per-target overrides
# silently win at build time, so any pbxproj entry creates drift risk.
if grep -qE 'MARKETING_VERSION = ' "$PBXPROJ"; then
    DISTINCT=$(grep -E 'MARKETING_VERSION = ' "$PBXPROJ" | awk -F'= ' '{print $2}' | tr -d ' ;' | sort -u)
    fail "pbxproj contains MARKETING_VERSION ($DISTINCT) — should live only in Build.xcconfig"
else
    pass "pbxproj has no MARKETING_VERSION override (xcconfig wins)"
fi

if grep -qE 'CURRENT_PROJECT_VERSION = ' "$PBXPROJ"; then
    fail "pbxproj contains CURRENT_PROJECT_VERSION — should live only in App.xcconfig"
else
    pass "pbxproj has no CURRENT_PROJECT_VERSION override (xcconfig wins)"
fi

# SemVer-ish sanity (allow X.Y.Z plus optional -prerelease).
if [[ -n "$VERSION" ]]; then
    if [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]]; then
        pass "MARKETING_VERSION matches SemVer"
    else
        warn "MARKETING_VERSION '$VERSION' is not strict X.Y.Z"
    fi
fi

# Build-number collision gate (#0124 follow-up): release.sh derives
# CURRENT_PROJECT_VERSION as YYYYMMDD at archive time. Same-day re-releases
# would produce an identical build number to the prior one, which Sparkle
# treats as "no update available" — repeat of the 1.0.0 → 1.0.1 mistake.
# Compare today's UTC date against the highest sparkle:version already in
# the appcast.
TODAY_BUILD="$(date -u +%Y%m%d)"
APPCAST="$REPO_ROOT/website/appcast.xml"
if [[ -f "$APPCAST" ]]; then
    HIGHEST_BUILD=$(grep -oE 'sparkle:version="[0-9]+"' "$APPCAST" 2>/dev/null \
        | grep -oE '[0-9]+' | sort -rn | head -1)
    if [[ -z "$HIGHEST_BUILD" ]]; then
        pass "appcast has no prior sparkle:version (first release)"
    elif [[ "$HIGHEST_BUILD" -lt "$TODAY_BUILD" ]]; then
        pass "today's build $TODAY_BUILD > highest in appcast ($HIGHEST_BUILD)"
    elif [[ "$HIGHEST_BUILD" -eq "$TODAY_BUILD" ]]; then
        warn "today's YYYYMMDD ($TODAY_BUILD) already in appcast — same-day re-release would collide; override release.sh BUILD_NUMBER to '$(date -u +%Y%m%d%H%M)' for this one"
    else
        fail "appcast has sparkle:version $HIGHEST_BUILD > today's $TODAY_BUILD (clock skew or stale appcast)"
    fi
else
    warn "website/appcast.xml not found — skipping build-number collision check"
fi

# Marketing-version bump gate (#0226): the most common release mistake is
# forgetting to bump MARKETING_VERSION, so the new build ships with the same
# marketing version as the last release (1.0.3 shipped as 1.0.2). Sparkle then
# shows the wrong "currently running" version in its dialog. The marketing
# version in App.xcconfig must be strictly greater than the newest release
# already advertised in the appcast.
if [[ -f "$APPCAST" && -n "$VERSION" ]]; then
    NEWEST_SHORT=$(appcast_newest_attr 'sparkle:shortVersionString')
    if [[ -z "$NEWEST_SHORT" ]]; then
        pass "appcast has no prior shortVersionString (first release)"
    else
        case "$(ver_cmp "$VERSION" "$NEWEST_SHORT")" in
            1)  pass "MARKETING_VERSION $VERSION > newest released $NEWEST_SHORT" ;;
            0)  fail "MARKETING_VERSION ($VERSION) equals the newest released version — bump it before release (#0226)" ;;
            *)  fail "MARKETING_VERSION ($VERSION) is older than the newest released $NEWEST_SHORT" ;;
        esac
    fi
fi

# --- Sparkle gates -----------------------------------------------------------

section "Sparkle gates"

if (( ALLOW_NO_SPARKLE )); then
    pass "Sparkle checks skipped (--allow-no-sparkle)"
else
    if grep -q "Sparkle" "$PACKAGE_SWIFT"; then
        pass "BattyKit/Package.swift declares Sparkle dependency"
    else
        fail "BattyKit/Package.swift missing Sparkle dependency"
    fi

    # Source of truth: Configuration/App.xcconfig. Info.plist references
    # $(SU_FEED_URL) / $(SU_PUBLIC_ED_KEY), so the build-time substitution
    # is deterministic — checking xcconfig is enough and doesn't require
    # a recent build.
    SU_FEED=$(grep -E '^SU_FEED_URL' "$APP_XCCONFIG" 2>/dev/null \
        | head -1 | awk -F'=' '{sub(/^[ \t]+/, "", $2); print $2}')
    if [[ -n "$SU_FEED" ]]; then
        pass "SU_FEED_URL set in App.xcconfig: $SU_FEED"
    else
        fail "SU_FEED_URL missing from App.xcconfig (#0097)"
    fi

    SU_KEY=$(grep -E '^SU_PUBLIC_ED_KEY' "$APP_XCCONFIG" 2>/dev/null \
        | head -1 | awk -F'=' '{sub(/^[ \t]+/, "", $2); print $2}')
    if [[ -n "$SU_KEY" && "$SU_KEY" != "PLACEHOLDER_BASE64_PUBKEY_REPLACE_BEFORE_RELEASE" ]]; then
        pass "SU_PUBLIC_ED_KEY set in App.xcconfig"
    else
        warn "SU_PUBLIC_ED_KEY missing/placeholder — run Sparkle's generate_keys before release"
    fi
fi

# --- Release-pipeline gates --------------------------------------------------

section "Release-pipeline gates"

TEAM_ID=$(grep -E '^DEVELOPMENT_TEAM' "$XCCONFIG" 2>/dev/null | awk -F= '{print $2}' | tr -d ' ')
if [[ -n "$TEAM_ID" ]] && security find-identity -p codesigning -v 2>/dev/null \
    | grep -q "Developer ID Application.*$TEAM_ID"; then
    pass "Developer ID Application cert in keychain ($TEAM_ID)"
else
    warn "Developer ID Application cert not found for team $TEAM_ID (release.sh will fail)"
fi

if xcrun notarytool history --keychain-profile Batty-notary >/dev/null 2>&1; then
    pass "notarytool keychain profile 'Batty-notary' configured"
else
    warn "notarytool 'Batty-notary' keychain profile missing (run scripts/setup-keys.sh)"
fi

if command -v create-dmg >/dev/null 2>&1; then
    pass "create-dmg installed"
else
    warn "create-dmg not on PATH (brew install create-dmg)"
fi

if command -v fileicon >/dev/null 2>&1; then
    pass "fileicon installed"
else
    warn "fileicon not on PATH (brew install fileicon)"
fi

# --- Website gates -----------------------------------------------------------

section "Website gates"

if [[ -s "$REPO_ROOT/website/index.html" ]]; then
    pass "website/index.html exists and is non-empty"
else
    fail "website/index.html missing or empty"
fi

if [[ -f "$REPO_ROOT/website/appcast.xml" ]]; then
    if xmllint --noout "$REPO_ROOT/website/appcast.xml" 2>/dev/null; then
        pass "website/appcast.xml is valid XML"
    else
        fail "website/appcast.xml fails XML validation"
    fi
else
    fail "website/appcast.xml missing"
fi

# Appcast <-> DMG consistency gate (#0226): the advertised attributes must
# match the artifact they point at. The newest item's DMG, if present locally
# under website/downloads/, is mounted read-only and its real version fields +
# byte length are compared to the sparkle:* attributes. A mismatch is exactly
# what produced the 1.0.3 "you're up to date" bug. Warn-level: already-shipped
# items are historical and the hard guarantee lives in release.sh +
# appcast-item.sh; --strict promotes these to failures.
if [[ -f "$APPCAST" ]]; then
    A_SHORT=$(appcast_newest_attr 'sparkle:shortVersionString')
    A_BUILD=$(appcast_newest_attr 'sparkle:version')
    A_LENGTH=$(appcast_newest_attr 'length')
    DMG_LOCAL="$REPO_ROOT/website/downloads/Batty-$A_SHORT.dmg"
    if [[ -z "$A_SHORT" ]]; then
        pass "appcast has no items to cross-check"
    elif [[ ! -f "$DMG_LOCAL" ]]; then
        warn "newest appcast item is $A_SHORT but website/downloads/Batty-$A_SHORT.dmg is absent — cannot cross-check"
    else
        BYTES=$(stat -f '%z' "$DMG_LOCAL")
        if [[ "$BYTES" == "$A_LENGTH" ]]; then
            pass "appcast length matches Batty-$A_SHORT.dmg ($BYTES bytes)"
        else
            warn "appcast length ($A_LENGTH) != Batty-$A_SHORT.dmg byte size ($BYTES)"
        fi
        MP=$(hdiutil attach "$DMG_LOCAL" -nobrowse -readonly -mountrandom /tmp 2>/dev/null \
            | awk '/\/tmp\// {print $NF; exit}')
        if [[ -n "$MP" && -d "$MP" ]]; then
            APP_IN=$(print -r -- "$MP"/*.app(N) | head -1)
            if [[ -n "$APP_IN" ]]; then
                D_SHORT=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_IN/Contents/Info.plist" 2>/dev/null)
                D_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_IN/Contents/Info.plist" 2>/dev/null)
                if [[ "$D_SHORT" == "$A_SHORT" ]]; then
                    pass "DMG CFBundleShortVersionString matches appcast ($A_SHORT)"
                else
                    warn "DMG CFBundleShortVersionString ($D_SHORT) != appcast sparkle:shortVersionString ($A_SHORT) (#0226)"
                fi
                if [[ "$D_BUILD" == "$A_BUILD" ]]; then
                    pass "DMG CFBundleVersion matches appcast ($A_BUILD)"
                else
                    warn "DMG CFBundleVersion ($D_BUILD) != appcast sparkle:version ($A_BUILD) (#0226)"
                fi
            else
                warn "no .app inside Batty-$A_SHORT.dmg — cannot verify versions"
            fi
            hdiutil detach "$MP" -quiet 2>/dev/null || true
        else
            warn "could not mount Batty-$A_SHORT.dmg for version cross-check"
        fi
    fi
fi

if [[ -n "${BATTY_EC2_KEY:-}" && -n "${BATTY_EC2_HOST:-}" && -n "${BATTY_EC2_PATH:-}" ]]; then
    pass "EC2 deploy env vars exported (BATTY_EC2_KEY / HOST / PATH)"

    if [[ -f "${BATTY_EC2_KEY}" ]]; then
        KEY_PERMS=$(stat -f '%Lp' "${BATTY_EC2_KEY}" 2>/dev/null || stat -c '%a' "${BATTY_EC2_KEY}")
        if [[ "$KEY_PERMS" == "400" || "$KEY_PERMS" == "600" ]]; then
            pass "deploy key has $KEY_PERMS perms"
        else
            fail "deploy key $BATTY_EC2_KEY has $KEY_PERMS perms (need 400/600)"
        fi
    else
        fail "BATTY_EC2_KEY points at $BATTY_EC2_KEY which does not exist"
    fi

    if (( SKIP_SSH )); then
        pass "SSH liveness skipped (--skip-ssh-check)"
    elif [[ -f "${BATTY_EC2_KEY:-}" ]]; then
        PORT="${BATTY_EC2_PORT:-22}"
        if ssh -i "$BATTY_EC2_KEY" -p "$PORT" \
            -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            "$BATTY_EC2_HOST" true 2>/dev/null; then
            pass "ssh to $BATTY_EC2_HOST works"
        else
            warn "ssh to $BATTY_EC2_HOST failed; deploy-website.sh will fail too"
        fi
    fi
else
    pass "EC2 deploy env vars not set — manual upload path (deploy-website.sh disabled)"
fi

# --- Fork gate ---------------------------------------------------------------

section "libghostty-spm fork gate"

if grep -q '\.package(path: "../../libghostty-spm")' "$PACKAGE_SWIFT"; then
    warn "BattyKit/Package.swift uses path: form — not reproducible from a fresh checkout (#0098)"
elif grep -q 'brennanMKE/libghostty-spm' "$PACKAGE_SWIFT"; then
    REV=$(grep -A1 'brennanMKE/libghostty-spm' "$PACKAGE_SWIFT" | grep -E 'revision' | head -1 \
        | awk -F\" '{print $2}')
    if [[ -n "$REV" ]]; then
        pass "BattyKit/Package.swift pinned at brennanMKE/libghostty-spm @ ${REV:0:7}"
        # Confirm the SHA is reachable on the published branch.
        if git ls-remote https://github.com/brennanMKE/libghostty-spm refs/heads/batty-delegates 2>/dev/null \
            | grep -q "^$REV"; then
            pass "pinned SHA is on origin/batty-delegates"
        else
            warn "pinned SHA $REV not found on remote batty-delegates branch (push needed?)"
        fi
    else
        warn "Package.swift references the fork but no revision pin found"
    fi
else
    warn "Package.swift fork dependency form unrecognised"
fi

# --- Workspace gate ----------------------------------------------------------

section "Workspace gate"

DIRTY=$(git -C "$REPO_ROOT" status --porcelain)
if [[ -z "$DIRTY" ]]; then
    pass "working tree is clean"
else
    # Strip the 2-char status + space prefix; for renames take the post-arrow path.
    DIRTY_PATHS=$(print -r -- "$DIRTY" | sed 's/^...//' | awk -F' -> ' '{print $NF}')
    NON_WEBSITE=$(print -r -- "$DIRTY_PATHS" | grep -v '^website/' || true)
    if [[ -z "$NON_WEBSITE" ]]; then
        pass "working tree dirty only under website/ (release prep — expected)"
    elif (( ALLOW_DIRTY )); then
        warn "working tree dirty (--allow-dirty given)"
    else
        fail "working tree is not clean outside website/ — commit or stash first"
    fi
fi

if git -C "$REPO_ROOT" fetch origin --quiet 2>/dev/null; then
    LOCAL_HEAD=$(git -C "$REPO_ROOT" rev-parse HEAD)
    REMOTE_HEAD=$(git -C "$REPO_ROOT" rev-parse origin/main 2>/dev/null || echo "")
    if [[ -n "$REMOTE_HEAD" ]]; then
        AHEAD=$(git -C "$REPO_ROOT" rev-list --count origin/main..HEAD)
        BEHIND=$(git -C "$REPO_ROOT" rev-list --count HEAD..origin/main)
        if [[ "$AHEAD" == "0" && "$BEHIND" == "0" ]]; then
            pass "HEAD == origin/main"
        elif [[ "$BEHIND" != "0" ]]; then
            fail "local main is behind origin/main by $BEHIND — pull first"
        else
            warn "local main is ahead of origin/main by $AHEAD — push after release"
        fi
    fi
fi

# --- Summary -----------------------------------------------------------------

section "Summary"
print "  $FAILS failure(s), $WARNS warning(s)"

if (( FAILS > 0 )); then
    exit 1
fi
exit 0
