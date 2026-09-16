#!/usr/bin/env python3
"""OWOTS normal-MOD to wardrobe-MOD converter.

This module intentionally uses only the Python standard library.  It is the
portable command line front end shipped to players; the optional AppearanceRsz
worker is used for every structured resource rewrite.  The converter never
writes the input MOD or the game installation.  A failed conversion publishes
only a diagnostic report and never a partial manifest.

The input side accepts an already extracted loose MOD directory and ordinary
KPKA 2/4 PAK files.  A protected WOTSPK01/WOTSPV03 envelope is diagnosed and
stopped before any indexed entries are treated as game resources.  Hashes in a
normal PAK are resolved only through a supplied hash map/file list; a file
type guess can never turn an unresolved hash into a successful conversion.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import dataclasses
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import textwrap
import zlib
from typing import Any, Iterable, Iterator, Mapping, Sequence

try:
    # Kept optional so the single-file source CLI still diagnoses a missing
    # provider cleanly; the release build includes game_pak_reference.py.
    from game_pak_reference import GamePakReference  # type: ignore
except ImportError:  # pragma: no cover - exercised by minimal source copies
    GamePakReference = None  # type: ignore[assignment,misc]


TOOL_VERSION = "0.1.0"
SCHEMA_VERSION = 2
KNOWN_EXTENSIONS = (
    ".pfb", ".user", ".mdf2", ".mesh", ".tex", ".mmi", ".mpi",
    ".jcns", ".chain2", ".motbank", ".motlist", ".fbxskel",
)
MAX_PAK_ENTRY_BYTES = 512 * 1024 * 1024
MAX_PAK_TOTAL_BYTES = 8 * 1024 * 1024 * 1024
STRUCTURED_EXTENSIONS = {".pfb", ".user", ".mdf2"}
OWOTS_RESOURCE_VERSIONS = {".pfb": "18", ".user": "3", ".mdf2": "51",
                           ".mesh": "260209350", ".tex": "251111100",
                           ".fbxskel": "7"}
TEXTURE_EXTENSIONS = {".tex"}
PARTS = {
    "body": ("BODY", "BODY_SUB", "HEAD", "HAIR"),
    "cloak": ("CLOAK",),
    "gauntlet": ("GAUNTLET",),
    "weapon": ("WEAPON", "SHEATH", "WEAPON_SUB", "SHEATH_SUB", "BOW"),
}
ALL_PARTS = {part for parts in PARTS.values() for part in parts}
PART_CATEGORY = {part: category for category, parts in PARTS.items() for part in parts}
SKIPPED_SUFFIXES = {
    ".dll", ".lua", ".luac", ".exe", ".bat", ".cmd", ".ps1", ".pyc",
    ".pdb", ".log", ".ini", ".json", ".txt", ".md", ".zip", ".rar",
}
SCRIPTS_OR_PLUGINS = {".lua", ".luac", ".dll", ".asi", ".pyd", ".exe"}
CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")
MOD_ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
VERSIONED_RE = re.compile(r"^(?P<logical>.+)\.(?P<version>[0-9]+)$")

# The wardrobe runtime can own a normal actor rig when the source asset is a
# complete translation-only 93-joint FBXSKEL.  This is deliberately a narrow
# contract: an expanded actor (for example Scarlet's 264-joint rig) also
# needs motion banks, component additions and other scripted behaviour which a
# static manifest cannot express.
FBXSKEL_MAGIC = 0x6E6C6B73
FBXSKEL_VERSION = 7
FBXSKEL_BONE_STRUCT_SIZE = 64
ACTOR_SKELETON_BONE_COUNT = 93
ACTOR_SKELETON_BASELINE_RESOURCE = (
    "art/model/character/ch0/ch001_00/90/ch001_00_90.fbxskel"
)
ACTOR_SKELETON_FLOAT_TOLERANCE = 1e-6


def bundled_file_list() -> Path | None:
    """Find the read-only OWOTS hash list in source and frozen layouts.

    A release keeps the large list beside the single-file EXE.  Source mode
    keeps it in ``runtime/``.  Searching the executable directory first also
    lets players replace the list for a matching game build without changing
    the converter binary.
    """
    candidates: list[Path] = []
    try:
        candidates.append(Path(sys.executable).resolve().parent / "OWOTS_STM_Release.list")
    except OSError:
        pass
    module_root = Path(__file__).resolve().parent
    candidates += [module_root / "OWOTS_STM_Release.list", module_root / "runtime" / "OWOTS_STM_Release.list"]
    meipass = getattr(sys, "_MEIPASS", None)
    if meipass:
        base = Path(meipass)
        candidates += [base / "OWOTS_STM_Release.list", base / "runtime" / "OWOTS_STM_Release.list"]
    seen: set[str] = set()
    for candidate in candidates:
        marker = str(candidate).casefold()
        if marker in seen:
            continue
        seen.add(marker)
        if candidate.is_file():
            return candidate
    return None


class ConversionError(RuntimeError):
    """A user-actionable conversion failure."""


@dataclasses.dataclass
class Issue:
    severity: str  # info, warning, error
    code: str
    message: str
    path: str | None = None
    details: dict[str, Any] = dataclasses.field(default_factory=dict)

    def as_dict(self) -> dict[str, Any]:
        data = {"severity": self.severity, "code": self.code, "message": self.message}
        if self.path:
            data["path"] = self.path
        if self.details:
            data["details"] = self.details
        return data


class Report:
    def __init__(self, command: str, source: Path):
        self.command = command
        self.source = str(source)
        self.issues: list[Issue] = []
        self.stats: dict[str, Any] = {}
        self.status = "pending"

    def add(self, severity: str, code: str, message: str, path: str | None = None,
            **details: Any) -> None:
        self.issues.append(Issue(severity, code, message, path, details))

    def info(self, code: str, message: str, path: str | None = None, **details: Any) -> None:
        self.add("info", code, message, path, **details)

    def warn(self, code: str, message: str, path: str | None = None, **details: Any) -> None:
        self.add("warning", code, message, path, **details)

    def error(self, code: str, message: str, path: str | None = None, **details: Any) -> None:
        self.add("error", code, message, path, **details)

    @property
    def errors(self) -> list[Issue]:
        return [issue for issue in self.issues if issue.severity == "error"]

    def as_dict(self) -> dict[str, Any]:
        return {
            "tool": "owots-mod-converter",
            "toolVersion": TOOL_VERSION,
            "command": self.command,
            "source": self.source,
            "status": self.status,
            "stats": self.stats,
            "issues": [issue.as_dict() for issue in self.issues],
        }


def _casefold(path: str) -> str:
    return path.casefold()


def logical_path(value: str) -> str:
    """Validate an engine logical path and return forward-slash form."""
    if not isinstance(value, str):
        raise ValueError("resource path must be text")
    value = value.replace("\\", "/")
    if not value or value.startswith("/") or ":" in value or "@" in value:
        raise ValueError(f"unsafe resource path: {value!r}")
    if CONTROL_RE.search(value) or any(p in ("", ".", "..") for p in value.split("/")):
        raise ValueError(f"unsafe resource path: {value!r}")
    return PurePosixPath(value).as_posix()


def strip_native_prefix(value: str) -> str:
    value = value.replace("\\", "/").lstrip("./")
    lower = value.casefold()
    # Keep a leading ``streaming/`` marker after removing natives/stm.  The
    # previous implementation removed both prefixes and consequently treated
    # the full-resolution companion as a duplicate base texture.
    if lower.startswith("natives/stm/"):
        return value[len("natives/stm/"):]
    if lower.startswith("streaming/"):
        return value
    return value


def split_versioned(value: str) -> tuple[str, str, bool]:
    """Return logical path, numeric file version, streaming flag.

    A suffix is accepted only when the preceding suffix is a known resource
    extension.  Thus ``readme.2026`` is never accidentally considered a game
    resource, while ``mesh.260209350`` is.
    """
    raw = strip_native_prefix(value)
    streaming = raw.casefold().startswith("streaming/")
    if streaming:
        raw = raw[len("streaming/"):]
    match = VERSIONED_RE.match(raw)
    if not match or not match.group("version"):
        raise ValueError(f"resource has no numeric version suffix: {value}")
    logical = logical_path(match.group("logical"))
    extension = PurePosixPath(logical).suffix.casefold()
    if extension not in KNOWN_EXTENSIONS:
        raise ValueError(f"unsupported or unversioned resource: {value}")
    return logical, match.group("version"), streaming


def validate_hash_path(value: str) -> str:
    """Validate a hashed game path without restricting its file extension.

    The official file list covers shaders, VFX and other engine resources in
    addition to the appearance formats understood by this converter.  Those
    paths are valid hash keys even though they are not publishable wardrobe
    assets, so this check deliberately enforces only traversal/version safety.
    """
    normalized = value.strip().replace("\\", "/")
    if not normalized.casefold().startswith("natives/stm/"):
        raise ValueError("path must begin with natives/stm/")
    relative = normalized[len("natives/stm/"):]
    if relative.casefold().startswith("streaming/"):
        relative = relative[len("streaming/"):]
    match = VERSIONED_RE.match(relative)
    if not match or not match.group("version"):
        raise ValueError("path must have a numeric version suffix")
    logical_path(match.group("logical"))
    return normalized


def physical_for(logical: str, version: str, streaming: bool = False) -> str:
    logical_path(logical)
    return ("natives/stm/" + ("streaming/" if streaming else "") + logical + "." + version)


@dataclasses.dataclass(frozen=True)
class Asset:
    logical: str
    version: str
    streaming: bool
    path: Path
    origin: str  # mod or game
    size: int

    @property
    def key(self) -> str:
        return self.logical.casefold()

    @property
    def variant_key(self) -> tuple[str, bool]:
        return self.key, self.streaming

    @property
    def extension(self) -> str:
        return PurePosixPath(self.logical).suffix.casefold()

    @property
    def sha256(self) -> str:
        digest = hashlib.sha256()
        with self.path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        return digest.hexdigest()


@dataclasses.dataclass(frozen=True)
class FbxSkelInfo:
    """Decoded, validated FBXSKEL v7 data needed by the actor-rig contract.

    The converter intentionally keeps the complete source transforms even
    though the wardrobe manifest only publishes bind positions.  Parent/name
    order and rotation/scale are compared with the stock actor baseline;
    positions remain source-owned so the runtime can apply a measured
    translation-only rig.  Keeping this parser here also means the portable
    EXE does not need to import a game/editor checkout or execute MOD Lua.
    """

    version: int
    magic: int
    data_offset: int
    lookup_offset: int
    bone_count: int
    names: tuple[str, ...]
    parent_indices: tuple[int, ...]
    symmetry_indices: tuple[int, ...]
    rotations: tuple[tuple[float, float, float, float], ...]
    positions: tuple[tuple[float, float, float], ...]
    scales: tuple[tuple[float, float, float], ...]
    segment_scaling: tuple[bool, ...]
    lookup: tuple[tuple[int, int], ...]
    sha256: str

    def bind_positions(self) -> dict[str, list[float]]:
        """Return finite positions in exact joint order for manifest JSON."""
        return {name: list(position) for name, position in zip(self.names, self.positions)}


def _decode_fbxskel_name(payload: bytes, offset: int) -> str:
    """Decode one null-terminated UTF-16LE name without unbounded scanning."""
    if offset < 0 or offset >= len(payload) or offset & 1:
        raise ValueError("FBXSKEL name offset is outside the UTF-16 string table")
    cursor = offset
    while cursor + 1 < len(payload):
        if payload[cursor:cursor + 2] == b"\x00\x00":
            try:
                value = payload[offset:cursor].decode("utf-16-le")
            except UnicodeDecodeError as error:
                raise ValueError("FBXSKEL joint name is not valid UTF-16LE") from error
            if not value or CONTROL_RE.search(value):
                raise ValueError("FBXSKEL joint name is empty or contains control characters")
            return value
        cursor += 2
    raise ValueError("FBXSKEL joint name is unterminated")


def parse_fbxskel(payload: bytes, source: str = "FBXSKEL") -> FbxSkelInfo:
    """Strictly decode an OWOTS FBXSKEL v7 resource.

    The file layout is the stable RE Engine table used by ``FbxSkelFile``:
    48-byte header, 64-byte reference-bone records, an 8-byte sorted lookup
    table, then the UTF-16 string table.  All offsets and indices are checked
    before reading.  This is a structural parser only; it never resolves a
    resource or runs code from the source MOD.
    """
    if not isinstance(payload, (bytes, bytearray, memoryview)):
        raise ValueError(f"{source}: FBXSKEL payload must be bytes")
    payload = bytes(payload)
    if len(payload) < 48:
        raise ValueError(f"{source}: FBXSKEL header is truncated")
    version, magic = struct.unpack_from("<II", payload, 0)
    data_offset, lookup_offset = struct.unpack_from("<QQ", payload, 16)
    bone_count = struct.unpack_from("<I", payload, 32)[0]
    if magic != FBXSKEL_MAGIC:
        raise ValueError(f"{source}: unexpected FBXSKEL magic: {magic:#x}")
    if version != FBXSKEL_VERSION:
        raise ValueError(f"{source}: unsupported FBXSKEL version: {version}")
    if bone_count <= 0 or bone_count > 4096:
        raise ValueError(f"{source}: FBXSKEL bone count is outside the safe bound: {bone_count}")
    table_end = data_offset + bone_count * FBXSKEL_BONE_STRUCT_SIZE
    lookup_end = lookup_offset + bone_count * 8
    if (data_offset < 48 or lookup_offset < table_end or table_end > len(payload) or
            lookup_end > len(payload)):
        raise ValueError(f"{source}: FBXSKEL bone/lookup table exceeds file boundary")
    if data_offset & 7 or lookup_offset & 7:
        raise ValueError(f"{source}: FBXSKEL table offsets are not aligned")

    names: list[str] = []
    parents: list[int] = []
    symmetries: list[int] = []
    rotations: list[tuple[float, float, float, float]] = []
    positions: list[tuple[float, float, float]] = []
    scales: list[tuple[float, float, float]] = []
    segments: list[bool] = []
    for index in range(bone_count):
        entry = data_offset + index * FBXSKEL_BONE_STRUCT_SIZE
        name_offset = struct.unpack_from("<Q", payload, entry)[0]
        if name_offset < lookup_end or name_offset >= len(payload):
            raise ValueError(f"{source}: FBXSKEL name offset out of range at bone {index}")
        names.append(_decode_fbxskel_name(payload, name_offset))
        parent = struct.unpack_from("<h", payload, entry + 12)[0]
        symmetry = struct.unpack_from("<h", payload, entry + 14)[0]
        if parent < -1 or parent >= index:
            raise ValueError(f"{source}: invalid FBXSKEL parent index at bone {index}: {parent}")
        # A stock FBXSKEL uses -1 for a bone without a symmetry partner;
        # otherwise the field is a zero-based bone index.
        if symmetry < -1 or symmetry >= bone_count:
            raise ValueError(f"{source}: invalid FBXSKEL symmetry index at bone {index}: {symmetry}")
        rotation = struct.unpack_from("<4f", payload, entry + 16)
        position = struct.unpack_from("<3f", payload, entry + 32)
        scale = struct.unpack_from("<3f", payload, entry + 44)
        if not all(math.isfinite(value) for value in rotation + position + scale):
            raise ValueError(f"{source}: FBXSKEL transform contains a non-finite value at bone {index}")
        parents.append(parent)
        symmetries.append(symmetry)
        rotations.append(tuple(rotation))
        positions.append(tuple(position))
        scales.append(tuple(scale))
        segments.append(payload[entry + 56] != 0)
    if len(set(names)) != len(names):
        raise ValueError(f"{source}: FBXSKEL contains duplicate joint names")
    if parents[0] not in (-1, 0):
        raise ValueError(f"{source}: unexpected FBXSKEL root parent index: {parents[0]}")

    lookup: list[tuple[int, int]] = []
    previous_hash: int | None = None
    seen_indices: set[int] = set()
    for index in range(bone_count):
        hash_value, bone_index = struct.unpack_from("<II", payload, lookup_offset + index * 8)
        if bone_index >= bone_count or bone_index in seen_indices:
            raise ValueError(f"{source}: FBXSKEL lookup bone index is invalid at row {index}")
        if previous_hash is not None and hash_value < previous_hash:
            raise ValueError(f"{source}: FBXSKEL lookup table is not sorted by hash")
        previous_hash = hash_value
        seen_indices.add(bone_index)
        lookup.append((hash_value, bone_index))
    if len(seen_indices) != bone_count:
        raise ValueError(f"{source}: FBXSKEL lookup table does not cover every joint")

    return FbxSkelInfo(
        version=version,
        magic=magic,
        data_offset=data_offset,
        lookup_offset=lookup_offset,
        bone_count=bone_count,
        names=tuple(names),
        parent_indices=tuple(parents),
        symmetry_indices=tuple(symmetries),
        rotations=tuple(rotations),
        positions=tuple(positions),
        scales=tuple(scales),
        segment_scaling=tuple(segments),
        lookup=tuple(lookup),
        sha256=hashlib.sha256(payload).hexdigest(),
    )


def _float_tuple_matches(left: Sequence[float], right: Sequence[float],
                         tolerance: float = ACTOR_SKELETON_FLOAT_TOLERANCE) -> bool:
    return len(left) == len(right) and all(
        math.isclose(a, b, rel_tol=tolerance, abs_tol=tolerance)
        for a, b in zip(left, right)
    )


def _quaternion_matches(left: Sequence[float], right: Sequence[float],
                        tolerance: float = ACTOR_SKELETON_FLOAT_TOLERANCE) -> bool:
    """Compare rotations while accepting the q/-q representation equivalence."""
    return _float_tuple_matches(left, right, tolerance) or _float_tuple_matches(
        left, tuple(-value for value in right), tolerance)


def compare_actor_skeleton_to_baseline(source: FbxSkelInfo, baseline: FbxSkelInfo,
                                       source_name: str = "source") -> None:
    """Require v1 topology and rest orientation to match the stock actor.

    Position differences are intentional: they are the measured independent
    body shape that the runtime applies.  Rotation/scale differences would
    require animation retargeting and are therefore outside v1.
    """
    if baseline.bone_count != ACTOR_SKELETON_BONE_COUNT:
        raise ValueError(
            f"baseline has unsupported FBXSKEL bone count: {baseline.bone_count}"
        )
    if source.bone_count != ACTOR_SKELETON_BONE_COUNT:
        raise ValueError(
            f"{source_name} has unsupported FBXSKEL bone count: {source.bone_count}"
        )
    if source.names != baseline.names:
        first = next((index for index, (left, right) in enumerate(zip(source.names, baseline.names))
                      if left != right), None)
        raise ValueError(f"{source_name} joint order/name differs from baseline at index {first}")
    if source.parent_indices != baseline.parent_indices:
        first = next((index for index, (left, right) in enumerate(
            zip(source.parent_indices, baseline.parent_indices)) if left != right), None)
        raise ValueError(f"{source_name} parent hierarchy differs from baseline at index {first}")
    for index, (symmetry, expected) in enumerate(
            zip(source.symmetry_indices, baseline.symmetry_indices)):
        # Some exporters normalize an unpaired bone's -1 sentinel to its own
        # index.  That representation has the same meaning and does not alter
        # the parent/name topology; retain strict equality for real partners.
        if symmetry != expected and not (
                (symmetry == index and expected == -1) or
                (symmetry == -1 and expected == index)):
            raise ValueError(f"{source_name} symmetry mapping differs from baseline at index {index}")
    for index, (rotation, expected) in enumerate(zip(source.rotations, baseline.rotations)):
        if not _quaternion_matches(rotation, expected):
            raise ValueError(f"{source_name} rotation differs from baseline at index {index}")
    for index, (scale, expected) in enumerate(zip(source.scales, baseline.scales)):
        if not _float_tuple_matches(scale, expected):
            raise ValueError(f"{source_name} scale differs from baseline at index {index}")
    for index, (segment_scaling, expected) in enumerate(
            zip(source.segment_scaling, baseline.segment_scaling)):
        if segment_scaling != expected:
            raise ValueError(f"{source_name} segment scaling differs from baseline at index {index}")


class SourceFiles:
    """Index a loose MOD without following links or writing into it."""

    def __init__(self, root: Path, report: Report, origin: str = "mod"):
        self.root = root.resolve(strict=True)
        self.report = report
        self.origin = origin
        self.assets: dict[tuple[str, bool], Asset] = {}
        self.other_files: list[str] = []

    def add_file(self, path: Path, relative: str) -> None:
        if path.is_symlink():
            self.report.warn("SYMLINK_SKIPPED", "为避免逃逸输入目录，跳过符号链接", relative)
            return
        try:
            resolved = path.resolve(strict=True)
        except OSError as error:
            self.report.error("INPUT_FILE_UNREADABLE", f"输入文件无法读取：{error}", relative)
            return
        if not resolved.is_relative_to(self.root):
            self.report.error("INPUT_PATH_ESCAPE", "输入目录含有指向目录外的 junction/链接，已拒绝", relative)
            return
        try:
            normalized = strip_native_prefix(relative)
            logical, version, streaming = split_versioned(normalized)
        except ValueError:
            self.other_files.append(relative.replace("\\", "/"))
            return
        if path.stat().st_size == 0:
            self.report.warn("EMPTY_RESOURCE", "跳过空资源文件", relative)
            return
        asset = Asset(logical, version, streaming, resolved, self.origin, resolved.stat().st_size)
        expected_version = OWOTS_RESOURCE_VERSIONS.get(asset.extension)
        if expected_version is not None and version != expected_version:
            self.report.error("RESOURCE_VERSION_UNSUPPORTED",
                              "资源版本与当前 OWOTS 读写器不匹配；不能仅改文件后缀后转换", relative,
                              actualVersion=version, supportedVersion=expected_version)
            return
        key = asset.variant_key
        old = self.assets.get(key)
        if old:
            if old.sha256 == asset.sha256:
                self.report.info("DUPLICATE_IDENTICAL", "忽略重复的相同资源", relative)
            else:
                self.report.error("DUPLICATE_RESOURCE", "同一逻辑资源存在不同内容，无法安全选择", relative,
                                  logical=logical, first=str(old.path))
            return
        self.assets[key] = asset

    @classmethod
    def from_directory(cls, root: Path, report: Report, origin: str = "mod") -> "SourceFiles":
        source = cls(root, report, origin)
        for path in sorted(root.rglob("*"), key=lambda p: p.as_posix().casefold()):
            if not path.is_file():
                continue
            try:
                relative = path.relative_to(root).as_posix()
            except ValueError:
                continue
            source.add_file(path, relative)
        source._report_non_assets()
        return source

    def _report_non_assets(self) -> None:
        for relative in self.other_files:
            suffix = Path(relative).suffix.casefold()
            lower = relative.casefold()
            if (suffix in SKIPPED_SUFFIXES or "/reframework/" in "/" + lower or
                    lower.startswith("reframework/") or "/plugins/" in "/" + lower):
                self.report.warn("OPTIONAL_FILE_OMITTED", "脚本、插件或元数据不会盲目携带到衣橱包", relative)
            else:
                self.report.info("NON_RESOURCE_OMITTED", "未识别为 OWOTS 资源，未复制", relative)

    def get(self, logical: str, streaming: bool = False) -> Asset | None:
        return self.assets.get((logical.casefold(), streaming))

    def variants(self, logical: str) -> tuple[Asset, ...]:
        values = [asset for (key, _stream), asset in self.assets.items() if key == logical.casefold()]
        return tuple(sorted(values, key=lambda item: item.streaming))


@dataclasses.dataclass
class ModInfo:
    values: dict[str, str]
    screenshot: Path | None = None


def parse_modinfo(root: Path, report: Report) -> ModInfo:
    """Read common fields leniently; ignore free text after the key/value area."""
    candidates = [path for path in (root / "modinfo.ini", root / "modinfo.txt") if path.is_file()]
    if not candidates:
        return ModInfo({})
    path = candidates[0]
    values: dict[str, str] = {}
    current = "modinfo"
    try:
        text = path.read_text(encoding="utf-8-sig", errors="replace")
    except OSError as error:
        report.warn("MODINFO_READ_FAILED", f"无法读取 modinfo：{error}", str(path))
        return ModInfo({})
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith((";", "#")):
            continue
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1].strip().casefold() or "modinfo"
            continue
        if "=" not in line:
            # Many old mods append Markdown/Chinese prose.  Do not make a
            # valid conversion fail because configparser rejects that prose.
            report.info("MODINFO_FREE_TEXT", "忽略 modinfo 中无键值的自由文本", f"{path}:{number}")
            continue
        key, value = line.split("=", 1)
        key = key.strip().casefold()
        if current not in ("modinfo", ""):
            # Only common fields from the root section are meaningful here.
            continue
        if key in values:
            report.warn("MODINFO_DUPLICATE", "重复 modinfo 字段，使用第一项", f"{path}:{number}", key=key)
            continue
        if key in {"name", "version", "author", "description", "homepage", "screenshot", "icon"}:
            values[key] = value.strip()
    screenshot = None
    name = values.get("screenshot") or values.get("icon")
    if name:
        candidate = (root / name.replace("\\", "/")).resolve()
        if candidate.is_file() and candidate.is_relative_to(root.resolve()):
            screenshot = candidate
        else:
            report.warn("SCREENSHOT_MISSING", "modinfo 指定的预览图不存在，已省略", name)
    if screenshot is None:
        for candidate in sorted(root.glob("preview.*")):
            if candidate.suffix.casefold() in {".png", ".jpg", ".jpeg"}:
                screenshot = candidate
                break
    return ModInfo(values, screenshot)


def safe_id(value: str) -> str:
    raw = str(value or "").strip()
    # A user-supplied valid ASCII ID is already stable and readable; retain
    # it byte-for-byte so links and saved wardrobe selections do not change.
    if raw and MOD_ID_RE.fullmatch(raw):
        return raw
    normalized = re.sub(r"[^a-z0-9._-]+", "-", raw.casefold()).strip("-._")
    digest = hashlib.sha256(raw.encode("utf-8")).hexdigest()[:12]
    prefix = normalized or "converted"
    prefix = prefix[: max(1, 128 - len(digest) - 1)].strip("-._") or "converted"
    return f"{prefix}-{digest}"


def native_hash(path: str) -> tuple[int, int]:
    """RE Engine PAK UTF-16 Murmur3 hash used by KPKA file lists."""
    path = path.replace("\\", "/")
    def murmur(data: bytes) -> int:
        h = 0xFFFFFFFF
        full = len(data) & ~3
        for offset in range(0, full, 4):
            k = int.from_bytes(data[offset:offset + 4], "little")
            k = (k * 0xCC9E2D51) & 0xFFFFFFFF
            k = ((k << 15) | (k >> 17)) & 0xFFFFFFFF
            k = (k * 0x1B873593) & 0xFFFFFFFF
            h ^= k
            h = ((h << 13) | (h >> 19)) & 0xFFFFFFFF
            h = (h * 5 + 0xE6546B64) & 0xFFFFFFFF
        tail = data[full:]
        k = 0
        if len(tail) == 3:
            k ^= tail[2] << 16
        if len(tail) >= 2:
            k ^= tail[1] << 8
        if len(tail) >= 1:
            k ^= tail[0]
            k = (k * 0xCC9E2D51) & 0xFFFFFFFF
            k = ((k << 15) | (k >> 17)) & 0xFFFFFFFF
            k = (k * 0x1B873593) & 0xFFFFFFFF
            h ^= k
        h ^= len(data)
        h ^= h >> 16
        h = (h * 0x85EBCA6B) & 0xFFFFFFFF
        h ^= h >> 13
        h = (h * 0xC2B2AE35) & 0xFFFFFFFF
        h ^= h >> 16
        return h
    return murmur(path.lower().encode("utf-16le")), murmur(path.upper().encode("utf-16le"))


class HashIndex:
    """Exact PAK hash→path resolution; collisions are rejected."""

    def __init__(self, report: Report):
        self.report = report
        self.by_hash: dict[tuple[int, int], str] = {}
        self.collisions: set[tuple[int, int]] = set()

    def add(self, path: str) -> None:
        path = path.strip().replace("\\", "/")
        if not path or path.startswith("#"):
            return
        if not path.casefold().startswith("natives/stm/"):
            return
        try:
            path = validate_hash_path(path)
        except ValueError as error:
            self.report.error("HASH_PATH_INVALID", f"文件列表路径不安全或没有支持的版本后缀：{error}", path)
            return
        key = native_hash(path)
        old = self.by_hash.get(key)
        if old and old.casefold() != path.casefold():
            self.collisions.add(key)
            self.report.error("PAK_HASH_COLLISION", "文件列表中存在相同 hash 的不同路径", path, first=old)
        else:
            self.by_hash[key] = path

    @classmethod
    def from_file(cls, path: Path, report: Report) -> "HashIndex":
        index = cls(report)
        try:
            with path.open("r", encoding="utf-8-sig", errors="replace") as stream:
                for line in stream:
                    index.add(line)
        except OSError as error:
            report.error("HASH_LIST_READ_FAILED", f"无法读取 PAK 文件列表：{error}", str(path))
        return index

    @classmethod
    def from_json(cls, path: Path, report: Report) -> "HashIndex":
        index = cls(report)
        try:
            value = json.loads(path.read_text(encoding="utf-8-sig"))
        except (OSError, json.JSONDecodeError) as error:
            report.error("HASH_MAP_READ_FAILED", f"无法读取哈希映射：{error}", str(path))
            return index
        if not isinstance(value, dict):
            report.error("HASH_MAP_FORMAT", "哈希映射必须是对象", str(path))
            return index
        for raw_hash, raw_path in value.items():
            if not isinstance(raw_hash, str) or not isinstance(raw_path, str):
                report.error("HASH_MAP_FORMAT", "映射键和值必须是文本", str(path))
                continue
            try:
                number = int(raw_hash.removeprefix("0x"), 16)
                if not 0 <= number <= 0xFFFFFFFFFFFFFFFF:
                    raise ValueError("hash 超出 64 位范围")
                lower = number & 0xFFFFFFFF
                upper = (number >> 32) & 0xFFFFFFFF
                normalized = raw_path.replace("\\", "/")
                if not normalized.casefold().startswith("natives/stm/"):
                    raise ValueError("path must begin with natives/stm/")
                normalized = validate_hash_path(normalized)
                if native_hash(normalized) != (lower, upper):
                    raise ValueError("hash 与路径不匹配")
                key = (lower, upper)
                old = index.by_hash.get(key)
                if old and old.casefold() != normalized.casefold():
                    raise ValueError("hash collision")
                index.by_hash[key] = normalized
            except ValueError as error:
                report.error("HASH_MAP_FORMAT", str(error), str(path), hash=raw_hash)
        return index

    def resolve(self, lower: int, upper: int) -> str | None:
        if (lower, upper) in self.collisions:
            return None
        return self.by_hash.get((lower, upper))


@dataclasses.dataclass(frozen=True)
class PakEntry:
    lower: int
    upper: int
    offset: int
    compressed_size: int
    decompressed_size: int
    attributes: int
    checksum: int
    compression: int
    encryption: int


class PakArchive:
    """Bounded reader for ordinary KPKA 2/4 packages.

    Feature 0 is fully extractable here (none/deflate).  Feature 40 game
    archives need the game's RSA table key and are therefore left to the
    optional game PAK provider; treating them as ordinary PAKs is unsafe.
    """

    def __init__(self, path: Path, report: Report):
        self.path = path.resolve(strict=True)
        self.report = report
        self.major = self.minor = self.feature = self.count = self.fingerprint = 0
        self.entries: list[PakEntry] = []
        self.protected: dict[str, Any] | None = None

    def parse(self) -> None:
        size = self.path.stat().st_size
        if size < 16:
            raise ConversionError("PAK 文件小于 16 字节")
        with self.path.open("rb") as stream:
            header = stream.read(16)
            if header[:4] != b"KPKA":
                raise ConversionError("不是 KPKA PAK 文件")
            # The four-byte KPKA magic precedes the 12-byte version/feature/
            # count/fingerprint header.  Keeping this slice explicit prevents
            # accidentally accepting a short or shifted header.
            self.major, self.minor, self.feature, self.count, self.fingerprint = struct.unpack("<BBHii", header[4:])
            if self.major not in (2, 4) or self.minor not in (0, 1, 2):
                raise ConversionError(f"不支持的 PAK 版本 {self.major}.{self.minor}")
            entry_size = 24 if self.major == 2 else 48
            table_end = 16 + self.count * entry_size
            if self.count < 0 or self.count > 10_000_000 or table_end > size:
                raise ConversionError("PAK 条目数量或目录大小越界")
            table = stream.read(self.count * entry_size)
            if self.feature != 0:
                self.report.warn("PAK_FEATURE", "PAK 使用带附加目录特性的格式；转换只允许已验证的普通条目",
                                 str(self.path), feature=self.feature)
                # Protected/custom PAKs are diagnosed before reading their
                # indexed table.  Feature 40 is a game archive and has an
                # encrypted table, so this table cannot be trusted here.
                if self.feature not in (0,):
                    return
            entries: list[PakEntry] = []
            total_decompressed = 0
            for index in range(self.count):
                chunk = table[index * entry_size:(index + 1) * entry_size]
                if self.major == 2:
                    offset, uncompressed, lower, upper = struct.unpack("<qqII", chunk)
                    if offset < table_end or uncompressed < 0:
                        raise ConversionError(f"PAK 条目 {index} 的偏移或长度越界")
                    if uncompressed > MAX_PAK_ENTRY_BYTES or offset + uncompressed > size:
                        raise ConversionError(f"PAK 条目 {index} 超出安全大小或文件边界")
                    total_decompressed += uncompressed
                    if total_decompressed > MAX_PAK_TOTAL_BYTES:
                        raise ConversionError("PAK 声明的总解压大小超过安全上限")
                    entries.append(PakEntry(lower, upper, offset, uncompressed, uncompressed, 0, 0, 0, 0))
                else:
                    lower, upper, offset, compressed, uncompressed, attributes, checksum = struct.unpack("<IIqqqqQ", chunk)
                    if min(offset, compressed, uncompressed) < 0:
                        raise ConversionError(f"PAK 条目 {index} 含负值范围")
                    if offset < table_end:
                        raise ConversionError(f"PAK 条目 {index} 的数据偏移落在目录表内")
                    if compressed > MAX_PAK_ENTRY_BYTES or uncompressed > MAX_PAK_ENTRY_BYTES:
                        raise ConversionError(f"PAK 条目 {index} 超过单条资源安全大小")
                    compression = attributes & 0xF
                    encryption = (attributes >> 16) & 0xFF
                    if offset + compressed > size:
                        raise ConversionError(f"PAK 条目 {index} 超出文件边界")
                    total_decompressed += uncompressed
                    if total_decompressed > MAX_PAK_TOTAL_BYTES:
                        raise ConversionError("PAK 声明的总解压大小超过安全上限")
                    entries.append(PakEntry(lower, upper, offset, compressed, uncompressed,
                                             attributes, checksum, compression, encryption))
            self.entries = entries

    def detect_protected(self) -> dict[str, Any] | None:
        size = self.path.stat().st_size
        needles = (b"WOTSPK01", b"WOTSPV03")
        found: dict[str, int] = {}
        with self.path.open("rb") as stream:
            position = 0
            carry = b""
            while position < size:
                block = stream.read(min(4 * 1024 * 1024, size - position))
                if not block:
                    break
                haystack = carry + block
                base = position - len(carry)
                for needle in needles:
                    at = haystack.find(needle)
                    if at >= 0 and needle.decode() not in found:
                        found[needle.decode()] = base + at
                carry = haystack[-len(max(needles, key=len)) + 1:]
                position += len(block)
        if "WOTSPK01" in found or "WOTSPV03" in found:
            payload_start = found.get("WOTSPK01")
            payload_end = found.get("WOTSPV03")
            self.protected = {
                "header": found.get("WOTSPK01"),
                "footer": found.get("WOTSPV03"),
                "payloadBytes": ((payload_end - payload_start) if payload_start is not None and payload_end is not None else None),
            }
            return self.protected
        return None

    def extract(self, entry: PakEntry, destination: Path) -> bytes:
        payload = self.read_payload(entry)
        destination.parent.mkdir(parents=True, exist_ok=True)
        with destination.open("xb") as stream:
            stream.write(payload)
        return payload

    def read_payload(self, entry: PakEntry) -> bytes:
        if self.feature != 0:
            raise ConversionError("PAK 带加密/分块目录，不能作为普通 MOD 解包")
        if entry.encryption:
            raise ConversionError("PAK 条目带资源加密标志，拒绝猜测密钥")
        if entry.compression not in (0, 1, 2):
            raise ConversionError(f"不支持的 PAK 压缩方式 {entry.compression}；请先用可信工具解包")
        with self.path.open("rb") as stream:
            stream.seek(entry.offset)
            payload = stream.read(entry.compressed_size)
        if len(payload) != entry.compressed_size:
            raise ConversionError("PAK 条目读取不完整")
        if entry.compression == 1:
            try:
                decoder = zlib.decompressobj(-15)
                # The one-byte margin detects expansion beyond the declared
                # size while keeping the allocation bounded by the header.
                payload = decoder.decompress(payload, entry.decompressed_size + 1)
                if len(payload) <= entry.decompressed_size and decoder.eof:
                    payload += decoder.flush(max(entry.decompressed_size + 1 - len(payload), 0))
                if (len(payload) > entry.decompressed_size or not decoder.eof or
                        decoder.unused_data or decoder.unconsumed_tail):
                    raise ConversionError("PAK DEFLATE 流未在声明长度内完整结束")
            except zlib.error as error:
                raise ConversionError(f"PAK DEFLATE 解压失败：{error}") from error
            except ConversionError:
                raise
        elif entry.compression == 2:
            try:
                import zstandard as zstd  # type: ignore
            except ImportError as error:
                raise ConversionError("PAK 使用 Zstandard；请安装 requirements.txt 中的 zstandard，或使用发行版 EXE") from error
            try:
                # Some zstandard frames carry their own content size and the
                # Python binding may honor that size before max_output_size.
                # Check the frame declaration first, then retain the bound
                # for unknown-size frames and reject trailing concatenated
                # data.
                frame_size = zstd.frame_content_size(payload)
                unknown = getattr(zstd, "CONTENTSIZE_UNKNOWN", (1 << 64) - 1)
                invalid = getattr(zstd, "CONTENTSIZE_ERROR", (1 << 64) - 2)
                if frame_size not in (unknown, invalid) and frame_size != entry.decompressed_size:
                    raise ConversionError("PAK Zstandard frame 长度与目录声明不一致")
                payload = zstd.ZstdDecompressor().decompress(
                    payload, max_output_size=entry.decompressed_size + 1,
                    allow_extra_data=False)
            except (zstd.ZstdError, ValueError) as error:  # type: ignore[name-defined]
                raise ConversionError(f"PAK Zstandard 解压失败：{error}") from error
        if len(payload) != entry.decompressed_size:
            raise ConversionError("PAK 条目解压长度与目录不一致")
        if entry.checksum:
            # RE PAK checksums differ across game versions.  A non-zero value
            # without a matching implementation is never called verified.
            self.report.warn("PAK_CHECKSUM_UNVERIFIED", "PAK 条目 checksum 非零，未声称校验通过",
                             str(self.path), checksum=f"0x{entry.checksum:016x}")
        return payload


class AppearanceWorker:
    """Small protocol client for the existing read/verify/rewrite worker."""

    def __init__(self, executable: Path, template: Path, timeout: int = 120):
        self.executable = executable.resolve(strict=True)
        self.template = template.resolve(strict=True)
        self.timeout = timeout

    @staticmethod
    def discover(explicit: Path | None, template: Path | None) -> "AppearanceWorker | None":
        here = Path(__file__).resolve()
        candidates: list[Path] = []
        if explicit:
            candidates.append(explicit)
        candidates += [
            here.parent / "runtime" / "AppearanceRsz.exe",
            here.parent / "runtime" / "AppearanceRsz.dll",
            here.parents[2] / "RE-Mesh-Editor-main" / "tools" / "appearance-rsz" / "bin" / "Release" / "net10.0" / "AppearanceRsz.dll",
            here.parents[2] / "RE-Mesh-Editor-main" / "tools" / "appearance-rsz" / "bin" / "Debug" / "net10.0" / "AppearanceRsz.dll",
        ]
        templates: list[Path] = []
        if template:
            templates.append(template)
        templates += [
            here.parent / "runtime" / "rszoniwots.json",
            here.parent / "runtime" / "rszoniwots_reelib_fixed.json",
            here.parents[2] / "RE-Mesh-Editor-main" / "modules" / "workspace" / "appearance_data" / "rszoniwots_reelib_fixed.json",
            here.parents[2] / "RE-Mesh-Editor-main" / "modules" / "workspace" / "appearance_data" / "rszoniwots.json",
        ]
        exe = next((path for path in candidates if path.is_file()), None)
        tpl = next((path for path in templates if path.is_file()), None)
        if not exe or not tpl:
            return None
        return AppearanceWorker(exe, tpl)

    def _run(self, source: Path, remap: Mapping[str, str], output: Path | None,
             allow_crc_mismatch: bool = False, native_part_id: int | None = None) -> dict[str, Any]:
        source = source.resolve(strict=True)
        with tempfile.TemporaryDirectory(prefix="owots-mod-converter-") as temporary:
            root = Path(temporary)
            output_temp = root / "output" / source.name if output else None
            if output_temp:
                output_temp.parent.mkdir(parents=True)
            request = {
                "Operation": "rewrite" if output else "inspect",
                "Input": str(source), "Template": str(self.template),
                "Output": str(output_temp) if output_temp else None,
                "Remap": dict(remap), "AllowCrcMismatch": bool(allow_crc_mismatch),
            }
            if native_part_id is not None:
                request["NativePartId"] = native_part_id
            request_path, result_path = root / "request.json", root / "result.json"
            request_path.write_text(json.dumps(request, ensure_ascii=False), encoding="utf-8")
            command = (["dotnet", str(self.executable)] if self.executable.suffix.casefold() == ".dll"
                       else [str(self.executable)]) + [str(request_path), str(result_path)]
            try:
                process = subprocess.run(command, capture_output=True, timeout=self.timeout,
                                         creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            except (OSError, subprocess.TimeoutExpired) as error:
                raise ConversionError(f"RSZ worker 未完成：{error}") from error
            if process.returncode:
                detail = (process.stderr + process.stdout).decode("utf-8", errors="replace")[-6000:]
                raise ConversionError(f"RSZ worker 失败：{detail}")
            try:
                result = json.loads(result_path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as error:
                raise ConversionError(f"RSZ worker 返回无效报告：{error}") from error
            before = hashlib.sha256(source.read_bytes()).hexdigest()
            if result.get("SourceSha256") != before:
                raise ConversionError("RSZ worker 未证明输入文件保持不变")
            if output:
                if result.get("ReadbackVerified") is not True or not output_temp or not output_temp.is_file():
                    raise ConversionError("RSZ worker 未验证输出回读")
                payload = output_temp.read_bytes()
                if hashlib.sha256(payload).hexdigest() != result.get("OutputSha256"):
                    raise ConversionError("RSZ worker 输出摘要不一致")
                output.parent.mkdir(parents=True, exist_ok=True)
                with output.open("xb") as stream:
                    stream.write(payload)
            return result

    def inspect(self, source: Path) -> dict[str, Any]:
        return self._run(source, {}, None)

    def rewrite(self, source: Path, destination: Path, remap: Mapping[str, str],
                allow_crc_mismatch: bool = False, native_part_id: int | None = None) -> dict[str, Any]:
        return self._run(source, remap, destination, allow_crc_mismatch, native_part_id)


@dataclasses.dataclass(frozen=True)
class ResourceNode:
    logical: str
    asset: Asset
    dependencies: tuple[str, ...]
    crc_warnings: tuple[dict[str, Any], ...] = ()


def _extract_paths(payload: bytes) -> tuple[str, ...]:
    """Conservative fallback for leaf resources; structured files require worker."""
    result: set[str] = set()
    for encoding in ("utf-8", "utf-16le"):
        try:
            text = payload.decode(encoding, errors="ignore")
        except UnicodeError:
            continue
        for match in re.finditer(r"[A-Za-z0-9_./-]{5,}\.(?:mesh|mdf2|tex|jcns|chain2|motlist|motbank|pfb|user)", text, re.I):
            value = match.group(0).replace("\\", "/")
            if value.startswith(("Art/", "art/", "GameDesign/", "gamedesign/")):
                try:
                    result.add(logical_path(value))
                except ValueError:
                    pass
    return tuple(sorted(result, key=str.casefold))


class GameReference:
    """Read-only loose game/reference tree.

    The full Steam install is usually PAK-only.  This provider intentionally
    reports that case instead of pretending that a file-list name proves that
    bytes are available; a future signed PAK provider can be plugged in via
    ``--game-extract`` without changing conversion semantics.
    """

    def __init__(self, root: Path, report: Report, pak_provider: Any | None = None,
                 *, allow_loose: bool = True):
        self.root = root.resolve(strict=True)
        self.report = report
        self.pak_provider = pak_provider
        self._index: dict[tuple[str, bool], list[Asset]] = {}
        self._pak_assets: dict[tuple[str, bool], Asset] = {}
        # A Steam install can contain user overrides beside its original PAKs.
        # Once the original PAK provider is active, scanning the whole root
        # could accidentally treat those overrides as authoritative game data.
        if allow_loose:
            self._build()

    def _build(self) -> None:
        for path in sorted(self.root.rglob("*"), key=lambda p: p.as_posix().casefold()):
            if not path.is_file() or path.is_symlink():
                continue
            rel = path.relative_to(self.root).as_posix()
            try:
                resolved = path.resolve(strict=True)
            except OSError as error:
                self.report.error("REFERENCE_FILE_UNREADABLE", f"参考文件无法读取：{error}", rel)
                continue
            if not resolved.is_relative_to(self.root):
                self.report.error("REFERENCE_PATH_ESCAPE", "参考目录含有指向目录外的 junction/链接，已跳过", rel)
                continue
            try:
                normalized = strip_native_prefix(rel)
                logical, version, streaming = split_versioned(normalized)
            except ValueError:
                continue
            asset = Asset(logical, version, streaming, resolved, "game", resolved.stat().st_size)
            self._index.setdefault(asset.variant_key, []).append(asset)

    def find(self, logical: str, streaming: bool = False) -> Asset | None:
        values = self._index.get((logical.casefold(), streaming), [])
        if len(values) > 1:
            self.report.error("GAME_VERSION_AMBIGUOUS", "参考目录中存在多个物理版本，无法猜选", logical,
                              versions=[asset.version for asset in values])
            return None
        if values:
            return values[0]
        if self.pak_provider:
            key = (logical.casefold(), bool(streaming))
            if key not in self._pak_assets:
                fetched = self.pak_provider.fetch(logical, streaming)
                if fetched:
                    path, version = fetched
                    self._pak_assets[key] = Asset(logical, version, streaming, path, "game", path.stat().st_size)
            return self._pak_assets.get(key)
        return None

    def all_for(self, logical: str) -> tuple[Asset, ...]:
        values = []
        for streaming in (False, True):
            found = self.find(logical, streaming)
            if found:
                values.append(found)
        return tuple(values)

    def close(self) -> None:
        if self.pak_provider:
            self.pak_provider.close()
            self.pak_provider = None


class InputBundle:
    def __init__(self, root: Path, report: Report, hash_index: HashIndex | None = None):
        self.root = root.resolve(strict=True)
        self.report = report
        self.source = SourceFiles(self.root, report)
        self.temp: tempfile.TemporaryDirectory[str] | None = None
        self.archive: PakArchive | None = None
        self.hash_index = hash_index

    def load(self) -> None:
        if self.root.is_dir():
            self.source = SourceFiles.from_directory(self.root, self.report)
            return
        if self.root.suffix.casefold() == ".pak":
            self._load_pak()
            return
        raise ConversionError("输入必须是已解包 MOD 目录或 .pak 文件")

    def _load_pak(self) -> None:
        archive = self.archive = PakArchive(self.root, self.report)
        archive.parse()
        protected = archive.detect_protected()
        if protected:
            self.report.error(
                "PAK_PROTECTED_CUSTOM",
                "检测到 WOTSPK01/WOTSPV03 专用加密封套；不能把标准目录中的截图/说明误当成 MOD 资源。",
                str(self.root), **protected,
            )
            self.report.info("PAK_PROTECTED_NEXT_STEP",
                             "请向 MOD 作者索取未加密 PAK/解包版，或提供作者授权的解密插件与路径映射。工具不会猜密钥。")
            return
        if archive.feature != 0:
            self.report.error("PAK_FEATURE_UNSUPPORTED",
                              "该 PAK 目录/资源带加密或分块特性，当前普通 PAK 管线不会假装已解包。",
                              str(self.root), feature=archive.feature)
            return
        self.temp = tempfile.TemporaryDirectory(prefix="owots-pak-extract-")
        extract_root = Path(self.temp.name)
        self.source = SourceFiles(extract_root, self.report)
        manifest_entries: set[int] = set()
        embedded_paths: set[str] = set()
        # Most authoring tools include a tiny __MANIFEST/MANIFEST.TXT.  Read
        # only plausibly-small unknown entries to discover that exact list;
        # this makes an ordinary PAK drag-and-drop friendly without accepting
        # arbitrary magic/type guesses.  The manifest itself is never copied.
        for number, entry in enumerate(archive.entries):
            if entry.decompressed_size > 2 * 1024 * 1024:
                continue
            try:
                payload = archive.read_payload(entry)
                text = payload.decode("utf-8-sig")
            except (UnicodeDecodeError, ConversionError):
                continue
            lines = [line.strip().replace("\\", "/") for line in text.splitlines() if line.strip()]
            candidate = []
            for line in lines:
                if line.casefold().startswith("natives/stm/"):
                    try:
                        _logical, _version, _streaming = split_versioned(line)
                    except ValueError:
                        break
                    candidate.append(line)
                elif line.casefold().startswith("__manifest/"):
                    continue
                else:
                    break
            if candidate and len(candidate) == len([line for line in lines if not line.casefold().startswith("__manifest/")]):
                manifest_entries.add(number)
                embedded_paths.update(candidate)
        if embedded_paths:
            if self.hash_index is None:
                self.hash_index = HashIndex(self.report)
                self.report.info("PAK_EMBEDDED_MANIFEST", "已从 PAK 内置清单建立精确路径索引",
                                 str(self.root), entries=len(embedded_paths))
            for path in embedded_paths:
                self.hash_index.add(path)
            self.report.stats["embeddedManifestPaths"] = len(embedded_paths)
            # A manifest is a complete contract for the small authoring PAKs
            # accepted here.  If the table has more/less data entries than
            # the manifest declares, stopping is safer than silently dropping
            # a model or carrying an unrelated payload into the wardrobe.
            data_entries = len(archive.entries) - len(manifest_entries)
            if data_entries != len(embedded_paths):
                self.report.error(
                    "PAK_MANIFEST_COVERAGE",
                    "PAK 内置清单没有覆盖全部数据条目，不能安全判断哪些资源属于 MOD。",
                    str(self.root), manifestEntries=len(embedded_paths),
                    dataEntries=data_entries,
                )
                return
        if not self.hash_index:
            self.report.error("PAK_HASH_INDEX_REQUIRED",
                              "普通 PAK 只有 hash 路径；请设置 --hash-list/--hash-map，或使用包含 __MANIFEST/MANIFEST.TXT 的 PAK。",
                              str(self.root))
            return
        resolved_entries = 0
        for number, entry in enumerate(archive.entries):
            if number in manifest_entries:
                continue
            path = self.hash_index.resolve(entry.lower, entry.upper)
            if not path:
                self.report.error("PAK_HASH_UNRESOLVED",
                                  "PAK 条目 hash 未在可信路径索引中解析，转换已阻止。",
                                  str(self.root), index=number,
                                  hash=f"{entry.upper:08x}{entry.lower:08x}")
                continue
            try:
                relative = path.removeprefix("natives/stm/")
                destination = extract_root / relative
                archive.extract(entry, destination)
                self.source.add_file(destination, relative)
                resolved_entries += 1
            except (ConversionError, OSError) as error:
                self.report.error("PAK_ENTRY_FAILED", str(error), path, index=number)
        if embedded_paths:
            self.report.stats["embeddedManifestVerified"] = resolved_entries == len(embedded_paths)
        self.source._report_non_assets()


def classify_part(logical: str) -> str | None:
    lower = logical.casefold()
    name = PurePosixPath(logical).name.casefold()
    tokens = re.split(r"[/_.-]+", lower)
    if "bodysub" in lower or "body_sub" in lower or "bodysub" in lower:
        return "BODY_SUB"
    for part, words in (("HEAD", ("head",)), ("HAIR", ("hair",)), ("CLOAK", ("cloak", "coat")),
                        ("GAUNTLET", ("gauntlet", "glove")), ("SHEATH_SUB", ("sheath_sub", "weaponsub")),
                        ("SHEATH", ("sheath",)), ("BOW", ("bow",)), ("WEAPON_SUB", ("weapon_sub",)),
                        ("WEAPON", ("weapon",))):
        if any(word in lower for word in words):
            return part
    if "/partslist/body/" in lower or "/body/" in lower:
        return "BODY"
    if name.endswith(".pfb") and "ch" in name:
        return "BODY"
    return None


def category_for_parts(parts: Sequence[str]) -> str:
    categories = {PART_CATEGORY[part] for part in parts if part in PART_CATEGORY}
    if len(categories) != 1:
        raise ConversionError("检测到多个衣橱分类；请用 --category 明确选择，避免把变体合并")
    return next(iter(categories))


def mdf_dependencies(payload: bytes) -> tuple[str, ...]:
    # Use the bundled strict parser.  A regex fallback would silently miss
    # slot/streaming semantics and could publish a blurry or incomplete asset.
    try:
        from owots_vendor.workspace.appearance_mdf import texture_dependencies  # type: ignore
    except ImportError as error:
        raise ConversionError("MDF2 依赖解析器未随工具安装；请把 vendor/appearance_mdf.py 放入发行包") from error
    try:
        values = texture_dependencies(payload)
    except (OSError, ValueError, KeyError, IndexError, struct.error) as error:
        raise ConversionError(f"MDF2 严格解析失败：{error}") from error
    return tuple(logical_path(value) for value in values)


class Converter:
    def __init__(self, args: argparse.Namespace, report: Report):
        self.args = args
        self.report = report
        self.worker = AppearanceWorker.discover(
            Path(args.worker) if getattr(args, "worker", None) else None,
            Path(args.template) if getattr(args, "template", None) else None,
        )
        if self.worker:
            self.report.info("RSZ_WORKER", "已启用 AppearanceRsz 结构化资源读写器", str(self.worker.executable))
        else:
            self.report.warn("RSZ_WORKER_MISSING",
                             "未找到 AppearanceRsz；遇到 PFB/USER 时会安全停止，避免伪造结构化输出。")
        self.modinfo: ModInfo | None = None
        self.bundle: InputBundle | None = None
        self.game: GameReference | None = None
        self.nodes: dict[str, ResourceNode] = {}
        self.roots: list[str] = []
        self.private: set[str] = set()
        self.routes: dict[str, str] = {}
        self.part_roots: dict[str, tuple[str, str | None, int | None]] = {}
        self.catalog_selection: dict[str, tuple[str, int | None]] = {}
        self.auto_native_parts: set[str] = set()
        self.actor_skeleton_candidates: list[tuple[Asset, FbxSkelInfo | None]] = []
        self.actor_skeleton_keys: set[str] = set()
        self.actor_skeleton_asset: Asset | None = None
        self.actor_skeleton_info: FbxSkelInfo | None = None
        self.actor_skeleton_body_mesh: str | None = None
        # Mesh-authored shape: no separate rig file, so the declaration carries
        # the baseline joint names only and the runtime reads the mesh rest.
        self.actor_skeleton_mesh_only: bool = False
        self.actor_skeleton_joint_names: list[str] | None = None

    def inspect(self) -> None:
        self.modinfo = parse_modinfo(self.args.input.resolve(), self.report) if self.args.input.is_dir() else None
        index = self._hash_index()
        self.bundle = InputBundle(self.args.input, self.report, index)
        self.bundle.load()
        self._audit_dynamic_behavior()
        self._inspect_actor_skeleton_sources()
        self.report.stats.update({
            "inputAssets": len(self.bundle.source.assets),
            "inputFiles": len(self.bundle.source.other_files) + len(self.bundle.source.assets),
            "pakEntries": len(self.bundle.archive.entries) if self.bundle.archive else 0,
        })
        if self.bundle.source.assets:
            candidates = self._candidates()
            self.report.stats["partCandidates"] = candidates
            for logical, part in candidates:
                self.report.info("PART_CANDIDATE", f"自动识别 {part} 资源", logical, part=part)
        if self.bundle.archive and self.bundle.archive.protected:
            self.report.stats["protectedPak"] = self.bundle.archive.protected

    def _dynamic_files(self) -> list[str]:
        """Return files whose runtime behavior cannot be represented by a manifest.

        Lua autorun scripts and native/plugin binaries can change arbitrary
        runtime state (including selecting multiple PFB variants).  A static
        package must not claim equivalence while silently omitting them.
        """
        assert self.bundle
        result: list[str] = []
        for relative in self.bundle.source.other_files:
            normalized = relative.replace("\\", "/")
            lower = normalized.casefold()
            suffix = PurePosixPath(normalized).suffix.casefold()
            if suffix in SCRIPTS_OR_PLUGINS or "/autorun/" in "/" + lower or "/plugins/" in "/" + lower:
                result.append(normalized)
        return sorted(set(result), key=str.casefold)

    def _audit_dynamic_behavior(self) -> None:
        """Make static-only limitations explicit before graph conversion."""
        dynamic = self._dynamic_files()
        if not dynamic:
            return
        self.report.stats["dynamicFiles"] = dynamic
        message = (
            "输入包含 Lua/原生插件等动态行为；静态衣橱 manifest 无法等价表达这些逻辑，"
            "默认阻止转换。若确认只需要静态模型，请显式启用 --experimental-static-only。"
        )
        if getattr(self.args, "experimental_static_only", False):
            self.report.warn("DYNAMIC_BEHAVIOR_STATIC_ONLY", message + " 当前已按实验静态模式继续。",
                             dynamic[0], files=dynamic)
        else:
            self.report.error("DYNAMIC_BEHAVIOR_UNSUPPORTED", message, dynamic[0], files=dynamic)

    def _source_actor_skeleton_assets(self) -> list[Asset]:
        """Return source FBXSKEL candidates in stable logical-path order."""
        assert self.bundle
        return sorted(
            (asset for asset in self.bundle.source.assets.values()
             if not asset.streaming and asset.extension == ".fbxskel"),
            key=lambda asset: asset.logical.casefold(),
        )

    def _inspect_actor_skeleton_sources(self) -> None:
        """Parse source rigs and expose safe diagnostics during ``inspect``.

        ``inspect`` has no selected BODY root yet, so it only validates the
        binary and the v1 size boundary.  Conversion performs the baseline,
        transform and body-mesh checks once the explicit part plan is known.
        """
        candidates = self._source_actor_skeleton_assets()
        self.actor_skeleton_candidates = []
        self.actor_skeleton_keys = {asset.logical.casefold() for asset in candidates}
        summaries: list[dict[str, Any]] = []
        for asset in candidates:
            try:
                info = parse_fbxskel(asset.path.read_bytes(), asset.logical)
            except (OSError, ValueError) as error:
                self.actor_skeleton_candidates.append((asset, None))
                self.report.error("ACTOR_SKELETON_INVALID",
                                  f"独立 FBXSKEL 无法安全解析：{error}", asset.logical)
                continue
            self.actor_skeleton_candidates.append((asset, info))
            summary = {
                "logical": asset.logical,
                "version": info.version,
                "boneCount": info.bone_count,
                "sha256": info.sha256,
            }
            summaries.append(summary)
            if info.bone_count != ACTOR_SKELETON_BONE_COUNT:
                self.report.error(
                    "ACTOR_SKELETON_TOPOLOGY_UNSUPPORTED",
                    "独立骨架不是 v1 支持的 93 关节角色骨架；追加关节需要专用 actor 适配器。",
                    asset.logical,
                    actualBoneCount=info.bone_count,
                    supportedBoneCount=ACTOR_SKELETON_BONE_COUNT,
                )
            else:
                self.report.info("ACTOR_SKELETON_CANDIDATE",
                                 "发现可进一步核对的 v1 独立角色骨架资源", asset.logical,
                                 boneCount=info.bone_count)
        if len(candidates) > 1:
            self.report.error(
                "ACTOR_SKELETON_AMBIGUOUS",
                "输入包含多个独立 FBXSKEL，无法猜测哪个角色骨架属于当前身体服装。",
                candidates[0].logical,
                candidates=[asset.logical for asset in candidates],
            )
        if summaries:
            self.report.stats["actorSkeletonSources"] = summaries

    @staticmethod
    def _actor_skeleton_issue_code(error: ValueError) -> str:
        text = str(error).casefold()
        if "rotation" in text or "scale" in text or "segment scaling" in text:
            return "ACTOR_SKELETON_TRANSFORM_UNSUPPORTED"
        if "joint order" in text or "parent hierarchy" in text or "symmetry" in text:
            return "ACTOR_SKELETON_TOPOLOGY_MISMATCH"
        if "bone count" in text:
            return "ACTOR_SKELETON_TOPOLOGY_UNSUPPORTED"
        return "ACTOR_SKELETON_BASELINE_MISMATCH"

    def _body_mesh_for_actor_skeleton(self) -> str | None:
        """Find the nearest MOD-owned mesh below the selected BODY PFB."""
        roots = self.part_roots.get("BODY")
        if not roots:
            return None
        root = roots[0].casefold()
        distances: dict[str, int] = {root: 0}
        pending: list[str] = [root]
        while pending:
            key = pending.pop(0)
            node = self.nodes.get(key)
            if not node:
                continue
            for dependency in node.dependencies:
                child = dependency.casefold()
                if child not in distances:
                    distances[child] = distances[key] + 1
                    pending.append(child)
        meshes = [
            (distances[key], node.logical.casefold(), node.logical)
            for key, node in self.nodes.items()
            if key in distances and node.asset.origin == "mod" and node.asset.extension == ".mesh"
        ]
        if not meshes:
            return None
        meshes.sort(key=lambda value: (value[0], value[1]))
        return meshes[0][2]

    def _prepare_mesh_actor_skeleton(self) -> None:
        """Publish a skeleton contract when the shape lives in the BODY mesh.

        A MOD that ships no separate rig file still carries its authored rest in
        the BODY mesh's own embedded skeleton.  In that case emit the declaration
        with the baseline joint names and no ``bindPositions``; the runtime then
        reads the equipped mesh's own rest.  A separate validated rig always wins
        (handled by ``_prepare_actor_skeleton``).
        """
        if self.actor_skeleton_asset is not None or self.actor_skeleton_candidates:
            return
        if getattr(self.args, "category", None) != "body" or "BODY" not in self.part_roots:
            return
        if self.game is None:
            return
        baseline_asset = self.game.find(ACTOR_SKELETON_BASELINE_RESOURCE, False)
        if baseline_asset is None:
            return
        try:
            baseline = parse_fbxskel(
                baseline_asset.path.read_bytes(), ACTOR_SKELETON_BASELINE_RESOURCE
            )
        except (OSError, ValueError):
            return
        if baseline.bone_count != ACTOR_SKELETON_BONE_COUNT:
            return
        body_mesh = self._body_mesh_for_actor_skeleton()
        if body_mesh is None:
            return
        self.actor_skeleton_mesh_only = True
        self.actor_skeleton_body_mesh = body_mesh
        self.actor_skeleton_joint_names = list(baseline.names)
        self.report.stats["actorSkeleton"] = {
            "source": "mesh",
            "bodyMesh": body_mesh,
            "bindPositions": "mesh",
            "baselineResource": ACTOR_SKELETON_BASELINE_RESOURCE,
            "baselineSha256": getattr(baseline_asset, "sha256", None),
            "boneCount": baseline.bone_count,
        }
        self.report.info(
            "ACTOR_SKELETON_MESH_SOURCE",
            "体型取自 BODY mesh 内嵌骨架，manifest 不写 bindPositions，运行时读取 mesh 休止。",
            body_mesh,
        )

    def _prepare_actor_skeleton(self) -> None:
        """Validate and register one source actor rig for private publishing.

        The game reference is consulted explicitly for the fixed stock /90
        rig.  A source file at the same logical path never becomes its own
        baseline by accident.  Only the position vectors may differ in v1;
        ordered names, parent/symmetry topology, rotations and scales must be
        identical to the reference.
        """
        if not self.actor_skeleton_candidates:
            self._inspect_actor_skeleton_sources()
        valid = [(asset, info) for asset, info in self.actor_skeleton_candidates if info is not None]
        if len(valid) != 1:
            return
        asset, info = valid[0]
        assert info is not None
        if info.bone_count != ACTOR_SKELETON_BONE_COUNT:
            return
        if getattr(self.args, "category", None) != "body" or "BODY" not in self.part_roots:
            self.report.error(
                "ACTOR_SKELETON_BODY_REQUIRED",
                "独立角色骨架只能绑定包含 BODY 部位的 body 衣橱条目。",
                asset.logical,
            )
            return
        if self.game is None:
            self.report.error(
                "ACTOR_SKELETON_BASELINE_MISSING",
                "无法读取原始角色 /90 骨架，不能验证独立骨架的角色拓扑和休止姿态。",
                ACTOR_SKELETON_BASELINE_RESOURCE,
            )
            return
        baseline_asset = self.game.find(ACTOR_SKELETON_BASELINE_RESOURCE, False)
        if baseline_asset is None:
            self.report.error(
                "ACTOR_SKELETON_BASELINE_MISSING",
                "原始游戏参考中没有固定 /90 角色骨架，不能安全发布独立骨架。",
                ACTOR_SKELETON_BASELINE_RESOURCE,
            )
            return
        try:
            baseline = parse_fbxskel(
                baseline_asset.path.read_bytes(), ACTOR_SKELETON_BASELINE_RESOURCE
            )
            compare_actor_skeleton_to_baseline(info, baseline, asset.logical)
        except (OSError, ValueError) as error:
            code = self._actor_skeleton_issue_code(error) if isinstance(error, ValueError) else "ACTOR_SKELETON_BASELINE_INVALID"
            self.report.error(
                code,
                f"独立骨架与原始 /90 角色骨架不兼容：{error}",
                asset.logical,
                baselineResource=ACTOR_SKELETON_BASELINE_RESOURCE,
                baselineSha256=getattr(baseline_asset, "sha256", None),
            )
            return
        body_mesh = self._body_mesh_for_actor_skeleton()
        if body_mesh is None:
            self.report.error(
                "ACTOR_SKELETON_BODY_MESH_REQUIRED",
                "独立骨架必须和所选 BODY PFB 依赖图中的 MOD-owned mesh 一起发布，不能猜测身体资源。",
                asset.logical,
            )
            return
        self.actor_skeleton_asset = asset
        self.actor_skeleton_info = info
        self.actor_skeleton_body_mesh = body_mesh
        # Register the source rig as a leaf node so the normal route planner
        # gives it the same private namespace and atomic copy treatment as a
        # mesh/MDF dependency.
        self.nodes[asset.logical.casefold()] = ResourceNode(asset.logical, asset, ())
        self.report.stats["actorSkeleton"] = {
            "source": asset.logical,
            "sourceSha256": info.sha256,
            "baselineResource": ACTOR_SKELETON_BASELINE_RESOURCE,
            "baselineSha256": baseline_asset.sha256,
            "boneCount": info.bone_count,
            "bodyMesh": body_mesh,
            "jointNameOrderVerified": True,
            "parentHierarchyVerified": True,
            "rotationScaleVerified": True,
            "segmentScalingVerified": True,
            "bindPositions": "source",
        }
        self.report.info(
            "ACTOR_SKELETON_VERIFIED",
            "独立角色骨架已通过 /90 拓扑、旋转和缩放核对；休止位置保留为源文件数据。",
            asset.logical,
            boneCount=info.bone_count,
            bodyMesh=body_mesh,
        )

    def _hash_index(self) -> HashIndex | None:
        hash_map = getattr(self.args, "hash_map", None)
        hash_list = getattr(self.args, "hash_list", None)
        if hash_map:
            return HashIndex.from_json(Path(hash_map).resolve(strict=True), self.report)
        if hash_list:
            return HashIndex.from_file(Path(hash_list).resolve(strict=True), self.report)
        # The release package carries the public OWOTS file list.  It is only
        # used for exact hash lookup and never treated as proof that bytes are
        # present in the game directory; the game provider performs that
        # second, read-only verification.
        if self.args.input.suffix.casefold() == ".pak":
            bundled = bundled_file_list()
            if bundled:
                self.report.info("BUNDLED_HASH_LIST", "使用发行包内置 OWOTS 文件列表解析普通 PAK", str(bundled))
                return HashIndex.from_file(bundled, self.report)
        return None

    def _candidates(self) -> list[tuple[str, str]]:
        assert self.bundle
        result = []
        for asset in self.bundle.source.assets.values():
            part = classify_part(asset.logical)
            if part:
                result.append((asset.logical, part))
        return sorted(set(result), key=lambda item: item[0].casefold())

    def _resolve_asset(self, logical: str, streaming: bool = False) -> Asset:
        assert self.bundle
        logical = logical_path(logical)
        mod = self.bundle.source.get(logical, streaming)
        if mod:
            return mod
        if self.game:
            game = self.game.find(logical, streaming)
            if game:
                return game
        raise ConversionError(f"缺少资源：{logical}{' (streaming)' if streaming else ''}")

    def _inspect_node(self, logical: str, asset: Asset) -> ResourceNode:
        extension = PurePosixPath(logical).suffix.casefold()
        if extension in STRUCTURED_EXTENSIONS and self.worker is None:
            raise ConversionError(f"需要 AppearanceRsz 才能安全读取 {logical}")
        dependencies: tuple[str, ...] = ()
        warnings: tuple[dict[str, Any], ...] = ()
        if extension in (".pfb", ".user"):
            selected = self.catalog_selection.get(logical.casefold())
            if selected:
                part, native_id = selected
                expected_prefab = next(
                    (prefab for selected_part, (prefab, catalog, _id) in self.part_roots.items()
                     if selected_part == part and catalog and catalog.casefold() == logical.casefold()),
                    None,
                )
                try:
                    result = self.worker.inspect(asset.path) if self.worker else {}
                    from owots_vendor.workspace.appearance_catalog import read_parts_catalog  # type: ignore
                    records = read_parts_catalog(result, part, logical)
                    chosen = [entry for entry in records
                              if (entry.native_id == native_id if native_id is not None
                                  else expected_prefab is not None and entry.prefab.casefold() == expected_prefab.casefold())]
                except (ImportError, KeyError, TypeError, ValueError, ConversionError) as error:
                    raise ConversionError(f"无法读取 {part} catalog 的 native-id {native_id}：{error}") from error
                if len(chosen) != 1:
                    self.report.error("CATALOG_ROW_AMBIGUOUS", "catalog 中没有唯一匹配的 PFB/原生 ID 行，请检查高级配置", logical,
                                      nativeId=native_id, expectedPrefab=expected_prefab, matches=len(chosen))
                    raise ConversionError(f"{logical} 中没有唯一匹配的 PFB/原生 ID 行")
                if expected_prefab and chosen[0].prefab.casefold() != expected_prefab.casefold():
                    self.report.error(
                        "CATALOG_PREFAB_MISMATCH",
                        "选中的 native-id 行指向的 PFB 与 manifest 目标 PFB 不同，已阻止避免运行时 preload timeout。",
                        logical,
                        nativeId=native_id,
                        expectedPrefab=expected_prefab,
                        selectedPrefab=chosen[0].prefab,
                    )
                    raise ConversionError("catalog 行与 PFB 不匹配：" + logical)
                if native_id is None:
                    native_id = chosen[0].native_id
                    current_prefab, current_catalog, _ = self.part_roots[part]
                    self.part_roots[part] = (current_prefab, current_catalog, native_id)
                    self.catalog_selection[logical.casefold()] = (part, native_id)
                    self.report.info("CATALOG_ID_AUTO", "已按 PFB 在真实 catalog 中唯一确定原生 ID", logical, nativeId=native_id)
                # A PlayerPartsList is a table.  Follow only the selected row;
                # otherwise unrelated installed rows become false dependencies
                # and can force an incomplete reference tree to fail.
                dependencies = (chosen[0].prefab,)
            else:
                result = self.worker.inspect(asset.path) if self.worker else {}
                values = []
                for binding in result.get("Bindings", []):
                    if not isinstance(binding, dict) or not isinstance(binding.get("Path"), str):
                        continue
                    raw = binding["Path"].removeprefix("@")
                    try:
                        values.append(logical_path(raw))
                    except ValueError:
                        self.report.warn("RESOURCE_PATH_IGNORED", "结构化资源含有非逻辑路径引用，已忽略", logical,
                                         value=raw)
                dependencies = tuple(sorted(set(values), key=str.casefold))
            warnings = tuple(result.get("CrcWarnings") or ())
            if warnings:
                self.report.warn("CRC_MISMATCH", "结构化资源存在 RSZ CRC mismatch；默认仍禁止写回，除非显式 --allow-crc-mismatch",
                                 logical, warnings=list(warnings))
        elif extension == ".mdf2":
            dependencies = mdf_dependencies(asset.path.read_bytes())
        else:
            dependencies = _extract_paths(asset.path.read_bytes()) if extension in {".mmi", ".mpi"} else ()
        return ResourceNode(logical, asset, dependencies, warnings)

    def _discover_graph(self, roots: Sequence[str]) -> None:
        pending = [logical_path(path) for path in roots]
        while pending:
            logical = pending.pop()
            key = logical.casefold()
            if key in self.nodes:
                continue
            try:
                asset = self._resolve_asset(logical)
            except ConversionError:
                # A complete Steam install is resolved through the read-only
                # PAK provider.  A missing edge therefore means either a
                # malformed/incomplete reference or a MOD dependency that
                # would be silently lost.  Keep the permissive behavior only
                # behind an explicit diagnostic opt-in.
                assert self.bundle
                if self.bundle.source.get(logical) is not None:
                    raise
                if getattr(self.args, "allow_unverified_game_assets", False):
                    self.report.warn("GAME_ASSET_UNVERIFIED",
                                     "参考目录未提供此依赖；实验选项允许发布包依赖游戏本体/PAK 中的同名资源",
                                     logical)
                elif self.game is None:
                    self.report.error("REQUIRED_DEPENDENCY_MISSING",
                                      "缺少必要依赖；请提供原始游戏目录或完整的 --game-extract",
                                      logical)
                else:
                    self.report.error("GAME_ASSET_MISSING",
                                      "原始游戏 PAK/参考目录中没有此依赖，不能安全外部化",
                                      logical)
                continue
            node = self._inspect_node(logical, asset)
            self.nodes[key] = node
            pending.extend(node.dependencies)
            # Streaming companions are published alongside their base node;
            # they are not a second graph node.  Keeping one logical key avoids
            # two private routes targeting the same manifest resource.
        self.report.stats["graphNodes"] = len(self.nodes)

    def _resolve_optional(self, logical: str, streaming: bool) -> Asset | None:
        assert self.bundle
        mod = self.bundle.source.get(logical, streaming)
        if mod:
            return mod
        return self.game.find(logical, streaming) if self.game else None

    def _select_part_roots(self) -> None:
        assert self.bundle
        if getattr(self.args, "parts_plan", None):
            self._select_planned_part_roots()
            return
        self.auto_native_parts = set()
        category = getattr(self.args, "category", None)
        requested_part = getattr(self.args, "part", None)
        if requested_part:
            requested_part = requested_part.upper()
            if requested_part not in ALL_PARTS:
                raise ConversionError(f"未知部位：{requested_part}")
        explicit_prefab = getattr(self.args, "prefab", None)
        explicit_catalog = getattr(self.args, "catalog", None)
        native_id = getattr(self.args, "native_id", None)
        if explicit_prefab:
            prefab = logical_path(explicit_prefab)
            if not prefab.casefold().endswith(".pfb"):
                raise ConversionError("prefab 必须是无数值版本后缀的 .pfb 逻辑路径")
            part = (getattr(self.args, "part", None) or classify_part(prefab) or "BODY").upper()
            if part not in ALL_PARTS:
                raise ConversionError(f"未知部位：{part}")
            catalog = logical_path(explicit_catalog) if explicit_catalog else None
            if catalog and not catalog.casefold().endswith(".user"):
                raise ConversionError("catalog 必须是无数值版本后缀的 .user 逻辑路径")
            if catalog:
                roles = self._native_catalog_roles()
                known_roles = roles.get(catalog.casefold())
                if not known_roles:
                    self.report.error(
                        "CATALOG_ROLE_UNVERIFIED",
                        "内置原生 catalog 索引中没有此路径，无法确认它的部位角色；请使用索引中的原始 catalog。",
                        catalog,
                        part=part,
                    )
                    raise ConversionError("无法验证 catalog 部位角色：" + catalog)
                if part not in known_roles:
                    self.report.error(
                        "CATALOG_ROLE_MISMATCH",
                        "显式 catalog 的原生部位角色与 --part/原始 PFB 不一致，已阻止。",
                        catalog,
                        expectedPart=part,
                        actualParts=sorted(known_roles),
                    )
                    raise ConversionError("catalog 部位角色不匹配：" + catalog)
            self.part_roots[part] = (prefab, catalog, native_id)
        else:
            auto = self._auto_native_part_roots(category, requested_part)
            if auto:
                self.part_roots.update(auto)
                self.auto_native_parts = set(auto)
            candidates = [(asset.logical, classify_part(asset.logical))
                           for asset in self.bundle.source.assets.values() if not asset.streaming]
            pfbs = [(logical, part) for logical, part in candidates
                    if part and logical.casefold().endswith(".pfb")]
            if not self.part_roots and not pfbs:
                raise ConversionError("未找到 PFB；普通 mesh/texture MOD 需要 --prefab 指定原始游戏 PFB")
            grouped: dict[str, list[str]] = {}
            for logical, part in pfbs:
                if (part and (requested_part is None or part == requested_part) and
                        (category is None or PART_CATEGORY[part] == category)):
                    grouped.setdefault(part, []).append(logical)
            for part, values in sorted(grouped.items()):
                unique = sorted({value.casefold(): value for value in values}.values(), key=str.casefold)
                if len(unique) > 1:
                    self.report.error(
                        "PFB_CANDIDATE_AMBIGUOUS",
                        "同一部位找到多个 PFB 候选，不能把 normal/HQ 或不同变体静默合并。",
                        part,
                        candidates=unique,
                    )
                    continue
                # An auto-indexed root has already been selected from the
                # original game.  Preserve it; source PFBs for other parts
                # still need to be retained when the index is partial.
                if part not in self.part_roots:
                    self.part_roots[part] = (unique[0], None, None)
            if any(issue.code == "PFB_CANDIDATE_AMBIGUOUS" for issue in self.report.errors):
                raise ConversionError("PFB 候选存在部位歧义；请用 --prefab 明确选择")
            if not self.part_roots:
                raise ConversionError("PFB 候选与 --category 不匹配，请用 --part/--prefab 明确选择")
        if category is None:
            category = category_for_parts(tuple(self.part_roots))
        if category not in PARTS:
            raise ConversionError("category 必须是 body、cloak、gauntlet 或 weapon")
        wrong = [part for part in self.part_roots if PART_CATEGORY.get(part) != category]
        if wrong:
            raise ConversionError("选择中包含多个衣橱分类：" + ", ".join(wrong))
        if explicit_catalog and not explicit_prefab:
            raise ConversionError("--catalog 必须和 --prefab 一起使用")
        if native_id is not None and not explicit_catalog:
            raise ConversionError("--native-id 需要 --catalog")
        self.catalog_selection = {
            catalog.casefold(): (part, native_id)
            for part, (_prefab, catalog, native_id) in self.part_roots.items()
            if catalog is not None
        }
        self.args.category = category

    def _select_planned_part_roots(self) -> None:
        """Validate each explicit root through the same single-root contract."""
        original_args = self.args
        if any(getattr(original_args, key, None) is not None
               for key in ("part", "prefab", "catalog", "native_id")):
            raise ConversionError("--parts-plan 不能与单部位选择参数一起使用")
        try:
            plan = json.loads(Path(original_args.parts_plan).read_text(encoding="utf-8-sig"))
        except (OSError, ValueError) as error:
            raise ConversionError("无法读取部位选择计划：" + str(error)) from error
        if not isinstance(plan, dict) or set(plan) != {"parts"}:
            raise ConversionError("部位计划必须为仅包含 parts 数组的 JSON 对象")
        rows = plan["parts"]
        if not isinstance(rows, list) or not rows or len(rows) > len(ALL_PARTS):
            raise ConversionError("parts 必须是非空且长度不超过部位总数的数组")
        selected = {}
        try:
            for row in rows:
                if (not isinstance(row, dict) or set(row) - {"part", "prefab", "catalog", "nativeId"}
                        or not all(isinstance(row.get(key), str) and row[key].strip()
                                   for key in ("part", "prefab", "catalog"))):
                    raise ConversionError("每个计划部位必须包含 part、prefab、catalog；nativeId 可选")
                if "catalog" in row and (not isinstance(row["catalog"], str) or not row["catalog"].strip()):
                    raise ConversionError("计划中的 catalog 必须为非空路径字符串")
                if "nativeId" in row and (type(row["nativeId"]) is not int or row["nativeId"] < 0):
                    raise ConversionError("计划中的 nativeId 必须为非负整数")
                part = row["part"].upper()
                if part in selected:
                    raise ConversionError("部位计划重复选择了 " + part)
                self.args = argparse.Namespace(**vars(original_args))
                self.args.parts_plan = None
                self.args.part, self.args.prefab = part, row["prefab"]
                self.args.catalog, self.args.native_id = row.get("catalog"), row.get("nativeId")
                self.part_roots = {}
                self._select_part_roots()
                selected.update(self.part_roots)
            category = category_for_parts(tuple(selected))
            if original_args.category is not None and original_args.category != category:
                raise ConversionError("部位计划与指定分类不一致")
            catalogs = [catalog.casefold() for _, catalog, _ in selected.values() if catalog]
            if len(catalogs) != len(set(catalogs)):
                raise ConversionError("不同部位不能共享同一个 catalog")
        finally:
            self.args = original_args
            self.part_roots = {}
            self.catalog_selection = {}
        self.part_roots = selected
        self.auto_native_parts = set()
        self.catalog_selection = {catalog.casefold(): (part, native_id)
                                  for part, (_, catalog, native_id) in selected.items() if catalog}
        self.args.category = category
        self.report.info("EXPLICIT_PARTS_PLAN", "使用经过逐部位校验的显式转换计划",
                         str(original_args.parts_plan), parts=list(selected))

    def _native_catalog_roles(self) -> dict[str, set[str]]:
        """Load exact catalog→part roles from the bundled native index."""
        index_path = Path(__file__).resolve().parent / "runtime" / "owots_native_parts.json"
        try:
            value = json.loads(index_path.read_text(encoding="utf-8"))
            records = value["records"]
        except (OSError, json.JSONDecodeError, KeyError, TypeError):
            return {}
        roles: dict[str, set[str]] = {}
        for record in records if isinstance(records, list) else ():
            if not isinstance(record, dict):
                continue
            catalog = record.get("catalog")
            part = str(record.get("part", "")).upper()
            if not isinstance(catalog, str) or part not in ALL_PARTS:
                continue
            try:
                normalized = logical_path(catalog)
            except ValueError:
                continue
            roles.setdefault(normalized.casefold(), set()).add(part)
        return roles

    def _verify_auto_part_graph(self) -> None:
        """Ensure every auto-selected PFB actually reaches MOD geometry/material.

        The native index is only a filename candidate source.  This second
        check follows the selected PFB dependency graph and requires a MOD
        owned mesh or MDF2 node for each automatically selected part, avoiding
        a false success when a similarly named native prefab was selected.
        """
        assert self.bundle
        if not self.auto_native_parts:
            return
        source_assets = {
            asset.logical.casefold(): asset
            for asset in self.bundle.source.assets.values()
            if not asset.streaming
        }
        checks: dict[str, Any] = {}
        for part in sorted(self.auto_native_parts):
            roots = self.part_roots.get(part)
            if not roots:
                continue
            prefab, _catalog, _native_id = roots
            reachable: set[str] = set()
            pending = [prefab.casefold()]
            while pending:
                key = pending.pop()
                if key in reachable:
                    continue
                reachable.add(key)
                node = self.nodes.get(key)
                if node:
                    pending.extend(dep.casefold() for dep in node.dependencies)
            matched = [asset for key, asset in source_assets.items() if key in reachable]
            geometry = [asset for asset in matched if asset.extension in {".mesh", ".mdf2"}]
            checks[part] = {
                "prefab": prefab,
                "reachableNodes": len(reachable),
                "matchedModResources": [asset.logical for asset in sorted(matched, key=lambda item: item.logical.casefold())],
                "matchedGeometryMaterial": [asset.logical for asset in sorted(geometry, key=lambda item: item.logical.casefold())],
            }
            if not geometry:
                self.report.error(
                    "NATIVE_PART_NO_MATCH",
                    "自动选择的原生 PFB 依赖图没有引用输入 MOD 的 mesh/MDF2；为避免错误部位转换，已阻止。",
                    prefab,
                    part=part,
                    sourceCandidates=[asset.logical for asset in source_assets.values()],
                )
        self.report.stats["autoPartDependencyChecks"] = checks

    def _auto_native_part_roots(self, requested_category: str | None,
                                requested_part: str | None = None) -> dict[str, tuple[str, str, int]]:
        """Infer native prefab/catalog/id from the bundled observed index.

        Filename matching is only a candidate filter.  The selected bytes are
        still resolved through GameReference (or the game PAK provider), and
        equal-looking candidates with different IDs remain an explicit
        ambiguity instead of a silent choice.
        """
        assert self.bundle
        candidates = [Path(__file__).resolve().parent / "runtime" / "owots_native_parts.json"]
        index_path = next((path for path in candidates if path.is_file()), None)
        if not index_path:
            return {}
        try:
            records = json.loads(index_path.read_text(encoding="utf-8"))["records"]
        except (OSError, json.JSONDecodeError, KeyError, TypeError) as error:
            self.report.warn("NATIVE_INDEX_UNAVAILABLE", f"原生部位索引读取失败：{error}", str(index_path))
            return {}
        stems = []
        for asset in self.bundle.source.assets.values():
            if asset.streaming or asset.extension not in {".mesh", ".mdf2", ".pfb"}:
                continue
            name = PurePosixPath(asset.logical).name.casefold()
            stem = name.split(".", 1)[0]
            stem = re.sub(r"(?:_hq|_normal|_high|_low)$", "", stem)
            if len(stem) >= 5:
                stems.append(stem)
        if not stems:
            return {}
        matches: list[dict[str, Any]] = []
        for record in records if isinstance(records, list) else ():
            if not isinstance(record, dict):
                continue
            part = str(record.get("part", "")).upper()
            category = PART_CATEGORY.get(part)
            prefab = record.get("prefab")
            catalog = record.get("catalog")
            native = record.get("native_id")
            if (not category or requested_category and category != requested_category or
                    requested_part and part != requested_part):
                continue
            if not isinstance(prefab, str) or not isinstance(catalog, str) or type(native) is not int:
                continue
            base = PurePosixPath(prefab.replace("\\", "/")).name.casefold()
            if base.endswith(".pfb"):
                base_stem = base[:-4]
            else:
                base_stem = base
            base_stem = re.sub(r"_hq$", "", base_stem)
            # Match a complete model stem.  A loose substring would conflate
            # ch001_00_00 with ch001_00_00_AC and incorrectly merge variants.
            if any(stem == base_stem for stem in stems):
                matches.append({"part": part, "category": category, "prefab": logical_path(prefab),
                                "catalog": logical_path(catalog), "native_id": native,
                                "variant": str(record.get("variant", "normal")).casefold()})
        normals = [record for record in matches if record["variant"] in {"normal", "base", ""}]
        if not normals:
            normals = matches
        by_part: dict[str, list[dict[str, Any]]] = {}
        for record in normals:
            by_part.setdefault(record["part"], []).append(record)
        result: dict[str, tuple[str, str, int]] = {}
        for part, values in sorted(by_part.items()):
            unique = {(value["prefab"].casefold(), value["catalog"].casefold(), value["native_id"]): value
                      for value in values}
            if len(unique) != 1:
                self.report.error("NATIVE_PART_AMBIGUOUS",
                                  "自动部位检测找到多个不同原生候选；请用 --prefab/--catalog/--native-id 明确选择",
                                  part, candidates=list(unique))
                continue
            value = next(iter(unique.values()))
            result[part] = (value["prefab"], value["catalog"], value["native_id"])
            self.report.info("NATIVE_PART_AUTO", "根据只读原生部位索引自动选择 prefab/catalog/native-id",
                             value["prefab"], part=part, catalog=value["catalog"], nativeId=value["native_id"])
        return result

    def _prepare_game(self) -> None:
        root = getattr(self.args, "game_root", None)
        extract = getattr(self.args, "game_extract", None)
        if extract:
            self.game = GameReference(Path(extract), self.report)
        elif root:
            root_path = Path(root).resolve(strict=True)
            provider = None
            explicit_list = getattr(self.args, "hash_list", None)
            list_path = Path(explicit_list).resolve(strict=True) if explicit_list else bundled_file_list()
            has_game_paks = any(root_path.glob("re_chunk_*.pak"))
            if has_game_paks and list_path and GamePakReference is not None:
                try:
                    provider = GamePakReference(root_path, list_path, self.report)
                    self.report.info("GAME_PAK_PROVIDER", "已启用原始游戏 PAK 只读按需取档", str(root_path))
                except (ImportError, OSError, ValueError, RuntimeError) as error:
                    self.report.error("GAME_PAK_PROVIDER_FAILED", f"原始游戏 PAK 参考初始化失败：{error}", str(root_path))
            # ``--game-root`` means the original Steam install.  Loose
            # extracted trees are intentionally accepted only through the
            # explicitly named ``--game-extract`` option.
            self.game = GameReference(root_path, self.report, provider, allow_loose=False)
            if has_game_paks and provider is None:
                self.report.error(
                    "GAME_PAK_PROVIDER_REQUIRED",
                    "原始游戏 PAK 只读参考不可用；请把 OWOTS_STM_Release.list 放在 EXE 旁或使用 --game-extract。",
                    str(root_path),
                )
            elif not has_game_paks:
                self.report.error(
                    "GAME_ROOT_PAK_MISSING",
                    "--game-root 应指向原始 Steam 安装目录；解包目录请改用 --game-extract。",
                    str(root_path),
                )

    def close(self) -> None:
        if self.game:
            self.game.close()

    def _compute_routes(self) -> None:
        # Required wardrobe roots are always independent.  Every ancestor that
        # points to a MOD-owned asset becomes independent by fixed point.
        required = {logical.casefold() for prefab, catalog, _id in self.part_roots.values()
                    for logical in ((prefab,) + ((catalog,) if catalog else ()))}
        changed = {key for key, node in self.nodes.items() if node.asset.origin == "mod"}
        private = set(required) | changed
        while True:
            parents = {key for key, node in self.nodes.items()
                       if any(dep.casefold() in private for dep in node.dependencies)}
            expanded = private | parents
            if expanded == private:
                break
            private = expanded
        self.private = private
        identity = safe_id(getattr(self.args, "mod_id", None) or
                           (self.modinfo.values.get("name") if self.modinfo else None) or self.args.input.stem)
        used: set[str] = set()
        for key in sorted(private):
            node = self.nodes.get(key)
            if not node:
                continue
            digest = hashlib.sha256(node.logical.casefold().encode()).hexdigest()[:16]
            target = f"mods/{identity}/{digest}/{PurePosixPath(node.logical).name}"
            if target.casefold() in used:
                raise ConversionError("独立资源输出路径冲突：" + target)
            used.add(target.casefold())
            self.routes[key] = target
        self.report.stats["privateResources"] = len(self.routes)
        self.report.stats["sharedResources"] = len(self.nodes) - len(self.routes)

    def _audit_unconsumed_mod_assets(self) -> None:
        """Make extra model assets visible instead of silently dropping them."""
        assert self.bundle
        consumed = {node.asset.logical.casefold() for node in self.nodes.values()
                    if node.asset.origin == "mod"}
        unconsumed: list[Asset] = []
        for asset in self.bundle.source.assets.values():
            if asset.streaming and asset.logical.casefold() in consumed:
                continue  # published with the consumed base texture
            if asset.logical.casefold() not in consumed:
                unconsumed.append(asset)
        self.report.stats["unconsumedModResources"] = [
            physical_for(asset.logical, asset.version, asset.streaming) for asset in unconsumed
        ]
        allow = bool(getattr(self.args, "allow_unconsumed_resources", False))
        strict_compat = bool(getattr(self.args, "strict_unconsumed", False))
        for asset in unconsumed:
            location = physical_for(asset.logical, asset.version, asset.streaming)
            if asset.extension == ".fbxskel":
                # Actor rigs are diagnosed by _inspect/_prepare_actor_skeleton
                # with a more specific reason (invalid binary, 264-joint
                # topology, missing BODY, or missing baseline).  Do not add a
                # second generic adapter error for the same candidate.  The
                # direct unit-level audit path keeps the legacy guard when no
                # candidate analysis has been run yet.
                if asset.logical.casefold() in self.actor_skeleton_keys:
                    continue
                message = ("独立骨架未被所选部位引用；静态衣橱不会自动替换角色根骨架，"
                           "体型可能保持游戏原始比例。需要专用骨架适配并验证实际关节位置")
                if strict_compat or not allow:
                    self.report.error("ACTOR_SKELETON_ADAPTER_REQUIRED", message, location)
                else:
                    self.report.warn("ACTOR_SKELETON_ADAPTER_REQUIRED",
                                     message + "（显式实验选项仅允许静态候选，未迁移独立骨架）",
                                     location)
            elif asset.extension in STRUCTURED_EXTENSIONS | {".mesh", ".tex"}:
                message = "MOD 中的模型/材质资源未被当前部位依赖图消费；请增加部位或选择变体"
                if strict_compat or not allow:
                    self.report.error("UNCONSUMED_MOD_RESOURCE", message, location)
                else:
                    self.report.warn("UNCONSUMED_MOD_RESOURCE",
                                     message + "（实验选项允许继续，资源仍不会静默复制）", location)
            else:
                if strict_compat:
                    self.report.error("UNCONSUMED_MOD_RESOURCE",
                                      "MOD 中的附属资源未被当前部位依赖图消费，未静默复制",
                                      location)
                else:
                    self.report.warn("UNCONSUMED_MOD_RESOURCE",
                                     "MOD 中的附属资源未被当前部位依赖图消费，未静默复制",
                                     location)

    def _copy_or_rewrite(self, node: ResourceNode, destination: Path,
                         remap: Mapping[str, str], selection: int | None,
                         payload_override: bytes | None = None) -> dict[str, Any] | None:
        source = node.asset.path
        extension = node.asset.extension
        if extension in (".pfb", ".user"):
            if self.worker is None:
                raise ConversionError(f"需要 AppearanceRsz 重写 {node.logical}")
            return self.worker.rewrite(source, destination, remap,
                                       bool(getattr(self.args, "allow_crc_mismatch", False)), selection)
        payload = source.read_bytes() if payload_override is None else payload_override
        if extension == ".mdf2" and remap:
            try:
                from owots_vendor.workspace.appearance_mdf import rewrite_textures  # type: ignore
                payload = rewrite_textures(payload, dict(remap))
            except (ImportError, OSError, ValueError, KeyError, IndexError, struct.error) as error:
                raise ConversionError(f"MDF2 纹理路径无法严格重写：{node.logical}：{error}") from error
        destination.parent.mkdir(parents=True, exist_ok=True)
        with destination.open("xb") as stream:
            stream.write(payload)
        return None

    def _publish_preview(self, package_root: Path, identity: str) -> str | None:
        if not self.modinfo or not self.modinfo.screenshot:
            return None
        image = self.modinfo.screenshot
        if image.stat().st_size > 4 * 1024 * 1024:
            self.report.warn("ICON_TOO_LARGE", "预览图超过 4 MiB，已省略", str(image))
            return None
        if image.suffix.casefold() not in {".png", ".jpg", ".jpeg"}:
            return None
        destination = package_root / "reframework" / "data" / "owots_appearance_lab" / "mods" / identity / ("preview" + image.suffix.lower())
        destination.parent.mkdir(parents=True, exist_ok=True)
        with destination.open("xb") as stream:
            stream.write(image.read_bytes())
        return f"preview{image.suffix.lower()}"

    def _actor_skeleton_manifest(self, identity: str) -> dict[str, Any] | None:
        """Build the schema-1 skeleton object from verified source bytes."""
        if self.actor_skeleton_mesh_only:
            body_mesh = self.routes.get((self.actor_skeleton_body_mesh or "").casefold())
            names = self.actor_skeleton_joint_names
            if not body_mesh or not names:
                return None
            if not body_mesh.casefold().startswith(f"mods/{identity.casefold()}/"):
                raise ConversionError("BODY mesh 输出路径未位于 MOD 私有命名空间")
            # No `resource` and no `bindPositions`: the runtime reads the equipped
            # BODY mesh's own skeleton rest for the authored shape.
            return {
                "schemaVersion": 1,
                "kind": "actor-fbxskel-v1",
                "bodyMesh": body_mesh,
                "jointNames": list(names),
                "baselineResource": ACTOR_SKELETON_BASELINE_RESOURCE,
            }
        if self.actor_skeleton_asset is None or self.actor_skeleton_info is None:
            return None
        resource = self.routes.get(self.actor_skeleton_asset.logical.casefold())
        body_mesh = self.routes.get((self.actor_skeleton_body_mesh or "").casefold())
        if not resource or not body_mesh:
            raise ConversionError("独立骨架或 BODY mesh 未能分配私有输出路径")
        if not resource.casefold().startswith(f"mods/{identity.casefold()}/"):
            raise ConversionError("独立骨架输出路径未位于 MOD 私有命名空间")
        if not body_mesh.casefold().startswith(f"mods/{identity.casefold()}/"):
            raise ConversionError("独立骨架 BODY mesh 输出路径未位于 MOD 私有命名空间")
        info = self.actor_skeleton_info
        return {
            "schemaVersion": 1,
            "kind": "actor-fbxskel-v1",
            "resource": resource,
            "bodyMesh": body_mesh,
            "jointNames": list(info.names),
            "bindPositions": info.bind_positions(),
            "baselineResource": ACTOR_SKELETON_BASELINE_RESOURCE,
        }

    def convert(self, output: Path) -> None:
        output = output.resolve()
        input_path = self.args.input.resolve()
        forbidden = [input_path]
        for option in ("game_root", "game_extract"):
            value = getattr(self.args, option, None)
            if value:
                forbidden.append(Path(value).resolve())
        for root in forbidden:
            if output == root or output.is_relative_to(root):
                raise ConversionError("输出目录不能与输入或只读参考目录相同/位于其中")
        if output.exists():
            raise ConversionError("输出目录已存在；为避免覆盖，请换一个新路径")
        self.modinfo = parse_modinfo(self.args.input.resolve(), self.report) if self.args.input.is_dir() else None
        self._prepare_game()
        index = self._hash_index()
        self.bundle = InputBundle(self.args.input, self.report, index)
        self.bundle.load()
        self._audit_dynamic_behavior()
        if self.report.errors:
            raise ConversionError("输入诊断存在阻止性错误；请先处理报告中的 error")
        self._select_part_roots()
        if self.game is None and getattr(self.args, "game_root", None):
            self._prepare_game()
        self._discover_graph([item for values in self.part_roots.values() for item in values[:2] if item])
        self._prepare_actor_skeleton()
        self._prepare_mesh_actor_skeleton()
        self._verify_auto_part_graph()
        self._compute_routes()
        self._audit_unconsumed_mod_assets()
        if self.report.errors:
            raise ConversionError("依赖图存在阻止性错误")
        identity = safe_id(getattr(self.args, "mod_id", None) or
                           (self.modinfo.values.get("name") if self.modinfo else None) or self.args.input.stem)
        staging_parent = output.resolve().parent
        staging_parent.mkdir(parents=True, exist_ok=True)
        staging = Path(tempfile.mkdtemp(prefix=output.name + ".staging-", dir=staging_parent))
        try:
            manifest_parts: list[dict[str, str]] = []
            for part, (prefab, catalog, native_id) in sorted(self.part_roots.items()):
                if prefab.casefold() not in self.routes:
                    raise ConversionError(f"原始 PFB 未能从参考目录/PAK 读取：{prefab}")
                prefab_target = self.routes[prefab.casefold()]
                catalog_target = None
                if catalog:
                    if catalog.casefold() not in self.routes:
                        raise ConversionError(f"原始 catalog USER 未能从参考目录/PAK 读取：{catalog}")
                    catalog_target = self.routes[catalog.casefold()]
                else:
                    self.report.warn("CATALOG_REQUIRED", f"{part} 没有独立 catalog；请在导出前提供 --catalog", prefab)
                    raise ConversionError(f"{part} 需要 --catalog 才能生成可识别衣橱条目")
                manifest_parts.append({"part": part, "catalog": catalog_target, "prefab": prefab_target})
            # First write all private nodes.  Every remap is based on the
            # final logical path, never a versioned physical filename.
            for key in sorted(self.routes):
                node = self.nodes[key]
                target = self.routes[key]
                remap = {dep: self.routes[dep.casefold()] for dep in node.dependencies if dep.casefold() in self.routes}
                selection = None
                for _part, (_prefab, catalog, native_id) in self.part_roots.items():
                    if catalog and catalog.casefold() == key:
                        selection = native_id
                variants: list[Asset] = [node.asset]
                base_override: bytes | None = None
                # The selected provider owns the base asset.  A complete
                # streaming companion from that same provider is included;
                # this preserves HQ textures and never mixes a MOD base with a
                # game streaming tail.
                if node.asset.extension == ".tex":
                    companion = self.bundle.source.get(node.logical, True) if self.bundle and node.asset.origin == "mod" else None
                    if companion is None and self.game and node.asset.origin == "game":
                        companion = self.game.find(node.logical, True)
                    if companion:
                        variants.append(companion)
                        try:
                            from texture_resolution import promote_texture_base  # type: ignore
                            base_override, decision = promote_texture_base(
                                node.asset.path.read_bytes(), companion.path.read_bytes())
                            summary = {
                                "logical": node.logical,
                                "promoted": bool(decision.get("promoted")),
                                "decision": decision.get("decision"),
                                "reasons": list(decision.get("reasons", ())),
                                "baseResolution": [decision.get("base", {}).get("width"),
                                                    decision.get("base", {}).get("height")],
                                "streamingResolution": [decision.get("streaming", {}).get("width"),
                                                         decision.get("streaming", {}).get("height")],
                            }
                            self.report.stats.setdefault("texturePromotions", []).append(summary)
                            self.report.info(
                                "TEXTURE_RESOLUTION",
                                "已检查 base/streaming 纹理；安全时用完整高清 companion 作为 base",
                                node.logical,
                                promoted=summary["promoted"],
                                reasons=summary["reasons"],
                            )
                        except (ImportError, OSError, ValueError, KeyError, TypeError) as error:
                            # The original bytes remain the safe fallback if
                            # the optional structural inspector is unavailable.
                            base_override = None
                            self.report.warn("TEXTURE_RESOLUTION_CHECK_FAILED",
                                             f"高清纹理结构检查失败，保留原 base：{error}", node.logical)
                seen_variants: set[tuple[str, bool]] = set()
                for asset in variants:
                    marker = (str(asset.path).casefold(), asset.streaming)
                    if marker in seen_variants:
                        continue
                    seen_variants.add(marker)
                    physical = staging / physical_for(target, asset.version, asset.streaming)
                    variant_node = node if not asset.streaming else ResourceNode(node.logical, asset, (), ())
                    self._copy_or_rewrite(variant_node, physical,
                                          remap if not asset.streaming else {},
                                          selection if not asset.streaming else None,
                                          base_override if not asset.streaming else None)
            icon = self._publish_preview(staging, identity)
            description = self.modinfo.values.get("description", "") if self.modinfo else ""
            author = self.modinfo.values.get("author", "") if self.modinfo else ""
            name = self.modinfo.values.get("name", identity) if self.modinfo else identity
            hide_parts = [str(part).upper() for part in (getattr(self.args, "hide_parts", ()) or ())]
            incompatible_categories = [
                str(category).casefold()
                for category in (getattr(self.args, "incompatible_categories", ()) or ())
            ]
            if (len(set(hide_parts)) != len(hide_parts) or
                    any(part not in ALL_PARTS for part in hide_parts) or
                    any(part in self.part_roots for part in hide_parts)):
                raise ConversionError("--hide-part 不能重复、未知或隐藏当前 manifest 已提供的部位")
            if (len(set(incompatible_categories)) != len(incompatible_categories) or
                    any(category not in PARTS or category == self.args.category
                        for category in incompatible_categories)):
                raise ConversionError("--incompatible-category 不能重复、未知或等于当前分类")
            manifest = {
                "schemaVersion": SCHEMA_VERSION, "id": identity, "name": name,
                "category": self.args.category, "parts": manifest_parts,
                "rules": {
                    "hideParts": hide_parts,
                    "incompatibleCategories": incompatible_categories,
                },
                "description": description, "author": author,
            }
            skeleton = self._actor_skeleton_manifest(identity)
            if skeleton:
                manifest["skeleton"] = skeleton
            if icon:
                manifest["icon"] = icon
            manifest_path = staging / "reframework" / "data" / "owots_appearance_lab" / "mods" / identity / "manifest.json"
            manifest_path.parent.mkdir(parents=True, exist_ok=True)
            with manifest_path.open("x", encoding="utf-8", newline="\n") as stream:
                json.dump(manifest, stream, ensure_ascii=False, indent=2)
                stream.write("\n")
            self.report.stats["manifest"] = str(manifest_path.relative_to(staging)).replace("\\", "/")
            self.report.status = "converted"
            self._write_reports(staging)
            if output.exists():
                raise ConversionError("输出目录已存在；为避免覆盖，请换一个空路径")
            staging.rename(output)
        except Exception:
            shutil.rmtree(staging, ignore_errors=True)
            raise

    def _write_reports(self, root: Path) -> None:
        report_json = root / "conversion-report.json"
        report_json.write_text(json.dumps(self.report.as_dict(), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        report_md = root / "CONVERSION-REPORT.md"
        lines = ["# OWOTS 衣橱转换报告", "", f"状态：`{self.report.status}`", "", "## 处理结果", ""]
        for issue in self.report.issues:
            location = f"（{issue.path}）" if issue.path else ""
            lines.append(f"- **{issue.severity}** `{issue.code}`：{issue.message}{location}")
        report_md.write_text("\n".join(lines) + "\n", encoding="utf-8")


def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="mod_converter",
        description="OWOTS 普通 MOD → 四分类独立衣橱 MOD 转换器（安全解包、依赖闭包、严格报告）",
    )
    sub = parser.add_subparsers(dest="command", required=True)
    inspect = sub.add_parser("inspect", help="只读扫描输入，输出诊断报告")
    convert = sub.add_parser("convert", help="转换为可安装的衣橱 MOD 包")
    for command in (inspect, convert):
        command.add_argument("--input", type=Path, required=True, help="松散 MOD 目录或普通 .pak 文件")
        command.add_argument("--hash-list", type=Path, help="可信 OWOTS_STM_Release.list")
        command.add_argument("--hash-map", type=Path, help="作者/用户提供的 JSON hash→natives/stm 路径映射")
        command.add_argument("--game-root", type=Path, help="只读原始游戏/解包参考目录")
        command.add_argument("--game-extract", type=Path, help="只读、已解包的 natives/stm 参考目录（优先于 game-root）")
        command.add_argument("--worker", type=Path, help="AppearanceRsz.exe 或 .dll")
        command.add_argument("--template", type=Path, help="RSZ 模板 JSON")
    inspect.add_argument("--report", type=Path, help="将只读检查 JSON 写入新文件（不覆盖已有文件）")
    convert.add_argument("--output", type=Path, required=True, help="新建输出目录（已存在时拒绝覆盖）")
    convert.add_argument("--id", dest="mod_id", help="稳定 MOD ID；默认从 modinfo/name 推断")
    convert.add_argument("--category", choices=tuple(PARTS), help="body/cloak/gauntlet/weapon")
    convert.add_argument("--part", help="部位，例如 BODY、HEAD、HAIR、CLOAK、WEAPON")
    convert.add_argument("--prefab", help="原始游戏 PFB 的逻辑路径（无版本后缀）")
    convert.add_argument("--catalog", help="原始游戏 PlayerPartsList USER 的逻辑路径（无版本后缀）")
    convert.add_argument("--native-id", type=int, help="目录中要选用的原生 ID；不填写则按 PFB 唯一匹配")
    convert.add_argument("--parts-plan", help="JSON 部位选择计划，用于配套的多个 PFB；与单部位参数互斥")
    convert.add_argument("--allow-crc-mismatch", action="store_true",
                         help="实验选项：允许 worker 对已报告 CRC mismatch 的 PFB/USER 写回；报告会明确标记")
    convert.add_argument("--strict-unconsumed", action="store_true",
                         help="兼容旧参数：把所有未消费资源视为错误（模型/材质默认已严格阻止）")
    convert.add_argument("--allow-unconsumed-resources", action="store_true",
                         help="实验选项：允许未消费的模型/材质继续（报告列出且不会静默复制）")
    convert.add_argument("--experimental-static-only", action="store_true",
                         help="实验选项：明确接受省略 Lua/原生插件的静态转换，不声称动态行为等价")
    convert.add_argument("--allow-unverified-game-assets", action="store_true",
                         help="实验选项：允许不完整参考目录中的未验证依赖由游戏本体提供（报告会标记）")
    convert.add_argument("--hide-part", dest="hide_parts", action="append",
                         choices=tuple(sorted(ALL_PARTS)),
                         help="写入 manifest rules.hideParts；可重复指定多个部位")
    convert.add_argument("--incompatible-category", dest="incompatible_categories", action="append",
                         choices=tuple(PARTS),
                         help="写入 manifest rules.incompatibleCategories；可重复指定多个分类")
    return parser


def _write_blocked_report(report: Report, requested_output: Path,
                          forbidden_roots: Sequence[Path]) -> Path | None:
    """Write diagnostics only into a newly created directory.

    A requested output may already contain a valid package.  In that case a
    failed retry must never replace its reports, so diagnostics are placed in
    a new sibling directory with a unique temporary suffix.  An output nested
    under the input is rejected without creating anything beside the source.
    """
    output = requested_output.resolve()
    for root in forbidden_roots:
        if output == root or output.is_relative_to(root):
            return None
    try:
        if output.exists():
            output.parent.mkdir(parents=True, exist_ok=True)
            report_dir = Path(tempfile.mkdtemp(prefix=output.name + ".blocked-", dir=str(output.parent)))
        else:
            output.parent.mkdir(parents=True, exist_ok=True)
            output.mkdir()
            report_dir = output
        report_json = report_dir / "conversion-report.json"
        report_json.write_text(json.dumps(report.as_dict(), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        report_md = report_dir / "CONVERSION-REPORT.md"
        report_md.write_text(
            "# OWOTS 衣橱转换报告\n\n状态：`blocked`\n\n" +
            "\n".join(f"- **{i.severity}** `{i.code}`：{i.message}" for i in report.issues) + "\n",
            encoding="utf-8",
        )
        report.stats["blockedReport"] = str(report_dir)
        return report_dir
    except OSError:
        return None


def run(args: argparse.Namespace) -> int:
    input_path = args.input.resolve()
    forbidden_roots = [input_path]
    for option in ("game_root", "game_extract"):
        value = getattr(args, option, None)
        if value:
            forbidden_roots.append(Path(value).resolve())
    report = Report(args.command, input_path)
    converter: Converter | None = None
    try:
        if not input_path.exists():
            raise ConversionError(f"输入不存在：{input_path}")
        converter = Converter(args, report)
        if args.command == "inspect":
            converter.inspect()
            report.status = "blocked" if report.errors else "inspected"
            output = getattr(args, "report", None)
            if output:
                report_path = Path(output).resolve()
                if any(report_path == root or report_path.is_relative_to(root)
                       for root in forbidden_roots):
                    raise ConversionError("检查报告不能写入输入或只读参考目录")
                report_path.parent.mkdir(parents=True, exist_ok=True)
                report_path.write_text(json.dumps(report.as_dict(), ensure_ascii=False, indent=2) + "\n",
                                       encoding="utf-8")
            else:
                print(json.dumps(report.as_dict(), ensure_ascii=False, indent=2))
            return 2 if report.errors else 0
        converter.convert(args.output.resolve())
        print(json.dumps(report.as_dict(), ensure_ascii=False, indent=2))
        return 0
    except (ConversionError, OSError, ValueError) as error:
        report.error("CONVERSION_BLOCKED", str(error))
        report.status = "blocked"
        if args.command == "convert" and getattr(args, "output", None):
            output = args.output.resolve()
            # A blocked PAK still gets a report, but no manifest or extracted
            # bytes.  If output already exists, use a new sibling report
            # directory so a valid package can never be overwritten.
            _write_blocked_report(report, output, forbidden_roots)
        print(json.dumps(report.as_dict(), ensure_ascii=False, indent=2), file=sys.stderr)
        return 2
    finally:
        if converter is not None:
            converter.close()


if __name__ == "__main__":
    raise SystemExit(run(make_parser().parse_args()))
