#!/bin/zsh
set -euo pipefail
source "${0:A:h}/swift_env.sh"
if [[ "$(uname -m)" != "arm64" ]]; then
  print -u2 "This application targets Apple Silicon only."
  exit 1
fi
swift build "${SWIFT_FLAGS[@]}" -c release --arch arm64
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
APP_PATH="$TASK_ROOT/Distribution/Build-$APP_VERSION/Codex Model Lens.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp .build/arm64-apple-macosx/release/CodexModelLens "$APP_PATH/Contents/MacOS/CodexModelLens"
cp Resources/Info.plist "$APP_PATH/Contents/Info.plist"
mkdir -p "$APP_PATH/Contents/Resources/NetworkCapture"
cp Resources/NetworkCapture/model_capture.py Resources/NetworkCapture/mitmproxy-LICENSE.txt "$APP_PATH/Contents/Resources/NetworkCapture/"
swift -sdk "$TASK_SDK" -module-cache-path "$CLANG_MODULE_CACHE_PATH" Scripts/make_icon.swift "$TASK_ROOT/Resources"
cp Resources/AppIcon.icns "$APP_PATH/Contents/Resources/AppIcon.icns"
swift -sdk "$TASK_SDK" -module-cache-path "$CLANG_MODULE_CACHE_PATH" Scripts/package_provider_icons.swift "$TASK_ROOT/Resources"
cp -R Resources/ProviderIcons "$APP_PATH/Contents/Resources/"
cp .build/arm64-apple-macosx/release/model-lens Distribution/model-lens
codesign --force --sign "${MODEL_LENS_SIGNING_IDENTITY:--}" --options runtime "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$TASK_ROOT/Distribution/Codex-Model-Lens-$APP_VERSION-arm64.zip"
print "Built: $APP_PATH"
