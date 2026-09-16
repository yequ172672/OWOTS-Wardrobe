"""Offline validator for the small YoRHa 2B skeleton companion.

This module never opens the game installation and never executes Lua.  It
checks ZIP safety, exact routes, and the byte structure of the two copied
FBXSKEL files.  It is also imported by the companion builder and the offline
regression tests.
"""

from __future__ import annotations

import hashlib
import json
import re
import struct
import zipfile
from pathlib import Path
from typing import Iterable


ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "manifest" / "yorha-2b-skeleton-manifest.json"
EXPECTED_SOURCE_SHA256 = "18e1eb5a76ed853187e708769263da7db8e7701d07d43d5fce3f2e86143c52fb"
EXPECTED_BONE_COUNT = 93
EXPECTED_VERSION = 7
EXPECTED_ASSET_FILES = {
    "reframework/autorun/yorha_2b_skeleton_adapter.lua",
    "manifest/yorha-2b-skeleton-manifest.json",
    "native-api-contract.json",
    "README-zh-CN.md",
    "natives/stm/mods/yorha_2b_base_static/dynamic/rig.fbxskel.7",
    "natives/stm/mods/yorha_2b_alternate_static/dynamic/rig.fbxskel.7",
}
REQUIRED_JOINTS = {
    "root",
    "COG",
    "Hip",
    "Spine_0",
    "Spine_1",
    "Spine_2",
    "Chest_Mark",
    "Neck_0",
    "Neck_1",
    "Head",
    "L_Shoulder",
    "L_UpperArm",
    "L_Forearm",
    "L_Hand",
    "R_Shoulder",
    "R_UpperArm",
    "R_Forearm",
    "R_Hand",
    "L_Thigh",
    "L_Knee",
    "L_Shin",
    "R_Thigh",
    "R_Knee",
    "R_Shin",
}


def _manifest() -> dict:
    return json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def normalize_member(name: str) -> str:
    return name.replace("\\", "/")


def validate_member_name(name: str) -> str:
    if not isinstance(name, str) or not name or "\x00" in name:
        raise ValueError(f"invalid ZIP member name: {name!r}")
    # Reject the original spelling before normalization.  Silently stripping
    # a leading slash would turn an absolute path into an apparently safe one;
    # colon rejection also covers Windows drives and NTFS ADS names.
    if name.startswith(("/", "\\")) or re.match(r"^[A-Za-z]:", name) or ":" in name:
        raise ValueError(f"absolute/ADS ZIP member: {name!r}")
    normalized = normalize_member(name)
    if normalized.startswith("/") or re.match(r"^[A-Za-z]:", normalized):
        raise ValueError(f"absolute ZIP member: {name!r}")
    parts = normalized.split("/")
    if any(not part or part == "." or part == ".." for part in parts):
        raise ValueError(f"unsafe ZIP member: {name!r}")
    return normalized


def _decode_utf16_name(data: bytes, offset: int) -> str:
    end = offset
    while end + 1 < len(data):
        if data[end : end + 2] == b"\x00\x00":
            return data[offset:end].decode("utf-16-le")
        end += 2
    raise ValueError("unterminated FBXSKEL name")


def inspect_fbxskel(data: bytes) -> dict:
    """Return and validate the stable v7 FBXSKEL header, table and names."""

    if len(data) < 48:
        raise ValueError("FBXSKEL header is truncated")
    version, magic = struct.unpack_from("<II", data, 0)
    bone_offset = struct.unpack_from("<I", data, 16)[0]
    hash_offset = struct.unpack_from("<I", data, 24)[0]
    bone_count = struct.unpack_from("<I", data, 32)[0]
    if magic != 1852599155:
        raise ValueError(f"unexpected FBXSKEL magic: {magic:#x}")
    if version != EXPECTED_VERSION:
        raise ValueError(f"unexpected FBXSKEL version: {version}")
    if bone_count != EXPECTED_BONE_COUNT:
        raise ValueError(f"unexpected FBXSKEL bone count: {bone_count}")
    table_end = bone_offset + bone_count * 64
    hash_end = hash_offset + bone_count * 8
    if not (48 <= bone_offset <= len(data) and table_end <= len(data) and hash_end <= len(data)):
        raise ValueError("FBXSKEL table exceeds file boundary")
    names: list[str] = []
    parent_indices: list[int] = []
    for index in range(bone_count):
        entry = bone_offset + index * 64
        name_offset = struct.unpack_from("<Q", data, entry)[0]
        if name_offset < hash_end or name_offset >= len(data):
            raise ValueError(f"FBXSKEL name offset out of range at bone {index}")
        names.append(_decode_utf16_name(data, name_offset))
        parent_indices.append(struct.unpack_from("<h", data, entry + 12)[0])
    if len(set(names)) != len(names):
        raise ValueError("FBXSKEL contains duplicate joint names")
    if not REQUIRED_JOINTS.issubset(names):
        missing = sorted(REQUIRED_JOINTS.difference(names))
        raise ValueError(f"FBXSKEL is missing required joints: {missing}")
    if parent_indices[0] not in (-1, 0):
        raise ValueError(f"unexpected root parent index: {parent_indices[0]}")
    for index, parent in enumerate(parent_indices):
        if parent >= index or parent < -1:
            raise ValueError(f"invalid parent index at bone {index}: {parent}")
    return {
        "version": version,
        "boneCount": bone_count,
        "sha256": sha256_bytes(data),
        "names": names,
        "parentIndices": parent_indices,
    }


def _is_reparse(path: Path) -> bool:
    if path.is_symlink():
        return True
    is_junction = getattr(path, "is_junction", None)
    return bool(is_junction and is_junction())


def _iter_directory(root: Path) -> Iterable[tuple[str, bytes]]:
    root = Path(root)
    if _is_reparse(root):
        raise ValueError("companion root may not be a symlink/junction")
    root = root.resolve()
    pending = [root]
    while pending:
        current = pending.pop()
        children = sorted(current.iterdir(), key=lambda item: item.as_posix().casefold(), reverse=True)
        for path in children:
            if _is_reparse(path):
                raise ValueError(f"symlink/junction is not allowed: {path}")
            if path.is_dir():
                pending.append(path)
                continue
            if not path.is_file():
                raise ValueError(f"unsupported companion filesystem entry: {path}")
            relative = path.relative_to(root).as_posix()
            yield validate_member_name(relative), path.read_bytes()


def _validate_entries(entries: dict[str, bytes]) -> dict:
    names = set(entries)
    missing = sorted(EXPECTED_ASSET_FILES - names)
    extra = sorted(names - EXPECTED_ASSET_FILES)
    if missing or extra:
        raise ValueError(f"companion file set mismatch; missing={missing}, extra={extra}")
    manifest = json.loads(entries["manifest/yorha-2b-skeleton-manifest.json"].decode("utf-8"))
    if manifest.get("schema") != "owots-yorha-2b-skeleton-companion-v1":
        raise ValueError("unexpected companion manifest schema")
    if manifest.get("source", {}).get("sha256") != EXPECTED_SOURCE_SHA256:
        raise ValueError("manifest source hash mismatch")
    variants = {item["id"]: item for item in manifest.get("variants", [])}
    expected_ids = {"yorha_2b_base_static", "yorha_2b_alternate_static"}
    if set(variants) != expected_ids:
        raise ValueError(f"manifest variant IDs mismatch: {sorted(variants)}")
    skeleton_reports = {}
    for variant_id in sorted(expected_ids):
        member = f"natives/stm/mods/{variant_id}/dynamic/rig.fbxskel.7"
        report = inspect_fbxskel(entries[member])
        if report["sha256"] != EXPECTED_SOURCE_SHA256:
            raise ValueError(f"{member} is not the audited source skeleton")
        if variants[variant_id].get("privateRigFile") != member:
            raise ValueError(f"manifest private rig route mismatch for {variant_id}")
        if not variants[variant_id].get("privateRig", "").startswith(f"mods/{variant_id}/"):
            raise ValueError(f"private runtime route escaped variant namespace: {variant_id}")
        skeleton_reports[variant_id] = {
            "member": member,
            "bytes": len(entries[member]),
            "sha256": report["sha256"],
            "boneCount": report["boneCount"],
        }
    lua = entries["reframework/autorun/yorha_2b_skeleton_adapter.lua"].decode("utf-8")
    required_tokens = (
        "get_adapter_snapshot",
        "get_scarlet_adapter_snapshot",
        "via.motion.DummySkeleton",
        "FbxSkeletonResourceHolder",
        "set_SkeletonResourceHandle",
        "restore_unresolved",
        "retry_restore",
        "yorha_2b_base_static",
        "yorha_2b_alternate_static",
    )
    missing_tokens = [token for token in required_tokens if token not in lua]
    if missing_tokens:
        raise ValueError(f"adapter missing required safety/operation tokens: {missing_tokens}")
    return {
        "schema": "owots-yorha-2b-companion-validation-v1",
        "memberCount": len(entries),
        "members": sorted(names),
        "skeletons": skeleton_reports,
        "adapterBytes": len(entries["reframework/autorun/yorha_2b_skeleton_adapter.lua"]),
    }


def validate_directory(root: Path) -> dict:
    entries = dict(_iter_directory(root))
    return _validate_entries(entries)


def validate_zip(path: Path) -> dict:
    entries: dict[str, bytes] = {}
    with zipfile.ZipFile(path) as archive:
        seen: set[str] = set()
        for info in archive.infolist():
            if info.is_dir():
                raise ValueError(f"directory member is not allowed: {info.filename!r}")
            mode = (info.external_attr >> 16) & 0o170000
            if mode == 0o120000:
                raise ValueError(f"symlink member is not allowed: {info.filename!r}")
            normalized = validate_member_name(info.filename)
            folded = normalized.casefold()
            if folded in {item.casefold() for item in seen}:
                raise ValueError(f"case-insensitive duplicate member: {info.filename!r}")
            seen.add(normalized)
            entries[normalized] = archive.read(info)
    return _validate_entries(entries)


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path)
    args = parser.parse_args()
    path = args.path.resolve()
    report = validate_zip(path) if zipfile.is_zipfile(path) else validate_directory(path)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
