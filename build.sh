#!/bin/bash
set -e

# Build configuration
SCHEME="Murmur"
APP_NAME="Murmur"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Defaults. The script builds, installs over the copy in /Applications and
# relaunches it, because that is the only copy that has the permissions
# (microphone, accessibility, screen recording) the app actually needs.
BUILD_CONFIG="release"
INSTALL_DIR="/Applications"
DO_INSTALL=1
DO_LAUNCH=1

usage() {
    cat <<'USAGE'
Usage: ./build.sh [debug|release] [options]

Builds Murmur.app, installs it, and relaunches it.

Options:
  --no-install          Build the bundle only; leave the installed copy alone.
  --no-launch           Install, but don't relaunch afterwards.
  --install-dir <dir>   Install somewhere other than /Applications.
  -h, --help            Show this message.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        debug|release)
            BUILD_CONFIG="$1"
            ;;
        --no-install)
            DO_INSTALL=0
            ;;
        --no-launch)
            DO_LAUNCH=0
            ;;
        --install-dir)
            if [ -z "${2:-}" ]; then
                echo "❌ --install-dir needs a directory" >&2
                exit 1
            fi
            INSTALL_DIR="$2"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "❌ Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

BUILD_DIR="$SCRIPT_DIR/.build/arm64-apple-macosx/${BUILD_CONFIG}"
APP_BUNDLE="$SCRIPT_DIR/build/${APP_NAME}.app"
INSTALLED_APP="${INSTALL_DIR%/}/${APP_NAME}.app"
INSTALLED_BINARY="$INSTALLED_APP/Contents/MacOS/${SCHEME}"

echo "🔨 Building ${APP_NAME} (${BUILD_CONFIG})..."
swift build -c "$BUILD_CONFIG" -Xswiftc -swift-version -Xswiftc 5

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

if [ "$DO_INSTALL" -eq 0 ]; then
    echo ""
    echo "Skipping install (--no-install). To install by hand:"
    echo "  ditto \"$APP_BUNDLE\" \"$INSTALLED_APP\""
    exit 0
fi

# A `swift run` instance holds the same hotkeys and HTTP port as the installed
# app, so flag it rather than silently ending up with two menu-bar icons.
DEV_PIDS="$(pgrep -f "$SCRIPT_DIR/.build/.*/${SCHEME}$" 2>/dev/null || true)"
if [ -n "$DEV_PIDS" ]; then
    echo ""
    echo "⚠️  A dev build is running (pid$([ "$(echo "$DEV_PIDS" | wc -l)" -gt 1 ] && echo s) $(echo $DEV_PIDS))."
    echo "    It will keep port 7878 and the global shortcuts. Quit it first if that matters."
fi

echo ""
echo "🚚 Installing to ${INSTALLED_APP}..."

if [ ! -d "$INSTALL_DIR" ]; then
    echo "❌ Install directory does not exist: $INSTALL_DIR" >&2
    exit 1
fi
if [ ! -w "$INSTALL_DIR" ]; then
    echo "❌ No write permission for $INSTALL_DIR." >&2
    echo "   Run it yourself with elevated rights, or pass --install-dir <somewhere writable>:" >&2
    echo "     sudo ditto \"$APP_BUNDLE\" \"$INSTALLED_APP\"" >&2
    exit 1
fi

# Quit the installed copy. Replacing a running bundle leaves the old process
# on the old files and the new binary never gets exercised.
WAS_RUNNING=0
RUNNING_PIDS="$(pgrep -f "^${INSTALLED_BINARY}$" 2>/dev/null || true)"
if [ -n "$RUNNING_PIDS" ]; then
    WAS_RUNNING=1
    echo "  ⏹  Quitting the running copy (pid $(echo $RUNNING_PIDS))..."
    osascript -e "quit app id \"com.murmur.app\"" >/dev/null 2>&1 || true

    # Graceful first, then escalate. The app tears down audio taps and flushes
    # history on terminate, so give it a real chance to finish.
    for _ in $(seq 1 20); do
        pgrep -f "^${INSTALLED_BINARY}$" >/dev/null 2>&1 || break
        sleep 0.25
    done
    if pgrep -f "^${INSTALLED_BINARY}$" >/dev/null 2>&1; then
        echo "  ⏹  Still running — sending TERM..."
        pkill -f "^${INSTALLED_BINARY}$" 2>/dev/null || true
        for _ in $(seq 1 12); do
            pgrep -f "^${INSTALLED_BINARY}$" >/dev/null 2>&1 || break
            sleep 0.25
        done
    fi
    if pgrep -f "^${INSTALLED_BINARY}$" >/dev/null 2>&1; then
        echo "  ⏹  Forcing quit..."
        pkill -9 -f "^${INSTALLED_BINARY}$" 2>/dev/null || true
        sleep 0.5
    fi
fi

# Replace rather than merge: a stale framework or resource bundle left behind
# by an older build is very hard to diagnose afterwards.
rm -rf "$INSTALLED_APP"
ditto "$APP_BUNDLE" "$INSTALLED_APP"
xattr -cr "$INSTALLED_APP" 2>/dev/null || true
echo "  ✅ Installed"

if [ "$DO_LAUNCH" -eq 0 ]; then
    if [ "$WAS_RUNNING" -eq 1 ]; then
        echo "  ℹ️  The app was running and is now stopped (--no-launch)."
    fi
    echo ""
    echo "✅ Deployed: $INSTALLED_APP"
    exit 0
fi

echo "🚀 Launching..."
open -a "$INSTALLED_APP"

# Verify it came up, and tell the two failure modes apart.
#
# Every build carries a fresh ad-hoc signature, so macOS treats the app as a
# brand-new binary and puts up a Keychain prompt per stored secret. Until those
# are answered, startup is parked in SecItemCopyMatching on the main thread:
# /health still answers (it runs off-main) but every main-actor route hangs.
# That reads exactly like a broken build unless it is spelled out.
HEALTH_URL="http://127.0.0.1:7878/api/v1/health"
STATUS_URL="http://127.0.0.1:7878/api/v1/draft/status"

echo "🔎 Waiting for the app to answer..."
HEALTHY=0
for _ in $(seq 1 30); do
    if curl -fsS -m 2 "$HEALTH_URL" >/dev/null 2>&1; then
        HEALTHY=1
        break
    fi
    sleep 1
done

echo ""
if [ "$HEALTHY" -eq 0 ]; then
    echo "⚠️  Deployed, but the HTTP server never answered $HEALTH_URL."
    echo "    Check Console (subsystem com.murmur.app) or run:"
    echo "      sample ${SCHEME} 2"
elif curl -fsS -m 8 "$STATUS_URL" >/dev/null 2>&1; then
    echo "✅ Deployed and healthy: $INSTALLED_APP"
else
    echo "✅ Deployed: $INSTALLED_APP"
    echo ""
    echo "⚠️  Main-thread routes aren't answering yet — there is almost certainly a"
    echo "    Keychain dialog waiting for you. Click \"Always Allow\" on each one."
    echo "    Cause: this build has a new ad-hoc signature, so the Keychain ACL for"
    echo "    every stored secret has to be granted again. Startup blocks in"
    echo "    SecItemCopyMatching until then; confirm with: sample ${SCHEME} 2"
fi
