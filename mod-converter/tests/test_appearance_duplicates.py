import io
import struct
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import mod_converter as mc
from appearance_duplicates import AppearanceFingerprints, deduplicate_groups, prefab_signature
from batch_converter import Candidate, companion_candidates
from input_containers import InputError


def pfb(paths, flags=0):
    data = bytearray(56+len(paths)*8)
    for i, path in enumerate(paths):
        struct.pack_into('<Q', data, 56+i*8, len(data))
        data.extend(path.encode('utf-16le')+b'\0\0')
    data.extend(b'\0'*((-len(data)) % 16))
    rsz = len(data)
    data.extend(b'\0'*64)
    struct.pack_into('<IiiiQQQQQ', data, 0, 0x424650, 0, len(paths), 0, 0, 0, 56, 0, rsz)
    struct.pack_into('<6I3Q', data, rsz, 0x5a5352, 16, 0, 1, 0, 0, 48, 64, 0)
    struct.pack_into('<II', data, rsz+48, 0x12345678, 0x87654321)
    data.extend(struct.pack('<I', flags))
    for path in paths:
        data.extend(struct.pack('<I', len(path)+1)+path.encode('utf-16le')+b'\0\0')
        data.extend(b'\0'*((-len(data)) % 4))
    return bytes(data)


def mdf(texture, shader=0, slot='BaseColorMap'):
    from owots_vendor.mdf.file_re_mdf import MDFFile, Material, TextureBinding
    value, material, binding = MDFFile(), Material(), TextureBinding()
    value.isOnimushaVariant = material.isOnimushaVariant = True
    material.materialName, material.mmtrPath = 'cloth', 'materialshader/test.mmtr'
    material.shaderType = shader
    binding.textureType, binding.texturePath = slot, texture
    material.textureList = [binding]
    value.materialList = [material]
    value.recalculateHashesAndOffsets(51)
    output = io.BytesIO()
    with redirect_stdout(io.StringIO()):
        value.write(output, 51)
    return output.getvalue()


class DuplicateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = mc.SourceFiles(self.root, mc.Report('test', self.root))
        self.originals = {}
        self.game = SimpleNamespace(find=lambda key, streaming=False: self.originals.get((key.lower(), streaming)))

    def asset(self, logical, payload, original=False, streaming=False):
        physical = self.root/str(len(list(self.root.iterdir())))
        physical.write_bytes(payload)
        version = {'.pfb': '18', '.mdf2': '51', '.tex': '251111100', '.mesh': '260209350'}.get(Path(logical).suffix, '3')
        asset = mc.Asset(logical, version, streaming, physical, 'game' if original else 'mod', len(payload))
        if original: self.originals[asset.variant_key] = asset
        else: self.source.assets[asset.variant_key] = asset
        return asset

    def outfit(self, name, identity, texture=b'red', mesh=b'same mesh', shader=0, flags=0,
               part='BODY', variant='normal', slot='BaseColorMap'):
        logical = 'gamedesign/'+name+'.pfb'
        paths = ['art/'+name+'.mesh', 'art/'+name+'.mdf2']
        self.asset(paths[0], mesh)
        self.asset(paths[1], mdf('art/'+name+'.tex', shader, slot))
        self.asset('art/'+name+'.tex', texture)
        self.asset(logical, pfb(paths, flags))
        reached = {logical, *paths, 'art/'+name+'.tex'}
        return Candidate({'part': part, 'prefab': logical, 'native_id': identity, 'variant': variant}, reached, reached.copy())

    def plan(self, groups, hidden=None, rules=None, records=(), cancelled=lambda: None, hidden_mesh=lambda key: False):
        def dependencies(key, source):
            asset = source.get(key) or self.game.find(key)
            return mc.mdf_dependencies(asset.path.read_bytes()) if key.endswith('.mdf2') else ()
        fingerprints = AppearanceFingerprints(self.source, self.game, records, dependencies, cancelled, set(), hidden_mesh)
        return deduplicate_groups(groups, fingerprints, hidden or {}, rules or [], mc.PART_CATEGORY, companion_candidates)

    def test_copied_models_materials_and_textures_merge_across_paths_and_native_ids(self):
        a, b = self.outfit('ch001_00_00', 1), self.outfit('ch001_31_00_longer', 2)
        plans = self.plan([[b], [a]])
        self.assertEqual(len(plans), 1)
        self.assertEqual(plans[0].covered_targets, [b.record])
        self.assertEqual(plans[0].duplicate_assets, b.changed)

    def test_texture_model_material_slot_and_opaque_prefab_differences_stay_separate(self):
        a = self.outfit('base', 1)
        for index, changed in enumerate(({'texture': b'blue'}, {'mesh': b'another mesh'}, {'shader': 1},
                                         {'slot': 'NormalMap'}, {'flags': 42}), 2):
            with self.subTest(changed=changed):
                b = self.outfit('variant'+str(index), index, **changed)
                self.assertEqual(len(self.plan([[a], [b]])), 2)

    def test_streaming_texture_difference_prevents_merge(self):
        a, b = self.outfit('first', 1), self.outfit('second', 2)
        self.asset('art/first.tex', b'large red', streaming=True)
        self.asset('art/second.tex', b'large blue', streaming=True)
        self.assertEqual(len(self.plan([[a], [b]])), 2)

    def test_texture_only_edits_keep_different_original_models(self):
        a, b = self.outfit('first', 1), self.outfit('second', 2)
        for candidate in (a, b):
            key = next(p for p in candidate.reached if p.endswith('.mesh'))
            del self.source.assets[key, False]
            candidate.changed.remove(key)
        self.assertEqual(len(self.plan([[a], [b]])), 2)

    def test_hide_rules_and_supplied_parts_are_part_of_the_outfit(self):
        a, b = self.outfit('first', 1), self.outfit('second', 2)
        self.assertEqual(len(self.plan([[a], [b]], rules=[{'BodyID': 1, 'IsVisibleCloak': False}])), 2)
        hair = self.outfit('hair', 3, part='HAIR')
        self.assertEqual(len(self.plan([[a], [b, hair]])), 2)

    def test_duplicate_accessories_keep_all_families_and_bodies_equip_the_same_entry(self):
        bodies = [self.outfit('ch001_'+family+'_00', i) for i, family in enumerate(('00', '31'))]
        cloaks = [self.outfit('ch001_'+family+'_01', 10+i, part='CLOAK') for i, family in enumerate(('00', '31'))]
        plans = self.plan([[c] for c in bodies+cloaks])
        self.assertEqual(len(plans), 2)
        entries = [p.entry(mc.PART_CATEGORY[p.group[0].record['part']]) for p in plans]
        body = next(e for e in entries if e['category']=='body')
        self.assertEqual(len(companion_candidates(body, entries, 'cloak')), 1)
        self.assertEqual(len(body['coveredTargets']), 1)

    def test_same_bodies_with_different_companion_appearances_do_not_merge(self):
        bodies = [self.outfit('ch001_'+family+'_00', i) for i, family in enumerate(('00', '31'))]
        cloaks = [self.outfit('ch001_'+family+'_01', 10+i, part='CLOAK', texture=str(i).encode()) for i, family in enumerate(('00', '31'))]
        self.assertEqual(len(self.plan([[c] for c in bodies+cloaks])), 4)

    def test_hq_extra_geometry_requires_placeholder_proof_and_identical_material(self):
        a, b = self.outfit('body', 1), self.outfit('body_hq', 1, variant='hq')
        ghost = ['art/ghost.mesh', 'art/ghost.mdf2']
        self.asset(ghost[0], b'placeholder')
        self.asset(ghost[1], mdf('art/body_hq.tex'))
        paths = ['art/body_hq.mesh', 'art/body_hq.mdf2', *ghost]
        self.asset(b.record['prefab'], pfb(paths))
        b.reached.update(ghost); b.changed.update(ghost)
        for c, resources in ((a, ['art/body.mesh', 'art/body.mdf2']), (b, paths)):
            self.asset(c.record['prefab'], pfb(resources), original=True)
        records = [a.record, b.record]
        self.assertEqual(len(self.plan([[a], [b]], records=records)), 2)
        self.assertEqual(len(self.plan([[a], [b]], records=records, hidden_mesh=lambda key: key==ghost[0])), 1)
        self.asset('art/body_hq.mdf2', mdf('art/body_hq.tex', shader=2))
        self.assertEqual(len(self.plan([[a], [b]], records=records, hidden_mesh=lambda key: key==ghost[0])), 2)

    def test_resource_slot_order_and_unknown_fields_are_preserved(self):
        paths = ['art/first.mesh', 'art/other.mesh']
        original = pfb(paths)
        switched = bytearray(original)
        left, right = struct.unpack_from('<QQ', switched, 56)
        struct.pack_into('<QQ', switched, 56, right, left)
        self.assertNotEqual(prefab_signature(original, lambda p:p), prefab_signature(bytes(switched), lambda p:p))
        self.assertNotEqual(prefab_signature(original, lambda p:p), prefab_signature(pfb(paths, 1), lambda p:p))

    def test_stock_hq_context_with_no_extra_authored_assets_does_not_create_an_outfit(self):
        a, b = self.outfit('body', 1), self.outfit('body_hq', 1, variant='hq')
        for c in (a, b):
            key = c.record['prefab']
            self.originals[key, False] = self.source.assets.pop((key, False))
            c.changed = {'art/shared.tex'}
        self.asset('art/shared.tex', b'changed')
        a.changed.add('art/body.mdf2')
        self.assertEqual(len(self.plan([[a], [b]])), 1)
        b.changed.add('art/body_hq.mdf2')
        self.asset('art/body_hq.mdf2', mdf('art/body_hq.tex', shader=1))
        self.assertEqual(len(self.plan([[a], [b]])), 2)

    def test_cancel_during_comparison_is_not_treated_as_uncertain_appearance(self):
        a = self.outfit('body', 1)
        def cancel(): raise InputError('cancelled', 'CANCELLED')
        with self.assertRaises(InputError): self.plan([[a]], cancelled=cancel)


if __name__ == '__main__': unittest.main()
