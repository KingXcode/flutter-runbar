"""Retain complete downloadable HTTP bodies without increasing the preview buffer."""
import os
import shutil
import tempfile
import uuid
import zlib
from pathlib import Path
from urllib.parse import urlsplit


FILE_LIMIT = 64 * 1024 * 1024
SESSION_LIMIT = 512 * 1024 * 1024
DISK_RESERVE = 512 * 1024 * 1024
CHUNK = 64 * 1024


def is_download(response, url):
    disposition = response.headers.get("content-disposition", "").lower()
    if disposition.split(";", 1)[0].strip() == "attachment" or "filename" in disposition:
        return True
    mime = response.headers.get("content-type", "").split(";", 1)[0].strip().lower()
    if mime.startswith(("image/", "audio/", "video/", "font/")):
        return True
    if mime.startswith("application/") and not any(x in mime for x in ("json", "xml", "javascript", "grpc", "x-www-form-urlencoded")):
        return True
    if not mime:
        try:
            return Path(urlsplit(url).path).suffix.lower() in {".zip", ".gz", ".pdf", ".png", ".jpg", ".jpeg", ".webp"}
        except ValueError:
            return False
    return False


class DownloadStore:
    def __init__(self, directory):
        self.directory = directory
        self.used = 0
        self.active = set()

    def start(self, request, response):
        if (not self.directory or request.method.upper() == "HEAD" or response.status_code < 200
                or response.status_code in (204, 205, 206, 304) or "content-range" in response.headers
                or not is_download(response, request.pretty_url)):
            return None, None
        encoding = response.headers.get("content-encoding", "").strip().lower()
        if encoding not in ("", "identity", "gzip", "deflate"):
            return None, "不支持下载正文的压缩编码"
        try:
            length = int(response.headers.get("content-length", "-1"))
        except ValueError:
            length = -1
        if length > FILE_LIMIT:
            return None, "文件超过 64 MB 缓存上限"
        if len(self.active) >= 4 or self.used >= SESSION_LIMIT:
            return None, "文件缓存已达并发或本次运行容量上限"
        try:
            self.directory.mkdir(mode=0o700, exist_ok=True)
            if self.directory.is_symlink() or shutil.disk_usage(self.directory).free < DISK_RESERVE + CHUNK:
                return None, "文件缓存目录不可用或磁盘空间不足"
            capture = Download(self, length, encoding)
            self.active.add(capture)
            return capture, None
        except OSError:
            return None, "无法创建文件缓存"

    def close(self):
        for capture in tuple(self.active):
            capture.discard()


class Download:
    def __init__(self, store, length, encoding):
        self.store = store
        self.length = length
        self.incoming = 0
        self.size = 0
        self.decoder = zlib.decompressobj(31 if encoding == "gzip" else 15) if encoding in ("gzip", "deflate") else None
        self.file = tempfile.NamedTemporaryFile(dir=store.directory, suffix=".part", delete=False)
        self.path = Path(self.file.name)

    def discard(self):
        if self in self.store.active:
            self.store.active.remove(self)
            self.store.used -= self.size
        try:
            self.file.close()
        except OSError:
            pass
        try:
            self.path.unlink(missing_ok=True)
        except OSError:
            pass

    def write(self, data):
        self.incoming += len(data)
        if self.incoming > FILE_LIMIT:
            raise ValueError("文件超过 64 MB 缓存上限")
        if self.decoder is None:
            self.write_decoded(data)
        else:
            for start in range(0, len(data), CHUNK):
                part = data[start:start + CHUNK]
                while part:
                    self.write_decoded(self.decoder.decompress(part, CHUNK))
                    if self.decoder.unused_data:
                        raise ValueError("压缩文件包含额外数据")
                    part = self.decoder.unconsumed_tail

    def write_decoded(self, data):
        next_size = self.size + len(data)
        if next_size > FILE_LIMIT:
            raise ValueError("解压后的文件超过 64 MB 缓存上限")
        if self.store.used + len(data) > SESSION_LIMIT:
            raise ValueError("本次运行的文件缓存超过 512 MB 上限")
        if next_size // (1024 * 1024) != self.size // (1024 * 1024):
            if shutil.disk_usage(self.store.directory).free < DISK_RESERVE + len(data):
                raise ValueError("文件缓存磁盘空间不足")
        self.file.write(data)
        self.size = next_size
        self.store.used += len(data)

    def finish(self):
        if self.length >= 0 and self.incoming != self.length or self.decoder is not None and not self.decoder.eof:
            raise ValueError("文件响应未完整接收")
        if not self.size:
            self.discard()
            return None
        self.file.close()
        filename = uuid.uuid4().hex + ".body"
        final = self.store.directory / filename
        self.path.replace(final)
        self.path = final
        return {"id": filename.removesuffix(".body"), "bytes": self.size}

    def retained(self):
        self.store.active.remove(self)
