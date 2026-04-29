#!/bin/bash
set -o errexit

# Packaging Script
# Usage: ./package.sh [Release/Debug] [Extension (tar.gz/tar.xz)] [Extra Tar Args]

BUILD_TYPE=${1:-Release}
EXTENSION=${2:-tar.xz}
EXTRA_TAR_ARGS=$3

mkdir -p dist
SUFFIX=""
if [ "$BUILD_TYPE" = "Debug" ]; then
  SUFFIX="-dbg"
fi

COMPRESSION_FLAG="-z"
if [[ "$EXTENSION" == *"xz"* ]]; then
  COMPRESSION_FLAG="-J"
  export XZ_OPT="-9 -T0"
fi

echo "Packaging LLVM (${BUILD_TYPE}) to dist/llvm${SUFFIX}.${EXTENSION}..."

tar --directory llvm-project/build/destdir \
    --create ${COMPRESSION_FLAG} --verbose \
    $EXTRA_TAR_ARGS \
    --file dist/llvm${SUFFIX}.${EXTENSION} .

echo "Package created: dist/llvm${SUFFIX}.${EXTENSION}"
