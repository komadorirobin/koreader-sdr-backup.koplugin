import re
import hashlib
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]


class PluginSourceTests(unittest.TestCase):
    def test_storage_root_enumeration_is_permission_safe(self):
        main = (PROJECT_DIR / "sdrbackup.koplugin" / "main.lua").read_text()
        self.assertNotIn('for name in lfs.dir("/storage")', main)
        self.assertIn('pcall(lfs.dir, "/storage")', main)
        self.assertIn("Device:hasExternalSD()", main)

    def test_manifest_scan_does_not_return_through_subprocess(self):
        main = (PROJECT_DIR / "sdrbackup.koplugin" / "main.lua").read_text()
        self.assertNotIn("runSubprocess(function() return self:createManifest()", main)
        self.assertIn("local manifest, scan_err = self:createManifest()", main)

    def test_ota_install_does_not_run_in_subprocess(self):
        updater = (PROJECT_DIR / "sdrbackup.koplugin" / "sdrbackup_updater.lua").read_text()
        install_section = updater.split("local function installUpdate", 1)[1].split(
            "local function showRelease", 1
        )[0]
        self.assertNotIn("dismissableRunInSubprocess", install_section)

    def test_update_checksums_match_plugin_files(self):
        plugin_dir = PROJECT_DIR / "sdrbackup.koplugin"
        checksums = {}
        for line in (plugin_dir / "files.sha256").read_text().splitlines():
            digest, name = line.split(maxsplit=1)
            checksums[name.lstrip("* ")] = digest
        for name in ("main.lua", "sdrbackup_updater.lua", "_meta.lua"):
            actual = hashlib.sha256((plugin_dir / name).read_bytes()).hexdigest()
            self.assertEqual(checksums.get(name), actual)

    def test_gettext_identifier_is_not_shadowed(self):
        offenders = []
        for path in (PROJECT_DIR / "sdrbackup.koplugin").glob("*.lua"):
            for line_number, line in enumerate(path.read_text().splitlines(), 1):
                stripped = line.strip()
                if stripped == 'local _ = require("gettext")':
                    continue
                if re.search(r"\bfor\s+_\s*,", line) or re.search(r"\blocal\s+[^=]*\b_\b", line):
                    offenders.append(f"{path.name}:{line_number}: {stripped}")
        self.assertEqual(offenders, [], "gettext '_' is shadowed:\n" + "\n".join(offenders))


if __name__ == "__main__":
    unittest.main()
