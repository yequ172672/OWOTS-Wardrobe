import json
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
import sys
from types import SimpleNamespace
import zlib

ROOT = Path(__file__).resolve().parents[1]
REAL_OWOTS_BASELINE = (
    ROOT.parents[1] / "_validation" / "2b-skeleton-static-audit-20260915"
    / "game-reference" / "natives" / "stm" / "art" / "model" / "character"
    / "ch0" / "ch001_00" / "90" / "ch001_00_90.fbxskel.7"
)
REAL_OWOTS_CUSTOM = (
    ROOT.parents[1] / "_validation" / "mod-converter-round2-20260915" / "2b"
    / "correct-paths" / "natives" / "stm" / "art" / "model" / "character"
    / "ch0" / "ch001_00" / "90" / "ch001_00_90.fbxskel.7"
)
sys.path.insert(0, str(ROOT))
import mod_converter as converter


class ConverterSafetyTests(unittest.TestCase):
    @staticmethod
    def _fbxskel_bytes(count=93, *, positions=None, rotations=None, scales=None,
                       names=None, parents=None, segment_scaling=None):
        """Build a small valid v7 fixture without shipping game assets."""
        names = list(names or (f"Joint{i}" for i in range(count)))
        if len(names) != count:
            raise ValueError("fixture name count mismatch")
        positions = positions or [(float(i), float(i + 1), float(i + 2)) for i in range(count)]
        rotations = rotations or [(0.0, 0.0, 0.0, 1.0) for _ in range(count)]
        scales = scales or [(1.0, 1.0, 1.0) for _ in range(count)]
        parents = list(parents or [-1] + list(range(count - 1)))
        segment_scaling = list(segment_scaling or [False for _ in range(count)])
        data_offset = 48
        lookup_offset = data_offset + count * converter.FBXSKEL_BONE_STRUCT_SIZE
        string_offset = (lookup_offset + count * 8 + 15) & ~15
        payload = bytearray(string_offset)
        name_offsets = []
        for name in names:
            name_offsets.append(len(payload))
            payload.extend(name.encode("utf-16-le"))
            payload.extend(b"\0\0")
        struct.pack_into("<II", payload, 0, converter.FBXSKEL_VERSION, converter.FBXSKEL_MAGIC)
        struct.pack_into("<QQI", payload, 16, data_offset, lookup_offset, count)
        for index in range(count):
            entry = data_offset + index * converter.FBXSKEL_BONE_STRUCT_SIZE
            struct.pack_into("<Q", payload, entry, name_offsets[index])
            struct.pack_into("<I", payload, entry + 8, index + 1)
            struct.pack_into("<hh", payload, entry + 12, parents[index], index)
            struct.pack_into("<4f", payload, entry + 16, *rotations[index])
            struct.pack_into("<3f", payload, entry + 32, *positions[index])
            struct.pack_into("<3f", payload, entry + 44, *scales[index])
            payload[entry + 56] = 1 if segment_scaling[index] else 0
            struct.pack_into("<II", payload, lookup_offset + index * 8, index + 1, index)
        return bytes(payload)

    @staticmethod
    def _write_v4_pak(path: Path, payload: bytes, compression: int = 0,
                      declared_size: int | None = None) -> None:
        if compression == 1:
            compressor = zlib.compressobj(wbits=-15)
            stored = compressor.compress(payload) + compressor.flush()
        elif compression == 2:
            import zstandard
            stored = zstandard.ZstdCompressor(level=1).compress(payload)
        else:
            stored = payload
        declared = len(payload) if declared_size is None else declared_size
        offset = 16 + 48
        header = b"KPKA" + struct.pack("<BBHii", 4, 0, 0, 1, 0)
        record = struct.pack("<IIqqqqQ", 0x1234, 0x5678, offset, len(stored), declared,
                             compression, 0)
        path.write_bytes(header + record + stored)

    def test_logical_path_rejects_escape_and_keeps_stream_marker(self):
        with self.assertRaises(ValueError):
            converter.logical_path("../outside.pfb")
        logical, version, streaming = converter.split_versioned(
            "natives/STM/streaming/Art/Model/A.tex.251111100")
        self.assertEqual(logical, "Art/Model/A.tex")
        self.assertEqual(version, "251111100")
        self.assertTrue(streaming)

    def test_hash_matches_manba_pak_entry(self):
        self.assertEqual(
            converter.native_hash("natives/stm/art/model/character/ch0/ch001_00/00/ch001_00_00.mesh.260209350"),
            (1239092683, 1735690464),
        )

    def test_safe_id_keeps_ascii_and_separates_unicode_names(self):
        self.assertEqual(converter.safe_id("my.mod-1"), "my.mod-1")
        self.assertNotEqual(converter.safe_id("服装甲"), converter.safe_id("服装乙"))
        self.assertTrue(converter.MOD_ID_RE.fullmatch(converter.safe_id("服装甲")))

    def test_fbxskel_parser_keeps_ordered_names_and_all_bind_positions(self):
        payload = self._fbxskel_bytes()
        info = converter.parse_fbxskel(payload, "fixture.fbxskel")
        self.assertEqual(info.bone_count, 93)
        self.assertEqual(info.names[0], "Joint0")
        self.assertEqual(info.names[-1], "Joint92")
        self.assertEqual(info.parent_indices[:3], (-1, 0, 1))
        self.assertEqual(info.positions[17], (17.0, 18.0, 19.0))
        self.assertEqual(info.bind_positions()["Joint17"], [17.0, 18.0, 19.0])

    @unittest.skipUnless(REAL_OWOTS_BASELINE.is_file(),
                         "local OWOTS validation fixture is unavailable")
    def test_real_owots_baseline_accepts_unpaired_symmetry_sentinel(self):
        info = converter.parse_fbxskel(
            REAL_OWOTS_BASELINE.read_bytes(), str(REAL_OWOTS_BASELINE)
        )
        self.assertEqual(info.bone_count, converter.ACTOR_SKELETON_BONE_COUNT)
        self.assertEqual(info.names[0], "root")
        self.assertEqual(info.symmetry_indices[65], -1)
        self.assertIn(-1, info.symmetry_indices)

    @unittest.skipUnless(REAL_OWOTS_BASELINE.is_file() and REAL_OWOTS_CUSTOM.is_file(),
                         "local OWOTS 2B validation fixtures are unavailable")
    def test_real_owots_2b_skeleton_keeps_topology_with_source_bind_positions(self):
        baseline = converter.parse_fbxskel(
            REAL_OWOTS_BASELINE.read_bytes(), str(REAL_OWOTS_BASELINE)
        )
        source = converter.parse_fbxskel(
            REAL_OWOTS_CUSTOM.read_bytes(), str(REAL_OWOTS_CUSTOM)
        )
        converter.compare_actor_skeleton_to_baseline(source, baseline)
        self.assertEqual(source.names, baseline.names)
        self.assertNotEqual(source.positions[3], baseline.positions[3])

    def test_fbxskel_baseline_comparison_accepts_position_shape_and_quaternion_sign(self):
        positions = [(float(i), float(i + 1), float(i + 2)) for i in range(93)]
        positions[17] = (17.5, 18.5, 19.5)
        rotations = [(0.0, 0.0, 0.0, 1.0) for _ in range(93)]
        rotations[5] = (0.0, 0.0, 0.0, -1.0)
        source = converter.parse_fbxskel(
            self._fbxskel_bytes(positions=positions, rotations=rotations), "source"
        )
        baseline = converter.parse_fbxskel(self._fbxskel_bytes(), "baseline")
        converter.compare_actor_skeleton_to_baseline(source, baseline)
        changed_scales = [(1.0, 1.0, 1.0) for _ in range(93)]
        changed_scales[5] = (1.1, 1.0, 1.0)
        changed = converter.parse_fbxskel(
            self._fbxskel_bytes(scales=changed_scales), "changed"
        )
        with self.assertRaisesRegex(ValueError, "scale differs"):
            converter.compare_actor_skeleton_to_baseline(changed, baseline)
        segment_scaling = [False for _ in range(93)]
        segment_scaling[5] = True
        changed_segments = converter.parse_fbxskel(
            self._fbxskel_bytes(segment_scaling=segment_scaling), "changed-segment-scaling"
        )
        with self.assertRaisesRegex(ValueError, "segment scaling differs"):
            converter.compare_actor_skeleton_to_baseline(changed_segments, baseline)

    def test_valid_actor_skeleton_is_private_and_published_in_manifest(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            rig_path = root / "natives/stm/art/mods/example/rig.fbxskel.7"
            mesh_path = root / "natives/stm/art/mods/example/body.mesh.260209350"
            rig_path.parent.mkdir(parents=True)
            rig_path.write_bytes(self._fbxskel_bytes())
            mesh_path.write_bytes(b"body mesh")
            # Keep the game baseline outside the source tree.  SourceFiles
            # indexes every resource below its input root, so a fixture copy
            # there would look like a second MOD-owned actor skeleton.
            baseline_path = root.parent / f"{root.name}-baseline.fbxskel.7"
            report = converter.Report("convert", root)
            args = converter.make_parser().parse_args([
                "convert", "--input", str(root), "--output", str(root / "out"),
                "--id", "example", "--category", "body", "--hide-part", "CLOAK",
            ])
            instance = converter.Converter(args, report)
            instance.bundle = converter.InputBundle(root, report)
            instance.bundle.load()
            baseline_path.write_bytes(self._fbxskel_bytes())
            prefab = "GameDesign/Action/Player/_Prefab/PartsList/Body/example.pfb"
            catalog = "gamedesign/system/catalogdata/playerbodypartslist_1st.user"
            prefab_path = root / "prefab.pfb.18"
            prefab_path.write_bytes(b"prefab")
            prefab_asset = converter.Asset(prefab, "18", False, prefab_path, "game", 6)
            mesh_asset = instance.bundle.source.get("art/mods/example/body.mesh")
            self.assertIsNotNone(mesh_asset)
            instance.part_roots = {"BODY": (prefab, catalog, 123)}
            instance.args.category = "body"
            instance.nodes = {
                prefab.casefold(): converter.ResourceNode(prefab, prefab_asset, (mesh_asset.logical,)),
                mesh_asset.logical.casefold(): converter.ResourceNode(mesh_asset.logical, mesh_asset, ()),
            }
            baseline_asset = converter.Asset(
                converter.ACTOR_SKELETON_BASELINE_RESOURCE, "7", False,
                baseline_path, "game", baseline_path.stat().st_size,
            )

            class FakeGame:
                def find(self, logical, streaming=False):
                    return None if streaming or logical != converter.ACTOR_SKELETON_BASELINE_RESOURCE else baseline_asset

            instance.game = FakeGame()
            instance._prepare_actor_skeleton()
            self.assertIsNotNone(instance.actor_skeleton_info)
            self.assertEqual(instance.actor_skeleton_body_mesh, mesh_asset.logical)
            instance._compute_routes()
            manifest = instance._actor_skeleton_manifest("example")
            self.assertEqual(manifest["kind"], "actor-fbxskel-v1")
            self.assertTrue(manifest["resource"].startswith("mods/example/"))
            self.assertTrue(manifest["bodyMesh"].startswith("mods/example/"))
            self.assertEqual(len(manifest["jointNames"]), 93)
            self.assertEqual(len(manifest["bindPositions"]), 93)
            self.assertEqual(manifest["baselineResource"], converter.ACTOR_SKELETON_BASELINE_RESOURCE)
            instance._audit_unconsumed_mod_assets()
            self.assertFalse(report.errors)

    def test_actor_skeleton_cannot_bind_non_body_category(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            rig_path = root / "natives/stm/art/mods/example/rig.fbxskel.7"
            rig_path.parent.mkdir(parents=True)
            rig_path.write_bytes(self._fbxskel_bytes())
            report = converter.Report("convert", root)
            args = converter.make_parser().parse_args([
                "convert", "--input", str(root), "--output", str(root / "out"),
                "--id", "example", "--category", "gauntlet",
            ])
            instance = converter.Converter(args, report)
            instance.bundle = converter.InputBundle(root, report)
            instance.bundle.load()
            instance.part_roots = {"GAUNTLET": ("example.pfb", "example.user", 1)}
            instance._prepare_actor_skeleton()
            self.assertIsNone(instance.actor_skeleton_info)
            self.assertTrue(any(issue.code == "ACTOR_SKELETON_BODY_REQUIRED"
                                for issue in report.errors))
            instance._audit_unconsumed_mod_assets()
            self.assertTrue(any("rig.fbxskel" in path
                                for path in report.stats["unconsumedModResources"]))

    def test_expanded_actor_skeleton_is_blocked_during_inspect(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            rig = root / "natives/stm/art/mods/scarlet/rig.fbxskel.7"
            rig.parent.mkdir(parents=True)
            rig.write_bytes(self._fbxskel_bytes(264))
            report_path = root.parent / (root.name + "-inspect.json")
            args = converter.make_parser().parse_args([
                "inspect", "--input", str(root), "--report", str(report_path),
            ])
            self.assertEqual(converter.run(args), 2)
            result = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertTrue(any(item["code"] == "ACTOR_SKELETON_TOPOLOGY_UNSUPPORTED"
                                for item in result["issues"]))

    def test_lenient_modinfo_ignores_free_text(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "modinfo.ini").write_text(
                "name=2B\nversion=v1\n\n中文说明不是 INI\nB站链接：https://example.invalid\n",
                encoding="utf-8")
            report = converter.Report("inspect", root)
            info = converter.parse_modinfo(root, report)
            self.assertEqual(info.values["name"], "2B")
            self.assertTrue(any(item.code == "MODINFO_FREE_TEXT" for item in report.issues))

    def test_streaming_companion_is_not_duplicate(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            base = root / "natives" / "stm" / "art" / "a.tex.251111100"
            high = root / "natives" / "stm" / "streaming" / "art" / "a.tex.251111100"
            base.parent.mkdir(parents=True)
            high.parent.mkdir(parents=True)
            base.write_bytes(b"base")
            high.write_bytes(b"high")
            report = converter.Report("inspect", root)
            source = converter.SourceFiles.from_directory(root, report)
            self.assertEqual(len(source.assets), 2)
            self.assertIsNotNone(source.get("art/a.tex", False))
            self.assertIsNotNone(source.get("art/a.tex", True))
            self.assertFalse(any(item.code == "DUPLICATE_RESOURCE" for item in report.issues))

    def test_protected_marker_is_reported_before_extraction(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "protected.pak"
            header = b"KPKA" + struct.pack("<BBHii", 4, 0, 0, 0, 0)
            path.write_bytes(header + b"padding" + b"WOTSPK01" + b"cipher" + b"WOTSPV03")
            report = converter.Report("inspect", path)
            archive = converter.PakArchive(path, report)
            archive.parse()
            found = archive.detect_protected()
            self.assertIsNotNone(found)
            self.assertEqual(found["header"], 23)

    def test_pak_bounds_reject_negative_entry(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "bad.pak"
            header = b"KPKA" + struct.pack("<BBHii", 4, 0, 0, 1, 0)
            record = struct.pack("<IIqqqqQ", 1, 2, -1, 1, 1, 0, 0)
            path.write_bytes(header + record)
            report = converter.Report("inspect", path)
            archive = converter.PakArchive(path, report)
            with self.assertRaises(converter.ConversionError):
                archive.parse()

    def test_hash_index_rejects_traversal_but_allows_unknown_game_extensions(self):
        report = converter.Report("inspect", Path("hash-list"))
        index = converter.HashIndex(report)
        index.add("natives/stm/systems/shader/example.vsdf.260605161")
        self.assertEqual(len(index.by_hash), 1)
        index.add("natives/stm/../outside.mesh.1")
        self.assertTrue(any(item.code == "HASH_PATH_INVALID" for item in report.errors))

    def test_pak_raw_deflate_and_zstd_payloads_are_bounded(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            cases = [("raw.pak", b"raw-data", 0)]
            cases.append(("deflate.pak", b"deflate-data" * 20, 1))
            if importlib.util.find_spec("zstandard"):
                cases.append(("zstd.pak", b"zstd-data" * 20, 2))
            for name, payload, compression in cases:
                path = root / name
                self._write_v4_pak(path, payload, compression)
                report = converter.Report("inspect", path)
                archive = converter.PakArchive(path, report)
                archive.parse()
                self.assertEqual(archive.read_payload(archive.entries[0]), payload)

    @unittest.skipUnless(importlib.util.find_spec("zstandard"), "zstandard is optional")
    def test_zstd_frame_size_cannot_hide_expansion(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "zstd-bomb.pak"
            self._write_v4_pak(path, b"A" * 1024, 2, declared_size=1)
            report = converter.Report("inspect", path)
            archive = converter.PakArchive(path, report)
            archive.parse()
            with self.assertRaises(converter.ConversionError):
                archive.read_payload(archive.entries[0])

    def test_deflate_declared_size_cannot_hide_expansion(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "bomb.pak"
            self._write_v4_pak(path, b"A" * 4096, 1, declared_size=1)
            report = converter.Report("inspect", path)
            archive = converter.PakArchive(path, report)
            archive.parse()
            with self.assertRaises(converter.ConversionError):
                archive.read_payload(archive.entries[0])

    def test_existing_output_is_not_modified_when_conversion_is_blocked(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            output = root / "already-installed"
            output.mkdir()
            sentinel = output / "conversion-report.json"
            sentinel.write_text("keep this report", encoding="utf-8")
            args = converter.make_parser().parse_args([
                "convert", "--input", str(source), "--output", str(output),
            ])
            self.assertEqual(converter.run(args), 2)
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep this report")

    def test_dynamic_lua_blocks_default_inspect(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            script = root / "reframework" / "autorun" / "dynamic.lua"
            script.parent.mkdir(parents=True)
            script.write_text("-- runtime behavior", encoding="utf-8")
            report_path = root.parent / (root.name + "-inspect.json")
            args = converter.make_parser().parse_args([
                "inspect", "--input", str(root), "--report", str(report_path),
            ])
            self.assertEqual(converter.run(args), 2)
            result = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual(result["status"], "blocked")
            self.assertTrue(any(item["code"] == "DYNAMIC_BEHAVIOR_UNSUPPORTED"
                                for item in result["issues"]))

    def test_missing_required_prefab_dependency_blocks_conversion(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            mesh = source / "natives" / "stm" / "art" / "body.mesh.260209350"
            mesh.parent.mkdir(parents=True)
            mesh.write_bytes(b"mesh")
            output = root / "converted"
            args = converter.make_parser().parse_args([
                "convert", "--input", str(source), "--output", str(output),
                "--category", "body", "--part", "BODY",
                "--prefab", "GameDesign/Action/Player/_Prefab/body.pfb",
            ])
            self.assertEqual(converter.run(args), 2)
            result = json.loads((output / "conversion-report.json").read_text(encoding="utf-8"))
            self.assertTrue(any(item["code"] == "REQUIRED_DEPENDENCY_MISSING"
                                for item in result["issues"]))

    def test_explicit_catalog_role_mismatch_is_blocked(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            report = converter.Report("convert", root)
            args = converter.make_parser().parse_args([
                "convert", "--input", str(root), "--output", str(root / "out"),
                "--category", "body", "--part", "BODY",
                "--prefab", "GameDesign/Action/Player/_Prefab/PartsList/Body/ch001_00_00.pfb",
                "--catalog", "gamedesign/system/catalogdata/playerhairpartslist_1st.user",
                "--native-id", "7482",
            ])
            instance = converter.Converter(args, report)
            instance.bundle = converter.InputBundle(root, report)
            instance.bundle.load()
            with self.assertRaises(converter.ConversionError):
                instance._select_part_roots()
            self.assertTrue(any(item.code == "CATALOG_ROLE_MISMATCH" for item in report.errors))

    def test_selected_catalog_row_must_point_to_manifest_prefab(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            report = converter.Report("convert", root)
            prefab = "GameDesign/Action/Player/_Prefab/PartsList/Body/ch001_00_00.pfb"
            catalog = "gamedesign/system/catalogdata/playerbodypartslist_1st.user"
            args = converter.make_parser().parse_args([
                "convert", "--input", str(root), "--output", str(root / "out"),
                "--category", "body", "--part", "BODY", "--prefab", prefab,
                "--catalog", catalog, "--native-id", "7482",
            ])
            instance = converter.Converter(args, report)
            instance.bundle = converter.InputBundle(root, report)
            instance.bundle.load()

            class FakeWorker:
                def inspect(self, _path):
                    return {"SchemaVersion": 1, "Operation": "inspect", "CrcWarnings": []}

            instance.worker = FakeWorker()
            instance._select_part_roots()
            catalog_bytes = root / "catalog.user.3"
            catalog_bytes.write_bytes(b"catalog")
            asset = converter.Asset(catalog, "3", False, catalog_bytes, "game", catalog_bytes.stat().st_size)
            catalog_module = __import__(
                "owots_vendor.workspace.appearance_catalog", fromlist=["read_parts_catalog"])
            original = catalog_module.read_parts_catalog
            catalog_module.read_parts_catalog = lambda *_args: (
                SimpleNamespace(native_id=7482,
                                 prefab="GameDesign/Action/Player/_Prefab/PartsList/Head/ch001_00_10.pfb"),
            )
            try:
                with self.assertRaises(converter.ConversionError):
                    instance._inspect_node(catalog, asset)
            finally:
                catalog_module.read_parts_catalog = original
            self.assertTrue(any(item.code == "CATALOG_PREFAB_MISMATCH" for item in report.errors))

    def test_fallback_pfb_candidates_are_grouped_by_part(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = (
                root / "GameDesign/Action/Player/_Prefab/PartsList/Body/ch001_99_00.pfb.18",
                root / "GameDesign/Action/Player/_Prefab/PartsList/Head/ch001_99_10.pfb.18",
                root / "GameDesign/Action/Player/_Prefab/PartsList/Hair/ch001_99_20.pfb.18",
            )
            for path in paths:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(path.name.encode())
            report = converter.Report("convert", root)
            args = converter.make_parser().parse_args([
                "convert", "--input", str(root), "--output", str(root / "out"),
                "--category", "body",
            ])
            instance = converter.Converter(args, report)
            instance.bundle = converter.InputBundle(root, report)
            instance.bundle.load()
            instance._select_part_roots()
            self.assertEqual(set(instance.part_roots), {"BODY", "HEAD", "HAIR"})

    def test_ambiguous_fallback_pfb_is_blocked(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in ("ch001_99_00.pfb.18", "ch001_99_01.pfb.18"):
                path = root / "GameDesign/Action/Player/_Prefab/PartsList/Body" / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(name.encode())
            report = converter.Report("convert", root)
            args = converter.make_parser().parse_args([
                "convert", "--input", str(root), "--output", str(root / "out"),
                "--category", "body",
            ])
            instance = converter.Converter(args, report)
            instance.bundle = converter.InputBundle(root, report)
            instance.bundle.load()
            with self.assertRaises(converter.ConversionError):
                instance._select_part_roots()
            self.assertTrue(any(item.code == "PFB_CANDIDATE_AMBIGUOUS" for item in report.errors))

    def test_unconsumed_actor_skeleton_requires_adapter_or_explicit_static_review(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            rig = root / "natives/stm/art/model/character/ch0/ch001_00/90/ch001_00_90.fbxskel.7"
            rig.parent.mkdir(parents=True)
            rig.write_bytes(b"separate actor skeleton fixture")
            for allow, strict in ((False, False), (True, False), (True, True)):
                with self.subTest(allow=allow, strict=strict):
                    report = converter.Report("convert", root)
                    args = SimpleNamespace(worker=None, template=None,
                                           allow_unconsumed_resources=allow,
                                           strict_unconsumed=strict, input=root)
                    instance = converter.Converter(args, report)
                    instance.bundle = converter.InputBundle(root, report)
                    instance.bundle.load()
                    instance._audit_unconsumed_mod_assets()
                    issues = [item for item in report.issues
                              if item.code == "ACTOR_SKELETON_ADAPTER_REQUIRED"]
                    self.assertEqual(len(issues), 1)
                    self.assertEqual(bool(report.errors), strict or not allow)
                    self.assertIn(rig.name, report.stats["unconsumedModResources"][0])

    def test_unconsumed_model_is_strict_unless_explicitly_allowed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            mesh = root / "natives/stm/art/model/body.mesh.260209350"
            mesh.parent.mkdir(parents=True)
            mesh.write_bytes(b"mesh")
            for allow in (False, True):
                report = converter.Report("convert", root)
                args = SimpleNamespace(worker=None, template=None,
                                       allow_unconsumed_resources=allow,
                                       strict_unconsumed=False, input=root)
                instance = converter.Converter(args, report)
                instance.bundle = converter.InputBundle(root, report)
                instance.bundle.load()
                instance._audit_unconsumed_mod_assets()
                if allow:
                    self.assertFalse(report.errors)
                    self.assertTrue(any(item.code == "UNCONSUMED_MOD_RESOURCE" for item in report.issues))
                else:
                    self.assertTrue(any(item.code == "UNCONSUMED_MOD_RESOURCE" for item in report.errors))


if __name__ == "__main__":
    unittest.main()
