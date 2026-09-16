-- Scarlet manual wardrobe gate (v2).
--
-- The only enable signal is the narrow, read-only wardrobe bridge. This
-- module owns no equipment or save state. It owns the lease boundary for the
-- native writes in the derived adapter: identity changes and failed restores
-- quarantine the adapter until every registered owner reports a restore.
-- The audited source declares this local before its first callback.  The
-- derived file prepends this gate, so preserve that scope explicitly.
local isolation_can_run
local scarlet_gate=(function()
 local M={
 previous=false,allowed=false,reason='bridge_missing',snapshot=nil,
  transitions=0,checks=0,handlers={},evaluating=false,
  restorePending=false,restoreUnresolved=false,restoreErrors={},
  restoreQueued=false,
  identity=nil,lastIdentity=nil,lastIdentityChange=nil,reentrant=0,
  actorPreflight=nil,actorContractBlocked=false,actorContractReason=nil,
 }
 local expected={
  scarlet_hat_static={
   BODY={prefab='mods/scarlet_hat_static/b60902b0c9f97048/ch001_00_00_HQ.pfb',catalog='mods/scarlet_hat_static/c406cadd4073f518/playerbodypartslisthq_1st.user'},
   HEAD={prefab='mods/scarlet_hat_static/2670bb075a9de61f/ch001_00_10_HQ.pfb',catalog='mods/scarlet_hat_static/cf3fdf041f9fbd65/playerheadpartslisthq_1st.user'},
   HAIR={prefab='mods/scarlet_hat_static/fa78e476fb9051c2/ch001_00_20_HQ.pfb',catalog='mods/scarlet_hat_static/1f9bad298db57811/playerhairpartslisthq_1st.user'}},
  scarlet_no_hat_static={
   BODY={prefab='mods/scarlet_no_hat_static/8fabaa2952df9e4c/ch001_01_00_HQ.pfb',catalog='mods/scarlet_no_hat_static/c406cadd4073f518/playerbodypartslisthq_1st.user'},
   HEAD={prefab='mods/scarlet_no_hat_static/2670bb075a9de61f/ch001_00_10_HQ.pfb',catalog='mods/scarlet_no_hat_static/cf3fdf041f9fbd65/playerheadpartslisthq_1st.user'},
   HAIR={prefab='mods/scarlet_no_hat_static/fa78e476fb9051c2/ch001_00_20_HQ.pfb',catalog='mods/scarlet_no_hat_static/1f9bad298db57811/playerhairpartslisthq_1st.user'}}}
 local function clean(v)
  return type(v)=='string' and v:gsub('\\','/'):gsub('^@',''):lower() or nil
 end
 local function live_address(v)
  if type(v)~='string' then return false end
  local x=v:lower():gsub('%s+','')
  return x:match('^0x[0-9a-f]+$')~=nil and x:match('^0x0+$')==nil
 end
 local function decode(v)
  if type(v)=='table' then return v end
  if type(v)=='string' and type(json)=='table' and type(json.load_string)=='function' then
   local ok,out=pcall(json.load_string,v);if ok and type(out)=='table' then return out end
  end
 end
 local function bridge_snapshot()
  local api=rawget(_G,'owots_appearance_lab');local f
  if type(api)=='table' then f=api.get_scarlet_adapter_snapshot or api.get_scarlet_adapter_snapshot_json end
  if type(f)~='function' then f=rawget(_G,'owots_appearance_lab_get_scarlet_adapter_snapshot')end
  if type(f)~='function' then return nil,'wardrobe_bridge_missing'end
  local ok,out=pcall(f);if not ok then return nil,'wardrobe_bridge_error:'..tostring(out)end
  local decoded=decode(out);if not decoded then return nil,'wardrobe_snapshot_not_object'end
  return decoded,nil
 end
 local function part_row(parts,name)
  if type(parts)~='table' then return nil end
  for _,row in pairs(parts)do
   if type(row)=='table' and type(row.part)=='string' and row.part:upper()==name then return row end
  end
 end
 local function exact_route(row,want)
  if type(row)~='table' or type(want)~='table' then return false end
  return clean(row.prefab)==clean(want.prefab) and clean(row.catalog)==clean(want.catalog)
 end
 local function identity(s)
  if type(s)~='table' then return nil end
  return table.concat({
   tostring(s.sessionId or ''),tostring(s.effectiveBodyModId or ''),
   tostring(s.selectionRevision or ''),clean(s.supporterAddress) or '',
   clean(s.playerEntityAddress) or '',
  },'|')
 end
 local function assess(s)
  if type(s)~='table' then return false,'snapshot_not_object' end
  local id=s.effectiveBodyModId;local map=expected[id]
  if not map then return false,'unsupported_scarlet_wardrobe_id' end
  if s.ready~=true then return false,tostring(s.reason or 'snapshot_not_ready') end
  if s.busy==true then return false,'wardrobe_busy' end
  if s.restoreUnresolved==true then return false,'wardrobe_restore_unresolved' end
  if s.catalogRowsVerified~=true then return false,'catalog_rows_not_verified' end
  if not live_address(s.supporterAddress) then return false,'supporter_address_not_live' end
  if not live_address(s.playerEntityAddress) then return false,'player_entity_address_not_live' end
  for _,part in ipairs({'BODY','HEAD','HAIR'})do
   if not exact_route(part_row(s.parts,part),map[part]) then return false,'catalog_route_mismatch:'..part end
  end
  return true,'ready'
 end
 local function assess_actor_contract()
  if type(M.actorPreflight)~='function' then return false,'actor_contract_preflight_missing' end
  local ok,ready,reason=pcall(M.actorPreflight)
  if not ok then return false,'actor_contract_missing:'..tostring(ready) end
  if ready~=true then return false,tostring(reason or 'actor_contract_missing') end
  return true,'ready'
 end
 local function run_restore(reason,s)
  local all=true;M.restoreErrors={}
  for index,handler in ipairs(M.handlers)do
   local ok,result=pcall(handler,reason,s)
   if not ok or result==false then
    all=false
    M.restoreErrors[#M.restoreErrors+1]={index=index,error=not ok and tostring(result) or 'handler_returned_false'}
   end
  end
  M.restorePending=not all;M.restoreUnresolved=not all
  if not all then M.lastRestoreFailure=reason end
  return all
 end
 local function evaluate(tag)
  -- Native getter hooks may indirectly ask for the snapshot. A nested query
  -- must fail closed without recursively running restoration handlers.
  if M.evaluating then M.reentrant=M.reentrant+1;M.reason='bridge_reentrant';return false,'bridge_reentrant' end
  M.evaluating=true;M.checks=M.checks+1
  local s,why=bridge_snapshot();local good,assessment=assess(s);why=good and assessment or why or assessment
  local actor_good,actor_reason=true,'not_checked'
  if good then actor_good,actor_reason=assess_actor_contract()end
  local accepted=good and actor_good
  if not accepted and good then why=actor_reason end
  local next_identity=identity(s)
  local changed=M.identity~=nil and next_identity~=M.identity
  local needs_restore=M.previous or M.allowed or M.restorePending or M.restoreUnresolved
  -- A gate check can run from a render/UI callback.  Never invoke a native
  -- restore handler from that path: queue it for flush_restore on the known
  -- game-thread application callback instead.
  if needs_restore and (M.restorePending or M.restoreUnresolved) then
   M.previous=false;M.allowed=false;M.actorContractBlocked=good and not actor_good or false;M.actorContractReason=good and actor_reason or nil
   M.reason='restore_pending';M.evaluating=false;return false,M.reason
  end
  if needs_restore and ((not accepted) or changed) then
   M.transitions=M.transitions+1
   if changed then M.lastIdentityChange={from=M.identity,to=next_identity,tag=tag} end
   M.previous=false;M.allowed=false;M.lastIdentity=M.identity;M.identity=nil
   M.restorePending=true;M.restoreUnresolved=true;M.restoreQueued=true;M.lastRestoreFailure=changed and 'wardrobe_identity_changed' or (why or 'rejected')
   M.snapshot=s;M.reason='restore_queued:'..tostring(M.lastRestoreFailure);M.evaluating=false;return false,M.reason
  end
  M.snapshot=s
  if not accepted then
   M.previous=false;M.allowed=false;M.actorContractBlocked=good and not actor_good or false;M.actorContractReason=good and actor_reason or nil;M.reason=why or 'rejected';M.evaluating=false;return false,M.reason
  end
  if M.restorePending or M.restoreUnresolved then
   M.previous=false;M.allowed=false;M.reason='restore_pending';M.evaluating=false;return false,M.reason
  end
  M.identity=next_identity;M.previous=true;M.allowed=true;M.actorContractBlocked=false;M.actorContractReason=nil;M.reason='ready';M.effectiveBodyModId=s.effectiveBodyModId
  M.evaluating=false;return true,M.reason
 end
 function M.allow(tag)return evaluate(tag or 'unknown')end
  function M.flush_restore(reason)
   -- This is the sole native-restore entry point.  The derived adapter calls
   -- it from the known game-thread application callback; render/UI hooks only
   -- call allow(), which records restoreQueued and returns.
   if not M.restorePending and not M.restoreUnresolved and not M.restoreQueued then return true end
  local cause=reason or M.lastRestoreFailure or 'restore_queued'
  local restored=run_restore(cause,M.snapshot)
  M.restoreQueued=false
  if restored then
   M.restorePending=false;M.restoreUnresolved=false;M.lastRestoreFailure=nil;M.reason='restored';return true
  end
  M.restorePending=true;M.restoreUnresolved=true;M.restoreQueued=true;M.reason='restore_pending:'..tostring(M.lastRestoreFailure or cause);return false
 end
 function M.static_catalog_verified()
  if not M.allowed or M.restorePending or M.restoreUnresolved then return false end
  local good=assess(M.snapshot);return good==true
 end
 function M.selected_id()
  return M.allowed and M.snapshot and expected[M.snapshot.effectiveBodyModId] and M.snapshot.effectiveBodyModId or nil
 end
 function M.route(path)
  if type(path)~='string' then return path end
  local id=M.selected_id();if not id then return path end
  return path:gsub('{id}',id)
 end
 function M.set_actor_preflight(handler)
  if handler~=nil and type(handler)~='function' then return false end
  M.actorPreflight=handler;return true
 end
 function M.status()
  return{schema='scarlet-manual-gate-v2',allowed=M.allowed,reason=M.reason,checks=M.checks,
   transitions=M.transitions,restorePending=M.restorePending,restoreUnresolved=M.restoreUnresolved,
   restoreErrors=M.restoreErrors,identity=M.identity,lastIdentity=M.lastIdentity,
   restoreQueued=M.restoreQueued,
   actorContractBlocked=M.actorContractBlocked,actorContractReason=M.actorContractReason,
   lastIdentityChange=M.lastIdentityChange,reentrant=M.reentrant,snapshot=M.snapshot}
 end
 function M.on_disable(handler)
  if type(handler)=='function' then M.handlers[#M.handlers+1]=handler;return #M.handlers end
  return nil
 end
 return M
end)()
