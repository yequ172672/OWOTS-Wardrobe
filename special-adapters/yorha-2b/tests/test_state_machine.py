"""Offline regression tests for the 2B skeleton companion.

The Lua adapter cannot be hosted safely outside REFramework, so the tests have
two complementary layers: the Lua source is parsed and checked for the
game-thread/lifecycle ordering, while a small deterministic model exercises
the same lease transitions (including delayed Motion rebuild and quarantine).
No game process, game PAK, or original MOD loader is opened by this script.
"""

from __future__ import annotations

import hashlib
import json
import re
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

from luaparser import ast
from lupa import LuaRuntime


HERE = Path(__file__).resolve()
ROOT = HERE.parents[1]
WORKSPACE = ROOT.parents[2]
TOOLS = ROOT / "tools"
sys.path.insert(0, str(TOOLS))

from build_companion import DEFAULT_SOURCE_RIG, build  # noqa: E402
from validate_companion import (  # noqa: E402
    EXPECTED_SOURCE_SHA256,
    inspect_fbxskel,
    validate_member_name,
    validate_zip,
)


LUA_PATH = ROOT / "src" / "yorha_2b_skeleton_adapter.lua"
REPORT_PATH = WORKSPACE / "_validation" / "2b-skeleton-diagnosis-20260915" / "yorha-2b-offline-report.json"


def _lua_method_metadata(lua_source: str) -> str:
    """Translate the production METHOD_SPECS literals into fake SDK metadata."""

    pattern = re.compile(
        r'\{\s*"([^"]+)",\s*"([^"]+)",\s*"([^"]+)",\s*\{([^}]*)\},\s*"([^"]+)",\s*(true|false),\s*(\d+)\s*\}'
    )
    rows = pattern.findall(lua_source)
    if len(rows) < 20:
        raise AssertionError(f"production METHOD_SPECS not found: {len(rows)}")
    output = []
    for key, type_name, method_name, raw_params, returns, is_static, rva in rows:
        params = re.findall(r'"([^"]+)"', raw_params)
        signature = f"{method_name}({', '.join(params)})"
        full_key = f"{type_name}|{signature}"
        params_lua = "{" + ",".join(json.dumps(item) for item in params) + "}"
        output.append(
            f"[{json.dumps(full_key)}]={{key={json.dumps(key)},returns={json.dumps(returns)},"
            f"static={is_static},rva={rva},params={params_lua}}}"
        )
    return "{" + ",".join(output) + "}"


def _lua_crc_metadata(lua_source: str) -> str:
    section = lua_source[lua_source.index("local TYPE_CRCS"): lua_source.index("local METHOD_SPECS")]
    rows = re.findall(r'\["([^"]+)"\]\s*=\s*(\d+)', section)
    return "{" + ",".join(f"[{json.dumps(name)}]={value}" for name, value in rows) + "}"


def _lua_joint_metadata() -> str:
    source = inspect_fbxskel(DEFAULT_SOURCE_RIG.read_bytes())
    return "{" + ",".join(json.dumps(name) for name in source["names"]) + "}"


def _lua_fake_sdk_harness() -> str:
    lua_source = LUA_PATH.read_text(encoding="utf-8")
    metadata = _lua_method_metadata(lua_source)
    crcs = _lua_crc_metadata(lua_source)
    joints = _lua_joint_metadata()
    source_path = str(LUA_PATH).replace("]]", "")
    return r'''
local frame = 1
local setter_calls = 0
local method_calls = 0
local dump_calls = 0
local update_callback, reset_callback, motion_callback
local state = { delay = 0, joint_reads = 1, always_pending = false, release_fail = false }
local snapshot = {
    schemaVersion = 1, sessionId = "s1", selectionRevision = 1,
    ready = true, reason = "applied", busy = false, restoreUnresolved = false,
    effectiveBodyModId = "yorha_2b_base_static", supporterAddress = "0x5000",
    playerEntityAddress = "0x6000", catalogRowsVerified = true,
    parts = {
        { part = "BODY", prefab = "mods/yorha_2b_base_static/b60902b0c9f97048/ch001_00_00_HQ.pfb", catalog = "mods/yorha_2b_base_static/c406cadd4073f518/playerbodypartslisthq_1st.user" },
        { part = "HEAD", prefab = "mods/yorha_2b_base_static/2670bb075a9de61f/ch001_00_10_HQ.pfb", catalog = "mods/yorha_2b_base_static/cf3fdf041f9fbd65/playerheadpartslisthq_1st.user" },
        { part = "HAIR", prefab = "mods/yorha_2b_base_static/fa78e476fb9051c2/ch001_00_20_HQ.pfb", catalog = "mods/yorha_2b_base_static/1f9bad298db57811/playerhairpartslisthq_1st.user" },
    },
}

local method_meta = __METHOD_META__
local crc_meta = __CRC_META__
local joint_names = __JOINTS__
local actor, body, entity, supporter, info, manager, motion, skeleton
local joint_array, private_positions, actor_joints, body_joints, body_transform
local types = {}
local parents = {
    ["via.Transform"] = "via.Component", ["via.render.Mesh"] = "via.Component",
    ["via.motion.Motion"] = "via.Component", ["via.motion.DummySkeleton"] = "via.Component",
    ["via.motion.SkeletonResourceHolder"] = "via.ResourceHolder",
    ["via.motion.FbxSkeletonResourceHolder"] = "via.motion.SkeletonResourceHolder",
    ["via.render.MeshResourceHolder"] = "via.ResourceHolder",
}
local function type_def(name)
    if types[name] then return types[name] end
    local d = { full = name, array = name:sub(-2) == "[]" }
    function d:get_full_name() return self.full end
    function d:is_array() return self.array end
    function d:is_a(wanted)
        local cursor = self.full
        while cursor do
            if cursor == wanted or wanted == "System.Object" then return true end
            cursor = parents[cursor]
        end
        return false
    end
    function d:get_crc_hash() return crc_meta[self.full] or 0 end
    function d:get_method(signature)
        local row = method_meta[self.full .. "|" .. signature]
        if not row then return nil end
        local m = { key = row.key, returns = row.returns, static = row.static, rva = row.rva, params = row.params }
        function m:get_num_params() return #self.params end
        function m:get_return_type() return type_def(self.returns) end
        function m:is_static() return self.static end
        function m:get_param_types()
            local result = {}
            for index, pname in ipairs(self.params) do result[index] = type_def(pname) end
            return result
        end
        function m:get_function() return self.rva + 0x10000000 end
        function m:call(object, ...)
            method_calls = method_calls + 1
            local args = { ... }
            if self.key == "pm_instance" then return manager end
            if self.key == "pm_info" then return info end
            if self.key == "pm_current" then return object == manager and args[1] == actor end
            if self.key == "info_valid" then return true end
            if self.key == "info_object" then return actor end
            if self.key == "info_entity" then return entity end
            if self.key == "entity_supporter" then return supporter end
            if self.key == "supporter_body_type" then return 0 end
            if self.key == "supporter_body" then return body end
            if self.key == "component_game_object" then return object.owner end
            if self.key == "component_valid" then return object ~= nil and object.valid ~= false end
            if self.key == "game_object_valid" then return object ~= nil and object.valid ~= false end
            if self.key == "game_object_transform" then return object.transform end
            if self.key == "game_object_components" then return object.components end
            if self.key == "transform_parent" then return object.parent end
            if self.key == "transform_joints" then
                if state.joint_reads == 0 then
                    state.joint_reads = 1
                    return array("via.Joint[]", {}, 0x9000)
                end
                return joint_array
            end
            if self.key == "array_length" then return #object.items end
            if self.key == "array_value" then return object.items[args[1] + 1] end
            if self.key == "mesh_ready" then return true end
            if self.key == "mesh_holder" then return object.resource_holder end
            if self.key == "resource_path" then return object.path end
            if self.key == "skeleton_get" then return object.holder end
            if self.key == "skeleton_set" then
                setter_calls = setter_calls + 1
                object.holder = args[1]
                state.delay, state.joint_reads = 1, 0
                for _, joint in ipairs(joint_array.items) do
                    local p = args[1].private and private_positions[joint.name] or { 0, 0, 0 }
                    joint.position = { x = p[1], y = p[2], z = p[3] }
                end
                return nil
            end
            if self.key == "motion_constructed" then
                if state.always_pending then return false end
                if state.delay > 0 then state.delay = state.delay - 1; return false end
                return true
            end
            if self.key == "joint_valid" then return object.valid ~= false end
            if self.key == "joint_name" then return object.name end
            if self.key == "joint_owner" then return object.owner end
            if self.key == "joint_base_position" then return object.position end
            if self.key == "joint_local_position" then return object.position end
            if self.key == "joint_set_local_position" then object.position = args[1]; return nil end
            if self.key == "joint_set_world_position" then object.world = args[1]; return nil end
            if self.key == "joint_world_position" then return object.world or object.position end
            if self.key == "transform_joint_by_name" then
                if object == body_transform then return body_joints[args[1]] end
                return actor_joints[args[1]]
            end
            if self.key == "frame" then return frame end
            error("unhandled fake method " .. tostring(self.key), 0)
        end
        return m
    end
    types[name] = d
    return d
end

local next_address = 0xA000
local function new_object(type_name, address)
    next_address = next_address + 1
    local object = { managed = true, type_name = type_name, address = address or next_address, refs = 0, valid = true }
    function object:get_address() return self.address end
    function object:get_type_definition() return type_def(self.type_name) end
    function object:add_ref() self.refs = self.refs + 1 end
    function object:release()
        if state.release_fail then error("fake release failure", 0) end
        self.refs = math.max(0, self.refs - 1)
    end
    return object
end
function array(type_name, items, address)
    local result = new_object(type_name, address)
    result.items = items
    return result
end

local function make_holder(path, private)
    local holder = new_object("via.motion.FbxSkeletonResourceHolder")
    holder.path, holder.private = path, private
    return holder
end
local stock_holder = make_holder("art/model/character/ch0/ch001_00/90/ch001_00_90.fbxskel", false)
local private_holder
local raw_resource = new_object("via.motion.FbxSkeletonResource")
function raw_resource:create_holder(_)
    private_holder = make_holder(self.path, true)
    return private_holder
end

actor = new_object("via.GameObject", 0x1000)
body = new_object("via.GameObject", 0x2000)
local actor_transform = new_object("via.Transform", 0x1100)
body_transform = new_object("via.Transform", 0x2100)
body_transform.parent, actor.transform, body.transform = actor_transform, actor_transform, body_transform
entity = new_object("app.cPlayerCharacterEntity", 0x6000)
supporter = new_object("app.cPlayerGameObjectSupporter", 0x5000)
info = new_object("app.cPlayerManageInfo", 0x7000)
manager = new_object("app.PlayerManager", 0x8000)
motion = new_object("via.motion.Motion", 0x1200)
skeleton = new_object("via.motion.DummySkeleton", 0x1300)
local body_mesh = new_object("via.render.Mesh", 0x2200)
local mesh_holder = new_object("via.render.MeshResourceHolder", 0x2300)
mesh_holder.path = "mods/yorha_2b_base_static/6beb535baea0379a/vyaomo_v_00.mesh"
body_mesh.resource_holder, body_mesh.owner = mesh_holder, body
skeleton.owner, skeleton.holder, motion.owner = actor, stock_holder, actor
actor.components = array("via.Component[]", { skeleton, motion }, 0x1400)
body.components = array("via.Component[]", { body_mesh }, 0x2400)
actor.transform, body.transform = actor_transform, body_transform
private_positions = {
    COG = { 0.0, 1.0199999809265137, 0.0 }, Hip = { 0.0, 0.059999942779541016, 0.0 },
    Spine_0 = { 0.0, -0.018999934196472168, 0.0 }, Spine_1 = { 0.0, 0.10000002384185791, 0.0 },
    Spine_2 = { 0.0, 0.10224626958370209, -0.0031286869198083878 },
    Neck_0 = { 0.0, 0.18826796114444733, -0.02067713439464569 },
    L_UpperArm = { 0.10052178800106049, -0.008498595096170902, -0.05425645783543587 },
    R_UpperArm = { -0.10052178800106049, -0.008498595096170902, -0.05425645783543587 },
}
local joint_items = {}
for index, name in ipairs(joint_names) do
    local joint = new_object("via.Joint", 0x3000 + index)
    joint.name, joint.owner, joint.position = name, actor_transform, { x = 0, y = 0, z = 0 }
    joint_items[index] = joint
end
joint_array = array("via.Joint[]", joint_items, 0x4000)
actor_transform.joints = joint_array
actor_joints = {}
for _, joint in ipairs(joint_items) do actor_joints[joint.name] = joint end
local body_joint_items = {}
for index, name in ipairs(joint_names) do
    local joint = new_object("via.Joint", 0x7000 + index)
    local x, y, z = 0, 0, 0
    if name == "Hip" then y = 0.06
    elseif name == "L_UpperArm" then x, y, z = 0.10052482, -0.00849748, -0.05425652 end
    joint.name, joint.owner, joint.position = name, body_transform, { x = x, y = y, z = z }
    body_joint_items[index] = joint
end
body_joints = {}
for _, joint in ipairs(body_joint_items) do body_joints[joint.name] = joint end
local function set_joint_positions(private)
    for _, joint in ipairs(joint_array.items) do
        local p = private and private_positions[joint.name] or { 0, 0, 0 }
        joint.position = { x = p and p[1] or 0, y = p and p[2] or 0, z = p and p[3] or 0 }
    end
end
local function set_holder_and_positions(holder, private)
    skeleton.holder = holder
    set_joint_positions(private)
end
local api = { get_adapter_snapshot = function() return snapshot end }
_G.owots_appearance_lab = api
sdk = {
    is_managed_object = function(object) return type(object) == "table" and object.managed == true end,
    to_int64 = function(value) return value end,
    find_type_definition = function(name) return type_def(name) end,
    create_resource = function(_, path)
        raw_resource.path = path
        raw_resource.private = true
        return raw_resource
    end,
}
json = { dump_file = function() dump_calls = dump_calls + 1 end }
Vector3f = { new = function(x, y, z) return { x = x, y = y, z = z } end }
re = {
    on_pre_application_entry = function(name, callback) if name == "UpdateMotion" then update_callback = callback end end,
    on_script_reset = function(callback) reset_callback = callback end,
}
local adapter = dofile([[__SOURCE_PATH__]])
local function advance()
    if motion_callback then motion_callback() end
    update_callback()
    frame = frame + 1
end
local function metrics() return { setters = setter_calls, calls = method_calls, dumps = dump_calls } end
return { adapter = adapter, snapshot = snapshot, advance = advance, metrics = metrics,
    actor_joints = actor_joints, body_joints = body_joints,
    reset = function() reset_callback() end,
    set_always_pending = function(value) state.always_pending = value == true end,
    set_release_failure = function(value) state.release_fail = value == true end,
    force_stock_with_custom_joints = function() set_holder_and_positions(stock_holder, true) end,
    force_stock_with_stock_joints = function() set_holder_and_positions(stock_holder, false) end,
    -- Simulate a late external/reentrant rebind after the adapter has already
    -- requested the stock holder.  Keep the observed joints at the stock
    -- baseline on purpose: the production adapter must still re-read holder
    -- ownership before releasing its private pins.
    force_private_with_stock_joints = function()
        skeleton.holder = private_holder
        for _, joint in ipairs(joint_array.items) do
            joint.position = { x = 0, y = 0, z = 0 }
        end
    end }
'''.replace("__METHOD_META__", metadata).replace("__CRC_META__", crcs).replace("__JOINTS__", joints).replace("__SOURCE_PATH__", source_path)


class LeaseModel:
    """Pure model of the adapter's holder lease and bounded rebuild waits."""

    def __init__(self) -> None:
        self.mode = "diagnostic"
        self.phase = "waiting"
        self.holder = "stock"
        self.pinned = False
        self.blocked = False
        self.setter_writes = 0
        self.restore_writes = 0
        self.frame = 0
        self.started = None
        self.session = None
        self.mod_id = None
        self.revision = None

    def mode_set(self, mode: str) -> None:
        if mode not in {"diagnostic", "apply"}:
            raise ValueError(mode)
        self.mode = mode

    def select(self, session: str, mod_id: str, revision: int) -> str:
        if self.blocked:
            return "blocked"
        if self.mode != "apply":
            self.phase = "diagnostic"
            return "diagnostic"
        self.session, self.mod_id, self.revision = session, mod_id, revision
        self.phase = "settling"
        self.holder = "private"
        self.pinned = True
        self.setter_writes += 1
        self.started = self.frame
        return "bound"

    def settle(self, constructed: bool, joint_count: int, names_ok: bool, custom_ok: bool) -> str:
        if self.phase != "settling":
            raise AssertionError(self.phase)
        if self.holder != "private":
            return self.quarantine("foreign holder during settle")
        if not constructed or joint_count != 93:
            if self.frame - (self.started or self.frame) > 300:
                return self.quarantine("settle timeout")
            return "pending"
        if names_ok and custom_ok:
            self.phase = "active"
            return "active"
        if self.frame - (self.started or self.frame) > 300:
            return self.quarantine("settle topology timeout")
        return "pending"

    def menu_pause(self, session: str, mod_id: str, revision: int) -> str:
        # C# intentionally emits a new revision for menu_paused because the
        # paused snapshot omits live addresses/parts.  The adapter therefore
        # holds only on session + body ID and rechecks the full lease on resume.
        if self.phase in {"active", "settling"} and (self.session, self.mod_id) == (session, mod_id):
            return "held"
        return self.request_restore("menu selection changed")

    def resume(self, session: str, mod_id: str, revision: int) -> str:
        if (self.session, self.mod_id, self.revision) == (session, mod_id, revision):
            return "continue"
        return self.request_restore("resume lease changed")

    def request_restore(self, reason: str) -> str:
        if self.phase == "waiting" and self.holder == "stock":
            return "already_restored"
        self.phase = "restoring"
        return "restore_queued"

    def restore_step(
        self,
        constructed: bool,
        joint_count: int,
        names_ok: bool,
        positions_ok: bool,
        current_holder: str = "private",
        release_ok: bool = True,
    ) -> str:
        if self.phase != "restoring":
            raise AssertionError(self.phase)
        if current_holder not in {"private", "stock"}:
            return self.quarantine("foreign holder preserved")
        if current_holder == "private":
            self.holder = "stock"
            self.restore_writes += 1
        if not constructed or joint_count != 93 or not names_ok or not positions_ok:
            if self.frame - (self.started or self.frame) > 300:
                return self.quarantine("restore timeout")
            return "pending"
        if not release_ok:
            self.pinned = True
            return self.quarantine("reference release failed")
        self.pinned = False
        self.phase = "waiting"
        self.mod_id = self.revision = self.session = None
        return "restored"

    def quarantine(self, reason: str) -> str:
        self.phase = "quarantined"
        self.blocked = True
        self.pinned = True
        return "quarantined"

    def retry_restore(self) -> str:
        if not self.blocked:
            return self.request_restore("explicit retry")
        self.blocked = False
        self.phase = "restoring"
        return "restore_queued"


class CompanionTests(unittest.TestCase):
    def test_source_is_audited_v7_93(self) -> None:
        source = DEFAULT_SOURCE_RIG.read_bytes()
        report = inspect_fbxskel(source)
        self.assertEqual(report["sha256"], EXPECTED_SOURCE_SHA256)
        self.assertEqual(report["version"], 7)
        self.assertEqual(report["boneCount"], 93)

    def test_builder_and_validator_use_exact_six_files(self) -> None:
        with tempfile.TemporaryDirectory(prefix="owots-2b-test-") as temp:
            output = Path(temp) / "companion.zip"
            result = build(output, DEFAULT_SOURCE_RIG)
            self.assertEqual(result["source"]["sha256"], EXPECTED_SOURCE_SHA256)
            validation = validate_zip(output)
            self.assertEqual(validation["memberCount"], 6)
            self.assertEqual(hashlib.sha256(output.read_bytes()).hexdigest(), result["sha256"])

    def test_zip_names_reject_absolute_drive_ads_and_parent_paths(self) -> None:
        for name in ("/escape", "\\escape", "C:/escape", "folder:stream", "../escape", "a/../b"):
            with self.subTest(name=name):
                with self.assertRaises(ValueError):
                    validate_member_name(name)

    def test_zip_rejects_case_duplicate_and_symlink(self) -> None:
        with tempfile.TemporaryDirectory(prefix="owots-2b-zip-") as temp:
            root = Path(temp)
            duplicate = root / "duplicate.zip"
            with zipfile.ZipFile(duplicate, "w") as archive:
                archive.writestr("A", b"one")
                archive.writestr("a", b"two")
            with self.assertRaises(ValueError):
                validate_zip(duplicate)

            symlink = root / "symlink.zip"
            info = zipfile.ZipInfo("link")
            info.create_system = 3
            info.external_attr = (0o120777 << 16)
            with zipfile.ZipFile(symlink, "w") as archive:
                archive.writestr(info, b"target")
            with self.assertRaises(ValueError):
                validate_zip(symlink)

    def test_lua_parses_and_keeps_native_writes_on_update_motion(self) -> None:
        lua = LUA_PATH.read_text(encoding="utf-8")
        ast.parse(lua)
        self.assertIn('local DEFAULT_MODE = "diagnostic"', lua)
        self.assertIn("get_adapter_snapshot", lua)
        self.assertIn("get_scarlet_adapter_snapshot", lua)
        self.assertIn("same_paused_lease", lua)
        self.assertIn("sessionId == state.session_id", lua)
        self.assertIn("seen_names", lua)
        self.assertIn("last_baseline_joint_positions", lua)
        self.assertIn("last_observed_joint_positions", lua)

        close_start = lua.index("function adapter.close")
        close_end = lua.index("function adapter.definitions", close_start)
        self.assertNotIn("skeleton_set", lua[close_start:close_end])
        retry_start = lua.index("function adapter.retry_restore")
        retry_end = lua.index("function adapter.close", retry_start)
        self.assertNotIn("restore_owned", lua[retry_start:retry_end])
        settle_start = lua.index("local function settle")
        settle_end = lua.index("local function tick_impl", settle_start)
        settle = lua[settle_start:settle_end]
        self.assertLess(settle.index('motion_constructed'), settle.index('capture_joints(candidate.context, true)'))
        restore_start = lua.index("local function restore_owned")
        restore_end = lua.index("local function bind", restore_start)
        restore = lua[restore_start:restore_end]
        self.assertLess(restore.index('motion_constructed'), restore.index('capture_joints(candidate.context, true)'))

    def test_lua_executes_fake_game_thread_delay_pause_restore_and_reset(self) -> None:
        """Run the production Lua chunk with a fully local fake SDK graph.

        The fake graph has no native DLL and no game process.  It deliberately
        returns a false Motion/Joints readiness sequence after each holder
        request so a direct setter/readback shortcut would fail this test.
        """

        lua = LuaRuntime(unpack_returned_tuples=True)
        harness = lua.execute(_lua_fake_sdk_harness())
        adapter = harness["adapter"]
        advance = harness["advance"]
        metrics = harness["metrics"]
        reset = harness["reset"]

        # Default diagnostic mode reads and records the stock 93-joint
        # baseline without invoking the sole native setter.
        advance()
        status = adapter.status()
        self.assertEqual(status["mode"], "diagnostic")
        self.assertEqual(status["phase"], "diagnostic")
        self.assertFalse(status["runtime_verified"])
        self.assertEqual(metrics()["setters"], 0)
        self.assertEqual(status["original_rig_path"], "art/model/character/ch0/ch001_00/90/ch001_00_90.fbxskel")
        diagnostic_dumps = metrics()["dumps"]
        advance()
        self.assertEqual(metrics()["setters"], 0)
        self.assertEqual(metrics()["dumps"], diagnostic_dumps)

        # Enabling apply is just a mode flag; the next game-thread callback
        # performs the setter and starts the delayed settling lease.
        self.assertTrue(adapter.enable_apply())
        before_mode = metrics()["setters"]
        advance()
        self.assertEqual(metrics()["setters"], before_mode + 1)
        self.assertEqual(adapter.status()["phase"], "settling")
        self.assertFalse(adapter.status()["runtime_verified"])

        # First callback: Motion not constructed.  Second: constructed but a
        # temporary zero-joint array.  Third: full custom 93-joint graph.
        self.assertEqual(adapter.status()["owned"], True)
        advance()
        self.assertEqual(adapter.status()["phase"], "settling")
        advance()
        self.assertEqual(adapter.status()["phase"], "settling")
        advance()
        self.assertEqual(adapter.status()["phase"], "active")
        self.assertTrue(adapter.status()["runtime_verified"])
        self.assertEqual(adapter.status()["owned_rig_path"], "mods/yorha_2b_base_static/dynamic/rig.fbxskel")

        # status() is scalar-only outside UpdateMotion: reading it must not
        # call any managed/native method, which is also true for UI callers.
        calls_before_status = metrics()["calls"]
        _ = adapter.status()
        self.assertEqual(metrics()["calls"], calls_before_status)

        # A menu pause may advance the revision and hides live addresses, but
        # the same session/body keeps the holder with zero extra setter calls.
        snapshot = harness["snapshot"]
        snapshot["ready"], snapshot["reason"], snapshot["selectionRevision"] = False, "menu_paused", 2
        snapshot["supporterAddress"], snapshot["playerEntityAddress"] = None, None
        setters_before_pause = metrics()["setters"]
        advance()
        self.assertEqual(metrics()["setters"], setters_before_pause)
        self.assertTrue(adapter.status()["paused"])
        self.assertEqual(adapter.status()["phase"], "active")

        # Resume has a new revision; full context validation rejects the old
        # lease and queues restoration.  Restoration itself also waits through
        # false constructed and zero/partial joints before releasing pins.
        snapshot["ready"], snapshot["reason"], snapshot["effectiveBodyModId"], snapshot["selectionRevision"] = (
            True, "applied", "yorha_2b_base_static", 3
        )
        snapshot["supporterAddress"], snapshot["playerEntityAddress"] = "0x5000", "0x6000"
        advance()
        self.assertEqual(adapter.status()["phase"], "restoring")
        self.assertFalse(adapter.status()["runtime_verified"])
        self.assertEqual(metrics()["setters"], setters_before_pause + 1)
        snapshot["ready"], snapshot["reason"], snapshot["effectiveBodyModId"] = False, "no_effective_body", "native_body"
        advance()
        self.assertEqual(adapter.status()["phase"], "restoring")
        advance()
        self.assertEqual(adapter.status()["phase"], "waiting")
        self.assertFalse(adapter.status()["owned"])
        self.assertFalse(adapter.status()["runtime_verified"])

        # A new session while paused is not an eligible hold and requests
        # restoration; this guards against revision/session reuse.
        snapshot["ready"], snapshot["reason"], snapshot["effectiveBodyModId"] = True, "applied", "yorha_2b_base_static"
        snapshot["selectionRevision"], snapshot["sessionId"] = 10, "s1"
        snapshot["supporterAddress"], snapshot["playerEntityAddress"] = "0x5000", "0x6000"
        advance()
        advance()
        advance()
        advance()
        self.assertEqual(adapter.status()["phase"], "active")
        snapshot["ready"], snapshot["reason"], snapshot["sessionId"] = False, "menu_paused", "s2"
        setters_before_session = metrics()["setters"]
        advance()
        self.assertEqual(adapter.status()["phase"], "restoring")
        self.assertEqual(metrics()["setters"], setters_before_session + 1)

        # Reset callback is deliberately invoked off the game callback.  It
        # must not call a setter or even a native getter, and must report the
        # unresolved restore explicitly.
        snapshot["ready"], snapshot["reason"], snapshot["effectiveBodyModId"], snapshot["sessionId"] = (
            False, "no_effective_body", "native_body", "s2"
        )
        advance()
        snapshot["ready"], snapshot["reason"], snapshot["effectiveBodyModId"], snapshot["sessionId"] = (
            True, "applied", "yorha_2b_base_static", "s1"
        )
        snapshot["selectionRevision"] = 20
        for _ in range(5):
            advance()
        self.assertEqual(adapter.status()["phase"], "active")
        setters_before_reset = metrics()["setters"]
        calls_before_reset = metrics()["calls"]
        reset()
        reset_status = adapter.status()
        self.assertEqual(metrics()["setters"], setters_before_reset)
        self.assertEqual(metrics()["calls"], calls_before_reset)
        self.assertEqual(reset_status["phase"], "quarantined")
        self.assertTrue(reset_status["restore_unresolved"])
        self.assertTrue(reset_status["blocked"])
        self.assertTrue(reset_status["script_reset_requires_restart"])
        self.assertIn("script_reset_restore_unverified", reset_status["last_error"])

    def test_lua_rechecks_holder_before_release_after_late_rebind(self) -> None:
        """A stale stock-looking joint array must not release a live private lease."""

        lua = LuaRuntime(unpack_returned_tuples=True)
        harness = lua.execute(_lua_fake_sdk_harness())
        adapter = harness["adapter"]
        advance = harness["advance"]
        metrics = harness["metrics"]
        snapshot = harness["snapshot"]
        force_private_with_stock_joints = harness["force_private_with_stock_joints"]

        # Read the baseline, explicitly opt into apply, and wait for the full
        # custom 93-joint graph.
        advance()
        self.assertTrue(adapter.enable_apply())
        advance()
        advance()
        advance()
        advance()
        self.assertEqual(adapter.status()["phase"], "active")
        setters_before_restore = metrics()["setters"]

        # Queue restoration, let the first original-holder write happen, then
        # simulate a late private rebind whose joints misleadingly look stock.
        snapshot["ready"], snapshot["reason"], snapshot["effectiveBodyModId"] = (
            False, "no_effective_body", "native_body"
        )
        advance()
        self.assertEqual(adapter.status()["phase"], "restoring")
        self.assertEqual(metrics()["setters"], setters_before_restore + 1)
        force_private_with_stock_joints()

        # Motion becomes constructed and exposes the stock-looking joints.  A
        # release-before-ownership-check implementation would report waiting
        # and drop the pinned private holder here; the production code must
        # reassert the original holder and remain in restoring.
        advance()
        advance()
        advance()
        status = adapter.status()
        self.assertEqual(status["phase"], "restoring")
        self.assertTrue(status["owned"])
        self.assertTrue(status["restore_pending"])
        self.assertFalse(status["runtime_verified"])
        self.assertEqual(metrics()["setters"], setters_before_restore + 2)
        self.assertTrue(any(row["kind"] == "restore_reasserted" for row in status["events"].values()))

    def test_lua_restore_waits_when_original_holder_has_custom_joints(self) -> None:
        """A returned stock holder is insufficient while Motion still exposes custom binds."""

        lua = LuaRuntime(unpack_returned_tuples=True)
        harness = lua.execute(_lua_fake_sdk_harness())
        adapter = harness["adapter"]
        advance = harness["advance"]
        metrics = harness["metrics"]
        snapshot = harness["snapshot"]
        force_stock_with_custom_joints = harness["force_stock_with_custom_joints"]
        force_stock_with_stock_joints = harness["force_stock_with_stock_joints"]

        # Reach a verified private lease first.
        advance()
        self.assertTrue(adapter.enable_apply())
        advance()
        advance()
        advance()
        advance()
        self.assertEqual(adapter.status()["phase"], "active")
        setters_before_restore = metrics()["setters"]

        # Request restoration.  The fake setter immediately reports the stock
        # holder, then a late Motion callback exposes the still-custom joint
        # positions.  The adapter must keep the lease pinned and wait.
        snapshot["ready"], snapshot["reason"], snapshot["effectiveBodyModId"] = (
            False, "no_effective_body", "native_body"
        )
        advance()
        self.assertEqual(adapter.status()["phase"], "restoring")
        self.assertEqual(metrics()["setters"], setters_before_restore + 1)
        force_stock_with_custom_joints()
        advance()  # Motion still reports unconstructed.
        advance()  # Constructed, but the temporary joint array is empty.
        advance()  # Full custom array; holder is stock but baseline is wrong.
        pending = adapter.status()
        self.assertEqual(pending["phase"], "restoring")
        self.assertTrue(pending["owned"])
        self.assertTrue(pending["restore_pending"])
        self.assertIn("restore_joints_pending:joint_bind_differs_from_baseline", pending["last_error"])
        self.assertEqual(metrics()["setters"], setters_before_restore + 1)

        # Once the stock baseline actually appears, release is allowed.
        force_stock_with_stock_joints()
        advance()
        restored = adapter.status()
        self.assertEqual(restored["phase"], "waiting")
        self.assertFalse(restored["owned"])
        self.assertFalse(restored["restore_unresolved"])

    def test_lua_pause_during_settle_and_restore_timeout_quarantines(self) -> None:
        """Pause never bypasses a restore timeout, including a lease still settling."""

        lua = LuaRuntime(unpack_returned_tuples=True)
        harness = lua.execute(_lua_fake_sdk_harness())
        adapter = harness["adapter"]
        advance = harness["advance"]
        metrics = harness["metrics"]
        snapshot = harness["snapshot"]
        set_always_pending = harness["set_always_pending"]

        # Bind, but pause before the first settle callback completes.  The
        # same session/body menu snapshot is a read-only hold with no setter.
        advance()
        self.assertTrue(adapter.enable_apply())
        advance()
        self.assertEqual(adapter.status()["phase"], "settling")
        setters_before_pause = metrics()["setters"]
        snapshot["ready"], snapshot["reason"], snapshot["selectionRevision"] = (
            False, "menu_paused", 2
        )
        snapshot["supporterAddress"], snapshot["playerEntityAddress"] = None, None
        advance()
        paused_settling = adapter.status()
        self.assertEqual(paused_settling["phase"], "settling")
        self.assertTrue(paused_settling["paused"])
        self.assertTrue(paused_settling["owned"])
        self.assertEqual(metrics()["setters"], setters_before_pause)

        # Resume with a new revision and force Motion to remain unconstructed.
        # Restoration must be queued despite the intervening menu pause.
        snapshot["ready"], snapshot["reason"], snapshot["selectionRevision"] = (
            True, "applied", 3
        )
        snapshot["supporterAddress"], snapshot["playerEntityAddress"] = "0x5000", "0x6000"
        set_always_pending(True)
        advance()
        restoring = adapter.status()
        self.assertEqual(restoring["phase"], "restoring")
        self.assertFalse(restoring["paused"])
        self.assertEqual(metrics()["setters"], setters_before_pause + 1)

        # A menu pause while restore is pending must not turn the restore back
        # into a hold or reset its bounded timeout.
        snapshot["ready"], snapshot["reason"], snapshot["selectionRevision"] = (
            False, "menu_paused", 4
        )
        snapshot["supporterAddress"], snapshot["playerEntityAddress"] = None, None
        advance()
        self.assertEqual(adapter.status()["phase"], "restoring")
        self.assertFalse(adapter.status()["paused"])
        setters_during_restore = metrics()["setters"]
        for _ in range(302):
            advance()
        timed_out = adapter.status()
        self.assertEqual(timed_out["phase"], "quarantined")
        self.assertTrue(timed_out["blocked"])
        self.assertTrue(timed_out["restore_unresolved"])
        self.assertTrue(timed_out["owned"])
        self.assertEqual(metrics()["setters"], setters_during_restore)

    def test_lua_cross_identity_restores_and_failed_release_can_retry(self) -> None:
        """Session/actor identity changes restore; failed release stays retryable."""

        lua = LuaRuntime(unpack_returned_tuples=True)
        harness = lua.execute(_lua_fake_sdk_harness())
        adapter = harness["adapter"]
        advance = harness["advance"]
        metrics = harness["metrics"]
        snapshot = harness["snapshot"]
        set_release_failure = harness["set_release_failure"]

        def activate() -> None:
            advance()
            self.assertTrue(adapter.enable_apply())
            advance()
            advance()
            advance()
            advance()
            self.assertEqual(adapter.status()["phase"], "active")

        activate()
        setters_after_first_bind = metrics()["setters"]

        # A new session cannot reuse the old lease, even with the same actor
        # addresses and otherwise valid routes.
        snapshot["sessionId"], snapshot["selectionRevision"] = "s2", 2
        advance()
        self.assertEqual(adapter.status()["phase"], "restoring")
        self.assertEqual(metrics()["setters"], setters_after_first_bind + 1)

        # Complete that restore so a new lease can be formed for the new
        # session.  The fake sequence is false/empty/full after the setter.
        snapshot["ready"], snapshot["reason"], snapshot["effectiveBodyModId"] = (
            False, "no_effective_body", "native_body"
        )
        advance()
        advance()
        advance()
        self.assertEqual(adapter.status()["phase"], "waiting")
        snapshot["ready"], snapshot["reason"], snapshot["effectiveBodyModId"], snapshot["selectionRevision"] = (
            True, "applied", "yorha_2b_base_static", 3
        )
        advance()
        advance()
        advance()
        advance()
        self.assertEqual(adapter.status()["phase"], "active")

        # A supporter identity change is rejected before any new lease can be
        # accepted, and routes the current lease through restoration.
        snapshot["supporterAddress"], snapshot["selectionRevision"] = "0xDEAD", 4
        setters_before_actor_restore = metrics()["setters"]
        advance()
        actor_changed = adapter.status()
        self.assertEqual(actor_changed["phase"], "restoring")
        self.assertTrue(any("actor_context_changed" in item for item in actor_changed["diagnostics"].values()))
        self.assertEqual(metrics()["setters"], setters_before_actor_restore + 1)

        # Force every release call to fail.  The adapter must quarantine while
        # retaining ownership and make retry_restore a queue-only UI call.
        set_release_failure(True)
        advance()
        advance()
        advance()
        advance()
        failed = adapter.status()
        self.assertEqual(failed["phase"], "quarantined")
        self.assertTrue(failed["blocked"])
        self.assertTrue(failed["owned"])
        self.assertTrue(failed["restore_unresolved"])
        calls_before_retry = metrics()["calls"]
        self.assertFalse(adapter.retry_restore())
        self.assertEqual(metrics()["calls"], calls_before_retry)
        self.assertEqual(adapter.status()["phase"], "restoring")

        # Once the external release failure is gone, the queued retry executes
        # on UpdateMotion and clears the lease without another setter.
        set_release_failure(False)
        setters_before_retry_tick = metrics()["setters"]
        advance()
        retried = adapter.status()
        self.assertEqual(retried["phase"], "waiting")
        self.assertFalse(retried["owned"])
        self.assertFalse(retried["blocked"])
        self.assertFalse(retried["restore_unresolved"])
        self.assertEqual(metrics()["setters"], setters_before_retry_tick)

    def test_lifecycle_model_diagnostic_apply_pause_restore(self) -> None:
        model = LeaseModel()
        self.assertEqual(model.select("s1", "yorha_2b_base_static", 1), "diagnostic")
        self.assertEqual(model.setter_writes, 0)
        model.mode_set("apply")
        self.assertEqual(model.select("s1", "yorha_2b_base_static", 2), "bound")
        self.assertEqual(model.settle(False, 0, False, False), "pending")
        self.assertEqual(model.holder, "private")
        self.assertEqual(model.settle(True, 93, True, True), "active")
        self.assertEqual(model.menu_pause("s1", "yorha_2b_base_static", 3), "held")
        self.assertEqual(model.holder, "private")
        self.assertEqual(model.resume("s1", "yorha_2b_base_static", 4), "restore_queued")
        self.assertEqual(model.restore_step(False, 0, False, False), "pending")
        self.assertEqual(model.holder, "stock")
        self.assertEqual(model.restore_step(True, 93, True, True), "restored")
        self.assertFalse(model.pinned)

    def test_lifecycle_model_quarantine_foreign_and_release_pin(self) -> None:
        model = LeaseModel()
        model.mode_set("apply")
        model.select("s1", "yorha_2b_alternate_static", 1)
        model.settle(True, 93, True, True)
        model.request_restore("actor changed")
        self.assertEqual(model.restore_step(True, 93, True, True, current_holder="foreign"), "quarantined")
        self.assertTrue(model.blocked)
        self.assertTrue(model.pinned)
        self.assertEqual(model.retry_restore(), "restore_queued")
        self.assertEqual(model.restore_step(True, 93, True, True, current_holder="stock", release_ok=False), "quarantined")
        self.assertTrue(model.pinned)


def run() -> int:
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(CompanionTests)
    stream = unittest.TextTestRunner(verbosity=2).run(suite)
    report = {
        "schema": "owots-yorha-2b-offline-validation-v2",
        "passed": stream.wasSuccessful(),
        "testsRun": stream.testsRun,
        "failures": [str(item[1]) for item in stream.failures],
        "errors": [str(item[1]) for item in stream.errors],
        "source": {
            "path": str(DEFAULT_SOURCE_RIG.resolve()),
            "sha256": EXPECTED_SOURCE_SHA256,
            "version": 7,
            "boneCount": 93,
        },
        "gameAccess": False,
        "runtimeExecution": False,
        "actualLuaExecutedWithFakeSdk": stream.wasSuccessful(),
        "gameRuntimeExecuted": False,
        "luaSyntaxParsed": stream.wasSuccessful(),
        "scope": "offline source/package/lifecycle checks; no in-game A/B claim",
    }
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if stream.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(run())
