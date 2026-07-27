#!/bin/bash
#
#  build_aftl.sh
#  NextAFT
#
#  Build android-file-transfer-linux as a static library for NextAFT.
#  Run this once after cloning, or when updating the vendored AFTL source.
#
#  Prerequisites:
#    - CMake 3.10+ (brew install cmake)
#    - Xcode Command Line Tools
#
#  Usage:
#    ./build_aftl.sh          # Release build
#    ./build_aftl.sh debug    # Debug build
#    AFTL_ARCHS=arm64 ./build_aftl.sh  # Apple Silicon only
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AFTL_DIR="${SCRIPT_DIR}/Vendor/aftl"
BUILD_DIR="${AFTL_DIR}/build"
BUILD_TYPE="${1:-Release}"
ARCHITECTURES="${AFTL_ARCHS:-arm64;x86_64}"

# ---------------------------------------------------------------------------
# Check prerequisites
# ---------------------------------------------------------------------------
if ! command -v cmake &>/dev/null; then
    echo "❌ cmake not found. Install with: brew install cmake"
    exit 1
fi

if [ ! -d "$AFTL_DIR" ]; then
    echo "❌ AFTL source not found at ${AFTL_DIR}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
echo "🔧 Building AFTL (${BUILD_TYPE})..."
echo "   Source: ${AFTL_DIR}"
echo "   Build:  ${BUILD_DIR}"

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

cmake "$AFTL_DIR" \
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
    -DBUILD_QT_UI=OFF \
    -DBUILD_SHARED_LIB=OFF \
    -DBUILD_FUSE=OFF \
    -DBUILD_PYTHON=OFF \
    -DBUILD_TAGLIB=OFF \
    -DBUILD_MTPZ=OFF \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_OSX_ARCHITECTURES="${ARCHITECTURES}"

NPROC=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
make -j"${NPROC}"

# ---------------------------------------------------------------------------
# Copy artifacts
# ---------------------------------------------------------------------------
OUTPUT_DIR="${SCRIPT_DIR}/Vendor/aftl-output"
mkdir -p "${OUTPUT_DIR}/lib"
mkdir -p "${OUTPUT_DIR}/include"

# Static library
cp "${BUILD_DIR}/libmtp-ng-static.a" "${OUTPUT_DIR}/lib/" 2>/dev/null || \
cp "${BUILD_DIR}/libmtp-ng.a" "${OUTPUT_DIR}/lib/" 2>/dev/null || \
    echo "⚠️  Static library not found, checking build dir..."
ls -la "${BUILD_DIR}"/*.a 2>/dev/null || true

# Copy headers
echo "📦 Copying headers..."
rsync -a --include='*.h' --include='*/' --exclude='*' \
    "${AFTL_DIR}/mtp/" "${OUTPUT_DIR}/include/mtp/"

# Also copy USB backend headers (Darwin/IOKit)
if [ -d "${AFTL_DIR}/mtp/backend/darwin" ]; then
    rsync -a --include='*.h' --include='*/' --exclude='*' \
        "${AFTL_DIR}/mtp/backend/darwin/" "${OUTPUT_DIR}/include/mtp/backend/darwin/"
fi

echo ""
echo "✅ AFTL build complete!"
echo "   Library: ${OUTPUT_DIR}/lib/"
echo "   Headers: ${OUTPUT_DIR}/include/"
echo ""
echo "NextAFT.xcodeproj is already configured to use this library."
