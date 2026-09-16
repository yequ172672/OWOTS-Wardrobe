-- YoRHa 2B actor-skeleton bridge candidate, v1.
--
-- This file is intentionally independent from the Scarlet adapter.  It uses
-- the same measured OWOTS SDK operation, but accepts only the two converted
-- 2B body IDs and only the exact catalog/PFB/mesh routes in the companion
-- manifest.  It does not run the original MOD loader or touch game files.
--
-- The only native setter is:
--   via.motion.DummySkeleton.set_SkeletonResourceHandle(
--       via.motion.SkeletonResourceHolder)
-- All calls run on the UpdateMotion game-thread callback.  A holder is kept
-- pinned until its ownership is read back and restoration is verified.

local M = {}

local SOURCE_RIG = "art/model/character/ch0/ch001_00/90/ch001_00_90.fbxskel"
local NATIVE_RIG = "art/model/character/ch0/ch001_00/90/ch001_00_90.fbxskel"
local EXPECTED_JOINT_COUNT = 93
local MAX_SETTLE_FRAMES = 300
local MAX_RESTORE_FRAMES = 300
local MAX_COMPONENTS = 128
local MAX_JOINTS = 256
local PERSIST_FRAME_INTERVAL = 60
-- The first run is read-only so a tester can inspect the real actor/baseline
-- before authorizing the single holder setter.  set_mode("apply") only queues
-- a mode change; the setter still runs exclusively from UpdateMotion.
local DEFAULT_MODE = "diagnostic"

local DEFINITIONS = {
    yorha_2b_base_static = {
        bodyPrefab = "mods/yorha_2b_base_static/b60902b0c9f97048/ch001_00_00_HQ.pfb",
        bodyCatalog = "mods/yorha_2b_base_static/c406cadd4073f518/playerbodypartslisthq_1st.user",
        headPrefab = "mods/yorha_2b_base_static/2670bb075a9de61f/ch001_00_10_HQ.pfb",
        headCatalog = "mods/yorha_2b_base_static/cf3fdf041f9fbd65/playerheadpartslisthq_1st.user",
        hairPrefab = "mods/yorha_2b_base_static/fa78e476fb9051c2/ch001_00_20_HQ.pfb",
        hairCatalog = "mods/yorha_2b_base_static/1f9bad298db57811/playerhairpartslisthq_1st.user",
        bodyMesh = "mods/yorha_2b_base_static/6beb535baea0379a/vyaomo_v_00.mesh",
        privateRig = "mods/yorha_2b_base_static/dynamic/rig.fbxskel",
    },
    yorha_2b_alternate_static = {
        bodyPrefab = "mods/yorha_2b_alternate_static/8fabaa2952df9e4c/ch001_01_00_HQ.pfb",
        bodyCatalog = "mods/yorha_2b_alternate_static/c406cadd4073f518/playerbodypartslisthq_1st.user",
        headPrefab = "mods/yorha_2b_alternate_static/2670bb075a9de61f/ch001_00_10_HQ.pfb",
        headCatalog = "mods/yorha_2b_alternate_static/cf3fdf041f9fbd65/playerheadpartslisthq_1st.user",
        hairPrefab = "mods/yorha_2b_alternate_static/fa78e476fb9051c2/ch001_00_20_HQ.pfb",
        hairCatalog = "mods/yorha_2b_alternate_static/1f9bad298db57811/playerhairpartslisthq_1st.user",
        bodyMesh = "mods/yorha_2b_alternate_static/c481cc3b133cc376/vyaomo_v_00.mesh",
        privateRig = "mods/yorha_2b_alternate_static/dynamic/rig.fbxskel",
    },
}

-- These are the distinctive bind positions from the audited source
-- ch001_00_90.fbxskel.  They prevent a path-only false positive if a provider
-- returns a holder with the right name but leaves the stock skeleton active.
local CUSTOM_BIND_POSITIONS = {
    COG = { 0.0, 1.0199999809265137, 0.0 },
    Hip = { 0.0, 0.059999942779541016, 0.0 },
    Spine_0 = { 0.0, -0.018999934196472168, 0.0 },
    Spine_1 = { 0.0, 0.10000002384185791, 0.0 },
    Spine_2 = { 0.0, 0.10224626958370209, -0.0031286869198083878 },
    Neck_0 = { 0.0, 0.18826796114444733, -0.02067713439464569 },
    L_UpperArm = { 0.10052178800106049, -0.008498595096170902, -0.05425645783543587 },
    R_UpperArm = { -0.10052178800106049, -0.008498595096170902, -0.05425645783543587 },
}
local DIAGNOSTIC_JOINT_NAMES = {
    "COG", "Hip", "Spine_0", "Spine_1", "Spine_2", "Neck_0", "L_UpperArm", "R_UpperArm",
}

-- Method/type contract is recorded separately in native-api-contract.json.
-- The adapter repeats its relevant signatures and CRCs here so a missing or
-- mismatched SDK fails closed before any native setter is attempted.
local TYPE_CRCS = {
    ["ace.GAElement`1<app.PlayerManager>"] = 437989116,
    ["app.PlayerManager"] = 346041440,
    ["app.cPlayerManageInfo"] = 3185740719,
    ["app.cPlayerCharacterEntity"] = 4067958465,
    ["app.cPlayerGameObjectSupporter"] = 1646483854,
    ["via.Component"] = 1881844667,
    ["via.GameObject"] = 4065074914,
    ["via.Transform"] = 1340992935,
    ["via.render.Mesh"] = 1829138609,
    ["via.ResourceHolder"] = 1072471267,
    ["via.motion.DummySkeleton"] = 2062619527,
    ["via.motion.Motion"] = 1638522585,
    ["via.Joint"] = 1272281384,
    ["via.Application"] = 1896701499,
    ["System.Array"] = 58605515,
}

local METHOD_SPECS = {
    { "pm_instance", "ace.GAElement`1<app.PlayerManager>", "get_Instance", {}, "app.PlayerManager", true, 109939872 },
    { "pm_info", "app.PlayerManager", "getControllingPlayer", {}, "app.cPlayerManageInfo", false, 77873440 },
    { "pm_current", "app.PlayerManager", "isControllingPlayer", { "via.GameObject" }, "System.Boolean", false, 111298048 },
    { "info_valid", "app.cPlayerManageInfo", "get_Valid", {}, "System.Boolean", false, 125839200 },
    { "info_object", "app.cPlayerManageInfo", "get_Object", {}, "via.GameObject", false, 86045520 },
    { "info_entity", "app.cPlayerManageInfo", "get_CharacterEntity", {}, "app.cPlayerCharacterEntity", false, 94387552 },
    { "entity_supporter", "app.cPlayerCharacterEntity", "get_GameObjectSupporter", {}, "app.cPlayerGameObjectSupporter", false, 108612672 },
    { "supporter_body_type", "app.cPlayerGameObjectSupporter", "convertObjTypeToPartsType", { "app.PlayerPartsDef.PARTS_TYPE" }, "app.cPlayerGameObjectSupporter.PLAYER_GAME_OBJECT", true, 11360992 },
    { "supporter_body", "app.cPlayerGameObjectSupporter", "getGameObject", { "app.cPlayerGameObjectSupporter.PLAYER_GAME_OBJECT" }, "via.GameObject", false, 3268272 },
    { "component_game_object", "via.Component", "get_GameObject", {}, "via.GameObject", false, 94821856 },
    { "component_valid", "via.Component", "get_Valid", {}, "System.Boolean", false, 94763376 },
    { "game_object_valid", "via.GameObject", "get_Valid", {}, "System.Boolean", false, 94806192 },
    { "game_object_transform", "via.GameObject", "get_Transform", {}, "via.Transform", false, 97957552 },
    { "game_object_components", "via.GameObject", "get_Components", {}, "via.Component[]", false, 97957600 },
    { "transform_parent", "via.Transform", "get_Parent", {}, "via.Transform", false, 125570976 },
    { "transform_joints", "via.Transform", "get_Joints", {}, "via.Joint[]", false, 125571280 },
    { "array_length", "System.Array", "GetLength", { "System.Int32" }, "System.Int32", false, 114447776 },
    { "array_value", "System.Array", "GetValue", { "System.Int32" }, "System.Object", false, 114447856 },
    { "mesh_ready", "via.render.Mesh", "get_MeshReady", {}, "System.Boolean", false, 122191152 },
    { "mesh_holder", "via.render.Mesh", "getMesh", {}, "via.render.MeshResourceHolder", false, 122190144 },
    { "resource_path", "via.ResourceHolder", "get_ResourcePath", {}, "System.String", false, 116635664 },
    { "skeleton_get", "via.motion.DummySkeleton", "get_SkeletonResourceHandle", {}, "via.motion.SkeletonResourceHolder", false, 113281056 },
    { "skeleton_set", "via.motion.DummySkeleton", "set_SkeletonResourceHandle", { "via.motion.SkeletonResourceHolder" }, "System.Void", false, 113281152 },
    { "motion_constructed", "via.motion.Motion", "get_JointsConstructed", {}, "System.Boolean", false, 99057168 },
    { "joint_valid", "via.Joint", "get_Valid", {}, "System.Boolean", false, 94763376 },
    { "joint_name", "via.Joint", "get_Name", {}, "System.String", false, 109358608 },
    { "joint_owner", "via.Joint", "get_Owner", {}, "via.Transform", false, 109360928 },
    { "joint_base_position", "via.Joint", "get_BaseLocalPosition", {}, "via.vec3", false, 109360528 },
    { "frame", "via.Application", "get_FrameCount", {}, "System.UInt32", true, 127698480 },
}

local function copy_array(value)
    local result = {}
    if type(value) ~= "table" then return result end
    for i, item in ipairs(value) do result[i] = item end
    return result
end

local function canonical(path)
    if type(path) ~= "string" then return nil end
    local value = path:gsub("\\", "/"):lower():gsub("^@+", "")
    value = value:gsub("^/natives/stm/", ""):gsub("^natives/stm/", "")
    value = value:gsub("%.%d+$", "")
    return value
end

local function address_text(value)
    if type(value) ~= "string" then return nil end
    local result = value:lower():gsub("%s+", "")
    if not result:match("^0x[0-9a-f]+$") or result:match("^0x0+$") then return nil end
    return result
end

local function object_address(sdk, object)
    if object == nil then return nil end
    local ok, value = pcall(function() return sdk.to_int64(object:get_address()) end)
    if not ok or value == nil then return nil end
    local ok_text, text = pcall(function() return string.format("0x%X", value) end)
    if not ok_text then return nil end
    return text:lower()
end

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function same_object(sdk, left, right)
    local a, b = object_address(sdk, left), object_address(sdk, right)
    return a ~= nil and b ~= nil and a == b
end

local function require_value(value, message)
    if not value then error(message, 0) end
    return value
end

local function safe_release(value)
    if value == nil then return true end
    local ok = pcall(function() value:release() end)
    return ok
end

local function shallow_status(status)
    local out = {}
    for key, value in pairs(status) do
        if key ~= "events" and key ~= "diagnostics" then out[key] = value end
    end
    out.events = copy_array(status.events)
    out.diagnostics = copy_array(status.diagnostics)
    return out
end

local function new_adapter()
    local sdk_ref = sdk
    local closed = false
    local api_ready = false
    local api_attempted = false
    local methods = {}
    local definitions = {}
    local image_base = nil
    local state = nil
    local blocked = false
    local restore_request_queued = false
    local close_requested = false
    local close_reason = nil
    local mode = DEFAULT_MODE
    local last_diagnostic_key = nil
    local last_persist_frame = nil
    local last_persist_signature = nil
    local last_frame = nil
    local status = {
        schema = "yorha-2b-skeleton-adapter-status-v1",
        phase = "waiting",
        candidate = true,
        mode = mode,
        apply_enabled = false,
        runtime_verified = false,
        native_setter_writes = 0,
        restore_writes = 0,
        restore_attempts = 0,
        bindings = 0,
        transitions = 0,
        errors = 0,
        frame = nil,
        last_error = nil,
        blocked = false,
        paused = false,
        restore_pending = false,
        restore_unresolved = false,
        restore_request_queued = false,
        close_requested = false,
        restore_requires_game_thread = false,
        script_reset_requires_restart = false,
        last_baseline_joint_positions = nil,
        last_observed_joint_positions = nil,
        last_original_holder_path = nil,
        last_private_holder_path = nil,
        bridge = "get_adapter_snapshot (fallback get_scarlet_adapter_snapshot)",
        source_rig = SOURCE_RIG,
        expected_joint_count = EXPECTED_JOINT_COUNT,
        events = {},
        diagnostics = {},
    }

    local function diagnostic(code, detail)
        local message = code .. (detail and (": " .. tostring(detail)) or "")
        status.last_error = message
        status.diagnostics[#status.diagnostics + 1] = message
        while #status.diagnostics > 64 do table.remove(status.diagnostics, 1) end
        if type(log) == "table" and type(log.error) == "function" then pcall(log.error, "[yorha-2b] " .. message) end
    end

    local function event(kind, data)
        local row = { kind = kind, frame = status.frame, data = data }
        status.events[#status.events + 1] = row
        while #status.events > 64 do table.remove(status.events, 1) end
    end

    local function set_phase(value, reason)
        if status.phase ~= value then
            status.phase = value
            status.transitions = status.transitions + 1
            event("phase", { value = value, reason = reason })
        end
        -- runtime_verified means the current lease is verified now.  It must
        -- never survive a new bind, a restore, a quarantine, or a waiting
        -- state as if it were an historical success.
        if value ~= "active" then status.runtime_verified = false end
    end

    local function persist(force)
        if type(json) == "table" and type(json.dump_file) == "function" then
            local signature = table.concat({
                tostring(status.phase), tostring(mode), tostring(status.blocked),
                tostring(status.restore_pending), tostring(status.restore_unresolved),
                tostring(status.runtime_verified), tostring(status.bindings),
                tostring(status.native_setter_writes), tostring(status.restore_writes),
                tostring(status.close_requested), tostring(status.paused),
            }, "|")
            local frame = status.frame
            if not force and last_persist_signature == signature and type(frame) == "number" and
                last_persist_frame ~= nil and frame - last_persist_frame < PERSIST_FRAME_INTERVAL then
                return
            end
            pcall(json.dump_file, "yorha-2b-skeleton-status.json", shallow_status(status), -1)
            last_persist_frame = frame
            last_persist_signature = signature
        end
    end

    local function managed(object, type_name)
        if object == nil or type(sdk_ref) ~= "table" or type(sdk_ref.is_managed_object) ~= "function" then return false end
        local ok, result = pcall(function()
            return sdk_ref.is_managed_object(object) and object:get_type_definition():is_a(type_name)
        end)
        return ok and result == true
    end

    local function keep(object)
        require_value(managed(object, "System.Object"), "managed object required")
        object:add_ref()
        return object
    end

    local function resolve_api()
        if api_ready then return true end
        if api_attempted and status.phase == "faulted" then return false end
        api_attempted = true
        local ok, reason = pcall(function()
            require_value(type(sdk_ref) == "table", "sdk unavailable")
            for type_name, crc in pairs(TYPE_CRCS) do
                local definition = sdk_ref.find_type_definition(type_name)
                if not definition then error("sdk type not ready: " .. type_name, 0) end
                require_value(definition:get_crc_hash() == crc, "SDK type CRC mismatch: " .. type_name)
                definitions[type_name] = definition
            end
            for _, spec in ipairs(METHOD_SPECS) do
                local key, type_name, name, params, returns, is_static, rva = table.unpack(spec)
                local definition = definitions[type_name]
                local signature = name .. "(" .. table.concat(params, ", ") .. ")"
                local method = definition:get_method(signature)
                require_value(method, "SDK method missing: " .. key)
                require_value(method:get_num_params() == #params, "SDK parameter count mismatch: " .. key)
                require_value(method:get_return_type():get_full_name() == returns, "SDK return type mismatch: " .. key)
                require_value(method:is_static() == is_static, "SDK staticness mismatch: " .. key)
                local parameter_types = method:get_param_types()
                for i, parameter in ipairs(params) do
                    require_value(parameter_types[i]:get_full_name() == parameter, "SDK parameter type mismatch: " .. key)
                end
                local address = sdk_ref.to_int64(method:get_function())
                local delta = address - rva
                image_base = image_base or delta
                require_value(delta == image_base, "SDK image-relative RVA mismatch: " .. key)
                methods[key] = method
            end
        end)
        if ok then
            api_ready = true
            set_phase("waiting", "sdk_ready")
            event("sdk_ready", { method_count = #METHOD_SPECS, image_base = image_base })
            persist()
            return true
        end
        reason = tostring(reason)
        -- Startup can precede the managed SDK. Retry that condition, but keep
        -- a real signature/CRC failure terminal so an incompatible build can
        -- never reach the setter.
        if reason:find("not ready", 1, true) or reason:find("sdk unavailable", 1, true) then
            status.last_error = reason
            status.phase = "waiting"
            api_attempted = false
            return false
        end
        status.errors = status.errors + 1
        diagnostic("api_contract_failed", reason)
        set_phase("faulted", "api_contract")
        persist()
        return false
    end

    local function call(key, object, ...)
        local method = require_value(methods[key], "missing method " .. key)
        return method:call(object, ...)
    end

    local function each_array_value(value, maximum, visitor)
        require_value(value and sdk_ref.is_managed_object(value), "native array missing")
        require_value(value:get_type_definition():is_array(), "native array type mismatch")
        require_value(type(visitor) == "function", "native array visitor missing")
        local array_pinned = false
        local ok_pin = pcall(function() value:add_ref() end)
        require_value(ok_pin, "native array pin failed")
        array_pinned = true
        local ok, reason = pcall(function()
            local count = call("array_length", value, 0)
            require_value(type(count) == "number" and count >= 0 and count <= maximum and count % 1 == 0,
                "native array bound exceeded")
            for index = 0, count - 1 do
                local item = call("array_value", value, index)
                local item_pinned = false
                if item ~= nil and sdk_ref.is_managed_object(item) then
                    local item_ok = pcall(function() item:add_ref() end)
                    require_value(item_ok, "native array item pin failed")
                    item_pinned = true
                end
                local visitor_ok, visitor_error = pcall(visitor, item, index, count)
                local release_ok = not item_pinned or safe_release(item)
                require_value(release_ok, "native array item release failed")
                if not visitor_ok then error(visitor_error, 0) end
            end
        end)
        if array_pinned then
            local release_ok = safe_release(value)
            if not release_ok then ok, reason = false, "native array release failed" end
        end
        if not ok then error(reason, 0) end
    end

    local function each_component(game_object, visitor)
        each_array_value(call("game_object_components", game_object), MAX_COMPONENTS, visitor)
    end

    local function resource_path(holder)
        if holder == nil or not managed(holder, "via.ResourceHolder") then return nil end
        return canonical(call("resource_path", holder))
    end

    local function valid_game_object(value)
        return managed(value, "via.GameObject") and call("game_object_valid", value) == true
    end

    local function valid_component(value)
        return managed(value, "via.Component") and call("component_valid", value) == true
    end

    local function exact_part(snapshot, part, prefab, catalog)
        if type(snapshot.parts) ~= "table" then return false end
        for _, row in pairs(snapshot.parts) do
            if type(row) == "table" and type(row.part) == "string" and row.part:upper() == part then
                return canonical(row.prefab) == canonical(prefab) and canonical(row.catalog) == canonical(catalog)
            end
        end
        return false
    end

    local function read_bridge_snapshot()
        local api = rawget(_G, "owots_appearance_lab")
        local function decode(value)
            if type(value) == "table" then return value end
            if type(value) == "string" and type(json) == "table" and type(json.load_string) == "function" then
                local ok, result = pcall(json.load_string, value)
                if ok and type(result) == "table" then return result end
            end
            return nil
        end
        local fn
        -- Prefer the generic alias supplied by the current bridge. Keep the
        -- old Scarlet name solely for compatibility with an older companion.
        if type(api) == "table" then fn = api.get_adapter_snapshot end
        if type(fn) ~= "function" and type(api) == "table" then fn = api.get_scarlet_adapter_snapshot end
        if type(fn) ~= "function" and type(api) == "table" then fn = api.get_scarlet_adapter_snapshot_json end
        if type(fn) ~= "function" then fn = rawget(_G, "owots_appearance_lab_get_scarlet_adapter_snapshot") end
        if type(fn) ~= "function" then return nil, "wardrobe_bridge_missing" end
        local ok, output = pcall(fn)
        if not ok then return nil, "wardrobe_bridge_error:" .. tostring(output) end
        local snapshot = decode(output)
        if not snapshot then return nil, "wardrobe_snapshot_not_object" end
        return snapshot, nil
    end

    local function validate_snapshot(snapshot)
        if type(snapshot) ~= "table" then return nil, "snapshot_not_object" end
        local mod_id = snapshot.effectiveBodyModId
        local definition = DEFINITIONS[mod_id]
        if not definition then return nil, "unsupported_body_id" end
        if snapshot.ready ~= true then return nil, tostring(snapshot.reason or "snapshot_not_ready") end
        if snapshot.busy == true then return nil, "transition_busy" end
        if snapshot.restoreUnresolved == true then return nil, "wardrobe_restore_unresolved" end
        if snapshot.catalogRowsVerified ~= true then return nil, "catalog_rows_unverified" end
        if type(snapshot.sessionId) ~= "string" or #snapshot.sessionId < 1 or #snapshot.sessionId > 128 or
            snapshot.sessionId:find("[%c]", 1) then return nil, "session_id_invalid" end
        if address_text(snapshot.supporterAddress) == nil then return nil, "supporter_identity_missing" end
        if address_text(snapshot.playerEntityAddress) == nil then return nil, "entity_identity_missing" end
        if type(snapshot.selectionRevision) ~= "number" or snapshot.selectionRevision < 0 or
            snapshot.selectionRevision % 1 ~= 0 then return nil, "selection_revision_invalid" end
        if not exact_part(snapshot, "BODY", definition.bodyPrefab, definition.bodyCatalog) then return nil, "body_route_mismatch" end
        if not exact_part(snapshot, "HEAD", definition.headPrefab, definition.headCatalog) then return nil, "head_route_mismatch" end
        if not exact_part(snapshot, "HAIR", definition.hairPrefab, definition.hairCatalog) then return nil, "hair_route_mismatch" end
        return definition, nil
    end

    local function same_paused_lease(snapshot, candidate)
        return candidate ~= nil and type(snapshot) == "table" and snapshot.reason == "menu_paused" and
            snapshot.sessionId == candidate.session_id and
            snapshot.effectiveBodyModId == candidate.mod_id
    end

    local function actor_ancestry(actor_transform, child_transform)
        local cursor = child_transform
        local visited = {}
        for _ = 1, 32 do
            if same_object(sdk_ref, cursor, actor_transform) then return true end
            if not cursor or not valid_component(cursor) then return false end
            local key = object_address(sdk_ref, cursor)
            if not key or visited[key] then return false end
            visited[key] = true
            cursor = call("transform_parent", cursor)
        end
        return false
    end

    local function resolve_actor(definition, snapshot)
        local manager = call("pm_instance", nil)
        require_value(managed(manager, "app.PlayerManager"), "player manager unavailable")
        local info = call("pm_info", manager)
        require_value(managed(info, "app.cPlayerManageInfo") and call("info_valid", info) == true, "player info unavailable")
        local actor = call("info_object", info)
        local entity = call("info_entity", info)
        require_value(valid_game_object(actor), "controlling actor invalid")
        require_value(call("pm_current", manager, actor) == true, "actor is not controlling player")
        require_value(managed(entity, "app.cPlayerCharacterEntity"), "player entity invalid")
        local supporter = call("entity_supporter", entity)
        require_value(managed(supporter, "app.cPlayerGameObjectSupporter"), "player supporter invalid")
        require_value(object_address(sdk_ref, supporter) == address_text(snapshot.supporterAddress), "supporter identity changed")
        require_value(object_address(sdk_ref, entity) == address_text(snapshot.playerEntityAddress), "entity identity changed")

        local body_type = call("supporter_body_type", nil, 0)
        if type(body_type) ~= "number" then body_type = require_value(body_type:get_field("value__"), "body enum missing") end
        local body = call("supporter_body", supporter, body_type)
        require_value(valid_game_object(body), "body GameObject invalid")
        local actor_transform = call("game_object_transform", actor)
        local body_transform = call("game_object_transform", body)
        require_value(valid_component(actor_transform) and valid_component(body_transform), "actor/body transform invalid")
        require_value(actor_ancestry(actor_transform, body_transform), "body is outside actor hierarchy")

        local body_meshes = {}
        each_component(body, function(component)
            if managed(component, "via.render.Mesh") and valid_component(component) and call("mesh_ready", component) == true then
                local path = resource_path(call("mesh_holder", component))
                if path == canonical(definition.bodyMesh) then
                    require_value(same_object(sdk_ref, call("component_game_object", component), body), "body mesh owner changed")
                    body_meshes[#body_meshes + 1] = { component = component, path = path }
                end
            end
        end)
        require_value(#body_meshes == 1, "exact body mesh path not uniquely present")

        local skeleton, motion
        each_component(actor, function(component)
            if managed(component, "via.motion.DummySkeleton") and valid_component(component) then
                require_value(skeleton == nil, "multiple root DummySkeleton components")
                skeleton = component
            elseif managed(component, "via.motion.Motion") and valid_component(component) then
                require_value(motion == nil, "multiple root Motion components")
                motion = component
            end
        end)
        require_value(skeleton ~= nil and motion ~= nil, "root Motion/DummySkeleton pair missing")
        require_value(same_object(sdk_ref, call("component_game_object", skeleton), actor), "skeleton owner changed")
        require_value(same_object(sdk_ref, call("component_game_object", motion), actor), "motion owner changed")
        local key = table.concat({
            object_address(sdk_ref, actor) or "?",
            object_address(sdk_ref, entity) or "?",
            object_address(sdk_ref, supporter) or "?",
            object_address(sdk_ref, body) or "?",
            object_address(sdk_ref, skeleton) or "?",
            object_address(sdk_ref, motion) or "?",
        }, ":")
        return {
            actor = actor,
            entity = entity,
            supporter = supporter,
            body = body,
            actor_transform = actor_transform,
            body_transform = body_transform,
            mesh = body_meshes[1].component,
            body_mesh_path = body_meshes[1].path,
            skeleton = skeleton,
            motion = motion,
            key = key,
            actor_address = object_address(sdk_ref, actor),
            entity_address = object_address(sdk_ref, entity),
            supporter_address = object_address(sdk_ref, supporter),
            body_address = object_address(sdk_ref, body),
        }
    end

    local function capture_joints(context, allow_pending)
        local names, positions, seen_names = {}, {}, {}
        local pending_reason
        each_array_value(call("transform_joints", context.actor_transform), MAX_JOINTS, function(joint, index)
            if pending_reason then return end
            if not (managed(joint, "via.Joint") and call("joint_valid", joint) == true) then
                if allow_pending then
                    pending_reason = "joint_pending:" .. tostring(index + 1)
                    return
                end
                error("invalid actor joint", 0)
            end
            require_value(same_object(sdk_ref, call("joint_owner", joint), context.actor_transform), "joint owner changed")
            local name = call("joint_name", joint)
            require_value(type(name) == "string" and #name > 0, "joint name invalid")
            require_value(not seen_names[name], "duplicate joint name: " .. name)
            seen_names[name] = true
            local position = call("joint_base_position", joint)
            if not (position and finite(position.x) and finite(position.y) and finite(position.z)) then
                if allow_pending then
                    pending_reason = "joint_position_pending:" .. tostring(name)
                    return
                end
                error("joint bind position invalid", 0)
            end
            local ordinal = #names + 1
            names[ordinal] = name
            positions[name] = { position.x, position.y, position.z }
        end)
        if pending_reason then return nil, pending_reason end
        if #names ~= EXPECTED_JOINT_COUNT then
            if allow_pending then return nil, "joint_count_pending:" .. tostring(#names) end
            error("actor joint count is not 93", 0)
        end
        return { names = names, positions = positions }
    end

    local function same_names(left, right)
        if type(left) ~= "table" or type(right) ~= "table" or #left ~= #right then return false end
        for index = 1, #left do if left[index] ~= right[index] then return false end end
        return true
    end

    local function same_positions(names, expected, actual, tolerance)
        if type(names) ~= "table" or type(expected) ~= "table" or type(actual) ~= "table" then return false end
        tolerance = tolerance or 0.00002
        for _, name in ipairs(names) do
            local left, right = expected[name], actual[name]
            if not left or not right then return false end
            for index = 1, 3 do
                if not finite(left[index]) or not finite(right[index]) or
                    math.abs(left[index] - right[index]) > tolerance then return false end
            end
        end
        return true
    end

    local function diagnostic_positions(positions)
        local out = {}
        if type(positions) ~= "table" then return out end
        for _, name in ipairs(DIAGNOSTIC_JOINT_NAMES) do
            local value = positions[name]
            if type(value) == "table" then
                out[name] = { value[1], value[2], value[3] }
            end
        end
        return out
    end

    local function custom_positions_match(joints)
        for name, expected in pairs(CUSTOM_BIND_POSITIONS) do
            local actual = joints.positions[name]
            if not actual then return false, "missing custom bind joint " .. name end
            for index = 1, 3 do
                if math.abs(actual[index] - expected[index]) > 0.00002 then
                    return false, "custom bind position mismatch " .. name
                end
            end
        end
        return true, nil
    end

    local function create_private_holder(definition)
        local raw, holder
        local ok, reason = pcall(function()
            raw = require_value(sdk_ref.create_resource("via.motion.FbxSkeletonResource", definition.privateRig),
                "private FBXSKEL resource creation failed")
            raw:add_ref()
            holder = require_value(raw:create_holder("via.motion.FbxSkeletonResourceHolder"),
                "private FBXSKEL holder creation failed")
            require_value(managed(holder, "via.motion.SkeletonResourceHolder"), "private holder base type mismatch")
            holder:add_ref()
            require_value(resource_path(holder) == canonical(definition.privateRig), "private holder path mismatch")
        end)
        if not ok then
            safe_release(holder)
            safe_release(raw)
            error(reason, 0)
        end
        return raw, holder
    end

    local function state_current(context, snapshot, definition, expected_revision)
        return context ~= nil and context.key == state.context.key and
            object_address(sdk_ref, context.actor) == state.context.actor_address and
            object_address(sdk_ref, context.body) == state.context.body_address and
            object_address(sdk_ref, context.skeleton) == state.context.skeleton_address and
            context.body_mesh_path == canonical(definition.bodyMesh) and
            snapshot.sessionId == state.session_id and
            snapshot.effectiveBodyModId == state.mod_id and
            snapshot.selectionRevision == expected_revision
    end

    local function release_state_references(candidate)
        if not candidate then return true end
        local ok = true
        -- The holder owns/use-counts the raw resource, so release it first.
        local function release_field(name)
            local value = candidate[name]
            if value == nil then return end
            if safe_release(value) then
                candidate[name] = nil
            else
                -- Keep a failed reference intact so an explicit retry can
                -- release it later.  Dropping the Lua field here would lose
                -- the pin and make a safe recovery impossible to audit.
                ok = false
            end
        end
        release_field("owned_holder")
        release_field("raw_resource")
        release_field("original_holder")
        return ok
    end

    local function restore_owned(reason)
        if state == nil then return true end
        local candidate = state
        -- A menu pause is only a hold while the current lease remains in its
        -- settling/active phase.  Once restoration starts, even a paused
        -- snapshot must be reported as restoring rather than leaving the
        -- previous `paused=true` UI state stale through a timeout/quarantine.
        status.paused = false
        local first_restore_attempt = candidate.phase ~= "restoring"
        if first_restore_attempt then
            candidate.phase = "restoring"
            candidate.restore_started_frame = status.frame or candidate.started_frame or 0
            candidate.restore_requested = false
            status.runtime_verified = false
            status.restore_pending = true
            status.restore_unresolved = false
            set_phase("restoring", reason)
        end
        status.restore_attempts = status.restore_attempts + 1
        local ok, result, pending_reason = pcall(function()
            require_value(valid_component(candidate.context.skeleton), "owned skeleton component invalid")
            require_value(same_object(sdk_ref, call("component_game_object", candidate.context.skeleton), candidate.context.actor),
                "owned skeleton actor changed")
            local current_holder = call("skeleton_get", candidate.context.skeleton)
            require_value(managed(current_holder, "via.motion.SkeletonResourceHolder"), "current skeleton holder invalid")
            if same_object(sdk_ref, current_holder, candidate.owned_holder) then
                if not candidate.restore_requested then
                    -- This is the only place restoration writes occur, and it
                    -- is reached from UpdateMotion (the game callback thread).
                    call("skeleton_set", candidate.context.skeleton, candidate.original_holder)
                    status.restore_writes = status.restore_writes + 1
                    local after = call("skeleton_get", candidate.context.skeleton)
                    require_value(same_object(sdk_ref, after, candidate.original_holder), "skeleton restore readback mismatch")
                    candidate.restore_requested = true
                    event("restore_requested", { mod_id = candidate.mod_id, reason = reason, path = resource_path(after) })
                end
            elseif same_object(sdk_ref, current_holder, candidate.original_holder) then
                candidate.restore_requested = true
            else
                error("foreign skeleton holder preserved: " .. tostring(resource_path(current_holder)), 0)
            end

            -- Setting the original holder only requests a Motion rebuild.  A
            -- readback of the holder is insufficient: wait for the game to
            -- reconstruct the stock joint array and compare the captured
            -- baseline before releasing any pinned references.
            local constructed = call("motion_constructed", candidate.context.motion) == true
            if not constructed then
                return nil, "restore_motion_pending:Motion.JointsConstructed=false"
            end
            local joints, joint_reason = capture_joints(candidate.context, true)
            if not joints then return nil, "restore_joints_pending:" .. tostring(joint_reason) end
            if not same_names(joints.names, candidate.baseline_names) then
                return nil, "restore_joints_pending:joint_order_differs_from_baseline"
            end
            if not same_positions(candidate.baseline_names, candidate.baseline_positions, joints.positions) then
                return nil, "restore_joints_pending:joint_bind_differs_from_baseline"
            end

            -- The holder can be rebound between the first restore request and
            -- this delayed Motion callback.  Never release our pins merely
            -- because a stale joint snapshot happens to look like the stock
            -- baseline.  Re-read ownership immediately before releasing: if
            -- our private holder is still installed, reassert the original
            -- holder and wait for a fresh rebuild; a foreign holder fails
            -- closed and keeps the lease pinned.
            local final_holder = call("skeleton_get", candidate.context.skeleton)
            require_value(managed(final_holder, "via.motion.SkeletonResourceHolder"), "final skeleton holder invalid")
            if same_object(sdk_ref, final_holder, candidate.owned_holder) then
                call("skeleton_set", candidate.context.skeleton, candidate.original_holder)
                status.restore_writes = status.restore_writes + 1
                local after = call("skeleton_get", candidate.context.skeleton)
                require_value(same_object(sdk_ref, after, candidate.original_holder), "skeleton restore reassert readback mismatch")
                candidate.restore_requested = true
                event("restore_reasserted", {
                    mod_id = candidate.mod_id,
                    reason = reason,
                    path = resource_path(after),
                })
                return nil, "restore_motion_pending:holder_reasserted"
            end
            require_value(same_object(sdk_ref, final_holder, candidate.original_holder),
                "foreign skeleton holder appeared before release")
            local original_path = resource_path(candidate.original_holder)
            require_value(release_state_references(candidate), "resource reference release failed")
            state = nil
            blocked = false
            status.blocked = false
            status.restore_pending = false
            status.restore_unresolved = false
            status.runtime_verified = false
            event("restored", {
                mod_id = candidate.mod_id,
                reason = reason,
                path = original_path,
                joint_count = #candidate.baseline_names,
                constructed = true,
                baseline_joint_positions = diagnostic_positions(candidate.baseline_positions),
                observed_joint_positions = diagnostic_positions(joints.positions),
            })
            set_phase("waiting", "restored")
            persist()
            return true
        end)
        if ok and result == nil then
            local frame = status.frame or candidate.restore_started_frame or 0
            status.restore_pending = true
            status.runtime_verified = false
            status.last_error = pending_reason or "restore_rebuild_pending"
            if frame - (candidate.restore_started_frame or frame) > MAX_RESTORE_FRAMES then
                ok = false
                result = "restore rebuild timeout: " .. tostring(status.last_error)
            else
                persist()
                return nil
            end
        end
        if not ok or result ~= true then
            blocked = true
            status.blocked = true
            status.restore_pending = false
            status.restore_unresolved = true
            status.runtime_verified = false
            status.errors = status.errors + 1
            diagnostic("restore_unresolved", tostring(result or "restore failed") .. "; restart blocked and references pinned")
            set_phase("quarantined", "restore_failed")
            persist()
            return false
        end
        return true
    end

    local function bind(definition, snapshot, context, frame)
        set_phase("binding", "exact_2b_selection")
        local current_holder = call("skeleton_get", context.skeleton)
        require_value(managed(current_holder, "via.motion.SkeletonResourceHolder"), "root skeleton holder invalid")
        require_value(resource_path(current_holder) == NATIVE_RIG, "root skeleton is not stock /90")
        local baseline = capture_joints(context)
        local original_path = resource_path(current_holder)
        local original_holder = keep(current_holder)
        local raw_resource, private_holder
        local candidate
        local ok, reason = pcall(function()
            raw_resource, private_holder = create_private_holder(definition)
            candidate = {
                mod_id = snapshot.effectiveBodyModId,
                session_id = snapshot.sessionId,
                revision = snapshot.selectionRevision,
                definition = definition,
                context = context,
                original_holder = original_holder,
                raw_resource = raw_resource,
                owned_holder = private_holder,
                baseline_names = baseline.names,
                baseline_positions = baseline.positions,
                started_frame = frame,
                phase = "settling",
                original_path = original_path,
                private_path = canonical(definition.privateRig),
            }
            candidate.context.skeleton_address = object_address(sdk_ref, context.skeleton)
            state = candidate
            status.last_baseline_joint_positions = diagnostic_positions(baseline.positions)
            status.last_original_holder_path = original_path
            status.last_private_holder_path = canonical(definition.privateRig)
            call("skeleton_set", context.skeleton, private_holder)
            status.native_setter_writes = status.native_setter_writes + 1
            local after = call("skeleton_get", context.skeleton)
            require_value(same_object(sdk_ref, after, private_holder) and resource_path(after) == canonical(definition.privateRig),
                "private skeleton setter readback mismatch")
            status.bindings = status.bindings + 1
            event("skeleton_requested", {
                mod_id = candidate.mod_id,
                revision = candidate.revision,
                actor = context.actor_address,
                body = context.body_address,
                private_path = resource_path(private_holder),
                baseline_joint_count = #baseline.names,
                original_holder_path = original_path,
                baseline_joint_positions = diagnostic_positions(baseline.positions),
            })
        end)
        if not ok then
            if candidate then
                state = candidate
                diagnostic("bind_failed", reason)
                restore_owned("bind_failed")
            else
                safe_release(private_holder)
                safe_release(raw_resource)
                safe_release(original_holder)
                diagnostic("bind_failed", reason)
                set_phase("waiting", "bind_failed_no_write")
                persist()
            end
            return false
        end
        set_phase("settling", "motion_rebuild_pending")
        persist()
        return true
    end

    local function settle(frame)
        local candidate = state
        require_value(candidate ~= nil and candidate.phase == "settling", "settle state missing")
        require_value(valid_component(candidate.context.skeleton) and valid_component(candidate.context.motion), "settle components invalid")
        local current_holder = call("skeleton_get", candidate.context.skeleton)
        require_value(same_object(sdk_ref, current_holder, candidate.owned_holder), "private holder ownership changed during settle")
        -- JointsConstructed is the asynchronous rebuild gate.  Do not inspect
        -- a zero/partial array while it is false; those are bounded pending
        -- states, while a wrong owner remains an immediate failure above.
        local constructed = call("motion_constructed", candidate.context.motion) == true
        if not constructed then
            status.last_error = "settle_motion_pending:Motion.JointsConstructed=false"
            if frame - candidate.started_frame > MAX_SETTLE_FRAMES then
                error("Motion rebuild timeout: " .. tostring(status.last_error), 0)
            end
            return false
        end
        local joints, joint_reason = capture_joints(candidate.context, true)
        if not joints then
            status.last_error = "settle_" .. tostring(joint_reason)
            if frame - candidate.started_frame > MAX_SETTLE_FRAMES then
                error("Motion rebuild timeout: " .. tostring(status.last_error), 0)
            end
            return false
        end
        local names_ok = same_names(joints.names, candidate.baseline_names)
        local custom_ok, custom_reason = custom_positions_match(joints)
        if constructed and names_ok and custom_ok then
            candidate.phase = "active"
            status.runtime_verified = true
            status.last_observed_joint_positions = diagnostic_positions(joints.positions)
            event("active", { mod_id = candidate.mod_id, frame = frame, joint_count = #joints.names, constructed = true })
            event("active_diagnostics", {
                mod_id = candidate.mod_id,
                private_holder_path = resource_path(candidate.owned_holder),
                original_holder_path = candidate.original_path,
                observed_joint_positions = diagnostic_positions(joints.positions),
            })
            set_phase("active", "motion_rebuilt_and_custom_binds_verified")
            persist()
            return true
        end
        if not names_ok then status.last_error = "motion joint order differs from stock baseline" end
        if not custom_ok then status.last_error = custom_reason end
        if not constructed then status.last_error = "Motion.JointsConstructed=false" end
        if frame - candidate.started_frame > MAX_SETTLE_FRAMES then
            error("Motion rebuild timeout: " .. tostring(status.last_error), 0)
        end
        return false
    end

    local function tick_impl()
        if closed then return end
        if not resolve_api() then return end
        local frame = call("frame", nil)
        if type(frame) ~= "number" then error("Application.FrameCount invalid", 0) end
        status.frame = frame
        if last_frame == frame then return end
        last_frame = frame

        if close_requested then
            -- close() only queues this request.  Restoration is performed on
            -- this UpdateMotion callback, never from on_script_reset/UI code.
            local requested_reason = close_reason or "adapter_close"
            local restored = restore_owned(requested_reason)
            if restored == true then
                close_requested = false
                status.close_requested = false
                status.restore_requires_game_thread = false
                closed = true
                set_phase("closed", requested_reason)
                persist()
            elseif restored == false then
                -- restore_owned already quarantined and pinned the lease.
                close_requested = false
                status.close_requested = false
                status.restore_requires_game_thread = false
                closed = true
                persist()
            end
            -- A nil result means Motion is still rebuilding.  Keep the
            -- queued request and let a later game-thread callback verify it.
            return
        end

        if restore_request_queued then
            restore_request_queued = false
            status.restore_request_queued = false
            if state ~= nil then
                local restored = restore_owned("explicit_restore_retry")
                if restored ~= true then return end
            else
                blocked = false
                status.blocked = false
                if status.phase == "quarantined" then set_phase("waiting", "no_lease_to_restore") end
            end
        end

        local snapshot, bridge_error = read_bridge_snapshot()
        local definition, gate_error = validate_snapshot(snapshot)
        local invalid_reason = bridge_error or gate_error
        if blocked then
            -- A failed restore is a hard stop. The explicit retry_restore API
            -- is the only way to attempt restoration; no automatic rebind.
            if invalid_reason then status.last_error = invalid_reason end
            return
        end
        if state ~= nil and state.phase == "restoring" then
            restore_owned("restore_pending")
            return
        end
        if state ~= nil and mode ~= "apply" then
            restore_owned("apply_disabled")
            return
        end
        -- Menu pause is a read-only suspension.  Keep the private holder and
        -- perform no native writes while the same session/id remains selected;
        -- the paused snapshot may advance its revision while hiding addresses.
        -- A changed session/body id or any resumed revision mismatch falls
        -- through to the full context check and restoration path.
        if same_paused_lease(snapshot, state) then
            status.paused = true
            status.last_error = nil
            persist()
            return
        end
        status.paused = false
        if state ~= nil and invalid_reason then
            restore_owned(invalid_reason)
            return
        end
        if definition == nil or snapshot == nil then
            set_phase("waiting", invalid_reason or "snapshot_waiting")
            return
        end

        local ok, context_or_error = pcall(resolve_actor, definition, snapshot)
        if not ok then
            local reason = tostring(context_or_error)
            if state ~= nil then
                diagnostic("actor_context_changed", reason)
                restore_owned("actor_context_changed")
            else
                status.last_error = reason
                set_phase("waiting", "actor_not_ready")
            end
            persist()
            return
        end
        local context = context_or_error
        if state == nil then
            if mode ~= "apply" then
                local diagnostic_ok, baseline_or_error = pcall(capture_joints, context)
                if diagnostic_ok then
                    status.last_baseline_joint_positions = diagnostic_positions(baseline_or_error.positions)
                    status.last_original_holder_path = resource_path(call("skeleton_get", context.skeleton))
                    status.last_observed_joint_positions = diagnostic_positions(baseline_or_error.positions)
                    status.runtime_verified = false
                    set_phase("diagnostic", "apply_disabled")
                    if last_diagnostic_key ~= context.key then
                        last_diagnostic_key = context.key
                        event("diagnostic_sample", {
                            actor = context.actor_address,
                            body = context.body_address,
                            original_holder_path = status.last_original_holder_path,
                            joint_count = #baseline_or_error.names,
                            baseline_joint_positions = diagnostic_positions(baseline_or_error.positions),
                            constructed = call("motion_constructed", context.motion) == true,
                        })
                    end
                else
                    status.last_error = "diagnostic_baseline_failed:" .. tostring(baseline_or_error)
                    set_phase("waiting", "diagnostic_baseline_pending")
                end
                persist()
                return
            end
            bind(definition, snapshot, context, frame)
            return
        end

        if mode ~= "apply" then
            restore_owned("apply_disabled")
            return
        end

        if snapshot.effectiveBodyModId ~= state.mod_id or snapshot.selectionRevision ~= state.revision or
            not state_current(context, snapshot, definition, state.revision) then
            restore_owned("selection_or_actor_changed")
            return
        end

        local ok_current, current_error = pcall(function()
            local holder = call("skeleton_get", state.context.skeleton)
            require_value(same_object(sdk_ref, holder, state.owned_holder), "foreign holder replaced owned holder")
            if state.phase == "settling" then
                settle(frame)
            elseif state.phase == "active" then
                require_value(call("motion_constructed", state.context.motion) == true, "Motion became unconstructed")
            else
                error("invalid adapter phase " .. tostring(state.phase), 0)
            end
        end)
        if not ok_current then
            diagnostic("runtime_validation_failed", current_error)
            restore_owned("runtime_validation_failed")
        end
    end

    local adapter = {}
    function adapter.tick()
        local ok, reason = pcall(tick_impl)
        if not ok then
            status.errors = status.errors + 1
            diagnostic("adapter_tick_failed", reason)
            if state ~= nil then restore_owned("adapter_tick_failed") else set_phase("waiting", "tick_failed") end
            persist()
        end
    end

    function adapter.status()
        local out = shallow_status(status)
        out.active_mod_id = state and state.mod_id or nil
        out.active_session_id = state and state.session_id or nil
        out.active_revision = state and state.revision or nil
        -- status() can be called from a render/UI callback (including
        -- on_script_reset).  Only return scalar paths captured on the game
        -- thread; never invoke a native getter from this public accessor.
        out.owned_rig_path = state and state.private_path or status.last_private_holder_path
        out.original_rig_path = state and state.original_path or status.last_original_holder_path
        out.actor_address = state and state.context.actor_address or nil
        out.entity_address = state and state.context.entity_address or nil
        out.supporter_address = state and state.context.supporter_address or nil
        out.body_address = state and state.context.body_address or nil
        out.body_mesh_path = state and state.context.body_mesh_path or nil
        out.api_ready = api_ready
        out.owned = state ~= nil
        out.mode = mode
        out.apply_enabled = mode == "apply"
        out.close_requested = close_requested
        out.restore_request_queued = restore_request_queued
        return out
    end

    function adapter.set_mode(value)
        if closed then return false end
        if value ~= "diagnostic" and value ~= "apply" then
            status.last_error = "invalid_mode:" .. tostring(value)
            persist()
            return false
        end
        mode = value
        status.mode = value
        status.apply_enabled = value == "apply"
        if value == "diagnostic" then status.runtime_verified = false end
        event("mode", { value = value, queued = true })
        persist()
        return true
    end

    function adapter.enable_apply()
        return adapter.set_mode("apply")
    end

    function adapter.disable_apply()
        return adapter.set_mode("diagnostic")
    end

    function adapter.retry_restore()
        if closed then return false end
        if state == nil then
            blocked = false
            status.blocked = false
            status.restore_pending = false
            status.restore_unresolved = false
            status.runtime_verified = false
            if status.phase == "quarantined" then set_phase("waiting", "no_lease_to_restore") end
            persist()
            return true
        end
        -- This public entry point may be called by a UI/render callback.  It
        -- therefore only queues work; the next UpdateMotion callback performs
        -- the holder setter and the delayed baseline verification.
        blocked = false
        status.blocked = false
        restore_request_queued = true
        status.restore_request_queued = true
        status.restore_pending = true
        status.runtime_verified = false
        set_phase("restoring", "explicit_restore_queued")
        persist()
        return false
    end

    function adapter.close(reason)
        if closed then return adapter.status() end
        reason = reason or "adapter_close"
        -- on_script_reset is synchronous and may run on the render/UI thread.
        -- Never call a native holder setter here.  If there is no later
        -- UpdateMotion callback, keep the lease marked unresolved and require
        -- a full game restart or a game-thread-aware owner to finish cleanup.
        close_requested = true
        close_reason = reason
        status.close_requested = true
        status.runtime_verified = false
        status.restore_requires_game_thread = state ~= nil
        if state ~= nil then
            status.restore_pending = true
            set_phase("restoring", "close_queued")
        end
        if reason == "script_reset" then
            close_requested = false
            status.close_requested = false
            if state ~= nil then
                blocked = true
                status.blocked = true
                status.restore_unresolved = true
                status.script_reset_requires_restart = true
                status.last_error = "script_reset_restore_unverified: no game-thread callback available"
                set_phase("quarantined", "script_reset_restore_unverified")
            else
                set_phase("closed", reason)
            end
            closed = true
        end
        persist()
        return adapter.status()
    end

    function adapter.definitions()
        return DEFINITIONS
    end

    return adapter
end

local adapter
local bootstrap_ok, bootstrap_error = pcall(function()
    adapter = new_adapter()
end)
if not bootstrap_ok then
    adapter = {
        tick = function() end,
        close = function() end,
        set_mode = function() return false end,
        enable_apply = function() return false end,
        disable_apply = function() return false end,
        retry_restore = function() return false end,
        status = function() return { schema = "yorha-2b-skeleton-adapter-status-v1", phase = "faulted", error = tostring(bootstrap_error), candidate = true } end,
    }
end

_G.yorha_2b_skeleton_adapter = adapter

if type(re) == "table" and type(re.on_pre_application_entry) == "function" then
    re.on_pre_application_entry("UpdateMotion", function() adapter.tick() end)
end
if type(re) == "table" and type(re.on_draw_ui) == "function" and type(imgui) == "table" and
    type(imgui.checkbox) == "function" then
    re.on_draw_ui(function()
        local changed, wanted = imgui.checkbox("Enable 2B independent skeleton (experimental)", adapter.status().mode == "apply")
        if changed then
            if wanted then adapter.enable_apply() else adapter.disable_apply() end
        end
        if type(imgui.text) == "function" then
            local current = adapter.status()
            imgui.text("2B skeleton: " .. tostring(current.phase) .. " / " .. tostring(current.mode))
        end
    end)
end
if type(re) == "table" and type(re.on_script_reset) == "function" then
    re.on_script_reset(function() adapter.close("script_reset") end)
end

return adapter
