#!/bin/bash
# Replays a local sample in the independent test app; never touches production apps.
set -euo pipefail
if [ "$#" -ne 4 ]; then
    echo "Usage: bash $0 SERIAL DEVICE_FILENAME bridge|copy screenshot|benchmark|seek" >&2
    exit 2
fi
serial="$1"
sample="$2"
mode="$3"
phase="$4"
[[ "$sample" =~ ^[a-zA-Z0-9_.-]+$ ]] || exit 2
case "$mode" in bridge|copy) ;; *) exit 2 ;; esac
case "$phase" in screenshot|benchmark|seek) ;; *) exit 2 ;; esac
adb="${ADB:-/Users/attempt/Library/Android/sdk/platform-tools/adb}"
test_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
result="$(mktemp -d /private/tmp/mpv-yuv-validation.XXXXXX)"
echo "Result: $result"
"$adb" -s "$serial" shell am force-stop is.xyz.mpv.yuvtest
"$adb" -s "$serial" shell run-as is.xyz.mpv.yuvtest test -f "files/$sample"
"$adb" -s "$serial" shell run-as is.xyz.mpv.yuvtest cp files/mpv.conf files/mpv.conf.validation-backup
cleanup() {
    "$adb" -s "$serial" shell am force-stop is.xyz.mpv.yuvtest >/dev/null 2>&1 || true
    "$adb" -s "$serial" shell run-as is.xyz.mpv.yuvtest mv files/mpv.conf.validation-backup files/mpv.conf >/dev/null 2>&1 || true
}
trap cleanup EXIT
decoder=mediacodec
[ "$mode" = bridge ] || decoder=mediacodec-copy
script=yuv-test.lua
[ "$phase" != benchmark ] || script=yuv-benchmark.lua
[ "$phase" != seek ] || script=yuv-seek.lua
"$adb" -s "$serial" shell run-as is.xyz.mpv.yuvtest sh -c '"cat > files/yuv-validation.lua"' < "$test_root/$script"
{
    sed -e "s/^hwdec=.*/hwdec=$decoder/" -e 's/yuv-test.lua/yuv-validation.lua/' "$test_root/yuv-test.conf"
    if [ "$phase" != screenshot ]; then
        printf '\nstart=0\npause=no\n'
    fi
} | "$adb" -s "$serial" shell run-as is.xyz.mpv.yuvtest sh -c '"cat > files/mpv.conf"'
# Reset only this test's generated output to exclude stale evidence.
"$adb" -s "$serial" shell run-as is.xyz.mpv.yuvtest sh -c '"printf null > files/yuv-benchmark.json; printf null > files/yuv-seek.json; printf null > files/yuv-properties.json; truncate -s 0 files/yuv-frame.png; truncate -s 0 files/yuv-test.log"'
"$adb" -s "$serial" shell input keyevent KEYCODE_WAKEUP
"$adb" -s "$serial" shell am start -W -n is.xyz.mpv.yuvtest/is.xyz.mpv.MPVActivity \
    -a android.intent.action.VIEW -d "file:///data/user/0/is.xyz.mpv.yuvtest/files/$sample"
case "$phase" in screenshot) sleep 12 ;; benchmark) sleep 30 ;; seek) sleep 17 ;; esac
"$adb" -s "$serial" exec-out run-as is.xyz.mpv.yuvtest cat files/yuv-test.log > "$result/playback.log"
output="yuv-$phase.json"
if [ "$phase" = screenshot ]; then
    output=yuv-properties.json
    "$adb" -s "$serial" exec-out run-as is.xyz.mpv.yuvtest cat files/yuv-frame.png > "$result/frame.png"
fi
"$adb" -s "$serial" exec-out run-as is.xyz.mpv.yuvtest cat "files/$output" > "$result/result.json"
printf 'Sample: %s\nMode: %s\nPhase: %s\n' "$sample" "$mode" "$phase" > "$result/case.txt"
cat "$result/result.json"
echo
# This is a capture harness, not an automatic pass verdict. Inspect the JSON/logs.
