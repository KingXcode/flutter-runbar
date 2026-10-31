#!/usr/bin/env python3
"""Publish only clean, pushed Runbar builds; never upload user data or notarize."""
import argparse
import fcntl
import hashlib
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import quote

ROOT = Path(__file__).resolve().parent.parent
REPO = 'KingXcode/flutter-runbar'


def run(*args, optional=False):
    result = subprocess.run(args, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180)
    if result.returncode and not optional:
        raise RuntimeError(result.stderr.strip()[:1600] or f'{args[0]} 操作失败')
    return result


def api(path, optional=False):
    result = run('gh', 'api', path, optional=True)
    if result.returncode:
        if optional and '(HTTP 404)' in result.stderr:
            return None
        raise RuntimeError(result.stderr.strip()[:1600] or 'GitHub API 操作失败')
    if len(result.stdout.encode()) > 2 * 1024 * 1024:
        raise RuntimeError('GitHub 返回信息过大，未继续发布。')
    return json.loads(result.stdout)


def context():
    config = (ROOT / 'project.yml').read_text()
    version = re.search(r'MARKETING_VERSION:\s*"([0-9]+\.[0-9]+\.[0-9]+)"', config).group(1)
    commit = run('git', 'rev-parse', 'HEAD', optional=True)
    if commit.returncode:
        build = int(re.search(r'CURRENT_PROJECT_VERSION:\s*"([0-9]+)"', config).group(1))
        sha = 'source-archive'
    else:
        sha = commit.stdout.strip()
        build = int(run('git', 'rev-list', '--count', 'HEAD').stdout.strip())
    return version, build, sha, f'v{version}+{build}'


def notes():
    text = (ROOT / 'CHANGELOG.md').read_text()
    match = re.search(r'^## 下一版本\s*\n(.*?)(?=^## |\Z)', text, re.M | re.S)
    value = match.group(1).strip() if match else ''
    if len(value) < 80 or len(value.encode()) > 100_000 or '### ' not in value or len(re.findall(r'^- ', value, re.M)) < 2:
        raise RuntimeError('请先在 CHANGELOG.md 的「下一版本」填写完整中文更新说明，分项写明新增、修复、用法及限制。')
    return value


def tag_commit(tag):
    value = api(f'repos/{REPO}/git/ref/tags/{quote(tag, safe="")}', optional=True)
    if not value:
        return None
    obj = value['object']
    for _ in range(3):
        if obj['type'] == 'commit':
            return obj['sha']
        if obj['type'] != 'tag':
            break
        obj = api(f'repos/{REPO}/git/tags/{obj["sha"]}')['object']
    raise RuntimeError('发布标签不能解析为确定的提交。')


def preflight():
    ctx = context()
    version, build, sha, tag = ctx
    if run('git', 'status', '--porcelain', '--untracked-files=normal').stdout.strip():
        raise RuntimeError('发布前请先提交本地改动并推送 main；仅本地打包请加 --no-publish。')
    if run('git', 'branch', '--show-current').stdout.strip() != 'main':
        raise RuntimeError('只自动发布 main；其他分支请使用 --no-publish。')
    remote = run('git', 'remote', 'get-url', 'origin').stdout.strip()
    if remote not in (f'https://github.com/{REPO}.git', f'https://github.com/{REPO}', f'git@github.com:{REPO}.git'):
        raise RuntimeError('origin 不是指定的 Runbar 仓库，未发布。')
    remote_sha = run('git', '-c', 'http.version=HTTP/1.1', 'ls-remote', 'origin', 'refs/heads/main').stdout.split()
    if not remote_sha or remote_sha[0] != sha:
        raise RuntimeError('当前提交尚未推送到远端 main，或 main 有更新；未发布。')
    repository = api(f'repos/{REPO}')
    if repository.get('private'):
        raise RuntimeError('应用内更新使用公开下载；当前仓库是私有仓库，未更改可见性或发布。')
    text = notes()
    digest = hashlib.sha256(text.encode()).hexdigest()
    latest = api(f'repos/{REPO}/releases/latest', optional=True)
    if latest and latest['tag_name'] != tag:
        old_digest = re.search(r'runbar-notes-sha256:([a-f0-9]{64})', latest.get('body') or '')
        if old_digest and old_digest.group(1) == digest:
            raise RuntimeError('更新说明与上一次发布相同，请先写清本次变化并提交推送，再发布新版本。')
        old = re.fullmatch(r'v(\d+)\.(\d+)\.(\d+)\+(\d+)', latest['tag_name'])
        if old and tuple(map(int, old.groups())) > (*map(int, version.split('.')), build):
            raise RuntimeError('GitHub 已有更高版本，不能将旧版本标记为最新。')
    target = tag_commit(tag)
    if target and target != sha:
        raise RuntimeError('相同版本标签已指向另一提交，拒绝覆盖。')
    return ctx, text, digest


def checksum(file):
    digest = hashlib.sha256()
    with file.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def publish(file, app):
    (version, build, sha, tag), text, notes_digest = preflight()
    if file.is_symlink():
        raise RuntimeError('安装包不能是符号链接。')
    file = file.resolve(); app = app.resolve()
    if file.parent != (ROOT / 'dist').resolve() or not file.is_file():
        raise RuntimeError('只发布 dist 中明确的安装包文件。')
    if not re.fullmatch(rf'Runbar-{re.escape(version)}-{build}-macOS[0-9.]+-(?:universal|arm64|x86_64)(?:-(?:signed|adhoc))?\.(?:zip|dmg)', file.name):
        raise RuntimeError('安装包名称与当前版本不匹配。')
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if (info.get('CFBundleIdentifier'), info.get('CFBundleShortVersionString'), str(info.get('CFBundleVersion')), info.get('RunbarSourceRevision')) != ('dev.kingxcode.flutter-runbar', version, str(build), sha):
        raise RuntimeError('安装包版本或源码提交与当前 main 不匹配。')
    run('codesign', '--verify', '--strict', str(app))
    architectures = set(run('lipo', '-archs', str(app / 'Contents/MacOS/Runbar')).stdout.split())
    if architectures != {'arm64', 'x86_64'} or '-universal' not in file.name:
        raise RuntimeError('发布包必须同时包含 Apple Silicon 与 Intel 架构。')
    digest = checksum(file)
    sums = file.with_name(file.name + '.sha256')
    sums.write_text(f'{digest}  {file.name}\n')
    body = f'# Runbar {version}（{build}）\n\n{text}\n\n### 发布信息\n- 系统要求：macOS {info["LSMinimumSystemVersion"]} 或更新版本。\n- 安装包支持 Apple Silicon 与 Intel。下载文件与 SHA-256 校验文件见附件。\n- 源码提交：`{sha}`。\n- 未进行 Apple 公证，不上传到 Apple；只发布 Runbar 安装包，不包含本机项目、配置、日志或网络记录。\n\n<!-- runbar-notes-sha256:{notes_digest} -->\n'
    existing = api(f'repos/{REPO}/releases/tags/{quote(tag, safe="")}', optional=True)
    if existing is None:
        notes_file = ROOT / '.build' / 'release-notes.md'
        notes_file.parent.mkdir(parents=True, exist_ok=True); notes_file.write_text(body)
        run('gh', 'release', 'create', tag, '--repo', REPO, '--target', sha, '--draft', '--title', f'Runbar {version}（{build}）', '--notes-file', str(notes_file))
        existing = api(f'repos/{REPO}/releases/tags/{quote(tag, safe="")}')
    if existing.get('prerelease'):
        raise RuntimeError('相同标签是预发布版本，未自动更改其类型。')
    if existing['draft'] and existing.get('body', '').strip() != body.strip():
        raise RuntimeError('已有草稿的更新说明与本次不同，请先检查草稿，未自动覆盖或发布。')
    # GitHub may defer creation of a new tag until a draft is published.
    target = tag_commit(tag)
    if target != sha and not (target is None and existing['draft'] and existing.get('target_commitish') == sha):
        raise RuntimeError('发布标签与本次源码不匹配，未上传安装包。')
    assets = {asset['name']: asset for asset in existing['assets']}
    if file.name in assets:
        if existing['draft'] and assets[file.name].get('digest') != 'sha256:' + digest:
            raise RuntimeError('草稿中的同名包与本次不同，拒绝覆盖；请先检查该草稿。')
        print('同一提交的安装包已经存在，保留原下载文件，不覆盖发布附件。')
        if sums.name not in assets:
            if assets[file.name].get('digest') != 'sha256:' + digest:
                raise RuntimeError('已有安装包与本次校验值不同，不能补传本次校验文件。')
            run('gh', 'release', 'upload', tag, str(sums), '--repo', REPO)
    else:
        if sums.name in assets:
            raise RuntimeError('已有同名校验文件但缺少安装包，请检查该发布，未覆盖附件。')
        run('gh', 'release', 'upload', tag, str(file), '--repo', REPO)
        run('gh', 'release', 'upload', tag, str(sums), '--repo', REPO)
    refreshed = api(f'repos/{REPO}/releases/tags/{quote(tag, safe="")}')
    uploaded = {asset['name']: asset for asset in refreshed['assets']}
    if file.name not in uploaded or sums.name not in uploaded:
        raise RuntimeError('附件尚未上传完整，草稿未发布。')
    if existing['draft']:
        if uploaded[file.name].get('digest') != 'sha256:' + digest:
            raise RuntimeError('GitHub 附件 SHA-256 与本次文件不匹配，草稿未发布。')
        run('gh', 'release', 'edit', tag, '--repo', REPO, '--draft=false', '--latest')
    if tag_commit(tag) != sha:
        raise RuntimeError('发布后的标签未指向本次提交，请检查 GitHub Release。')
    print(f'GitHub Release：https://github.com/{REPO}/releases/tag/{quote(tag, safe="")}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['context', 'preflight', 'publish'])
    parser.add_argument('--artifact', type=Path); parser.add_argument('--app', type=Path)
    args = parser.parse_args()
    if args.action == 'context':
        version, build, sha, tag = context(); print(f'{version}\t{build}\t{sha}\t{tag}')
    elif args.action == 'preflight':
        ctx, _, _ = preflight(); print(f'发布检查通过：{ctx[3]}')
    else:
        if not args.artifact or not args.app:
            parser.error('publish 需要 --artifact 和 --app')
        lock = ROOT / '.build/release-publish.lock'; lock.parent.mkdir(exist_ok=True)
        with lock.open('w') as stream:
            fcntl.flock(stream, fcntl.LOCK_EX)
            publish(args.artifact, args.app)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, subprocess.TimeoutExpired, ValueError) as error:
        sys.exit('Release 发布失败：' + str(error))
