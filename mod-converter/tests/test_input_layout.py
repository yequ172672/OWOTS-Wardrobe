import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from mod_converter import Report, SourceFiles


class InputLayoutTests(unittest.TestCase):
    def test_wrapped_mod_uses_native_resource_path(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            mesh = root / 'Author Package' / 'natives' / 'STM' / 'Art' / 'Model' / 'hair.mesh.260209350'
            mesh.parent.mkdir(parents=True)
            mesh.write_bytes(b'opaque-model')
            source = SourceFiles.from_directory(root, Report('inspect', root))
            self.assertIsNotNone(source.get('art/model/hair.mesh', False),
                'Packaging directory leaked into the logical asset path')


if __name__ == '__main__':
    unittest.main()
