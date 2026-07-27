#!/usr/bin/env python3
"""Small, dependency-free receiver for the KOReader SDR Backup plugin."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import secrets
import shutil
import socket
import sys
import tempfile
import threading
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path, PurePosixPath
from urllib.parse import parse_qs, quote, unquote, urlsplit


API_PREFIX = "/api/v1"
MAX_JSON_BYTES = 32 * 1024 * 1024


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def load_json(path: Path, default=None):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return default


def atomic_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_name, path)
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass


def safe_backup_id(value: str) -> str:
    if not value or any(ch not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_" for ch in value):
        raise ValueError("invalid backup id")
    return value


def safe_portable_path(value: str) -> PurePosixPath:
    if not value or "\x00" in value or value.startswith("/"):
        raise ValueError("invalid relative path")
    path = PurePosixPath(value)
    if any(part in ("", ".", "..") for part in path.parts):
        raise ValueError("invalid relative path")
    return path


def safe_relative_path(value: str) -> PurePosixPath:
    path = safe_portable_path(value)
    if path.parts[0] != "roots":
        raise ValueError("backup paths must start with roots/")
    return path


def validate_manifest(manifest: dict) -> None:
    if manifest.get("schema_version") != 1:
        raise ValueError("unsupported manifest schema")
    roots = manifest.get("roots")
    files = manifest.get("files")
    directories = manifest.get("sdr_directories")
    if not isinstance(roots, list) or not isinstance(files, list) or not isinstance(directories, list):
        raise ValueError("invalid manifest collections")
    root_ids = set()
    for root in roots:
        root_id = root.get("id") if isinstance(root, dict) else None
        if not isinstance(root_id, str) or not root_id or "/" in root_id or root_id in root_ids:
            raise ValueError("invalid or duplicate storage root")
        root_ids.add(root_id)
    seen = set()
    for entry in files:
        if not isinstance(entry, dict):
            raise ValueError("invalid file entry")
        backup_path = entry.get("backup_path")
        root_id = entry.get("root_id")
        relative_path = entry.get("relative_path")
        if root_id not in root_ids or not isinstance(relative_path, str):
            raise ValueError("file refers to an unknown storage root")
        safe_portable_path(relative_path)
        expected = f"roots/{root_id}/{relative_path}"
        if backup_path != expected or backup_path in seen:
            raise ValueError("invalid or duplicate backup path")
        safe_relative_path(backup_path)
        seen.add(backup_path)
        size = entry.get("size")
        if not isinstance(size, int) or isinstance(size, bool) or size < 0:
            raise ValueError("invalid file size")


def local_ip() -> str:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("10.255.255.255", 1))
        return sock.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        sock.close()


class BackupStore:
    def __init__(self, root: Path):
        self.root = root.expanduser().resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()

    def backup_dir(self, backup_id: str) -> Path:
        return self.root / safe_backup_id(backup_id)

    def manifest(self, backup_id: str):
        value = load_json(self.backup_dir(backup_id) / "manifest.json")
        if not isinstance(value, dict):
            raise FileNotFoundError("manifest not found")
        return value

    def create(self, manifest: dict) -> str:
        validate_manifest(manifest)
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        backup_id = f"{stamp}-{secrets.token_hex(3)}"
        target = self.backup_dir(backup_id)
        with self._lock:
            target.mkdir(parents=True, exist_ok=False)
            (target / "files").mkdir()
            manifest = dict(manifest)
            manifest["backup_id"] = backup_id
            manifest["server_created_at"] = utc_now()
            atomic_json(target / "manifest.json", manifest)
            atomic_json(target / "state.json", {"state": "uploading", "updated_at": utc_now()})
        return backup_id

    def write_file(self, backup_id: str, backup_path: str, source, length: int) -> dict:
        relative = safe_relative_path(backup_path)
        backup_dir = self.backup_dir(backup_id)
        if not (backup_dir / "manifest.json").is_file():
            raise FileNotFoundError("backup not found")
        target = backup_dir / "files" / Path(*relative.parts)
        target.parent.mkdir(parents=True, exist_ok=True)
        digest = hashlib.sha256()
        written = 0
        fd, tmp_name = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent)
        try:
            with os.fdopen(fd, "wb") as handle:
                remaining = length
                while remaining:
                    chunk = source.read(min(1024 * 1024, remaining))
                    if not chunk:
                        raise ConnectionError("request body ended early")
                    handle.write(chunk)
                    digest.update(chunk)
                    written += len(chunk)
                    remaining -= len(chunk)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(tmp_name, target)
        finally:
            try:
                os.unlink(tmp_name)
            except FileNotFoundError:
                pass
        return {"path": backup_path, "size": written, "sha256": digest.hexdigest()}

    def uploaded(self, backup_id: str) -> list[dict]:
        manifest = self.manifest(backup_id)
        result = []
        base = self.backup_dir(backup_id) / "files"
        for entry in manifest.get("files", []):
            try:
                relative = safe_relative_path(str(entry["backup_path"]))
                target = base / Path(*relative.parts)
                stat = target.stat()
            except (KeyError, ValueError, FileNotFoundError, OSError):
                continue
            if stat.st_size == int(entry.get("size", -1)):
                result.append({"backup_path": entry["backup_path"], "size": stat.st_size})
        return result

    def complete(self, backup_id: str) -> dict:
        manifest = self.manifest(backup_id)
        base = self.backup_dir(backup_id) / "files"
        integrity = []
        missing = []
        wrong_size = []
        for entry in manifest.get("files", []):
            backup_path = str(entry.get("backup_path", ""))
            try:
                relative = safe_relative_path(backup_path)
                target = base / Path(*relative.parts)
                stat = target.stat()
            except (ValueError, FileNotFoundError, OSError):
                missing.append(backup_path)
                continue
            expected = int(entry.get("size", -1))
            if stat.st_size != expected:
                wrong_size.append({"path": backup_path, "expected": expected, "actual": stat.st_size})
                continue
            digest = hashlib.sha256()
            with target.open("rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(chunk)
            integrity.append({"backup_path": backup_path, "size": stat.st_size, "sha256": digest.hexdigest()})
        if missing or wrong_size:
            state = {"state": "incomplete", "updated_at": utc_now(), "missing": missing, "wrong_size": wrong_size}
            atomic_json(self.backup_dir(backup_id) / "state.json", state)
            return state
        state = {
            "state": "complete",
            "completed_at": utc_now(),
            "file_count": len(integrity),
            "total_bytes": sum(item["size"] for item in integrity),
        }
        atomic_json(self.backup_dir(backup_id) / "integrity.json", {"files": integrity})
        atomic_json(self.backup_dir(backup_id) / "state.json", state)
        return state

    def list_complete(self) -> list[dict]:
        backups = []
        for directory in self.root.iterdir():
            if not directory.is_dir():
                continue
            state = load_json(directory / "state.json", {})
            manifest = load_json(directory / "manifest.json", {})
            if state.get("state") != "complete" or not isinstance(manifest, dict):
                continue
            backups.append({
                "backup_id": directory.name,
                "created_at": manifest.get("created_at") or manifest.get("server_created_at"),
                "completed_at": state.get("completed_at"),
                "file_count": state.get("file_count", len(manifest.get("files", []))),
                "sdr_directory_count": len(manifest.get("sdr_directories", [])),
                "total_bytes": state.get("total_bytes", 0),
            })
        backups.sort(key=lambda item: item.get("completed_at") or "", reverse=True)
        return backups

    def file_path(self, backup_id: str, backup_path: str) -> Path:
        relative = safe_relative_path(backup_path)
        target = self.backup_dir(backup_id) / "files" / Path(*relative.parts)
        if not target.is_file():
            raise FileNotFoundError("file not found")
        return target


class BackupHandler(BaseHTTPRequestHandler):
    server_version = "KOReaderSDRBackup/1.0"
    protocol_version = "HTTP/1.1"

    @property
    def store(self) -> BackupStore:
        return self.server.store

    def log_message(self, fmt, *args):
        sys.stdout.write("[%s] %s\n" % (self.log_date_time_string(), fmt % args))
        sys.stdout.flush()

    def _json(self, status: int, value) -> None:
        payload = json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _error(self, status: int, message: str) -> None:
        self._json(status, {"error": message})

    def _authorized(self) -> bool:
        supplied = self.headers.get("X-SDRBackup-Token", "")
        return secrets.compare_digest(supplied, self.server.token)

    def _require_auth(self) -> bool:
        if self._authorized():
            return True
        self._error(HTTPStatus.UNAUTHORIZED, "invalid token")
        return False

    def _read_json(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            raise ValueError("invalid content length")
        if length <= 0 or length > MAX_JSON_BYTES:
            raise ValueError("invalid JSON body size")
        try:
            return json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ValueError("invalid JSON") from exc

    def _discard_body(self) -> None:
        try:
            remaining = int(self.headers.get("Content-Length", "0"))
        except ValueError as exc:
            raise ValueError("invalid content length") from exc
        while remaining > 0:
            chunk = self.rfile.read(min(64 * 1024, remaining))
            if not chunk:
                raise ConnectionError("request body ended early")
            remaining -= len(chunk)

    def do_GET(self):
        parsed = urlsplit(self.path)
        if parsed.path == f"{API_PREFIX}/ping":
            if not self._require_auth():
                return
            return self._json(HTTPStatus.OK, {"ok": True, "server": self.server_version})
        if not self._require_auth():
            return
        parts = [unquote(part) for part in parsed.path.strip("/").split("/")]
        try:
            if parts == ["api", "v1", "backups"]:
                return self._json(HTTPStatus.OK, {"backups": self.store.list_complete()})
            if len(parts) == 5 and parts[:3] == ["api", "v1", "backups"] and parts[4] == "manifest":
                return self._json(HTTPStatus.OK, self.store.manifest(parts[3]))
            if len(parts) == 5 and parts[:3] == ["api", "v1", "backups"] and parts[4] == "uploaded":
                return self._json(HTTPStatus.OK, {"files": self.store.uploaded(parts[3])})
            if len(parts) == 5 and parts[:3] == ["api", "v1", "backups"] and parts[4] == "file":
                query = parse_qs(parsed.query)
                backup_path = query.get("path", [""])[0]
                target = self.store.file_path(parts[3], backup_path)
                size = target.stat().st_size
                self.send_response(HTTPStatus.OK)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(size))
                self.end_headers()
                with target.open("rb") as handle:
                    shutil.copyfileobj(handle, self.wfile, length=1024 * 1024)
                return
        except (ValueError, FileNotFoundError) as exc:
            return self._error(HTTPStatus.NOT_FOUND, str(exc))
        self._error(HTTPStatus.NOT_FOUND, "unknown endpoint")

    def do_POST(self):
        if not self._require_auth():
            return
        parsed = urlsplit(self.path)
        parts = [unquote(part) for part in parsed.path.strip("/").split("/")]
        try:
            if parts == ["api", "v1", "backups"]:
                manifest = self._read_json()
                backup_id = self.store.create(manifest)
                return self._json(HTTPStatus.CREATED, {"backup_id": backup_id})
            if len(parts) == 5 and parts[:3] == ["api", "v1", "backups"] and parts[4] == "complete":
                self._discard_body()
                result = self.store.complete(parts[3])
                status = HTTPStatus.OK if result["state"] == "complete" else HTTPStatus.CONFLICT
                return self._json(status, result)
        except (ValueError, FileNotFoundError, FileExistsError, ConnectionError) as exc:
            return self._error(HTTPStatus.BAD_REQUEST, str(exc))
        self._error(HTTPStatus.NOT_FOUND, "unknown endpoint")

    def do_PUT(self):
        if not self._require_auth():
            return
        parsed = urlsplit(self.path)
        parts = [unquote(part) for part in parsed.path.strip("/").split("/")]
        if len(parts) != 5 or parts[:3] != ["api", "v1", "backups"] or parts[4] != "file":
            return self._error(HTTPStatus.NOT_FOUND, "unknown endpoint")
        try:
            length = int(self.headers.get("Content-Length", "-1"))
            if length < 0:
                raise ValueError("Content-Length is required")
            query = parse_qs(parsed.query)
            backup_path = query.get("path", [""])[0]
            result = self.store.write_file(parts[3], backup_path, self.rfile, length)
            self._json(HTTPStatus.OK, result)
        except (ValueError, FileNotFoundError, ConnectionError, OSError) as exc:
            self._error(HTTPStatus.BAD_REQUEST, str(exc))


def read_or_create_token(config_path: Path) -> str:
    config = load_json(config_path, {})
    token = config.get("token") if isinstance(config, dict) else None
    if not isinstance(token, str) or len(token) < 16:
        token = secrets.token_urlsafe(24)
        atomic_json(config_path, {"token": token})
    return token


def build_server(host: str, port: int, backup_dir: Path, token: str) -> ThreadingHTTPServer:
    server = ThreadingHTTPServer((host, port), BackupHandler)
    server.store = BackupStore(backup_dir)
    server.token = token
    return server


def parse_args():
    parser = argparse.ArgumentParser(description="Receive KOReader SDR backups over the local network")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=54321)
    parser.add_argument("--backup-dir", type=Path, default=Path.home() / "KOReader SDR Backups")
    parser.add_argument("--config", type=Path, default=Path.home() / ".koreader-sdr-backup-server.json")
    parser.add_argument("--token")
    parser.add_argument("--print-config", action="store_true", help="print connection settings as JSON and exit")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    token = args.token or read_or_create_token(args.config.expanduser())
    if args.print_config:
        print(json.dumps({
            "server_url": f"http://{local_ip()}:{args.port}",
            "token": token,
            "backup_dir": str(args.backup_dir.expanduser().resolve()),
        }, ensure_ascii=False))
        return 0
    server = build_server(args.host, args.port, args.backup_dir, token)
    print("KOReader SDR Backup-mottagare är igång")
    print(f"Serveradress: http://{local_ip()}:{args.port}")
    print(f"Token: {token}")
    print(f"Backupmapp: {server.store.root}")
    print("Låt detta fönster vara öppet under backup/återställning.\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nServern stoppad.")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
