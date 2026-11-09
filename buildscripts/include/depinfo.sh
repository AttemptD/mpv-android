#!/bin/bash -e

## Dependency versions
# Make sure to keep v_ndk and v_ndk_n in sync, both are listed on the NDK download page

v_sdk=11076708_latest
v_ndk=r30
v_ndk_n=30.0.16248370
v_sdk_platform=36
v_sdk_build_tools=36.0.0

v_lua=5.2.4
v_unibreak=8.0
v_harfbuzz=15.0.0
v_fribidi=1.0.17
v_freetype=2.15.0
v_mbedtls=3.6.7
v_libxml2=2.15.4
v_fontconfig=2.18.3
v_curl=8.23.0

# The mpv fork includes the Android patches; keep the official base for exports.
mpv_repository=https://github.com/AttemptD/mpv.git
mpv_upstream_repository=https://github.com/mpv-player/mpv.git
v_mpv_upstream=d9d402dc07d02c9aa178fb3e33adc390fa2785cc
v_mpv=18520fd59582feed78cbceaf55626d36f059f84b
v_libplacebo=275f7dea27924cdd34ab2e6c20e448b6bc4fab65
v_ffmpeg=d32b387f2b0a484599d4587d651891f0c63c4238

v_libsmb2=libsmb2-6.2
v_libbluray=1.3.4
v_libdvdcss=1.4.3
v_libdvdread=6.1.3
v_libdvdnav=6.1.1


## Dependency tree

dep_mbedtls=()
dep_dav1d=()
dep_libxml2=()
dep_libsmb2=()
dep_libbluray=()
dep_libdvdcss=()
dep_libdvdread=(libdvdcss)
dep_libdvdnav=(libdvdread)
dep_ffmpeg=(mbedtls dav1d libxml2 libsmb2)
dep_freetype2=()
dep_fontconfig=(libxml2 freetype2)
dep_fribidi=()
dep_harfbuzz=()
dep_unibreak=()
dep_libass=(freetype2 fontconfig fribidi harfbuzz unibreak)
dep_lua=()
dep_libplacebo=()
dep_curl=(mbedtls)
dep_mpv=(ffmpeg libass lua libplacebo curl libbluray libdvdnav)
dep_mpv_android=(mpv)


## for CI workflow

# pinned ffmpeg revision
v_ci_ffmpeg=n9.0.2

# filename used to uniquely identify a build prefix
ci_tarball="prefix-n${v_ndk}-l${v_lua}-u${v_unibreak}-h${v_harfbuzz}-fr${v_fribidi}-ft${v_freetype}-x${v_libxml2}-fo${v_fontconfig}-m${v_mbedtls}-c${v_curl}-smb${v_libsmb2}-bd${v_libbluray}-dvd${v_libdvdnav}-pl${v_libplacebo}-ff${v_ci_ffmpeg}.tgz"
