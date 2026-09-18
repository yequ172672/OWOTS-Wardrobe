"""Conservative read-only OWOTS geometry probe; never an input-validity gate.

Offsets follow mesh 260209350 (internal 250203152), as documented by the local
RE-Mesh-Editor format reader. Unsupported streams/morphs are preserved intact.
"""
import math
import struct


def geometry(data: bytes, *, baseline=False) -> dict:
    def read(fmt, offset):
        if offset < 0 or offset + struct.calcsize(fmt) > len(data):
            raise ValueError('模型数据不完整')
        return struct.unpack_from(fmt, data, offset)
    def u64(offset): return read('<Q', offset)[0]
    magic, version, size = read('<III', 0)
    if magic != 0x4853454d or version != 250203152 or size != len(data):
        raise ValueError('模型布局尚不支持自动判断')
    main, shadow, occlusion, morph, buffer, streaming = (u64(offset) for offset in (48, 56, 64, 80, 88, 160))
    flags, = read('<H', 22)
    if not main or not buffer or (not baseline and (occlusion or morph or flags & 4)):
        raise ValueError('含有额外几何或形态键，保留原模型')
    if streaming and read('<I', streaming)[0]:
        raise ValueError('含有外部模型流，保留原模型')
    lod_count, _, _, _, mesh_count, index32, _ = read('<4BHBB', main)
    if not 1 <= lod_count <= 16 or index32 not in (0, 1):
        raise ValueError('LOD 布局尚不支持自动判断')
    lods = [u64(main+64+i*8) for i in range(lod_count)]
    if shadow:
        count, = read('<B', shadow)
        if count > 16 or any(u64(shadow+64+i*8) not in lods for i in range(count)):
            raise ValueError('阴影包含独立几何，保留原模型')
    elements, vertices = u64(buffer), u64(buffer+8)
    total_bytes, vertex_bytes = read('<II', buffer+24)
    _, element_count = read('<HH', buffer+32)
    face_end, = read('<I', buffer+52)
    if not 1 <= element_count <= 64 or not 0 <= vertex_bytes <= face_end <= total_bytes or vertices+total_bytes > len(data):
        raise ValueError('模型缓冲区范围无效')
    entries = [read('<HHI', elements+i*8) for i in range(element_count)]
    positions = [e for e in entries if e[0] == 0]
    if len(positions) != 1 or positions[0][1] != 12:
        raise ValueError('顶点位置格式尚不支持自动判断')
    start = positions[0][2]
    end = min([e[2] for e in entries if e[2] > start] + [vertex_bytes])
    if start >= end or end > vertex_bytes or (end-start)%12:
        raise ValueError('顶点位置范围无效')
    vertex_count = (end-start)//12
    points = list(struct.iter_unpack('<3f', data[vertices+start:vertices+end]))
    if any(not math.isfinite(v) for point in points for v in point):
        raise ValueError('顶点位置不是有限数值')
    counts = []
    meshes = 0
    for lod_number, lod in enumerate(lods):
        lod_meshes = 0
        groups, = read('<B', lod)
        if not 1 <= groups <= 128:
            raise ValueError('LOD 分组范围无效')
        indices = 0
        lod_vertices = 0
        for index in range(groups):
            group = u64(lod+16+index*8)
            _, submeshes, _, _, _, count, faces = read('<BBHHHII', group)
            meshes += submeshes
            lod_meshes += submeshes
            if not 1 <= submeshes <= 128 or count > vertex_count:
                raise ValueError('子模型范围无效')
            sub_faces = 0
            for sub in range(submeshes):
                _, quad, stream_index, _, _, face_count, face_start, vertex_start, stream_offset, platform_offset, _ = read('<4B7I', group+16+sub*32)
                if quad or stream_index or stream_offset or platform_offset or face_count%3:
                    raise ValueError('包含额外索引或模型流，保留原模型')
                index_size = 4 if index32 else 2
                if (face_start+face_count)*index_size > face_end-vertex_bytes:
                    raise ValueError('索引范围无效')
                if face_count:
                    values = read('<'+('I' if index32 else 'H')*face_count, vertices+vertex_bytes+face_start*index_size)
                    if max(values)+vertex_start >= vertex_count:
                        raise ValueError('索引超出顶点范围')
                sub_faces += face_count
            # Each 16-bit submesh's index array can have one alignment index.
            if not sub_faces <= faces <= sub_faces + (submeshes if not index32 else 0):
                raise ValueError('索引数量不一致')
            indices += sub_faces
            lod_vertices += count
        counts.append({'vertices': lod_vertices, 'indices': indices})
        # The header records the highest LOD's submesh count, not their sum.
        if lod_number == 0 and lod_meshes != mesh_count:
            raise ValueError('存在未覆盖的子模型')
    minimum = [min(p[axis] for p in points) for axis in range(3)]
    maximum = [max(p[axis] for p in points) for axis in range(3)]
    diagonal = math.dist(minimum, maximum)
    return {'lods': counts, 'vertexCount': vertex_count, 'diagonal': diagonal,
            'minimum': minimum, 'maximum': maximum, 'allLodsChecked': True}


def placeholder(payload: bytes, baseline: bytes) -> dict:
    try:
        source, original = geometry(payload), geometry(baseline, baseline=True)
    except (ValueError, struct.error, OverflowError) as error:
        return {'hide': False, 'reason': str(error), 'preserved': True}
    reference_indices = max(lod['indices'] for lod in original['lods'])
    maximum_indices = max(lod['indices'] for lod in source['lods'])
    tiny = source['diagonal'] <= min(0.001, original['diagonal'] * 0.001)
    reduced = reference_indices >= 300 and maximum_indices <= 60 and maximum_indices <= reference_indices * 0.02
    hidden = reduced and (maximum_indices == 0 or tiny)
    return {'hide': hidden, 'reason': 'all-lods-tiny-placeholder' if hidden else 'keep-authored-geometry',
            'source': source, 'baseline': original, 'preserved': not hidden}
