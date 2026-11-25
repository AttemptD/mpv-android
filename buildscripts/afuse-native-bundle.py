#!/usr/bin/env python3
"""Export and install the shared Android runtime used by both Afuse apps."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ABIS = {"armeabi-v7a": "armv7l", "arm64-v8a": "arm64"}
LIBRARIES = (
    "libavcodec.so", "libavdevice.so", "libavfilter.so", "libavformat.so",
    "libavutil.so", "libbluray.so", "libmpv.so", "libsmb2.so",
    "libswresample.so", "libswscale.so",
)
INPUT_PATCHES = (
    "ffmpeg-upstream-20261109.patch",
    "libplacebo-upstream-20261109.patch",
    "mbedtls-android-arm32-aesce.patch",
)


def sha256(file):
    digest = hashlib.sha256()
    with file.open("rb") as src:
        for chunk in iter(lambda: src.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def llvm_bin(ndk, expected_version):
    properties = (ndk / "source.properties").read_text()
    match = re.search(r"^Pkg\.Revision\s*=\s*(\S+)", properties, re.M)
    if not match or match[1] != expected_version:
        raise ValueError(f"{ndk} must be NDK {expected_version}")
    candidates = [
        host / "bin" for host in (ndk / "toolchains/llvm/prebuilt").iterdir()
        if (host / "bin/llvm-nm").is_file()
    ]
    if len(candidates) != 1:
        raise ValueError(f"Expected one LLVM toolchain in {ndk}")
    return candidates[0]


def bridge_symbols():
    binding = HERE.parent / "app/src/main/java/is/xyz/mpv/ExoSubtitles.java"
    return {
        "Java_is_xyz_mpv_ExoSubtitles_" + method
        for method in re.findall(r"\bnative\s+\w+\s+(\w+)\(", binding.read_text())
    }


def check_mpv(library, nm, revision, expected_symbols):
    symbols = {
        row.split()[-1] for row in run(nm, "-D", "--defined-only", library).splitlines()
    }
    missing = sorted(expected_symbols - symbols)
    if missing:
        raise ValueError(f"{library} is missing JNI symbols: {', '.join(missing)}")
    contents = library.read_bytes()
    features = (revision[:8].encode(), b"android-gl-trace\0", b"Clamping HW+ sampling")
    if any(feature not in contents for feature in features):
        raise ValueError(f"{library} is missing the pinned revision, GL diagnostics or SDR sampling")


def export_bundle(args):
    llvm = llvm_bin(args.ndk, args.ndk_version)
    output = args.output.resolve()
    if output.exists():
        raise ValueError(f"Bundle destination already exists: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    # Record exact build inputs separately from the hashes of the stripped output.
    manifest = {
        "schema": 1,
        "mpv": args.mpv,
        "ffmpeg": args.ffmpeg,
        "libplacebo": args.libplacebo,
        "ndk": args.ndk_version,
        "patches": {name: sha256(HERE / "patches" / name) for name in INPUT_PATCHES},
        "abiLibraries": {},
    }
    expected_symbols = bridge_symbols()
    if not expected_symbols:
        raise ValueError("No Exo subtitle JNI declarations were found")
    with tempfile.TemporaryDirectory(prefix=".afuse-native-", dir=output.parent) as temp:
        stage = Path(temp) / "bundle"
        for abi, arch in ABIS.items():
            library_dir = stage / "libs" / abi
            library_dir.mkdir(parents=True)
            records = manifest["abiLibraries"][abi] = {}
            for name in LIBRARIES:
                source = args.prefix / arch / "lib" / name
                target = library_dir / name
                subprocess.run([llvm / "llvm-strip", "--strip-unneeded", "-o", target, source], check=True)
                if name == "libmpv.so":
                    check_mpv(target, llvm / "llvm-nm", args.mpv, expected_symbols)
                alignments = [
                    int(line.split()[-1], 16)
                    for line in run(llvm / "llvm-readelf", "-lW", target).splitlines()
                    if line.strip().startswith("LOAD ")
                ]
                if not alignments or min(alignments) < 16384:
                    raise ValueError(f"{source} lacks 16 KiB ELF segment alignment")
                machine = "ARM" if abi == "armeabi-v7a" else "AArch64"
                header = run(llvm / "llvm-readelf", "-h", target)
                if not re.search(rf"^\s*Machine:\s+{machine}$", header, re.M):
                    raise ValueError(f"{source} does not match {abi}")
                records[name] = sha256(target)
        (stage / "native-engine.json").write_text(json.dumps(manifest, indent=2) + "\n")
        stage.rename(output)
    print(f"Exported {args.mpv} for {', '.join(ABIS)} to {output}")


def install_bundle(args):
    bundle = args.bundle.resolve()
    manifest_file = bundle / "native-engine.json"
    manifest = json.loads(manifest_file.read_text())
    if manifest.get("schema") != 1 or set(manifest["abiLibraries"]) != set(ABIS):
        raise ValueError(f"Unexpected native engine manifest: {manifest_file}")
    for abi, records in manifest["abiLibraries"].items():
        if set(records) != set(LIBRARIES):
            raise ValueError(f"Incomplete runtime for {abi}")
        for name, expected in records.items():
            if sha256(bundle / "libs" / abi / name) != expected:
                raise ValueError(f"Invalid bundle library: {abi}/{name}")

    modules = [root.resolve() / "mpv" for root in args.apps]
    for module in modules:
        for abi in ABIS:
            if not (module / "src/main/libs" / abi / "libplayer.so").is_file():
                raise ValueError(f"Missing existing app JNI bridge for {abi} in {module}")
    for module in modules:
        with tempfile.TemporaryDirectory(prefix=".afuse-native-", dir=module) as temp:
            stage = Path(temp)
            shutil.copytree(bundle / "libs", stage / "libs")
            shutil.copyfile(manifest_file, stage / "native-engine.json")
            shutil.copyfile(HERE / "verify-afuse-native.gradle", stage / "verify-afuse-native.gradle")
            for abi in ABIS:
                for name in LIBRARIES:
                    os.replace(stage / "libs" / abi / name, module / "src/main/libs" / abi / name)
            os.replace(stage / "verify-afuse-native.gradle", module / "verify-afuse-native.gradle")
            # Publish the lock last. An interrupted copy fails the APK hash check.
            os.replace(stage / "native-engine.json", module / "native-engine.json")
        print(f"Installed {manifest['mpv']} in {module}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    export = commands.add_parser("export")
    export.add_argument("--prefix", type=Path, required=True)
    export.add_argument("--ndk", type=Path, required=True)
    export.add_argument("--ndk-version", required=True)
    export.add_argument("--mpv", required=True)
    export.add_argument("--ffmpeg", required=True)
    export.add_argument("--libplacebo", required=True)
    export.add_argument("output", type=Path)
    export.set_defaults(action=export_bundle)
    install = commands.add_parser("install")
    install.add_argument("bundle", type=Path)
    install.add_argument("apps", type=Path, nargs="+")
    install.set_defaults(action=install_bundle)
    args = parser.parse_args()
    try:
        args.action(args)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
