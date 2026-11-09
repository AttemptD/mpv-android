# Dolby Vision HW+ transition regression (2026-09-10)

## Cause and fix

The observed solid purple flash is gpu-next's explicit error clear in
`vo_gpu_next.c`, not proof that the Dolby Vision reshaping matrix is wrong.
On Samsung, the production log and a local P5 reproduction both showed
`acquireLatestImage failed: -30001` followed by a failed render.

The decoder and VO run on separate threads. Flushing/reopening MediaCodec
invalidates its old Surface buffers. Merely resetting the VO afterward is too
late: an in-flight draw, or an old frame held by the player/filter chain, can
still try to submit that buffer. Retained-frame redraws also must not reset
the render queue before a new frame arrives.

`mpv-android-dovi-transition.patch` therefore:

1. Serializes a preparation callback on the VO thread before decoder flush.
   For gpu-next + MediaCodec + Dolby Vision only, this completes the active
   draw and stops queued old frames while retaining the last displayed frame.
2. Clears player/filter pending frames before a manual decoder reinitialization,
   preserving the seek target before resetting playback state.
3. Defers the gpu-next queue reset for a retained old Dolby Vision MediaCodec
   frame until a new frame ID arrives.

No changes to the error-clear color, tone mapper, RPU parsing, YUV bridge
resolution, per-frame GPU copy count, or FFmpeg/JNI ABI are involved.
This is not an automatic decoder fallback or a promise of instant mode changes.

## Tests

Independent package: `is.xyz.mpv.yuvtest`; Samsung SM-S9110, ARM64.

- Original build, local P5: 5 mapping/render errors in a 16-second seek/mode
  sequence (`/private/tmp/mpv-transition.3TC5LK/playback.log`).
- Only deferring queue reset was insufficient (4 errors). Adding the VO
  barrier without clearing player pending frames was also insufficient.
- Full fix: short sequence completed with 0 mapping/render errors
  (`/private/tmp/mpv-transition.oh9HBs/playback.log`).
- Extended sequence includes forward/backward seek, rapid HW+/HW toggles,
  paused seek, paused HW/HW+/SW/HW+ switches, and resume. No mapping/render
  errors in `/private/tmp/mpv-transition.HnB7nJ/playback.log`.
- The associated screen recording has 463 encoded video frames. All were
  scanned for near-full-screen purple; none were detected. A contact sheet
  was visually checked. This is not a colorimetry/clarity certification.
- All four ABIs compile; only ARM64 has runtime validation in this round.
- Existing 7-stage P5/HW+/HW/SW/P8.1/SDR return-path checks pass on the updated
  library (`/private/tmp/afuse-p5-device.n8W2pY/`). The 14 Lua policy tests pass.
- A verified P5 clip with AAC audio also completed the extended sequence
  without mapping/render errors (`/private/tmp/mpv-transition.274v3v/`).
  Audio restarted after several transient underruns around seeks/mode changes
  and resume. This is not a gapless-audio or long-term A/V-sync certification.

Run with an unlocked device and local sample in the independent app's files:

```sh
bash buildscripts/tests/run-yuv-transition.sh DEVICE_SERIAL
RECORD=1 bash buildscripts/tests/run-yuv-transition.sh DEVICE_SERIAL
SAMPLE=p5-av-dovi.mp4 AUDIO=1 bash buildscripts/tests/run-yuv-transition.sh DEVICE_SERIAL
python3 buildscripts/tests/check-transition-recording.py /path/to/transition.mp4
```

The harness backs up/restores only this independent app's mpv.conf. Recordings
are stored under unique `/data/local/tmp/mpv-transition.*.mp4` paths on-device.
Rapid requests can cancel an earlier transition before its playback-restart;
the later paused stages separately exercise stable decoder choices.

For remuxed samples, use `-strict unofficial` and verify the DOVI configuration
record with ffprobe. A first A/V test clip accidentally omitted it and the
P5-only Lua policy correctly stayed inactive; that run is not P5 bridge evidence.
For this source, preserve its original `dvh1` tag. Forcing `hvc1` produced a
clip with missing HEVC extradata and a decoder assertion before playback;
that malformed clip was excluded rather than treated as a transition result.

The full AfuseKt APK is built with the same ARM64 native payload, but production
app UI, long-play A/V behavior, TV performance, and other devices still require
user verification. The production installation is not replaced by the harness.
