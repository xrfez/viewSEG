#!/usr/bin/env bash
# Cross-builds a static SDL3 for x86_64-windows-gnu with zig, for `nim winRelease`.
#
#   tools/sdl3-windows.sh [PREFIX]
#
# PREFIX defaults to $SDL3_WINDOWS_PREFIX, else ~/.cache/viewSEG/sdl3-<version>-x86_64-windows-gnu
# (the place config.nims looks). It ends up with include/SDL3/*.h and lib/libSDL3.a.
# Skips the build when PREFIX/lib/libSDL3.a exists. Needs git, cmake, ninja and zig.
#
# The version matches sdl3_nim 3.4.18.0 and the Linux SDL (CI, nim-dev image). This
# belongs in the nim-dev image later, next to the Linux SDL build, with
# SDL3_WINDOWS_PREFIX set there.
set -euo pipefail

version=3.4.18
target=x86_64-windows-gnu
prefix=${1:-${SDL3_WINDOWS_PREFIX:-$HOME/.cache/viewSEG/sdl3-$version-$target}}

if [ -f "$prefix/lib/libSDL3.a" ]; then
  echo "sdl3-windows: $prefix/lib/libSDL3.a already built"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# CMake wants single programs for the compiler and archiver, not `zig cc`.
mkdir -p "$work/bin"
for tool in cc c++ ar ranlib rc; do
  printf '#!/bin/sh\nexec zig %s "$@"\n' "$tool" > "$work/bin/zig-$tool"
  chmod +x "$work/bin/zig-$tool"
done

git clone -q --depth 1 --branch "release-$version" \
  https://github.com/libsdl-org/SDL.git "$work/SDL"

# Static only, no tests or examples. The flags SDL's own MinGW build relies on are set by
# its CMake (Windows host APIs: WASAPI, DirectSound, XInput, D3D, OpenGL via WGL).
cmake -S "$work/SDL" -B "$work/build" -G Ninja \
  -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
  -DCMAKE_C_COMPILER="$work/bin/zig-cc" -DCMAKE_C_COMPILER_TARGET=$target \
  -DCMAKE_CXX_COMPILER="$work/bin/zig-c++" -DCMAKE_CXX_COMPILER_TARGET=$target \
  -DCMAKE_AR="$work/bin/zig-ar" -DCMAKE_RANLIB="$work/bin/zig-ranlib" \
  -DCMAKE_RC_COMPILER="$work/bin/zig-rc" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_INSTALL_LIBDIR=lib \
  -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
  -DSDL_TEST_LIBRARY=OFF
cmake --build "$work/build"
cmake --install "$work/build"
echo "sdl3-windows: installed $prefix/lib/libSDL3.a"
