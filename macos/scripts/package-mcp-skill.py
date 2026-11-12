#!/usr/bin/env python3
"""Bundle the public Runbar diagnostic skill, without runtime data or credentials."""
import argparse
import io
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
REPOSITORY_ROOT = ROOT.parent
NAME = "runbar-diagnostics"
SOURCE = REPOSITORY_ROOT / "skills" / NAME
FILES = ("SKILL.md", "agents/openai.yaml", "references/setup.md")


def atomic_write(destination, data):
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=".runbar-skill-", delete=False) as stream:
        temporary = Path(stream.name)
        try:
            os.fchmod(stream.fileno(), 0o644)
            stream.write(data); stream.flush()
            os.replace(temporary, destination)
        finally:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "dist" / "skills")
    args = parser.parse_args()
    content = {}
    for name in FILES:
        file = SOURCE / name
        if not file.is_file() or file.is_symlink() or file.resolve() != file.absolute():
            raise SystemExit("Missing or redirected skill resource: " + name)
        if file.stat().st_size > 65_536:
            raise SystemExit("Skill resource exceeds 64 KiB: " + name)
        content[name] = file.read_bytes()
    text = content["SKILL.md"].decode("utf-8")
    if not text.startswith("---\n") or not re.search(r"^name: runbar-diagnostics$", text, re.M):
        raise SystemExit("Skill frontmatter must identify runbar-diagnostics.")
    version = re.search(r'^  version: "([0-9]+\.[0-9]+\.[0-9]+)"$', text, re.M)
    if version is None:
        raise SystemExit('Skill metadata.version must contain a semantic version.')
    hashes = {name: hashlib.sha256(data).hexdigest() for name, data in content.items()}
    revision = hashlib.sha256(''.join(name + '\0' + hashes[name] + '\n' for name in sorted(hashes)).encode()).hexdigest()
    manifest = {"schemaVersion": 1, "name": NAME, "version": version.group(1), "revision": revision, "files": hashes}
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name in sorted(content):
            entry = zipfile.ZipInfo(NAME + "/" + name, date_time=(2020, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.create_system = 3
            entry.external_attr = 0o100644 << 16
            archive.writestr(entry, content[name])
    args.output.mkdir(parents=True, exist_ok=True)
    destination = args.output / (NAME + ".zip")
    expanded = args.output / NAME
    if expanded.is_symlink() or expanded.resolve() == SOURCE.resolve():
        raise SystemExit('Expanded output must not redirect to the source skill.')
    with tempfile.TemporaryDirectory(dir=args.output, prefix=".runbar-skill-stage-") as staging:
        folder = Path(staging) / NAME
        for name, data in content.items():
            atomic_write(folder / name, data)
        atomic_write(folder / 'manifest.json', (json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + '\n').encode())
        backup = Path(staging) / 'previous'
        if expanded.exists():
            # Xcode creates parent directories for declared script outputs
            # before the first build. Only accept that empty, known skeleton.
            skeleton = expanded.is_dir() and all(
                item.is_dir() and not item.is_symlink() and item.relative_to(expanded).as_posix() in ('agents', 'references')
                for item in expanded.rglob('*')
            )
            if not expanded.is_dir() or (not (expanded / 'manifest.json').is_file() and not skeleton):
                raise SystemExit('Refusing to replace an unknown expanded output directory.')
            os.replace(expanded, backup)
        try:
            os.replace(folder, expanded)
        except BaseException:
            if backup.exists():
                os.replace(backup, expanded)
            raise
    atomic_write(destination, output.getvalue())
    print("Runbar diagnostic Skill: " + str(destination))


if __name__ == "__main__":
    main()
