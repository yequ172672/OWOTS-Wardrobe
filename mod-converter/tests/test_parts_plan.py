"""Explicit multi-part plans must preserve single-root safety checks."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import mod_converter as converter


class PartsPlanTests(unittest.TestCase):
    def select(self, rows, extra=()):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            plan = root / 'plan.json'
            plan.write_text(json.dumps({'parts': rows}), encoding='utf-8')
            args = converter.make_parser().parse_args([
                'convert', '--input', str(root), '--output', str(root / 'out'),
                '--parts-plan', str(plan), *extra])
            report = converter.Report('convert', root)
            instance = converter.Converter(args, report)
            instance.bundle = converter.InputBundle(root, report)
            instance._select_part_roots()
            return instance

    def test_body_head_hair_are_all_retained(self):
        instance = self.select([{'part': part, 'prefab': f'custom/{part}.pfb',
                                 'catalog': f'gamedesign/system/catalogdata/player{part.lower()}partslist_1st.user'}
                                for part in ('BODY', 'HEAD', 'HAIR')])
        self.assertEqual(set(instance.part_roots), {'BODY', 'HEAD', 'HAIR'})
        self.assertEqual(instance.args.category, 'body')

    def test_duplicates_categories_bad_roles_and_conflicts_rejected(self):
        body = {'part': 'BODY', 'prefab': 'custom/body.pfb',
                'catalog': 'gamedesign/system/catalogdata/playerbodypartslist_1st.user'}
        invalid = [
            [body, body],
            [body, {'part': 'CLOAK', 'prefab': 'custom/cloak.pfb'}],
            [dict(body, catalog='gamedesign/system/catalogdata/playerhairpartslist_1st.user')],
            [dict(body, nativeId=True)],
            [dict(body, unexpected='typo')],
            [dict(body, prefab='custom/body.user')],
            [dict(body, catalog='custom/catalog.pfb')],
            [{'part': 'BODY', 'prefab': 'custom/body.pfb'}],
        ]
        for rows in invalid:
            with self.subTest(rows=rows), self.assertRaises(converter.ConversionError):
                self.select(rows)
        with self.assertRaises(converter.ConversionError):
            self.select([body], ['--prefab', 'other.pfb'])


if __name__ == '__main__':
    unittest.main()
