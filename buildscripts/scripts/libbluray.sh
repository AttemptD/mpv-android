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

$0 clean

./configure --host="$ndk_triple" --prefix=/usr/local \
	--disable-static --enable-shared \
	--disable-bdjava-jar \
	--disable-examples \
	--without-freetype \
	--without-libxml2

make -j$cores
make DESTDIR="$prefix_dir" install
