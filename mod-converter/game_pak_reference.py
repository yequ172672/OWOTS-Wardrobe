"""Read original OWOTS game PAK resources without installing Blender or writing the game.

Uses the existing verified RE Asset Library TOC/chunk reader. It resolves exact
path hashes, respects numbered patch priority, and materializes requested assets
in a private temporary cache. Custom MOD envelopes are handled by the MOD input
reader, never by this reference provider.
"""
from pathlib import Path
import hashlib
import re
import tempfile

from owots_vendor.hashing.mmh3.pymmh3 import hashUTF16
from owots_vendor.pak.file_re_pak import PakFile
from owots_vendor.pak.entry_reader import readPakEntryData

DEFAULT_VERSIONS = {'.pfb': '18', '.user': '3', '.mesh': '260209350', '.mdf2': '51',
                    '.tex': '251111100', '.chain2': '17', '.fbxskel': '7', '.motbank': '4'}


def pak_hash(path):
    path = path.replace('\\', '/')
    return (hashUTF16(path.lower()) << 32) | hashUTF16(path.upper())


class GamePakReference:
    def __init__(self, game_root, file_list, report=None, *, max_asset_bytes=512 * 1024 * 1024):
        self.root = Path(game_root).resolve(strict=True)
        self.report = report
        self.max_asset_bytes = max_asset_bytes
        self._cache = tempfile.TemporaryDirectory(prefix='owots-original-reference-')
        self.cache_root = Path(self._cache.name).resolve()
        self.entries = {}
        self.archives = {}
        self.paths = {}
        self.materialized = {}
        self.source_stats = {}
        self._index_paths(Path(file_list))
        self._index_archives()

    def _info(self, code, message, **details):
        if self.report:
            self.report.info(code, message, **details)

    def _index_paths(self, file_list):
        with file_list.open(encoding='utf-8-sig') as stream:
            for raw in stream:
                path = raw.strip().replace('\\', '/')
                if not path.lower().startswith('natives/stm/'):
                    continue
                relative = path[len('natives/stm/'):]
                streaming = relative.lower().startswith('streaming/')
                if streaming:
                    relative = relative[len('streaming/'):]
                logical, dot, version = relative.rpartition('.')
                if not dot or not version.isdigit():
                    continue
                self.paths.setdefault((logical.casefold(), streaming), set()).add((path, version))

    def _index_archives(self):
        base = [path for path in self.root.glob('re_chunk_*.pak') if path.is_file()]
        dlc = [path for path in self.root.glob('*/re_dlc*.pak') if path.is_file()]
        def order(path):
            match = re.search(r'\.patch_(\d+)\.pak$', path.name, re.I)
            return (1 if match else 0, int(match[1]) if match else 0, path.name.casefold())
        archives = sorted(base, key=order) + sorted(dlc, key=lambda path: path.as_posix().casefold())
        if not archives:
            raise ValueError('原始游戏目录未找到 re_chunk_*.pak；请选择游戏目录或已解包资源目录')
        for path in archives:
            if path.is_symlink() or not path.resolve().is_relative_to(self.root):
                raise ValueError('Reference PAK escaped the selected game directory')
            if path.stat().st_size == 0:
                continue
            pak = PakFile()
            with path.open('rb') as stream:
                pak.readTOC(stream)
            # Standard user-made PAKs carry a self manifest. They are MOD
            # inputs, never an authoritative copy of original game resources.
            manifest_hash = pak_hash('__MANIFEST/MANIFEST.TXT')
            if any(((entry.hashNameLower << 32) | entry.hashNameUpper) == manifest_hash
                   for entry in pak.toc.entryList):
                self._info('GAME_MOD_PAK_SKIPPED', '参考目录内的 MOD PAK 已排除，请使用未修改的原始游戏资源', path=str(path))
                continue
            own_hashes = set()
            for entry in pak.toc.entryList:
                key = (entry.hashNameLower << 32) | entry.hashNameUpper
                if key in own_hashes:
                    raise ValueError('Duplicate hashes in original PAK: ' + path.name)
                own_hashes.add(key)
                self.entries[key] = (path, entry)
            self.archives[path] = pak.chunkTable
            self.source_stats[path] = (path.stat().st_size, path.stat().st_mtime_ns)
            self._info('GAME_PAK_INDEX', '已只读索引原始游戏 PAK', path=str(path), entries=len(own_hashes))

    def _resolve(self, logical, streaming):
        logical = str(logical).replace('\\', '/')
        if logical.startswith('/') or ':' in logical or any(part in ('', '.', '..') for part in logical.split('/')):
            raise ValueError('Invalid logical game resource path')
        candidates = set(self.paths.get((logical.casefold(), bool(streaming)), ()))
        # Some official lists omit streaming paths. A known exact format version
        # is admitted only when its exact hash exists in the actual game PAKs.
        version = DEFAULT_VERSIONS.get(Path(logical).suffix.casefold())
        if version:
            candidates.add(('natives/stm/' + ('streaming/' if streaming else '') + logical + '.' + version, version))
        matches = {}
        for physical, version in candidates:
            key = pak_hash(physical)
            if key in self.entries:
                matches[(key, version)] = (physical, version, self.entries[key])
        if len(matches) > 1:
            raise ValueError('多个实际游戏资源版本匹配，不能猜选：' + logical)
        return next(iter(matches.values()), None)

    def contains(self, logical, streaming=False):
        return self._resolve(logical, streaming) is not None

    def fetch(self, logical, streaming=False):
        """Return (read-only-source-cache Path, numeric version), or None if absent."""
        key = (logical.casefold(), bool(streaming))
        if key in self.materialized:
            return self.materialized[key]
        resolved = self._resolve(logical, streaming)
        if resolved is None:
            return None
        physical, version, (archive, entry) = resolved
        if (archive.stat().st_size, archive.stat().st_mtime_ns) != self.source_stats[archive]:
            raise ValueError('原始游戏 PAK 在转换期间发生变化，请重新分析')
        if entry.decompressedSize < 0 or entry.decompressedSize > self.max_asset_bytes:
            raise ValueError('参考资源大小超出单文件读取上限：' + physical)
        destination = self.cache_root / physical.lower()
        destination.parent.mkdir(parents=True, exist_ok=True)
        if not destination.resolve().is_relative_to(self.cache_root):
            raise ValueError('Reference cache path escaped')
        with archive.open('rb') as stream:
            data = readPakEntryData(entry, stream, self.archives[archive])
        if len(data) != entry.decompressedSize:
            raise ValueError('原始资源解包长度不匹配：' + physical)
        with destination.open('xb') as stream:
            stream.write(data)
        self.materialized[key] = (destination, version)
        self._info('GAME_RESOURCE_VERIFIED', '已从原始游戏 PAK 验证并读取依赖', path=physical,
                   bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
        return destination, version

    def close(self):
        self._cache.cleanup()

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.close()
