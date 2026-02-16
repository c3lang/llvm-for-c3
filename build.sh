#!/bin/bash

set -o errexit
set -o errtrace

LLVM_VERSION=$1
LLVM_REPO_URL=${2:-https://github.com/llvm/llvm-project.git}
LLVM_CROSS="$3"

if [[ -z "$LLVM_REPO_URL" || -z "$LLVM_VERSION" ]]
then
  echo "Usage: $0 <llvm-version> <llvm-repository-url> [aarch64/riscv64]"
  exit 1
fi

# Detect musl build
STATIC_BUILD=""
if [[ "$LLVM_CROSS" == *musl* ]]; then
  STATIC_BUILD="ON"
fi

# Clone the LLVM project.
if [ ! -d llvm-project ]
then
	if git clone -b "release/$LLVM_VERSION" --single-branch --depth=1 "$LLVM_REPO_URL" llvm-project; then
		LLVM_REF="release/$LLVM_VERSION"
	elif git clone -b "llvmorg-$LLVM_VERSION" --single-branch --depth=1 "$LLVM_REPO_URL" llvm-project; then
		LLVM_REF="llvmorg-$LLVM_VERSION"
	else
		echo "Error: Could not find branch 'release/$LLVM_VERSION' or tag 'llvmorg-$LLVM_VERSION'"
		exit 1
	fi
fi

cd llvm-project
git fetch origin
git checkout "$LLVM_REF"
git reset --hard "$LLVM_REF"

# Create directories
mkdir -p build
mkdir -p build_rt

# Adjust compilation based on build type
BUILD_TYPE=$4
if [[ -z "$BUILD_TYPE" ]]; then
  BUILD_TYPE="Release"
fi

# Adjust cross-compilation (Only RISC-V requires cross-compiling on current CI runners)
CROSS_COMPILE=""
TARGET_TRIPLE=""
if [[ "$LLVM_CROSS" == *riscv64* ]]; then
    TARGET_TRIPLE="riscv64-linux-gnu"
    CROSS_COMPILE="-DLLVM_HOST_TRIPLE=$TARGET_TRIPLE -DCMAKE_C_COMPILER=riscv64-linux-gnu-gcc-13 -DCMAKE_CXX_COMPILER=riscv64-linux-gnu-g++-13 -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=riscv64"
fi

# Set defaults
ENABLE_ASSERTIONS="OFF"
OPTIMIZED_TABLEGEN="ON"
PARALLEL_LINK_FLAGS=""
BUILD_PARALLEL_FLAGS=""
CMAKE_ARGUMENTS=""

if [[ "$BUILD_TYPE" == "Debug" ]]; then
  BUILD_TYPE="Release"
  ENABLE_ASSERTIONS="ON"

  # if [[ "${OSTYPE}" == linux* ]]; then
  #   # Grouped Linux-specific Debug optimizations to save memory on CI
  #   CMAKE_ARGUMENTS="-DLLVM_USE_SPLIT_DWARF=ON"
  #   #OPTIMIZED_TABLEGEN="OFF"
  #   PARALLEL_LINK_FLAGS="-DLLVM_PARALLEL_LINK_JOBS=2"
  #   BUILD_PARALLEL_FLAGS="--parallel 2"
  # fi
fi

df -h

# -- PHASE 1: Build LLVM + LLD --
cd build
cmake \
  -G Ninja \
  -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
  -DCMAKE_DISABLE_FIND_PACKAGE_LibXml2=TRUE \
  -DCMAKE_INSTALL_PREFIX="/" \
  -DLLVM_ENABLE_PROJECTS="lld" \
  -DLLVM_ENABLE_RUNTIMES="" \
  -DLLVM_ENABLE_ZLIB=OFF \
  -DLLVM_ENABLE_ZSTD=OFF \
  -DLLVM_TARGETS_TO_BUILD="X86;AArch64;RISCV;WebAssembly;LoongArch;ARM" \
  -DLLVM_INCLUDE_DOCS=OFF \
  -DLLVM_BUILD_TESTS=OFF \
  -DLLVM_ENABLE_ASSERTIONS="${ENABLE_ASSERTIONS}" \
  -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_ENABLE_LIBXML2=0 \
  -DLLVM_ENABLE_DOXYGEN=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DLLVM_INCLUDE_TOOLS=ON \
  -DLLVM_INCLUDE_RUNTIMES=OFF \
  -DLLVM_INCLUDE_UTILS=OFF \
  -DLLVM_ENABLE_CURL=OFF \
  -DLLVM_ENABLE_BINDINGS=OFF \
  -DLLVM_OPTIMIZED_TABLEGEN="${OPTIMIZED_TABLEGEN}" \
  $(if [[ "$STATIC_BUILD" == "ON" ]]; then echo "-DBUILD_SHARED_LIBS=OFF -DLLVM_BUILD_LLVM_DYLIB=OFF -DLLVM_LINK_LLVM_DYLIB=OFF -DCMAKE_EXE_LINKER_FLAGS=-static"; else echo "-DLLVM_BUILD_LLVM_DYLIB=ON -DLLVM_LINK_LLVM_DYLIB=ON"; fi) \
  ${CROSS_COMPILE} \
  ${PARALLEL_LINK_FLAGS} \
  ${CMAKE_ARGUMENTS} \
  ../llvm

cmake --build . --config "${BUILD_TYPE}" ${BUILD_PARALLEL_FLAGS}

find . -name "*.o" -type f -delete || true
find . -name "*.dwo" -type f -delete || true

DESTDIR=destdir cmake --install . --config "${BUILD_TYPE}"

find . -maxdepth 1 ! -name 'destdir' ! -name 'bin' ! -name 'lib' ! -name '.' -exec rm -rf {} + || true

# -- PHASE 2: Build compiler-rt (Builtins & Sanitizers) --

# --- AUTO-DISCOVERY ---
# Locate llvm-config inside the destdir (it might be in /bin or /usr/bin)
LLVM_CONFIG_PATH=$(find "$(pwd)/destdir" -name llvm-config -type f | head -n 1)
if [[ -z "$LLVM_CONFIG_PATH" ]]; then
  echo "Error: Could not find llvm-config"
  exit 1
fi

LLVM_CMAKE_DIR_PATH=$(find "$(pwd)/destdir" -name LLVMConfig.cmake -type f -exec dirname {} + | head -n 1)
if [[ -z "$LLVM_CMAKE_DIR_PATH" ]]; then
  echo "Error: Could not find LLVMConfig.cmake"
  exit 1
fi
echo "Found LLVM CMake dir at: $LLVM_CMAKE_DIR_PATH"

# We need the host triple for standalone compiler-rt build. 
# Skip running llvm-config if cross-compiling to avoid Exec format errors.
LLVM_LIB_DIR=$(find "$(pwd)/destdir" -name "lib" -type d | head -n 1)

# Tell the OS where to find libLLVM.so so llvm-config can run
if [[ "${OSTYPE}" == linux* ]]; then
  export LD_LIBRARY_PATH="$LLVM_LIB_DIR:$LD_LIBRARY_PATH"
elif [[ "${OSTYPE}" == darwin* ]]; then
  export DYLD_LIBRARY_PATH="$LLVM_LIB_DIR:$DYLD_LIBRARY_PATH"
fi

HOST_TRIPLE=${TARGET_TRIPLE:-$($LLVM_CONFIG_PATH --host-target)}
echo "Host Triple: $HOST_TRIPLE"

cd ../build_rt
cmake \
  -G Ninja \
  -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
  -DCMAKE_INSTALL_PREFIX="/" \
  -DLLVM_CMAKE_DIR="$LLVM_CMAKE_DIR_PATH" \
  -DCMAKE_C_COMPILER_TARGET="${HOST_TRIPLE}" \
  -DCOMPILER_RT_BUILD_BUILTINS=ON \
  $(if [[ "$STATIC_BUILD" == "ON" ]]; then echo "-DCOMPILER_RT_BUILD_SANITIZERS=OFF"; else echo "-DCOMPILER_RT_BUILD_SANITIZERS=ON"; fi) \
  -DCOMPILER_RT_BUILD_XRAY=OFF \
  -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
  -DCOMPILER_RT_BUILD_PROFILE=OFF \
  -DCOMPILER_RT_BUILD_MEMPROF=OFF \
  -DCOMPILER_RT_BUILD_ORC=OFF \
  -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
  ${CROSS_COMPILE} \
  ${CMAKE_ARGUMENTS} \
  ../compiler-rt

echo "Building compiler-rt..."
df -h

cmake --build . --config "${BUILD_TYPE}" ${BUILD_PARALLEL_FLAGS}

echo "Installing compiler-rt..."
df -h

# Install to the same destdir as LLVM
DESTDIR=../build/destdir cmake --install . --config "${BUILD_TYPE}"

echo "Final Disk Usage:"
df -h
