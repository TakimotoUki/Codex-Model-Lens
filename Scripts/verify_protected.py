#!/usr/bin/env python3
"""Compare file metadata without modifying sibling development folders."""
from pathlib import Path
import json
import os
import argparse

project = Path(__file__).resolve().parent.parent
root = project.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline', type=Path, default=project / 'Documentation/protected-files-before.json')
parser.add_argument('--output', type=Path, default=project / 'Documentation/protected-files-after.json')
args = parser.parse_args()
before = json.loads(args.baseline.read_text())
after = {}
for top in root.iterdir():
    if top == project:
        continue
    items = [top] if not top.is_dir() else (p for p in top.rglob('*') if p.is_file() or p.is_symlink())
    for path in items:
        try:
            stat = path.lstat()
            after[str(path.relative_to(root))] = [stat.st_size, stat.st_mtime_ns, os.readlink(path) if path.is_symlink() else '']
        except OSError:
            pass
report = {
    'unchanged': sum(after.get(name) == values for name, values in before.items()),
    'changed': [name for name, values in before.items() if name in after and after[name] != values],
    'missing': [name for name in before if name not in after],
    'added': [name for name in after if name not in before],
    'verification': 'size, modification time, and symlink target; not a content hash audit',
}
destination = args.output.resolve()
if not destination.is_relative_to(project):
    parser.error('Report must stay inside this project.')
destination.write_text(json.dumps(report, ensure_ascii=False, indent=2))
print(json.dumps(report, ensure_ascii=False, indent=2))
