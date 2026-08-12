#!/bin/zsh
# scripts/screenshot-batty.sh
# Capture a screenshot of the Batty window and return the file path.

usage() {
    cat <<'EOF'
Usage: batty-screenshot.sh [-o <output-dir>] [-h]

Options:
  -o, --output-directory <dir>   Output directory for screenshots (default: ~/Desktop)
  -h, --help                     Show this help text

Description:
  Captures a screenshot of the Batty window and saves it to the specified directory.
  If no output directory is provided, defaults to ~/Desktop.

Examples:
  batty-screenshot.sh
  batty-screenshot.sh -o /tmp/screenshots
  batty-screenshot.sh --output-directory ~/Pictures/Batty
EOF
}

OUTPUT_DIR="$HOME/Desktop"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output-directory)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: $1 requires a directory argument" >&2
                exit 1
            fi
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

WINDOW_ID=$(windows --json | jq -r '.[] | select(.appName == "Batty") | .windowID' | head -1)

if [ -z "$WINDOW_ID" ] || [ "$WINDOW_ID" = "null" ]; then
    echo "ERROR: Batty window not found" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_PATH="${OUTPUT_DIR}/batty-${TIMESTAMP}.png"

screencapture -x -l "$WINDOW_ID" "$OUTPUT_PATH"
echo "$OUTPUT_PATH"
