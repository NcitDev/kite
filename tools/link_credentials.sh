#!/bin/bash
#
# Puts your Telegram API credentials outside the repository and symlinks them into the
# source tree, so `git clean -fdx` cannot delete them and no api_hash can be committed.
#
# Usage: tools/link_credentials.sh

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STORE="${XDG_CONFIG_HOME:-$HOME/.config}/kite"
REAL="$STORE/Credentials.swift"
LINK="$REPO/packages/ApiCredentials/Sources/ApiCredentials/Credentials.swift"
TEMPLATE="$REPO/packages/ApiCredentials/Credentials.example.swift"

mkdir -p "$STORE"
chmod 700 "$STORE"

if [ ! -f "$REAL" ]; then
  cp "$TEMPLATE" "$REAL"
  chmod 600 "$REAL"
  echo "Created $REAL"
  echo
  echo "Fill in the pair from https://my.telegram.org, then run this again:"
  echo "  \$EDITOR $REAL"
  exit 1
fi

if grep -q 'apiId: Int32 = 0' "$REAL"; then
  echo "error: $REAL still has the placeholder apiId." >&2
  echo "Fill in your values from https://my.telegram.org first." >&2
  exit 1
fi

# -h rather than -f: a dangling symlink is still something we want to replace.
if [ -h "$LINK" ] || [ -f "$LINK" ]; then
  rm "$LINK"
fi
ln -s "$REAL" "$LINK"

echo "Linked $LINK"
echo "     -> $REAL"
