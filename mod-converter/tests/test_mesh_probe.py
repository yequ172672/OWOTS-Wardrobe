import struct
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from mesh_probe import geometry, placeholder


def mesh(scale, indices=3, second_lod_scale=None):
    levels = [scale] + ([] if second_lod_scale is None else [second_lod_scale])
    vertices = [(0, 0, 0), (scale, 0, 0), (0, scale, 0)]
    if len(levels) == 2:
        vertices.extend([(0, 0, 0), (second_lod_scale, 0, 0), (0, second_lod_scale, 0)])
    vertex_bytes = len(vertices)*12
    face_bytes = indices*2*len(levels)
    payload = bytearray(1024+vertex_bytes+face_bytes)
    struct.pack_into('<III', payload, 0, 0x4853454d, 250203152, len(payload))
    struct.pack_into('<Q', payload, 48, 176)
    struct.pack_into('<Q', payload, 88, 800)
    struct.pack_into('<4BHBB', payload, 176, len(levels), 1, 1, 27, 1, 0, 0)
    for number, _ in enumerate(levels):
        lod = 320+number*128
        group = lod+32
        struct.pack_into('<Q', payload, 240+number*8, lod)
        struct.pack_into('<B', payload, lod, 1)
        struct.pack_into('<Q', payload, lod+16, group)
        struct.pack_into('<BBHHHII', payload, group, 0, 1, 0, 0, 0, 3, indices)
        struct.pack_into('<4B7I', payload, group+16, 0, 0, 0, 0, 0, indices, number*indices, number*3, 0, 0, 0)
    struct.pack_into('<QQ', payload, 800, 912, 1024)
    struct.pack_into('<IIHH', payload, 824, vertex_bytes+face_bytes, vertex_bytes, 1, 1)
    struct.pack_into('<I', payload, 852, vertex_bytes+face_bytes)
    struct.pack_into('<HHI', payload, 912, 0, 12, 0)
    for number, vertex in enumerate(vertices): struct.pack_into('<3f', payload, 1024+number*12, *vertex)
    for number in range(indices*len(levels)): struct.pack_into('<H', payload, 1024+vertex_bytes+number*2, number%3)
    return bytes(payload)


class PlaceholderTests(unittest.TestCase):
    def test_tiny_reduced_geometry_with_original_reference_is_hidden(self):
        result = placeholder(mesh(.00001), mesh(1, 300))
        self.assertTrue(result['hide'])
        self.assertTrue(result['source']['allLodsChecked'])

    def test_low_polygon_visible_accessory_is_preserved(self):
        self.assertFalse(placeholder(mesh(.2), mesh(1, 300))['hide'])

    def test_visible_second_lod_cannot_be_hidden(self):
        data = mesh(.00001, second_lod_scale=.2)
        self.assertEqual(len(geometry(data)['lods']), 2)
        self.assertFalse(placeholder(data, mesh(1, 300))['hide'])

    def test_optional_probe_failure_preserves_bytes(self):
        data = mesh(.00001)[:-2]
        self.assertTrue(placeholder(data, mesh(1, 300))['preserved'])


if __name__ == '__main__': unittest.main()
