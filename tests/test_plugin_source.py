import re
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]


class PluginSourceTests(unittest.TestCase):
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
