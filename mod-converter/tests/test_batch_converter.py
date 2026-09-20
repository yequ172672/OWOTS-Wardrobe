import sys
import unittest
import json
import tempfile
import zipfile
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from batch_converter import BatchConverter, Result, Notice, Candidate, group_candidates, companion_candidates
from input_containers import InputError


def candidate(part, identity, stem, changed, variant='normal'):
    return Candidate({'part': part, 'native_id': identity, 'prefab': 'gamedesign/'+stem+'.pfb', 'variant': variant}, set(changed), set(changed))


class PlanningTests(unittest.TestCase):
    def test_empty_material_part_becomes_hide_only_with_body_and_all_materials_empty(self):
        from types import SimpleNamespace
        import struct
        import mod_converter as mc
        empty = struct.pack('<4sHHQ', b'MDF\0', 1, 0, 1)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root/'empty.mdf2.51'
            path.write_bytes(empty)
            asset = SimpleNamespace(path=path)
            source = SimpleNamespace(get=lambda key: asset if key == 'head.mdf2' else None)
            head = candidate('HEAD', 1, 'head', ['head.mdf2', 'head.mesh'])
            body = candidate('BODY', 1, 'body', ['body.mesh'])
            with BatchConverter(root) as converter:
                converter.game = SimpleNamespace(find=lambda key: None, close=lambda: None)
                converter._mesh_placeholder = lambda *args: {'hide': False}
                self.assertEqual(mc.mdf_dependencies(empty), ())
                hidden = converter._placeholder_parts([body, head], source, Result('test'))
                self.assertIn(('normal', 'HEAD'), hidden)
                self.assertEqual(converter._placeholder_parts([head], source, Result('test')), {})
                custom = SimpleNamespace(get=lambda key: asset if key in ('head.mdf2', head.record['prefab']) else None)
                self.assertEqual(converter._placeholder_parts([body, head], custom, Result('test')), {})
                head.reached.add('visible.mdf2')
                self.assertEqual(converter._placeholder_parts([body, head], source, Result('test')), {})

    def test_empty_material_fallback_copies_bytes_without_serializing(self):
        import struct
        from types import SimpleNamespace
        import mod_converter as mc
        payload = struct.pack('<4sHHQ', b'MDF\0', 1, 0, 1)
        with tempfile.TemporaryDirectory() as directory:
            source, target = Path(directory)/'source', Path(directory)/'private.mdf2.51'
            source.write_bytes(payload)
            node = SimpleNamespace(asset=SimpleNamespace(path=source, extension='.mdf2'))
            mc.Converter._copy_or_rewrite(None, node, target, {}, None)
            self.assertEqual(target.read_bytes(), payload)

    def test_empty_material_is_exact_header_not_truncated_or_nonempty(self):
        import struct
        import mod_converter as mc
        empty = struct.pack('<4sHHQ', b'MDF\0', 1, 0, 1)
        self.assertTrue(mc.is_empty_mdf(empty))
        for payload in (empty[:-1], empty+b'\0', b'BAD!'+empty[4:],
                        struct.pack('<4sHHQ', b'MDF\0', 1, 1, 1),
                        struct.pack('<4sHHQ', b'MDF\0', 99, 0, 1)):
            self.assertFalse(mc.is_empty_mdf(payload))

    def test_unrelated_archive_assets_are_reported_without_reading_source_documents(self):
        import tempfile
        import zipfile
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            archive = root/'mod.zip'
            with zipfile.ZipFile(archive, 'w') as zipped:
                zipped.writestr('natives/stm/art/body.mesh.260209350', b'mesh fixture')
                zipped.writestr('natives/stm/sound/custom.sbnk.1', b'unrelated')
                zipped.writestr('README.md', b'not model data')
            result = Result(str(archive))
            with BatchConverter(root) as converter:
                self.assertEqual(len(list(converter._layers(archive, result))), 1)
                self.assertEqual([n.code for n in result.notices], ['OUTSIDE_WARDROBE_SCOPE'])
                self.assertEqual(result.ledger, [{'path': 'natives/stm/sound/custom.sbnk.1', 'disposition': 'unsupported'}])

    def test_shared_cloak_uses_unique_body_family_without_dropping_other_entries(self):
        def entry(category, stem):
            return {'category': category, 'targets': [{'prefab': stem+'.pfb', 'variant': 'normal'}]}
        body = entry('body', 'ch001_00_00')
        cloaks = [entry('cloak', stem) for stem in ('ch001_00_01', 'ch001_40_00', 'ch001_40_01')]
        self.assertEqual(companion_candidates(body, cloaks, 'cloak'), cloaks[:1])
        self.assertEqual(companion_candidates(entry('body', 'ch001_40_00'), cloaks, 'cloak'), cloaks)
        self.assertEqual(len(cloaks), 3)

    def test_body_companions_are_grouped_but_visible_accessories_are_separate(self):
        values = [candidate(part, i, part, [part]) for i, part in enumerate(('BODY', 'HEAD', 'HAIR', 'CLOAK', 'GAUNTLET'))]
        groups = group_candidates(values)
        self.assertEqual([[c.record['part'] for c in group] for group in groups], [['BODY', 'HEAD', 'HAIR'], ['CLOAK'], ['GAUNTLET']])

    def test_several_weapons_pair_only_by_exact_native_id(self):
        values = [candidate(part, i, part+str(i), [part+str(i)]) for i in (12, 13) for part in ('WEAPON', 'SHEATH', 'WEAPON_SUB')]
        groups = group_candidates(values)
        self.assertEqual(len(groups), 2)
        self.assertTrue(all(len({c.record['native_id'] for c in group}) == 1 for group in groups))

    def test_ambiguous_hair_is_never_combined_by_cartesian_product(self):
        values = [candidate('BODY', 1, 'body', ['body']), candidate('HAIR', 2, 'hair-a', ['a']), candidate('HAIR', 3, 'hair-b', ['b'])]
        self.assertTrue(all(len(group) == 1 for group in group_candidates(values)))


class ArchivePublishingTests(unittest.TestCase):
    class FixtureConverter(BatchConverter):
        def _setup(self, source): pass
        def _layers(self, source, result, depth=0): yield source
        def _convert_layer(self, layer, original, layer_number, package, result):
            identity = 'test.body'
            manifest = 'reframework/data/owots_appearance_lab/mods/test.body/manifest.json'
            content = {'id': identity, 'category': 'body', 'rules': {}, 'parts': [{
                'catalog': 'mods/test.body/catalog.user', 'prefab': 'mods/test.body/body.pfb'}]}
            files = {manifest: json.dumps(content).encode(),
                     'natives/stm/mods/test.body/catalog.user.3': b'catalog fixture',
                     'natives/stm/mods/test.body/body.pfb.18': b'model fixture'}
            for relative, payload in files.items():
                path = package/relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(payload)
            result.entries.append({'id': identity, 'manifest': manifest})
            result.notices.append(Notice('TEST_LIMIT', 'Test limitation'))

    def test_default_is_beside_each_input_with_suffix_report_and_no_loose_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            game = root/'game'
            game.mkdir()
            sources = [root/'one'/'Outfit.v1.2', root/'two'/'Another.rar']
            sources[0].mkdir(parents=True)
            sources[1].parent.mkdir()
            sources[1].write_bytes(b'original archive')
            with self.FixtureConverter(game) as converter:
                for source in sources:
                    result = converter.convert(source)
                    output = Path(result.output)
                    expected = source.name if source.is_dir() else source.stem
                    self.assertEqual(output, source.parent/(expected+'-衣橱.zip'))
                    self.assertEqual(result.status, 'needs_test')
                    with zipfile.ZipFile(output) as archive:
                        self.assertIsNone(archive.testzip())
                        self.assertEqual(archive.read('natives/stm/mods/test.body/body.pfb.18'), b'model fixture')
                        self.assertEqual(json.loads(archive.read('conversion-report.json')), result.as_dict())
                    self.assertEqual(set(source.parent.iterdir()), {source, output})
            self.assertEqual(sources[1].read_bytes(), b'original archive')

    def test_custom_output_preserves_an_existing_archive_and_numbers_new_results(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            game, source, output = root/'game', root/'input.zip', root/'chosen'
            game.mkdir()
            source.write_bytes(b'original')
            output.mkdir()
            existing = output/'input-衣橱.zip'
            existing.write_bytes(b'do not replace')
            with self.FixtureConverter(game) as converter:
                result = converter.convert(source, output)
            self.assertEqual(Path(result.output), output/'input-衣橱 (2).zip')
            self.assertEqual(existing.read_bytes(), b'do not replace')
            self.assertEqual(set(output.iterdir()), {existing, Path(result.output)})

    def test_cancel_during_packaging_leaves_no_archive_or_staging_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            game, source = root/'game', root/'input.zip'
            game.mkdir()
            source.write_bytes(b'original')
            cancelled = [False]
            def progress(message):
                if message == '正在打包…': cancelled[0] = True
            with self.FixtureConverter(game, progress=progress, cancelled=lambda: cancelled[0]) as converter:
                with self.assertRaises(InputError) as error: converter.convert(source)
                self.assertEqual(error.exception.code, 'CANCELLED')
                self.assertEqual(set(root.iterdir()), {game, source})

    def test_default_output_still_refuses_writing_into_the_game(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source = root/'mod.zip'
            source.write_bytes(b'original')
            with self.FixtureConverter(root) as converter:
                with self.assertRaises(InputError) as error: converter.convert(source)
                self.assertEqual(error.exception.code, 'OUTPUT_INSIDE_INPUT')


if __name__ == '__main__': unittest.main()
