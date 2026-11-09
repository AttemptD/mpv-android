#!/bin/bash -e

. ../../include/path.sh

build=_build$ndk_suffix
NDK_BUILD="$(command -v ndk-build)"
if [ -z "$NDK_BUILD" ]; then
	echo "ndk-build not found in PATH" >&2
	exit 1
fi
NDK_ROOT="$(cd "$(dirname "$NDK_BUILD")" && pwd)"
TOOLCHAIN="$NDK_ROOT/build/cmake/android.toolchain.cmake"

case "$ndk_triple" in
	arm-linux-androideabi) android_abi=armeabi-v7a ;;
	aarch64-linux-android) android_abi=arm64-v8a ;;
	i686-linux-android) android_abi=x86 ;;
	x86_64-linux-android) android_abi=x86_64 ;;
	*) echo "Unknown ndk_triple: $ndk_triple" >&2; exit 1 ;;
esac

if [ "$1" == "build" ]; then
	true
elif [ "$1" == "clean" ]; then
	rm -rf "$build"
	exit 0
else
	exit 255
fi

unset CC CXX

rm -rf "$build"
cmake -B "$build" \
	-DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
	-DANDROID_ABI="$android_abi" \
	-DANDROID_PLATFORM=android-23 \
	-DCMAKE_INSTALL_PREFIX=/usr/local \
	-DBUILD_SHARED_LIBS=ON \
	-DENABLE_EXAMPLES=OFF \
	-DENABLE_GSSAPI=OFF \
	-DENABLE_LIBKRB5=OFF

cmake --build "$build" -j$cores
DESTDIR="$prefix_dir" cmake --install "$build"
