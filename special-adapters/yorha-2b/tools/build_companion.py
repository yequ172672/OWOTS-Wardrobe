"""Build the small, deterministic YoRHa 2B skeleton companion ZIP.

The builder reads one audited FBXSKEL from a caller supplied path (or the
offline validation extract) and copies its bytes into the two private variant
routes.  It never reads the game installation and never includes the static
wardrobe package, PAKs, saves, logs, or a loader.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import tempfile
import zipfile
from pathlib import Path

from validate_companion import (
    EXPECTED_ASSET_FILES,
    EXPECTED_BONE_COUNT,
    EXPECTED_SOURCE_SHA256,
    EXPECTED_VERSION,
    inspect_fbxskel,
    validate_zip,
)


ROOT = Path(__file__).resolve().parents[1]
WORKSPACE_ROOT = ROOT.parents[2]
DEFAULT_SOURCE_RIG = (
    WORKSPACE_ROOT
    / "_validation"
    / "mod-converter-round2-20260915"
    / "2b"
    / "correct-paths"
    / "natives"
    / "stm"
    / "art"
    / "model"
    / "character"
    / "ch0"
    / "ch001_00"
    / "90"
    / "ch001_00_90.fbxskel.7"
)

PACKAGE_FILES = {
    "reframework/autorun/yorha_2b_skeleton_adapter.lua": ROOT / "src" / "yorha_2b_skeleton_adapter.lua",
    "manifest/yorha-2b-skeleton-manifest.json": ROOT / "manifest" / "yorha-2b-skeleton-manifest.json",
    "native-api-contract.json": ROOT / "native-api-contract.json",
    "README-zh-CN.md": ROOT / "README-zh-CN.md",
}
RIG_ROUTES = {
    "natives/stm/mods/yorha_2b_base_static/dynamic/rig.fbxskel.7",
    "natives/stm/mods/yorha_2b_alternate_static/dynamic/rig.fbxskel.7",
}
ZIP_EPOCH = (2020, 1, 1, 0, 0, 0)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _reject_reparse(path: Path, label: str) -> None:
    if path.is_symlink():
        raise ValueError(f"{label} may not be a symlink: {path}")
    is_junction = getattr(path, "is_junction", None)
    if is_junction and is_junction():
        raise ValueError(f"{label} may not be a junction: {path}")


def read_source(path: Path) -> tuple[bytes, dict]:
    path = Path(path)
    _reject_reparse(path, "source rig")
    if not path.is_file():
        raise FileNotFoundError(f"source rig does not exist: {path}")
    data = path.read_bytes()
    report = inspect_fbxskel(data)
    if len(data) != 8594 or report["sha256"] != EXPECTED_SOURCE_SHA256:
        raise ValueError(
            "source rig is not the audited 2B skeleton; "
            f"expected {EXPECTED_SOURCE_SHA256}, got {report['sha256']}"
        )
    if report["version"] != EXPECTED_VERSION or report["boneCount"] != EXPECTED_BONE_COUNT:
        raise ValueError("source rig version/bone count differs from audited v7/93")
    return data, report


def _read_package_files() -> dict[str, bytes]:
    entries: dict[str, bytes] = {}
    for member, path in PACKAGE_FILES.items():
        _reject_reparse(path, "package source")
        if not path.is_file():
            raise FileNotFoundError(f"package source missing: {path}")
        entries[member] = path.read_bytes()
    return entries


def build(output: Path, source_rig: Path) -> dict:
    source, source_report = read_source(source_rig)
    entries = _read_package_files()
    for route in RIG_ROUTES:
        entries[route] = source
    if set(entries) != EXPECTED_ASSET_FILES:
        raise ValueError("builder file set differs from validator allowlist")

    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    _reject_reparse(output.parent, "output directory")
    if output.exists():
        _reject_reparse(output, "output ZIP")

    fd, temporary_name = tempfile.mkstemp(prefix=f".{output.name}.", suffix=".tmp", dir=output.parent)
    os.close(fd)
    temporary = Path(temporary_name)
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for member in sorted(entries):
                info = zipfile.ZipInfo(member, date_time=ZIP_EPOCH)
                info.compress_type = zipfile.ZIP_DEFLATED
                info.create_system = 3
                info.external_attr = (0o100600 << 16)
                archive.writestr(info, entries[member])
        os.replace(temporary, output)
    finally:
        if temporary.exists():
            temporary.unlink()

    validation = validate_zip(output)
    result = {
        "schema": "owots-yorha-2b-skeleton-companion-build-v1",
        "output": str(output.resolve()),
        "bytes": output.stat().st_size,
        "sha256": sha256(output.read_bytes()),
        "source": {
            "path": str(Path(source_rig).resolve()),
            "bytes": len(source),
            "sha256": source_report["sha256"],
            "version": source_report["version"],
            "boneCount": source_report["boneCount"],
        },
        "members": sorted(entries),
        "validation": validation,
    }
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        type=Path,
        default=WORKSPACE_ROOT / "_validation" / "2b-skeleton-diagnosis-20260915" / "yorha-2b-skeleton-companion.zip",
    )
    parser.add_argument("--source-rig", type=Path, default=DEFAULT_SOURCE_RIG)
    args = parser.parse_args()
    result = build(args.output, args.source_rig)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

