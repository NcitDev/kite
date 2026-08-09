#!/bin/bash
#
# Clears the quarantine flag macOS puts on Kite when it is downloaded, which is what makes
# Gatekeeper refuse to open it. Kite is signed, but with an ad-hoc signature rather than an
# Apple Developer ID, so it cannot be notarized and macOS will not vouch for it.
#
# Double-clicking this file will NOT work — macOS blocks downloaded scripts for exactly the
# reason you would expect. Instead:
#
#   1. Open Terminal (Applications > Utilities, or Spotlight)
#   2. Type:  bash          <- with a trailing space
#   3. Drag this file into the Terminal window
#   4. Press Return
#

set -uo pipefail

say() { printf '%s\n' "$*"; }

say ""
say "Kite — clearing the download quarantine flag"
say "==========================================="
say ""

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APP=""
for candidate in "/Applications/Kite.app" "$HOME/Applications/Kite.app"; do
  if [ -d "$candidate" ]; then
    APP="$candidate"
    break
  fi
done

if [ -z "$APP" ]; then
  # Running straight off the disk image, before the app has been installed. Clearing the
  # flag on the read-only copy would achieve nothing, since the copy made into Applications
  # gets its own.
  if [ -d "$HERE/Kite.app" ]; then
    say "Kite has not been installed yet."
    say ""
    say "Drag Kite onto the Applications folder in this window first, then run this again."
    say ""
    exit 1
  fi
  say "Could not find Kite.app in /Applications or ~/Applications."
  say ""
  say "If you installed it somewhere else, run this instead, with your own path:"
  say "  xattr -dr com.apple.quarantine /path/to/Kite.app"
  say ""
  exit 1
fi

say "Found:  $APP"

if ! xattr -l "$APP" 2>/dev/null | grep -q "com.apple.quarantine"; then
  say ""
  say "It is not quarantined — nothing to do. Kite should open normally."
  say ""
  read -r -p "Press Return to close this window. " _ || true
  exit 0
fi

if xattr -dr com.apple.quarantine "$APP" 2>/dev/null; then
  say "Cleared: com.apple.quarantine"
else
  say ""
  say "Could not clear the flag. You may need to run it yourself:"
  say "  sudo xattr -dr com.apple.quarantine \"$APP\""
  say ""
  exit 1
fi

say ""
say "Done. Opening Kite…"
open "$APP" || true
say ""
read -r -p "Press Return to close this window. " _ || true
