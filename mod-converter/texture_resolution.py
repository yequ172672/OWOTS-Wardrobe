"""Safe resolution inspection for OWOTS ``.tex.251111100`` payloads.

The converter sometimes receives both the normal texture and its
``natives/stm/streaming`` companion.  The latter is often the complete,
higher-resolution image while the normal file is only a small fallback.  A
safe promotion may use the *unchanged streaming bytes* as the new base file;
no image data is decoded or re-encoded here.

This module deliberately implements only the direct, uncompressed
``TEX251111100`` layout verified by ``RE-Mesh-Editor-main/modules/tex``:

* a 40-byte texture header;
* ``imageCount * mipCount`` 16-byte mip records;
* absolute mip data offsets and stored byte lengths.

Structural checks prove that declared records and byte ranges are complete.
They do not prove that compressed pixels decode correctly or that the image
looks right.  ``pixel_decoded`` is therefore always ``False`` in the returned
metadata.  Unsupported arrays, cubemaps, indirect/GDeflate-style layouts,
unknown formats, partial mip chains, and smaller companions are retained as
the original base bytes.
"""

from __future__ import annotations

import re
import struct
from typing import Any


OWOTS_TEX_VERSION = 251111100
TEX_MAGIC = b"TEX\x00"
_MAGIC_UINT = int.from_bytes(TEX_MAGIC, "little")
_HEADER = struct.Struct("<IIHHHBBIiIBBHBBHHH")
_MIP = struct.Struct("<QII")


# The numeric values mirror the DXGI mapping used by file_re_tex.py.  The
# common block formats are enough to establish full row/chain byte bounds;
# unknown values remain inspectable but are never considered safe to promote.
_FORMAT_NAMES: dict[int, str] = {
    70: "BC1TYPELESS",
    71: "BC1UNORM",
    72: "BC1UNORMSRGB",
    73: "BC2TYPELESS",
    74: "BC2UNORM",
    75: "BC2UNORMSRGB",
    76: "BC3TYPELESS",
    77: "BC3UNORM",
    78: "BC3UNORMSRGB",
    79: "BC4TYPELESS",
    80: "BC4UNORM",
    81: "BC4SNORM",
    82: "BC5TYPELESS",
    83: "BC5UNORM",
    84: "BC5SNORM",
    94: "BC6HTYPELESS",
    95: "BC6HUF16",
    96: "BC6HSF16",
    97: "BC7TYPELESS",
    98: "BC7UNORM",
    99: "BC7UNORMSRGB",
    1024: "VIAEXTENSION",
}


def _format_name(format_code: int) -> str:
    return _FORMAT_NAMES.get(format_code, f"UNKNOWN(0x{format_code:08x})")


def _format_geometry(format_code: int) -> tuple[int, int, int] | None:
    """Return (block_width, block_height, bytes_per_block), when known."""

    name = _FORMAT_NAMES.get(format_code, "")
    bc = re.match(r"BC(\d+)", name)
    if bc:
        number = int(bc.group(1))
        return 4, 4, 8 if number in (1, 4) else 16
    # ASTC IDs in tex_format_enum.py are sequential by block shape.  Parse the
    # shape from the symbolic name only when the value is recognized locally.
    # Unknown ASTC values are intentionally conservative.
    if name.startswith("ASTC"):
        shape = re.match(r"ASTC(\d+)X(\d+)", name)
        if shape:
            return int(shape.group(1)), int(shape.group(2)), 16

    # The remaining DXGI formats are linear.  Their names are regular enough
    # to derive a byte width without importing the editor's vendor modules.
    if name and name != "VIAEXTENSION":
        channels = re.findall(r"[RGBA X](\d+)", name.split("TYPELESS")[0])
        if not channels:
            channels = re.findall(r"[RGBA X](\d+)", name.split("UNORM")[0])
        if channels:
            bits = sum(int(value) for value in channels)
            return 1, 1, (bits + 7) // 8
    return None


def _as_payload(payload: bytes | bytearray | memoryview, name: str) -> bytes:
    if not isinstance(payload, (bytes, bytearray, memoryview)):
        raise TypeError(f"{name} must be bytes-like")
    return bytes(payload)


def _expected_mip_count(width: int, height: int, depth: int) -> int:
    count = 1
    while max(width, height, depth) > 1:
        width = max(width >> 1, 1)
        height = max(height >> 1, 1)
        depth = max(depth >> 1, 1)
        count += 1
    return count


def _mip_dimensions(width: int, height: int, depth: int, mip_index: int) -> tuple[int, int, int]:
    return (
        max(width >> mip_index, 1),
        max(height >> mip_index, 1),
        max(depth >> mip_index, 1),
    )


def _issue(code: str, message: str, severity: str = "error", **details: Any) -> dict[str, Any]:
    item: dict[str, Any] = {"severity": severity, "code": code, "message": message}
    if details:
        item["details"] = details
    return item


def _metadata_base(payload_size: int) -> dict[str, Any]:
    return {
        "valid": False,
        "structurally_valid": False,
        "safe_for_promotion": False,
        "pixel_decoded": False,
        "pixel_data_verified": False,
        "version": None,
        "width": None,
        "height": None,
        "depth": None,
        "image_count": None,
        "mip_header_size": None,
        "mip_count": None,
        "expected_mip_count": None,
        "format": None,
        "format_name": None,
        "cubemap_marker": None,
        "is_array": False,
        "is_cubemap": False,
        "is_single_2d": False,
        "layout": "unknown",
        "header_size": _HEADER.size,
        "mip_table_end": None,
        "data_start": None,
        "data_end": None,
        "trailing_bytes": None,
        "mips": [],
        "issues": [],
        "promotion_blockers": [],
        "payload_bytes": payload_size,
    }


def _append_blocker(metadata: dict[str, Any], reason: str) -> None:
    blockers = metadata["promotion_blockers"]
    if reason not in blockers:
        blockers.append(reason)


def inspect_texture(payload: bytes | bytearray | memoryview) -> dict[str, Any]:
    """Inspect an OWOTS TEX payload without decoding pixels.

    The returned dictionary is intentionally JSON-serializable.  ``valid``
    describes structural parsing.  ``safe_for_promotion`` is stricter: it
    requires one complete direct-layout 2D image with known format geometry.
    A valid array or cubemap can therefore still have ``valid=True`` while
    being rejected for promotion.
    """

    raw = _as_payload(payload, "payload")
    metadata = _metadata_base(len(raw))
    issues: list[dict[str, Any]] = metadata["issues"]

    if len(raw) < _HEADER.size:
        issues.append(_issue("payload_too_small", "TEX header is truncated", size=len(raw)))
        _append_blocker(metadata, "invalid_structure")
        return metadata

    values = _HEADER.unpack_from(raw, 0)
    (
        magic,
        version,
        width,
        height,
        depth,
        image_count,
        mip_header_size,
        format_code,
        _swizzle_control,
        cubemap_marker,
        _unkn04,
        _unkn05,
        _null0,
        _swizzle_height_depth,
        _swizzle_width,
        _null1,
        _seven,
        _one,
    ) = values
    metadata.update(
        {
            "version": version,
            "width": width,
            "height": height,
            "depth": depth,
            "image_count": image_count,
            "mip_header_size": mip_header_size,
            "format": format_code,
            "format_name": _format_name(format_code),
            "cubemap_marker": cubemap_marker,
            "is_array": image_count > 1,
            "is_cubemap": cubemap_marker != 0,
            "is_single_2d": image_count == 1 and depth == 1 and cubemap_marker == 0,
        }
    )

    if magic != _MAGIC_UINT:
        issues.append(_issue("bad_magic", "payload is not a TEX file", actual=hex(magic)))
    if version != OWOTS_TEX_VERSION:
        issues.append(
            _issue(
                "unsupported_version",
                "only OWOTS TEX version 251111100 is accepted for promotion",
                version=version,
            )
        )
        _append_blocker(metadata, "unsupported_version")
    if image_count == 0:
        issues.append(_issue("no_images", "TEX imageCount is zero"))
    if width == 0 or height == 0 or depth == 0:
        issues.append(
            _issue(
                "invalid_dimensions",
                "TEX dimensions must all be positive",
                width=width,
                height=height,
                depth=depth,
            )
        )
    if mip_header_size == 0 or mip_header_size % _MIP.size:
        issues.append(
            _issue(
                "invalid_mip_header_size",
                "imageMipHeaderSize is not a positive multiple of 16",
                value=mip_header_size,
            )
        )

    mip_count = mip_header_size // _MIP.size
    metadata["mip_count"] = mip_count
    if width and height and depth:
        expected_mips = _expected_mip_count(width, height, depth)
        metadata["expected_mip_count"] = expected_mips
        if mip_count != expected_mips:
            issues.append(
                _issue(
                    "partial_mip_chain",
                    "mip count does not reach the 1x1x1 tail",
                    actual=mip_count,
                    expected=expected_mips,
                )
            )
            _append_blocker(metadata, "partial_mip_chain")

    if image_count > 1:
        _append_blocker(metadata, "array_texture")
    if depth != 1:
        _append_blocker(metadata, "volume_texture")
    if cubemap_marker != 0:
        _append_blocker(metadata, "cubemap")

    geometry = _format_geometry(format_code)
    if geometry is None:
        issues.append(
            _issue(
                "unknown_format_geometry",
                "format code is preserved but its row geometry is unknown; pixel completeness cannot be proven",
                severity="warning",
                format=format_code,
            )
        )
        _append_blocker(metadata, "unknown_format_geometry")

    count = image_count * mip_count
    table_end = _HEADER.size + count * _MIP.size
    metadata["mip_table_end"] = table_end
    if count <= 0:
        _append_blocker(metadata, "invalid_structure")
        return metadata
    if len(raw) < table_end:
        issues.append(
            _issue(
                "mip_table_truncated",
                "mip record table extends past the payload",
                table_end=table_end,
                payload_bytes=len(raw),
            )
        )
        _append_blocker(metadata, "invalid_structure")
        return metadata

    entries: list[tuple[int, int, int]] = []
    for index in range(count):
        entries.append(_MIP.unpack_from(raw, _HEADER.size + index * _MIP.size))

    first_offset = entries[0][0]
    metadata["data_start"] = first_offset
    if first_offset < table_end:
        metadata["layout"] = "invalid"
        issues.append(
            _issue(
                "mip_offset_before_data",
                "first mip offset overlaps the header/record table",
                offset=first_offset,
                table_end=table_end,
            )
        )
    elif first_offset == table_end:
        metadata["layout"] = "direct"
    else:
        # A gap may be legal padding, but it is outside the verified direct
        # layout and could also represent an indirect/GDeflate-style table.
        metadata["layout"] = "indirect_or_padded"
        _append_blocker(metadata, "indirect_or_padded_layout")
        issues.append(
            _issue(
                "indirect_or_padded_layout",
                "first mip does not begin immediately after the record table; promotion is disabled",
                severity="warning",
                offset=first_offset,
                table_end=table_end,
            )
        )

    previous_offset = -1
    previous_end = table_end
    data_end = 0
    valid_ranges = True
    mip_metadata: list[dict[str, Any]] = metadata["mips"]
    geometry_known = geometry is not None
    block_width, block_height, bytes_per_block = geometry or (1, 1, 0)

    for index, (offset, scanline_length, stored_size) in enumerate(entries):
        image_index, mip_index = divmod(index, mip_count)
        mip_width, mip_height, mip_depth = _mip_dimensions(width, height, depth, mip_index)
        end = offset + stored_size
        item: dict[str, Any] = {
            "image_index": image_index,
            "mip_index": mip_index,
            "width": mip_width,
            "height": mip_height,
            "depth": mip_depth,
            "offset": offset,
            "scanline_length": scanline_length,
            "stored_size": stored_size,
            "end": end,
            "minimum_size": None,
            "complete": False,
        }
        mip_metadata.append(item)

        if offset < table_end:
            issues.append(
                _issue(
                    "mip_offset_before_data",
                    "mip offset overlaps the header/record table",
                    index=index,
                    offset=offset,
                    table_end=table_end,
                )
            )
            valid_ranges = False
        if offset < previous_offset:
            issues.append(
                _issue(
                    "mip_offset_order",
                    "mip offsets are not monotonic",
                    index=index,
                    previous=previous_offset,
                    offset=offset,
                )
            )
            valid_ranges = False
        if stored_size == 0:
            issues.append(_issue("mip_size_zero", "mip has no data", index=index))
            valid_ranges = False
        if scanline_length == 0:
            issues.append(_issue("mip_scanline_zero", "mip scanline length is zero", index=index))
            valid_ranges = False
        if offset < previous_end:
            issues.append(
                _issue(
                    "mip_overlap",
                    "mip byte ranges overlap",
                    index=index,
                    previous_end=previous_end,
                    offset=offset,
                )
            )
            valid_ranges = False
        if end > len(raw):
            issues.append(
                _issue(
                    "mip_out_of_bounds",
                    "mip byte range extends past the payload",
                    index=index,
                    end=end,
                    payload_bytes=len(raw),
                )
            )
            valid_ranges = False

        if geometry_known:
            logical_row = ((mip_width + block_width - 1) // block_width) * bytes_per_block
            row_count = ((mip_height + block_height - 1) // block_height) * mip_depth
            minimum_size = scanline_length * row_count
            item["logical_row_bytes"] = logical_row
            item["row_count"] = row_count
            item["minimum_size"] = minimum_size
            if scanline_length < logical_row:
                issues.append(
                    _issue(
                        "mip_scanline_short",
                        "scanline length is shorter than the format row",
                        index=index,
                        scanline_length=scanline_length,
                        logical_row_bytes=logical_row,
                    )
                )
                valid_ranges = False
            if stored_size < minimum_size:
                issues.append(
                    _issue(
                        "mip_data_short",
                        "mip data is shorter than the complete declared row chain",
                        index=index,
                        stored_size=stored_size,
                        minimum_size=minimum_size,
                    )
                )
                valid_ranges = False
            item["complete"] = stored_size >= minimum_size and scanline_length >= logical_row

        previous_offset = offset
        previous_end = max(previous_end, end)
        data_end = max(data_end, end)

    metadata["data_end"] = data_end
    metadata["trailing_bytes"] = max(len(raw) - data_end, 0) if data_end else None
    metadata["structurally_valid"] = (
        magic == _MAGIC_UINT
        and version == OWOTS_TEX_VERSION
        and image_count > 0
        and mip_count > 0
        and len(raw) >= table_end
        and valid_ranges
        and not any(issue["severity"] == "error" for issue in issues)
    )
    metadata["valid"] = metadata["structurally_valid"]

    if not metadata["structurally_valid"]:
        _append_blocker(metadata, "invalid_structure")
    if metadata["layout"] != "direct":
        _append_blocker(metadata, "indirect_or_padded_layout")
    if mip_count != metadata.get("expected_mip_count"):
        _append_blocker(metadata, "partial_mip_chain")
    if not geometry_known:
        _append_blocker(metadata, "unknown_format_geometry")

    metadata["safe_for_promotion"] = bool(
        metadata["structurally_valid"]
        and metadata["layout"] == "direct"
        and metadata["is_single_2d"]
        and geometry_known
        and mip_count == metadata.get("expected_mip_count")
        and all(item["complete"] for item in mip_metadata)
    )
    return metadata


def _unique(values: list[str]) -> list[str]:
    result: list[str] = []
    for value in values:
        if value not in result:
            result.append(value)
    return result


def promote_texture_base(
    base_payload: bytes | bytearray | memoryview,
    streaming_payload: bytes | bytearray | memoryview,
) -> tuple[bytes, dict[str, Any]]:
    """Use a complete higher-resolution streaming payload as base when safe.

    On every rejected decision the returned bytes are an exact copy of the
    original base payload.  On success they are an exact copy of the original
    streaming payload; no header rewrite, decompression, or pixel conversion
    occurs.  ``metadata["promoted"]`` is the stable decision flag.
    """

    base = _as_payload(base_payload, "base_payload")
    streaming = _as_payload(streaming_payload, "streaming_payload")
    base_info = inspect_texture(base)
    streaming_info = inspect_texture(streaming)
    reasons: list[str] = []

    if not base_info["structurally_valid"]:
        reasons.append("base:invalid_structure")
        reasons.extend(f"base:{reason}" for reason in base_info["promotion_blockers"])
    elif not base_info["safe_for_promotion"]:
        reasons.extend(f"base:{reason}" for reason in base_info["promotion_blockers"])
    if not streaming_info["structurally_valid"]:
        reasons.append("streaming:invalid_structure")
        reasons.extend(f"streaming:{reason}" for reason in streaming_info["promotion_blockers"])
    elif not streaming_info["safe_for_promotion"]:
        reasons.extend(f"streaming:{reason}" for reason in streaming_info["promotion_blockers"])

    comparable_fields = (
        ("version", "version_mismatch"),
        ("format", "format_mismatch"),
        ("image_count", "image_count_mismatch"),
        ("depth", "depth_mismatch"),
        ("cubemap_marker", "cubemap_mismatch"),
    )
    for field, reason in comparable_fields:
        base_value = base_info.get(field)
        streaming_value = streaming_info.get(field)
        if base_value is not None and streaming_value is not None and base_value != streaming_value:
            reasons.append(reason)

    base_width, base_height = base_info.get("width"), base_info.get("height")
    stream_width, stream_height = streaming_info.get("width"), streaming_info.get("height")
    if all(isinstance(value, int) for value in (base_width, base_height, stream_width, stream_height)):
        if stream_width < base_width or stream_height < base_height:
            reasons.append("streaming_smaller_than_base")
        elif stream_width == base_width and stream_height == base_height:
            reasons.append("streaming_not_higher_resolution")

    reasons = _unique(reasons)
    promoted = not reasons
    decision = {
        "promoted": promoted,
        "decision": "promoted_streaming_as_base" if promoted else "kept_base",
        "output_source": "streaming_original_bytes" if promoted else "base_original_bytes",
        "pixel_decoded": False,
        "structural_validation_only": True,
        "reasons": reasons,
        "base": base_info,
        "streaming": streaming_info,
    }
    return (streaming if promoted else base), decision


__all__ = ["OWOTS_TEX_VERSION", "inspect_texture", "promote_texture_base"]
