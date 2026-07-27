import http.client
import io
import json
import tempfile
import threading
import unittest
from pathlib import Path

import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "companion"))
from sdr_backup_server import BackupStore, build_server, safe_relative_path


def sample_manifest():
    return {
        "schema_version": 1,
        "created_at": "2026-07-27T10:00:00Z",
        "roots": [{"id": "internal", "kind": "internal", "original_path": "/storage/emulated/0"}],
        "sdr_directories": [{"root_id": "internal", "relative_path": "Books/Test.sdr"}],
        "files": [{
            "root_id": "internal",
            "relative_path": "Books/Test.sdr/metadata.lua",
            "backup_path": "roots/internal/Books/Test.sdr/metadata.lua",
            "source_path": "/storage/emulated/0/Books/Test.sdr/metadata.lua",
            "category": "sdr",
            "size": 4,
            "mtime": 1,
        }],
    }


class StoreTests(unittest.TestCase):
    def test_complete_backup_and_integrity(self):
        with tempfile.TemporaryDirectory() as directory:
            store = BackupStore(Path(directory))
            backup_id = store.create(sample_manifest())
            store.write_file(backup_id, "roots/internal/Books/Test.sdr/metadata.lua", io.BytesIO(b"data"), 4)
            state = store.complete(backup_id)
            self.assertEqual(state["state"], "complete")
            self.assertEqual(store.list_complete()[0]["sdr_directory_count"], 1)
            integrity = json.loads((Path(directory) / backup_id / "integrity.json").read_text())
            self.assertEqual(len(integrity["files"][0]["sha256"]), 64)

    def test_incomplete_backup_is_not_listed(self):
        with tempfile.TemporaryDirectory() as directory:
            store = BackupStore(Path(directory))
            backup_id = store.create(sample_manifest())
            self.assertEqual(store.complete(backup_id)["state"], "incomplete")
            self.assertEqual(store.list_complete(), [])

    def test_rejects_path_traversal(self):
        for value in ("../secret", "/absolute", "roots/internal/../secret"):
            with self.assertRaises(ValueError):
                safe_relative_path(value)


class HttpTests(unittest.TestCase):
    def test_ping_requires_token(self):
        with tempfile.TemporaryDirectory() as directory:
            server = build_server("127.0.0.1", 0, Path(directory), "test-secret-token")
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                connection = http.client.HTTPConnection("127.0.0.1", server.server_port)
                connection.request("GET", "/api/v1/ping")
                response = connection.getresponse()
                self.assertEqual(response.status, 401)
                response.read()
                connection.close()

                connection = http.client.HTTPConnection("127.0.0.1", server.server_port)
                connection.request("GET", "/api/v1/ping", headers={"X-SDRBackup-Token": "test-secret-token"})
                response = connection.getresponse()
                self.assertEqual(response.status, 200)
                self.assertTrue(json.loads(response.read())["ok"])
                connection.close()
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)

    def test_full_http_round_trip(self):
        with tempfile.TemporaryDirectory() as directory:
            server = build_server("127.0.0.1", 0, Path(directory), "test-secret-token")
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            headers = {"X-SDRBackup-Token": "test-secret-token"}
            try:
                connection = http.client.HTTPConnection("127.0.0.1", server.server_port)
                body = json.dumps(sample_manifest()).encode()
                connection.request("POST", "/api/v1/backups", body=body, headers={**headers, "Content-Type": "application/json"})
                response = connection.getresponse()
                self.assertEqual(response.status, 201)
                backup_id = json.loads(response.read())["backup_id"]

                path = "/api/v1/backups/%s/file?path=roots%%2Finternal%%2FBooks%%2FTest.sdr%%2Fmetadata.lua" % backup_id
                connection.request("PUT", path, body=b"data", headers=headers)
                response = connection.getresponse()
                self.assertEqual(response.status, 200)
                response.read()

                connection.request("POST", f"/api/v1/backups/{backup_id}/complete", body=b"{}", headers=headers)
                response = connection.getresponse()
                self.assertEqual(response.status, 200)
                self.assertEqual(json.loads(response.read())["state"], "complete")

                connection.request("GET", f"/api/v1/backups/{backup_id}/file?path=roots%2Finternal%2FBooks%2FTest.sdr%2Fmetadata.lua", headers=headers)
                response = connection.getresponse()
                self.assertEqual(response.status, 200)
                self.assertEqual(response.read(), b"data")
                connection.close()
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
