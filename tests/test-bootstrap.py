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
    def run_installer(self, answer=None, existing=False, bad_digest=False,
                      provider="optionsplus", arch="arm64", bad_openlogi_digest=False,
                      bad_openlogi_signature=False, incomplete_options=False):
        with tempfile.TemporaryDirectory(prefix="mx4-bootstrap-test-") as directory:
            root = Path(directory)
            apps = root / "Applications"
            apps.mkdir()
            (apps / "Hammerspoon.app").mkdir()
            agent = root / "logi-agent"
            if provider in ("optionsplus", "both"):
                (apps / "logioptionsplus.app").mkdir()
                if not incomplete_options:
                    agent.write_text("fixture")
                    agent.chmod(0o755)
            openlogi = root / "Other Apps" / "OpenLogi.app"
            if provider in ("openlogi", "both"):
                openlogi.mkdir(parents=True)
                (openlogi / "untouched").write_text("existing settings")
            dmgs = root / "openlogi.dmg"
            dmgs.write_text("fake signed DMG")
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
            source = re.sub(r"openlogi_sha256=[0-9a-f]{64}", "openlogi_sha256=" +
                            ("0" * 64 if bad_openlogi_digest else hashlib.sha256(dmgs.read_bytes()).hexdigest()), source)
            source = source.replace("apps_dir=/Applications", f'apps_dir="{apps}"')
            source = re.sub(r"^logi_agent=.+$", f'logi_agent="{agent}"', source, flags=re.M)

            def stub(name, body):
                script = root / name
                script.write_text("#!/bin/sh\nset -eu\n" + body)
                script.chmod(0o755)
                return str(script)

            replacements = {
                "/usr/bin/id": stub("id", "printf '501\\n'\n"),
                "/usr/bin/osascript": stub("lookup", '''
case "$*" in
    *org.openlogi.openlogi*) printf "%s" "$MX4_TEST_OPENLOGI" ;;
    *) printf "%s" "$MX4_TEST_EXISTING" ;;
esac
'''),
                "/usr/bin/uname": stub("uname", '''
case "$1" in -s) echo Darwin ;; -m) echo "$MX4_TEST_ARCH" ;; *) exit 1 ;; esac
'''),
                "/usr/sbin/spctl": stub("assessment", "exit 0\n"),
                "/usr/bin/hdiutil": stub("dmg", '''
case "$1" in
    attach)
        while [ "$1" != -mountpoint ]; do shift; done
        shift
        mkdir -p "$1/OpenLogi.app"
        echo fixture > "$1/OpenLogi.app/fixture"
        ;;
    detach) echo detached >> "$MX4_TEST_DOWNLOADS" ;;
    *) exit 1 ;;
esac
'''),
                "/usr/bin/codesign": stub("signature", '''
case "$*" in
    *Hammerspoon.app*) printf 'TeamIdentifier=VQCYSNZB89\\n' ;;
    *logioptionsplus.app*) printf 'TeamIdentifier=QED4VVPZWA\\n' ;;
    *OpenLogi.app*)
        [ "$MX4_TEST_BAD_SIGNATURE" = 0 ] || exit 1
        printf 'TeamIdentifier=8U3ZJ258K9\\n' ;;
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
    */AprilNEA/OpenLogi/releases/*) cp "$MX4_TEST_DMG" "$output" ;;
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
                       MX4_TEST_PACKAGE=str(package), MX4_TEST_ALTZIP=str(altzip),
                       MX4_TEST_OPENLOGI=str(openlogi) if openlogi.exists() else "",
                       MX4_TEST_DMG=str(dmgs), MX4_TEST_ARCH=arch,
                       MX4_TEST_BAD_SIGNATURE="1" if bad_openlogi_signature else "0")
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
            if openlogi.exists():
                self.assertEqual((openlogi / "untouched").read_text(), "existing settings")
            self.installed_openlogi = (apps / "OpenLogi.app" / "fixture").exists()
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


    def test_missing_provider_downloads_openlogi_for_each_architecture(self):
        for arch in ("arm64", "x86_64"):
            with self.subTest(arch=arch):
                result, installed, _, downloads = self.run_installer(provider="none", arch=arch)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(installed and self.installed_openlogi)
                self.assertIn(f"OpenLogi-v0.8.8-macos-{arch}.dmg", downloads)
                self.assertIn("detached", downloads)
                self.assertNotIn("download01.logi.com", downloads)
                self.assertIn("OpenLogi Agent", result.stdout)

    def test_existing_providers_are_preserved(self):
        for provider in ("openlogi", "optionsplus", "both"):
            with self.subTest(provider=provider):
                result, installed, _, downloads = self.run_installer(provider=provider)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(installed)
                self.assertFalse(self.installed_openlogi)
                self.assertNotIn("OpenLogi/releases", downloads)
                self.assertNotIn("download01.logi.com", downloads)
                if provider == "both":
                    self.assertIn("Both providers are installed", result.stdout)

    def test_partial_options_install_does_not_add_competing_provider(self):
        result, installed, _, downloads = self.run_installer(incomplete_options=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(installed)
        self.assertFalse(self.installed_openlogi)
        self.assertNotIn("OpenLogi/releases", downloads)

    def test_invalid_openlogi_download_is_never_installed(self):
        for field in ("bad_openlogi_digest", "bad_openlogi_signature"):
            with self.subTest(field=field):
                result, installed, _, downloads = self.run_installer(provider="none", **{field: True})
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(installed or self.installed_openlogi)
                if field == "bad_openlogi_signature":
                    self.assertIn("detached", downloads)


if __name__ == "__main__":
    unittest.main()
