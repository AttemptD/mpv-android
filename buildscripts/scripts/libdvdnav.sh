#!/bin/bash -e

. ../../include/path.sh

if [ "$1" == "build" ]; then
	true
elif [ "$1" == "clean" ]; then
	[ -f Makefile ] && make distclean 2>/dev/null || true
	rm -f Makefile config.status config.log libtool
	exit 0
else
	exit 255
fi

[ -x configure ] || autoreconf -fi
$0 clean

CFLAGS="${CFLAGS:-} -fPIC" ./configure --host="$ndk_triple" --prefix=/usr/local \
	--disable-shared --enable-static

make -j$cores
make DESTDIR="$prefix_dir" install
