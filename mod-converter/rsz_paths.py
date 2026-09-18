"""Offset-preserving path edits for OWOTS PFB18 / USER3.

The outer resource/userdata tables and RSZ external-userdata table have fixed
layouts. Inline RSZ paths use a UTF-16 code-unit count and a NUL terminator.
Only these bounded path spans are changed, to paths of exactly the same size.
No class fields, CRCs, lengths, offsets, indices or unknown bytes are serialized.
Catalog row selection still belongs to the structured AppearanceRsz worker.
"""
from dataclasses import dataclass
import hashlib
import re
import struct


class PathLayoutError(ValueError):
    pass


PATH = re.compile(r'@?[A-Za-z0-9_ ./-]+\.(?:pfb|user|mesh|mdf2|tex|mmtr|mmi|mpi|chain2?|jcns|fbxskel|motbank|motlist|motfsm2?|gpuc|clsp|sfur|jmap|jntexprgraph)', re.I)
TABLE_PATH = re.compile(r'@?[A-Za-z0-9_ ./-]+\.[A-Za-z][A-Za-z0-9_]*')


@dataclass(frozen=True)
class Span:
    offset: int
    path: str
    kind: str


def inventory(data: bytes) -> tuple[Span, ...]:
    def unpack(fmt, offset):
        if offset < 0 or offset + struct.calcsize(fmt) > len(data):
            raise PathLayoutError('结构化资源的表格超出文件范围。')
        return struct.unpack_from(fmt, data, offset)

    def table(offset, count, size, limit):
        if count < 0 or count > 100000 or (count and (offset < 0 or offset + count * size > limit)):
            raise PathLayoutError('结构化资源的表格范围无效。')

    spans = {}

    def string(offset, limit, kind):
        if offset < 0 or offset % 2 or offset >= limit:
            raise PathLayoutError('结构化资源的字符串位置无效。')
        end = offset
        while end + 2 <= limit and end - offset <= 8192:
            if data[end:end+2] == b'\0\0':
                value = data[offset:end].decode('utf-16le', errors='strict')
                pattern = PATH if kind == 'inline-path' else TABLE_PATH
                if value and pattern.fullmatch(value):
                    if any(part in ('', '.', '..') for part in value.lstrip('@').split('/')):
                        raise PathLayoutError('结构化资源包含无效路径。')
                    spans[offset] = Span(offset, value, kind)
                elif value:
                    raise PathLayoutError('资源表中有尚不支持的路径：' + value[:160])
                return
            end += 2
        raise PathLayoutError('结构化资源的字符串缺少结尾。')

    magic, = unpack('<I', 0)
    if magic == 0x424650:
        _, objects, resources, refs, users, ref_table, resource_table, user_table, rsz = unpack('<IiiiQQQQQ', 0)
        table(56, objects, 12, rsz)
        table(ref_table, refs, 16, rsz)
    elif magic == 0x525355:
        _, resources, users, _, resource_table, user_table, rsz = unpack('<IiiiQQQ', 0)
    else:
        raise PathLayoutError('不是受支持的 PFB / USER 资源。')
    if rsz < (56 if magic == 0x424650 else 40) or rsz + 48 > len(data):
        raise PathLayoutError('RSZ 数据位置无效。')
    table(resource_table, resources, 8, rsz)
    table(user_table, users, 16, rsz)
    for index in range(resources):
        offset, = unpack('<Q', resource_table + index * 8)
        string(offset, rsz, 'resource')
    for index in range(users):
        offset, = unpack('<Q', user_table + index * 16 + 8)
        string(offset, rsz, 'userdata')
    signature, version, objects, instances, users, reserved, info_offset, data_offset, user_offset = unpack('<6I3Q', rsz)
    if signature != 0x5a5352 or version != 16 or reserved != 0:
        raise PathLayoutError('尚不支持这个 RSZ 版本。')
    begin = rsz + data_offset
    if not rsz + 48 <= begin <= len(data):
        raise PathLayoutError('RSZ 字段范围无效。')
    table(rsz + 48, objects, 4, begin)
    table(rsz + info_offset, instances, 8, begin)
    table(rsz + user_offset, users, 16, begin)
    for index in range(users):
        offset, = unpack('<Q', rsz + user_offset + index * 16 + 8)
        string(rsz + offset, begin, 'external-userdata')
    # String/Resource values have an aligned int32 UTF-16 count. No generic
    # find-and-replace: only complete, bounded, terminated path values qualify.
    for offset in range(begin, len(data) - 6, 4):
        count, = unpack('<I', offset)
        if not 6 <= count <= 4096:
            continue
        end = offset + 4 + count * 2
        if end > len(data) or data[end-2:end] != b'\0\0':
            continue
        try:
            value = data[offset+4:end-2].decode('utf-16le')
        except UnicodeDecodeError:
            continue
        if PATH.fullmatch(value):
            string(offset+4, end, 'inline-path')
    ordered = tuple(spans[key] for key in sorted(spans))
    for left, right in zip(ordered, ordered[1:]):
        if left.offset + len(left.path.encode('utf-16le')) + 2 > right.offset:
            raise PathLayoutError('资源路径范围重叠。')
    return ordered


def dependencies(data: bytes) -> tuple[str, ...]:
    return tuple(sorted({span.path.lstrip('@') for span in inventory(data)}, key=str.casefold))


def private_path(identity: str, logical: str) -> str:
    prefix = 'mods/' + identity + '/'
    extension = '.' + logical.rsplit('.', 1)[1]
    count = len(logical.encode('utf-16le')) // 2 - len(prefix) - len(extension)
    if count < 24:
        # Short weapon paths still receive a content-derived private route.
        # BODY skeleton paths separately enforce the per-entry namespace.
        prefix = 'mods/_/'
        count = len(logical.encode('utf-16le')) // 2 - len(prefix) - len(extension)
    if count < 24:
        raise PathLayoutError('原始资源路径过短，无法为它分配独立路径：' + logical)
    digest = hashlib.shake_256((identity + '\0' + logical.casefold()).encode()).hexdigest((count + 1) // 2)
    return prefix + digest[:count] + extension


def rewrite(data: bytes, remap: dict[str, str]) -> tuple[bytes, dict]:
    spans = inventory(data)
    mappings = {key.casefold(): value for key, value in remap.items()}
    if len(mappings) != len(remap):
        raise PathLayoutError('重复的资源重定向。')
    result = bytearray(data)
    edits = []
    used = set()
    for span in spans:
        key = span.path.lstrip('@').casefold()
        if key not in mappings:
            continue
        replacement = ('@' if span.path.startswith('@') else '') + mappings[key]
        if not PATH.fullmatch(replacement):
            raise PathLayoutError('输出资源路径无效。')
        before, after = span.path.encode('utf-16le'), replacement.encode('utf-16le')
        if len(before) != len(after):
            raise PathLayoutError('路径改写必须保留原始字节长度。')
        result[span.offset:span.offset+len(before)] = after
        used.add(key)
        edits.append({'offset': span.offset, 'bytes': len(before), 'before': span.path, 'after': replacement})
    if used != mappings.keys():
        raise PathLayoutError('未在资源中找到所有待改写路径。')
    # A duplicate in an unrecognized storage layout must not remain at the
    # original path. Require every exact occurrence to have a known span.
    for old in {span.path for span in spans if span.path.lstrip('@').casefold() in used}:
        needle = old.encode('utf-16le') + b'\0\0'
        offsets = {span.offset for span in spans if span.path == old}
        start = 0
        while (position := data.find(needle, start)) >= 0:
            if position not in offsets:
                raise PathLayoutError('资源中还有无法确认布局的同名引用。')
            start = position + len(needle)
    output = bytes(result)
    actual = inventory(output)
    expected = tuple(Span(span.offset,
        ('@' if span.path.startswith('@') else '') + mappings[span.path.lstrip('@').casefold()]
        if span.path.lstrip('@').casefold() in mappings else span.path, span.kind) for span in spans)
    if actual != expected or len(data) != len(output):
        raise PathLayoutError('路径改写回读未通过。')
    # Undo precisely the declared spans. This proves all other bytes identical.
    restored = bytearray(output)
    for edit in edits:
        restored[edit['offset']:edit['offset']+edit['bytes']] = edit['before'].encode('utf-16le')
    if bytes(restored) != data:
        raise PathLayoutError('路径之外的数据发生了变化。')
    return output, {'method': 'equal-size-path-spans', 'unchangedOutsidePaths': True, 'edits': edits}
