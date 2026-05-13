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

# --- Build gates -------------------------------------------------------------

section "Build gates"

if (( SKIP_BUILD )); then
    pass "build/test skipped (--skip-build)"
else
    if DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
        xcodebuild -scheme Batty -destination 'platform=macOS' \
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
BUILT_APP=$(find ~/Library/Developer/Xcode/DerivedData/Batty-* \
    -type d -name "Batty.app" -path "*/Build/Products/Debug/*" \
    ! -path "*Index.noindex*" 2>/dev/null | head -1)
if [[ -n "$BUILT_APP" && -f "$BUILT_APP/Contents/Resources/terminfo/78/xterm-ghostty" ]]; then
    pass "terminfo sentinel present in built app"
elif [[ -z "$BUILT_APP" ]]; then
    warn "no built Batty.app found in DerivedData — run a build first"
else
    fail "Batty.app/Contents/Resources/terminfo/78/xterm-ghostty missing (#0003)"
fi

# --- Version gates -----------------------------------------------------------

section "Version gates"

VERSION=$(grep -E '^MARKETING_VERSION' "$XCCONFIG" 2>/dev/null | head -1 | awk -F= '{print $2}' | tr -d ' ')

if [[ -z "$VERSION" ]]; then
    fail "MARKETING_VERSION missing from $XCCONFIG"
else
    pass "MARKETING_VERSION = $VERSION (Build.xcconfig)"
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
    fail "pbxproj contains CURRENT_PROJECT_VERSION — should live only in Build.xcconfig"
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

    if [[ -n "$BUILT_APP" ]]; then
        FEED=$(plutil -extract SUFeedURL raw "$BUILT_APP/Contents/Info.plist" 2>/dev/null)
        if [[ -n "$FEED" && "$FEED" != "(null)" ]]; then
            pass "SUFeedURL in built Info.plist: $FEED"
        else
            fail "SUFeedURL missing from built Info.plist (#0097)"
        fi

        EDKEY=$(plutil -extract SUPublicEDKey raw "$BUILT_APP/Contents/Info.plist" 2>/dev/null)
        if [[ -n "$EDKEY" && "$EDKEY" != "PLACEHOLDER_BASE64_PUBKEY_REPLACE_BEFORE_RELEASE" ]]; then
            pass "SUPublicEDKey set in built Info.plist"
        else
            warn "SUPublicEDKey is still the placeholder — run Sparkle's generate_keys before release"
        fi
    else
        warn "no built Batty.app — can't inspect Info.plist"
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
    warn "BATTY_EC2_KEY / HOST / PATH not all set — deploy-website.sh will refuse to run"
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

if [[ -z "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
    pass "working tree is clean"
else
    if (( ALLOW_DIRTY )); then
        warn "working tree dirty (--allow-dirty given)"
    else
        fail "working tree is not clean — commit or stash first"
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
