#!/usr/bin/env python3
"""Embed pinned, self-contained macOS proxy engines without executing them.

Xcode invokes this for normal builds and archives. Downloads live in .build;
end users need neither Homebrew nor a separate Python / mitmproxy installation.
Keep upstream app bundles intact so their signatures and dependency licenses
remain valid. This script never installs certificates or runs the engine.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import shutil
import subprocess
import sys
import tarfile
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent.parent
LOCK_FILE = ROOT / "scripts/proxy-engine.lock.json"
CACHE = ROOT / ".build/proxy-engine-cache"
ARCHITECTURES = ("arm64", "x86_64")
MAX_DOWNLOAD = 160 * 1024 * 1024
MAX_EXPANDED = 512 * 1024 * 1024


def run(*arguments):
    result = subprocess.run([str(item) for item in arguments], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if result.returncode:
        raise RuntimeError(f"{arguments[0]} failed:\n{result.stdout[-8000:]}")
    return result.stdout.strip()


def digest(file):
    value = hashlib.sha256()
    with file.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def atomic_json(destination, value):
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=".runbar-proxy-", delete=False) as stream:
        temporary = Path(stream.name)
        try:
            os.fchmod(stream.fileno(), 0o644)
            stream.write((json.dumps(value, indent=2, sort_keys=True) + "\n").encode())
            stream.flush()
            os.replace(temporary, destination)
        finally:
            temporary.unlink(missing_ok=True)


def archive_for(lock, architecture):
    artifact = lock["artifacts"][architecture]
    name = f"mitmproxy-{lock['version']}-macos-{architecture}.tar.gz"
    expected_url = f"https://downloads.mitmproxy.org/{lock['version']}/{name}"
    if artifact["url"] != expected_url or len(artifact["sha256"]) != 64:
        raise ValueError("Proxy engine lock must pin an official HTTPS artifact and SHA-256.")
    CACHE.mkdir(parents=True, exist_ok=True)
    archive = CACHE / name
    if archive.is_file() and archive.stat().st_size <= MAX_DOWNLOAD and digest(archive) == artifact["sha256"]:
        return archive
    with tempfile.NamedTemporaryFile(dir=CACHE, suffix=".download", delete=False) as stream:
        temporary = Path(stream.name)
    try:
        print(f"Downloading bundled proxy engine {lock['version']} ({architecture})…", flush=True)
        run("/usr/bin/curl", "--proto", "=https", "--tlsv1.2", "--fail", "--silent", "--show-error",
            "--location", "--retry", "2", "--max-time", "180", "--max-filesize", str(MAX_DOWNLOAD),
            artifact["url"], "--output", temporary)
        if temporary.stat().st_size > MAX_DOWNLOAD or digest(temporary) != artifact["sha256"]:
            raise ValueError(f"Proxy engine archive checksum mismatch ({architecture}).")
        os.chmod(temporary, 0o644)
        os.replace(temporary, archive)
    finally:
        temporary.unlink(missing_ok=True)
    return archive


def validate_members(members):
    if len(members) > 20000 or sum(item.size for item in members) > MAX_EXPANDED:
        raise ValueError("Proxy engine archive exceeds extraction limits.")
    links = {item.name.rstrip("/") for item in members if item.issym() or item.islnk()}
    for item in members:
        path = PurePosixPath(item.name)
        if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] != "mitmproxy.app":
            raise ValueError("Unexpected path in proxy engine archive.")
        if not (item.isfile() or item.isdir() or item.issym() or item.islnk()):
            raise ValueError("Unsupported entry in proxy engine archive.")
        if any(str(parent) in links for parent in path.parents):
            raise ValueError("Proxy engine archive writes through a link.")
        if item.issym() or item.islnk():
            target = item.linkname if item.islnk() else posixpath.join(str(path.parent), item.linkname)
            normalized = PurePosixPath(posixpath.normpath(target))
            if normalized.is_absolute() or ".." in normalized.parts or not normalized.parts or normalized.parts[0] != "mitmproxy.app":
                raise ValueError("Proxy engine archive link escapes the app bundle.")


def verify_engine(app, architecture):
    executable = app / "Contents/MacOS/mitmdump"
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError(f"Bundled mitmdump is missing or not executable: {architecture}")
    architectures = run("/usr/bin/lipo", "-archs", executable).split()
    if architecture not in architectures:
        raise ValueError(f"Bundled engine architecture mismatch: {architecture} vs {architectures}")
    # Validate original publisher signatures; never re-sign or weaken the engine.
    team = json.loads(LOCK_FILE.read_text())["signingTeam"]
    if len(team) != 10 or not team.isalnum():
        raise ValueError("Invalid proxy publisher team in lock file.")
    requirement = f'=anchor apple generic and certificate leaf[subject.OU] = "{team}"'
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", "--test-requirement", requirement, app)
    run("/usr/bin/codesign", "--verify", "--strict", "--test-requirement", requirement, executable)
    return executable


def prepare(lock, architecture):
    archive = archive_for(lock, architecture)
    parent = CACHE / lock["version"] / architecture
    app = parent / "mitmproxy.app"
    marker = parent / "archive.json"
    expected = {"sha256": lock["artifacts"][architecture]["sha256"], "version": lock["version"]}
    if app.is_dir() and marker.is_file():
        try:
            if json.loads(marker.read_text()) == expected:
                verify_engine(app, architecture)
                return app
        except (ValueError, OSError, RuntimeError):
            pass
    parent.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=parent.parent, prefix=f".{architecture}-") as temporary:
        staged = Path(temporary)
        with tarfile.open(archive, "r:gz") as tar:
            members = tar.getmembers()
            validate_members(members)
            # Paths, entry types, symlink targets and symlink ancestors were
            # validated above, including on Apple's bundled Python 3.9.
            tar.extractall(staged, members=members)
        verify_engine(staged / "mitmproxy.app", architecture)
        if parent.exists():
            shutil.rmtree(parent)
        parent.mkdir()
        os.replace(staged / "mitmproxy.app", app)
        atomic_json(marker, expected)
    return app


def embed(source, destination, architecture):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_symlink() or destination.parent.is_symlink():
        raise ValueError("Refusing to embed an engine through a symlink.")
    backup = destination.with_name(f".runbar-proxy-backup-{uuid.uuid4().hex}")
    with tempfile.TemporaryDirectory(dir=destination.parent, prefix=".runbar-proxy-") as temporary:
        staged = Path(temporary) / destination.name
        run("/usr/bin/ditto", "--norsrc", "--noextattr", source, staged)
        verify_engine(staged, architecture)
        if destination.exists():
            os.replace(destination, backup)
        try:
            os.replace(staged, destination)
        except BaseException:
            if backup.exists():
                os.replace(backup, destination)
            raise
        if backup.exists():
            shutil.rmtree(backup)


def build(arguments):
    architectures = sorted(set(arguments.architectures.split()))
    if not architectures or any(item not in ARCHITECTURES for item in architectures):
        raise ValueError("Only arm64 and x86_64 proxy engines are supported.")
    lock = json.loads(LOCK_FILE.read_text())
    if lock.get("schemaVersion") != 1 or lock.get("product") != "mitmproxy":
        raise ValueError("Unsupported proxy engine lock file.")
    engines = {architecture: prepare(lock, architecture) for architecture in architectures}
    if arguments.prepare_only:
        print(f"Proxy engine cache ready: {lock['version']} ({', '.join(architectures)})")
        return
    app = arguments.app.absolute()
    if app.suffix != ".app" or not (app / "Contents/Info.plist").is_file():
        raise ValueError("--app must name an existing Runbar.app build product.")
    manifest = {"schemaVersion": 1, "product": "mitmproxy", "version": lock["version"], "architectures": {}}
    for architecture, source in engines.items():
        relative = f"Helpers/RunbarProxy-{architecture}.app/Contents/MacOS/mitmdump"
        destination = app / "Contents/Helpers" / f"RunbarProxy-{architecture}.app"
        embed(source, destination, architecture)
        manifest["architectures"][architecture] = {"executable": relative, **lock["artifacts"][architecture]}
    # A derived-data folder may previously have built a different ARCHS set.
    # Remove only our own unrequested helpers, never unrelated nested code.
    for architecture in set(ARCHITECTURES) - set(architectures):
        stale = app / "Contents/Helpers" / f"RunbarProxy-{architecture}.app"
        if stale.is_dir() and not stale.is_symlink():
            shutil.rmtree(stale)
    atomic_json(app / "Contents/Resources/ProxyEngine/manifest.json", manifest)
    print(f"Embedded mitmproxy {lock['version']} ({', '.join(architectures)}), original signatures retained.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, help="Unsigned Runbar.app build product; outer signing follows this phase.")
    parser.add_argument("--architectures", default="arm64 x86_64", help="Space-separated Xcode ARCHS.")
    parser.add_argument("--prepare-only", action="store_true", help="Fetch and verify build cache only.")
    arguments = parser.parse_args()
    if sys.platform != "darwin":
        raise SystemExit("Bundled proxy engines require macOS build tools.")
    if not arguments.prepare_only and not arguments.app:
        parser.error("--app or --prepare-only is required")
    CACHE.mkdir(parents=True, exist_ok=True)
    # Xcode Run / Archive in different derived-data folders share this cache.
    with (CACHE / ".package.lock").open("a+") as stream:
        fcntl.flock(stream.fileno(), fcntl.LOCK_EX)
        build(arguments)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, tarfile.TarError) as error:
        raise SystemExit(f"Proxy engine packaging failed: {error}")
