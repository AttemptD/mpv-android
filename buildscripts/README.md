# Building

Compiling the native parts is a process separate from Gradle and the app won't work if you skip this.

This process is supported on Linux and macOS. Windows (or WSL) will **not** work.

## Download dependencies

`download.sh` will take care of installing the Android SDK, NDK and downloading the sources.

If you're running on Debian/Ubuntu or RHEL/Fedora it will also install the necessary dependencies for you.

```sh
./download.sh
```

If you already have the Android SDK installed you can symlink `android-sdk-linux` to your SDK root
before running the script and the necessary SDK packages will still be installed.

A matching NDK version (inside the SDK) will be picked up automatically or downloaded and installed otherwise.

## Build

```sh
./buildall.sh
```

Run `buildall.sh` with `--clean` to clean the build directories before building.
For a guaranteed clean build also run `rm -rf prefix` beforehand.

By default this will build only for 32-bit ARM (`armv7l`).
You probably want to build for AArch64 too, and perhaps Intel x86.

To do this run one (or more) of these commands **before** ./buildall.sh:
```sh
./buildall.sh --arch arm64 mpv
./buildall.sh --arch x86 mpv
./buildall.sh --arch x86_64 mpv
```

# Developing

## Getting logs

```sh
adb logcat # get all logs, useful when drivers/vendor libs output to logcat
adb logcat -s mpv # get only mpv logs
```

## Rebuilding a single component

If you've made changes to a single component (e.g. ffmpeg or mpv) and want a new build you can of course just run ./buildall.sh but it's also possible to just build a single component like this:

```sh
./buildall.sh -n ffmpeg
# optional: add --clean to build from a clean state
```

Note that you might need to rebuild for other architectures (`--arch`) too depending on your device.

Afterwards, build mpv-android and install the apk:

```sh
./buildall.sh -n
adb install -r ../app/build/outputs/apk/default/debug/app-default-universal-debug.apk
```

## Using Android Studio

You can use Android Studio to develop the Java part of the codebase. Before using it, make sure to build the project at least once by following the steps in the **Build** section.

You should point Android Studio to existing SDK installation at `mpv-android/buildscripts/sdk/android-sdk-linux`.
Then click "Open an existing Android Studio project" and select `mpv-android`.

Note that if you build from Android Studio only the Java/Kotlin part will be built.
If you make any changes to libraries (ffmpeg, mpv, ...) or mpv-android native code (`app/src/main/jni/*`), first rebuild native code with:

```sh
./buildall.sh -n
```

then build the project from Android Studio.

# Maintaining the Afuse forks

The `codex/afuse` branches in [mpv-android](https://github.com/AttemptD/mpv-android/tree/codex/afuse)
and [mpv](https://github.com/AttemptD/mpv/tree/codex/afuse) hold the local changes.
Each local repository uses `origin` for the personal fork and `upstream` for the
official repository. The `master` branches retain the official baseline.

`include/depinfo.sh` records the exact mpv fork commit in `v_mpv`, its official
base in `v_mpv_upstream`, and the source URLs. Dependency downloads and CI use
the fork commit directly. The consolidated mpv patch is retained as an export;
it is not applied a second time. libplacebo continues to use a pinned upstream
revision plus its local patch.

Merge `upstream/master` into `codex/afuse` in each repository to sync. After
testing and pushing an updated mpv core, update the outer project's `v_mpv`
pin and patch export, then commit and push the outer repository. See the
[sync record](../docs/upstream-sync-20261109.txt) for commands and validation.
