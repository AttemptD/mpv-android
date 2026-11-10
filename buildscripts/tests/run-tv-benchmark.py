#!/usr/bin/env python3
"""Benchmark the TV flavor without changing production players or global settings."""
import argparse
import json
from pathlib import Path
import shlex
import subprocess
import tempfile
import time

PACKAGE = 'is.xyz.mpv.tv'
ROOT = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('serial')
parser.add_argument('remote_media', help='Existing readable media on the Android device')
parser.add_argument('--adb', default='adb')
parser.add_argument('--duration', type=int, default=20)
parser.add_argument('--output', choices=['auto', 'gpu', 'embed'], default='auto')
parser.add_argument('--audio', choices=['none', 'stereo', 'auto'], default='none')
parser.add_argument('--lifecycle', action='store_true', help='Pause/seek/caption regression; runs for at least 22 seconds')
parser.add_argument('--force-hdr10', action='store_true', help='Test-only opt-in for confirmed HDR10 displays with missing API capabilities')
parser.add_argument('--force-dolby', action='store_true', help='Diagnostic decoder attempt only; does not establish Dolby display support')
parser.add_argument('--platform-dolby', action='store_true', help='Enable the TV flavor platform Dolby compatibility preference')
parser.add_argument('--safe-seek', action='store_true', help='Diagnostic: decode all preroll frames during exact seeks')
args = parser.parse_args()
if not 12 <= args.duration <= 120:
    parser.error('--duration must be between 12 and 120 seconds')
if args.lifecycle: args.duration = max(args.duration, 22)
destination = Path(tempfile.mkdtemp(prefix='tv-mpv-', dir='/tmp')).resolve()
print(f'Results: {destination}', flush=True)

def adb(*parts, data=None, check=True, timeout=30):
    result = subprocess.run([args.adb, '-s', args.serial, *parts], input=data,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(result.stderr.decode(errors='replace'))
    return result

def shell(command, **kwargs):
    return adb('shell', command, **kwargs)

def read(path):
    result = adb('shell', '-T', 'run-as', PACKAGE, 'cat', path, check=False)
    return result.stdout if result.returncode == 0 else None

def write(path, data):
    command = f'run-as {PACKAGE} sh -c ' + shlex.quote('cat > ' + shlex.quote(path))
    shell(command, data=data)

conf = 'files/mpv.conf'
script = 'files/scripts/tv-benchmark.lua'
prefs = f'shared_prefs/{PACKAGE}_preferences.xml'
backups = {}
try:
    shell(f'am force-stop {PACKAGE}')
    shell(f'run-as {PACKAGE} mkdir -p files/scripts shared_prefs')
    backups = {path: read(path) for path in (conf, script, prefs)}
    shell(f'run-as {PACKAGE} rm -f files/tv-benchmark.json files/tv-benchmark.json.partial')
    command = f'cat {shlex.quote(args.remote_media)} | run-as {PACKAGE} sh -c ' + shlex.quote('cat > files/tv-sample.mkv')
    shell(command, timeout=120)
    subtitle = b'[Script Info]\nScriptType: v4.00+\nPlayResX: 1920\nPlayResY: 1080\n[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, OutlineColour, BorderStyle, Outline, Alignment, MarginL, MarginR, MarginV\nStyle: Default,Roboto,70,&H0000FFFF,&H00000000,1,3,2,20,20,80\n[Events]\nFormat: Layer, Start, End, Style, Text\nDialogue: 0,0:00:00.00,0:10:00.00,Default,TV mpv - native subtitle test\n'
    write('files/tv-test.ass', subtitle)
    configuration = [
        'vo=gpu-next', 'hwdec=mediacodec,mediacodec-copy', 'video-sync=audio',
        'keep-open=yes', 'osd-level=0', 'sub-auto=no',
        'load-scripts=no', f'scripts-append=/data/user/0/{PACKAGE}/files/scripts/tv-benchmark.lua',
        f'sub-file=/data/user/0/{PACKAGE}/files/tv-test.ass', 'sid=auto',
        f'script-opts=tv-benchmark-duration={args.duration},tv-benchmark-lifecycle={"yes" if args.lifecycle else "no"},tv-benchmark-force_dolby={"yes" if args.force_dolby else "no"}',
        'msg-level=all=warn,vd=info,afuse_p5=info,tv_benchmark=info',
    ]
    if args.audio == 'none': configuration.append('aid=no')
    if args.audio == 'stereo': configuration.append('audio-channels=stereo')
    if args.safe_seek: configuration.append('hr-seek-framedrop=no')
    if args.output == 'embed':
        configuration.extend(['vo=mediacodec_embed', 'hwdec=mediacodec',
            f'scripts=/data/user/0/{PACKAGE}/files/scripts/tv-benchmark.lua'])
    write(conf, ('\n'.join(configuration) + '\n').encode())
    write(script, (ROOT / 'tv-benchmark.lua').read_bytes())
    write(prefs, (f'<?xml version="1.0" encoding="utf-8"?><map>'
                  f'<boolean name="tv_native_output" value="{str(args.output == "auto").lower()}"/>'
                  f'<boolean name="tv_hdr10_compatibility" value="{str(args.force_hdr10).lower()}"/>'
                  f'<boolean name="tv_platform_dolby" value="{str(args.platform_dolby).lower()}"/>'
                  f'<boolean name="tv_match_frame_rate" value="true"/>'
                  f'<boolean name="gpu_next" value="true"/></map>').encode())
    before = shell('date "+%m-%d %H:%M:%S.000"').stdout.decode().strip()
    launch = shell(f'am start -W -n {PACKAGE}/is.xyz.mpv.MPVActivity -a android.intent.action.VIEW '
                   f'-d file:///data/user/0/{PACKAGE}/files/tv-sample.mkv -t video/x-matroska')
    (destination / 'launch.txt').write_bytes(launch.stdout + launch.stderr)
    deadline = time.monotonic() + args.duration + 35
    report = None
    while time.monotonic() < deadline:
        report = read('files/tv-benchmark.json')
        if report: break
        time.sleep(2)
    (destination / 'logcat.txt').write_bytes(adb('logcat', '-d', '-T', before, '-s',
        'mpv:V', 'tv-mpv:V', 'AndroidRuntime:E', 'ACodec:W', 'CCodec:W', 'AudioTrack:W', check=False).stdout)
    (destination / 'composited.png').write_bytes(adb('exec-out', 'screencap', '-p').stdout)
    (destination / 'surfaceflinger.txt').write_bytes(shell('dumpsys SurfaceFlinger').stdout)
    partial = read('files/tv-benchmark.json.partial')
    if partial: (destination / 'partial.json').write_bytes(partial)
    if not report and partial:
        report = json.dumps(dict(json.loads(partial), reason='host-timeout', checks={})).encode()
    if not report: raise RuntimeError(f'No result within timeout; inspect {destination}')
    (destination / 'report.json').write_bytes(report)
    result = json.loads(report)
    failed_speed = False
    progressing = [s for s in result['samples'] if s.get('time-pos', 0) >= 3 and not s.get('pause')]
    if len(progressing) < 2: progressing = [s for s in result['samples'] if 'time-pos' in s]
    if len(progressing) >= 2 and not args.lifecycle:
        first, last = progressing[0], progressing[-1]
        elapsed = last['wall'] - first['wall']
        summary = {'clock_ratio': (last['time-pos'] - first['time-pos']) / elapsed,
                   'wall_seconds': elapsed, 'vo': last.get('current-vo'),
                   'hwdec': last.get('hwdec-current'),
                   'render_drops': last.get('frame-drop-count', 0) - first.get('frame-drop-count', 0),
                   'total_render_drops': last.get('frame-drop-count', 0),
                   'decoder_drops': last.get('decoder-frame-drop-count', 0) - first.get('decoder-frame-drop-count', 0),
                   'total_decoder_drops': last.get('decoder-frame-drop-count', 0),
                   'native_hdr': last.get('android-native-hdr-status'),
                   'native_dolby': last.get('android-native-dolby-status'),
                   'audio': last.get('audio-out-params'), 'video': last.get('video-params')}
        for name in ('android-native-hdr-status', 'android-native-dolby-status'):
            state = last.get(name, {})
            if state.get('active'):
                submitted = (state.get('frames', 0) - first.get(name, {}).get('frames', 0)) / elapsed
                summary['submitted_fps'] = submitted
                failed_speed = submitted < last.get('container-fps', 0) * 0.9
        failed_speed = failed_speed or abs(summary['clock_ratio'] - 1) > 0.05
        (destination / 'summary.json').write_text(json.dumps(summary, indent=2))
        print(json.dumps(summary, ensure_ascii=False))
    print(json.dumps({'directory': str(destination), 'reason': result['reason'], 'checks': result['checks']}))
    if result['reason'] in ('host-timeout', 'stalled-before-2s'):
        raise SystemExit(2)
    if args.lifecycle and not all(result['checks'].get(key) is True for key in
        ('paused-seek', 'paused-seek-forward', 'paused-seek-backward', 'paused-caption-redraw', 'resume-clock')):
        raise SystemExit(3)
    if failed_speed: raise SystemExit(4)
finally:
    shell(f'am force-stop {PACKAGE}', check=False)
    for path, data in backups.items():
        if data is None: shell(f'run-as {PACKAGE} rm -f {shlex.quote(path)}', check=False)
        else: write(path, data)
