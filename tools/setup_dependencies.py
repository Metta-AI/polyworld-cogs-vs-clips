#!/usr/bin/env python3
"""Fetch pinned dependencies into a private directory without editing siblings."""
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
DESTINATION = ROOT / '.deps'
DESTINATION.mkdir(exist_ok=True)
for line in (ROOT / 'dependencies.lock').read_text().splitlines():
    name, version, url, revision = line.split()
    directory = DESTINATION / name
    if not directory.exists():
        subprocess.run(['git', 'init', str(directory)], check=True)
        subprocess.run(['git', '-C', str(directory), 'remote', 'add', 'origin', url], check=True)
    current = subprocess.run(['git', '-C', str(directory), 'rev-parse', 'HEAD'], capture_output=True, text=True)
    if current.returncode == 0 and current.stdout.strip() == revision:
        continue
    dirty = subprocess.check_output(['git', '-C', str(directory), 'status', '--porcelain'], text=True)
    if dirty:
        raise SystemExit(f'Refusing to replace modified dependency: {directory}')
    subprocess.run(['git', '-C', str(directory), 'fetch', '--depth=1', 'origin', revision], check=True)
    subprocess.run(['git', '-C', str(directory), 'checkout', '--detach', revision], check=True)
print(f'Dependencies ready. Set POLYWORLD_DEPS={DESTINATION}')
