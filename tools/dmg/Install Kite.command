#!/bin/bash
#
# Installs Kite: copies it to /Applications, clears the download quarantine flag that makes
# Gatekeeper refuse to open it, launches it, and closes this Terminal window.
#
# Kite is signed, but with an ad-hoc signature rather than an Apple Developer ID, so it
# cannot be notarized and macOS will not vouch for it. Clearing the flag is what lets it run.
#
# Double-clicking this file will NOT work — macOS blocks downloaded scripts too. Instead:
#
#   1. Open Terminal (Applications > Utilities, or Spotlight)
#   2. Type:  bash          <- with a trailing space
#   3. Drag this file into the Terminal window
#   4. Press Return
#

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="/Applications/Kite.app"

say() { printf '%s\n' "$*"; }
fail() { say ""; say "$*"; say ""; read -r -p "Press Return to close. " _ || true; exit 1; }

# Closes the window this script was dragged into. Backgrounded with a delay so the script has
# already exited by the time it fires — Terminal prompts before closing a window with a live
# process in it, and this way there is none.
close_this_window() {
  local tty_name
  tty_name="$(tty 2>/dev/null)" || return 0
  case "$tty_name" in /dev/*) ;; *) return 0 ;; esac
  (
    sleep 1
    osascript >/dev/null 2>&1 <<OSA
tell application "Terminal"
    repeat with w in windows
        try
            repeat with t in tabs of w
                if tty of t is "$tty_name" then close w
            end repeat
        end try
    end repeat
end tell
OSA
  ) >/dev/null 2>&1 &
}

say ""
say "Installing Kite"
say "==============="
say ""

SOURCE=""
if [ -d "$HERE/Kite.app" ]; then
  SOURCE="$HERE/Kite.app"
elif [ -d "$TARGET" ]; then
  say "Kite is already in Applications; just clearing the quarantine flag."
else
  fail "Could not find Kite.app next to this script, or in /Applications."
fi

if [ -n "$SOURCE" ]; then
  # Replacing a running copy would leave a half-written bundle behind.
  if pgrep -f "$TARGET/Contents/MacOS/Kite" >/dev/null 2>&1; then
    say "Quitting the running copy of Kite…"
    osascript -e 'tell application id "dev.kiteapp.Kite" to quit' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      pgrep -f "$TARGET/Contents/MacOS/Kite" >/dev/null 2>&1 || break
      sleep 1
    done
  fi

  say "Copying to /Applications… (this takes a moment, it is a large app)"
  rm -rf "$TARGET" 2>/dev/null

  # ditto rather than cp: the app contains framework version symlinks that must survive.
  if ! ditto "$SOURCE" "$TARGET" 2>/dev/null; then
    say "Needs permission to write to /Applications; you will be asked to authenticate."
    if ! osascript -e "do shell script \"ditto '$SOURCE' '$TARGET'\" with administrator privileges" >/dev/null 2>&1; then
      fail "Could not copy Kite into /Applications. Drag it there manually, then run this again."
    fi
  fi
  say "Installed: $TARGET"
fi

if xattr -l "$TARGET" 2>/dev/null | grep -q "com.apple.quarantine"; then
  if xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null; then
    say "Cleared:   com.apple.quarantine"
  else
    if ! osascript -e "do shell script \"xattr -dr com.apple.quarantine '$TARGET'\" with administrator privileges" >/dev/null 2>&1; then
      fail "Could not clear the quarantine flag. Run this yourself:
  sudo xattr -dr com.apple.quarantine \"$TARGET\""
    fi
    say "Cleared:   com.apple.quarantine"
  fi
else
  say "Not quarantined — nothing to clear."
fi

say ""
say "Opening Kite…"
open "$TARGET" || fail "Installed, but could not launch it. Open Kite from Applications."

say "Done. You can eject the disk image."
close_this_window
exit 0
