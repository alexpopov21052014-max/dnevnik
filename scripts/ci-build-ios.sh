#!/usr/bin/env bash
# Сборка iOS-архива и .ipa из index.html.
set -euo pipefail

STEP="${1:-all}"
WEB_DIR="${WEB_DIR:-.}"
APP_ID="${APP_ID:-ru.dnevnik.app}"
APP_NAME="${APP_NAME:-Дневник}"
APP_NAME_LATIN="${APP_NAME_LATIN:-Dnevnik}"
BUNDLE_DISPLAY="${APP_NAME}"
EXPORT_METHOD="${EXPORT_METHOD:-unsigned}"
ARCHIVE_PATH="${ARCHIVE_PATH:-build/App.xcarchive}"
OUT_DIR="${OUT_DIR:-build/ipa}"
XCODE_MAJOR="${XCODE_MAJOR:-15}"

init() {
  echo "== CAP INIT =="
  mkdir -p www
  cp "$WEB_DIR/index.html" www/index.html
  [ -f "$WEB_DIR/manifest.webmanifest" ] && cp "$WEB_DIR/manifest.webmanifest" www/ || true
  [ -d "$WEB_DIR/icons" ] && cp -R "$WEB_DIR/icons" www/ || true

  npm init -y >/dev/null
  npm pkg set name=dnevnik-ios version=1.0.0 private=true
  npm install --no-audit --no-fund @capacitor/core@6 @capacitor/ios@6 @capacitor/cli@6

  npx cap init "$APP_NAME" "$APP_ID" --web-dir=www --npm-client npm || true
  npx cap add ios
  npx cap sync ios

  PLIST=ios/App/App/Info.plist
  /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $BUNDLE_DISPLAY" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $BUNDLE_DISPLAY" "$PLIST"
  /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PLIST"
}

sign_setup() {
  echo "== SIGN SETUP =="
  : "${IPA_SIGNING_KEY_BASE64:?нет секрета IPA_SIGNING_KEY_BASE64}"
  : "${IPA_SIGNING_KEY_PASSWORD:?нет секрета IPA_SIGNING_KEY_PASSWORD}"
  : "${IPA_PROVISIONING_PROFILE_BASE64:?нет секрета IPA_PROVISIONING_PROFILE_BASE64}"

  KEYCHAIN="build/ci.keychain-db"
  security create-keychain -p ci "$KEYCHAIN"
  security set-keychain-settings -lut 21600 "$KEYCHAIN"
  security unlock-keychain -p ci "$KEYCHAIN"

  echo "$IPA_SIGNING_KEY_BASE64" | base64 -d > build/cert.p12
  security import build/cert.p12 -k "$KEYCHAIN" -P "$IPA_SIGNING_KEY_PASSWORD" -A -T /usr/bin/codesign -T /usr/bin/security
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k ci "$KEYCHAIN" >/dev/null
  security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | sed 's/"//g')

  mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"
  echo "$IPA_PROVISIONING_PROFILE_BASE64" | base64 -d > build/ci.mobileprovision
  cp build/ci.mobileprovision "$HOME/Library/MobileDevice/Provisioning Profiles/ci.mobileprovision"
  security cms -D -i build/ci.mobileprovision > build/profile.plist

  TEAM_ID=$(/usr/libexec/PlistBuddy -c "Print :TeamIdentifier:0" build/profile.plist)
  PROFILE_NAME=$(/usr/libexec/PlistBuddy -c "Print :Name" build/profile.plist)

  case "$EXPORT_METHOD" in
    development) SIGN_IDENTITY="Apple Development" ;;
    ad-hoc|app-store|enterprise) SIGN_IDENTITY="Apple Distribution" ;;
    *) SIGN_IDENTITY="Apple Development" ;;
  esac

  {
    echo "TEAM_ID=$TEAM_ID"
    echo "PROFILE_NAME=$PROFILE_NAME"
    echo "SIGN_IDENTITY=$SIGN_IDENTITY"
    echo "KEYCHAIN=$KEYCHAIN"
  } >> "${GITHUB_ENV:-/dev/null}"

  echo "team=$TEAM_ID profile=$PROFILE_NAME identity=$SIGN_IDENTITY"
  python3 scripts/make_export_options.py
}

archive_signed() {
  echo "== ARCHIVE (signed, $EXPORT_METHOD) =="
  cd ios/App
  xcodebuild archive \
    -workspace App.xcworkspace \
    -scheme App \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$OLDPWD/$ARCHIVE_PATH" \
    DEVELOPMENT_TEAM="${TEAM_ID:-}" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Development}" \
    PROVISIONING_PROFILE_SPECIFIER="${PROFILE_NAME:-}" \
    -quiet
  cd "$OLDPWD"
}

archive_unsigned() {
  echo "== ARCHIVE (unsigned) =="
  cd ios/App
  xcodebuild archive \
    -workspace App.xcworkspace \
    -scheme App \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$OLDPWD/$ARCHIVE_PATH" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGN_ENTITLEMENTS="" \
    -quiet
  cd "$OLDPWD"
}

package_unsigned() {
  echo "== PACKAGE (unsigned .ipa) =="
  mkdir -p "$OUT_DIR"
  APP_PATH="$ARCHIVE_PATH/Products/Applications/App.app"
  [ -d "$APP_PATH" ] || { echo "нет $APP_PATH"; ls -la "$ARCHIVE_PATH/Products/Applications" || true; exit 1; }
  rm -rf build/Payload
  mkdir -p build/Payload
  cp -R "$APP_PATH" build/Payload/App.app
  rm -rf build/Payload/App.app/_CodeSignature build/Payload/App.app/embedded.mobileprovision
  ( cd build && zip -qry "$OLDPWD/$OUT_DIR/$APP_NAME_LATIN-unsigned.ipa" Payload )
  ls -lh "$OUT_DIR"
}

export_signed() {
  echo "== EXPORT (signed .ipa) =="
  mkdir -p "$OUT_DIR"
  python3 scripts/make_export_options.py
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$OUT_DIR" \
    -exportOptionsPlist ExportOptions.plist \
    -allowProvisioningUpdates
  ls -lh "$OUT_DIR"
}

case "$STEP" in
  init) init ;;
  sign) sign_setup ;;
  archive) if [ "$EXPORT_METHOD" = "unsigned" ]; then archive_unsigned; else archive_signed; fi ;;
  package) package_unsigned ;;
  export) export_signed ;;
  all)
    init
    if [ "$EXPORT_METHOD" = "unsigned" ]; then archive_unsigned; package_unsigned; else sign_setup; archive_signed; export_signed; fi
    ;;
  *) echo "неизвестный шаг: $STEP"; exit 2 ;;
esac
