import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RELEASE_BOT = ROOT / ".github" / "workflows" / "release-bot.yml"
CI = ROOT / ".github" / "workflows" / "ci.yml"


def read_workflow(path):
    return path.read_text(encoding="utf-8")


def indented_block(workflow, header, indent):
    lines = workflow.splitlines()
    expected_header = f"{' ' * indent}{header}:"
    try:
        start = lines.index(expected_header) + 1
    except ValueError as error:
        raise AssertionError(f"Missing {header!r} block") from error

    body = []
    for line in lines[start:]:
        if line and len(line) - len(line.lstrip()) <= indent:
            break
        body.append(line)
    return "\n".join(body)


def top_level_block(workflow, key):
    return indented_block(workflow, key, 0)


def job_block(workflow, job_name):
    return indented_block(top_level_block(workflow, "jobs"), job_name, 2)


class TestReleaseBotWorkflow(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = read_workflow(RELEASE_BOT)

    def test_can_dispatch_release_workflow(self):
        permissions = top_level_block(self.workflow, "permissions")
        self.assertRegex(permissions, r"(?m)^  actions:\s*write\s*$")

    def test_dispatches_ci_at_new_tag_after_pushing_tag(self):
        auto_release = job_block(self.workflow, "auto-release")
        tag_push = 'git push origin "v${NEW_VER}"'
        dispatch = 'gh workflow run ci.yml --ref "v${NEW_VER}"'
        self.assertIn(dispatch, auto_release)
        self.assertIn("GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}", auto_release)
        self.assertNotIn("continue-on-error: true", auto_release)
        self.assertLess(auto_release.index(tag_push), auto_release.index(dispatch))


class TestCIWorkflow(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = read_workflow(CI)

    def test_supports_tag_pr_and_manual_release_triggers(self):
        triggers = top_level_block(self.workflow, "on")
        self.assertRegex(triggers, r"(?m)^  pull_request:\s*$")
        self.assertRegex(triggers, r'(?m)^    tags:\s*\[\s*"v\*"\s*\]\s*$')
        self.assertRegex(triggers, r"(?m)^  workflow_dispatch:\s*$")

    def test_serializes_same_ref_without_cancelling_running_release(self):
        concurrency = top_level_block(self.workflow, "concurrency")
        self.assertRegex(concurrency, r"(?m)^  group:.*github\.ref")
        self.assertRegex(concurrency, r"(?m)^  cancel-in-progress:\s*false\s*$")

    def test_backend_matrix_runs_real_connections_on_windows_and_linux(self):
        block = job_block(self.workflow, "test")
        self.assertIn("os: [ubuntu-latest, windows-latest]", block)
        self.assertIn("run: mix test", block)
        self.assertIn("local_ssh_integration_test.exs --include integration", block)
        self.assertNotIn("if: github.event_name", block)

    def test_release_packages_require_successful_backend_tests(self):
        for name in ("native-windows", "package-linux", "publish-container"):
            block = job_block(self.workflow, name)
            self.assertIn("needs: [metadata-check, test]", block)
        self.assertIn("needs: [native-windows, package-linux, publish-container]", job_block(self.workflow, "release"))
        self.assertIn("platforms: linux/amd64,linux/arm64", job_block(self.workflow, "publish-container"))

    def test_release_keeps_required_assets_and_container_tags(self):
        windows = job_block(self.workflow, "native-windows")
        linux = job_block(self.workflow, "package-linux")
        container = job_block(self.workflow, "publish-container")
        release = job_block(self.workflow, "release")

        self.assertIn("ssh-client-windows-x64.zip", windows)
        self.assertIn("installer\\ssh-client-setup-v*-windows-x64.exe", windows)
        self.assertIn("ssh-client-linux-x64.tar.gz", linux)
        self.assertIn(
            "ghcr.io/${{ github.repository }}:${{ steps.version.outputs.version }}",
            container,
        )
        self.assertIn("ghcr.io/${{ github.repository }}:latest", container)
        self.assertRegex(release, r"(?m)^          make_latest:\s*true\s*$")

    def test_native_application_and_installer_are_validated_on_pull_requests(self):
        windows = job_block(self.workflow, "native-windows")
        self.assertNotRegex(windows, r"(?m)^    if:")
        self.assertIn("dotnet-version: '10.0.x'", windows)
        self.assertIn("./scripts/build_windows.ps1", windows)
        self.assertIn("./scripts/test_native_windows.ps1", windows)
        installer = (ROOT / "windows" / "installer.iss").read_text(encoding="utf-8")
        self.assertIn('#define AppExeName "ssh-client.exe"', installer)
        self.assertNotIn("taskkill.exe", installer)
        self.assertNotIn("wscript.exe", installer)

    def test_release_download_excludes_build_metadata_artifacts(self):
        release = job_block(self.workflow, "release")
        self.assertRegex(release, r"(?m)^          pattern:\s*ssh-client-\*\s*$")


if __name__ == "__main__":
    unittest.main()
