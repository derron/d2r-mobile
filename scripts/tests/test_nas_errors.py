"""验证九类提示、固定诊断、隐私与文案数量。 | Verify nine categories, fixed diagnostics, privacy and the text budget."""
import csv
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class NasErrorTests(unittest.TestCase):
    def test_categories_system_errors_and_private_data_are_separated(self):
        with tempfile.TemporaryDirectory(prefix="nas-error-test-") as folder:
            binary = Path(folder) / "errors"
            subprocess.run(["xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
                            str(ROOT / "dm/host/tests/nas_error_driver.m"), str(ROOT / "dm/host/dm_i18n.c"),
                            "-framework", "Foundation", "-o", str(binary)], check=True)
            english = subprocess.run([str(binary)], env=dict(os.environ, DM_LANG="en-US"), capture_output=True, text=True, check=True)
            chinese = subprocess.run([str(binary)], env=dict(os.environ, DM_LANG="zh-CN"), capture_output=True, text=True, check=True)
            en, zh = json.loads(english.stdout), json.loads(chinese.stdout)
            self.assertEqual(len(set(en)), 9)
            self.assertEqual(len(set(zh)), 9)
            self.assertTrue(all(a != b for a, b in zip(en, zh)))
            self.assertIn("operation=network-test detail=-1001", english.stderr)
            self.assertIn("operation=local-test detail=513", english.stderr)
            for text in [english.stdout, english.stderr, chinese.stdout, chinese.stderr]:
                for private in ["private-user", "private-password", "private.invalid", "private-save-path"]:
                    self.assertNotIn(private, text)

    def test_new_keys_fit_budget_and_have_no_unused_entries(self):
        with (ROOT / "dm/i18n/ui_text.tsv").open() as table:
            rows = {row["键"]: row for row in csv.DictReader(table, delimiter="\t")}
        keys = set(rows)
        added = {key for key in keys if key.startswith(("dmNas", "dmSync"))}
        self.assertLessEqual(len(added), 50)
        self.assertEqual(len([key for key in added if key.startswith("dmSync")]), 10)
        sources = list((ROOT / "dm/ios/Sources").glob("nas*")) + [ROOT / "dm/host/front_mac.m", ROOT / "dm/host/dm_update.c"]
        refs = set()
        for path in sources:
            refs.update(re.findall(r'"(dm(?:Nas|Sync)\w+)"', path.read_text()))
        # 系统权限取静态资源，仍需与多语表保持一致。 | System permissions use static resources but must match the table.
        for language, column in [("en", "English"), ("zh-Hans", "中文")]:
            resource = (ROOT / "dm/ios/Sources" / (language + ".lproj") / "InfoPlist.strings").read_text()
            self.assertIn("dmNasLocalNetworkPurpose", resource)
            self.assertIn('"NSLocalNetworkUsageDescription" = "' + rows["dmNasLocalNetworkPurpose"][column] + '";', resource)
        refs.add("dmNasLocalNetworkPurpose")
        self.assertEqual(added, refs)
