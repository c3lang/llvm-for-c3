#!/usr/bin/env bash
set -euo pipefail

# Configurations
LLVM_VERSION="${1:-}"
LLVM_REPO_URL="${2:-https://github.com/llvm/llvm-project.git}"
BUILD_TYPE="${3:-Release}"

if [[ -z "$LLVM_VERSION" ]]; then
  echo "Usage: $0 <llvm-version> [llvm-repository-url] [Release/Debug]"
  exit 1
fi

echo "Using LLVM Version:  ${LLVM_VERSION}"
echo "Using Repo URL:      ${LLVM_REPO_URL}"
echo "Build Type:          ${BUILD_TYPE}"

# Clone the LLVM project (matching the logic in build.sh)
LLVM_REF="$LLVM_VERSION"
if [ ! -d llvm-project ]; then
  echo "Cloning llvm-project..."
  if git clone -b "release/$LLVM_VERSION" --single-branch --depth=1 "$LLVM_REPO_URL" llvm-project; then
    LLVM_REF="release/$LLVM_VERSION"
  elif git clone -b "llvmorg-$LLVM_VERSION" --single-branch --depth=1 "$LLVM_REPO_URL" llvm-project; then
    LLVM_REF="llvmorg-$LLVM_VERSION"
  elif git clone -b "$LLVM_VERSION" --single-branch --depth=1 "$LLVM_REPO_URL" llvm-project; then
    LLVM_REF="$LLVM_VERSION"
  else
    echo "Error: Could not find branch/tag for version '$LLVM_VERSION'"
    exit 1
  fi
fi

cd llvm-project
git fetch origin
git checkout "$LLVM_REF"
git reset --hard "$LLVM_REF"

# 1. Build the Native Host TableGen Tool
# We unset Emscripten variables within a subshell to ensure the host compiler is used
if [ ! -f build_host/bin/llvm-tblgen ]; then
  echo "Building native host tools (llvm-tblgen)..."
  (
    unset CC CXX CFLAGS CXXFLAGS LDFLAGS
    cmake -S llvm -B build_host -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DLLVM_BUILD_TOOLS=OFF \
      -DLLVM_INCLUDE_TESTS=OFF
    cmake --build build_host --target llvm-tblgen
  )
fi

# 2. Build LLVM/LLD Static Libraries for WebAssembly using Emscripten
echo "Building LLVM/LLD static libraries for WebAssembly..."
mkdir -p build_wasm

# Clean and recreate destdir for packaging
rm -rf build/destdir
mkdir -p build/destdir

emcmake cmake -S llvm -B build_wasm -G Ninja \
  -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
  -DCMAKE_INSTALL_PREFIX="/" \
  -DLLVM_ENABLE_PROJECTS="lld" \
  -DLLVM_TARGETS_TO_BUILD="WebAssembly" \
  -DLLVM_DEFAULT_TARGET_TRIPLE="wasm32-unknown-wasi" \
  -DLLVM_TABLEGEN="$(pwd)/build_host/bin/llvm-tblgen" \
  -DLLVM_ENABLE_THREADS=OFF \
  -DLLVM_ENABLE_ZLIB=OFF \
  -DLLVM_ENABLE_ZSTD=OFF \
  -DLLVM_ENABLE_BACKTRACES=OFF \
  -DLLVM_ENABLE_LIBXML2=OFF \
  -DCMAKE_DISABLE_FIND_PACKAGE_LibXml2=TRUE \
  -DLLVM_ENABLE_BINDINGS=OFF \
  -DLLVM_BUILD_TOOLS=OFF \
  -DLLVM_INCLUDE_TOOLS=ON \
  -DLLVM_INCLUDE_UTILS=OFF \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DLLVM_INCLUDE_DOCS=OFF \
  -DLLVM_ENABLE_DOXYGEN=OFF \
  -DLLVM_ENABLE_PIC=OFF

cmake --build build_wasm

# 3. Install to staged destdir (so package.sh functions seamlessly)
echo "Staging libraries for packaging..."
cmake --install build_wasm --prefix "build/destdir"

echo "WebAssembly LLVM/LLD built and staged successfully!"