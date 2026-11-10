# C3 Custom LLVM Builds

This repository contains scripts and GitHub Actions workflows for producing custom, lean LLVM builds specifically tailored for the [C3 Programming Language](https://c3-lang.org/) compiler ([c3c](https://github.com/c3lang/c3c)).

## Overview

The goal of this project is to provide pre-built LLVM binaries that are:
- **Lean**: Disables unnecessary features like Clang, documentation, and tests to reduce size.
- **Complete for C3**: Includes `lld` (linker) and `compiler-rt` (builtins and sanitizers) for all supported platforms.
- **Consistent**: Unified build process across Windows, macOS, and Linux.
- **Developer Friendly**: Provides both optimized `Release` builds and `Debug` builds (including PDBs on Windows) for easier compiler debugging.

## Supported Platforms

We produce artifacts for the following architectures and operating systems:

| OS | Architecture | Build Types |
|----|--------------|-------------|
| **Linux** | `amd64`, `aarch64`, `riscv64` | Release, Debug |
| **macOS** | `amd64` (Intel), `arm64` (Apple Silicon) | Release, Debug |
| **Windows** | `amd64` (x64) | Release, Debug |

## Configuration Details

These builds are configured with the following key settings:
- **Projects**: `lld` enabled.
- **Runtimes**: `compiler-rt` (Builtins and Sanitizers including ASan/TSan/UBSan where supported).
- **Targets**: `X86`, `AArch64`, `RISCV`, `WebAssembly`, `LoongArch`, `ARM`.
- **Optimization**: `Release` used for Debug builds to keep them usable while retaining assertions.
- **Static Linking**: Designed to be statically linked into the `c3c` binary where applicable.
- ~~**Optimization**: `RelWithDebInfo` used for Debug builds to keep them usable while retaining symbols.~~
- ~~**Strip**: Debug symbols are retained in Debug builds; Release builds are stripped.~~

## CI & Releases

Artifacts are automatically built on every push to the `main` branch, and are published to GitHub Releases whenever a tag matching `llvm_*` is pushed.

The version used is currently pinned to **LLVM 23.1.0** (`llvmorg-23.1.1` tag).

## Attribution

This project is inspired by the excellent [wasmerio/llvm-custom-builds](https://github.com/wasmerio/llvm-custom-builds) repository. We thank the Wasmer team for providing such a solid foundation for automated LLVM builds.

# License

The scripts in this repository are licensed under the MIT License. LLVM itself is licensed under the Apache License v2.0 with LLVM Exceptions.
