#!/usr/bin/env bash
# Build Toolbox.app (Sparkle + Developer ID signing + optional notarization).
# Usage: ./scripts/build-app.sh [--notarize | --no-notarize | --fast] [--allow-adhoc] [path/to/icon.png]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Toolbox"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
BUILD_NUMBER="${BUILD_NUMBER:-$VERSION}"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
NOTARY_PROFILE="${NOTARY_PROFILE:-notary-profile}"

NOTARIZE=2  # 2 = auto (re-notarize if previous build was notarized), 1 = force, 0 = skip
FAST=0
ALLOW_ADHOC=0
ICON_PNG="$ROOT_DIR/assets/AppIcon.png"

for arg in "$@"; do
  case "$arg" in
    --notarize) NOTARIZE=1 ;;
    --no-notarize) NOTARIZE=0 ;;
    --fast) FAST=1; NOTARIZE=0 ;;
    --allow-adhoc) ALLOW_ADHOC=1 ;;
    -h|--help)
      echo "Usage: $0 [--notarize | --no-notarize | --fast] [--allow-adhoc] [icon.png]"
      exit 0
      ;;
    *.png) ICON_PNG="$arg" ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

cd "$ROOT_DIR"

# Resolve signing identity BEFORE touching the existing bundle so a locked/sandboxed Keychain
# can never silently downgrade a Developer ID build to ad-hoc and break macOS TCC permissions.
CERT=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Developer ID Application" | awk -F'"' '{print $2}' || true)
if [[ -z "$CERT" ]]; then
  if [[ "$NOTARIZE" == "1" ]]; then
    echo "error: --notarize requires a 'Developer ID Application' certificate in Keychain" >&2
    exit 1
  elif [[ "$ALLOW_ADHOC" != "1" ]]; then
    echo "error: no 'Developer ID Application' certificate found in Keychain." >&2
    echo "Refusing to silently fall back to ad-hoc signing because changing the designated requirement breaks macOS Accessibility/Screen Recording TCC permissions." >&2
    echo "Unlock your Keychain (or run outside a sandboxed shell), or pass --allow-adhoc explicitly." >&2
    exit 1
  fi
fi

if [[ "$NOTARIZE" == "2" ]]; then
  if [[ -d "$APP_BUNDLE" ]] && codesign -v -R="notarized" "$APP_BUNDLE" >/dev/null 2>&1; then
    echo "-> auto-notarize: previous build was notarized"
  else
    NOTARIZE=0
  fi
fi

echo "Building $APP_NAME v$VERSION (build $BUILD_NUMBER)..."

bash "$ROOT_DIR/vendor/fetch-sparkle.sh"

if [[ "$FAST" == "1" ]]; then
  swift build -c debug
  BIN_PATH="$(swift build -c debug --show-bin-path)/$APP_NAME"
else
  swift build -c release
  BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"
fi

PREV_TEAM_ID=""
if [[ -d "$APP_BUNDLE" ]]; then
  PREV_TEAM_ID=$(codesign -dv "$APP_BUNDLE" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}' || true)
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" \
         "$APP_BUNDLE/Contents/Resources" \
         "$APP_BUNDLE/Contents/Frameworks" \
         "$APP_BUNDLE/Contents/Library"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD_NUMBER/g" \
    "$ROOT_DIR/Resources/Info.plist" > "$APP_BUNDLE/Contents/Info.plist"

# Bundle Sparkle framework + Updater helper
cp -R "$ROOT_DIR/vendor/sparkle/Sparkle.framework" "$APP_BUNDLE/Contents/Frameworks/"
cp -R "$ROOT_DIR/vendor/sparkle/Sparkle.framework/Versions/Current/Updater.app" "$APP_BUNDLE/Contents/Library/"

# Generate AppIcon.icns
if [[ -f "$ICON_PNG" ]]; then
  echo "Generating AppIcon.icns from $ICON_PNG..."
  ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
  rm -rf "$ICONSET_DIR"
  mkdir -p "$ICONSET_DIR"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_PNG" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
    size2x=$((size * 2))
    sips -z "$size2x" "$size2x" "$ICON_PNG" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET_DIR"
fi

# Code-sign inside-out
if [[ -n "$CERT" ]]; then
  echo "Code-signing with: $CERT"
  SIGN_FLAGS=(--force --options=runtime)
  if [[ "$NOTARIZE" != "0" ]]; then
    SIGN_FLAGS+=(--timestamp)
  fi
  codesign --sign "$CERT" "${SIGN_FLAGS[@]}" "$APP_BUNDLE/Contents/Library/Updater.app"
  codesign --sign "$CERT" --deep "${SIGN_FLAGS[@]}" "$APP_BUNDLE"
else
  echo "Warning: no Developer ID cert found — using ad-hoc signature (--allow-adhoc)"
  if [[ -n "$PREV_TEAM_ID" && "$PREV_TEAM_ID" != "not set" ]]; then
    echo "WARNING: Previous bundle was signed with TeamIdentifier=$PREV_TEAM_ID; ad-hoc signing changes the designated requirement and will break macOS Accessibility/Screen Recording TCC permissions." >&2
  fi
  NOTARIZE=0
  codesign --force --deep -s - "$APP_BUNDLE"
fi

if [[ "$NOTARIZE" != "0" ]]; then
  echo "Notarizing + stapling (profile: $NOTARY_PROFILE)..."
  NOTARIZE_ZIP="$BUILD_DIR/notarize.zip"
  rm -f "$NOTARIZE_ZIP"
  ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARIZE_ZIP"
  trap 'rm -f "$NOTARIZE_ZIP"' EXIT
  xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f "$NOTARIZE_ZIP"
  trap - EXIT
  xcrun stapler staple "$APP_BUNDLE"
  codesign -vvvv -R="notarized" "$APP_BUNDLE" >/dev/null
  echo "Built + signed + notarized: $APP_BUNDLE"
else
  echo "Built + signed: $APP_BUNDLE"
fi
