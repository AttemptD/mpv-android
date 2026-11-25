#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 /absolute/path/to/new-bundle" >&2
    exit 2
fi
case "$1" in
    /*) output="$1" ;;
    *) output="$PWD/$1" ;;
esac
if [ -e "$output" ]; then
    echo "Bundle destination already exists: $output" >&2
    exit 2
fi

cd "$(dirname "$0")"
. ./include/depinfo.sh
export MPV_ANDROID_NDK="${MPV_ANDROID_NDK:-$PWD/sdk/android-ndk-$v_ndk}"
if ! grep -Fxq "Pkg.Revision = $v_ndk_n" "$MPV_ANDROID_NDK/source.properties"; then
    echo "The shared Afuse bundle requires NDK $v_ndk_n. Run ./download.sh or set MPV_ANDROID_NDK." >&2
    exit 1
fi

# The dependency script reads optional unset variables.
./include/download-deps.sh
if [ -n "$(git -C deps/mpv status --porcelain -- . ':(exclude)_build_*')" ]; then
    echo "Build the native bundle from the clean mpv revision $v_mpv." >&2
    exit 1
fi
for arch in armv7l arm64; do
    ./buildAfusekt.sh --clean --arch "$arch" mpv
done
python3 ./afuse-native-bundle.py export --prefix "$PWD/prefix" \
    --ndk "$MPV_ANDROID_NDK" --ndk-version "$v_ndk_n" \
    --mpv "$v_mpv" --ffmpeg "$v_ffmpeg" --libplacebo "$v_libplacebo" "$output"
