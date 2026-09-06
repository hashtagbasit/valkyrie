#!/bin/bash
# Build Valkyrie and assemble a runnable .app bundle.
#
# Needs only the Xcode Command Line Tools — no full Xcode. Swift Package Manager
# produces the executable and this script wraps it in the bundle macOS expects.
set -e
cd "$(dirname "$0")"

APP="Valkyrie.app"
CONTENTS="$APP/Contents"
VERSION="${VERSION:-1.0.0}"

echo ">>> Building (release)..."
swift build -c release

echo ">>> Assembling $APP ..."
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp .build/release/Valkyrie "$CONTENTS/MacOS/Valkyrie"

# Ship the flash engine, the lz4 decompressor and libusb inside the bundle so the
# app needs nothing installed. Without this, a user would have to clone a repo,
# install four Homebrew packages and compile C++ before flashing anything.
if [ -d Vendor ]; then
  mkdir -p "$CONTENTS/Resources/bin"
  cp Vendor/heimdall Vendor/lz4 Vendor/libusb-1.0.0.dylib "$CONTENTS/Resources/bin/"
  chmod +x "$CONTENTS/Resources/bin/heimdall" "$CONTENTS/Resources/bin/lz4"
  echo "    bundled: heimdall, lz4, libusb"
fi

if [ -f Resources/Valkyrie.icns ]; then
  cp Resources/Valkyrie.icns "$CONTENTS/Resources/Valkyrie.icns"
  ICON_ENTRY="<key>CFBundleIconFile</key><string>Valkyrie</string>"
else
  ICON_ENTRY=""
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Valkyrie</string>
    <key>CFBundleDisplayName</key><string>Valkyrie</string>
    <key>CFBundleIdentifier</key><string>dev.local.valkyrie</string>
    <key>CFBundleExecutable</key><string>Valkyrie</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    $ICON_ENTRY
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS will launch it locally without a developer certificate.
# The nested binaries are signed first — signing the bundle alone leaves them invalid.
for nested in "$CONTENTS/Resources/bin/"*; do
  [ -e "$nested" ] && codesign --force --sign - "$nested" 2>/dev/null
done
codesign --force --sign - "$APP" 2>/dev/null || echo "    (ad-hoc signing skipped)"

echo ">>> Built $(pwd)/$APP"
