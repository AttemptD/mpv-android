#!/usr/bin/env python3
"""Package the exact native payload of a freshly built universal test APK.

This audits architecture, DT_NEEDED closure, ELF LOAD alignment and patch markers.
It does not claim runtime or color correctness from compilation alone.
"""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ABIS = {
    "armeabi-v7a": "ARM",
    "arm64-v8a": "AArch64",
    "x86": "Intel 80386",
    "x86_64": "Advanced Micro Devices X86-64",
}
SYSTEM = {
    "libc.so", "libm.so", "libdl.so", "liblog.so", "libz.so",
    "libandroid.so", "libOpenSLES.so", "libEGL.so", "libGLESv2.so",
    "libGLESv3.so", "libmediandk.so", "libjnigraphics.so",
}


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    parser.add_argument("output", type=Path, help="New, non-existing directory")
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() or output.with_suffix(".zip").exists():
        parser.error("Refusing to overwrite an existing artifact")
    readelf = next((ROOT / "buildscripts/sdk/android-ndk-r29/toolchains/llvm/prebuilt").glob("*/bin/llvm-readelf"))
    output.mkdir(parents=True)
    records = []
    with zipfile.ZipFile(args.apk) as apk:
        for abi, machine in ABIS.items():
            members = [i for i in apk.namelist() if i.startswith(f"lib/{abi}/") and i.endswith(".so")]
            names = {Path(i).name for i in members}
            required = {"libmpv.so", "libplayer.so", "libavcodec.so", "libavformat.so", "libavutil.so", "libc++_shared.so"}
            if not required <= names:
                raise RuntimeError(f"Missing ABI payload: {abi}: {required - names}")
            folder = output / "jniLibs" / abi
            folder.mkdir(parents=True)
            for member in members:
                dest = folder / Path(member).name
                data = apk.read(member)
                dest.write_bytes(data)
                elf = run(str(readelf), "--wide", "-h", "-l", "-d", str(dest))
                actual_machine = re.search(r"Machine:\s+(.+)", elf).group(1).strip()
                if actual_machine != machine:
                    raise RuntimeError(f"Wrong architecture: {dest}: {actual_machine}")
                needed = re.findall(r"\(NEEDED\).*?\[(.*?)\]", elf)
                missing = set(needed) - names - SYSTEM
                if missing:
                    raise RuntimeError(f"Missing runtime dependencies: {dest}: {missing}")
                alignments = [int(line.split()[-1], 16) for line in elf.splitlines() if line.strip().startswith("LOAD ")]
                # The NDK's 32-bit libc++ ships 4 KiB LOADs; audit these honestly
                # without claiming 16 KiB runtime support for 32-bit payloads.
                minimum_alignment = 16384 if abi in ("arm64-v8a", "x86_64") else 4096
                if not alignments or min(alignments) < minimum_alignment:
                    raise RuntimeError(f"ELF LOAD alignment below {minimum_alignment}: {dest}: {alignments}")
                if dest.name == "libmpv.so":
                    for marker in (b"android-dovi-yuv", b"HW+ Dolby Vision raw YUV sampling active"):
                        if marker not in data:
                            raise RuntimeError(f"HW+ patch missing: {dest}")
                if dest.name == "libavcodec.so" and b"Dolby Vision RPU side data active for MediaCodec output" not in data:
                    raise RuntimeError(f"MediaCodec RPU patch missing: {dest}")
                records.append({"file": str(dest.relative_to(output)), "bytes": len(data),
                                "sha256": hashlib.sha256(data).hexdigest(), "machine": machine,
                                "needed": needed, "load_alignment": alignments})
    provenance = {"apk_sha256": hashlib.sha256(args.apk.read_bytes()).hexdigest(),
                  "native_libraries": records, "git_revisions": {}}
    for name, folder in [("mpv-android", ROOT)] + [(n, ROOT / "buildscripts/deps" / n) for n in ("mpv", "ffmpeg", "libplacebo")]:
        provenance["git_revisions"][name] = run("git", "-C", str(folder), "rev-parse", "HEAD")
    (output / "MANIFEST.json").write_text(json.dumps(provenance, indent=2) + "\n")
    patches = output / "source-patches"
    shutil.copytree(ROOT / "buildscripts/patches", patches)
    # Include the exact local JNI source and binding that the supplied libplayer expects.
    shutil.copytree(ROOT / "app/src/main/jni", output / "jni-source")
    shutil.copy2(ROOT / "app/src/main/java/is/xyz/mpv/MPVLib.kt", output / "MPVLib.kt")
    for name in ("HWPLUS_DOVI.md", "TV_DIAGNOSTICS.md", "HWPLUS_PHONE_PACKAGE.md"):
        shutil.copy2(ROOT / "buildscripts/tests" / name, output / name)
    shutil.copy2(ROOT / "buildscripts/tests/HWPLUS_PHONE_PACKAGE.md", output / "README.md")
    shutil.copy2(ROOT / "buildscripts/include/depinfo.sh", output / "depinfo.sh")
    licenses = output / "upstream-license-texts"
    licenses.mkdir()
    for name, patterns in {"mpv": ("LICENSE.*", "Copyright"), "ffmpeg": ("COPYING.*", "LICENSE.md")}.items():
        for pattern in patterns:
            for path in (ROOT / "buildscripts/deps" / name).glob(pattern):
                shutil.copy2(path, licenses / f"{name}-{path.name}")
    checksums = []
    for file in sorted(output.rglob("*")):
        if file.is_file():
            checksums.append(f"{hashlib.sha256(file.read_bytes()).hexdigest()}  {file.relative_to(output)}")
    (output / "SHA256SUMS").write_text("\n".join(checksums) + "\n")
    archive = shutil.make_archive(str(output), "zip", root_dir=output.parent, base_dir=output.name)
    print(json.dumps({"archive": archive, "library_count": len(records),
                      "sha256": hashlib.sha256(Path(archive).read_bytes()).hexdigest()}, indent=2))


if __name__ == "__main__":
    main()
