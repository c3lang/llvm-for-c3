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

# Detect OS
OS_TYPE="unknown"
case "${OSTYPE}" in
  linux*)   OS_TYPE="linux" ;;
  darwin*)  OS_TYPE="darwin" ;;
  msys*|cygwin*) OS_TYPE="windows" ;;
esac

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
	elif git clone -b "$LLVM_VERSION" --single-branch --depth=1 "$LLVM_REPO_URL" llvm-project; then
		LLVM_REF="$LLVM_VERSION"
	else
		echo "Error: Could not find branch 'release/$LLVM_VERSION', tag 'llvmorg-$LLVM_VERSION', or branch/tag '$LLVM_VERSION'"
		exit 1
	fi
fi

cd llvm-project
git fetch origin
git checkout "$LLVM_REF"
git reset --hard "$LLVM_REF"

# Apply pdb-patch (Windows-only, only for non-Release builds)
if [[ "$OS_TYPE" == "windows" && "$4" == "Debug" ]]; then
    echo "Applying PDB patch for Windows Debug build..."
    PDB_PATCH='
	get_target_property(type ${name} TYPE)
	if(${type} STREQUAL "STATIC_LIBRARY")
		set(pdb_dir ${CMAKE_CURRENT_BINARY_DIR}/pdb)
		set_target_properties(
			${name}
			PROPERTIES
			COMPILE_PDB_NAME_DEBUG ${name}
			COMPILE_PDB_OUTPUT_DIRECTORY_DEBUG ${pdb_dir}
			)
		install(
			FILES ${pdb_dir}/${name}.pdb
			CONFIGURATIONS Debug
			DESTINATION lib${LLVM_LIBDIR_SUFFIX}
			OPTIONAL
			)
	endif()
'
    export PDB_PATCH
    perl -i -0777 -pe 's/endmacro\s*\(add_llvm_library\)/$ENV{PDB_PATCH}\nendmacro(add_llvm_library)/g' llvm/cmake/modules/AddLLVM.cmake
fi

# Create directories
mkdir -p build
mkdir -p build_rt

# Adjust compilation based on build type
BUILD_TYPE_SPECIFIED=$4
if [[ -z "$BUILD_TYPE_SPECIFIED" ]]; then
  BUILD_TYPE_SPECIFIED="Release"
fi
BUILD_TYPE=$BUILD_TYPE_SPECIFIED

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
fi

if [[ "$OS_TYPE" == "windows" ]]; then
  # Windows-specific flags matching build.ps1
  CMAKE_ARGUMENTS="$CMAKE_ARGUMENTS -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded\$<\$<CONFIG:Debug>:Debug>"
  CMAKE_ARGUMENTS="$CMAKE_ARGUMENTS -DLLVM_ENABLE_TERMINFO=OFF"
fi

# Enable LLVM Driver to save space by merging multiple tools into one binary
CMAKE_ARGUMENTS="$CMAKE_ARGUMENTS -DLLVM_TOOL_LLVM_DRIVER_BUILD=ON"

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
  -DLLVM_ENABLE_ZLIB=$([[ "$OS_TYPE" == "windows" ]] && echo "OFF" || echo "FORCE_ON") \
  -DLLVM_ENABLE_ZSTD=$([[ "$OS_TYPE" == "windows" ]] && echo "OFF" || echo "FORCE_ON") \
  $(if [[ "$STATIC_BUILD" == "ON" ]]; then echo "-DZLIB_LIBRARY=/usr/lib/libz.a -DZLIB_INCLUDE_DIR=/usr/include -Dzstd_LIBRARY=/usr/lib/libzstd.a -Dzstd_INCLUDE_DIR=/usr/include"; fi) \
  -DLLVM_TARGETS_TO_BUILD="X86;AArch64;RISCV;WebAssembly;LoongArch;ARM;AVR;" \
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
  $(if [[ "$STATIC_BUILD" == "ON" ]]; then echo "-DBUILD_SHARED_LIBS=OFF -DLLVM_BUILD_LLVM_DYLIB=OFF -DLLVM_LINK_LLVM_DYLIB=OFF -DCMAKE_EXE_LINKER_FLAGS=-static"; elif [[ "$OS_TYPE" == "windows" ]]; then echo "-DBUILD_SHARED_LIBS=OFF -DLLVM_BUILD_LLVM_DYLIB=OFF -DLLVM_BUILD_LLVM_C_DYLIB=OFF -DLLVM_LINK_LLVM_DYLIB=OFF"; else echo "-DLLVM_BUILD_LLVM_DYLIB=ON -DLLVM_LINK_LLVM_DYLIB=ON"; fi) \
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
# Locate llvm-config inside the destdir (looking specifically in bin directories to avoid headers)
LLVM_CONFIG_PATH=$(find "$(pwd)/destdir" -path "*/bin/llvm-config*" -type f | head -n 1)
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
if [[ "$OS_TYPE" == "linux" ]]; then
  export LD_LIBRARY_PATH="$LLVM_LIB_DIR:$LD_LIBRARY_PATH"
elif [[ "$OS_TYPE" == "darwin" ]]; then
  export DYLD_LIBRARY_PATH="$LLVM_LIB_DIR:$DYLD_LIBRARY_PATH"
elif [[ "$OS_TYPE" == "windows" ]]; then
  export PATH="$LLVM_LIB_DIR:$PATH"
fi

HOST_TRIPLE=${TARGET_TRIPLE:-$("$LLVM_CONFIG_PATH" --host-target)}
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

# -- PHASE 3: Post-processing (Stripping) --
if [[ "$BUILD_TYPE_SPECIFIED" == "Release" && "$OS_TYPE" != "windows" ]]; then
  echo "Stripping binaries and libraries to save space..."
  # Strip executables (using find to avoid issues with long argument lists)
  find ../build/destdir -type f -executable -exec strip --strip-all {} + || true
  # Strip static libraries
  find ../build/destdir -name "*.a" -exec strip --strip-unneeded {} + || true
fi

echo "Final Disk Usage:"
df -h
