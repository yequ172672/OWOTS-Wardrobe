"""Bounded asset-only extraction; source descriptions and executable contents stay unread."""
from __future__ import annotations

import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import tempfile
import zipfile
from dataclasses import dataclass
from typing import Callable

MAX_FILE = 512 * 1024 * 1024
MAX_TOTAL = 8 * 1024 * 1024 * 1024
MAX_FILES = 100_000
ASSET = re.compile(r"\.(?:mesh|mdf2|tex|pfb|user|chain2|fbxskel|mmi|mpi|jcns|motbank|motlist|mmtr|gpuc|clsp|sfur|jmap|jntexprgraph)\.\d+$", re.I)
CONTAINERS = {'.zip', '.rar', '.7z', '.pak'}


class InputError(ValueError):
    def __init__(self, message: str, code: str = 'INPUT_UNSUPPORTED'):
        super().__init__(message)
        self.code = code


def member_path(name: str) -> str:
    name = name.replace('\\', '/')
    if not name or name.startswith('/') or any(ord(c) < 32 for c in name) or ':' in name:
        raise InputError('压缩包包含不安全的文件路径：' + name, 'ARCHIVE_PATH_UNSAFE')
    parts = name.rstrip('/').split('/')
    if any(part in ('', '.', '..') or part.endswith((' ', '.')) for part in parts):
        raise InputError('压缩包包含不安全的文件路径：' + name, 'ARCHIVE_PATH_UNSAFE')
    if any(re.fullmatch(r'(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?', part, re.I) for part in parts):
        raise InputError('压缩包包含 Windows 保留路径：' + name, 'ARCHIVE_PATH_UNSAFE')
    return PurePosixPath(*parts).as_posix()


@dataclass(frozen=True)
class Member:
    name: str
    size: int
    directory: bool = False


class ExpandedInput:
    """Owns extraction lifetime; omitted entries are inventory only, never executed/read."""
    def __init__(self, source: Path, cancelled: Callable[[], bool] = lambda: False):
        self.source = source.resolve(strict=True)
        self.root = self.source
        self.omitted: list[str] = []
        self._temporary: tempfile.TemporaryDirectory | None = None
        self.cancelled = cancelled
        self._written = 0
        self._members: dict[str, Member] = {}

    def check_cancel(self):
        if self.cancelled():
            raise InputError('已取消', 'CANCELLED')

    def __enter__(self):
        try:
            self.open()
            return self
        except BaseException:
            self.close()
            raise

    def __exit__(self, *args):
        self.close()

    def close(self):
        if self._temporary:
            self._temporary.cleanup()
            self._temporary = None

    def open(self):
        self.check_cancel()
        if self.source.is_dir() or self.source.suffix.casefold() == '.pak':
            return
        suffix = self.source.suffix.casefold()
        if suffix not in {'.zip', '.rar', '.7z'}:
            raise InputError('请选择 Mod 文件夹、ZIP、RAR、7z 或 PAK 文件。')
        self._temporary = tempfile.TemporaryDirectory(prefix='owots-mod-input-')
        self.root = Path(self._temporary.name).resolve()
        try:
            if suffix == '.zip': self._zip()
            elif suffix == '.rar': self._rar()
            else: self._sevenzip()
        except InputError:
            raise
        except ImportError as exc:
            raise InputError('缺少压缩包支持，请使用完整发行版或先解压 Mod。', 'ARCHIVE_SUPPORT_MISSING') from exc
        except Exception as exc:
            raise InputError('无法解压此文件：' + str(exc), 'ARCHIVE_READ_FAILED') from exc

    def _select(self, members: list[Member]) -> list[str]:
        if len(members) > MAX_FILES or sum(m.size for m in members) > MAX_TOTAL:
            raise InputError('压缩包解压后超过允许的大小。', 'ARCHIVE_LIMIT')
        seen = set()
        selected = []
        for member in members:
            self.check_cancel()
            normalized = member_path(member.name)
            if normalized.casefold() in seen:
                raise InputError('压缩包内存在重名文件：' + normalized, 'ARCHIVE_DUPLICATE')
            seen.add(normalized.casefold())
            if member.size < 0 or member.size > MAX_FILE:
                raise InputError('压缩包中的文件超过允许的大小：' + normalized, 'ARCHIVE_LIMIT')
            if member.directory:
                continue
            self._members[normalized] = member
            # Nested containers are expanded by the batch planner, with a depth limit.
            if ASSET.search(normalized) or Path(normalized).suffix.casefold() in CONTAINERS:
                selected.append(member.name)
            else:
                self.omitted.append(normalized)
        return selected

    def _destination(self, name: str) -> Path:
        normalized = member_path(name)
        if normalized not in self._members:
            raise InputError('压缩包输出不在已验证的目录中。', 'ARCHIVE_PATH_UNSAFE')
        path = (self.root / normalized).resolve()
        if not path.is_relative_to(self.root):
            raise InputError('压缩包输出越界。', 'ARCHIVE_PATH_UNSAFE')
        path.parent.mkdir(parents=True, exist_ok=True)
        return path

    def _copy(self, source, name: str):
        expected = self._members[member_path(name)].size
        count = 0
        with self._destination(name).open('xb') as target:
            while chunk := source.read(1024 * 1024):
                self.check_cancel()
                count += len(chunk)
                self._written += len(chunk)
                if count > expected or count > MAX_FILE or self._written > MAX_TOTAL:
                    raise InputError('压缩包数据超过声明的大小。', 'ARCHIVE_LIMIT')
                target.write(chunk)
        if count != expected:
            raise InputError('压缩包中的文件不完整：' + name, 'ARCHIVE_TRUNCATED')

    def _zip(self):
        with zipfile.ZipFile(self.source) as archive:
            infos = archive.infolist()
            if any(stat.S_ISLNK(info.external_attr >> 16) for info in infos):
                raise InputError('压缩包中包含链接，无法作为独立 Mod 解压。', 'ARCHIVE_LINK')
            if any(info.flag_bits & 1 for info in infos):
                raise InputError('请先解开压缩包的密码保护。', 'ARCHIVE_PASSWORD')
            selected = self._select([Member(i.filename, i.file_size, i.is_dir()) for i in infos])
            for name in selected:
                with archive.open(name) as source:
                    self._copy(source, name)

    def _rar(self):
        import rarfile
        reader = Path(__file__).resolve().parent/'runtime/7zip/7z.exe'
        if not reader.is_file():
            raise InputError('解压组件缺失，请重新解压转换器。', 'ARCHIVE_READER_MISSING')
        # Solid RAR is common in mods and unsupported by Windows' libarchive.
        # Use the bundled reader only, streaming regular selected members.
        rarfile.SEVENZIP_TOOL = str(reader)
        rarfile.tool_setup(unrar=False, unar=False, sevenzip=True, sevenzip2=False, bsdtar=False, force=True)
        with rarfile.RarFile(self.source) as archive:
            if archive.needs_password():
                raise InputError('请先解开压缩包的密码保护。', 'ARCHIVE_PASSWORD')
            infos = archive.infolist()
            if any(not (i.is_file() or i.is_dir()) or i.is_symlink() for i in infos):
                raise InputError('压缩包中包含链接或特殊文件。', 'ARCHIVE_LINK')
            selected = self._select([Member(i.filename, i.file_size, i.is_dir()) for i in infos])
            for name in selected:
                with archive.open(name) as source:
                    self._copy(source, name)

    def _sevenzip(self):
        import py7zr
        from py7zr.io import Py7zIO, WriterFactory
        owner = self
        opened = []

        class Sink(Py7zIO):
            def __init__(self, name):
                self.expected = owner._members[member_path(name)].size
                self.count = 0
                self.file = owner._destination(name).open('x+b')
                opened.append(self)
            def write(self, data):
                owner.check_cancel()
                if self.file.tell() != self.count:
                    raise InputError('解压程序请求了覆盖写入。', 'ARCHIVE_READ_FAILED')
                self.count += len(data)
                owner._written += len(data)
                if self.count > self.expected or owner._written > MAX_TOTAL:
                    raise InputError('压缩包数据超过声明的大小。', 'ARCHIVE_LIMIT')
                return self.file.write(data)
            def read(self, size=None):
                return self.file.read(-1 if size is None else size)
            def seek(self, offset, whence=0):
                # The library rewinds after CRC verification. Reads are bounded to
                # our own output; writes remain append-only even after a seek.
                position = offset + (self.file.tell() if whence == 1 else self.count if whence == 2 else 0)
                if whence not in (0, 1, 2) or not 0 <= position <= self.count:
                    raise InputError('解压程序请求了越界访问。', 'ARCHIVE_READ_FAILED')
                return self.file.seek(position)
            def flush(self):
                if not self.file.closed: self.file.flush()
            def size(self): return self.count
            def close(self):
                if not self.file.closed: self.file.close()

        class Factory(WriterFactory):
            def create(self, filename): return Sink(filename)

        try:
            with py7zr.SevenZipFile(self.source, 'r') as archive:
                if archive.needs_password():
                    raise InputError('请先解开压缩包的密码保护。', 'ARCHIVE_PASSWORD')
                infos = archive.list()
                if any(i.is_symlink or not (i.is_file or i.is_directory) for i in infos):
                    raise InputError('压缩包中包含链接或特殊文件。', 'ARCHIVE_LINK')
                selected = self._select([Member(i.filename, i.uncompressed, i.is_directory) for i in infos])
                if selected:
                    archive.extract(targets=selected, factory=Factory())
            if any(sink.count != sink.expected for sink in opened):
                raise InputError('压缩包中的文件不完整。', 'ARCHIVE_TRUNCATED')
        finally:
            for sink in opened: sink.close()
