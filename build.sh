#!/usr/bin/env zsh

set -euo pipefail

PROJECT="Batty.xcodeproj"
SCHEME="Batty (Beta)"
CONFIGURATION="Debug"
BUILD_DIR="build"

ACTIONS=("${@:-build}")

for ACTION in "${ACTIONS[@]}"; do
    case "$ACTION" in
        clean)
            xcodebuild clean \
                -project "$PROJECT" \
                -scheme "$SCHEME" \
                -configuration "$CONFIGURATION"
            ;;
        build)
            xcodebuild build \
                -project "$PROJECT" \
                -scheme "$SCHEME" \
                -configuration "$CONFIGURATION" \
                -derivedDataPath "$BUILD_DIR"
            ;;
        run)
            xcodebuild build \
                -project "$PROJECT" \
                -scheme "$SCHEME" \
                -configuration "$CONFIGURATION" \
                -derivedDataPath "$BUILD_DIR"
            APP_PATH=$(find "$BUILD_DIR" -name "Batty Beta.app" -type d | head -1)
            if [[ -z "$APP_PATH" ]]; then
                echo "Error: Batty Beta.app not found in $BUILD_DIR" >&2
                exit 1
            fi
            open "$APP_PATH"
            ;;
        terminate)
            if pkill -x "Batty Beta"; then
                echo "Batty Beta terminated."
            else
                echo "Batty Beta is not running." >&2
            fi
            ;;
        screenshot)
            "$0" clean build run
            sleep 2
            ./screenshot.sh
            "$0" terminate
            ;;
        *)
            echo "Unknown action: $ACTION" >&2
            echo "Usage: $0 [clean|build|run|terminate|screenshot] ..." >&2
            exit 1
            ;;
    esac
done
