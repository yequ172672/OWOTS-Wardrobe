import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from input_containers import ExpandedInput, InputError, member_path


class ContainerTests(unittest.TestCase):
    def test_asset_only_zip_keeps_wrapper_and_streaming_and_omission_inventory(self):
        with tempfile.TemporaryDirectory() as folder:
            archive = Path(folder) / 'test.zip'
            name = '外层/natives/STM/streaming/art/body.tex.251111100'
            with zipfile.ZipFile(archive, 'w') as f:
                f.writestr(name, b'texture')
                f.writestr('说明.txt', 'Never read this description')
                f.writestr('reframework/autorun/a.lua', 'error("do not execute")')
            with ExpandedInput(archive) as expanded:
                self.assertEqual((expanded.root/name).read_bytes(), b'texture')
                self.assertFalse((expanded.root/'说明.txt').exists())
                self.assertIn('reframework/autorun/a.lua', expanded.omitted)
                root = expanded.root
            self.assertFalse(root.exists())

    def test_unsafe_and_duplicate_entries_do_not_extract(self):
        for bad in ['../escape', '/root/a', 'C:/file', 'a/NUL.tex.1', 'a./x', 'a\ntext']:
            with self.subTest(bad=bad), self.assertRaises(InputError): member_path(bad)
        with tempfile.TemporaryDirectory() as folder:
            archive = Path(folder) / 'dupe.zip'
            with zipfile.ZipFile(archive, 'w') as f:
                f.writestr('a.mesh.260209350', b'a')
                f.writestr('A.mesh.260209350', b'b')
            with self.assertRaisesRegex(InputError, '重名'):
                with ExpandedInput(archive): pass

    @unittest.skipUnless(importlib.util.find_spec('py7zr'), 'optional 7z library not installed')
    def test_sevenzip_roundtrip_uses_bounded_writer(self):
        import py7zr
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'a.mesh.260209350'
            source.write_bytes(b'testmesh'*100)
            archive = Path(folder) / 'test.7z'
            with py7zr.SevenZipFile(archive, 'w') as f:
                f.write(source, 'natives/STM/a.mesh.260209350')
            with ExpandedInput(archive) as expanded:
                self.assertEqual((expanded.root/'natives/STM/a.mesh.260209350').read_bytes(), source.read_bytes())

    def test_cancel_stops_before_reading_source(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaisesRegex(InputError, '取消'):
                with ExpandedInput(Path(folder), lambda: True): pass
