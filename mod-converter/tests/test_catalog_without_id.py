"""An omitted native ID must not bypass real catalog/PFB consistency."""
from pathlib import Path
from types import SimpleNamespace
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import mod_converter as converter


class CatalogWithoutIdTests(unittest.TestCase):
    def exercise(self, rows, expected_id=None):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prefab = 'GameDesign/Action/Player/_Prefab/PartsList/Body/ch001_00_00.pfb'
            catalog = 'gamedesign/system/catalogdata/playerbodypartslist_1st.user'
            args = converter.make_parser().parse_args(['convert', '--input', str(root), '--output', str(root / 'out'),
                '--prefab', prefab, '--catalog', catalog, '--part', 'BODY'])
            report = converter.Report('convert', root)
            instance = converter.Converter(args, report)
            instance.bundle = converter.InputBundle(root, report)
            instance.bundle.load()
            instance._select_part_roots()
            instance.worker = SimpleNamespace(inspect=lambda _: {'CrcWarnings': []})
            resource = root / 'catalog.user.3'
            resource.write_bytes(b'fixture')
            asset = converter.Asset(catalog, '3', False, resource, 'game', 7)
            with patch('owots_vendor.workspace.appearance_catalog.read_parts_catalog', return_value=rows):
                if expected_id is None:
                    with self.assertRaises(converter.ConversionError):
                        instance._inspect_node(catalog, asset)
                else:
                    node = instance._inspect_node(catalog, asset)
                    self.assertEqual(instance.part_roots['BODY'][2], expected_id)
                    self.assertEqual(node.dependencies, (prefab,))

    def test_wrong_prefab_without_id_is_rejected(self):
        self.exercise([SimpleNamespace(native_id=1, prefab='other.pfb')])

    def test_unique_matching_prefab_selects_real_id(self):
        self.exercise([SimpleNamespace(native_id=42, prefab='GameDesign/Action/Player/_Prefab/PartsList/Body/ch001_00_00.pfb')], 42)

    def test_multiple_ids_for_same_prefab_are_ambiguous(self):
        path = 'GameDesign/Action/Player/_Prefab/PartsList/Body/ch001_00_00.pfb'
        self.exercise([SimpleNamespace(native_id=1, prefab=path), SimpleNamespace(native_id=2, prefab=path)])


if __name__ == '__main__':
    unittest.main()
