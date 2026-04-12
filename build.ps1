$LLVM_VERSION = $args[0]
$LLVM_REPO_URL = $args[1]
$TARGET_BUILD_TYPE = $args[2]

if ([string]::IsNullOrEmpty($LLVM_REPO_URL)) {
    $LLVM_REPO_URL = "https://github.com/llvm/llvm-project.git"
}

if ([string]::IsNullOrEmpty($TARGET_BUILD_TYPE)) {
    $TARGET_BUILD_TYPE = "Release"
}

$BUILD_TYPE = "Release"
$ENABLE_ASSERTIONS = "OFF"

if ($TARGET_BUILD_TYPE -eq "Debug") {
    $BUILD_TYPE = "Release"
    $ENABLE_ASSERTIONS = "ON"
}

if ([string]::IsNullOrEmpty($LLVM_VERSION)) {
    Write-Output "Usage: $PSCommandPath <llvm-version> <llvm-repository-url>"
    Write-Output ""
    Write-Output "# Arguments"
    Write-Output "  llvm-version         The name of a LLVM release branch without the 'release/' prefix"
    Write-Output "  llvm-repository-url  The URL used to clone LLVM sources (default: https://github.com/llvm/llvm-project.git)"

	exit 1
}

# Clone the LLVM project.
if (-not (Test-Path -Path "llvm-project" -PathType Container)) {
    $LLVM_REF = "release/$LLVM_VERSION"
    git clone -b $LLVM_REF --single-branch --depth=1 "$LLVM_REPO_URL" llvm-project
    if (-not $?) {
        $LLVM_REF = "llvmorg-$LLVM_VERSION"
        git clone -b $LLVM_REF --single-branch --depth=1 "$LLVM_REPO_URL" llvm-project
    }
    if (-not $?) {
        Write-Error "Error: Could not find branch 'release/$LLVM_VERSION' or tag 'llvmorg-$LLVM_VERSION'"
        exit 1
    }
} else {
    # If it already exists, we need to determine what the ref was or just try to update
    # For CI, it usually won't exist yet, but for local testing:
    $LLVM_REF = "release/$LLVM_VERSION" # Default
}

Set-Location llvm-project
git fetch origin
git checkout "$LLVM_REF"
git reset --hard "$LLVM_REF"
# Apply pdb-patch (Windows-only, only for non-Release builds)
if ($TARGET_BUILD_TYPE -eq "Debug") {
    $AddLLVM = "llvm/cmake/modules/AddLLVM.cmake"
    $LiteralPatch = @"

	get_target_property(type `${name} TYPE)
	if(`${type} STREQUAL "STATIC_LIBRARY")
		set(pdb_dir `${CMAKE_CURRENT_BINARY_DIR}/pdb)
		set_target_properties(
			`${name}
			PROPERTIES
			COMPILE_PDB_NAME_DEBUG `${name}
			COMPILE_PDB_OUTPUT_DIRECTORY_DEBUG `${pdb_dir}
			)
		install(
			FILES `${pdb_dir}/`${name}.pdb
			CONFIGURATIONS Debug
			DESTINATION lib`${LLVM_LIBDIR_SUFFIX}
			OPTIONAL
			)
	endif()

"@
    (Get-Content $AddLLVM) -replace 'endmacro\s*\(add_llvm_library', ($LiteralPatch + "`nendmacro(add_llvm_library") | Set-Content $AddLLVM
}

# Adjust compilation based on the OS.
$CMAKE_ARGUMENTS = ""

# Adjust cross compilation
$CROSS_COMPILE = ""

# PHASE 1: Build LLVM + LLD
New-Item -Path "build" -Force -ItemType "directory"
Set-Location build
New-Item -Path "build_llvm" -Force -ItemType "directory"
Set-Location build_llvm

cmake `
  -G "Ninja" `
  -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" `
  -DCMAKE_INSTALL_PREFIX="../destdir" `
  -DCMAKE_MSVC_RUNTIME_LIBRARY="MultiThreaded$<$<CONFIG:Debug>:Debug>" `
  -DLLVM_ENABLE_PROJECTS="lld" `
  -DLLVM_ENABLE_RUNTIMES="" `
  -DLLVM_ENABLE_TERMINFO=OFF `
  -DLLVM_ENABLE_ZLIB=OFF `
  -DLLVM_ENABLE_ZSTD=OFF `
  -DLLVM_ENABLE_LIBXML2=OFF `
  -DLLVM_ENABLE_CURL=OFF `
  -DLLVM_ENABLE_BINDINGS=OFF `
  -DLLVM_INCLUDE_DOCS=OFF `
  -DLLVM_INCLUDE_EXAMPLES=OFF `
  -DLLVM_INCLUDE_GO_TESTS=OFF `
  -DLLVM_INCLUDE_TESTS=OFF `
  -DLLVM_INCLUDE_BENCHMARKS=OFF `
  -DLLVM_INCLUDE_TOOLS=ON `
  -DLLVM_INCLUDE_UTILS=OFF `
  -DLLVM_OPTIMIZED_TABLEGEN=ON `
  -DLLVM_ENABLE_ASSERTIONS="${ENABLE_ASSERTIONS}" `
  -DLLVM_TARGETS_TO_BUILD="X86;AArch64;RISCV;WebAssembly;LoongArch;ARM;AVR;" `
  $CROSS_COMPILE `
  $CMAKE_ARGUMENTS `
  ../../llvm

cmake --build . --config "${BUILD_TYPE}"
cmake --install . --config "${BUILD_TYPE}"

# PHASE 2: Build compiler-rt
# Get host triple
$HOST_TRIPLE = (./bin/llvm-config.exe --host-target)

Set-Location ..
New-Item -Path "build_rt" -Force -ItemType "directory"
Set-Location build_rt

cmake `
  -G "Ninja" `
  -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" `
  -DCMAKE_INSTALL_PREFIX="../destdir" `
  -DCMAKE_MSVC_RUNTIME_LIBRARY="MultiThreaded$<$<CONFIG:Debug>:Debug>" `
  -DLLVM_CMAKE_DIR="$(Get-Item ../build_llvm/lib/cmake/llvm).FullName" `
  -DCMAKE_C_COMPILER_TARGET="$HOST_TRIPLE" `
  -DCOMPILER_RT_BUILD_BUILTINS=ON `
  -DCOMPILER_RT_BUILD_SANITIZERS=ON `
  -DCOMPILER_RT_BUILD_XRAY=OFF `
  -DCOMPILER_RT_BUILD_LIBFUZZER=OFF `
  -DCOMPILER_RT_BUILD_PROFILE=OFF `
  -DCOMPILER_RT_BUILD_MEMPROF=OFF `
  -DCOMPILER_RT_BUILD_ORC=OFF `
  -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON `
  $CROSS_COMPILE `
  $CMAKE_ARGUMENTS `
  ../../compiler-rt

cmake --build . --config "${BUILD_TYPE}"
cmake --install . --config "${BUILD_TYPE}"

Set-Location ../..
