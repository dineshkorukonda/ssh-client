import os
import shutil
import tempfile
import unittest
import importlib.util

# Dynamically import scripts/sync_release.py
spec = importlib.util.spec_from_file_location(
    "sync_release",
    os.path.join(os.path.dirname(__file__), "sync_release.py")
)
sync_release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync_release)


class TestSyncRelease(unittest.TestCase):
    def test_get_current_version(self):
        ver = sync_release.get_current_version()
        self.assertRegex(ver, r"^[0-9]+\.[0-9]+\.[0-9]+.*$")

    def test_calculate_next_version(self):
        self.assertEqual(sync_release.calculate_next_version("0.0.8", "patch"), "0.0.9")
        self.assertEqual(sync_release.calculate_next_version("0.0.8", "minor"), "0.1.0")
        self.assertEqual(sync_release.calculate_next_version("0.0.8", "major"), "1.0.0")

    def test_check_emoji_violations_detection(self):
        violations = sync_release.check_emoji_violations()
        self.assertEqual(violations, [])

    def test_mock_bump_version_end_to_end(self):
        tmp_dir = tempfile.mkdtemp(prefix="sync_release_test_")
        try:
            # Create mock file structure
            mix_path = os.path.join(tmp_dir, "mix.exs")
            with open(mix_path, "w", encoding="utf-8") as f:
                f.write('defmodule App.MixProject do\n  @version "0.0.8"\n  def project do\n    [version: "0.0.8"]\n  end\nend\n')

            iss_path = os.path.join(tmp_dir, "installer.iss")
            with open(iss_path, "w", encoding="utf-8") as f:
                f.write('#define AppVersion "0.0.8"\n')

            updater_path = os.path.join(tmp_dir, "updater.ex")
            with open(updater_path, "w", encoding="utf-8") as f:
                f.write('defmodule SSHClient.Updater do\n  @current_version "0.0.8"\nend\n')

            rel_notes_path = os.path.join(tmp_dir, "RELEASE_NOTES.md")
            with open(rel_notes_path, "w", encoding="utf-8") as f:
                f.write('# Release Notes - v0.0.8\n\nSummary notes.\n')

            changelog_path = os.path.join(tmp_dir, "CHANGELOG.md")
            with open(changelog_path, "w", encoding="utf-8") as f:
                f.write('# Changelog\n\nSemantic Versioning](https://semver.org/spec/v2.0.0.html).\n\n## [0.0.8] - 2026-09-05\n- Initial.\n')

            web_idx_path = os.path.join(tmp_dir, "index.html")
            with open(web_idx_path, "w", encoding="utf-8") as f:
                f.write('<span class="app-version-badge">v0.0.8</span>\n<span class="app-latest-release">v0.0.8</span>\n<a href="/releases/download/v0.0.8/ssh-client-setup-v0.0.8-windows-x64.exe">Download</a>\n')

            # Override FILES dict in sync_release
            orig_files = sync_release.FILES.copy()
            sync_release.FILES = {
                "mix": mix_path,
                "installer": iss_path,
                "updater": updater_path,
                "release_notes": rel_notes_path,
                "changelog": changelog_path,
                "web_index": web_idx_path,
                "web_install": os.path.join(tmp_dir, "install.html"),
                "web_install_idx": os.path.join(tmp_dir, "install_idx.html"),
                "web_changelog": os.path.join(tmp_dir, "changelog.html"),
                "web_changelog_idx": os.path.join(tmp_dir, "changelog_idx.html"),
            }

            try:
                # Perform bump to 0.0.9
                sync_release.bump_version("0.0.9", "Test bump notes")

                # Verify files were updated
                with open(mix_path, "r", encoding="utf-8") as f:
                    self.assertIn('version: "0.0.9"', f.read())

                with open(iss_path, "r", encoding="utf-8") as f:
                    self.assertIn('#define AppVersion "0.0.9"', f.read())

                with open(updater_path, "r", encoding="utf-8") as f:
                    self.assertIn('@current_version "0.0.9"', f.read())

                with open(rel_notes_path, "r", encoding="utf-8") as f:
                    self.assertIn('## ssh-client v0.0.9 (Beta)', f.read())

                with open(changelog_path, "r", encoding="utf-8") as f:
                    self.assertIn('## [0.0.9]', f.read())

                with open(web_idx_path, "r", encoding="utf-8") as f:
                    content = f.read()
                    self.assertIn('v0.0.9', content)
                    self.assertIn('ssh-client-setup-v0.0.9-windows-x64.exe', content)

            finally:
                sync_release.FILES = orig_files

        finally:
            shutil.rmtree(tmp_dir, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
