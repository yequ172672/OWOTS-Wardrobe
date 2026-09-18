import struct
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import rsz_paths as paths


def fixture():
    path = 'art/model/character/ch0/ch001_00/00/ch001_00_00.mesh'
    value = path.encode('utf-16le') + b'\0\0'
    rsz = (64 + len(value) + 15) & ~15
    data = bytearray(rsz + 64)
    struct.pack_into('<IiiiQQQQQ', data, 0, 0x424650, 0, 1, 0, 0, 0, 56, 0, rsz)
    struct.pack_into('<Q', data, 56, 64)
    data[64:64+len(value)] = value
    struct.pack_into('<6I3Q', data, rsz, 0x5a5352, 16, 0, 1, 0, 0, 48, 64, 0)
    struct.pack_into('<II', data, rsz+48, 0x12345678, 0x87654321)
    data.extend(struct.pack('<I', len(path)+1) + value + b'untouched')
    return bytes(data), path


class PathTests(unittest.TestCase):
    def test_typed_resource_table_can_keep_original_sound_reference(self):
        data, original = fixture()
        sound = original[:-4] + 'sbnk'
        data = data.replace(original.encode('utf-16le'), sound.encode('utf-16le'))
        self.assertIn(sound, paths.dependencies(data))
        self.assertEqual(paths.rewrite(data, {})[0], data)

    def test_short_weapon_path_gets_equal_size_private_route(self):
        original = 'art/model/item/it0/it000_0000/it000_0000_00.mesh'
        first = paths.private_path('c0123456789ab', original)
        second = paths.private_path('c1123456789ab', original)
        self.assertEqual(len(original), len(first))
        self.assertNotEqual(first, second)
        self.assertTrue(first.startswith('mods/'))

    def test_equal_size_relocation_preserves_crc_and_unknown_bytes(self):
        data, original = fixture()
        target = paths.private_path('c12345', original)
        output, proof = paths.rewrite(data, {original: target})
        self.assertEqual(paths.dependencies(output), (target,))
        self.assertEqual(len(data), len(output))
        self.assertTrue(proof['unchangedOutsidePaths'])
        self.assertEqual(len(proof['edits']), 2)
        self.assertEqual(paths.rewrite(output, {target: original})[0], data)

    def test_rejects_length_change_and_untyped_duplicate(self):
        data, original = fixture()
        with self.assertRaises(paths.PathLayoutError): paths.rewrite(data, {original: 'a.mesh'})
        data += original.encode('utf-16le') + b'\0\0'
        with self.assertRaises(paths.PathLayoutError):
            paths.rewrite(data, {original: paths.private_path('c12345', original)})

    def test_bad_table_and_unknown_layout_are_not_rewritten(self):
        data, original = fixture()
        bad = bytearray(data)
        struct.pack_into('<Q', bad, 56, len(data)+10)
        with self.assertRaises(paths.PathLayoutError): paths.inventory(bytes(bad))
        self.assertEqual(paths.rewrite(data, {})[0], data)


if __name__ == '__main__': unittest.main()
