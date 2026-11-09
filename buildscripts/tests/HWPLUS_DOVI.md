# Experimental HW+ Dolby Vision mapping

Latest phone package: [four-ABI rebuild and integration notes](HWPLUS_PHONE_PACKAGE.md).
The 2026-09-10 Samsung recheck is recorded at the end of this document.

Latest TV follow-up: [2026-09-08 diagnostics](TV_DIAGNOSTICS.md). The TV is still
not production-qualified; disabling frame dropping avoids the observed stall
but remains around 9 fps and does not give accurate seeks.

## Scope and origin

The parent repository commit `8d5521783226e6e36b929d9360ae10147fc17551`
(`HW映射`) adds `ffmpeg-mediacodec-dovi-metadata.patch`. It parses HEVC RPU NALs,
matches them to MediaCodec output timestamps, and attaches FFmpeg Dolby Vision
side data. The actual reshaping and tone mapping are provided by upstream
mpv/libplacebo. The local patch supplies metadata missing from this MediaCodec
path; it is not a new tone-mapping algorithm.

This experiment adds `mpv-android-dovi-yuv.patch`, applied after the existing
Android HDR output patch by `include/download-deps.sh`. The dependency checkout
under `deps/mpv` is ignored by the parent repository, so the tracked patch is
the durable implementation. Base mpv revision: `b955aa28f3`; libplacebo revision:
`22ee762e`; FFmpeg reports `n9.0`.

## What the OES bridge does

Normal `samplerExternalOES` sampling returns RGB after the driver's conversion.
`GL_EXT_YUV_target` provides `__samplerExternal2DY2YEXT`, which returns the
Y/U/V components without that conversion. The bridge uses one fullscreen draw
with three R16F color attachments. libplacebo then receives planar YUV plus the
existing per-frame Dolby Vision metadata. Chroma is expanded by the driver to
4:4:4; this is not a bit-exact replacement for software chroma reconstruction.

There is no CPU frame readback/upload in this bridge. There is still a GPU copy,
three full-resolution intermediate planes (about 47.5 MiB at 3840x2160), and GPU
tone-mapping work. Low-end TV performance is **not** guaranteed.

The mapper caches the last copied source frame for paused redraws/screenshots:
a MediaCodec buffer cannot be released to the Surface twice. The retained source
reference makes the buffer identity comparison safe.

With the experimental option enabled, AImageReader uses two acquired-image slots
instead of five. The tested Amlogic codec rejected the original buffer count
during startup. Two slots were enough for acquireLatestImage and allowed the
codec to start. The option defaults to **off**; normal configurations keep the
existing behavior.

## Enable

Add these options to mpv.conf and reopen playback:

```ini
vo=gpu-next
gpu-context=android
gpu-api=opengl
hwdec=mediacodec
android-dovi-yuv=yes
```

For initial SDR comparison, also use:

```ini
android-hdr-output=no
target-colorspace-hint=no
target-prim=bt.709
target-trc=bt.1886
target-peak=100
tone-mapping=bt.2390
```

This does not enable native Dolby Vision output on an unsupported display.
GPU Vulkan interop and FEL reconstruction are outside this experiment.
Only frames with parsed Dolby Vision metadata enable the YUV bridge. Missing
GPU capabilities, shader failures, or framebuffer failures are reported as
errors; this code does not implement automatic runtime fallback. Use
`hwdec=mediacodec-copy` manually when necessary.

Expected log entries:

```text
Dolby Vision RPU side data active for MediaCodec output
Using hardware decoding (mediacodec).
Experimental HW+ Dolby Vision YUV bridge initialized
HW+ Dolby Vision raw YUV sampling active: 3840x2160.
```

## Rebuild

From the repository root, with the existing dependencies/toolchain prepared:

```sh
./buildscripts/buildAfusekt.sh -n --arch armv7l mpv
./buildscripts/buildAfusekt.sh -n --arch arm64 mpv
buildscripts/sdk/android-ndk-r29/ndk-build -C app/src/main -j4 \
  APP_ABI='armeabi-v7a arm64-v8a' \
  PREFIX32="$PWD/buildscripts/prefix/armv7l" \
  PREFIX64="$PWD/buildscripts/prefix/arm64"
./gradlew -I buildscripts/tests/yuv-test.init.gradle :app:assembleDefaultDebug
```

The init script creates package `is.xyz.mpv.yuvtest`, separate from production
mpv and Afusekt. The initial September 7 experiment rebuilt only ARMv7/ARM64.
The September 10 delivery separately rebuilt all four ABIs; only use that new
delivery for x86/x86_64, not the initial experiment's stale splits.

`Android.mk` now includes optional libbluray/libsmb2 shared libraries, which the
local native binaries require but the previous APK packaging omitted.

## Verification on 2026-09-07

The supplied Zootopia MKV is **P8.1**, HEVC Main 10, 3840x2160, BL + RPU,
without an enhancement layer. A 25-second video-only excerpt starting around
10:00 was remuxed without re-encoding; the original 54 GB file was not modified.

The test suite includes:

- `yuv_bridge_probe.c`: compiles the exact playback shaders, uploads known
  AHardwareBuffer YUV codes, reads the three R16F targets, and checks component
  values and orientation. Low bits are varied in P010 to detect 8-bit truncation.
  CPU access is used only for these test assertions.
- `yuv-test.conf` / `yuv-test.lua`: same-frame screenshot and property capture.
- `yuv-benchmark.lua`: video-only wall-clock/progress/drop-counter measurement.
- `yuv-seek.lua`: seek forward, seek backward, pause and resume.

Results observed:

| Device | Raw sampling probe | Real P8.1 playback |
| --- | --- | --- |
| Box R 4K Plus, Mali-G31, Android 12, 32-bit | 8-bit passed; P010 allocation unavailable | HW+ and RPU bridge start; paused 4K screenshot works. Continuous playback remains slow and is not performance-qualified. |
| Samsung SM-S9110, Adreno 740 | 8-bit and P010 10-bit passed | HW+ mapping, continuous playback, forward/backward seek, pause/resume passed on the short excerpt. |
| OPPO PKX110, Adreno 830 | 8-bit and P010 10-bit passed | APK installation did not complete; no end-to-end claim. |

On Samsung, the sampled playback interval advanced about 17.06 video seconds in
17.03 wall seconds with HW+, and 17.02 video seconds in 17.02 wall seconds with
HW copy-back; both recorded zero frame drops. This does **not** establish that
HW+ is faster: both kept up with this 24-fps sample. It is a short video-only
test, not an audio/video synchronization or thermal endurance test.
These measurements used an earlier benchmark script that also queried
`vo-passes`; the checked-in script omits that query to reduce instrumentation
overhead. Re-run matched tests before drawing performance conclusions.

Same-frame screenshots from HW and HW+ were visually close, not identical.
The TV screenshot RGB PSNR was about 47.8 dB. This checks agreement between two
paths, not conformance to a Dolby reference. Differences can include chroma
upsampling, driver output precision, and FP16 rounding.

The hardware-buffer probe proves GPU sampling precision for allocated buffers;
it does **not** prove that every MediaCodec emits 10-bit buffers. Actual decoder
output precision on vendor-private formats still needs checking. Other
profiles, full-length playback, HDR output, DRM, Surface recreation, and a broad
device matrix remain unverified. The experimental flag should remain off by
default until those checks and TV performance work are completed.

## P5 follow-up: The Legend of Hei 2 (2026-09-07)

The user supplied `罗小黑战记 2.mp4`. ffprobe confirms Dolby Vision profile 5,
level 6, compatibility ID 0, BL + RPU without EL, HEVC Main 10,
3840x1616 at 24 fps, full range. A 25-second video-only excerpt near 10:00 was
copied without re-encoding. With the host FFmpeg, MP4 remuxing needed
`-strict unofficial` to preserve the DOVI configuration record; verify this
with ffprobe after remuxing. The source movie was not modified.

No additional native-code change was needed for this sample. Samsung SM-S9110
with the existing ARM64 experimental build reported `mediacodec`, `gpu-next`,
Dolby Vision metadata and active 3840x1616 raw YUV sampling. The HW+ and HW
copy-back screenshots at excerpt time 5.0 seconds were visually close, with no
obvious pink/green color failure. RGB PSNR was 41.48 dB; this is only a
cross-path comparison, not a Dolby reference validation. The copy-back path
reported NV12 (8-bit), so it is not a 10-bit fidelity reference.

Using the benchmark script without `vo-passes` queries:

| Samsung mode | Video progress | Wall interval | Renderer / decoder drops |
| --- | --- | --- | --- |
| HW+ (`mediacodec`) | 17.041667 s | 17.046704 s | 0 / 0 |
| HW (`mediacodec-copy`) | 17.041666 s | 17.051278 s | 0 / 0 |

HW+ seek forward to 12.041667 s, backward to 2.0 s, pause and resume completed
while remaining on `mediacodec`. These short video-only runs do not establish
a performance advantage, audio sync, thermal stability or full-movie support.

On the TV, the first run lost its display Surface and changed to `vo=null`;
that run was invalid. After waking the device and restarting, HW+ raw YUV
mapping and a screenshot succeeded. The continuous test did not finish its
3-to-20-second interval within the 30-second observation window. The log also
contained 146 `MediaCodec Dolby Vision metadata queue overflow; dropping oldest
RPU` warnings. Their causal relationship to playback stalls is not established.
They originate in the existing FFmpeg metadata patch and require separate
investigation; do not qualify this TV's P5 playback as passing.

Host evidence is stored under `/private/tmp/mpv-p5-*` (temporary artifacts).
Both test apps were stopped after verification; production apps were unchanged.

## Samsung recheck and four-ABI package (2026-09-10)

Rebuilt FFmpeg, MPV and JNI for arm64-v8a, armeabi-v7a, x86 and x86_64 from the
current patched source. No new mapping algorithm or TV performance change was
introduced. The exact rebuilt ARM64 APK was installed over the independent
Samsung test package, not over production Afusekt. The user confirmed the
visible playback was normal during this session.

Both existing video-only excerpts were replayed with the SDR configuration
above, default frame dropping (not `framedrop=no`), and the checked-in benchmark
script without `vo-passes` queries. Both kept `hwdec-current=mediacodec`,
`current-vo=gpu-next`, Dolby Vision metadata and active raw YUV sampling.

| Samsung HW+ sample | Video progress | Wall interval | Renderer / decoder drops |
| --- | --- | --- | --- |
| P5, 3840x1616 | 16.833333 s | 16.824933 s | 0 / 0 |
| P8.1, 3840x2160 | 17.017000 s | 17.022042 s | 0 / 0 |

Seek forward/backward, pause and resume completed on both without leaving HW+.
P5 restart positions were 12.041667 and 2.0 seconds; P8.1 positions were 12.012
and 2.002 seconds. Same-frame HW+ versus HW copy-back screenshots were visually
close, with RGB PSNR of 41.33 dB (P5) and 40.36 dB (P8.1), not identical. This
remains a cross-path comparison, not reference Dolby color validation. The P5
HW comparison decoded to NV12, so it is not a 10-bit fidelity reference.

The installed Samsung APK SHA-256 was checked on-device against the host APK:
`482a3fca265708d73c627bd7981e1713d2c25b0d8e27ca2d8359b461acc129a0`.
The four-ABI delivery is extracted from the final universal APK; its ARM64
payload is checked against that tested per-ABI APK. See `MANIFEST.json` for
per-library hashes and static ELF checks. Samsung uses 4 KiB system pages.
Other ABIs were not run on devices this session, and TV mapping remains
unqualified. Whole-film A/V synchronization, sustained thermal performance,
background/Surface lifecycle and automatic fallback remain unvalidated.

Capture script: `run-yuv-validation.sh SERIAL DEVICE_FILENAME bridge|copy
screenshot|benchmark|seek`. It restores the test app's previous mpv.conf and
stops the test app after each capture. It does not touch production apps.

Host evidence directories (temporary; no media URLs/tokens):

- P5 HW+: screenshot `mpv-yuv-validation.Fbz723`, benchmark `mpv-yuv-validation.IEJmhg`,
  seek `mpv-yuv-validation.C31BxW`; HW screenshot `mpv-yuv-validation.FF4LBi`.
- P8.1 HW+: screenshot `mpv-yuv-validation.jD5ZRU`, benchmark `mpv-yuv-validation.GcFh8y`,
  seek `mpv-yuv-validation.hEjmeJ`; HW screenshot `mpv-yuv-validation.PWiAsN`.

All directories above are under `/private/tmp/`. No full movie or test video
is included in the deliverable. AfuseKt, AfuseKtV and Media3 were not modified.
