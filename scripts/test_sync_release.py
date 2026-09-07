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


def _write(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)


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

    def test_version_sources_exclude_root_release_docs(self):
        self.assertNotIn("release_notes", sync_release.FILES)
        self.assertNotIn("changelog", sync_release.FILES)
        versions = sync_release.extract_versions()
        self.assertNotIn("RELEASE_NOTES.md", versions)
        self.assertNotIn("CHANGELOG.md", versions)

    def test_extract_versions_ignores_leftover_root_markdown(self):
        tmp_dir = tempfile.mkdtemp(prefix="sync_release_ignore_md_")
        orig_files = sync_release.FILES.copy()
        orig_root = sync_release.ROOT_DIR
        try:
            mix_path = os.path.join(tmp_dir, "mix.exs")
            _write(mix_path, 'defmodule App.MixProject do\n  def project do\n    [version: "0.0.9"]\n  end\nend\n')
            _write(os.path.join(tmp_dir, "installer.iss"), '#define AppVersion "0.0.9"\n')
            _write(os.path.join(tmp_dir, "updater.ex"), 'defmodule SSHClient.Updater do\n  @current_version "0.0.9"\nend\n')
            _write(
                os.path.join(tmp_dir, "index.html"),
                '<span class="font-mono text-[10px] text-neutral-500 border border-neutral-800 px-1.5 py-0.5 rounded ml-1">v0.0.9</span>\n',
            )
            _write(os.path.join(tmp_dir, "RELEASE_NOTES.md"), "## ssh-client v0.0.1 (Beta)\n")
            _write(os.path.join(tmp_dir, "CHANGELOG.md"), "## [0.0.1] - 2026-01-01\n")

            sync_release.ROOT_DIR = tmp_dir
            sync_release.FILES = {
                "mix": mix_path,
                "installer": os.path.join(tmp_dir, "installer.iss"),
                "updater": os.path.join(tmp_dir, "updater.ex"),
                "web_index": os.path.join(tmp_dir, "index.html"),
                "web_install": os.path.join(tmp_dir, "install.html"),
                "web_install_idx": os.path.join(tmp_dir, "install_idx.html"),
                "web_changelog": os.path.join(tmp_dir, "changelog.html"),
                "web_changelog_idx": os.path.join(tmp_dir, "changelog_idx.html"),
            }

            versions = sync_release.extract_versions()
            self.assertEqual(set(versions.values()), {"0.0.9"})
            self.assertNotIn("RELEASE_NOTES.md", versions)
            self.assertNotIn("CHANGELOG.md", versions)
            self.assertTrue(sync_release.check_sync("0.0.9"))
        finally:
            sync_release.FILES = orig_files
            sync_release.ROOT_DIR = orig_root
            shutil.rmtree(tmp_dir, ignore_errors=True)

    def test_check_sync_fails_on_version_mismatch(self):
        tmp_dir = tempfile.mkdtemp(prefix="sync_release_mismatch_")
        orig_files = sync_release.FILES.copy()
        try:
            mix_path = os.path.join(tmp_dir, "mix.exs")
            _write(mix_path, 'defmodule App.MixProject do\n  def project do\n    [version: "0.0.9"]\n  end\nend\n')
            _write(os.path.join(tmp_dir, "installer.iss"), '#define AppVersion "0.0.8"\n')
            _write(os.path.join(tmp_dir, "updater.ex"), 'defmodule SSHClient.Updater do\n  @current_version "0.0.9"\nend\n')
            _write(
                os.path.join(tmp_dir, "index.html"),
                '<span class="font-mono text-[10px] text-neutral-500 border border-neutral-800 px-1.5 py-0.5 rounded ml-1">v0.0.9</span>\n',
            )

            sync_release.FILES = {
                "mix": mix_path,
                "installer": os.path.join(tmp_dir, "installer.iss"),
                "updater": os.path.join(tmp_dir, "updater.ex"),
                "web_index": os.path.join(tmp_dir, "index.html"),
                "web_install": os.path.join(tmp_dir, "install.html"),
                "web_install_idx": os.path.join(tmp_dir, "install_idx.html"),
                "web_changelog": os.path.join(tmp_dir, "changelog.html"),
                "web_changelog_idx": os.path.join(tmp_dir, "changelog_idx.html"),
            }

            self.assertFalse(sync_release.check_sync("0.0.9"))
        finally:
            sync_release.FILES = orig_files
            shutil.rmtree(tmp_dir, ignore_errors=True)

    def test_mock_bump_version_end_to_end(self):
        tmp_dir = tempfile.mkdtemp(prefix="sync_release_test_")
        try:
            mix_path = os.path.join(tmp_dir, "mix.exs")
            _write(mix_path, 'defmodule App.MixProject do\n  @version "0.0.8"\n  def project do\n    [version: "0.0.8"]\n  end\nend\n')

            iss_path = os.path.join(tmp_dir, "installer.iss")
            _write(iss_path, '#define AppVersion "0.0.8"\n')

            updater_path = os.path.join(tmp_dir, "updater.ex")
            _write(updater_path, 'defmodule SSHClient.Updater do\n  @current_version "0.0.8"\nend\n')

            leftover_notes = os.path.join(tmp_dir, "RELEASE_NOTES.md")
            leftover_changelog = os.path.join(tmp_dir, "CHANGELOG.md")
            _write(leftover_notes, "## ssh-client v0.0.8 (Beta)\n\nSummary notes.\n")
            _write(leftover_changelog, "# Changelog\n\nSemantic Versioning](https://semver.org/spec/v2.0.0.html).\n\n## [0.0.8] - 2026-09-05\n- Initial.\n")

            web_idx_path = os.path.join(tmp_dir, "index.html")
            _write(
                web_idx_path,
                '<span class="font-mono text-[10px] text-neutral-500 border border-neutral-800 px-1.5 py-0.5 rounded ml-1">v0.0.8</span>\n'
                '<span class="app-latest-release">v0.0.8</span>\n'
                '<a href="https://github.com/dineshkorukonda/ssh-client/releases/tag/v0.0.8">GitHub Release v0.0.8 ↗</a>\n'
                '<pre>ssh-client-setup-v0.0.8-windows-x64.exe</pre>\n'
                '<h3>Download v0.0.8</h3>\n'
                '<a href="/releases/download/v0.0.8/ssh-client-setup-v0.0.8-windows-x64.exe">Download</a>\n'
                '<a href="/releases/download/v0.0.8/ssh-client-windows-x64.zip">Download Zip</a>\n'
                '<a href="/releases/download/v0.0.8/ssh-client-linux-x64.tar.gz">Download Tar</a>\n'
                '<code>docker pull ghcr.io/dineshkorukonda/ssh-client:0.0.8</code>\n',
            )

            web_changelog_path = os.path.join(tmp_dir, "changelog.html")
            _write(
                web_changelog_path,
                '<span class="font-mono text-[10px] text-neutral-400 border border-neutral-800 px-1.5 py-0.5 rounded ml-1">v0.0.8</span>\n'
                '    <!-- Version v0.0.8 -->\n'
                '    <section class="space-y-6">\n'
                '      <span class="text-xl font-bold text-white">v0.0.8</span>\n'
                '      <span class="font-mono text-[10px] text-red-500 border border-red-950 bg-red-950/20 px-2 py-0.5 rounded app-latest-release">latest release</span>\n'
                '      <a href="https://github.com/dineshkorukonda/ssh-client/releases/tag/v0.0.8">GitHub Release ↗</a>\n'
                '    </section>\n',
            )

            orig_files = sync_release.FILES.copy()
            sync_release.FILES = {
                "mix": mix_path,
                "installer": iss_path,
                "updater": updater_path,
                "web_index": web_idx_path,
                "web_install": os.path.join(tmp_dir, "install.html"),
                "web_install_idx": os.path.join(tmp_dir, "install_idx.html"),
                "web_changelog": web_changelog_path,
                "web_changelog_idx": os.path.join(tmp_dir, "changelog_idx.html"),
            }

            try:
                sync_release.bump_version("0.0.9", "Test bump notes")

                with open(mix_path, "r", encoding="utf-8") as f:
                    self.assertIn('version: "0.0.9"', f.read())

                with open(iss_path, "r", encoding="utf-8") as f:
                    self.assertIn('#define AppVersion "0.0.9"', f.read())

                with open(updater_path, "r", encoding="utf-8") as f:
                    self.assertIn('@current_version "0.0.9"', f.read())

                with open(leftover_notes, "r", encoding="utf-8") as f:
                    leftover_notes_body = f.read()
                    self.assertIn("v0.0.8", leftover_notes_body)
                    self.assertNotIn("v0.0.9", leftover_notes_body)

                with open(leftover_changelog, "r", encoding="utf-8") as f:
                    leftover_changelog_body = f.read()
                    self.assertIn("## [0.0.8]", leftover_changelog_body)
                    self.assertNotIn("## [0.0.9]", leftover_changelog_body)

                self.assertFalse(os.path.exists(os.path.join(tmp_dir, "web", "RELEASE_NOTES.md")))

                with open(web_idx_path, "r", encoding="utf-8") as f:
                    content = f.read()
                    self.assertIn('v0.0.9</span>', content)
                    self.assertIn('GitHub Release v0.0.9 ↗', content)
                    self.assertIn('releases/tag/v0.0.9', content)
                    self.assertIn('Download v0.0.9', content)
                    self.assertIn('ssh-client-setup-v0.0.9-windows-x64.exe', content)
                    self.assertIn('ssh-client-windows-x64.zip', content)
                    self.assertIn('ssh-client-linux-x64.tar.gz', content)
                    self.assertIn('docker pull ghcr.io/dineshkorukonda/ssh-client:0.0.9', content)

                with open(web_changelog_path, "r", encoding="utf-8") as f:
                    cl_html = f.read()
                    self.assertIn('<!-- Version v0.0.9 -->', cl_html)
                    self.assertIn('<!-- Version v0.0.8 -->', cl_html)
                    self.assertIn('releases/tag/v0.0.9', cl_html)
                    self.assertIn('releases/tag/v0.0.8', cl_html)
                    self.assertIn("Test bump notes", cl_html)

                self.assertTrue(sync_release.check_sync("0.0.9"))

            finally:
                sync_release.FILES = orig_files

        finally:
            shutil.rmtree(tmp_dir, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
