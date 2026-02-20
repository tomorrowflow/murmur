#!/bin/bash
set -e

# Build configuration
SCHEME="Murmur"
BUILD_CONFIG="${1:-release}"
APP_NAME="Murmur"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build/arm64-apple-macosx/${BUILD_CONFIG}"
APP_BUNDLE="$SCRIPT_DIR/build/${APP_NAME}.app"

echo "🔨 Building ${APP_NAME} (${BUILD_CONFIG})..."
swift build -c "$BUILD_CONFIG"

echo "📦 Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy Info.plist
cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Copy app icon
if [ -f "$SCRIPT_DIR/Sources/AppIcon.icns" ]; then
    cp "$SCRIPT_DIR/Sources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    echo "  ✅ Copied app icon"
fi

# Copy the binary (this IS the CFBundleExecutable — no wrapper script)
cp "$BUILD_DIR/$SCHEME" "$APP_BUNDLE/Contents/MacOS/${SCHEME}"

# Copy SPM resource bundles into Contents/Resources/
for bundle in "$BUILD_DIR"/*.bundle; do
    if [ -d "$bundle" ]; then
        cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
        echo "  ✅ Copied resource bundle: $(basename "$bundle")"
    fi
done

# Copy framework dependencies
for fw in "$BUILD_DIR"/*.framework; do
    if [ -d "$fw" ]; then
        mkdir -p "$APP_BUNDLE/Contents/Frameworks"
        cp -R "$fw" "$APP_BUNDLE/Contents/Frameworks/"
        echo "  ✅ Copied framework: $(basename "$fw")"
    fi
done

# Copy dylibs
for dylib in "$BUILD_DIR"/*.dylib; do
    if [ -f "$dylib" ]; then
        mkdir -p "$APP_BUNDLE/Contents/Frameworks"
        cp "$dylib" "$APP_BUNDLE/Contents/Frameworks/"
        echo "  ✅ Copied dylib: $(basename "$dylib")"
    fi
done

# Fix rpaths so the binary finds frameworks in Contents/Frameworks/
echo "🔧 Fixing rpaths..."
BINARY="$APP_BUNDLE/Contents/MacOS/${SCHEME}"
install_name_tool -add_rpath @executable_path/../Frameworks "$BINARY" 2>/dev/null || true

# Sign individual components (we can't sign the whole .app due to symlinks at root)
echo "🔏 Code signing..."
if [ -d "$APP_BUNDLE/Contents/Frameworks" ]; then
    for item in "$APP_BUNDLE/Contents/Frameworks/"*; do
        codesign --force --deep --sign - "$item" 2>/dev/null || true
    done
fi
codesign --force --sign - "$BINARY"

# Create symlinks at the .app root pointing to Contents/Resources/*.bundle
# SPM's auto-generated Bundle.module accessor checks Bundle.main.bundleURL/<name>.bundle
# For a .app, Bundle.main.bundleURL is the .app root, so we need symlinks there.
# This MUST happen after codesigning (symlinks would cause "unsealed contents" error).
for bundle in "$APP_BUNDLE/Contents/Resources/"*.bundle; do
    if [ -d "$bundle" ]; then
        BNAME="$(basename "$bundle")"
        ln -s "Contents/Resources/$BNAME" "$APP_BUNDLE/$BNAME"
        echo "  🔗 Symlinked: $BNAME"
    fi
done

# Clear quarantine attribute
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

echo ""
echo "✅ Build complete: $APP_BUNDLE"
echo ""
echo "To install, run:"
echo "  cp -R \"$APP_BUNDLE\" /Applications/"
echo ""
echo "Or drag build/${APP_NAME}.app to your Applications folder."
