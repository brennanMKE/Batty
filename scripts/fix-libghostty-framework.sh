#!/usr/bin/env zsh
# Reshapes the macOS slice of libghostty.framework from shallow to versioned
# layout so Xcode's embed-frameworks validation accepts it.
#
# Upstream Lakr233/libghostty-spm ships macos-arm64_x86_64/libghostty.framework
# with Info.plist + binary + Headers/ + Modules/ at the framework root
# (iOS-style shallow bundle). macOS requires Versions/A/{Headers,Modules,
# Resources,binary} with symlinks at the root. See issues/0212.md for the
# full investigation, including why this can't be done as an Xcode build
# phase: ProcessXCFramework runs before any of the target's PBXShellScript
# phases, so the fixup has to be applied to the SPM artifact cache before
# xcodebuild starts a build. Run via scripts/build.sh, not Xcode directly.
#
# Usage: fix-libghostty-framework.sh [path-to-libghostty.framework]
# If no path is given, locates the framework in the most recent Batty
# DerivedData directory. Idempotent — safe to re-run; handles partial state.

set -euo pipefail

FWK="${1:-}"
if [[ -z "$FWK" ]]; then
    DD=$(/bin/ls -td "$HOME/Library/Developer/Xcode/DerivedData/Batty-"*(/N) 2>/dev/null | head -1)
    if [[ -z "$DD" ]]; then
        print -u2 "error: no Batty DerivedData directory found"
        print -u2 "(run xcodebuild -resolvePackageDependencies first)"
        exit 1
    fi
    FWK="$DD/SourcePackages/artifacts/libghostty-spm/libghostty/GhosttyKit.xcframework/macos-arm64_x86_64/libghostty.framework"
fi

if [[ ! -d "$FWK" ]]; then
    print -u2 "error: framework not found at $FWK"
    print -u2 "(run xcodebuild -resolvePackageDependencies first to populate the SPM cache)"
    exit 1
fi

if [[ -L "$FWK/libghostty" && -d "$FWK/Versions/A" ]]; then
    print "fix-libghostty-framework: $FWK already versioned"
    exit 0
fi

if [[ -e "$FWK/Versions" ]]; then
    rm -rf "$FWK/Versions"
fi
for f in libghostty Headers Modules Resources; do
    if [[ -L "$FWK/$f" ]]; then
        rm "$FWK/$f"
    fi
done

print "fix-libghostty-framework: reshaping $FWK"

cd "$FWK"
mkdir -p Versions/A/Resources
mv libghostty Headers Modules Versions/A/
mv Info.plist Versions/A/Resources/
(cd Versions && ln -s A Current)
ln -s Versions/Current/libghostty libghostty
ln -s Versions/Current/Headers Headers
ln -s Versions/Current/Modules Modules
ln -s Versions/Current/Resources Resources

print "fix-libghostty-framework: done"
