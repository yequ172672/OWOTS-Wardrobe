"""Do not publish assets from a different game's format version unchanged."""
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import mod_converter as converter


class ResourceVersionTests(unittest.TestCase):
    def test_other_game_mesh_version_blocks_input(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / 'natives/stm/art/body.mesh.230110883'
            path.parent.mkdir(parents=True)
            path.write_bytes(b'mesh bytes deliberately not parsed by an indexer')
            report = converter.Report('inspect', root)
            files = converter.SourceFiles.from_directory(root, report)
            self.assertFalse(files.assets)
            self.assertEqual([issue.code for issue in report.errors], ['RESOURCE_VERSION_UNSUPPORTED'])


if __name__ == '__main__':
    unittest.main()
