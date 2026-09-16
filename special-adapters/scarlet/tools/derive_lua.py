"""Rebuild the gated Scarlet Lua candidate from the audited source.

The source is read only.  This intentionally uses bounded line edits instead
of regexes over the embedded JSON contract, whose long lines are easy to
corrupt.  The generated file is a derived candidate and is never executed by
this tool.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
SOURCE = ROOT / "参考文件" / "Scarlet-Model-1.1.0" / "reframework" / "autorun" / "scarlet_native_adapter.lua"
GATE = Path(__file__).resolve().parents[1] / "src" / "scarlet_gate.lua"
DEST = Path(__file__).resolve().parents[1] / "src" / "scarlet_manual_adapter.lua"
PATH_MAP = Path(__file__).resolve().parents[1] / "manifest" / "runtime-path-map.json"

# These two actor settings are present in the audited whole-player PFB but
# are not represented by the static wardrobe PFBs.  The derived candidate
# checks their runtime type definitions before it can bind any dynamic
# component.  Field layouts remain intentionally unresolved; a future
# private actor contract must supply them rather than guessing offsets.
ACTOR_SETTING_TYPES = (
    "app.CharacterTimelineEventActorPlayer.cVirtualGroundHeightOffsetSetting",
    "app.CharacterTimelineEventActorPlayer.cOverwriteSpecificWeaponDrawSetting",
)

# The audited contracts contain the original loose-mod paths.  The derived
# script must use the private wardrobe namespace that is actually shipped with
# each static ID.  ``{id}`` is resolved by scarlet_gate.route at runtime.
ROUTE_REWRITES = (
    ("art/mods/scarlet/p/body_mesh_2de4180b65dbe6b20a.mesh",
     "mods/scarlet_hat_static/6516e70211991f0b/body_mesh_2de4180b65dbe6b20a.mesh"),
    ("art/mods/scarlet/p/body_mesh_ae4e361f60ab521537.mesh",
     "mods/scarlet_no_hat_static/67cc2ab84782dc5b/body_mesh_ae4e361f60ab521537.mesh"),
    ("art/mods/scarlet/p/face_mesh_9da307fec900e6d3ae.mesh",
     "mods/{id}/6423f1b37f91f9b9/face_mesh_9da307fec900e6d3ae.mesh"),
    ("art/mods/scarlet/p/hair_empty_7b4984196f493e487.mesh",
     "mods/{id}/065fbc394a33f4ea/hair_empty_7b4984196f493e487.mesh"),
    ("art/mods/scarlet/p/rig_dd9ab81db072df9531fbfe9d.fbxskel",
     "mods/{id}/dynamic/rig.fbxskel"),
    ("art/mods/scarlet/isolation/scarlet_common.motbank",
     "mods/{id}/dynamic/scarlet_common.motbank"),
    ("art/mods/scarlet/isolation/scarlet_designchange.motbank",
     "mods/{id}/dynamic/scarlet_designchange.motbank"),
    ("art/mods/scarlet/isolation/scarlet_weapon.motbank",
     "mods/{id}/dynamic/scarlet_weapon.motbank"),
    ("art/mods/scarlet/isolation/scarlet_visual.user",
     "mods/{id}/dynamic/scarlet_visual.user"),
    ("art/mods/scarlet/isolation/scarlet_sheath.user",
     "mods/{id}/dynamic/scarlet_sheath.user"),
    ("art/mods/scarlet/isolation/scarlet_aaa.user",
     "mods/{id}/dynamic/scarlet_aaa.user"),
    ("art/mods/scarlet/p/empty_chain_188ce7286fa25651.chain2",
     "mods/{id}/dynamic/chain_0.chain2"),
    ("art/mods/scarlet/p/empty_chain_1378acd141f77147f46804b4fa4.chain2",
     "mods/{id}/dynamic/chain_2.chain2"),
)


def mapped_constraint_rewrites():
    """Return audited JCNS source paths as selected-ID placeholders.

    The seven actor/body constraint assets live in the source MOD under the
    same ``art/mods/scarlet/p`` directory.  Their target hash directories are
    identical for both static variants, but the leading wardrobe ID differs.
    Reading the checked-in full map keeps this generator synchronized with the
    actual resource builder and avoids hand-maintained path drift.
    """
    if not PATH_MAP.exists():
        raise RuntimeError(f"missing machine-readable path map: {PATH_MAP}")
    data = json.loads(PATH_MAP.read_text(encoding="utf-8"))
    variants = data.get("variants", {})
    hat = variants.get("scarlet_hat_static", {}).get("pathMap", {})
    no_hat = variants.get("scarlet_no_hat_static", {}).get("pathMap", {})
    result = []
    for source, target in sorted(hat.items()):
        if not (source.startswith("art/mods/scarlet/p/") and source.endswith(".jcns")):
            continue
        other = no_hat.get(source)
        if not other:
            raise RuntimeError(f"constraint path missing from no-hat map: {source}")
        target_placeholder = target.replace("mods/scarlet_hat_static/", "mods/{id}/", 1)
        other_placeholder = other.replace("mods/scarlet_no_hat_static/", "mods/{id}/", 1)
        if target_placeholder != other_placeholder:
            raise RuntimeError(f"variant constraint target differs: {source}")
        result.append((source, target_placeholder))
    if len(result) < 7:
        raise RuntimeError(f"expected at least 7 audited JCNS routes, got {len(result)}")
    return tuple(result)


def rewrite_routes(text):
    """Rewrite only audited Scarlet resource literals, preserving game paths."""
    for old, new in ROUTE_REWRITES + mapped_constraint_rewrites():
        text = text.replace(old, new)
    for quality in ("normal", "hq"):
        text = text.replace(
            f"art/mods/scarlet/private/parts_{quality}.user",
            f"mods/{{id}}/dynamic/parts_{quality}.user",
        )
        text = text.replace(
            f"art/mods/scarlet/private/refresh_{quality}.user",
            f"mods/{{id}}/dynamic/refresh_{quality}.user",
        )
        for index in range(8):
            text = text.replace(
                f"art/mods/scarlet/private/lease_{quality}_{index}.user",
                f"mods/{{id}}/dynamic/lease_{quality}_{index}.user",
            )
        text = text.replace(
            f"art/mods/scarlet/private/head_{quality}.pfb",
            f"mods/{{id}}/dynamic/head_{quality}.pfb",
        )
        text = text.replace(
            f"art/mods/scarlet/private/hair_{quality}.pfb",
            f"mods/{{id}}/dynamic/hair_{quality}.pfb",
        )
    return text


def find(lines, predicate, label, start=0, end=None):
    end = len(lines) if end is None else end
    hits = [i for i in range(start, end) if predicate(lines[i], i)]
    if len(hits) != 1:
        raise RuntimeError(f"{label}: expected 1 match, got {len(hits)} {hits[:8]}")
    return hits[0]


def after(lines, index, value):
    lines[index + 1:index + 1] = value.splitlines()


def main():
    source = rewrite_routes(SOURCE.read_text(encoding="utf-8-sig")).replace(
        "_G.scarlet_native_adapter", "_G.scarlet_manual_adapter"
    )
    lines = source.splitlines()
    header = """-- Scarlet Manual Wardrobe Adapter v1
-- Derived from Little1113's Scarlet-Model-1.1.0 native adapter.
-- This manually migrated candidate never loads the original Scarlet Lua/DLL.
-- Native writes and route hooks require the exact OWOTS wardrobe bridge gate.
-- Source provenance: Scarlet-Model-1.1.0 / scarlet_native_adapter.lua
-- Source SHA-256: B280101CDEC954F73EACE41527379500E6367504644F775B72291FC2A160A272
-- Original author: Little1113
""".splitlines()
    if lines[0].strip() != "local isolation_can_run":
        raise RuntimeError("unexpected audited source header")
    lines = GATE.read_text(encoding="utf-8").splitlines() + lines[1:]
    # ``re.on_script_reset`` is dispatched by ScriptRunner from a UI/render
    # context on some REFramework builds.  Keep the reset callback scalar-only:
    # native cleanup is explicitly restart-required and is flushed by the
    # game-thread callback below when the bridge gate can safely run it.
    gate_end = next(
        (index for index, line in enumerate(lines) if line.strip() == "end)()"),
        None,
    )
    if gate_end is None:
        raise RuntimeError("gate module end: missing module terminator")
    lines[gate_end + 1:gate_end + 1] = [
        "local scarlet_reset_required=false;local scarlet_reset_reason=nil",
    ]
    lines = [
        line.replace(
            "v.resource:match('^art/mods/scarlet/p/')",
            "v.resource:match('^mods/scarlet_(hat_static|no_hat_static)/')",
        )
        for line in lines
    ]

    # Keep the unresolved whole-player settings explicit in the generated
    # runtime contract.  Resolver.new performs a type-presence check during
    # bootstrap; no field offset or guessed setting layout is introduced.
    i = find(
        lines,
        lambda s, _: 'local C=json.load_string([=[{"schema":"scarlet-native-adapter-contract-v1"' in s,
        "native contract",
    )
    lines[i + 1:i + 1] = [
        "C.actor_setting_types={" + ",".join(repr(name) for name in ACTOR_SETTING_TYPES) + "}"
    ]

    # Bootstrap must reject a host that cannot even expose both unresolved
    # whole-player setting types.  This is a read-only type lookup; actual
    # component/field binding remains a separate actor preflight below.
    backend_start = find(lines, lambda s, _: s.strip() == "local Backend=(function()", "backend start")
    backend_ends = [
        idx for idx in range(backend_start + 1, len(lines))
        if lines[idx].strip() == "end)()"
    ]
    if not backend_ends:
        raise RuntimeError("backend end: missing module terminator")
    backend_end = backend_ends[0]
    i = find(
        lines,
        lambda s, _: s.strip() == "function M.new(C,sdk)",
        "backend constructor",
        backend_start,
        backend_end,
    )
    lines[i + 1:i + 1] = [
        "  for _,name in ipairs(C.actor_setting_types or{})do need(sdk.find_type_definition(name),'Actor contract type unavailable: '..name)end",
    ]

    i = find(lines, lambda s, _: s.strip().startswith("re.on_application_entry(C.entry,function()"), "main callback")
    after(lines, i, "   if not scarlet_gate.allow('UpdateConstraintsEnd') then scarlet_gate.flush_restore('UpdateConstraintsEnd');return end")
    i = find(lines, lambda s, _: "function self.close()closed=true;pending={}" in s, "late close")
    lines[i] = lines[i].replace(
        "event({kind='closed'});return self.status()end",
        "event({kind='closed'});return self.status()end\n function self.retry()closed=false;pending={};status.closed=false;return self.status()end",
    )
    i = find(lines, lambda s, _: "stack[#stack+1]=not closed and core.before" in s, "late hook")
    lines[i] = lines[i].replace(
        "stack[#stack+1]=not closed and core.before",
        "stack[#stack+1]=scarlet_gate.allow('UpdateJoint') and not closed and core.before",
    )
    i = find(lines, lambda s, _: s.strip().startswith("return{status=core.status,events=core.events"), "late return")
    lines[i] = lines[i].replace(
        "close=function()closed=true;bound=nil;return core.close()end,",
        "close=function()closed=true;bound=nil;return core.close()end,retry=function()closed=false;bound=nil;return core.retry()end,",
    )
    i = find(lines, lambda s, _: "re.on_script_reset(function()if late then late.close()end;if controller then controller:close()end end" in s, "main reset")
    lines[i:i] = [
        "scarlet_gate.on_disable(function(reason)local all=true;if controller then local ok,result=pcall(function()return controller:retry()end);if not ok or result==false then all=false end end;if late and late.retry then local ok,result=pcall(late.retry);if not ok or result==false then all=false end end;return all end)"
    ]

    # Both private-parts hooks mutate native request/closure objects.
    indices = [i for i, s in enumerate(lines) if "if closed or not state.active then return end" in s]
    if len(indices) != 2:
        raise RuntimeError(f"router guards: {indices}")
    lines[indices[0]] = lines[indices[0]].replace(
        "if closed or not state.active then return end",
        "if closed or not state.active or not scarlet_gate.allow('private_parts_request') then return end",
    )
    lines[indices[1]] = lines[indices[1]].replace(
        "if closed or not state.active then return end",
        "if closed or not state.active or not scarlet_gate.allow('private_parts_closure') then return end",
    )

    router_start = find(lines, lambda s, _: s.strip() == "local Router=(function()", "router start")
    prop_marker = find(lines, lambda s, _: s.strip() == "local Prop=(function()", "prop marker", router_start + 1)
    i = find(
        lines,
        lambda s, idx: s.strip() == "function self.close()" and idx + 2 < prop_marker and "state.active=false;state.closed=true" in lines[idx + 2],
        "router close",
        router_start,
        prop_marker,
    )
    lines[i:i] = [
        " function self.pause()",
        "  if closed then return end;state.active=false;state.quarantined=true",
        "  local ok,why=pcall(retire_catalogs);if not ok then state.cleanup_error=tostring(why)end;return ok",
        " end",
        " function self.resume()state.quarantined=false;return true end",
    ]
    router_start = find(lines, lambda s, _: s.strip() == "local Router=(function()", "router start refresh")
    prop_marker = find(lines, lambda s, _: s.strip() == "local Prop=(function()", "prop marker refresh", router_start + 1)
    i = find(lines, lambda s, _: s.strip() == "re.on_frame(function()", "router frame", router_start, prop_marker)
    after(lines, i, " if not scarlet_gate.allow('private_parts_frame') then return end\n if instance and instance.resume then instance.resume()end")
    i = find(lines, lambda s, _: "s.private_parts=instance and instance.status()" in s, "router status", router_start, prop_marker)
    after(lines, i, " scarlet_gate.on_disable(function()if instance and instance.pause then local ok,result=pcall(instance.pause);return ok and result~=false end;return true end)")

    # Prop visibility has reversible mesh.enabled leases.
    prop_start = find(lines, lambda s, _: s.strip() == "local Prop=(function()", "prop start")
    fit_marker = find(lines, lambda s, _: s.strip() == "local Fit=(function()", "fit marker", prop_start + 1)
    i = find(lines, lambda s, _: "local defs,methods,fields={},{},{};local image;local closed=false;local leases={}" in s, "prop locals", prop_start, fit_marker)
    lines[i] = lines[i].replace("closed=false;local leases={}", "closed=false;local paused=false;local leases={}")
    fit_marker = find(lines, lambda s, _: s.strip() == "local Fit=(function()", "fit marker refresh", i + 1)
    i = find(lines, lambda s, idx: s.strip() == "function self.step()" and idx + 1 < fit_marker and "if closed then return end" in lines[idx + 1], "prop step", prop_start, fit_marker)
    lines[i + 1] = lines[i + 1].replace("if closed then return end", "if closed or paused then return end")
    i = find(lines, lambda s, idx: s.strip() == "function self.close()" and idx + 1 < fit_marker and "closed=true;local old={}" in lines[idx + 1], "prop close", prop_start, fit_marker)
    lines[i:i] = [
        " function self.pause()",
        "  if closed then return true end;local all=true;local old={};for key in pairs(leases)do old[#old+1]=key end;for _,key in ipairs(old)do local ok=pcall(release,key);if not ok then all=false end end;paused=true;return all",
        " end",
        " function self.resume()if not closed then paused=false end;return true end",
    ]
    i = find(lines, lambda s, _: "re.on_pre_application_entry('BeginRendering',function()" in s, "prop callback", prop_start, fit_marker + 8)
    lines[i] = "re.on_pre_application_entry('BeginRendering',function()if not scarlet_gate.allow('BeginRendering') then return end;if good and instance then if instance.resume then instance.resume()end;instance.step()end end)"

    # Left fit writes rotations in the updateJoint pre-hook.
    fit_start = find(lines, lambda s, _: s.strip() == "local Fit=(function()", "fit start")
    fit_end = find(lines, lambda s, _: "local FC=json.load_string" in s, "fit end", fit_start + 1)
    i = find(lines, lambda s, _: "store.scarlet_left_reference=nil;S.entries=S.entries+1;if closed then return end" in s, "fit hook", fit_start, fit_end)
    lines[i] = lines[i].replace("if closed then return end", "if closed or not scarlet_gate.allow('left_fit_updateJoint') then return end")

    # Release owns a reversible blade local-position lease.
    release_start = find(lines, lambda s, _: s.strip() == "local Release=(function()", "release start")
    release_end = find(lines, lambda s, _: "local GC=json.load_string" in s, "release end", release_start + 1)
    i = find(lines, lambda s, _: "status=function()S.closed=closed" in s and "lease=nil end}" in s, "release return", release_start, release_end)
    lines[i] = lines[i].replace(
        "end,status=function()S.closed=closed;return S end,close=",
        "end,status=function()S.closed=closed;return S end,pause=function()local ok,why=pcall(restore);if not ok then S.restore_error=tostring(why);return false end;lease=nil;return true end,close=",
    )
    i = find(lines, lambda s, _: "re.on_application_entry('UpdateBehavior',function()" in s, "release callback")
    lines[i] = "re.on_application_entry('UpdateBehavior',function()if not scarlet_gate.allow('UpdateBehavior') then return end;if good then release.step()end end)"

    i = find(lines, lambda s, _: "if closed or S.weapon_error then return end" in s, "weapon setup")
    lines[i] = lines[i].replace("if closed or S.weapon_error then return end", "if closed or S.weapon_error or not scarlet_gate.allow('weapon_setup_visual') then return end")
    i = find(lines, lambda s, _: "if closed or updating or S.weapon_error then return end" in s, "weapon update")
    lines[i] = lines[i].replace("if closed or updating or S.weapon_error then return end", "if closed or updating or S.weapon_error or not scarlet_gate.allow('weapon_update_visual') then return end")

    # Isolation exposes an ownership-checked restore operation for the gate's
    # game-thread flush.  A render/UI denial only queues that operation; it is
    # never called directly from the hook that observed the denial.
    isolation_start = find(lines, lambda s, _: s.strip() == "local Isolation=(function()", "isolation start")
    i = find(lines, lambda s, idx: s.strip() == "function self.status()return S end" and idx + 1 < len(lines) and "function self.can_run()" in lines[idx + 1], "isolation status", isolation_start)
    lines[i:i] = [
        " function self.pause()",
        "  if closed then return end",
        "  local all=true;for _,s in pairs(owners)do if s and not s.failed then local ok,why=pcall(function()custom_enabled(s,false);apply_banks(s,'native');apply_parameters(s,'native');s.family='native';s.target=nil;s.phase='ready'end);if not ok then all=false;S.restore_unresolved=true;S.last_restore_error=tostring(why)end end end",
        "  if all then invalidate('manual gate disabled');S.restore_unresolved=false;S.phase='paused' else S.phase='restore_pending' end;return all",
        " end",
    ]
    i = find(lines, lambda s, _: s.strip().startswith("isolation_can_run=function()"), "isolation can_run")
    lines[i] = "isolation_can_run=function()return scarlet_gate.allow('isolation_can_run') and ok and isolation.can_run()end"
    i = find(lines, lambda s, _: s.strip().startswith("re.on_pre_application_entry('UpdateMotion',function()"), "motion callback")
    lines[i] = "re.on_pre_application_entry('UpdateMotion',function()if not scarlet_gate.allow('UpdateMotion') then return end;if ok then isolation.step()else json.dump_file('scarlet-driver-isolation-status.json',{error=tostring(isolation)},-1)end end)"

    # Do not let any dynamic rig, weapon, cloth or native stage writer run
    # before the exact whole-player actor contract has been observed.  The
    # resolver already validates the ordered 264/577 skeleton and all eleven
    # role components without binding them; this callback turns a failed
    # validation into an explicit retryable quarantine reason.
    isolation_end = find(
        lines,
        lambda s, idx: idx > isolation_start and s.strip() == "end)()",
        "isolation end",
        isolation_start + 1,
    )
    i = find(
        lines,
        lambda s, _: s.strip() == "function M.new(C,sdk,invalidate)",
        "isolation constructor",
        isolation_start,
        isolation_end,
    )
    lines[i] = " function M.new(C,sdk,invalidate,actor_preflight)"
    i = find(
        lines,
        lambda s, _: s.strip().startswith("local S={schema='scarlet-costume-driver-isolation-v2'"),
        "isolation status",
        isolation_start,
        isolation_end,
    )
    lines[i] = lines[i].replace(
        "owners={},events={}",
        "owners={},events={},blocked_reason=nil,actor_contract_required=true",
    )
    i = find(
        lines,
        lambda s, _: s.strip() == "local self={};local last_output=0",
        "isolation locals",
        isolation_start,
        isolation_end,
    )
    lines[i:i] = [
        "  local function actor_ready()",
        "   if type(actor_preflight)~='function' then return false,'actor_contract_preflight_missing' end",
        "   local probe_ok,ready,reason=pcall(actor_preflight)",
        "   if not probe_ok then return false,'actor_contract_missing:'..tostring(ready) end",
        "   if ready~=true then return false,tostring(reason or 'actor_contract_missing') end",
        "   return true",
        "  end",
    ]
    i = find(
        lines,
        lambda s, idx: s.strip() == "function self.step()" and idx + 1 < isolation_end and lines[idx + 1].strip() == "if closed then return end",
        "isolation step",
        isolation_start,
        isolation_end,
    )
    lines[i + 2:i + 2] = [
        "   local actor_ok,actor_reason=actor_ready()",
        "   if not actor_ok then S.phase='blocked_actor_contract';S.blocked_reason=actor_reason;S.actor_contract_blocked_frames=(S.actor_contract_blocked_frames or 0)+1;if os.clock()-last_output>.25 then last_output=os.clock();json.dump_file('scarlet-driver-isolation-status.json',S,-1)end;return end",
        "   S.blocked_reason=nil;if S.phase=='blocked_actor_contract' then S.phase='waiting' end",
    ]
    i = find(
        lines,
        lambda s, _: s.strip() == "function self.can_run()",
        "isolation can_run body",
        isolation_start,
        isolation_end,
    )
    guard = find(
        lines,
        lambda s, _: s.strip() == "if closed or not refs.ready or S.errors>0 then return false end",
        "isolation can_run guard",
        i + 1,
    )
    lines[guard + 1:guard + 1] = [
        "   local actor_ok,actor_reason=actor_ready();if not actor_ok then S.phase='blocked_actor_contract';S.blocked_reason=actor_reason;return false end;S.blocked_reason=nil;if S.phase=='blocked_actor_contract' then S.phase='waiting' end",
    ]

    # The gate calls this same read-only preflight from every native hook, so
    # weapon/parts/cloth callbacks cannot get a write window before Isolation
    # has validated the actor.  Throttle only the expensive resolver scan;
    # actor/selection changes invalidate naturally on the next probe window.
    i = find(
        lines,
        lambda s, _: s.strip().startswith("local ok,isolation=pcall(Isolation.new,IC,sdk,"),
        "isolation construction call",
    )
    original_motion = lines[i + 1]
    lines[i:i + 2] = [
        "local actor_preflight_last=-1;local actor_preflight_next=0;local actor_preflight_ready=false;local actor_preflight_reason='actor_contract_preflight_missing'",
        "local function actor_preflight()local frame=adapter.frame();if type(frame)~='number'or frame<0 then actor_preflight_ready=false;actor_preflight_reason='actor_contract_missing:invalid frame';return false,actor_preflight_reason end;if actor_preflight_last>=0 and frame<actor_preflight_last then actor_preflight_next=0;actor_preflight_ready=false end;actor_preflight_last=frame;if frame<actor_preflight_next then return actor_preflight_ready,actor_preflight_reason end;actor_preflight_next=frame+15;local probe_ok,ready,detail=pcall(function()local contexts=adapter.resolve_all(frame,true);if type(contexts)~='table'then return false,'actor_contract_missing:resolve_all returned invalid contexts'end;for _,ctx in ipairs(contexts)do if ctx and ctx.kind=='player'and adapter.current_owner_context(ctx)==true then return true,nil end end;return false,'actor_contract_missing:player actor context absent'end);if probe_ok and ready==true then actor_preflight_ready=true;actor_preflight_reason=nil;return true end;actor_preflight_ready=false;if probe_ok then actor_preflight_reason=tostring(detail or 'actor_contract_missing:player actor context absent')else actor_preflight_reason='actor_contract_missing:'..tostring(ready)end;return false,actor_preflight_reason end",
        "scarlet_gate.set_actor_preflight(actor_preflight)",
        "local ok,isolation=pcall(Isolation.new,IC,sdk,function()if adapter then adapter.invalidate('manual gate disabled')end;if controller then controller:retry()end end,actor_preflight)",
        original_motion,
    ]

    # Resolve the placeholder namespace at the actual resource boundary.  The
    # static catalog route is already private and exact; the dynamic motion,
    # skeleton, chain and USER companions are selected by the same wardrobe ID.
    for index, line in enumerate(lines):
        # Normalize after expanding the selected wardrobe ID.  This keeps
        # native read-back paths comparable to contract placeholders in the
        # dynamic fallback (the static catalog path is already concrete).
        line = line.replace(
            "local function canon(p)return type(p)=='string'and p:gsub('\\\\','/'):",
            "local function canon(p)return type(p)=='string'and scarlet_gate.route(p):gsub('\\\\','/'):",
        )
        line = line.replace(
            "type(p)=='string'and p:lower():gsub",
            "type(p)=='string'and scarlet_gate.route(p):lower():gsub",
        )
        line = line.replace(
            "p and p:lower():gsub",
            "p and scarlet_gate.route(p):lower():gsub",
        )
        line = line.replace(
            "canonical(A.path(p))==path",
            "canonical(A.path(p))==canonical(scarlet_gate.route(path))",
        )
        line = line.replace(
            "canonical(A.path(p))==part.path",
            "canonical(A.path(p))==canonical(scarlet_gate.route(part.path))",
        )
        line = line.replace(
            "resource(call('jc_layer_asset',l))~=path",
            "resource(call('jc_layer_asset',l))~=canonical(scarlet_gate.route(path))",
        )
        line = line.replace(
            "A.path(p)==part.path",
            "A.path(p)==canon(scarlet_gate.route(part.path))",
        )
        line = line.replace(
            "sdk.create_resource('via.PrefabResource',path)",
            "sdk.create_resource('via.PrefabResource',scarlet_gate.route(path))",
        )
        line = line.replace(
            "path==(part==2 and C.scarlet_head_mesh or C.scarlet_hair_mesh)",
            "path==canon(part==2 and scarlet_gate.route(C.scarlet_head_mesh) or scarlet_gate.route(C.scarlet_hair_mesh))",
        )
        line = line.replace(
            "need(path(s.scarlet_bank)==C.scarlet_banks[role]",
            "need(path(s.scarlet_bank)==scarlet_gate.route(C.scarlet_banks[role])",
        )
        line = line.replace(
            "if r.path==C.scarlet_weapon or r.path==C.original_weapon then",
            "if r.path==scarlet_gate.route(C.scarlet_weapon) or r.path==C.original_weapon then",
        )
        line = line.replace(
            "v.rig==(want=='native'and C.native_rig or C.scarlet_rig)",
            "v.rig==(want=='native'and C.native_rig or scarlet_gate.route(C.scarlet_rig))",
        )
        line = line.replace(
            "p and p:match('^art/mods/scarlet/')",
            "p and p:match('^mods/scarlet_[^/]+/')",
        )
        line = line.replace(
            "sdk.create_userdata(x.type,x.path)",
            "sdk.create_userdata(x.type,scarlet_gate.route(x.path))",
        )
        line = line.replace(
            "sdk.create_resource(x.type,x.path)",
            "sdk.create_resource(x.type,scarlet_gate.route(x.path))",
        )
        lines[index] = line

    # Actor preflight is also called by render/UI-side gate checks.  The normal
    # resolver retires stale source leases, which can restore native fields;
    # give it a read-only mode for preflight so only the game-thread frame path
    # performs lease retirement.
    i = find(lines, lambda s, _: s.strip() == "function self.resolve_all(frame)", "backend resolve_all")
    lines[i] = "  function self.resolve_all(frame,read_only)"
    i = find(
        lines,
        lambda s, _: "if not managed(manager,'app.PlayerManager')then release_all_sources();cache={};missing_probe={};return{}end" in s,
        "backend resolve_all manager guard",
    )
    lines[i] = lines[i].replace(
        "if not managed(manager,'app.PlayerManager')then release_all_sources();cache={};missing_probe={};return{}end",
        "if not managed(manager,'app.PlayerManager')then if not read_only then release_all_sources()end;cache={};missing_probe={};return{}end",
    )
    i = find(
        lines,
        lambda s, _: "local retired={};for address in pairs(bound_sources)do if not used[address]then retired[#retired+1]=address end end;for _,address in ipairs(retired)do release_source(address)end" in s,
        "backend resolve_all lease retirement",
    )
    lines[i] = lines[i].replace(
        "local retired={};for address in pairs(bound_sources)do if not used[address]then retired[#retired+1]=address end end;for _,address in ipairs(retired)do release_source(address)end",
        "if not read_only then local retired={};for address in pairs(bound_sources)do if not used[address]then retired[#retired+1]=address end end;for _,address in ipairs(retired)do release_source(address)end end",
    )
    for index, line in enumerate(lines):
        if "local contexts=adapter.resolve_all(frame);" in line:
            lines[index] = line.replace(
                "local contexts=adapter.resolve_all(frame);",
                "local contexts=adapter.resolve_all(frame,true);",
            )

    # Decorators wrap the backend resolver after the base read-only guard is
    # installed.  Preserve the flag through every wrapper; otherwise a
    # render/UI actor probe would silently call the backend in write mode and
    # retire native source leases off the game thread.
    for index, line in enumerate(lines):
        if line.strip() == "function A.resolve_all(frame)":
            lines[index] = " function A.resolve_all(frame,read_only)"
            line = lines[index]
        if "local contexts=original_resolve(frame);" in line:
            lines[index] = line.replace(
                "local contexts=original_resolve(frame);",
                "local contexts=original_resolve(frame,read_only);",
            )
        if "local contexts=resolve(frame);" in line:
            lines[index] = lines[index].replace(
                "local contexts=resolve(frame);",
                "local contexts=resolve(frame,read_only);",
            )

    # All modules that own persistent native state must participate in the
    # game-thread restore flush.  The reset callbacks remain scalar-only;
    # these handlers are the only cleanup route after a gate denial.
    prop_start = find(lines, lambda s, _: s.strip() == "local Prop=(function()", "prop start for restore")
    fit_marker = find(lines, lambda s, _: s.strip() == "local Fit=(function()", "fit marker for restore", prop_start + 1)
    i = find(lines, lambda s, _: s.strip().startswith("local good,instance=pcall(Prop.new"), "prop construction", prop_start, fit_marker)
    after(lines, i, "scarlet_gate.on_disable(function()if good and instance and instance.pause then local ok,result=pcall(instance.pause);return ok and result~=false end;return true end)")

    release_start = find(lines, lambda s, _: s.strip() == "local Release=(function()", "release start for restore")
    release_end = find(lines, lambda s, _: s.strip().startswith("local GC=json.load_string"), "release end for restore", release_start + 1)
    # The construction follows the embedded GC contract, so it is after the
    # module marker's JSON boundary rather than inside ``release_end``.
    i = find(lines, lambda s, _: s.strip().startswith("local good,release=pcall(Release.new"), "release construction", release_end + 1)
    after(lines, i, "scarlet_gate.on_disable(function()if good and release and release.pause then local ok,result=pcall(release.pause);return ok and result~=false end;return true end)")

    i = find(lines, lambda s, _: s.strip().startswith("local ok,isolation=pcall(Isolation.new"), "isolation construction for restore")
    after(lines, i, "scarlet_gate.on_disable(function()if ok and isolation and isolation.pause then local ok2,result=pcall(isolation.pause);return ok2 and result~=false end;return true end)")

    # Isolation chain maps use the placeholder route as their JSON key.  Look
    # up by the resolved path as well, so the actual Chain2 holder is paired
    # with the native chain after {id} expansion.
    for index, line in enumerate(lines):
        if line.strip() == "local function bind(root,role,processor,entity)":
            lines[index:index] = [
                "  local function route_map(map,key)",
                "   if not map then return nil end;local direct=map[key];if direct then return direct end",
                "   for source,value in pairs(map)do if canon(source)==key then return value end end",
                "  end",
            ]
            break

    # Pool entries are keyed by the placeholder path in the embedded
    # contract, while the native catalog returns the expanded path.  Keep
    # the private-path check strict, but compare through the selected route.
    # This prevents an unrelated mod's Prefab from being put into our pool.
    for index, line in enumerate(lines):
        if line.strip() == "local pool_adapter={":
            lines[index:index] = [
                "  local function private_path(path)",
                "   local actual=canon(path);if not actual then return false end",
                "   for expected in pairs(C.private_paths)do",
                "    if actual==canon(expected)or actual==canon(expected:gsub('{id}','scarlet_hat_static'))or actual==canon(expected:gsub('{id}','scarlet_no_hat_static'))then return true end",
                "   end",
                "   return false",
                "  end",
            ]
            break
    for index, line in enumerate(lines):
        lines[index] = line.replace(
            "need(C.private_paths[canon(call('prefab_path',o))],'Private prefab path required')",
            "need(private_path(call('prefab_path',o)),'Private prefab path required')",
        )
    for index, line in enumerate(lines):
        lines[index] = line.replace(
            "local h=call('chain_get',c);local key=C.chain_map[path(h)];local pair=C.chain_pairs and C.chain_pairs[path(h)]",
            "local h=call('chain_get',c);local hp=path(h);local key=route_map(C.chain_map,hp);local pair=route_map(C.chain_pairs,hp)",
        )

    # The static wardrobe catalog owns Head/Hair already.  Running the old
    # dynamic catalog router in that mode would duplicate IDs and could touch
    # another mod's equipment, so it is a deliberate no-op in the exact
    # bridge-approved state.
    for index, line in enumerate(lines):
        if line.strip() == "if closed or state.fatal_error then return end":
            lines[index:index] = [
                "   if scarlet_gate.static_catalog_verified() then state.ready=true;state.active=false;state.static_catalog_mode=true;return end",
            ]
            break

    # A failed release must keep its lease for a later, ownership-checked
    # retry.  The gate treats a false return as unresolved restoration.
    for index, line in enumerate(lines):
        lines[index] = line.replace(
            "function self.pause()\n  if closed then return end",
            "function self.pause()\n  if closed then return true end",
        )

    # Reset handlers are deliberately reduced to a scalar marker.  Several
    # original handlers call close(), and close() may restore native values;
    # doing that from ScriptRunner's reset dispatch can run on a UI/render
    # thread.  A restart is therefore required instead of attempting native
    # cleanup from the reset callback.  Keep the source handler shape intact
    # enough for REFramework registration while making the callback harmless.
    for index, line in enumerate(lines):
        if "re.on_script_reset(function()" in line and ".close" in line:
            lines[index] = "re.on_script_reset(function()scarlet_reset_required=true;scarlet_reset_reason='script_reset_requires_restart';end)"

    # Expose the marker in the diagnostic status without adding a write path.
    i = find(lines, lambda s, _: "s.wrapper_error=boot_error" in s, "status wrapper error")
    lines[i + 1:i + 1] = [
        "s.restart_required=scarlet_reset_required;s.restart_reason=scarlet_reset_reason",
    ]

    i = find(lines, lambda s, _: s.strip() == "_G.scarlet_manual_adapter.voice_api_version=1", "status marker")
    lines[i:i] = [
        "_G.scarlet_manual_adapter.manual_migration=true",
        "_G.scarlet_manual_adapter.original_author='Little1113'",
        "_G.scarlet_manual_adapter.gate=scarlet_gate.status",
    ]
    DEST.write_text("\n".join(header + lines) + "\n", encoding="utf-8")
    print(f"wrote {DEST} bytes={DEST.stat().st_size} lines={len(header + lines)}")
    print(f"sdk.hook={sum('sdk.hook' in s for s in lines)} re.callbacks={sum('re.on_' in s for s in lines)} gate.checks={sum('scarlet_gate.allow' in s for s in lines)}")


if __name__ == "__main__":
    main()
