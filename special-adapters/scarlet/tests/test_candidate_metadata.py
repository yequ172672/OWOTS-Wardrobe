"""Offline structural checks for the generated Scarlet candidate.

This test never imports or executes Lua and never opens a game asset.  It
guards the source provenance, private route map and actor hard-gate metadata
that make the manually migrated candidate reviewable.
"""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[4]
ADAPTER = ROOT / "re-engine-mcp-CN" / "special-adapters" / "scarlet"


class ScarletCandidateMetadataTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.path_map = json.loads(
            (ADAPTER / "manifest" / "runtime-path-map.json").read_text(encoding="utf-8")
        )
        cls.actor = json.loads(
            (ADAPTER / "manifest" / "actor-contract.json").read_text(encoding="utf-8")
        )
        cls.lua = (ADAPTER / "src" / "scarlet_manual_adapter.lua").read_text(encoding="utf-8")

    def test_both_variants_have_full_route_maps(self) -> None:
        self.assertEqual(
            set(self.path_map["variants"]),
            {"scarlet_hat_static", "scarlet_no_hat_static"},
        )
        for variant in self.path_map["variants"].values():
            self.assertEqual(variant["pathMapEntryCount"], 120)
            self.assertEqual(len(variant["pathMap"]), 120)
            self.assertGreater(len(variant["files"]), 0)
            for source, target in variant["pathMap"].items():
                self.assertTrue(source and target)
                self.assertFalse(Path(source).drive or source.startswith("\\\\"))
                self.assertFalse(Path(target).drive or target.startswith("\\\\"))
                self.assertTrue(target.startswith("mods/"), target)

    def test_actor_contract_is_explicit_and_hard_gated(self) -> None:
        root = self.actor["actorRootContract"]
        self.assertEqual(root["actorJointCount"], 264)
        self.assertEqual(root["bodyJointCount"], 577)
        self.assertEqual(len(root["actorJointNames"]), 264)
        self.assertEqual(len(root["bodyJointNames"]), 577)
        self.assertEqual(len(root["nativeStageRoles"]), 11)
        evidence = self.actor["wholePlayerEvidence"]
        self.assertEqual(evidence["scarletInstanceCount"], 371)
        self.assertEqual(evidence["stockInstanceCount"], 261)
        self.assertTrue(evidence["commonPrefixIsIdentical"])
        self.assertEqual(
            sum(item["delta"] for item in evidence["additionalTypeCounts"].values()),
            110,
        )
        # The resource map intentionally does not pretend that the extra
        # actor PFB is a wardrobe asset.
        self.assertIn("not in static wardrobe PFBs", evidence["deliveryStatus"])
        unresolved = evidence["unresolvedRuntimePrerequisites"]
        self.assertEqual(
            unresolved["wholePlayerActorInstanceCreation"]["status"],
            "not_implemented",
        )
        self.assertEqual(unresolved["ragdoll"]["type"], "via.dynamics.Ragdoll")
        self.assertEqual(unresolved["ragdoll"]["scarletOffset"], "0x5DF0")
        self.assertEqual(unresolved["ragdoll"]["gameOffset"], "0x56B0")
        self.assertFalse(self.actor["status"]["runtimeGameTested"])

    def test_generated_lua_has_provenance_gate_and_private_routing(self) -> None:
        self.assertIn(
            "B280101CDEC954F73EACE41527379500E6367504644F775B72291FC2A160A272",
            self.lua,
        )
        self.assertNotIn("D:/CODE/re", self.lua)
        self.assertNotIn("D:\\\\CODE\\\\re", self.lua)
        self.assertNotIn("参考文件", self.lua)
        self.assertIn("scarlet_hat_static", self.lua)
        self.assertIn("scarlet_no_hat_static", self.lua)
        self.assertIn("mods/{id}/dynamic/rig.fbxskel", self.lua)
        self.assertIn("scarlet_gate.static_catalog_verified()", self.lua)
        self.assertIn("local function route_map", self.lua)
        self.assertIn("restorePending", self.lua)
        self.assertIn("blocked_actor_contract", self.lua)
        self.assertIn("actor_contract_preflight_missing", self.lua)
        self.assertIn("adapter.resolve_all(frame,true)", self.lua)
        self.assertIn("function self.resolve_all(frame,read_only)", self.lua)
        self.assertIn("if not read_only then release_all_sources()end", self.lua)
        self.assertIn("if not read_only then local retired=", self.lua)
        self.assertIn("scarlet_gate.set_actor_preflight(actor_preflight)", self.lua)
        self.assertIn("scarlet_reset_required=false", self.lua)
        self.assertIn("script_reset_requires_restart", self.lua)
        for line in self.lua.splitlines():
            if "re.on_script_reset(function()" in line:
                self.assertNotIn(".close", line)
                self.assertNotIn("pcall", line)
        # The preflight must be encountered before the first dynamic load in
        # Isolation.step, so a missing whole-player actor cannot partially
        # switch the rig and only fail later in a native stage.
        self.assertLess(
            self.lua.index("S.phase='blocked_actor_contract'"),
            self.lua.index("if not load()then return end"),
        )

        # Original dynamic root paths must not survive in the generated
        # resource routes.  Actor-correction paths are the documented hard
        # prerequisite and are checked separately by actor-contract.json.
        self.assertNotIn("art/mods/scarlet/isolation/", self.lua)
        self.assertNotIn("art/mods/scarlet/p/rig_", self.lua)
        self.assertNotIn("art/mods/scarlet/p/empty_chain_", self.lua)

    def test_unresolved_actor_paths_are_documented(self) -> None:
        unresolved = {
            item["source"]
            for role in self.actor["roleRequirements"]
            for item in role.get("layers", [])
            if item.get("targetTemplate") is None
        }
        self.assertGreaterEqual(len(unresolved), 6)
        # These paths are deliberately retained as an actor-contract signal;
        # they may not be silently rewritten to a nonexistent target.
        for path in unresolved:
            self.assertIn(path, self.lua)

    def test_lua_sources_parse_with_real_parser(self) -> None:
        """Parse both Lua sources without executing the game adapter."""
        from luaparser import ast

        ast.parse(
            (ADAPTER / "src" / "scarlet_gate.lua").read_text(encoding="utf-8")
        )
        ast.parse(self.lua)

    def test_native_entry_points_are_gate_first(self) -> None:
        """Every derived native write path checks the exact gate first.

        This is a source-level check: constructing the adapter requires the
        real game SDK, so the test records the callback ordering that can be
        proven offline without pretending to be a live native acceptance test.
        """
        ordered_paths = (
            ("re.on_application_entry(C.entry,function()", "scarlet_gate.allow('UpdateConstraintsEnd')", "controller:step(C.entry)"),
            ("sdk.hook(methods.update_joint,function(args)", "scarlet_gate.allow('UpdateJoint')", "core.before("),
            ("sdk.hook(methods[hook.key],function(args)", "scarlet_gate.allow('private_parts_request')", "record_request("),
            ("sdk.hook(methods[h.key],function(args)", "scarlet_gate.allow('private_parts_closure')", "object:set_field('prefab'"),
            ("re.on_frame(function()", "scarlet_gate.allow('private_parts_frame')", "instance.step()"),
            ("re.on_pre_application_entry('BeginRendering',function()", "scarlet_gate.allow('BeginRendering')", "instance.step()"),
            ("sdk.hook(methods.update_joint,function(args)", "scarlet_gate.allow('left_fit_updateJoint')", "setq(j.L_UpperArm"),
            ("re.on_application_entry('UpdateBehavior',function()", "scarlet_gate.allow('UpdateBehavior')", "release.step()"),
            ("sdk.hook(methods.gm_setup_visual,function(args)", "scarlet_gate.allow('weapon_setup_visual')", "args[3]="),
            ("sdk.hook(methods.gm_update_visual,function(args)", "scarlet_gate.allow('weapon_update_visual')", "gm:get_field"),
            ("re.on_pre_application_entry('UpdateMotion',function()", "scarlet_gate.allow('UpdateMotion')", "isolation.step()"),
        )
        occurrences = {}
        for marker, gate, write in ordered_paths:
            occurrence = occurrences.get(marker, 0)
            start = -1
            search_from = 0
            for _ in range(occurrence + 1):
                start = self.lua.find(marker, search_from)
                if start < 0:
                    break
                search_from = start + len(marker)
            occurrences[marker] = occurrence + 1
            self.assertGreaterEqual(start, 0, marker)
            gate_at = self.lua.find(gate, start)
            write_at = self.lua.find(write, start)
            self.assertGreaterEqual(gate_at, start, (marker, gate))
            self.assertGreaterEqual(write_at, start, (marker, write))
            self.assertLess(gate_at, write_at, (marker, gate, write))

    def test_actor_preflight_resolver_is_read_only(self) -> None:
        """The gate's render-side actor probe cannot retire native leases."""
        preflight = self.lua.index("local function actor_preflight()")
        preflight_end = self.lua.index("\nscarlet_gate.set_actor_preflight", preflight)
        body = self.lua[preflight:preflight_end]
        self.assertIn("adapter.resolve_all(frame,true)", body)
        self.assertNotIn("release_source", body)
        self.assertNotIn("release_all_sources", body)
        resolver = self.lua.index("function self.resolve_all(frame,read_only)")
        self.assertLess(
            self.lua.index("if not read_only then release_all_sources()end", resolver),
            self.lua.index("if not read_only then local retired=", resolver),
        )

    def test_gate_blocks_before_actor_contract_and_recovers(self) -> None:
        """Exercise the real Lua gate with a read-only mocked bridge."""
        from lupa import LuaRuntime

        lua = LuaRuntime(unpack_returned_tuples=True)
        gate_source = (
            (ADAPTER / "src" / "scarlet_gate.lua").read_text(encoding="utf-8")
            + "\nreturn scarlet_gate"
        )
        gate = lua.execute(gate_source)
        table = lua.table_from
        parts = table(
            [
                table(
                    {
                        "part": "BODY",
                        "prefab": "mods/scarlet_hat_static/b60902b0c9f97048/ch001_00_00_HQ.pfb",
                        "catalog": "mods/scarlet_hat_static/c406cadd4073f518/playerbodypartslisthq_1st.user",
                    }
                ),
                table(
                    {
                        "part": "HEAD",
                        "prefab": "mods/scarlet_hat_static/2670bb075a9de61f/ch001_00_10_HQ.pfb",
                        "catalog": "mods/scarlet_hat_static/cf3fdf041f9fbd65/playerheadpartslisthq_1st.user",
                    }
                ),
                table(
                    {
                        "part": "HAIR",
                        "prefab": "mods/scarlet_hat_static/fa78e476fb9051c2/ch001_00_20_HQ.pfb",
                        "catalog": "mods/scarlet_hat_static/1f9bad298db57811/playerhairpartslisthq_1st.user",
                    }
                ),
            ]
        )
        snapshot = table(
            {
                "effectiveBodyModId": "scarlet_hat_static",
                "ready": True,
                "busy": False,
                "restoreUnresolved": False,
                "catalogRowsVerified": True,
                "supporterAddress": "0x1234",
                "playerEntityAddress": "0x5678",
                "sessionId": "gate-test",
                "selectionRevision": 1,
                "parts": parts,
            }
        )
        lua.globals().test_snapshot = snapshot
        lua.globals().owots_appearance_lab = lua.execute(
            "return {get_scarlet_adapter_snapshot=function() return _G.test_snapshot end}"
        )

        gate["set_actor_preflight"](
            lua.eval(
                "function() return false, 'actor_contract_missing:actor_corrections' end"
            )
        )
        allowed, reason = gate["allow"]("test-blocked")
        self.assertFalse(allowed)
        self.assertEqual(reason, "actor_contract_missing:actor_corrections")
        status = gate["status"]()
        self.assertTrue(status["actorContractBlocked"])
        self.assertFalse(status["allowed"])

        gate["set_actor_preflight"](lua.eval("function() return true end"))
        allowed, reason = gate["allow"]("test-recover")
        self.assertTrue(allowed)
        self.assertEqual(reason, "ready")
        status = gate["status"]()
        self.assertFalse(status["actorContractBlocked"])
        self.assertTrue(status["allowed"])

    def test_gate_queues_restore_until_game_thread_flush(self) -> None:
        """A render-side denial must not execute a native restore handler."""
        from lupa import LuaRuntime

        lua = LuaRuntime(unpack_returned_tuples=True)
        gate_source = (
            (ADAPTER / "src" / "scarlet_gate.lua").read_text(encoding="utf-8")
            + "\nreturn scarlet_gate"
        )
        gate = lua.execute(gate_source)
        table = lua.table_from
        lua.globals().test_snapshot = table(
            {
                "effectiveBodyModId": "scarlet_hat_static",
                "ready": True,
                "busy": False,
                "restoreUnresolved": False,
                "catalogRowsVerified": True,
                "supporterAddress": "0x1234",
                "playerEntityAddress": "0x5678",
                "sessionId": "queue-test",
                "selectionRevision": 1,
                "parts": table(
                    [
                        table(
                            {
                                "part": "BODY",
                                "prefab": "mods/scarlet_hat_static/b60902b0c9f97048/ch001_00_00_HQ.pfb",
                                "catalog": "mods/scarlet_hat_static/c406cadd4073f518/playerbodypartslisthq_1st.user",
                            }
                        ),
                        table(
                            {
                                "part": "HEAD",
                                "prefab": "mods/scarlet_hat_static/2670bb075a9de61f/ch001_00_10_HQ.pfb",
                                "catalog": "mods/scarlet_hat_static/cf3fdf041f9fbd65/playerheadpartslisthq_1st.user",
                            }
                        ),
                        table(
                            {
                                "part": "HAIR",
                                "prefab": "mods/scarlet_hat_static/fa78e476fb9051c2/ch001_00_20_HQ.pfb",
                                "catalog": "mods/scarlet_hat_static/1f9bad298db57811/playerhairpartslisthq_1st.user",
                            }
                        ),
                    ]
                ),
            }
        )
        lua.globals().owots_appearance_lab = lua.execute(
            "return {get_scarlet_adapter_snapshot=function() return _G.test_snapshot end}"
        )
        gate["set_actor_preflight"](lua.eval("function() return true end"))
        self.assertTrue(gate["allow"]("game-ready")[0])
        lua.globals().restore_calls = 0
        gate["on_disable"](
            lua.eval(
                "function() _G.restore_calls=_G.restore_calls+1;return true end"
            )
        )

        lua.globals().test_snapshot["ready"] = False
        allowed, reason = gate["allow"]("render-deny")
        self.assertFalse(allowed)
        self.assertTrue(reason.startswith("restore_queued:"))
        self.assertEqual(lua.globals().restore_calls, 0)
        self.assertTrue(gate["status"]()["restoreQueued"])

        self.assertTrue(gate["flush_restore"]("game-thread"))
        self.assertEqual(lua.globals().restore_calls, 1)
        status = gate["status"]()
        self.assertFalse(status["restoreQueued"])
        self.assertFalse(status["restorePending"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
