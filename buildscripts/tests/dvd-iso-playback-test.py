#!/usr/bin/env python3
"""Exercise a DVD ISO through the app's bd:// route, without an Android device.

Requires an mpv executable built with libbluray, libdvdnav and JSON IPC.
The process uses null outputs and software decoding; it cannot validate Android
Surface presentation. Only the supplied ISO is served, on the loopback interface.
"""
import argparse
import json
from pathlib import Path
import re
import shutil
import socket
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Client:
    def __init__(self, process, path):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(0.2)
        deadline = time.monotonic() + 12
        while True:
            try:
                self.sock.connect(str(path))
                break
            except (FileNotFoundError, ConnectionRefusedError):
                if process.poll() is not None or time.monotonic() >= deadline:
                    self.sock.close()
                    raise RuntimeError("MPV IPC did not start")
                time.sleep(0.05)
        self.buffer = b""
        self.seq = 0

    def call(self, command):
        self.seq += 1
        self.sock.sendall((json.dumps({"command": command, "request_id": self.seq}) + "\n").encode())
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if b"\n" not in self.buffer:
                try:
                    data = self.sock.recv(65536)
                except socket.timeout:
                    continue
                if not data:
                    raise RuntimeError("MPV IPC closed")
                self.buffer += data
                continue
            line, self.buffer = self.buffer.split(b"\n", 1)
            event = json.loads(line)
            if event.get("event") == "end-file" and event.get("reason") == "error":
                raise RuntimeError("MPV ended playback with an error")
            if event.get("request_id") == self.seq:
                if event.get("error") == "success":
                    return event.get("data")
                if command[0] != "get_property":
                    raise RuntimeError("MPV command failed: " + event.get("error", "unknown"))
                return None
        raise TimeoutError("MPV IPC response timed out")

    def get(self, name):
        return self.call(["get_property", name])

    def state(self):
        return {name: self.get(name) for name in ("time-pos", "vo-configured", "seeking", "pause")}

    def wait(self, predicate):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            state = self.state()
            if predicate(state):
                return state
            time.sleep(0.05)
        raise TimeoutError("Playback state did not settle: " + json.dumps(state))


def ready(state):
    return (state["vo-configured"] is True and state["seeking"] is False and
            isinstance(state["time-pos"], (int, float)))


def exercise(mpv, name, url, device, output, start=0):
    # Keep the socket below Unix-domain path length limits on macOS as well.
    work = Path(tempfile.mkdtemp(prefix="mpv-dvd-", dir="/tmp"))
    process = None
    client = None
    result = {"case": name, "requested_start_s": start, "passed": False}
    try:
        args = [str(mpv), "--no-config", "--terminal=no", "--input-terminal=no",
                "--vo=null", "--ao=null", "--hwdec=no", "--idle=yes", "--pause=yes",
                "--speed=4", "--access-references=no", "--msg-level=all=v",
                "--input-ipc-server=" + str(work / "ipc"),
                "--log-file=" + str(output / (name + ".log")), "--start=" + str(start)]
        key = "dvd-device" if url.startswith("dvd:") else "bluray-device"
        args += ["--" + key + "=" + device]
        with (output / (name + "-console.log")).open("wb") as log:
            process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
            client = Client(process, work / "ipc")
            client.call(["loadfile", url, "replace"])
            # libdvdnav's time search is bounded by the disc's navigation packs.
            # Check actual returned positions, allowing the same tolerance on
            # the dvd:// control and the app's bd:// routes.
            result["seek_tolerance_s"] = 3
            initial = client.wait(lambda s: ready(s) and abs(s["time-pos"] - start) < 3)
            tracks = client.get("track-list") or []
            video = [t for t in tracks if t.get("type") == "video"]
            audio = [t for t in tracks if t.get("type") == "audio"]
            assert any(t.get("codec") == "mpeg2video" for t in video), "DVD MPEG-2 track missing"
            assert audio, "DVD audio tracks missing"
            result.update(duration_s=client.get("duration"), tracks=[
                {k: t.get(k) for k in ("id", "type", "codec", "lang")} for t in tracks],
                video=client.get("video-params"), initial_position_s=initial["time-pos"])

            client.call(["set_property", "pause", False])
            playing = client.wait(lambda s: ready(s) and s["time-pos"] > initial["time-pos"] + 1)
            result["advanced_to_s"] = playing["time-pos"]
            client.call(["set_property", "pause", True])

            chapters = client.get("chapter-list") or []
            result["chapter_count"] = len(chapters)
            if len(chapters) > 2:
                target = chapters[2]["time"]
                client.call(["set_property", "chapter", 2])
                positioned = client.wait(lambda s: ready(s) and abs(s["time-pos"] - target) < 3)
                result["chapter_position_s"] = positioned["time-pos"]
                result["chapter_seek_passed"] = True

            client.call(["seek", 1800, "absolute+exact"])
            positioned = client.wait(lambda s: ready(s) and abs(s["time-pos"] - 1800) < 3)
            result["exact_seek_position_s"] = positioned["time-pos"]
            result["exact_seek_passed"] = True

            current = client.get("aid")
            other = next((t for t in audio if t["id"] != current), None)
            if other:
                client.call(["set_property", "aid", other["id"]])
                result["audio_switch_passed"] = client.get("aid") == other["id"]
                assert result["audio_switch_passed"], "Audio selection failed"
            client.call(["set_property", "pause", False])
            resumed = client.wait(lambda s: ready(s) and s["time-pos"] > positioned["time-pos"] + 1)
            result["resumed_position_s"] = resumed["time-pos"]
            assert process.poll() is None, "Player exited during playback"
            result["passed"] = True
    except Exception as error:
        result["error"] = str(error)
    finally:
        if client:
            try:
                client.call(["quit"])
            except (RuntimeError, TimeoutError, OSError):
                pass
            client.sock.close()
        if process:
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        shutil.rmtree(work)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mpv", type=Path, required=True)
    parser.add_argument("--iso", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="New directory for reports")
    args = parser.parse_args()
    mpv, iso, output = args.mpv.resolve(), args.iso.resolve(), args.output.resolve()
    if not mpv.is_file() or not iso.is_file():
        parser.error("MPV executable and ISO must exist")
    output.mkdir(parents=True, exist_ok=False)
    size = iso.stat().st_size

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *unused):
            pass

        def do_HEAD(self):
            self.serve(False)

        def do_GET(self):
            self.serve(True)

        def serve(self, body):
            if self.path != "/disc.iso":
                self.send_error(404)
                return
            request = self.headers.get("Range")
            start, end = 0, size - 1
            if request:
                match = re.fullmatch(r"bytes=(\d+)-(\d*)", request)
                if not match:
                    self.send_error(416)
                    return
                start = int(match[1])
                end = min(int(match[2]) if match[2] else size - 1, size - 1)
            if start > end:
                self.send_error(416)
                return
            self.send_response(206 if request else 200)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(end - start + 1))
            self.send_header("Content-Type", "application/octet-stream")
            if request:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            if body:
                try:
                    with iso.open("rb") as source:
                        source.seek(start)
                        remaining = end - start + 1
                        while remaining:
                            data = source.read(min(remaining, 65536))
                            if not data:
                                break
                            self.wfile.write(data)
                            remaining -= len(data)
                except (BrokenPipeError, ConnectionResetError):
                    pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        remote = f"http://127.0.0.1:{server.server_port}/disc.iso"
        cases = [("dvd-control", "dvd://longest", str(iso), 0),
                 ("bd-local", "bd://longest", str(iso), 0),
                 ("bd-http", "bd://longest", remote, 0),
                 ("bd-local-resume", "bd://longest", str(iso), 1800),
                 ("bd-http-resume", "bd://longest", remote, 1800),
                 ("bd-http-title", "bd://0", remote, 0)]
        results = []
        for name, url, device, start in cases:
            result = exercise(mpv, name, url, device, output, start)
            results.append(result)
            print(json.dumps({"case": name, "passed": result["passed"],
                              "error": result.get("error")}), flush=True)
        report = {"iso": iso.name, "size": size, "android_surface_tested": False,
                  "passed": all(r["passed"] for r in results), "cases": results}
        (output / "summary.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        return 0 if report["passed"] else 1
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    raise SystemExit(main())
