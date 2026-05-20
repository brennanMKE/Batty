#!/usr/bin/env zsh

# Find the window ID for Batty Beta
WINDOW_ID=$(windows | grep co.sstools.Batty.beta | head -1 | awk '{print $1}')

if [[ -z "$WINDOW_ID" ]]; then
    echo "Warning: Themes window not found — is the app running?" >&2
    exit 1
fi

mkdir -p screenshots

TIMESTAMP=$(date +%Y%m%d%H%M%S)
FILENAME="screenshots/screenshot_${TIMESTAMP}.png"
/usr/sbin/screencapture -l $WINDOW_ID "$FILENAME" && echo "$FILENAME"
