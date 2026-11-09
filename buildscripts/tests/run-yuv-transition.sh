#!/bin/bash
# Uses only the independent test app and the local P5 sample already on-device.
set -euo pipefail
serial="${1:?Supply adb serial}"
sample="${SAMPLE:-p5.mp4}"
[[ "$sample" =~ ^[a-zA-Z0-9_.-]+$ ]] || exit 2
adb="${ADB:-/Users/attempt/Library/Android/sdk/platform-tools/adb}"
test_root="$(cd "$(dirname "$0")" && pwd)"
policy="${P5_POLICY:-/Users/attempt/AndroidStudioProject/AfuseKt/app/src/main/assets/mpv/afuse_p5.lua}"
result="$(mktemp -d /private/tmp/mpv-transition.XXXXXX)"
capture="/data/local/tmp/$(basename "$result").mp4"
echo "Result: $result"
"$adb" -s "$serial" shell am force-stop is.xyz.mpv.yuvtest
"$adb" -s "$serial" shell run-as is.xyz.mpv.yuvtest cp files/mpv.conf files/mpv.conf.transition-backup
cleanup() {
    "$adb" -s "$serial" shell am force-stop is.xyz.mpv.yuvtest >/dev/null 2>&1 || true
    "$adb" -s "$serial" shell run-as is.xyz.mpv.yuvtest mv files/mpv.conf.transition-backup files/mpv.conf >/dev/null 2>&1 || true
}
trap cleanup EXIT
"$adb" -s "$serial" shell run-as is.xyz.mpv.yuvtest sh -c '"cat > files/afuse_p5.lua"' < "$policy"
"$adb" -s "$serial" shell run-as is.xyz.mpv.yuvtest sh -c '"cat > files/yuv-transition.lua"' < "$test_root/yuv-transition.lua"
{
    sed -e 's/^start=.*/start=0/' -e 's/^pause=.*/pause=no/' \
        -e 's/^script=.*/script=\/data\/user\/0\/is.xyz.mpv.yuvtest\/files\/afuse_p5.lua/' \
        -e 's/^msg-level=.*/msg-level=all=v,vo\/gpu-next=trace,ffmpeg\/video=trace/' "$test_root/yuv-test.conf"
    printf '\nscript=/data/user/0/is.xyz.mpv.yuvtest/files/yuv-transition.lua\n'
    if [ "${AUDIO:-0}" = 1 ]; then printf 'audio=auto\n'; fi
} | "$adb" -s "$serial" shell run-as is.xyz.mpv.yuvtest sh -c '"cat > files/mpv.conf"'
"$adb" -s "$serial" shell run-as is.xyz.mpv.yuvtest sh -c '"truncate -s 0 files/yuv-transition.done; truncate -s 0 files/yuv-test.log"'
"$adb" -s "$serial" shell input keyevent KEYCODE_WAKEUP
if [ "${RECORD:-0}" = 1 ]; then
    "$adb" -s "$serial" shell screenrecord --size 1170x540 --time-limit 38 "$capture" > "$result/screenrecord.log" 2>&1 &
    record_pid=$!
fi
"$adb" -s "$serial" shell am start -W -n is.xyz.mpv.yuvtest/is.xyz.mpv.MPVActivity \
    -a android.intent.action.VIEW -d "file:///data/user/0/is.xyz.mpv.yuvtest/files/$sample"
for attempt in $(seq 1 45); do
    if "$adb" -s "$serial" shell run-as is.xyz.mpv.yuvtest test -s files/yuv-transition.done; then break; fi
    sleep 1
done
"$adb" -s "$serial" exec-out run-as is.xyz.mpv.yuvtest cat files/yuv-test.log > "$result/playback.log"
if [ "${RECORD:-0}" = 1 ]; then
    wait "$record_pid"
    "$adb" -s "$serial" pull "$capture" "$result/transition.mp4"
fi
rg 'TRANSITION|Waiting for frame|acquireLatestImage|Mapping hardware|Failed rendering|Failed updating' "$result/playback.log" || true
"$adb" -s "$serial" shell run-as is.xyz.mpv.yuvtest test -s files/yuv-transition.done
if rg -q 'Failed rendering frame|Mapping hardware decoded surface failed|Failed updating frames|Waiting for frame timed out' "$result/playback.log"; then
    echo 'FAIL: transient rendering error in transition sequence' >&2
    exit 1
fi
echo 'PASS: transition sequence completed without logged mapping/render errors (inspect recording separately).'
