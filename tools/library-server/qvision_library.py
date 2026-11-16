#!/usr/bin/env python3
"""QVision Library: serves baked "Rendered" scenes from this PC to the headset over the LAN.

Python 3 standard library only. Run:

    py -3 qvision_library.py ["C:\\All Docs\\06_Apple vision pro\\assets\\Rendered"] [--port 8770]

Endpoints
---------
GET /index.json    -> [{ "id", "title", "file", "sizeBytes", "modified", "thumbnail"?, "sidecar"? }]
                      Regenerated from the folder on every request. Only top-level *.usdz files
                      are listed; "<Name>.json" next to one is its sidecar, "<Name>.jpg" / ".jpeg" /
                      ".png" its thumbnail.
GET /files/<name>  -> streams one file of that folder (usdz, json, jpg/jpeg/png) with Content-Length.
                      Names are matched against the folder listing, so no path can escape it.
                      Supports a single "Range: bytes=N-" / "bytes=N-M" / "bytes=-N" (206), so an
                      interrupted download can resume.
GET /health        -> { "name": "QVision Library", "version": 2, "scenes": N }
GET /              -> short plain-text status page.

Only clients with a private / loopback / link-local address are served (LAN only); everyone
else gets 403. Every request is logged to the console.

Client models never go into the public repo or the app: they stay in this folder.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import ipaddress
import json
import os
import socket
import sys
import threading
import urllib.parse
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULT_FOLDER = r"C:\All Docs\06_Apple vision pro\assets\Rendered"
DEFAULT_PORT = 8770
LIBRARY_VERSION = 2
CHUNK = 1024 * 1024  # 1 MiB per write while streaming

SERVED_TYPES = {
    ".usdz": "model/vnd.usdz+zip",
    ".json": "application/json; charset=utf-8",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
}
THUMBNAIL_EXTS = (".jpg", ".jpeg", ".png")

_log_lock = threading.Lock()


def log(line: str) -> None:
    stamp = _dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with _log_lock:
        print(f"[{stamp}] {line}", flush=True)


def is_lan_client(address: str) -> bool:
    """True for private, loopback and link-local addresses (IPv4, IPv6 and IPv4-mapped IPv6)."""
    try:
        ip = ipaddress.ip_address(address.split("%", 1)[0])
    except ValueError:
        return False
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped is not None:
        ip = ip.ipv4_mapped
    return ip.is_private or ip.is_loopback or ip.is_link_local


def folder_files(folder: str) -> dict[str, str]:
    """Top-level regular files of the folder: lower-case name -> real name."""
    result: dict[str, str] = {}
    try:
        with os.scandir(folder) as entries:
            for entry in entries:
                try:
                    if entry.is_file(follow_symlinks=False):
                        result[entry.name.lower()] = entry.name
                except OSError:
                    continue
    except OSError:
        pass
    return result


def read_sidecar(path: str) -> dict | None:
    try:
        with open(path, "r", encoding="utf-8-sig") as handle:
            data = json.load(handle)
        return data if isinstance(data, dict) else None
    except (OSError, ValueError):
        return None


def iso_utc(timestamp: float) -> str:
    return _dt.datetime.fromtimestamp(timestamp, tz=_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def build_index(folder: str) -> list[dict]:
    files = folder_files(folder)
    index: list[dict] = []
    for lower, name in sorted(files.items()):
        stem, ext = os.path.splitext(name)
        if ext.lower() != ".usdz":
            continue
        path = os.path.join(folder, name)
        try:
            stat = os.stat(path)
        except OSError:
            continue
        entry: dict = {
            "id": stem,
            "title": stem.replace("_", " ").strip() or stem,
            "file": name,
            "sizeBytes": stat.st_size,
            "modified": iso_utc(stat.st_mtime),
        }
        sidecar_name = files.get((stem + ".json").lower())
        if sidecar_name:
            entry["sidecar"] = sidecar_name
            data = read_sidecar(os.path.join(folder, sidecar_name))
            if data and isinstance(data.get("title"), str) and data["title"].strip():
                entry["title"] = data["title"].strip()
            if data and isinstance(data.get("shading"), str):
                entry["shading"] = data["shading"]
        for thumb_ext in THUMBNAIL_EXTS:
            thumb_name = files.get((stem + thumb_ext).lower())
            if thumb_name:
                entry["thumbnail"] = thumb_name
                break
        index.append(entry)
    index.sort(key=lambda e: e["title"].lower())
    return index


def resolve_served_file(folder: str, raw_name: str) -> str | None:
    """Maps a requested name to a real file of the folder, or None.

    The decoded name must be a bare file name (no separators, no '..', no drive or stream
    syntax) and must match an existing top-level file with a served extension. The returned
    path is re-checked to sit directly inside the folder.
    """
    name = urllib.parse.unquote(raw_name)
    if not name or name in (".", ".."):
        return None
    if any(ch in name for ch in ("/", "\\", ":", "\x00")) or ".." in name:
        return None
    real = folder_files(folder).get(name.lower())
    if real is None:
        return None
    if os.path.splitext(real)[1].lower() not in SERVED_TYPES:
        return None
    base = os.path.realpath(folder)
    path = os.path.realpath(os.path.join(base, real))
    if os.path.dirname(path) != base or not os.path.isfile(path):
        return None
    return path


class LibraryHandler(BaseHTTPRequestHandler):
    server_version = "QVisionLibrary/2.0"
    protocol_version = "HTTP/1.1"
    folder: str = DEFAULT_FOLDER

    # Quiet the default stderr access log: we log ourselves.
    def log_message(self, format: str, *args) -> None:  # noqa: A002 (stdlib signature)
        pass

    def _client(self) -> str:
        return self.client_address[0] if self.client_address else "?"

    def _log(self, status: int, note: str = "") -> None:
        extra = f" {note}" if note else ""
        log(f"{self._client()} {self.command} {self.path} -> {status}{extra}")

    def _send_bytes(self, status: int, body: bytes, content_type: str, head_only: bool = False) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if not head_only:
            self.wfile.write(body)

    def _error(self, status: int, message: str, head_only: bool = False) -> None:
        body = json.dumps({"error": message}).encode("utf-8")
        self._send_bytes(status, body, "application/json; charset=utf-8", head_only)
        self._log(status, message)

    def do_HEAD(self) -> None:
        self._handle(head_only=True)

    def do_GET(self) -> None:
        self._handle(head_only=False)

    def _handle(self, head_only: bool) -> None:
        if not is_lan_client(self._client()):
            self._error(HTTPStatus.FORBIDDEN, "LAN clients only", head_only)
            return

        path = urllib.parse.urlsplit(self.path).path

        if path in ("/", ""):
            lines = [
                "QVision Library",
                f"Folder: {self.folder}",
                f"Scenes: {len(build_index(self.folder))}",
                "GET /health, GET /index.json, GET /files/<name> (Range supported)",
            ]
            self._send_bytes(HTTPStatus.OK, ("\n".join(lines) + "\n").encode("utf-8"),
                             "text/plain; charset=utf-8", head_only)
            self._log(HTTPStatus.OK)
            return

        if path == "/health":
            scenes = sum(1 for name in folder_files(self.folder) if name.endswith(".usdz"))
            body = json.dumps({"name": "QVision Library", "version": LIBRARY_VERSION, "scenes": scenes}).encode("utf-8")
            self._send_bytes(HTTPStatus.OK, body, "application/json; charset=utf-8", head_only)
            self._log(HTTPStatus.OK)
            return

        if path == "/index.json":
            index = build_index(self.folder)
            body = json.dumps(index, indent=2).encode("utf-8")
            self._send_bytes(HTTPStatus.OK, body, "application/json; charset=utf-8", head_only)
            self._log(HTTPStatus.OK, f"{len(index)} scene(s)")
            return

        if path.startswith("/files/"):
            file_path = resolve_served_file(self.folder, path[len("/files/"):])
            if file_path is None:
                self._error(HTTPStatus.NOT_FOUND, "no such file", head_only)
                return
            self._stream_file(file_path, head_only)
            return

        self._error(HTTPStatus.NOT_FOUND, "unknown path", head_only)

    def _parse_range(self, size: int):
        """Returns None (no usable Range header: send everything), "bad" (416) or (first, last)."""
        header = self.headers.get("Range")
        if not header:
            return None
        unit, _, spec = header.partition("=")
        if unit.strip().lower() != "bytes" or "," in spec:
            return None  # multi-range / other units: ignore, send the whole file
        first_text, dash, last_text = spec.strip().partition("-")
        if not dash:
            return None
        try:
            if first_text == "":
                # Suffix form: the last N bytes.
                count = int(last_text)
                if count <= 0:
                    return "bad"
                first, last = max(0, size - count), size - 1
            else:
                first = int(first_text)
                last = int(last_text) if last_text else size - 1
        except ValueError:
            return None
        if first < 0 or first >= size or last < first:
            return "bad"
        return first, min(last, size - 1)

    def _stream_file(self, file_path: str, head_only: bool) -> None:
        try:
            handle = open(file_path, "rb")
        except OSError as error:
            self._error(HTTPStatus.INTERNAL_SERVER_ERROR, f"can't open file: {error.strerror}", head_only)
            return
        with handle:
            size = os.fstat(handle.fileno()).st_size
            content_type = SERVED_TYPES.get(os.path.splitext(file_path)[1].lower(), "application/octet-stream")
            byte_range = self._parse_range(size)
            if byte_range == "bad":
                self.send_response(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.send_header("Accept-Ranges", "bytes")
                self.end_headers()
                self._log(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE, f"range {self.headers.get('Range')!r} of {size}")
                return
            if byte_range is None:
                status, first, last = HTTPStatus.OK, 0, size - 1
            else:
                status = HTTPStatus.PARTIAL_CONTENT
                first, last = byte_range
            length = last - first + 1 if size > 0 else 0
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(length))
            self.send_header("Accept-Ranges", "bytes")
            if status == HTTPStatus.PARTIAL_CONTENT:
                self.send_header("Content-Range", f"bytes {first}-{last}/{size}")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if head_only:
                self._log(status, f"{length} bytes (HEAD)")
                return
            sent = 0
            try:
                handle.seek(first)
                while sent < length:
                    chunk = handle.read(min(CHUNK, length - sent))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    sent += len(chunk)
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                self._log(status, f"client went away after {sent}/{length} bytes")
                self.close_connection = True
                return
            note = f"{sent} bytes"
            if status == HTTPStatus.PARTIAL_CONTENT:
                note += f" (bytes {first}-{last}/{size})"
            self._log(status, note)


def lan_addresses() -> list[str]:
    """Best-effort list of this PC's private IPv4 addresses."""
    found: list[str] = []
    try:
        # No packet is sent: connect() on UDP only picks the outgoing interface.
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            probe.connect(("10.255.255.255", 1))
            found.append(probe.getsockname()[0])
        finally:
            probe.close()
    except OSError:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            found.append(info[4][0])
    except OSError:
        pass
    result: list[str] = []
    for address in found:
        try:
            ip = ipaddress.ip_address(address)
        except ValueError:
            continue
        if ip.is_private and not ip.is_loopback and not ip.is_link_local and address not in result:
            result.append(address)
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="QVision Library: serve baked Rendered scenes on the LAN.")
    parser.add_argument("folder", nargs="?", default=DEFAULT_FOLDER, help="folder with <Name>.usdz (+ .json, .jpg)")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help=f"TCP port (default {DEFAULT_PORT})")
    parser.add_argument("--bind", default="0.0.0.0", help="address to listen on (default all interfaces)")
    args = parser.parse_args(argv)

    folder = os.path.abspath(args.folder)
    if not os.path.isdir(folder):
        try:
            os.makedirs(folder, exist_ok=True)
            log(f"Created the library folder {folder}")
        except OSError as error:
            print(f"Library folder {folder!r} doesn't exist and can't be created: {error}", file=sys.stderr)
            return 2

    LibraryHandler.folder = folder
    try:
        httpd = ThreadingHTTPServer((args.bind, args.port), LibraryHandler)
    except OSError as error:
        print(f"Can't listen on {args.bind}:{args.port}: {error}", file=sys.stderr)
        print("Is the Library already running in another window?", file=sys.stderr)
        return 1
    httpd.daemon_threads = True

    scenes = build_index(folder)
    log(f"QVision Library serving {folder}")
    log(f"{len(scenes)} scene(s): " + (", ".join(s["file"] for s in scenes) if scenes else "none yet"))
    addresses = lan_addresses()
    if addresses:
        for address in addresses:
            log(f"On the headset use this PC address: {address}   (http://{address}:{args.port}/index.json)")
    else:
        log(f"Listening on port {args.port}. Find this PC's IPv4 address with 'ipconfig'.")
    log("LAN clients only. Press Ctrl+C to stop.")

    try:
        httpd.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        log("Stopping.")
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
