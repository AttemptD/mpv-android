#!/bin/bash -e

. ../../include/path.sh

if [ "$1" == "build" ]; then
	true
elif [ "$1" == "clean" ]; then
	make clean
	exit 0
else
	exit 255
fi

$0 clean # separate building not supported, always clean
if [[ "$ndk_triple" == "i686"* ]]; then
	./scripts/config.py unset MBEDTLS_AESNI_C
else
	./scripts/config.py set MBEDTLS_AESNI_C
fi

# since 3.6.6 mbedTLS defaults to /dev/random, which is known to block unnecessarily
./scripts/config.py set MBEDTLS_PLATFORM_DEV_RANDOM '"/dev/urandom"'

mbedtls_make_args=()
if [[ "$ndk_triple" == "arm-linux-androideabi" ]]; then
	aesce_patch=../../patches/mbedtls-android-arm32-aesce.patch
	if ! patch -f -s -R -p1 --dry-run < "$aesce_patch" >/dev/null 2>&1; then
		patch -f -s -p1 --dry-run < "$aesce_patch"
		patch -f -s -p1 < "$aesce_patch"
	fi
	mbedtls_make_args+=(MBEDTLS_ANDROID_ARM32_AESCE=1)
fi

make -j"$cores" "${mbedtls_make_args[@]}" no_test
make DESTDIR="$prefix_dir" "${mbedtls_make_args[@]}" install
