#!/bin/bash
#
# Ad-hoc signs a built Kite.app and packages it as a DMG.
#
# There is no Developer ID certificate on this project yet, so the app is signed with
# an ad-hoc signature ("-"). That satisfies macOS's requirement that arm64 binaries be
# signed at all, but it carries no team identity and cannot be notarized, so Gatekeeper
# will still warn on first launch. See README-INSTALL.md for what users have to do.
#
# Usage: tools/package_kite.sh <path-to-Kite.app> [output-dir]

set -euo pipefail

APP="${1:?usage: package_kite.sh <path-to-Kite.app> [output-dir]}"
OUT="${2:-build/dist}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTITLEMENTS="$REPO/Telegram-Mac/Telegram-Mac.entitlements"

[ -d "$APP" ] || { echo "error: $APP does not exist" >&2; exit 1; }
[ -f "$ENTITLEMENTS" ] || { echo "error: missing $ENTITLEMENTS" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
echo "==> Kite $VERSION"

# Firebase ships its macOS slices in the iOS "shallow" framework layout, with the binary and
# Info.plist loose at the top level. macOS requires a versioned bundle, which is why the
# Validate phase of the Xcode build rejects them. They are genuine dynamic libraries, so they
# have to stay embedded; restructure them in place instead of dropping them.
restructure_framework() {
  local fw="$1"
  local name
  name="$(basename "$fw" .framework)"
  [ -f "$fw/$name" ] && [ ! -L "$fw/$name" ] || return 0   # already versioned

  mkdir -p "$fw/Versions/A/Resources"
  for item in "$fw"/*; do
    [ "$(basename "$item")" = "Versions" ] && continue
    mv "$item" "$fw/Versions/A/"
  done
  [ -f "$fw/Versions/A/Info.plist" ] && mv "$fw/Versions/A/Info.plist" "$fw/Versions/A/Resources/Info.plist"

  ln -sfn A "$fw/Versions/Current"
  ln -sfn "Versions/Current/$name" "$fw/$name"
  ln -sfn Versions/Current/Resources "$fw/Resources"
  for extra in Headers Modules; do
    [ -d "$fw/Versions/A/$extra" ] && ln -sfn "Versions/Current/$extra" "$fw/$extra"
  done
  chmod +x "$fw/Versions/A/$name"
  echo "    restructured $name.framework"
}

echo "==> Normalising framework layout"
for fw in "$APP"/Contents/Frameworks/*.framework; do
  restructure_framework "$fw"
done

# Code signing has to run inside-out: a bundle's signature covers everything nested in it,
# so signing the outer app first would be invalidated by every inner signature afterwards.
# Signing a bundle's designated main executable is the same operation as signing the bundle,
# so it has to be left to the -depth pass below; doing it here would seal the bundle while
# its plug-ins are still unsigned.
is_bundle_main_executable() {
  local file="$1" dir contents exe
  dir="$(dirname "$file")"
  [ "$(basename "$dir")" = "MacOS" ] || return 1
  contents="$(dirname "$dir")"
  [ -f "$contents/Info.plist" ] || return 1
  exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$contents/Info.plist" 2>/dev/null)" || return 1
  [ "$exe" = "$(basename "$file")" ]
}

echo "==> Signing nested code"
# Loose Mach-O files have to be caught by content, not by name: Sparkle's Autoupdate.app
# ships a bare `fileop` helper that is neither a bundle nor a .dylib, and an unsigned one
# anywhere inside the tree makes the enclosing bundle fail to seal.
find "$APP/Contents" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) -print0 |
  while IFS= read -r -d '' binary; do
    is_bundle_main_executable "$binary" && continue
    case "$(file -b "$binary")" in
      *Mach-O*) codesign --force --sign - --timestamp=none "$binary" ;;
    esac
  done

# -depth walks a directory's contents before the directory itself, which is exactly the
# inside-out order signing needs: Sparkle embeds an Updater.app and XPC services that must
# each carry a valid signature before the framework around them is sealed.
find "$APP/Contents" -depth \( -name '*.framework' -o -name '*.appex' -o -name '*.xpc' -o -name '*.app' \) -print0 |
  while IFS= read -r -d '' bundle; do
    codesign --force --sign - --timestamp=none "$bundle"
  done

echo "==> Signing $APP"
codesign --force --sign - --timestamp=none --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

echo "==> Building DMG"
mkdir -p "$OUT"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/Kite.app"
ln -s /Applications "$STAGE/Applications"

# Shipped alongside the app because an unnotarized build is refused on first launch and the
# fix is not discoverable. Only the instructions ship: a helper script would arrive carrying
# the same quarantine flag it exists to remove, so it cannot be double-clicked either.
if [ -d "$REPO/tools/dmg" ]; then
  cp "$REPO/tools/dmg/READ ME FIRST.txt" "$STAGE/"
fi

DMG="$OUT/Kite-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Kite $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "==> $DMG ($(du -h "$DMG" | cut -f1))"
shasum -a 256 "$DMG"
