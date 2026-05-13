#!/usr/bin/env zsh
# Push the website/ tree to the EC2 host that serves https://batty.sstools.co/.
#
# Reads:
#   BATTY_EC2_KEY    Path to the .pem file. Permissions must be 400/600.
#   BATTY_EC2_HOST   user@host or user@public-dns (e.g. ec2-user@batty.sstools.co).
#   BATTY_EC2_PATH   Absolute path on the remote, e.g. /var/www/batty.
#   BATTY_EC2_PORT   (optional) SSH port; defaults to 22.
#
# Idempotent. rsync --delete keeps the remote in sync with website/, so
# files removed locally also disappear from the live site. Excludes
# .DS_Store and editor cruft.
#
# Run after a release pipeline completes and after appcast.xml has been
# regenerated for the new <item>. Does NOT bump versions, sign, notarize,
# or tag — those are separate scripts.

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h}"
SITE_DIR="$REPO_ROOT/website"

# --- Preflight ---------------------------------------------------------------

require_env() {
    local name="$1"
    local value
    value="${(P)name:-}"
    if [[ -z "$value" ]]; then
        print -u2 "error: env var $name is not set"
        print -u2 "       export $name=... before re-running"
        exit 1
    fi
}

require_env BATTY_EC2_KEY
require_env BATTY_EC2_HOST
require_env BATTY_EC2_PATH

PORT="${BATTY_EC2_PORT:-22}"

if [[ ! -f "$BATTY_EC2_KEY" ]]; then
    print -u2 "error: key file not found at $BATTY_EC2_KEY"
    exit 1
fi

KEY_PERMS=$(stat -f '%Lp' "$BATTY_EC2_KEY" 2>/dev/null || stat -c '%a' "$BATTY_EC2_KEY")
if [[ "$KEY_PERMS" != "400" && "$KEY_PERMS" != "600" ]]; then
    print -u2 "error: $BATTY_EC2_KEY has permissions $KEY_PERMS — SSH will refuse it."
    print -u2 "       chmod 600 \"$BATTY_EC2_KEY\""
    exit 1
fi

if [[ ! -d "$SITE_DIR" ]]; then
    print -u2 "error: $SITE_DIR does not exist; nothing to deploy"
    exit 1
fi

if [[ ! -f "$SITE_DIR/index.html" ]]; then
    print -u2 "error: $SITE_DIR/index.html missing — bail before pushing a broken site"
    exit 1
fi

if [[ ! -f "$SITE_DIR/appcast.xml" ]]; then
    print -u2 "warning: $SITE_DIR/appcast.xml is missing — Sparkle clients will 404 on update checks"
fi

# --- Deploy ------------------------------------------------------------------

print "==> Deploying website to $BATTY_EC2_HOST:$BATTY_EC2_PATH"
print "    Key:    $BATTY_EC2_KEY"
print "    Port:   $PORT"
print "    Source: $SITE_DIR"

SSH_OPTS=(-i "$BATTY_EC2_KEY" -p "$PORT" -o StrictHostKeyChecking=accept-new)

# Confirm the remote path exists before pushing — rsync will create files
# but not the leaf directory. Fail loudly if the user mistyped the path.
if ! ssh "${SSH_OPTS[@]}" "$BATTY_EC2_HOST" "test -d \"$BATTY_EC2_PATH\""; then
    print -u2 "error: remote directory $BATTY_EC2_PATH does not exist on $BATTY_EC2_HOST"
    print -u2 "       ssh in and create it, then re-run"
    exit 1
fi

rsync \
    -avz \
    --delete \
    --exclude '.DS_Store' \
    --exclude '*.swp' \
    --exclude '*.bak' \
    -e "ssh -i $BATTY_EC2_KEY -p $PORT -o StrictHostKeyChecking=accept-new" \
    "$SITE_DIR/" \
    "$BATTY_EC2_HOST:$BATTY_EC2_PATH/"

print "==> Done. Verify https://batty.sstools.co/ in a browser."
