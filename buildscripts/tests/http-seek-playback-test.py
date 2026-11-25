#!/usr/bin/env python3
"""Check curl byte fidelity, read-through seeks, retry, EOF and cancellation.

Uses generated raw RGB frames, a throttled loopback HTTP Range server, and a
headless mpv with the image VO. No external media or Android device is needed.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mpv", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--curl-buffer-size", choices=["4MiB", "8MiB", "16MiB"], default="4MiB")
    parser.add_argument("--curl-seek-cache-size", choices=["32MiB", "64MiB"], default="32MiB")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location(
        "dvd_test", Path(__file__).with_name("dvd-iso-playback-test.py"))
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    media = args.output / "frames.rgb"
    with media.open("wb") as f:
        for i in range(240):
            f.write(bytes((i, i * 37 % 256, i * 73 % 256)) * (320 * 180))
    release = threading.Event()
    requests = []
    broken = False

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def handle(self):
            try:
                super().handle()
            except (BrokenPipeError, ConnectionResetError):
                pass  # Closing an obsolete HTTP range is expected.

        def log_message(self, *_):
            pass

        def do_GET(self):
            nonlocal broken
            match = re.fullmatch(r"bytes=(\d+)-(\d*)", self.headers.get("Range", ""))
            start = int(match[1]) if match else 0
            end = min(int(match[2]) if match and match[2] else media.stat().st_size - 1,
                      media.stat().st_size - 1)
            requests.append((self.path, start))
            if start > end:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{media.stat().st_size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            self.send_response(206 if match else 200)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(end - start + 1))
            if match:
                self.send_header("Content-Range", f"bytes {start}-{end}/{media.stat().st_size}")
            self.end_headers()
            sent = 0
            try:
                with media.open("rb") as f:
                    f.seek(start)
                    while start + sent <= end:
                        if self.path == "/stall" and sent >= 256 * 1024:
                            release.wait(20)
                            return
                        data = f.read(min(16384, end - start - sent + 1))
                        self.wfile.write(data)
                        self.wfile.flush()
                        sent += len(data)
                        if self.path == "/retry" and not broken and sent >= 256 * 1024:
                            broken = True
                            self.close_connection = True
                            return
                        time.sleep(0.01)
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{server.server_port}"

    def exercise(label, source, cancel=False):
        out = args.output / label
        out.mkdir()
        with tempfile.TemporaryDirectory(prefix="mpv-seek-", dir="/tmp") as work:
            sock = Path(work) / "ipc"
            command = [str(args.mpv), "--no-config", "--terminal=no", "--idle=yes",
                       "--pause=yes", "--keep-open=yes", "--ao=null", "--hwdec=no",
                       "--curl-enabled=yes", "--curl-buffer-size=" + args.curl_buffer_size,
                       "--curl-seek-cache-size=" + args.curl_seek_cache_size,
                       "--cache=no", "--demuxer-max-back-bytes=0",
                       "--demuxer-readahead-secs=0", "--demuxer=rawvideo",
                       "--demuxer-rawvideo-w=320", "--demuxer-rawvideo-h=180",
                       "--demuxer-rawvideo-mp-format=rgb24", "--demuxer-rawvideo-fps=10",
                       "--vo=image", "--vo-image-format=png", "--vo-image-outdir=" + str(out),
                       "--input-ipc-server=" + str(sock), "--log-file=" + str(out / "mpv.log")]
            with (out / "console.log").open("wb") as log:
                process = subprocess.Popen(command, stdout=log, stderr=log)
                client = helper.Client(process, sock)
                try:
                    client.call(["loadfile", str(source)])
                    client.wait(helper.ready)
                    if cancel:
                        client.call(["seek", 1.0, "absolute+exact"])
                        time.sleep(0.2)
                        start = time.monotonic()
                        client.call(["stop"])
                        result = round(time.monotonic() - start, 3)
                        assert result < 3, "Cancel blocked behind HTTP read-through"
                        return {"stop_latency_s": result}
                    hashes = []
                    first_requests = None
                    for target in [0, 1.0, 0.2, 19.0, 19.2, 19.0, 23.9, 0.0]:
                        client.call(["seek", target, "absolute+exact"])
                        client.wait(lambda s: helper.ready(s) and abs(s["time-pos"] - target) < 0.02)
                        deadline = time.monotonic() + 5
                        while not list(out.glob("*.png")) and time.monotonic() < deadline:
                            time.sleep(0.02)
                        time.sleep(0.1)
                        image = max(out.glob("*.png"), key=lambda f: f.stat().st_mtime_ns)
                        hashes.append(hashlib.sha256(image.read_bytes()).hexdigest())
                        if target == 1.0 and label == "http":
                            first_requests = len([r for r in requests if r[0] == "/normal"])
                    if label == "http":
                        assert first_requests == 1, "Nearby forward seek reopened HTTP"
                    client.call(["seek", 23.9, "absolute+exact"])
                    client.wait(lambda s: helper.ready(s) and s["time-pos"] > 23.8)
                    client.call(["set_property", "pause", False])
                    deadline = time.monotonic() + 5
                    while not client.get("eof-reached") and time.monotonic() < deadline:
                        time.sleep(0.05)
                    assert client.get("eof-reached"), "EOF was not delivered"
                    return {"frame_sha256": hashes, "eof": True,
                            "requests_after_short_seek": first_requests}
                finally:
                    client.sock.close()
                    process.terminate()
                    try:
                        process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()

    try:
        results = {"local": exercise("local", media)}
        results["http"] = exercise("http", url + "/normal")
        results["retry"] = exercise("retry", url + "/retry")
        assert broken, "Retry fault was not exercised"
        assert len(set(results["local"]["frame_sha256"])) == 6, "Seek frames did not change"
        assert results["local"]["frame_sha256"] == results["http"]["frame_sha256"]
        assert results["local"]["frame_sha256"] == results["retry"]["frame_sha256"]
        results["cancel"] = exercise("cancel", url + "/stall", cancel=True)
        results["passed"] = True
        (args.output / "result.json").write_text(json.dumps(results, indent=2) + "\n")
        print("HTTP seek byte fidelity, short forward read-through, retry, EOF and cancel: PASS")
    finally:
        release.set()
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
