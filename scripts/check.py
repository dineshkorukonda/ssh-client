#!/usr/bin/env python3
"""
Pre-flight verification script for ssh-client.
Runs all repository checks in sequence:
  1. Zero-emoji aesthetic compliance
  2. Release metadata version synchronization
  3. Release script unit tests
  4. Elixir unit test suite (mix test)
"""

import os
import sys
import subprocess
import shutil

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def run_step(step_name, cmd, cwd=REPO_ROOT, env=None):
    print(f"\n=== [STEP] {step_name} ===")
    print(f"Running: {' '.join(cmd) if isinstance(cmd, list) else cmd}")
    res = subprocess.run(cmd, cwd=cwd, shell=isinstance(cmd, str), env=env)
    if res.returncode != 0:
        print(f"\nFAILED: {step_name} exited with status {res.returncode}")
        sys.exit(res.returncode)
    print(f"PASSED: {step_name}")

def resolve_mix_command(env=None):
    path = env.get("PATH") if env else None
    if shutil.which("mix", path=path):
        return [shutil.which("mix", path=path), "test"] if sys.platform == "win32" else ["mix", "test"]
    
    scoop_elixir = os.path.expanduser(r"~\scoop\apps\elixir\current\bin\mix.ps1")
    scoop_elixir_bat = os.path.expanduser(r"~\scoop\apps\elixir\current\bin\mix.bat")
    scoop_shims_mix = os.path.expanduser(r"~\scoop\shims\mix.ps1")
    
    if os.path.exists(scoop_elixir_bat):
        return [scoop_elixir_bat, "test"]
    elif os.path.exists(scoop_shims_mix) or os.path.exists(scoop_elixir):
        return ["powershell", "-NoProfile", "-Command", "mix test"]
    
    return ["mix", "test"]

def main():
    print("Starting pre-flight verification...")
    
    env = os.environ.copy()
    if sys.platform == "win32":
        scoop_paths = [
            os.path.expanduser(r"~\scoop\apps\elixir\current\bin"),
            os.path.expanduser(r"~\scoop\apps\erlang\current\bin"),
            os.path.expanduser(r"~\scoop\shims"),
        ]
        existing_path = env.get("PATH", "")
        env["PATH"] = ";".join(scoop_paths) + ";" + existing_path

    # Step 1: Emoji compliance check
    run_step(
        "Zero-Emoji Compliance Audit",
        [sys.executable, os.path.join(REPO_ROOT, "scripts", "sync_release.py"), "--emoji-check"],
        env=env
    )

    # Step 2: Version synchronization check
    run_step(
        "Release Version Synchronization",
        [sys.executable, os.path.join(REPO_ROOT, "scripts", "sync_release.py"), "--check"],
        env=env
    )

    # Step 3: Release script unit tests
    run_step(
        "Release Script Unit Tests",
        [sys.executable, os.path.join(REPO_ROOT, "scripts", "test_sync_release.py"), "-v"],
        env=env
    )

    # Step 4: Mix test suite
    mix_cmd = resolve_mix_command(env=env)
    run_step(
        "Elixir Unit Tests (mix test)",
        mix_cmd,
        env=env
    )

    print("\n=======================================================")
    print("SUCCESS: All pre-flight checks passed!")
    print("=======================================================")

if __name__ == "__main__":
    main()
