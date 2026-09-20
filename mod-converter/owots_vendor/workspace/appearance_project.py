"""Independent outfit package planning; no bpy, game deployment or prefab byte rewriting.

Digests describe final staged bytes, AFTER structured reference remapping. A source
baseline is not a published-output baseline: an unchanged private asset is still
required for the first independent package.
"""
from dataclasses import dataclass
import hashlib
from pathlib import Path, PurePosixPath
import re

CATEGORIES = ("body", "cloak", "gauntlet", "weapon")
PARTS = {
    "body": ("BODY", "BODY_SUB", "HEAD", "HAIR"),
    "cloak": ("CLOAK",), "gauntlet": ("GAUNTLET",),
    "weapon": ("WEAPON", "SHEATH", "WEAPON_SUB", "SHEATH_SUB", "BOW"),
}


def build_manifest(identity, name, category, parts, *, hide_parts=(),
                   incompatible_categories=(), description="", author="", icon=""):
    """Create schema 2 metadata; does not assert runtime hide capabilities."""
    if not isinstance(identity, str) or not re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,127}", identity):
        raise ValueError("Invalid stable id")
    if category not in CATEGORIES or not isinstance(name, str) or not name.strip():
        raise ValueError("Invalid category/name")
    provided, output = set(), []
    for part in parts:
        if set(part) != {"part", "catalog", "prefab"}:
            raise ValueError("Unsupported part fields")
        logical = part["part"]
        if logical not in PARTS[category] or logical in provided:
            raise ValueError("Duplicate or wrong-category part")
        provided.add(logical)
        item = {"part": logical}
        for key, extension in (("catalog", ".user"), ("prefab", ".pfb")):
            value = _logical_path(part[key])
            if "@" in value or not value.lower().endswith(extension):
                raise ValueError("Expected logical resource path without version suffix")
            item[key] = value
        output.append(item)
    hidden, incompatible = list(hide_parts), list(incompatible_categories)
    known = {part for group in PARTS.values() for part in group}
    if not provided or len(set(hidden)) != len(hidden) or any(p not in known or p in provided for p in hidden):
        raise ValueError("Invalid provided/hidden parts")
    if len(set(incompatible)) != len(incompatible) or any(c not in CATEGORIES or c == category for c in incompatible):
        raise ValueError("Invalid incompatible categories")
    if any(not isinstance(value, str) for value in (description, author, icon)):
        raise ValueError("Metadata must be text")
    result = {"schemaVersion": 4, "id": identity, "name": name, "category": category,
              "parts": output, "rules": {"hideParts": hidden, "incompatibleCategories": incompatible},
              "description": description, "author": author}
    if icon:
        icon = _logical_path(icon)
        if "@" in icon or not icon.lower().endswith((".png", ".jpg", ".jpeg")):
            raise ValueError("Expected PNG/JPEG icon")
        result["icon"] = icon
    return result


def _logical_path(value):
    if not isinstance(value, str) or not value or "\\" in value or ":" in value:
        raise ValueError("Expected a normalized relative resource path")
    if value.startswith("/") or any(p in ("", ".", "..") for p in value.split("/")):
        raise ValueError("Resource path must stay within the package")
    if any(ord(c) < 32 for c in value):
        raise ValueError("Control character in resource path")
    return PurePosixPath(value).as_posix()


def _digest(value):
    if not isinstance(value, str) or not re.fullmatch(r"[a-f0-9]{64}", value):
        raise ValueError("Expected lowercase SHA256")
    return value


@dataclass(frozen=True)
class SourceBaseline:
    logical_path: str
    sha256: str

    @classmethod
    def capture(cls, path, logical_path):
        # Kept separately from exporter-normalized edit fingerprints.
        return cls(_logical_path(logical_path), hashlib.sha256(Path(path).read_bytes()).hexdigest())


@dataclass(frozen=True)
class PackageAsset:
    asset_id: str
    target: str
    sha256: str
    dependencies: tuple = ()
    shared: bool = False


def plan_package(roots, assets, published=None):
    """Return required private assets whose final bytes are absent/different.

All references must resolve to explicit asset records. Shared records identify
external game resources and stop traversal; callers must have verified them.
This plans writes only. Existing owner reconciliation governs removals/publish.
"""
    published = {} if published is None else published
    for target, digest in published.items():
        _logical_path(target)
        _digest(digest)
    pending = list(roots)
    seen, paths, planned = set(), {}, []
    while pending:
        identity = pending.pop()
        if identity in seen:
            continue
        seen.add(identity)
        if identity not in assets:
            raise ValueError(f"Missing asset dependency: {identity}")
        asset = assets[identity]
        if asset.asset_id != identity:
            raise ValueError("Asset identity mismatch")
        target = _logical_path(asset.target)
        _digest(asset.sha256)
        if asset.shared:
            continue
        collision = paths.setdefault(target.casefold(), identity)
        if collision != identity:
            raise ValueError(f"Conflicting package output: {target}")
        pending.extend(asset.dependencies)
        if published.get(target) != asset.sha256:
            planned.append(asset)
    return tuple(sorted(planned, key=lambda asset: (asset.target.casefold(), asset.asset_id)))
