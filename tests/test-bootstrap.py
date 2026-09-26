"""Exercise bootstrap decisions on macOS with fake downloads/apps, never live ones.

System unzip, checksums, staging, and shell control flow are real. Network,
publisher checks, Launch Services, and the installed package are test fixtures.
"""
import hashlib
import os
from pathlib import Path
import pty
import re
import subprocess
import sys
import tempfile
import unittest
import zipfile


@unittest.skipUnless(sys.platform == "darwin", "bootstrap targets macOS")
class BootstrapTest(unittest.TestCase):
    def run_installer(self, answer=None, existing=False, bad_digest=False):
        with tempfile.TemporaryDirectory(prefix="mx4-bootstrap-test-") as directory:
            root = Path(directory)
            apps = root / "Applications"
            apps.mkdir()
            (apps / "Hammerspoon.app").mkdir()
            (apps / "logioptionsplus.app").mkdir()
            agent = root / "logi-agent"
            agent.write_text("fixture")
            agent.chmod(0o755)
            alternate = root / "Other Apps" / "AltTab.app"
            if existing:
                alternate.mkdir(parents=True)

            source = (Path(__file__).resolve().parents[1] / "scripts/bootstrap.sh").read_text()
            version = re.search(r"^version=(.+)$", source, re.M)[1]
            package = root / "package.zip"
            with zipfile.ZipFile(package, "w") as archive:
                base = f"mx-master-mac-{version}-macos-universal"
                archive.writestr(base + "/install.sh", 'touch "$MX4_TEST_MARKER"\n')
                archive.writestr(base + "/mx4-device-helper", "fixture")
            altzip = root / "alttab.zip"
            with zipfile.ZipFile(altzip, "w") as archive:
                archive.writestr("AltTab.app/fixture", "downloaded AltTab")
            source = re.sub(r"^package_sha256=.+$", "package_sha256=" +
                            ("0" * 64 if bad_digest else hashlib.sha256(package.read_bytes()).hexdigest()),
                            source, flags=re.M)
            source = re.sub(r"^alttab_sha256=.+$", "alttab_sha256=" +
                            hashlib.sha256(altzip.read_bytes()).hexdigest(), source, flags=re.M)
            source = source.replace("apps_dir=/Applications", f'apps_dir="{apps}"')
            source = re.sub(r"^logi_agent=.+$", f'logi_agent="{agent}"', source, flags=re.M)

            def stub(name, body):
                script = root / name
                script.write_text("#!/bin/sh\nset -eu\n" + body)
                script.chmod(0o755)
                return str(script)

            replacements = {
                "/usr/bin/id": stub("id", "printf '501\\n'\n"),
                "/usr/bin/osascript": stub("lookup", 'printf "%s" "$MX4_TEST_EXISTING"\n'),
                "/usr/bin/codesign": stub("signature", '''
case "$*" in
    *Hammerspoon.app*) printf 'TeamIdentifier=VQCYSNZB89\\n' ;;
    *logioptionsplus.app*) printf 'TeamIdentifier=QED4VVPZWA\\n' ;;
    *AltTab.app*) printf 'TeamIdentifier=QXD7GW8FHY\\n' ;;
    *) exit 1 ;;
esac
'''),
                "/usr/bin/curl": stub("download", '''
output=''
while [ "$#" -gt 0 ]; do
    if [ "$1" = --output ]; then shift; output=$1; fi
    url=$1
    shift
done
printf '%s\\n' "$url" >> "$MX4_TEST_DOWNLOADS"
case "$url" in
    */mx-master-mac/releases/*) cp "$MX4_TEST_PACKAGE" "$output" ;;
    */alt-tab-macos/releases/*) cp "$MX4_TEST_ALTZIP" "$output" ;;
    *) exit 1 ;;
esac
'''),
            }
            for original, replacement in replacements.items():
                source = source.replace(original, '"' + replacement + '"')
            candidate = root / "bootstrap.sh"
            candidate.write_text(source)
            downloads = root / "downloads"
            marker = root / "installed"
            env = dict(os.environ, MX4_TEST_EXISTING=str(alternate) if existing else "",
                       MX4_TEST_MARKER=str(marker), MX4_TEST_DOWNLOADS=str(downloads),
                       MX4_TEST_PACKAGE=str(package), MX4_TEST_ALTZIP=str(altzip))
            if answer is None:
                result = subprocess.run(["/bin/sh", str(candidate)], env=env,
                                        stdin=subprocess.DEVNULL, capture_output=True, text=True)
            else:
                master, slave = pty.openpty()
                try:
                    os.write(master, (answer + "\n").encode())
                    result = subprocess.run(["/bin/sh", str(candidate)], env=env,
                                            stdin=slave, capture_output=True, text=True)
                finally:
                    os.close(master)
                    os.close(slave)
            return (result, marker.exists(), (apps / "AltTab.app").exists(),
                    downloads.read_text() if downloads.exists() else "")

    def test_no_terminal_defaults_to_native(self):
        result, installed, alt, downloads = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(installed)
        self.assertFalse(alt)
        self.assertNotIn("Install AltTab too?", result.stdout)
        self.assertNotIn("alt-tab-macos", downloads)

    def test_decline_or_empty_answer(self):
        for answer in ("n", ""):
            with self.subTest(answer=answer):
                result, installed, alt, _ = self.run_installer(answer=answer)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(installed)
                self.assertFalse(alt)
                self.assertIn("Install AltTab too?", result.stdout)

    def test_explicit_yes_installs_alttab(self):
        result, installed, alt, downloads = self.run_installer(answer="y")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(installed and alt)
        self.assertIn("alt-tab-macos", downloads)

    def test_existing_copy_elsewhere_is_preserved(self):
        result, installed, alt, downloads = self.run_installer(answer="y", existing=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(installed)
        self.assertFalse(alt)
        self.assertNotIn("Install AltTab too?", result.stdout)
        self.assertNotIn("alt-tab-macos", downloads)

    def test_bad_package_digest_stops_before_any_install(self):
        result, installed, alt, _ = self.run_installer(answer="y", bad_digest=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(installed or alt)
        self.assertIn("Checksum mismatch", result.stderr)


if __name__ == "__main__":
    unittest.main()
