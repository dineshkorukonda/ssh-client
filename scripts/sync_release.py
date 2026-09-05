#!/usr/bin/env python3
"""
Release and Changelog Synchronization Tool for ssh-client.
Enforces synchronization across all 6 version locations and guarantees zero emojis.

Usage:
  python scripts/sync_release.py --check [version]
  python scripts/sync_release.py --emoji-check
  python scripts/sync_release.py --get-current
  python scripts/sync_release.py --get-next [patch|minor|major]
  python scripts/sync_release.py <version> [--notes "Release summary"]
  python scripts/sync_release.py --auto-bump "Commit message or PR title"
"""

import sys
import os
import re
import argparse
from datetime import date

ROOT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

FILES = {
    "mix": os.path.join(ROOT_DIR, "mix.exs"),
    "installer": os.path.join(ROOT_DIR, "windows", "installer.iss"),
    "updater": os.path.join(ROOT_DIR, "lib", "ssh_client", "updater.ex"),
    "release_notes": os.path.join(ROOT_DIR, "RELEASE_NOTES.md"),
    "changelog": os.path.join(ROOT_DIR, "CHANGELOG.md"),
    "web_index": os.path.join(ROOT_DIR, "web", "index.html"),
    "web_install": os.path.join(ROOT_DIR, "web", "install.html"),
    "web_install_idx": os.path.join(ROOT_DIR, "web", "install", "index.html"),
    "web_changelog": os.path.join(ROOT_DIR, "web", "changelog.html"),
    "web_changelog_idx": os.path.join(ROOT_DIR, "web", "changelog", "index.html"),
}

ALLOWED_CODEPOINTS = {
    0x2190, 0x2191, 0x2192, 0x2193, 0x2194,  # arrows
    0x21B5,                                    # carriage return arrow
    0x2022, 0x2023, 0x25AA, 0x25AB,            # bullets
    0x2500, 0x2502, 0x250C, 0x2510, 0x2514, 0x2518, 0x251C, 0x2524, 0x252C, 0x2534, 0x253C, # box drawing
    0x2588, 0x2591, 0x2592, 0x2593,            # block elements
    0x2014, 0x2013,                            # dashes
    0x2018, 0x2019, 0x201C, 0x201D,            # quotes
    0x2026,                                    # ellipsis
}


def extract_versions():
    versions = {}

    # 1. mix.exs: version: "0.0.x"
    if os.path.exists(FILES["mix"]):
        with open(FILES["mix"], "r", encoding="utf-8") as f:
            content = f.read()
            m = re.search(r'version:\s*"([^"]+)"', content)
            if m:
                versions["mix.exs"] = m.group(1)

    # 2. windows/installer.iss: #define AppVersion "0.0.x"
    if os.path.exists(FILES["installer"]):
        with open(FILES["installer"], "r", encoding="utf-8") as f:
            content = f.read()
            m = re.search(r'#define\s+AppVersion\s+"([^"]+)"', content)
            if m:
                versions["windows/installer.iss"] = m.group(1)

    # 3. lib/ssh_client/updater.ex: @current_version "0.0.x"
    if os.path.exists(FILES["updater"]):
        with open(FILES["updater"], "r", encoding="utf-8") as f:
            content = f.read()
            m = re.search(r'@current_version\s+"([^"]+)"', content)
            if m:
                versions["lib/ssh_client/updater.ex"] = m.group(1)

    # 4. RELEASE_NOTES.md: ## ssh-client v0.0.x
    if os.path.exists(FILES["release_notes"]):
        with open(FILES["release_notes"], "r", encoding="utf-8") as f:
            content = f.read()
            m = re.search(r"##\s+ssh-client\s+v([0-9]+\.[0-9]+\.[0-9]+[a-zA-Z0-9.\-]*)", content)
            if m:
                versions["RELEASE_NOTES.md"] = m.group(1)

    # 5. CHANGELOG.md: ## [0.0.x]
    if os.path.exists(FILES["changelog"]):
        with open(FILES["changelog"], "r", encoding="utf-8") as f:
            content = f.read()
            m = re.search(r"##\s+\[([0-9]+\.[0-9]+\.[0-9]+[a-zA-Z0-9.\-]*)\]", content)
            if m:
                versions["CHANGELOG.md"] = m.group(1)

    # 6. web/index.html: v0.0.x
    if os.path.exists(FILES["web_index"]):
        with open(FILES["web_index"], "r", encoding="utf-8") as f:
            content = f.read()
            m = re.search(r'class="[^"]*app-version-badge[^"]*"[^>]*>v([0-9]+\.[0-9]+\.[0-9]+[a-zA-Z0-9.\-]*)<', content)
            if not m:
                m = re.search(r'>v([0-9]+\.[0-9]+\.[0-9]+[a-zA-Z0-9.\-]*)<', content)
            if m:
                versions["web/index.html"] = m.group(1)

    return versions


def get_current_version():
    versions = extract_versions()
    return versions.get("mix.exs", "0.0.1")


def calculate_next_version(current=None, bump_type="patch"):
    if not current:
        current = get_current_version()

    parts = current.split(".")
    try:
        major = int(parts[0])
        minor = int(parts[1]) if len(parts) > 1 else 0
        patch = int(parts[2]) if len(parts) > 2 else 0
    except ValueError:
        return current + ".1"

    if bump_type == "major":
        return f"{major + 1}.0.0"
    elif bump_type == "minor":
        return f"{major}.{minor + 1}.0"
    else:  # patch
        return f"{major}.{minor}.{patch + 1}"


def check_emoji_violations():
    violations = []
    scan_exts = (
        ".ex",
        ".exs",
        ".heex",
        ".html",
        ".md",
        ".iss",
        ".js",
        ".css",
        ".json",
        ".yml",
        ".yaml",
        ".sh",
        ".bat",
    )
    ignored_dirs = {".git", "_build", "deps", "node_modules", "installer", ".elixir_ls"}

    for root, dirs, files in os.walk(ROOT_DIR):
        dirs[:] = [d for d in dirs if d not in ignored_dirs]
        for file in files:
            if not file.endswith(scan_exts):
                continue
            path = os.path.join(root, file)
            rel_path = os.path.relpath(path, ROOT_DIR)
            with open(path, "r", encoding="utf-8", errors="ignore") as f:
                for line_num, line in enumerate(f, 1):
                    for char in line:
                        code = ord(char)
                        if code in ALLOWED_CODEPOINTS:
                            continue
                        if (
                            0x1F300 <= code <= 0x1FAFF
                            or 0x2600 <= code <= 0x27BF
                            or 0xFE00 <= code <= 0xFE0F
                            or 0x1F900 <= code <= 0x1F9FF
                            or 0x1F600 <= code <= 0x1F64F
                            or 0x1F680 <= code <= 0x1F6FF
                        ):
                            violations.append(
                                f"{rel_path}:{line_num}: character U+{code:04X} in '{line.strip()}'"
                            )
                            break
    return violations


def check_sync(expected_version=None):
    versions = extract_versions()
    print("Checking version synchronization across repository files...")
    all_ok = True
    found_versions = set(versions.values())

    for filename, ver in versions.items():
        match_str = "OK"
        if expected_version and ver != expected_version:
            match_str = f"MISMATCH (expected {expected_version})"
            all_ok = False
        print(f"  - {filename:<32} : {ver} [{match_str}]")

    if len(found_versions) > 1:
        print(f"\nERROR: Inconsistent versions detected across files: {found_versions}")
        all_ok = False

    if expected_version and (len(found_versions) != 1 or list(found_versions)[0] != expected_version):
        print(f"\nERROR: Repository version does not match expected version '{expected_version}'")
        all_ok = False

    if all_ok:
        current_v = list(found_versions)[0] if found_versions else "unknown"
        print(f"\nSUCCESS: All files synchronized at version {current_v}.")

    return all_ok


def bump_version(new_version, notes=None):
    today = date.today().strftime("%Y-%m-%d")
    current_versions = extract_versions()
    old_version = current_versions.get("mix.exs", "0.0.1")

    print(f"Bumping version from {old_version} -> {new_version}...")

    # 1. mix.exs
    if os.path.exists(FILES["mix"]):
        with open(FILES["mix"], "r", encoding="utf-8") as f:
            content = f.read()
        content = re.sub(r'version:\s*"[^"]+"', f'version: "{new_version}"', content)
        with open(FILES["mix"], "w", encoding="utf-8") as f:
            f.write(content)
        print(f"  Updated {FILES['mix']}")

    # 2. windows/installer.iss
    if os.path.exists(FILES["installer"]):
        with open(FILES["installer"], "r", encoding="utf-8") as f:
            content = f.read()
        content = re.sub(
            r'#define\s+AppVersion\s+"[^"]+"',
            f'#define AppVersion "{new_version}"',
            content,
        )
        with open(FILES["installer"], "w", encoding="utf-8") as f:
            f.write(content)
        print(f"  Updated {FILES['installer']}")

    # 3. lib/ssh_client/updater.ex
    if os.path.exists(FILES["updater"]):
        with open(FILES["updater"], "r", encoding="utf-8") as f:
            content = f.read()
        content = re.sub(
            r'@current_version\s+"[^"]+"',
            f'@current_version "{new_version}"',
            content,
        )
        with open(FILES["updater"], "w", encoding="utf-8") as f:
            f.write(content)
        print(f"  Updated {FILES['updater']}")

    # 4. RELEASE_NOTES.md
    if os.path.exists(FILES["release_notes"]):
        notes_body = notes if notes else f"Beta release v{new_version} updates application binaries and features."
        new_release_notes = f"""## ssh-client v{new_version} (Beta)

{notes_body}

---

### Binary Packages and Downloads

| Platform | Format | Package / Asset |
|---|---|---|
| Windows x64 | Single-File Installer | [ssh-client-setup-v{new_version}-windows-x64.exe](https://github.com/dineshkorukonda/ssh-client/releases/download/v{new_version}/ssh-client-setup-v{new_version}-windows-x64.exe) |
| Windows x64 | Portable ZIP Archive | [ssh-client-windows-x64.zip](https://github.com/dineshkorukonda/ssh-client/releases/download/v{new_version}/ssh-client-windows-x64.zip) |
| Linux x64 | Standalone Tarball | [ssh-client-linux-x64.tar.gz](https://github.com/dineshkorukonda/ssh-client/releases/download/v{new_version}/ssh-client-linux-x64.tar.gz) |
| Container (Docker) | GitHub Packages (GHCR) | `docker pull ghcr.io/dineshkorukonda/ssh-client:{new_version}` |

---

### Key Highlights in v{new_version}

- **Update Notes**: {notes_body}
- **Editorial Stark Dark UI**: Zero-emoji monochrome interface with high-contrast typography and real-time telemetry.
- **Master Vault**: PBKDF2 with AES-256-GCM encryption.
- **Integrated SFTP Explorer & Multi-Tab Terminal**: Remote directory explorer and embedded full-bleed xterm.js terminal.

---

### Documentation & Links

- Repository: https://github.com/dineshkorukonda/ssh-client
- Documentation: https://ssh-client.dineshkorukonda.online
- Installation: https://ssh-client.dineshkorukonda.online/install
- Changelog: https://ssh-client.dineshkorukonda.online/changelog
"""
        with open(FILES["release_notes"], "w", encoding="utf-8") as f:
            f.write(new_release_notes)
        print(f"  Updated {FILES['release_notes']}")

    # 5. CHANGELOG.md
    if os.path.exists(FILES["changelog"]):
        with open(FILES["changelog"], "r", encoding="utf-8") as f:
            cl_content = f.read()
        if f"## [{new_version}]" not in cl_content:
            entry = f"\n## [{new_version}] - {today}\n\n### Changed\n- {notes or 'General improvements and bug fixes.'}\n\n---\n"
            header_marker = "Semantic Versioning](https://semver.org/spec/v2.0.0.html).\n"
            header_end = cl_content.find(header_marker)
            if header_end != -1:
                insert_pos = header_end + len(header_marker)
                cl_content = cl_content[:insert_pos] + entry + cl_content[insert_pos:]
            else:
                cl_content = entry + cl_content
            with open(FILES["changelog"], "w", encoding="utf-8") as f:
                f.write(cl_content)
            print(f"  Updated {FILES['changelog']}")

    # 6. web HTML files
    web_files = [
        FILES["web_index"],
        FILES["web_install"],
        FILES["web_install_idx"],
        FILES["web_changelog"],
        FILES["web_changelog_idx"],
    ]
    for wpath in web_files:
        if os.path.exists(wpath):
            # Replace navbar and hero version badges
            w_content = re.sub(
                r'(class="[^"]*app-version-badge[^"]*"[^>]*>)v[0-9]+\.[0-9]+\.[0-9]+[a-zA-Z0-9.\-]*(</span>)',
                rf'\g<1>v{new_version}\g<2>',
                w_content,
            )
            w_content = re.sub(
                r'(class="[^"]*app-latest-release[^"]*"[^>]*>)v[0-9]+\.[0-9]+\.[0-9]+[a-zA-Z0-9.\-]*(</span>)',
                rf'\g<1>v{new_version}\g<2>',
                w_content,
            )
            # Replace download URLs
            w_content = re.sub(
                r'/releases/download/v[0-9]+\.[0-9]+\.[0-9]+[a-zA-Z0-9.\-]*/ssh-client-setup-v[0-9]+\.[0-9]+\.[0-9]+[a-zA-Z0-9.\-]*-windows-x64\.exe',
                f'/releases/download/v{new_version}/ssh-client-setup-v{new_version}-windows-x64.exe',
                w_content,
            )
            w_content = re.sub(
                r'/releases/download/v[0-9]+\.[0-9]+\.[0-9]+[a-zA-Z0-9.\-]*/ssh-client-windows-x64\.zip',
                f'/releases/download/v{new_version}/ssh-client-windows-x64.zip',
                w_content,
            )
            w_content = re.sub(
                r'/releases/download/v[0-9]+\.[0-9]+\.[0-9]+[a-zA-Z0-9.\-]*/ssh-client-linux-x64\.tar\.gz',
                f'/releases/download/v{new_version}/ssh-client-linux-x64.tar.gz',
                w_content,
            )
            w_content = re.sub(
                r'docker pull ghcr\.io/dineshkorukonda/ssh-client:[0-9]+\.[0-9]+\.[0-9]+[a-zA-Z0-9.\-]*',
                f'docker pull ghcr.io/dineshkorukonda/ssh-client:{new_version}',
                w_content,
            )
            with open(wpath, "w", encoding="utf-8") as f:
                f.write(w_content)
            print(f"  Updated {wpath}")

    print("\nVerifying synchronization after update...")
    check_sync(new_version)


def main():
    parser = argparse.ArgumentParser(description="Synchronize and validate versions and changelogs.")
    parser.add_argument("version", nargs="?", help="New version to bump across repository (e.g. 0.0.3)")
    parser.add_argument("--check", nargs="?", const="", help="Check version synchronization across all files")
    parser.add_argument("--emoji-check", action="store_true", help="Audit repository for emoji violations")
    parser.add_argument("--get-current", action="store_true", help="Print current repository version")
    parser.add_argument("--get-next", nargs="?", const="patch", help="Calculate next version (patch|minor|major)")
    parser.add_argument("--auto-bump", help="Automatically bump version using commit/PR message")
    parser.add_argument("--notes", help="Release notes summary for the version bump")

    args = parser.parse_args()

    if args.get_current:
        print(get_current_version())
        sys.exit(0)

    if args.get_next:
        bump_t = args.get_next.lower() if args.get_next in ("patch", "minor", "major") else "patch"
        print(calculate_next_version(bump_type=bump_t))
        sys.exit(0)

    if args.emoji_check:
        print("Auditing repository for emoji violations...")
        violations = check_emoji_violations()
        if violations:
            print(f"ERROR: Found {len(violations)} emoji violation(s):")
            for v in violations:
                print(f"  {v}")
            sys.exit(1)
        else:
            print("SUCCESS: 0 emoji violations detected. Codebase complies with strict aesthetic rules.")
            sys.exit(0)

    if args.check is not None:
        target_v = args.check.lstrip("v") if args.check else None
        ok = check_sync(target_v)
        if not ok:
            sys.exit(1)
        # Also run emoji check as part of --check
        violations = check_emoji_violations()
        if violations:
            print(f"ERROR: Found {len(violations)} emoji violation(s):")
            for v in violations:
                print(f"  {v}")
            sys.exit(1)
        sys.exit(0)

    if args.auto_bump:
        msg = args.auto_bump.strip()
        # Clean merge prefixes like "Merge pull request #123 from ... \n\n feat: something"
        lines = [line.strip() for line in msg.splitlines() if line.strip()]
        first_line = lines[0] if lines else "chore: updates"
        for line in lines:
            if not line.startswith("Merge pull request") and not line.startswith("Merge branch"):
                first_line = line
                break

        # Determine bump type
        bump_type = "patch"
        if first_line.startswith("feat:") or first_line.startswith("feat("):
            bump_type = "patch" # in 0.0.x beta lifecycle, features advance patch or minor
        elif "BREAKING CHANGE" in msg:
            bump_type = "minor"

        next_ver = calculate_next_version(bump_type=bump_type)
        print(f"Auto-bumping version to {next_ver} based on message: '{first_line}'")
        bump_version(next_ver, first_line)
        violations = check_emoji_violations()
        if violations:
            print(f"ERROR: Found {len(violations)} emoji violation(s):")
            for v in violations:
                print(f"  {v}")
            sys.exit(1)
        # Output next_ver to stdout for scripts/actions
        print(f"NEW_VERSION={next_ver}")
        sys.exit(0)

    if args.version:
        ver = args.version.lstrip("v")
        bump_version(ver, args.notes)
        violations = check_emoji_violations()
        if violations:
            print(f"ERROR: Found {len(violations)} emoji violation(s):")
            for v in violations:
                print(f"  {v}")
            sys.exit(1)
        sys.exit(0)

    parser.print_help()


if __name__ == "__main__":
    main()
