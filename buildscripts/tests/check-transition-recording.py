"""Detect gpu-next's near-full-screen purple error fill, not general color accuracy."""
import subprocess
import sys

proc = subprocess.Popen([
    'ffmpeg', '-v', 'error', '-i', sys.argv[1], '-vf', 'scale=80:36,setpts=N/30/TB',
    '-enc_time_base', '1/30', '-fps_mode', 'passthrough', '-f', 'rawvideo',
    '-pix_fmt', 'rgb24', '-'], stdout=subprocess.PIPE)
size = 80 * 36 * 3
frames, purple = 0, []
while True:
    data = proc.stdout.read(size)
    if not data:
        break
    assert len(data) == size, 'Incomplete decoded frame'
    frames += 1
    pixels = list(zip(data[0::3], data[1::3], data[2::3]))
    ratio = sum(70 < r < 190 and g < 65 and b > 180
                for r, g, b in pixels) / len(pixels)
    if ratio > 0.85:
        purple.append(frames)
assert proc.wait() == 0 and frames, 'Recording could not be decoded'
print(f'Decoded frames: {frames}; near-full-screen purple frames: {len(purple)}')
assert not purple, f'Purple frame indices: {purple}'
