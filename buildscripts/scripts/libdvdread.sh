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

CPPFLAGS="-I$prefix_dir/include" CFLAGS="${CFLAGS:-} -fPIC" \
	./configure --host="$ndk_triple" --prefix=/usr/local \
	--disable-shared --enable-static \
	--with-libdvdcss \
	--disable-apidoc

make -j$cores
make DESTDIR="$prefix_dir" install

# libtool rewrites static dependency paths to the final /usr/local prefix
# during DESTDIR install. Keep the archive usable by the next cross build.
$SED -i "s|/usr/local/lib/libdvdcss.la|$prefix_dir/lib/libdvdcss.la|g" \
	"$prefix_dir/lib/libdvdread.la"
