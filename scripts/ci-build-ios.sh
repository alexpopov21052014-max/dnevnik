#!/usr/bin/env bash
# Сборка iOS-архива и .ipa из index.html.
# Использование: bash scripts/ci-build-ios.sh <init|sign|archive|package|export|env|pod|all>
set -euo pipefail

STEP="${1:-all}"
WEB_DIR="${WEB_DIR:-.}"
APP_ID="${APP_ID:-ru.dnevnik.app}"
APP_NAME="${APP_NAME:-Дневник}"
APP_NAME_LATIN="${APP_NAME_LATIN:-Dnevnik}"
BUNDLE_DISPLAY="${APP_NAME}"
EXPORT_METHOD="${EXPORT_METHOD:-unsigned}"
CAP_VERSION="${CAP_VERSION:-7}"
ARCHIVE_PATH="${ARCHIVE_PATH:-build/App.xcarchive}"
OUT_DIR="${OUT_DIR:-build/ipa}"

export CI=true
export CAPACITOR_TELEMETRY=0
export NPM_CONFIG_FUND=false
export NPM_CONFIG_AUDIT=false

ensure_cocoapods() {
  if command -v pod >/dev/null 2>&1; then
    echo "CocoaPods уже есть: $(pod --version)"
    return 0
  fi
  echo "CocoaPods не найден, ставлю..."
  echo "ruby: $(ruby -v 2>&1 || echo нет)"
  echo "gem:  $(gem -v 2>&1 || echo нет)"

  if command -v brew >/dev/null 2>&1; then
    echo "-> brew install cocoapods"
    brew install cocoapods && hash -r && command -v pod >/dev/null 2>&1 && { pod --version; return 0; }
  fi

  echo "-> gem install cocoapods"
  sudo gem install cocoapods --no-document -n /usr/local/bin || true
  hash -r
  if ! command -v pod >/dev/null 2>&1; then
    GEM_BIN="$(gem environment gemdir 2>/dev/null || true)/bin"
    export PATH="$PATH:$GEM_BIN:/opt/homebrew/bin:/usr/local/bin"
  fi
  command -v pod >/dev/null 2>&1 || { echo "::error::CocoaPods не установился"; exit 1; }
  pod --version
}

show_env() {
  echo "===== ENVIRONMENT ====="
  echo "node:   $(node -v 2>&1 || echo нет)"
  echo "npm:    $(npm -v 2>&1 || echo нет)"
  echo "ruby:   $(ruby -v 2>&1 || echo нет)"
  echo "pod:    $(pod --version 2>&1 || echo нет)"
  echo "xcode:  $(xcodebuild -version 2>&1 | tr '\n' ' ' || echo нет)"
  echo "sw_vers: $(sw_vers 2>&1 | tr '\n' ' ' || echo нет)"
  echo "pwd:    $(pwd)"
  echo "files:  $(ls -1 | tr '\n' ' ')"
  echo "======================="
}

init() {
  echo "== CAP INIT =="
  show_env

  mkdir -p www
  cp "$WEB_DIR/index.html" www/index.html
  [ -f "$WEB_DIR/manifest.webmanifest" ] && cp "$WEB_DIR/manifest.webmanifest" www/ || true
  [ -d "$WEB_DIR/icons" ] && cp -R "$WEB_DIR/icons" www/ || true
  echo "www: $(ls -1 www | tr '\n' ' ')"

  ensure_cocoapods

  npm init -y >/dev/null
  npm pkg set name=dnevnik-ios version=1.0.0 >/dev/null
  npm pkg set private=true >/dev/null

  echo "== npm install @capacitor $CAP_VERSION =="
  if ! npm install --no-audit --no-fund \
      "@capacitor/core@$CAP_VERSION" "@capacitor/ios@$CAP_VERSION" "@capacitor/cli@$CAP_VERSION"; then
    echo "не удалось поставить Capacitor $CAP_VERSION, пробую последнюю версию"
    npm install --no-audit --no-fund @capacitor/core @capacitor/ios @capacitor/cli
  fi
  echo "capacitor cli: $(npx cap --version 2>&1 || echo нет)"

  # конфиг пишем сами: cap init умеет уходить в интерактивный ввод и падать в CI
  node -e "require('fs').writeFileSync('capacitor.config.json', JSON.stringify({appId:process.env.APP_ID, appName:process.env.APP_NAME, webDir:'www', server:{iosScheme:'https'}}, null, 2))"
  echo "---- capacitor.config.json ----"
  cat capacitor.config.json

  echo "== cap add ios =="
  if ! npx cap add ios; then
    echo "::error::cap add ios упал"
    ls -la . ios 2>/dev/null || true
    exit 1
  fi

  echo "== cap sync ios =="
  npx cap sync ios

  if [ ! -d ios/App/Pods ]; then
    echo "== pod install (вручную) =="
    ( cd ios/App && (pod install --repo-update || pod install) )
  fi

  PLIST=ios/App/App/Info.plist
  [ -f "$PLIST" ] || { echo "::error::нет $PLIST"; ls -la ios/App/App || true; exit 1; }
  /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $BUNDLE_DISPLAY" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $BUNDLE_DISPLAY" "$PLIST"
  /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PLIST"

  echo "== cap doctor =="
  npx cap doctor || true
  echo "== IOS PROJECT =="
  ls -la ios/App
}

sign_setup() {
  echo "== SIGN SETUP =="
  : "${IPA_SIGNING_KEY_BASE64:?нет секрета IPA_SIGNING_KEY_BASE64}"
  : "${IPA_SIGNING_KEY_PASSWORD:?нет секрета IPA_SIGNING_KEY_PASSWORD}"
  : "${IPA_PROVISIONING_PROFILE_BASE64:?нет секрета IPA_PROVISIONING_PROFILE_BASE64}"

  PKG_DIR="build/signing"
  mkdir -p "$PKG_DIR"
  KEYCHAIN="$PWD/$PKG_DIR/ci.keychain-db"

  security create-keychain -p ci "$KEYCHAIN"
  security set-keychain-settings -lut 21600 "$KEYCHAIN"
  security unlock-keychain -p ci "$KEYCHAIN"

  echo "$IPA_SIGNING_KEY_BASE64" | base64 -d > "$PKG_DIR/cert.p12"
  security import "$PKG_DIR/cert.p12" -k "$KEYCHAIN" -P "$IPA_SIGNING_KEY_PASSWORD" -A \
    -T /usr/bin/codesign -T /usr/bin/security
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k ci "$KEYCHAIN" >/dev/null
  security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')

  mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"
  echo "$IPA_PROVISIONING_PROFILE_BASE64" | base64 -d > "$PKG_DIR/ci.mobileprovision"
  cp "$PKG_DIR/ci.mobileprovision" "$HOME/Library/MobileDevice/Provisioning Profiles/ci.mobileprovision"
  security cms -D -i "$PKG_DIR/ci.mobileprovision" > "$PKG_DIR/profile.plist"

  TEAM_ID=$(/usr/libexec/PlistBuddy -c "Print :TeamIdentifier:0" "$PKG_DIR/profile.plist")
  PROFILE_NAME=$(/usr/libexec/PlistBuddy -c "Print :Name" "$PKG_DIR/profile.plist")

  case "$EXPORT_METHOD" in
    development) SIGN_IDENTITY="Apple Development" ;;
    ad-hoc|app-store|enterprise) SIGN_IDENTITY="Apple Distribution" ;;
    *) SIGN_IDENTITY="Apple Development" ;;
  esac

  {
    echo "TEAM_ID=$TEAM_ID"
    echo "PROFILE_NAME=$PROFILE_NAME"
    echo "SIGN_IDENTITY=$SIGN_IDENTITY"
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
    PROVISIONING_PROFILE_SPECIFIER="${PROFILE_NAME:-}"
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
    CODE_SIGN_ENTITLEMENTS=""
  cd "$OLDPWD"
}

package_unsigned() {
  echo "== PACKAGE (unsigned .ipa) =="
  mkdir -p "$OUT_DIR"
  APP_PATH="$ARCHIVE_PATH/Products/Applications/App.app"
  [ -d "$APP_PATH" ] || { echo "::error::нет $APP_PATH"; ls -la "$ARCHIVE_PATH/Products/Applications" || true; exit 1; }
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
  env) show_env ;;
  pod) ensure_cocoapods ;;
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
