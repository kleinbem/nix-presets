"""Serve random photos from a folder, cropped to a wall panel's screen size.

GET /random.jpg?w=1280&h=800 returns a baseline JPEG (ESP32 decoders can't do
progressive), EXIF-rotated and cropped to fill the screen. GET /healthz -> ok.
"""

import collections
import io
import os
import random
import socket
import stat
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from PIL import Image, ImageOps

try:
    from pillow_heif import register_heif_opener

    register_heif_opener()
except ImportError:
    pass

PHOTO_DIR = os.environ.get("PHOTO_DIR", "/var/lib/photos")
EXTENSIONS = (".jpg", ".jpeg", ".png", ".webp", ".heic", ".heif")
RESCAN_SECONDS = 300
MAX_SIDE = 2560
# Pixels a photo may have after JPEG draft scaling; bigger ones are skipped (MemoryMax).
MAX_PIXELS = 30_000_000

_files: list[str] = []
_scanned = float("-inf")
_recent: collections.deque[str] = collections.deque()
_recent_set: set[str] = set()
_lock = threading.Lock()
# Renders are memory-heavy; a few at a time is plenty for wall panels.
_renders = threading.BoundedSemaphore(2)


def _walk_error(err: OSError) -> None:
    print(f"cannot read {err.filename}: {err.strerror}", file=sys.stderr, flush=True)


def _photos() -> list[str]:
    global _files, _scanned
    with _lock:
        if time.monotonic() - _scanned > RESCAN_SECONDS:
            found = []
            for root, _dirs, names in os.walk(PHOTO_DIR, onerror=_walk_error):
                found += [
                    os.path.join(root, n)
                    for n in names
                    if n.lower().endswith(EXTENSIONS)
                ]
            _files, _scanned = found, time.monotonic()
        return _files


def _candidates() -> list[str]:
    """All photos, the ones not shown recently first, each group shuffled."""
    files = _photos()
    with _lock:
        fresh = [f for f in files if f not in _recent_set]
        stale = [f for f in files if f in _recent_set]
    random.shuffle(fresh)
    random.shuffle(stale)
    return fresh + stale


def _forget(path: str) -> None:
    with _lock:
        if path in _recent_set:
            _recent_set.discard(path)
            _recent.remove(path)


def _remember(path: str, total: int) -> None:
    # Don't repeat a photo until most of the others have been shown.
    keep = max(0, min(total - 1, total * 3 // 4))
    with _lock:
        if path not in _recent_set:
            _recent.append(path)
            _recent_set.add(path)
        while len(_recent) > keep:
            _recent_set.discard(_recent.popleft())


def _open_regular(path: str):
    # O_NONBLOCK so a FIFO can't block the open; fstat on the fd closes the check-then-open gap.
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise ValueError("not a regular file")
    return os.fdopen(fd, "rb")


def _render(path: str, width: int, height: int) -> bytes:
    with _open_regular(path) as f, Image.open(f) as img:
        img.draft("RGB", (width * 2, height * 2))  # fast JPEG downscale on decode
        if img.width * img.height > MAX_PIXELS:
            raise ValueError(f"{img.width}x{img.height} is over the pixel budget")
        img = ImageOps.exif_transpose(img).convert("RGB")
        img = ImageOps.fit(img, (width, height), Image.Resampling.LANCZOS)
        out = io.BytesIO()
        img.save(out, "JPEG", quality=85, progressive=False, optimize=True)
        return out.getvalue()


class Handler(BaseHTTPRequestHandler):
    # A client that stops sending must not hold its thread forever, nor one
    # that trickles bytes: every connection is cut after 30s in total.
    timeout = 10
    deadline = 30

    def setup(self):
        super().setup()
        self._deadline = threading.Timer(self.deadline, self._cut)
        self._deadline.daemon = True
        self._deadline.start()

    def finish(self):
        self._deadline.cancel()
        super().finish()

    def _cut(self):
        try:
            self.connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/healthz":
            self._send(200, b"ok", "text/plain")
            return
        if url.path != "/random.jpg":
            self._send(404, b"not found", "text/plain")
            return
        q = parse_qs(url.query)
        try:
            w = min(MAX_SIDE, max(16, int(q.get("w", ["1280"])[0])))
            h = min(MAX_SIDE, max(16, int(q.get("h", ["800"])[0])))
        except ValueError:
            self._send(400, b"bad size", "text/plain")
            return
        candidates = _candidates()
        if not candidates:
            self._send(404, b"no photos", "text/plain")
            return
        for path in candidates:
            # Reserve it, so a parallel request picks another photo.
            _remember(path, len(candidates))
            if not _renders.acquire(timeout=15):
                _forget(path)
                self._send(503, b"busy", "text/plain")
                return
            try:
                body = _render(path, w, h)
            except (OSError, ValueError, Image.DecompressionBombError) as err:
                self.log_message("skipping %s: %s", path, err)
                _forget(path)
                continue
            finally:
                _renders.release()
            try:
                self._send(200, body, "image/jpeg")
            except OSError:
                _forget(path)  # the panel didn't get it
            return
        self._send(500, b"no readable photo", "text/plain")

    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


class Server(ThreadingHTTPServer):
    """Caps connection threads; connections over the limit are closed at once."""

    daemon_threads = True
    _slots = threading.BoundedSemaphore(16)

    def process_request(self, request, client_address):
        if not self._slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self._slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._slots.release()


def main() -> None:
    # Panels on the LAN fetch from it; the module opens the port only on openFirewallOn.
    host = os.environ.get("LISTEN_HOST", "0.0.0.0")  # noqa: S104
    port = int(os.environ.get("LISTEN_PORT", "8099"))
    Server((host, port), Handler).serve_forever()


if __name__ == "__main__":
    sys.exit(main())
