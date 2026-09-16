-- Scarlet Manual Wardrobe Adapter v1
-- Derived from Little1113's Scarlet-Model-1.1.0 native adapter.
-- This manually migrated candidate never loads the original Scarlet Lua/DLL.
-- Native writes and route hooks require the exact OWOTS wardrobe bridge gate.
-- Source provenance: Scarlet-Model-1.1.0 / scarlet_native_adapter.lua
-- Source SHA-256: B280101CDEC954F73EACE41527379500E6367504644F775B72291FC2A160A272
-- Original author: Little1113
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
local scarlet_reset_required=false;local scarlet_reset_reason=nil
-- Existing v9 native driver plus one bounded native IK at the final handoff.
local Core=(function()
-- Native constraint orchestration with a separately measured seven-root TR bridge.
local M={}
local function need(v,s)if not v then error(s,0)end end
local function integer(v,lo,hi)return type(v)=='number'and v%1==0 and v>=lo and v<=hi end
local function copy(v)
 if type(v)~='table'then return v end;local out={};for k,x in pairs(v)do out[k]=copy(x)end;return out
end
function M.new(C,A)
 for _,k in ipairs({'frame','clock','frequency','resolve_all','current','bind','validate_step','update','invalidate'})do need(type(A[k])=='function','Missing native adapter '..k)end
 need(type(C.roles)=='table'and#C.roles>0 and#C.roles<=16,'Unbounded native stage list')
 local seen={};for _,r in ipairs(C.roles)do need(type(r)=='string'and not seen[r],'Duplicate stage');seen[r]=true end
 local frequency=A.frequency();need(integer(frequency,1,1000000000000),'Invalid native QPC frequency')
 local closed,busy=false,false;local last_callback=nil;local owners={};local samples={};local cursor=0;local sequence=0
 local status={schema='scarlet-native-adapter-status-v1',state='waiting',frames=0,total_native_calls=0,duplicates=0,faults=0,bindings=0,frequency=frequency,
               no_lua_pose_math=false,pose_math_backend='REFramework C++ GLM plus bounded three-joint Lua attachment reference',expected_joint_write_calls_per_owner=(C.assembly.removed==true and 15 or 17),
               expected_calls_per_owner=#C.roles,maximum_native_calls_per_owner=#C.roles+1,native_call_scope='constraint components plus reported conditional late_sheath_ik',entry=C.entry,candidate=true,last_error=nil}
 local function clock()local x=A.clock();need(integer(x,1,9007199254740991),'Invalid native QPC timestamp');return x end
 local function ticks(a,b)need(b>=a,'QPC moved backwards');return b-a end
 local function record(row)
  sequence=sequence+1;row.sequence=sequence;cursor=cursor%512+1;samples[cursor]=row;status.sample_sequence=sequence;status.ring_overwritten=math.max(0,sequence-512)
 end
 local self={}
 local function run(entry)
  if closed then return false,'closed'end
  if entry~=C.entry then return false,'wrong application entry'end
  if busy then status.duplicates=status.duplicates+1;return false,'reentrant'end
  local frame=A.frame();need(integer(frame,0,0xffffffff),'Invalid Application.FrameCount')
  if frame==last_callback then status.duplicates=status.duplicates+1;return false,'duplicate frame'end
  if last_callback and frame<last_callback then owners={};A.invalidate('frame counter restarted')end
  last_callback=frame;busy=true
  local total_start=clock();local empty_start=clock();local empty_end=clock();local binding_start=clock()
  local ok,contexts=pcall(A.resolve_all,frame);local binding_end=clock()
  if not ok then
   busy=false;status.state='binding unavailable';status.last_error=tostring(contexts);status.faults=status.faults+1
   local finish=clock();local total=ticks(total_start,finish)
   record({frame=frame,success=false,cold=true,phase='resolve',owners={},native_calls=0,native_ticks=0,pose_bridge_ticks=0,joint_write_calls=0,rollback_write_calls=0,lookup_ticks=ticks(binding_start,binding_end),binding_ticks=0,
           empty_ticks=ticks(empty_start,empty_end),total_ticks=total,non_native_ticks=total,core_start_tick=total_start,core_end_tick=finish});return false,contexts
  end
  need(type(contexts)=='table'and#contexts<=2,'Unbounded owned actor set')
  local unique={}
  for _,ctx in ipairs(contexts)do
   if type(ctx.key)~='string'or type(ctx.actor_id)~='string'or unique[ctx.actor_id]then
    busy=false;status.state='ambiguous owned actor';status.last_error='Duplicate or invalid Actor lease';status.faults=status.faults+1;return false,status.last_error
   end
   unique[ctx.actor_id]=true
  end
  local native_ticks=0;local bridge_ticks=0;local joint_writes=0;local rollback_writes=0
  local calls=0;local success=true;local per_owner={};local bind_ticks=0;local cold=false
  for _,ctx in ipairs(contexts)do
   local state=owners[ctx.actor_id]
   if not state or state.key~=ctx.key then state={key=ctx.key,bound=false,last_frame=nil,quarantined=false};owners[ctx.actor_id]=state end
   local row={actor=ctx.actor_id,body=ctx.body_id,key=ctx.key,generation=ctx.generation or ctx.key,kind=ctx.kind,native_calls=0,native_ticks=0,stage_ticks={},pose_bridge_ticks=0,bridge_stage_ticks={},joint_write_calls=0,rollback_write_calls=0,new_binding=false}
   if state.quarantined then row.success=false;row.error='binding quarantined';success=false
   elseif ctx.skip_native then row.success=true;row.skipped=true;row.skip_reason=ctx.skip_reason or'owned Body hidden'
   elseif state.last_frame==frame then row.success=false;row.error='duplicate owner';status.duplicates=status.duplicates+1;success=false
   else
    local before=clock()
    local function pose_hook(key,role)
     if not A[key]then return end
     local config=C.coherent_cloth
     local hip=C.hip_clearance and role==C.hip_clearance.role
     if not hip and config and((key=='before_stage'and role~=config.start_role)or(key=='after_stage'and role~=config.kin_role and role~=config.finish_role))then return end
     local a=clock();local good,result=pcall(A[key],ctx,role);local dt=ticks(a,clock())
     row.pose_bridge_ticks=row.pose_bridge_ticks+dt
     row.bridge_stage_ticks[key..':'..tostring(role)]=dt
     need(good,result);return result
    end
    local good,why=pcall(function()
     need(A.current(ctx)==true,'Owned actor/Body lease expired')
     if not state.bound then local a=clock();A.bind(ctx);bind_ticks=bind_ticks+ticks(a,clock());state.bound=true;status.bindings=status.bindings+1;row.new_binding=true;cold=true end
     -- Mark before the first native write; an exception cannot cause a retry
     -- of a partial native chain in this frame.
     state.last_frame=frame
     if A.before_primary_native then
      -- Only a supplementary native solve. Failure is reported but must not
      -- freeze the existing primary character drive on later frames.
      local ok_extra,extra=pcall(A.before_primary_native,ctx)
      if not ok_extra then extra={success=false,native_calls=0,native_ticks=0,reason='host_supplement_error',error=tostring(extra)}end
      need(type(extra)=='table'and integer(extra.native_calls,0,1)and integer(extra.native_ticks,0,9007199254740991),'Invalid supplementary native accounting')
      row.late_sheath=extra
      if extra.native_calls==1 then
       row.native_calls=row.native_calls+1;row.native_ticks=row.native_ticks+extra.native_ticks
       row.stage_ticks.late_sheath_ik=extra.native_ticks
      end
      if extra.success~=true then success=false;status.supplement_faults=(status.supplement_faults or 0)+1 end
     end
     for _,role in ipairs(C.roles)do
      need(A.current(ctx)==true,'Owned actor changed during native chain')
      need(A.validate_step(ctx,role)==true,'Native component identity/timing changed: '..role)
      pose_hook('before_stage',role)
      local a=clock();row.native_calls=row.native_calls+1;local called,error=pcall(A.update,ctx,role);local b=clock();local dt=ticks(a,b)
      row.stage_ticks[role]=dt;row.native_ticks=row.native_ticks+dt;need(called,error)
      pose_hook('after_stage',role)
     end
     need(A.current(ctx)==true,'Owned actor changed after native chain')
    end)
    if not good then
     if A.abort_pose then
      local a=clock();local recovered,result=pcall(A.abort_pose,ctx,why);local dt=ticks(a,clock())
      row.pose_bridge_ticks=row.pose_bridge_ticks+dt;row.bridge_stage_ticks.recovery=dt
      row.recovery=recovered and result or{success=false,error=tostring(result)}
     end
     state.quarantined=true;state.bound=false;row.error=tostring(why);status.last_error=row.error;status.faults=status.faults+1;success=false
    end
    local pose_quality_good=true
    if A.pose_stats then
     local measured,stats=pcall(A.pose_stats,ctx)
     if measured then row.joint_write_calls=stats.joint_write_calls;row.rollback_write_calls=stats.rollback_write_calls;row.pose_bridge_completed=stats.completed
      row.coherent_joint_write_calls=stats.coherent_joint_write_calls;row.hip_scalar_write_calls=stats.hip_scalar_write_calls;row.hip_scalar_recovery_calls=stats.hip_scalar_recovery_calls
      row.coherent_baseline_valid=stats.baseline_valid;row.coherent_native_only=stats.native_only;row.coherent_baseline_reason=stats.reason
      pose_quality_good=stats.completed==true and stats.baseline_valid~=false and stats.native_only~=true
      if not pose_quality_good then success=false;status.pose_incomplete_frames=(status.pose_incomplete_frames or 0)+1;status.last_pose_error=stats.reason or 'Incomplete pose bridge'end
     else good=false;success=false;state.quarantined=true;row.error=tostring(stats);status.last_error=row.error;status.faults=status.faults+1 end
    end
    local assembly_ok,assembly
    if C.assembly.removed==true then assembly_ok=true;assembly={frame=frame,key=ctx.key,actor=ctx.actor_id,reads=0,writes=0,rollback_writes=0,completed=true,removed=true}
    else assembly_ok,assembly=pcall(A.assembly_frame,frame,ctx.actor_id)end
    if not assembly_ok or type(assembly)~='table' then
     assembly={frame=frame,key=ctx.key,actor=ctx.actor_id,reads=0,writes=0,rollback_writes=0,completed=false,error=tostring(assembly or 'Assembly stage did not produce a record')}
    end
    local valid_assembly=assembly.frame==frame and assembly.key==ctx.key and assembly.actor==ctx.actor_id
      and integer(assembly.reads,0,3)and integer(assembly.writes,0,2)and integer(assembly.rollback_writes,0,2)
    row.assembly=assembly
    if valid_assembly then
     row.joint_write_calls=row.joint_write_calls+assembly.writes
     row.rollback_write_calls=row.rollback_write_calls+assembly.rollback_writes
    end
    local accessory_good=valid_assembly and assembly.completed==true and assembly.rollback_writes==0 and ((C.assembly.removed==true and assembly.removed==true and assembly.reads==0 and assembly.writes==0)or(C.assembly.removed~=true and assembly.reads==3 and assembly.writes==2))
    if not accessory_good then success=false;status.assembly_faults=(status.assembly_faults or 0)+1;status.last_assembly_error=assembly.error or 'Invalid accessory stage record'end
    row.native_chain_success=good;row.success=good and pose_quality_good and accessory_good and(not row.late_sheath or row.late_sheath.success==true);row.owner_total_ticks=ticks(before,clock())
   end
   calls=calls+row.native_calls;native_ticks=native_ticks+row.native_ticks
   bridge_ticks=bridge_ticks+row.pose_bridge_ticks;joint_writes=joint_writes+row.joint_write_calls;rollback_writes=rollback_writes+row.rollback_write_calls
   per_owner[#per_owner+1]=row
  end
  for actor in pairs(owners)do if not unique[actor]then owners[actor]=nil end end
  status.frames=status.frames+1;status.total_native_calls=status.total_native_calls+calls;status.owner_count=#contexts
  status.state=#contexts==0 and'waiting'or success and'complete'or(status.faults>0 and'quarantined'or'accessory_incomplete')
  local finish=clock();local total=ticks(total_start,finish);status.last_frame=frame
  record({frame=frame,success=success,cold=cold,owners=per_owner,native_calls=calls,native_ticks=native_ticks,lookup_ticks=ticks(binding_start,binding_end),binding_ticks=bind_ticks,
          pose_bridge_ticks=bridge_ticks,joint_write_calls=joint_writes,rollback_write_calls=rollback_writes,orchestration_ticks=total-native_ticks-bridge_ticks,
          total_ticks=total,non_native_ticks=total-native_ticks,empty_ticks=ticks(empty_start,empty_end),core_start_tick=total_start,core_end_tick=finish})
  busy=false;return success
 end
 function self:step(entry)
  local ok,a,b=pcall(run,entry)
  if not ok then
   busy=false;for _,owner in pairs(owners)do owner.quarantined=true end
   status.state='quarantined';status.last_error=tostring(a);status.faults=status.faults+1;return false,status.last_error
  end
  return a,b
 end
 function self:status()return copy(status)end
 function self:sequence()return sequence end
 function self:finish_callback(before_sequence,start_tick,end_tick)
  need(not busy and integer(before_sequence,0,9007199254740991)and integer(start_tick,1,9007199254740991)and integer(end_tick,start_tick,9007199254740991),'Invalid callback annotation')
  if sequence<=before_sequence then return false end
  local row=samples[cursor];row.callback_start_tick=start_tick;row.callback_end_tick=end_tick;row.callback_ticks=end_tick-start_tick
  status.callback_timing_scope='QPC span enclosing core.step including FrameCount, resolve and record construction; excludes outer timer call edges, this annotation and REFramework dispatch.'
  status.core_timing_scope='total_ticks starts after FrameCount and ends before recording the sample.'
  return true
 end
 function self:samples()
  local out={};for _,row in pairs(samples)do out[#out+1]=copy(row)end;table.sort(out,function(a,b)return a.sequence<b.sequence end);return out
 end
 function self:samples_since(after)
  need(integer(after,0,9007199254740991),'Invalid sample cursor');local first=math.max(1,sequence-511);local out={}
  for _,row in pairs(samples)do if row.sequence>after then out[#out+1]=copy(row)end end;table.sort(out,function(a,b)return a.sequence<b.sequence end)
  return{schema='scarlet-native-adapter-timing-v1',frequency=frequency,latest_sequence=sequence,first_available_sequence=first,lost=math.max(0,first-after-1),samples=out}
 end
 function self:retry()need(not busy,'Cannot retry inside a native chain');owners={};A.invalidate('explicit retry');status.state='waiting';status.last_error=nil end
 function self:close()need(not busy,'Cannot close inside a native chain');closed=true;owners={};A.invalidate('script reset');status.state='closed'end
 return self
end
return M

end)()
local Backend=(function()
-- Cached, owned SDK binding. The only mutators bind a native source GO or call Constraint.update.
local M={}
local function need(v,s)if not v then error(s,0)end end
local function integer(v,a,b)return type(v)=='number'and v%1==0 and v>=a and v<=b end
local function id(o)return o and tostring(o:get_address())or nil end
local function same(a,b)return a~=nil and b~=nil and id(a)==id(b)end
local function canonical(p)
 if type(p)~='string'then return nil end;p=p:gsub('\\','/'):lower():gsub('^@','');p=p:match('/natives/stm/(.+)$')or p:gsub('^natives/stm/','');return p:gsub('%.%d+$','')
end
local function body_resource_map(C)
 local entries=C.body_variants or{{name='hat',resource=C.body_path,sha256=C.body_mesh_sha256}}
 need(type(entries)=='table'and #entries>=1 and #entries<=2,'Body resource variant count differs')
 local map={}
 for _,v in ipairs(entries)do
  need(type(v.name)=='string'and(v.name=='hat'or v.name=='no_hat'),'Unknown native costume variant')
  need(type(v.resource)=='string'and canonical(v.resource)==v.resource and v.resource:match('^mods/scarlet_(hat_static|no_hat_static)/'),'Body resource path is not explicit canonical Scarlet data')
  need(type(v.sha256)=='string'and #v.sha256==64 and not v.sha256:find('[^0-9a-f]'),'Body resource digest is malformed')
  need(not map[v.resource],'Duplicate body resource variant');map[v.resource]=v
 end
 need(map[C.body_path]and map[C.body_path].sha256==C.body_mesh_sha256,'Primary body resource identity differs')
 return map
end
M.body_resource_map=body_resource_map
function M.new(C,sdk)
  for _,name in ipairs(C.actor_setting_types or{})do need(sdk.find_type_definition(name),'Actor contract type unavailable: '..name)end
 local body_resources=body_resource_map(C)
 local defs,methods={},{ };local base
 for name,crc in pairs(C.crcs)do local d=sdk.find_type_definition(name);need(d and d:get_crc_hash()==crc,'SDK type CRC mismatch: '..name);defs[name]=d end
 for _,s in ipairs(C.specs)do
  local chosen
  for _,f in ipairs(defs[s.type]:get_methods())do
   if f:get_name()==s.name and f:get_num_params()==#s.params and f:get_return_type():get_full_name()==s.returns and f:is_static()==s.is_static then
    local match=true;local ps=f:get_param_types();for i,t in ipairs(s.params)do if ps[i]:get_full_name()~=t then match=false end end
    if match then local p=sdk.to_int64(f:get_function());need(integer(p,1,9007199254740991),'Missing native function');base=base or(p-s.rva);need(p-s.rva==base,'Fixed RVA mismatch: '..s.key);need(not chosen,'Ambiguous method: '..s.key);chosen=f end
   end
  end
  need(chosen,'Missing fixed method: '..s.key);methods[s.key]=chosen
 end
 local owner=defs['app.cEntityBase']:get_field('_Owner');need(owner and owner:get_offset_from_base()==16 and owner:get_type():get_full_name()=='via.GameObject','Typed player owner field changed')
 local function call(key,o,...)return methods[key]:call(o,...)end
 local function managed(o,t)return o~=nil and sdk.is_managed_object(o)and o:get_type_definition():is_a(t)end
 local function go_valid(o)return managed(o,'via.GameObject')and call('go_valid',o)==true end
 local function component_valid(o)return managed(o,'via.Component')and call('component_valid',o)==true end
 local function list(a,maximum)
  need(a and sdk.is_managed_object(a)and a:get_type_definition():is_array(),'Typed native array missing');local n=call('array_length',a,0);need(integer(n,0,maximum),'Array bound exceeded');local r={}
  for i=0,n-1 do r[#r+1]=call('array_value',a,i)end;return r
 end
 local function components(go)return list(call('go_components',go),128)end
 local function resource(holder)return holder and canonical(call('resource_path',holder))or nil end
 local function read_ptr(address)
  need(integer(address,65536,9007199254740991)and address%8==0,'Invalid native array address')
  local v=sdk.to_valuetype(sdk.to_ptr(address),'System.UInt64');need(v~=nil,'Cannot inspect fixed native pointer slot');return v:get_field(C.uint64_field)
 end
 local function vector_matches(v,e)
  if v==nil then return false end
  for i,k in ipairs({'x','y','z','w'})do if e[i]~=nil and string.pack('<f',v[k])~=string.pack('<f',e[i])then return false end end;return true
 end
 local function copy_signature(c)
  -- 148b80210 passes component+58; 148b7ffca reads container+18
  -- count and +10 array, so these are component+70 and +68.
  local n=c:read_dword(0x70);local p=c:read_qword(0x68);need(integer(n,1,128),'Native copy row count outside bound');need(integer(p,65536,9007199254740991)and p%8==0,'Native copy row storage absent')
  return n,p
 end
 local function copy_matches(c,want)
  local count=c:read_dword(0x70);if count~=#want.rows then return false end
  local n,p=copy_signature(c)
  for i,row in ipairs(want.rows)do
   local ptr=read_ptr(p+8*(i-1));local value=sdk.to_managed_object(sdk.to_ptr(ptr));need(managed(value,'via.motion.ConstraintTargetJoint'),'Native copy row type mismatch')
   if call('row_source',value)~=row.JointName or call('row_target',value)~=row.MyJointName or not vector_matches(call('row_position',value),row.LocalPositionOffset)or not vector_matches(call('row_rotation',value),row.LocalRotationOffset)then return false end
  end
  return true,n,p
 end
 local function layer_matches(c,want)
  local n=call('jc_count',c);if n~=#want.layers then return false end
  for i,path in ipairs(want.layers)do local l=call('jc_layer',c,i-1);if not l or resource(call('jc_layer_asset',l))~=canonical(scarlet_gate.route(path)) then return false end end
  return true
 end
 local function validate_layers(c,want)
  if call('jc_count',c)~=#want.layers then return false end
  for i,path in ipairs(want.layers)do
   local l=call('jc_layer',c,i-1)
   if not l or call('jc_layer_enabled',l)~=true or call('jc_layer_pause',l)~=false or call('jc_layer_blend',l)~=1 or call('jc_layer_override',l)~=true or call('jc_layer_timing',l)~=3 then return false end
   if resource(call('jc_layer_asset',l))~=canonical(scarlet_gate.route(path)) then return false end
  end
  return true
 end
 local function identify_roles(go,profile,result)
  local objects=components(go)
  for role,want in pairs(profile)do
   local found,n,p
   for _,c in ipairs(objects)do
    if managed(c,want.type)and component_valid(c)then
     local match,cn,cp
     if want.kind=='copy'then match,cn,cp=copy_matches(c,want)else match=layer_matches(c,want)end
     if match then need(not found,'Ambiguous owned component role '..role);found=c;n=cn;p=cp end
    end
   end
   need(found,'Owned native component absent: '..role);need(same(call('component_go',found),go),'Native component owner mismatch')
   need(call('constraint_enabled',found)==true and call('constraint_mode',found)==0 and call('constraint_timing',found)==3,'Owned native component is not enabled ByBehavior3: '..role)
   if want.kind=='copy'then need(call('copy_scale',found)==false,'Unexpected native scale writer')else need(validate_layers(found,want),'Owned layer timing/resource changed')end
   result[role]={object=found,owner=go,definition=want,count=n,array=p}
  end
 end
 local function validate_skeleton(t,names,is_body)
  local joints=list(call('tr_joints',t),1024);need(#joints==#names,'Native skeleton count differs')
  for i,j in ipairs(joints)do need(managed(j,'via.Joint')and call('joint_valid',j)==true and call('joint_name',j)==names[i],'Native skeleton name/order differs')end
  if is_body then
   need(call('same_joints',t)==true,'Body same-joint constraints unavailable')
   for _,b in ipairs(C.carriers)do
    local j=joints[b.index+1];local parent=call('joint_parent',j);need(parent and call('joint_name',parent)==b.parent,'Carrier parent differs: '..b.name)
    local p=call('joint_base_p',j);local q=call('joint_base_q',j);local s=call('joint_base_s',j);local plus,minus=0,0
    for i,k in ipairs({'x','y','z'})do need(math.abs(p[k]-b.position[i])<=2e-6 and math.abs(s[k]-1)<=2e-6,'Carrier bind translation/scale differs')end
    for i,k in ipairs({'x','y','z','w'})do plus=math.max(plus,math.abs(q[k]-b.rotation[i]));minus=math.max(minus,math.abs(q[k]+b.rotation[i]))end
    need(math.min(plus,minus)<=2e-6,'Carrier bind quaternion differs: '..b.name)
   end
  end
 end
 local cache={};local bound_sources={};local generation=0;local current={};local last_resolve_frame;local missing_probe={}

 local lease_stats={restored=0,foreign_preserved=0,expired=0,restore_failures=0}
 local function equivalent(a,b)return(a==nil and b==nil)or same(a,b)end
 local function release_source(address)
  local record=bound_sources[address];if not record then return end
  if not component_valid(record.object)or not go_valid(record.owner)or not same(call('component_go',record.object),record.owner)then
   bound_sources[address]=nil;lease_stats.expired=lease_stats.expired+1;return
  end
  local matches,n,p=copy_matches(record.object,record.definition)
  if not matches or n~=record.count or p~=record.array then
   bound_sources[address]=nil;lease_stats.foreign_preserved=lease_stats.foreign_preserved+1;return
  end
  local current_source=call('copy_source_go',record.object)
  local original=record.original;if original and not go_valid(original)then original=nil end
  if record.written and same(current_source,record.expected)and not equivalent(current_source,original)then
   need(not record.restore_attempted,'An earlier source restore is unresolved')
   record.restore_attempted=true
   local ok,why=pcall(function()
    call('copy_set_source_go',record.object,original)
    need(equivalent(call('copy_source_go',record.object),original),'Native source restoration readback differs')
   end)
   if not ok then lease_stats.restore_failures=lease_stats.restore_failures+1;error(why,0)end
   lease_stats.restored=lease_stats.restored+1
  elseif record.written and not equivalent(current_source,original)then
   lease_stats.foreign_preserved=lease_stats.foreign_preserved+1
  end
  bound_sources[address]=nil
 end
 local function release_all_sources()
  local addresses={};for address in pairs(bound_sources)do addresses[#addresses+1]=address end
  for _,address in ipairs(addresses)do release_source(address)end
 end

 local function visible(body,mesh)return call('go_draw',body)==true and call('go_draw_self',body)==true and call('mesh_enabled',mesh)==true and call('mesh_part',mesh,0)==true end
 local function body_of(actor)
  local root=call('go_transform',actor);need(component_valid(root),'Actor Transform unavailable');local pending={{t=root,depth=0}};local seen={};local nodes=0;local candidates={};local shown={}
  while #pending>0 do
   local item=table.remove(pending);local t=item.t;nodes=nodes+1;need(nodes<=512 and item.depth<=32,'Actor subtree bound exceeded');need(component_valid(t)and not seen[id(t)],'Invalid or cyclic actor subtree');seen[id(t)]=true
   if item.parent then need(same(call('tr_parent',t),item.parent),'Body ancestry changed')end
   local go=call('component_go',t);need(go_valid(go),'Subtree GO invalid')
   for _,c in ipairs(components(go))do
    if managed(c,'via.render.Mesh')and component_valid(c)and call('mesh_ready',c)==true and body_resources[resource(call('mesh_holder',c))]~=nil then
     local path=resource(call('mesh_holder',c));local variant=body_resources[path]
     local value={body=go,transform=t,mesh=c,root=root,body_path=path,body_mesh_sha256=variant.sha256,costume_variant=variant.name};candidates[#candidates+1]=value;if visible(go,c)then shown[#shown+1]=value end
    end
   end
   local child=call('tr_child',t);local siblings={}
   while child do need(not siblings[id(child)],'Sibling cycle');siblings[id(child)]=true;pending[#pending+1]={t=child,parent=t,depth=item.depth+1};need(#pending+nodes<=512,'Actor subtree queue bound exceeded');child=call('tr_next',child)end
  end
  need(#shown<=1,'Multiple visible current Scarlet Body meshes');if#shown==1 then return shown[1]end;if#candidates==1 then return candidates[1]end;return nil
 end
 local function ancestry(ctx)
  local t=ctx.body_transform;local seen={}
  for _=1,32 do if same(t,ctx.actor_transform)then return true end;if not component_valid(t)or seen[id(t)]then return false end;seen[id(t)]=true;t=call('tr_parent',t);if not t then return false end end;return false
 end
 local function current_context(ctx)
  local a=current[ctx.kind]
  return a and same(a,ctx.actor)and go_valid(ctx.actor)and go_valid(ctx.body)and component_valid(ctx.mesh)and call('mesh_ready',ctx.mesh)==true and resource(call('mesh_holder',ctx.mesh))==ctx.body_path and body_resources[ctx.body_path]~=nil and body_resources[ctx.body_path].sha256==ctx.body_mesh_sha256 and ancestry(ctx)
 end
 local function make_context(kind,actor,b)
  b=b or body_of(actor);if not b then return nil end
  validate_skeleton(b.root,C.actor_names,false);validate_skeleton(b.transform,C.body_names,true)
  local roles={};identify_roles(actor,C.profiles[kind],roles);identify_roles(b.body,C.profiles.body,roles)
  local child,chain
  for _,c in ipairs(components(b.body))do
   if managed(c,'via.motion.ChildSecondary')then need(not child,'Ambiguous ChildSecondary');child=c end
   if managed(c,'via.motion.Chain2')then need(not chain,'Ambiguous Chain2');chain=c end
  end
  need(child,'Owned Body ChildSecondary component absent')
  need(chain,'Owned Body Chain2 component absent')
  local merged_mode=call('child_merged',child)
  need(type(merged_mode)=='boolean','ChildSecondary mode has invalid type')
  -- MergedSkeleton is a configurable mode, not an animation-ready predicate.
  -- The actual skeleton names, helper parents/binds and same-joint constraint
  -- were verified above; retain the engine's mode without changing it.
  need(call('chain_timing',chain)==4,'Owned Body Chain2 is not configured for Last')
  generation=generation+1;local key=id(actor)..':'..id(b.body)..':'..id(b.mesh)..':'..generation
  return{body_path=b.body_path,body_mesh_sha256=b.body_mesh_sha256,costume_variant=b.costume_variant,key=key,generation=generation,kind=kind,actor_id=id(actor),body_id=id(b.body),actor=actor,body=b.body,mesh=b.mesh,actor_transform=b.root,body_transform=b.transform,roles=roles,chain=chain,child=child,child_merged_mode=merged_mode,was_visible=visible(b.body,b.mesh),next_hidden_probe=(last_resolve_frame or 0)+30}
 end
 local self={}
 function self.frame()return call('frame',nil)end
 function self.clock()return call('clock',nil)end
 function self.frequency()return call('frequency',nil)end
  function self.resolve_all(frame,read_only)
  last_resolve_frame=frame;current={};local manager=call('pm_instance',nil);if not managed(manager,'app.PlayerManager')then if not read_only then release_all_sources()end;cache={};missing_probe={};return{}end
  local info=call('pm_info',manager)
  if managed(info,'app.cPlayerManageInfo')and call('info_valid',info)==true then
   local actor=call('info_go',info);local entity=call('info_entity',info)
   if go_valid(actor)and call('pm_current',manager,actor)==true and managed(entity,'app.cEntityBase')and same(owner:get_data(entity),actor)then current.player=actor end
  end
  if call('pm_ui_ready',manager)==true then local ui=call('pm_ui',manager);if go_valid(ui)and call('go_name',ui)==C.preview_name then current.preview=ui end end
  local out={}
  for _,kind in ipairs({'player','preview'})do
   local actor=current[kind]
   if actor then
    local ctx=cache[kind]
    if ctx and not current_context(ctx)then cache[kind]=nil;ctx=nil;missing_probe[kind]=nil end
    if not ctx then
     local missing=missing_probe[kind]
     if not missing or missing.actor~=id(actor)or frame>=missing.next_frame then
      -- Retain a bounded retry deadline even when schema/parts construction
      -- is incomplete. A thrown cold probe must not scan the subtree every frame.
      missing_probe[kind]={actor=id(actor),next_frame=frame+30}
      ctx=make_context(kind,actor);cache[kind]=ctx;if ctx then missing_probe[kind]=nil end
     end
    end
    if ctx then
     local shown=visible(ctx.body,ctx.mesh)
     if not shown and(ctx.was_visible or frame>=ctx.next_hidden_probe)then
      local candidate=body_of(actor);ctx.next_hidden_probe=frame+30
      if candidate and not same(candidate.body,ctx.body)then ctx=make_context(kind,actor,candidate);cache[kind]=ctx;shown=visible(ctx.body,ctx.mesh)end
     end
     ctx.was_visible=shown;ctx.skip_native=not shown;ctx.skip_reason=not shown and'owned Body hidden'or nil;out[#out+1]=ctx
    end
   else cache[kind]=nil end
  end
  local used={};for _,ctx in pairs(cache)do for _,r in pairs(ctx.roles)do used[id(r.object)]=true end end
  if not read_only then local retired={};for address in pairs(bound_sources)do if not used[address]then retired[#retired+1]=address end end;for _,address in ipairs(retired)do release_source(address)end end
  return out
 end
 function self.current(ctx)return current_context(ctx)and call('frame',nil)==last_resolve_frame end
 -- Native updateJoint precedes this adapter's frame callback. These readonly
 -- accessors retain the validated actor lease without requiring this frame's
 -- resolve_all; the late module also checks the fresh PlayerManager owner.
 function self.peek_owned_player()return cache.player end
 function self.current_owner_context(ctx)return ctx and cache.player==ctx and current_context(ctx)end
 function self.bind(ctx)
  need(current_context(ctx),'Actor changed before source binding')
  for _,role in ipairs(C.roles)do local r=ctx.roles[role];need(r,'Missing stage '..role)
   if r.definition.kind=='copy'then
    local target=r.definition.source_owner=='owned_body_runtime_binding'and ctx.body or r.owner;local old=call('copy_source_go',r.object)
    local address=id(r.object);local record=bound_sources[address]
    if record then need(same(record.object,r.object)and same(record.owner,r.owner),'Native binding owner changed')end
    if not same(old,target)then
     need(old==nil or(record and record.written and same(old,record.expected)),'Owned native source changed externally')
     if not record then record={object=r.object,owner=r.owner,original=old,written=false,definition=r.definition,count=r.count,array=r.array};bound_sources[address]=record end
     record.expected=target;record.written=true;record.restore_attempted=nil
     call('copy_set_source_go',r.object,target);need(same(call('copy_source_go',r.object),target),'Native source binding readback differs')
     need(r.object:read_byte(0xa1)==1,'Native source rebind did not invalidate cached joints')
    end
    r.source=target
   end
  end
 end
 function self.validate_step(ctx,role)
  local r=ctx.roles[role];if not r or not component_valid(r.object)or not same(call('component_go',r.object),r.owner)then return false end
  if call('constraint_enabled',r.object)~=true or call('constraint_mode',r.object)~=0 or call('constraint_timing',r.object)~=3 then return false end
  if r.definition.kind=='copy'then local n,p=copy_signature(r.object);return n==r.count and p==r.array and call('copy_scale',r.object)==false and same(call('copy_source_go',r.object),r.source)end
  return validate_layers(r.object,r.definition)
 end
 function self.update(ctx,role)call('native_update',ctx.roles[role].object)end
 function self.invalidate(reason)release_all_sources();cache={};current={};missing_probe={};last_resolve_frame=nil end
 function self.source_lease_status()local n=0;for _ in pairs(bound_sources)do n=n+1 end;return{active=n,restored=lease_stats.restored,foreign_preserved=lease_stats.foreign_preserved,expired=lease_stats.expired,restore_failures=lease_stats.restore_failures}end
 return self
end
return M

end)()
local Math=(function()
-- Pure stage coordinator. No SDK, callbacks, bone setters, or hidden globals.
-- All quaternion/vector operations are supplied C++ operations through backend.
local M = {}
local ROOTS = {
    {name="Ab_SkirtL_S01", group="L", domain="Actor"},
    {name="Ab-Fr-SuiteA-01", group="Front", domain="Actor"},
    {name="Ab-R-SkirtA-01", group="R", domain="Actor"},
    {name="Ab-L-SkirtA-01", group="L", domain="Actor"},
    {name="Ab-R-SkirtQ-01", group="R", domain="Body"},
    {name="Ab-R-SkirtQ-02", group="R", domain="Body"},
    {name="Ab-L-SkirtA-02", group="L", domain="Body"},
}
local L, R, F = "Ab-L-SkirtA-01", "Ab-R-SkirtA-01", "Ab-Fr-SuiteA-01"
local BONE7 = {ROOTS[1].name, F, R, L, ROOTS[5].name, ROOTS[6].name, ROOTS[7].name}
local BONE3, BONE2 = {L, R, F}, {L, R}
local REQUIRED = {"q_clone", "v_clone", "q_identity", "q_normalized", "q_inverse",
    "q_mul", "q_slerp", "q_rotate", "v_add", "v_sub", "v_scale", "validate_pose"}

function M.new(backend, fraction)
    assert(fraction == 0 or fraction == 0.05, "fraction must be exactly 0 or 0.05")
    for _, k in ipairs(REQUIRED) do assert(type(backend[k]) == "function", "missing backend " .. k) end
    local active, busy, last_frame = nil, false, -1
    local self = {}
    local function guarded(fn)
        assert(not busy, "coherent cloth reentry")
        busy = true
        local ok, result = pcall(fn)
        busy = false
        if not ok then active = nil; error(result, 0) end
        return result
    end
    local function copy_pose(p)
        assert(p and backend.validate_pose(p), "invalid finite nonzero P/Q pose")
        return {p=backend.v_clone(p.p), q=backend.q_clone(p.q)}
    end
    local function copy_set(poses, names)
        assert(type(poses) == "table", "pose map required")
        local result = {}
        for _, name in ipairs(names) do result[name] = copy_pose(poses[name]) end
        return result
    end
    local function require_stage(frame, key, stage)
        assert(active and active.frame == frame and active.key == key, "frame/owner mismatch or absent start")
        assert(active.stage == stage, "coherent cloth phase order")
    end
    function self:start(frame, key, before7)
        return guarded(function()
            assert(not active, "unfinished coherent cloth stage")
            assert(type(frame) == "number" and frame >= 0 and frame % 1 == 0 and frame > last_frame, "frame must advance")
            assert(type(key) == "string" and #key > 0, "nonempty owner epoch key required")
            last_frame = frame
            active = {frame=frame, key=key, before=copy_set(before7, BONE7), stage="before"}
            return true
        end)
    end
    function self:set_kin(frame, key, kin3)
        return guarded(function()
            require_stage(frame, key, "before")
            active.kin = copy_set(kin3, BONE3)
            active.stage = "kin"
            return true
        end)
    end
    function self:finish(frame, key, desired2)
        return guarded(function()
            require_stage(frame, key, "kin")
            local desired = copy_set(desired2, BONE2)
            local deltas = {}
            if fraction ~= 0 then
                local function side(name)
                    local old, goal = active.kin[name], desired[name]
                    local total = backend.q_normalized(backend.q_mul(
                        backend.q_normalized(goal.q), backend.q_inverse(backend.q_normalized(old.q))))
                    local q = backend.q_normalized(backend.q_slerp(backend.q_identity(), total, fraction))
                    local shift = backend.v_scale(backend.v_sub(goal.p, old.p), fraction)
                    return {q=q, pivot=old.p, shift=shift}
                end
                deltas.L, deltas.R = side(L), side(R)
                local q = backend.q_normalized(backend.q_slerp(deltas.L.q, deltas.R.q, 0.5))
                local pivot = active.kin[F].p
                local function displacement(d, point)
                    local relative = backend.v_sub(point, d.pivot)
                    return backend.v_add(backend.v_sub(backend.q_rotate(d.q, relative), relative), d.shift)
                end
                local shift = backend.v_scale(backend.v_add(displacement(deltas.L, pivot), displacement(deltas.R, pivot)), 0.5)
                deltas.Front = {q=q, pivot=pivot, shift=shift}
            end
            local batch = {}
            for _, spec in ipairs(ROOTS) do
                local old, result = active.before[spec.name], nil
                if fraction == 0 then
                    result = copy_pose(old)
                else
                    local d = deltas[spec.group]
                    local relative = backend.v_sub(old.p, d.pivot)
                    local change = backend.v_add(backend.v_sub(backend.q_rotate(d.q, relative), relative), d.shift)
                    result = {
                        p=backend.v_add(old.p, change),
                        q=backend.q_normalized(backend.q_mul(d.q, backend.q_normalized(old.q))),
                    }
                    assert(backend.validate_pose(result), "invalid computed pose")
                end
                batch[#batch+1] = {name=spec.name, domain=spec.domain, group=spec.group,
                    p=result.p, q=result.q, frame=frame, key=key}
            end
            active = nil
            return batch
        end)
    end
    -- Caller owns recovery of actual bones after reset/partial setter failure.
    -- Abort discards stage data; it deliberately cannot emit stale-frame writes.
    function self:abort()
        return guarded(function() active = nil; return true end)
    end
    return self
end
return M

end)()
local MathBackend=(function()
-- Dependency injection only. Quaternion is the caller's REFramework C++ type.
-- Constructor positional order, when needed externally, is (w,x,y,z).
return function(Quaternion)
    local function finite(x) return type(x) == "number" and x == x and x > -math.huge and x < math.huge end
    return {
        q_clone=function(q) return q:clone() end,
        v_clone=function(v) return v:clone() end,
        q_identity=function() return Quaternion.identity() end,
        q_normalized=function(q) return q:normalized() end,
        q_inverse=function(q) return q:inverse() end,
        q_mul=function(a,b) return a*b end,
        q_slerp=function(a,b,t) return a:slerp(b,t) end,
        q_rotate=function(q,v) return q*v end,
        v_add=function(a,b) return a+b end,
        v_sub=function(a,b) return a-b end,
        v_scale=function(v,s) return v*s end,
        validate_pose=function(pose)
            local p,q=pose.p,pose.q
            return p ~= nil and q ~= nil and finite(p.x) and finite(p.y) and finite(p.z)
                and finite(q.w) and finite(q.x) and finite(q.y) and finite(q.z)
                and q:length() > 1e-8 and q:length() < 1e8
        end,
    }
end

end)()
local Bridge=(function()
-- Cached seven-root TR bridge. Joint writes use the actual Actor/Body domain.
local M={}
local function need(value,message)if not value then error(message,0)end end
local function id(object)return object and tostring(object:get_address())or nil end
local function same(a,b)return a~=nil and b~=nil and id(a)==id(b)end
local function finite(x)return type(x)=='number'and x==x and math.abs(x)<math.huge end
local function clone_pose(pose)return {p=pose.p:clone(),q=pose.q:clone()}end
local function plain_pose(pose)
 local out={p={pose.p.x,pose.p.y,pose.p.z},q={pose.q.x,pose.q.y,pose.q.z,pose.q.w}}
 if pose.local_s then out.local_s={pose.local_s.x,pose.local_s.y,pose.local_s.z}end
 return out
end
function M.decorate(C,sdk,A,Math,math_backend)
 local config=C.coherent_cloth;need(config and config.fraction==.05,'Unapproved cloth response')
 need(config.baseline and config.baseline.mode=='owned-local-and-native-reset-v1','Explicit cloth baseline contract required')
 local methods,defs={},{};local base
 for _,spec in ipairs(C.coherent_specs)do
  local definition=defs[spec.type]
  if not definition then definition=sdk.find_type_definition(spec.type);need(definition and definition:get_crc_hash()==C.crcs[spec.type],'Coherent SDK type changed');defs[spec.type]=definition end
  local method=definition:get_method(spec.name..'('..table.concat(spec.params,', ')..')')
  need(method and method:get_num_params()==#spec.params and method:get_return_type():get_full_name()==spec.returns and method:is_static()==spec.is_static,'Coherent SDK signature changed: '..spec.key)
  local params=method:get_param_types();for i,name in ipairs(spec.params)do need(params[i]:get_full_name()==name,'Coherent parameter changed')end
  local address=sdk.to_int64(method:get_function());need(finite(address)and address>0,'Coherent native address absent');base=base or(address-spec.rva);need(base==address-spec.rva,'Coherent native RVA changed')
  methods[spec.key]=method
 end
 local function call(key,object,...)return methods[key]:call(object,...)end
 local function valid_joint(joint)
  return joint and sdk.is_managed_object(joint)and joint:get_type_definition():is_a('via.Joint')and call('joint_valid',joint)==true
 end
 local function validate(ctx,entry)
  need(A.current(ctx)==true and valid_joint(entry.joint),'Coherent root lease expired')
  need(call('joint_name',entry.joint)==entry.name and same(call('joint_owner',entry.joint),entry.owner),'Coherent root write domain changed')
 end
 local function read_pose(ctx,entry)
  validate(ctx,entry)
  local p=call('joint_world_p',entry.joint);local q=call('joint_world_q',entry.joint)
  for _,key in ipairs({'x','y','z'})do need(finite(p[key])and finite(q[key]),'Nonfinite cloth input')end
  need(finite(q.w)and q:length()>.5 and q:length()<1.5,'Invalid cloth input quaternion')
  return{p=p:clone(),q=q:clone()}
 end
 local function collect(ctx,names,include_scale)
  local result={};for _,name in ipairs(names)do
   local entry=ctx.coherent_roots[name];local pose=read_pose(ctx,entry)
   if include_scale then pose.local_s=call('joint_local_scale',entry.joint):clone()end
   result[name]=pose
  end;return result
 end

 -- Actor4 have no own Chain2 node. Retain their external local inputs while
 -- identifying unchanged values left by our previous successful write.
 local function local_pose(ctx,entry)
  validate(ctx,entry)
  local p=call('joint_local_p',entry.joint);local q=call('joint_local_q',entry.joint)
  for _,k in ipairs({'x','y','z'})do need(finite(p[k])and finite(q[k]),'Nonfinite cloth local baseline')end
  need(finite(q.w),'Nonfinite cloth local baseline W');return{p=p:clone(),q=q:clone()}
 end
 local function exact_local(a,b)
  if not a or not b then return false end
  for _,k in ipairs({'x','y','z'})do if a.p[k]~=b.p[k]then return false end end
  local plus,minus=true,true
  for _,k in ipairs({'x','y','z','w'})do plus=plus and a.q[k]==b.q[k];minus=minus and a.q[k]==-b.q[k]end
  return plus or minus
 end
 local function parent_pose(ctx,entry)
  validate(ctx,entry);local p=call('joint_parent',entry.joint)
  need(same(p,entry.parent.joint),'Cloth baseline parent changed')
  return read_pose(ctx,entry.parent)
 end
 local function from_local(ctx,entry,pose)
  local parent=parent_pose(ctx,entry);local m=call('joint_world_matrix',entry.parent.joint)
  local out={p=pose.p:clone(),q=math_backend.q_normalized(math_backend.q_mul(parent.q,pose.q))}
  for _,k in ipairs({'x','y','z'})do out.p[k]=m[0][k]*pose.p.x+m[1][k]*pose.p.y+m[2][k]*pose.p.z+m[3][k];need(finite(out.p[k]),'Nonfinite parent-carried cloth baseline')end
  return out
 end
 local function transport(pose,from,to)
  local d=math_backend.q_normalized(math_backend.q_mul(to.q,math_backend.q_inverse(from.q)))
  return{p=math_backend.v_add(to.p,math_backend.q_rotate(d,math_backend.v_sub(pose.p,from.p))),q=math_backend.q_normalized(math_backend.q_mul(d,pose.q))}
 end
 local function prepare_baseline(ctx,raw)
  local before={};local pending={};local held={};local cache=ctx.coherent_baseline_cache or{}
  for _,spec in ipairs(config.write_order)do
   local name=spec.name;local entry=ctx.coherent_roots[name];before[name]=clone_pose(raw[name])
   if spec.domain=='Actor'then
    local incoming=local_pose(ctx,entry);local old=cache[name]
    if old and exact_local(incoming,old.written)then pending[name]=clone_pose(old.baseline);before[name]=from_local(ctx,entry,pending[name]);held[name]=true
    else pending[name]=clone_pose(incoming);held[name]=false end
   end
  end
  ctx.coherent_baseline_pending={local_baselines=pending,held=held,raw_local={}}
  for name in pairs(pending)do ctx.coherent_baseline_pending.raw_local[name]=local_pose(ctx,ctx.coherent_roots[name])end
  return before
 end
 local function complete_baseline(ctx,saved)
  local kin=collect(ctx,config.kin_roots);local state=ctx.coherent_baseline_pending
  for _,name in ipairs(config.kin_roots)do
   if state.held[name]and exact_local(local_pose(ctx,ctx.coherent_roots[name]),state.raw_local[name])then kin[name]=from_local(ctx,ctx.coherent_roots[name],state.local_baselines[name])end
  end
  local before=ctx.coherent_baseline_before;local reset_evidence={}
  for _,spec in ipairs(config.write_order)do if spec.domain=='Body'then
   local name=spec.name;local entry=ctx.coherent_roots[name];local raw=read_pose(ctx,entry);local lp=local_pose(ctx,entry);local wanted=config.baseline.reset_body_local[name]
   need(wanted,'Body baseline expectation absent');local p_error=0;local plus,minus=0,0
   for i,k in ipairs({'x','y','z'})do p_error=math.max(p_error,math.abs(lp.p[k]-wanted.p[i]))end
   for i,k in ipairs({'x','y','z','w'})do plus=math.max(plus,math.abs(lp.q[k]-wanted.q[i]));minus=math.max(minus,math.abs(lp.q[k]+wanted.q[i]))end
   local q_error=math.min(plus,minus);reset_evidence[name]={position_error=p_error,rotation_error=q_error}
   if p_error>config.baseline.reset_tolerance or q_error>config.baseline.reset_tolerance then
    saved.baseline_valid=false;saved.baseline_error='Native cloth reset did not provide the contracted local baseline: '..name;saved.baseline_reset=reset_evidence
    ctx.coherent_stats.baseline_valid=false;ctx.coherent_stats.native_only=true;ctx.coherent_stats.reason=saved.baseline_error
    ctx.coherent_baseline_cache={};return false
   end
   local parent_name=entry.parent.name
   if before[parent_name]then raw=transport(raw,parent_pose(ctx,entry),before[parent_name])end
   before[name]=raw
  end end
  saved.baseline_valid=true;saved.baseline_reset=reset_evidence;saved.baseline_held_actor=state.held
  ctx.coherent_stats.baseline_valid=true;ctx.coherent_stats.native_only=false
  saved.before={};for name,pose in pairs(before)do saved.before[name]=plain_pose(pose)end
  ctx.coherent_bridge:start(saved.frame,ctx.key,before);ctx.coherent_bridge:set_kin(saved.frame,ctx.key,kin)
  saved.kin={};for name,pose in pairs(kin)do saved.kin[name]=plain_pose(pose)end
  return true
 end
 local function commit_baseline(ctx)
  local pending=ctx.coherent_baseline_pending;local cache={}
  for name,pose in pairs(pending.local_baselines)do cache[name]={baseline=clone_pose(pose),written=local_pose(ctx,ctx.coherent_roots[name])}end
  ctx.coherent_baseline_cache=cache;ctx.coherent_baseline_pending=nil;ctx.coherent_baseline_before=nil
 end
 local original_bind=A.bind
 local original_invalidate=A.invalidate
 local original_resolve=A.resolve_all
 local latest={}
 function A.bind(ctx)
  original_bind(ctx)
  local roots={};local wanted={};for _,entry in ipairs(config.write_order)do wanted[entry.name]=entry end
  for _,domain in ipairs({'Actor','Body'})do
   local transform=domain=='Actor'and ctx.actor_transform or ctx.body_transform
   local array=call('transform_joints',transform)
   need(array and sdk.is_managed_object(array)and array:get_type_definition():is_array(),'Coherent native joint array unavailable')
   local count=call('array_length',array,0);need(count==(domain=='Actor'and#C.actor_names or#C.body_names),'Coherent skeleton count changed')
   for index=0,count-1 do
    local joint=call('array_value',array,index);need(valid_joint(joint),'Invalid native joint while binding cloth roots')
    local name=call('joint_name',joint);local selected=wanted[name]
    if selected and selected.domain==domain then
     need(not roots[name]and same(call('joint_owner',joint),transform),'Ambiguous cloth root/domain')
     local parent=call('joint_parent',joint);need(valid_joint(parent),'Cloth baseline parent absent')
     local parent_name=call('joint_name',parent);local parent_owner=call('joint_owner',parent)
     need(parent_name==config.baseline.parents[name]and(same(parent_owner,ctx.actor_transform)or same(parent_owner,ctx.body_transform)),'Cloth baseline parent domain changed')
     roots[name]={name=name,domain=domain,joint=joint,owner=transform,parent={name=parent_name,joint=parent,owner=parent_owner}}
    end
   end
  end
  for _,entry in ipairs(config.write_order)do need(roots[entry.name],'Missing actual cloth root '..entry.name)end
  ctx.coherent_baseline_cache={}
  ctx.coherent_roots=roots
  ctx.coherent_bridge=Math.new(math_backend,config.fraction)
  ctx.coherent_input=nil
 end
 function A.resolve_all(frame,read_only)
  local contexts=original_resolve(frame,read_only);local found={}
  for _,ctx in ipairs(contexts)do found[ctx.actor_id]=true end
  for actor in pairs(latest)do if not found[actor]then latest[actor]=nil end end
  return contexts
 end
 function A.before_stage(ctx,role)
  if role~=config.start_role then return end
  local frame=A.frame();need(ctx.coherent_bridge and ctx.coherent_roots,'Cloth bridge was not bound')
  local before=collect(ctx,config.all_roots,true)
  ctx.coherent_raw_before=before
  ctx.coherent_baseline_before=prepare_baseline(ctx,before)
  ctx.coherent_stats={frame=frame,joint_write_calls=0,rollback_write_calls=0,completed=false}
  local plain={};for name,pose in pairs(before)do plain[name]=plain_pose(pose)end
  ctx.coherent_input={schema='scarlet-coherent-cloth-frame-v1',frame=frame,actor=ctx.actor_id,body=ctx.body_id,
   generation=ctx.generation,key=ctx.key,fraction=config.fraction,observed_before=plain,before=plain,baseline_mode=config.baseline.mode,math_sha256=config.math_sha256,completed=false}
 end
 function A.after_stage(ctx,role)
  if role==config.kin_role then
   local saved=ctx.coherent_input;need(saved and saved.frame==A.frame()and saved.key==ctx.key,'Cloth kin phase lacks current before')
   complete_baseline(ctx,saved)
  elseif role==config.finish_role then
   local saved=ctx.coherent_input;need(saved and saved.frame==A.frame()and saved.key==ctx.key,'Cloth finish lacks current frame')
   if saved.baseline_valid==false then
    -- The native stage has already produced its source-rule pose. Do not
    -- overwrite it with an unverified or prior-frame Lua baseline, and do
    -- not throw this accessory failure into primary character drive.
    saved.completed=false;saved.native_only=true;saved.joint_write_calls=0;latest[ctx.actor_id]=saved
    commit_baseline(ctx)
    ctx.coherent_input=nil;ctx.coherent_raw_before=nil;ctx.coherent_baseline_pending=nil;ctx.coherent_baseline_before=nil;return
   end
   need(saved.kin,'Cloth finish lacks current kin')
   local desired=collect(ctx,config.desired_roots)
   local goals=ctx.coherent_bridge:finish(saved.frame,ctx.key,desired)
   need(type(goals)=='table'and#goals==7,'Coherent output count changed')
   saved.desired={};for name,pose in pairs(desired)do saved.desired[name]=plain_pose(pose)end
   saved.expected={};saved.joint_write_calls=0
   -- The pure module has completed and checked every goal before any setter.
   for index,goal in ipairs(goals)do
    local definition=config.write_order[index];need(goal.name==definition.name and goal.domain==definition.domain,'Coherent parent-first write order changed')
    local entry=ctx.coherent_roots[goal.name];validate(ctx,entry)
    for _,key in ipairs({'x','y','z'})do need(finite(goal.p[key])and finite(goal.q[key]),'Nonfinite cloth target')end
    need(finite(goal.q.w)and goal.q:length()>.99 and goal.q:length()<1.01,'Invalid cloth target quaternion')
   end
   for _,goal in ipairs(goals)do
    local entry=ctx.coherent_roots[goal.name];validate(ctx,entry)
    ctx.coherent_stats.joint_write_calls=ctx.coherent_stats.joint_write_calls+1
    call('joint_set_world_q',entry.joint,goal.q);saved.joint_write_calls=saved.joint_write_calls+1
    ctx.coherent_stats.joint_write_calls=ctx.coherent_stats.joint_write_calls+1
    call('joint_set_world_p',entry.joint,goal.p);saved.joint_write_calls=saved.joint_write_calls+1
    saved.expected[goal.name]=plain_pose(goal)
   end
   need(A.current(ctx)==true and saved.frame==A.frame(),'Cloth owner/frame changed after writes')
   saved.local_scale_after={}
   for _,name in ipairs(config.all_roots)do
    local s=call('joint_local_scale',ctx.coherent_roots[name].joint)
    local old=ctx.coherent_raw_before[name].local_s
    need(finite(s.x)and finite(s.y)and finite(s.z)and s.x==old.x and s.y==old.y and s.z==old.z,'Cloth world setter changed local scale')
    saved.local_scale_after[name]={s.x,s.y,s.z}
   end
   commit_baseline(ctx)
   saved.completed=true;ctx.coherent_stats.completed=true;latest[ctx.actor_id]=saved
   ctx.coherent_input=nil;ctx.coherent_raw_before=nil
  end
 end
 function A.abort_pose(ctx,reason)
  ctx.coherent_baseline_cache={};ctx.coherent_baseline_pending=nil;ctx.coherent_baseline_before=nil
  local saved=ctx.coherent_input
  if ctx.coherent_bridge then ctx.coherent_bridge:abort()end
  if not saved then return{attempted=false,reason='no active cloth snapshot'}end
  saved.completed=false;saved.error=tostring(reason)
  local rollback={attempted=false,success=false,write_calls=0}
  local ok,why=pcall(function()
   need(saved.frame==A.frame()and saved.key==ctx.key and A.current(ctx)==true,'Expired cloth frame; no recovery writes')
   need(ctx.coherent_raw_before,'Missing recovery snapshot')
   -- Check every domain before the first recovery write. Each setter rechecks
   -- ownership; a deleted/replaced actor never receives stale recovery poses.
   for _,spec in ipairs(config.write_order)do validate(ctx,ctx.coherent_roots[spec.name])end
   rollback.attempted=true
   for _,spec in ipairs(config.write_order)do
    local entry=ctx.coherent_roots[spec.name];local pose=ctx.coherent_raw_before[spec.name]
    validate(ctx,entry);rollback.write_calls=rollback.write_calls+1
    call('joint_set_world_q',entry.joint,pose.q)
    validate(ctx,entry);rollback.write_calls=rollback.write_calls+1
    call('joint_set_world_p',entry.joint,pose.p)
   end
   need(saved.frame==A.frame()and A.current(ctx)==true,'Cloth frame expired during recovery')
   for _,spec in ipairs(config.write_order)do
    local entry=ctx.coherent_roots[spec.name];validate(ctx,entry)
    local s=call('joint_local_scale',entry.joint);local old=ctx.coherent_raw_before[spec.name].local_s
    need(finite(s.x)and finite(s.y)and finite(s.z)and s.x==old.x and s.y==old.y and s.z==old.z,'Recovery left changed local scale')
   end
  end)
  rollback.success=ok;if not ok then rollback.error=tostring(why)end
  saved.rollback=rollback;latest[ctx.actor_id]=saved
  if ctx.coherent_stats then ctx.coherent_stats.rollback_write_calls=rollback.write_calls;ctx.coherent_stats.rollback_success=ok end
  ctx.coherent_input=nil;ctx.coherent_raw_before=nil
  return rollback
 end
 function A.pose_stats(ctx)
  local s=ctx.coherent_stats
  if not s or s.frame~=A.frame()then return{joint_write_calls=0,rollback_write_calls=0,completed=false}end
  return{joint_write_calls=s.joint_write_calls,rollback_write_calls=s.rollback_write_calls,completed=s.completed,rollback_success=s.rollback_success,baseline_valid=s.baseline_valid,native_only=s.native_only,reason=s.reason}
 end
 function A.coherent_frame(frame,actor)
  local saved=latest[actor]
  if not saved or saved.frame~=frame then return nil end
  local function copy(value)if type(value)~='table'then return value end;local out={};for k,v in pairs(value)do out[k]=copy(v)end;return out end
  return copy(saved)
 end
 function A.invalidate(reason)latest={};original_invalidate(reason)end
 return A
end
return M

end)()
local HipGate=(function()
-- Scalar response only. Actual vector length is supplied by the C++ backend.
local M={}
local function finite(v)return type(v)=='number'and v==v and math.abs(v)<math.huge end
function M.weight(distance,inner,outer)
 assert(finite(distance)and distance>=0,'Invalid hand distance')
 assert(finite(inner)and finite(outer)and inner>=0 and outer>inner,'Invalid clearance radii')
 if distance<=inner then return 1 end
 if distance>=outer then return 0 end
 local t=(distance-inner)/(outer-inner)
 local s=t*t*t*(10+t*(-15+6*t))
 return math.max(0,math.min(1,1-s))
end
return M

end)()
local HipBinding=(function()
-- One cached scalar input; Hip pose remains a native JointConstraints output.
local M={}
local function need(v,s)if not v then error(s,0)end end
local function id(v)return v and tostring(v:get_address())or nil end
local function same(a,b)return a and b and id(a)==id(b)end
local function finite(v)return type(v)=='number'and v==v and math.abs(v)<math.huge end
local function xyz(v)return{v.x,v.y,v.z}end
local function copy(t)if type(t)~='table'then return t end;local out={};for k,v in pairs(t)do out[k]=copy(v)end;return out end
function M.decorate(C,sdk,A,Gate)
 local config=C.hip_clearance;need(config and config.inner_radius_m==.35,'Unapproved Hip clearance plateau')
 need(config.outer_radius_m==.55,'Unapproved Hip clearance taper')
 local methods,defs={},{};local base
 for _,spec in ipairs(C.hip_clearance_specs)do
  local td=defs[spec.type]
  if not td then td=sdk.find_type_definition(spec.type);need(td and td:get_crc_hash()==C.crcs[spec.type],'Hip SDK type changed');defs[spec.type]=td end
  local method=td:get_method(spec.name..'('..table.concat(spec.params,', ')..')')
  need(method and method:get_num_params()==#spec.params and method:get_return_type():get_full_name()==spec.returns and method:is_static()==spec.is_static,'Hip SDK method changed')
  for i,p in ipairs(method:get_param_types())do need(p:get_full_name()==spec.params[i],'Hip SDK parameter changed')end
  local address=sdk.to_int64(method:get_function());need(finite(address)and address>0,'Hip method lacks native address')
  base=base or(address-spec.rva);need(base==address-spec.rva,'Hip native method RVA changed');methods[spec.key]=method
 end
 local function call(key,o,...)return methods[key]:call(o,...)end
 local function joint_valid(o)return o and sdk.is_managed_object(o)and o:get_type_definition():is_a('via.Joint')and call('joint_valid',o)==true end
 local function validate(ctx,entry)
  need(A.current(ctx)==true and joint_valid(entry.joint),'Hip input owner expired')
  need(call('joint_name',entry.joint)==entry.name and same(call('joint_owner',entry.joint),entry.owner),'Hip cached joint identity changed')
 end
 local function get_vector(ctx,entry,key)
  validate(ctx,entry);local value=call(key,entry.joint)
  need(value and finite(value.x)and finite(value.y)and finite(value.z),'Nonfinite Hip input')
  return value:clone()
 end
 local bind,pre,post,abort,stats,frame_data,invalidate,resolve=A.bind,A.before_stage,A.after_stage,A.abort_pose,A.pose_stats,A.coherent_frame,A.invalidate,A.resolve_all
 local latest={}
 function A.bind(ctx)
  bind(ctx)
  local array=call('transform_joints',ctx.body_transform)
  need(array and sdk.is_managed_object(array)and array:get_type_definition():is_array(),'Hip Body joint array unavailable')
  need(call('array_length',array,0)==#C.body_names,'Hip Body skeleton count changed')
  local found={}
  for index,name in ipairs(C.body_names)do
   local purpose=name==config.hand_joint and'hand'or name==config.pelvis_joint and'pelvis'or name==config.register_joint and'register'or nil
   if purpose then
    local joint=call('array_value',array,index-1);need(joint_valid(joint)and call('joint_name',joint)==name,'Hip input joint layout changed')
    local owner=call('joint_owner',joint)
    need(same(owner,ctx.body_transform)or(purpose~='register'and same(owner,ctx.actor_transform)),'Hip input joint is outside the actual Actor/Body domain')
    need(not found[purpose],'Duplicate Hip input joint');found[purpose]={name=name,joint=joint,owner=owner}
   end
  end
  need(found.hand and found.pelvis and found.register,'Missing required Hip distance/register joints')
  ctx.hip_clearance_nodes=found;ctx.hip_clearance_input=nil;ctx.hip_clearance_stats=nil
 end
 function A.before_stage(ctx,role)
  if pre then pre(ctx,role)end
  if role~=config.role then return end
  local frame=A.frame();local nodes=ctx.hip_clearance_nodes;need(nodes,'Hip gate not bound')
  need(not ctx.hip_clearance_input,'Unfinished Hip scalar input')
  local hand=get_vector(ctx,nodes.hand,'joint_world_p');local pelvis=get_vector(ctx,nodes.pelvis,'joint_world_p')
  local distance=(hand-pelvis):length();need(finite(distance),'C++ distance is not finite')
  local weight=Gate.weight(distance,config.inner_radius_m,config.outer_radius_m)
  local before=get_vector(ctx,nodes.register,'joint_local_p');local target=before:clone();target.x=weight/100.0
  local saved={schema='scarlet-hip-clearance-frame-v1',frame=frame,key=ctx.key,actor=ctx.actor_id,body=ctx.body_id,generation=ctx.generation,
   hand=xyz(hand),pelvis=xyz(pelvis),distance_m=distance,inner_radius_m=config.inner_radius_m,outer_radius_m=config.outer_radius_m,
   requested_gate=weight,register_joint=nodes.register.name,register_owner=id(nodes.register.owner),register_before=xyz(before),
   input_write_calls=0,completed=false}
  ctx.hip_clearance_input=saved;ctx.hip_clearance_before=before
  ctx.hip_clearance_stats={frame=frame,input_write_calls=0,recovery_write_calls=0,completed=false}
  validate(ctx,nodes.register);ctx.hip_clearance_stats.input_write_calls=1;saved.input_write_calls=1
  call('joint_set_local_p',nodes.register.joint,target)
  local actual=get_vector(ctx,nodes.register,'joint_local_p')
  need(actual.y==before.y and actual.z==before.z,'Hip scalar write changed another component')
  need(math.abs(actual.x-target.x)<1e-8,'Hip scalar input did not read back')
  saved.register_after=xyz(actual);saved.register_readback_times_100_double=actual.x*100
  saved.native_factor_semantics='float32(register_after[1] * 100.0f)'
  need(A.current(ctx)==true and A.frame()==frame,'Hip scalar write crossed owner/frame')
 end
 function A.after_stage(ctx,role)
  if post then post(ctx,role)end
  if role~=config.role then return end
  local saved=ctx.hip_clearance_input
  need(saved and saved.frame==A.frame()and saved.key==ctx.key and A.current(ctx)==true,'Hip response lacks its same-frame scalar input')
  local actual=get_vector(ctx,ctx.hip_clearance_nodes.register,'joint_local_p')
  for i,key in ipairs({'x','y','z'})do need(actual[key]==saved.register_after[i],'Native Hip stage unexpectedly rewrote scalar input')end
  saved.completed=true;ctx.hip_clearance_stats.completed=true;latest[ctx.actor_id]=saved
  ctx.hip_clearance_input=nil;ctx.hip_clearance_before=nil
 end
 function A.abort_pose(ctx,reason)
  local coherent=abort and abort(ctx,reason)or{attempted=false}
  local saved=ctx.hip_clearance_input
  if not saved then return coherent end
  saved.error=tostring(reason);saved.completed=false
  local recovery={attempted=false,scalar_restored=false,native_pose_restored=false,
    scope='Only the scalar register can be restored here. A failed native Hip stage requires owner quarantine and controlled game recovery.'}
  local ok,why=pcall(function()
   need(saved.frame==A.frame()and saved.key==ctx.key and A.current(ctx)==true,'Expired Hip scalar recovery frame')
   local entry=ctx.hip_clearance_nodes.register;validate(ctx,entry)
   recovery.attempted=true;ctx.hip_clearance_stats.recovery_write_calls=1
   call('joint_set_local_p',entry.joint,ctx.hip_clearance_before)
   local actual=get_vector(ctx,entry,'joint_local_p')
   for i,key in ipairs({'x','y','z'})do need(actual[key]==saved.register_before[i],'Hip scalar recovery did not read back')end
  end)
  recovery.scalar_restored=ok;if not ok then recovery.error=tostring(why)end
  saved.recovery=recovery;latest[ctx.actor_id]=saved;ctx.hip_clearance_input=nil;ctx.hip_clearance_before=nil
  return{coherent=coherent,hip=recovery,success=false}
 end
 function A.pose_stats(ctx)
  local result=stats and stats(ctx)or{joint_write_calls=0,rollback_write_calls=0,completed=true}
  result.coherent_joint_write_calls=result.joint_write_calls
  local s=ctx.hip_clearance_stats
  if s and s.frame==A.frame()then
   result.hip_scalar_write_calls=s.input_write_calls;result.hip_scalar_recovery_calls=s.recovery_write_calls
   result.joint_write_calls=result.joint_write_calls+s.input_write_calls
   result.rollback_write_calls=result.rollback_write_calls+s.recovery_write_calls
   result.completed=result.completed and s.completed
  else result.hip_scalar_write_calls=0;result.hip_scalar_recovery_calls=0;result.completed=false end
  return result
 end
 function A.coherent_frame(frame,actor)
  local result=frame_data and frame_data(frame,actor)or nil
  local saved=latest[actor]
  if result then
   result.coherent_completed=result.completed
   if saved and saved.frame==frame then result.hip_clearance=copy(saved)
   else result.hip_clearance={available=false,frame=frame,completed=false}end
   result.completed=result.coherent_completed==true and result.hip_clearance.completed==true
  end
  return result
 end
 function A.resolve_all(frame,read_only)
  local contexts=resolve(frame,read_only);local alive={};for _,ctx in ipairs(contexts)do alive[ctx.actor_id]=true end
  for actor in pairs(latest)do if not alive[actor]then latest[actor]=nil end end
  return contexts
 end
 function A.invalidate(reason)latest={};invalidate(reason)end
 return A
end
return M

end)()
local LateCore=(function()
-- Post updateJoint records completion; the host flushes once before primary.
-- Only native updateIK performs pose work. This module has no bone mathematics.
local M={}
local function need(v,s)if not v then error(s,0)end end
local function finite(x)return type(x)=='number'and x==x and math.abs(x)<math.huge end
local function copy(x)if type(x)~='table'then return x end;local o={};for k,v in pairs(x)do o[k]=copy(v)end;return o end
function M.condition(s)
 if type(s)~='table'then return false,'missing_snapshot'end
 if not s.enabled or not s.transfer_enabled or not s.overwrite_active then return false,'inactive'end
 if s.overwrite_request_pending then return false,'overwrite_not_consumed'end
 if s.action_type~='app.PlayerBasicAction.cAutoWeaponOffIdle'then return false,'outside_observed_action'end
 for _,k in ipairs({'transfer_rate','hold_rate','sequence_blend','sequence_ik'})do if not finite(s[k])or s[k]<0 or s[k]>1 then return false,'invalid_rate_'..k end end
 if s.transfer_rate<=0 or s.transfer_rate>=1 then return false,'transfer_endpoint'end
 if s.hold_rate<=0 or s.sequence_blend<=0 or s.sequence_ik<=0 then return false,'hand_ik_inactive'end
 local rate=string.unpack('<f',string.pack('<f',s.hold_rate*s.sequence_blend*s.sequence_ik))
 if rate~=1 then return false,'partial_ik_rate_not_supported'end
 return true,'late_native_hand_target',rate
end
function M.new(A)
 for _,n in ipairs({'get_owner','is_current','frame','clock','frequency','snapshot','call_ik'})do need(type(A[n])=='function','Missing deferred sheath adapter '..n)end
 local frequency=A.frequency();need(finite(frequency)and frequency>0,'Deferred sheath QPC frequency')
 local closed,busy=false,false;local frame_scope;local pending,flushed={},{};local blocked={};local events={};local seq,ticket_sequence=0,0
 local status={schema='scarlet-native-late-sheath-status-v2',candidate=true,runtime_verified=false,frequency=frequency,hook_entries=0,matched_entries=0,completed_updates=0,flushes=0,native_calls=0,native_attempts=0,faults=0,duplicates=0,timing_conflicts=0,reentrant_skips=0,pre_wrapper_ticks=0,post_wrapper_ticks=0,flush_ticks=0,native_ticks=0}
 local function event(e)
  seq=seq+1;e.sequence=seq;e.schema='scarlet-native-late-sheath-event-v2';events[#events+1]=e;if#events>128 then table.remove(events,1)end
  if A.event then pcall(A.event,copy(e))end
 end
 local function enter_frame(f)
  need(finite(f)and f%1==0 and f>=0,'Deferred sheath frame')
  need(frame_scope==nil or f>=frame_scope,'Deferred sheath frame moved backwards')
  if frame_scope~=f then frame_scope=f;pending={};flushed={}end
 end
 local function empty(reason,frame,key)return{native_calls=0,native_attempts=0,native_ticks=0,success=true,reason=reason,frame=frame,owner_key=key}end
 local self={}
 function self.before(updater_address)
  status.hook_entries=status.hook_entries+1
  if closed then return nil end
  if busy then status.reentrant_skips=status.reentrant_skips+1;return nil end
  local t=A.clock();local ok,ticket=pcall(function()
   local owner=A.get_owner();if not owner or owner.kind~='player'or tostring(owner.updater_address)~=tostring(updater_address)then return nil end
   local f=A.frame();need(finite(f)and f%1==0 and f>=0,'Deferred sheath frame')
   status.matched_entries=status.matched_entries+1
   return{owner=owner,context=owner.context,frame=f,updater_address=tostring(updater_address),owner_key=owner.key,default_target=(not A.precondition or A.precondition(owner))==true}
  end)
  status.pre_wrapper_ticks=status.pre_wrapper_ticks+math.max(0,A.clock()-t)
  if not ok then status.faults=status.faults+1;event({kind='binding_fault',error=tostring(ticket)});return nil end
  return ticket
 end
 function self.after(ticket)
  if closed or not ticket then return false,'closed_or_unowned'end
  if busy then status.reentrant_skips=status.reentrant_skips+1;return false,'reentrant'end
  local t=A.clock();local recorded,reason=false,'not_recorded'
  local ok,err=pcall(function()
   local f=A.frame();if f~=ticket.frame then reason='original_updateJoint_crossed_frame';event({kind=reason,before_frame=ticket.frame,after_frame=f,owner_key=ticket.owner_key});return end
   local o=A.get_owner();if o~=ticket.owner or o.context~=ticket.context or o.key~=ticket.owner_key then reason='owner_changed';return end
   enter_frame(f);ticket_sequence=ticket_sequence+1;ticket.serial=ticket_sequence;ticket.completed_tick=A.clock()
   status.completed_updates=status.completed_updates+1
   local prior=flushed[ticket.updater_address]
   if prior then
    status.timing_conflicts=status.timing_conflicts+1
    event({kind='timing_conflict_updateJoint_after_flush',frame=f,owner_key=ticket.owner_key,updater=ticket.updater_address,completed_ticket_serial=ticket.serial,completed_tick=ticket.completed_tick,flush_ticket_serial=prior.ticket_serial,flush_native_calls=prior.native_calls,flush_reason=prior.reason,flush_start_tick=prior.start_tick,flush_end_tick=prior.end_tick})
    reason='timing_conflict_after_flush'
   else reason='latest_owned_completion_saved'end
   -- Keep the last completed original call, including one with an alternate
   -- target. Never keep an earlier permissive ticket after a later update.
   if not pending[ticket.updater_address]then local count=0;for _ in pairs(pending)do count=count+1 end;need(count<32,'Deferred sheath pending owner bound')end
   pending[ticket.updater_address]=ticket;recorded=true
  end)
  status.post_wrapper_ticks=status.post_wrapper_ticks+math.max(0,A.clock()-t)
  if not ok then status.faults=status.faults+1;event({kind='completion_marker_fault',frame=ticket.frame,owner_key=ticket.owner_key,error=tostring(err)});return false,'fault'end
  return recorded,reason
 end
 function self.flush(ctx)
  if closed then return empty('closed')end
  if busy then status.reentrant_skips=status.reentrant_skips+1;return empty('reentrant')end
  local start=A.clock();local out=empty('not_run');out.flush_start_tick=start;local owner,ledger
  local ok,err=pcall(function()
   status.flushes=status.flushes+1
   local f=A.frame();out.frame=f
   if not ctx or ctx.kind~='player'then out.reason='not_owned_player_context';return end
   owner=A.get_owner();if not owner or owner.kind~='player'or owner.context~=ctx or owner.key~=ctx.key then out.reason='owner_context_mismatch';return end
   out.owner_key=owner.key;out.updater=tostring(owner.updater_address);enter_frame(f)
   if flushed[out.updater]then status.duplicates=status.duplicates+1;out.reason='already_flushed_this_owner_frame';return end
   local count=0;for _ in pairs(flushed)do count=count+1 end;need(count<32,'Deferred sheath owner bound')
   ledger={native_calls=0,reason='flush_started',owner_key=owner.key,start_tick=start};flushed[out.updater]=ledger
   local ticket=pending[out.updater]
   if not ticket then out.reason='no_completed_updateJoint_this_frame';return end
   out.completed_ticket_serial=ticket.serial;out.original_completed_tick=ticket.completed_tick;ledger.ticket_serial=ticket.serial
   if ticket.frame~=f or ticket.owner~=owner or ticket.context~=ctx or ticket.owner_key~=ctx.key then out.reason='completion_ticket_context_mismatch';return end
   if blocked[owner.key]then out.reason='owner_quarantined';return end
   if not ticket.default_target then out.reason='original_alternate_ik_target';return end
   local before=copy(A.snapshot(owner));local wanted,why,rate=M.condition(before);out.reason=why
   if not wanted then return end
   if not A.is_current(owner)then out.reason='owner_changed';return end
   -- Mark before invoking native code. A recursive flush cannot call twice.
   busy=true;local native_start=A.clock();out.native_attempts=1;out.native_calls=1;ledger.native_calls=1
   status.native_attempts=status.native_attempts+1;status.native_calls=status.native_calls+1
   local call_ok,call_error=pcall(A.call_ik,owner,rate);local native_end=A.clock();busy=false
   out.native_start_tick=native_start;out.native_end_tick=native_end
   need(native_end>=native_start,'Deferred sheath QPC moved backwards')
   out.native_ticks=native_end-native_start;status.native_ticks=status.native_ticks+out.native_ticks
   if not call_ok then error(call_error,0)end
   need(A.frame()==f,'Frame changed during deferred native IK')
   need(A.is_current(owner),'Owner changed during deferred native IK')
   local after=A.snapshot(owner)
   for _,k in ipairs({'enabled','transfer_enabled','transfer_rate','hold_rate','sequence_blend','sequence_ik','overwrite_active','overwrite_request_pending','action_type'})do need(after[k]==before[k],'Unexpected control-state write during deferred native IK: '..k)end
   out.reason='native_updateIK_completed';out.rate=rate;out.transfer_rate=before.transfer_rate
   event({kind='native_updateIK_before_primary',frame=f,owner_key=owner.key,actor=owner.actor_address,body=owner.body_address,updater=out.updater,completed_ticket_serial=ticket.serial,original_completed_tick=ticket.completed_tick,flush_start_tick=start,native_start_tick=native_start,native_end_tick=native_end,rate=rate,transfer_rate=before.transfer_rate,native_ticks=out.native_ticks,after_original_updateJoint=true,before_primary_by_host_contract=true,control_parameters_unchanged=true,pose_math='native only'})
  end)
  busy=false
  if not ok then
   if owner then blocked[owner.key]=true end
   status.faults=status.faults+1;out.success=false;out.reason='fault';out.error=tostring(err);out.native_call_may_have_partially_written=out.native_attempts==1
   event({kind='native_fault',frame=out.frame,owner_key=out.owner_key,error=out.error,native_calls=out.native_calls,native_ticks=out.native_ticks,native_call_may_have_partially_written=out.native_call_may_have_partially_written,quarantined=true})
  end
  out.flush_end_tick=A.clock()
  if ledger then ledger.reason=out.reason;ledger.native_calls=out.native_calls;ledger.end_tick=out.flush_end_tick end
  status.flush_ticks=status.flush_ticks+math.max(0,out.flush_end_tick-start)
  return out
 end
 function self.close()closed=true;pending={};status.closed=true;event({kind='closed'});return self.status()end
 function self.retry()closed=false;pending={};status.closed=false;return self.status()end
 function self.status()local s=copy(status);s.busy=busy;s.closed=closed;s.latest_sequence=seq;s.latest_completed_ticket=ticket_sequence;return s end
 function self.events(after)
  local out={};for _,e in ipairs(events)do if e.sequence>(after or 0)then out[#out+1]=copy(e)end end
  return{events=out,latest_sequence=seq,first_available=events[1]and events[1].sequence or seq+1}
 end
 return self
end
return M

end)()
local LateSDK=(function()
-- Post updateJoint saves completion only. Host flush(ctx) replays before primary.
-- Caller supplies the existing fully validated adapter's cached player context.
local M={}
local function need(v,s)if not v then error(s,0)end end
local function id(o)return o and tostring(o:get_address())end
local function same(a,b)return a~=nil and b~=nil and id(a)==id(b)end
function M.new(C,sdk,thread,A,Core)
 for _,n in ipairs({'peek_owned_player','current_owner_context','frame','clock','frequency'})do need(type(A[n])=='function','Missing late sheath host '..n)end
 local defs,methods,fields={},{},{};local base;local bound;local closed=false
 for n,crc in pairs(C.crcs)do local d=sdk.find_type_definition(n);need(d and d:get_crc_hash()==crc,'Late sheath SDK CRC '..n);defs[n]=d end
 for _,s in ipairs(C.specs)do
  local f=defs[s.type]:get_method(s.name..'('..table.concat(s.params,', ')..')')
  need(f and f:get_num_params()==#s.params and f:get_return_type():get_full_name()==s.returns and f:is_static()==s.is_static,'Late sheath native signature '..s.key)
  local va=sdk.to_int64(f:get_function());base=base or(va-s.rva);need(va-s.rva==base,'Late sheath native RVA '..s.key);methods[s.key]=f
 end
 for _,s in ipairs(C.fields)do local f=defs[s.type]:get_field(s.name);need(f and f:get_offset_from_base()==s.offset and f:get_type():get_full_name()==s.value_type,'Late sheath field layout '..s.key);fields[s.key]=f end
 local function call(k,o,...)return methods[k]:call(o,...)end
 local function get(k,o)return fields[k]:get_data(o)end
 local function managed(o,t)return o~=nil and sdk.is_managed_object(o)and o:get_type_definition():is_a(t)end
 local function valid_context(ctx)
  return ctx and ctx.kind=='player'and ctx.skip_native~=true and A.current_owner_context(ctx)and call('go_valid',ctx.actor)and call('go_valid',ctx.body)and call('component_valid',ctx.mesh)and same(call('component_go',ctx.mesh),ctx.body)
 end
 local function get_owner()
  if closed then return nil end
  local ctx=A.peek_owned_player();if not ctx or ctx.kind~='player'then bound=nil;return nil end
  if bound and bound.context==ctx and bound.key==ctx.key then return bound end
  if not valid_context(ctx)then bound=nil;return nil end
  local pm=call('pm_instance',nil);if not managed(pm,'app.PlayerManager')then return nil end
  local info=call('pm_info',pm);if not managed(info,'app.cPlayerManageInfo')then return nil end
  local character=call('info_character',info);local entity=call('info_entity',info)
  if not managed(entity,'app.cPlayerCharacterEntity')or not same(call('component_go',character),ctx.actor)then return nil end
  local updater=call('entity_sheath',entity);if not managed(updater,'app.mcLeftHandSheathHold')then return nil end
  local state=get('state',updater);local onoff=get('onoff',updater);local overwrite=get('overwrite',updater)
  if not managed(state,'app.mcLeftHandSheathHold.StateValue')or not managed(onoff,'app.mcLeftHandSheathHold.cWeaponOnOff')or not managed(overwrite,'app.cJointPosOverwriteRate')then return nil end
  local request=get('request',overwrite);if not managed(request,'app.cJointPosOverwriteRate.RequestDate')then return nil end
  bound={context=ctx,key=ctx.key,kind='player',actor_address=id(ctx.actor),body_address=id(ctx.body),updater_address=id(updater),entity=entity,character=character,updater=updater,state=state,onoff=onoff,overwrite=overwrite,request=request}
  return bound
 end
 local function is_current(o)
  if closed or bound~=o or not valid_context(o.context)then return false end
  local pm=call('pm_instance',nil);if not managed(pm,'app.PlayerManager')then return false end
  local info=call('pm_info',pm);if not managed(info,'app.cPlayerManageInfo')then return false end
  return same(call('info_entity',info),o.entity)and same(call('info_character',info),o.character)and same(call('entity_sheath',o.entity),o.updater)
   and same(get('state',o.updater),o.state)and same(get('onoff',o.updater),o.onoff)and same(get('overwrite',o.updater),o.overwrite)and same(get('request',o.overwrite),o.request)
 end
 local function snapshot(o)
  if not same(get('state',o.updater),o.state)or not same(get('onoff',o.updater),o.onoff)or not same(get('overwrite',o.updater),o.overwrite)or not same(get('request',o.overwrite),o.request)then return{enabled=false}end
  local s={enabled=get('enabled',o.updater),transfer_enabled=get('transfer_enabled',o.onoff),transfer_rate=get('transfer_rate',o.onoff),
   overwrite_active=get('overwrite_active',o.overwrite),overwrite_request_pending=get('request_pending',o.request),hold_rate=get('hold_rate',o.state),sequence_blend=get('sequence_blend',o.updater),sequence_ik=get('sequence_ik',o.updater)}
  -- Resolve action only in the tiny candidate window, not every frame.
  if s.enabled and s.transfer_enabled and s.overwrite_active and s.transfer_rate>0 and s.transfer_rate<1 and s.hold_rate>0 then
   local controller=call('base_action_controller',o.character);local action=controller and call('current_action',controller);s.action_type=action and action:get_type_definition():get_full_name()
  end
  return s
 end
 local core=Core.new({get_owner=get_owner,is_current=is_current,frame=A.frame,clock=A.clock,frequency=A.frequency,snapshot=snapshot,
  precondition=function(o)return same(get('state',o.updater),o.state)and get('ik_pos_go',o.state)==nil end,
  call_ik=function(o,rate)call('update_ik',o.updater,rate)end,event=A.event})
 local storage_key='scarlet_late_sheath_updateJoint_v2'
 sdk.hook(methods.update_joint,function(args)
  local s=thread.get_hook_storage();local slot=s[storage_key]or{stack={},overflow=0};s[storage_key]=slot;local stack=slot.stack
  -- A stack preserves nested pre/post pairing. Core also rejects reentrancy.
  if slot.overflow>0 or#stack>=8 then slot.overflow=slot.overflow+1;return sdk.PreHookResult.CALL_ORIGINAL end
  stack[#stack+1]=scarlet_gate.allow('UpdateJoint') and not closed and core.before(tostring(sdk.to_int64(args[2])))or false
  return sdk.PreHookResult.CALL_ORIGINAL
 end,function(ret)
  local s=thread.get_hook_storage();local slot=s[storage_key];if slot and slot.overflow>0 then slot.overflow=slot.overflow-1;return ret end
  local stack=slot and slot.stack;local ticket=stack and table.remove(stack)
  if ticket and not closed then core.after(ticket)end
  return ret
 end)
 return{status=core.status,events=core.events,flush=core.flush,close=function()closed=true;bound=nil;return core.close()end,retry=function()closed=false;bound=nil;return core.retry()end,
  contract_sha256=C.contract_sha256,scope='Owned player only; latest completed original updateJoint; host flush before primary; native updateIK only; no Lua bone math'}
end
return M

end)()
local AssemblyMath=(function()
-- Fixed three-input accessory reference. No SDK calls, graph search, hooks or
-- vertex sampling. Caller supplies current Body joint world matrices as
-- row-major 16-number arrays and owns all runtime identity/write checks.
local M = {}
local function mm(a,b)
    local r={}
    for i=0,3 do for j=0,3 do
        local x=0
        for k=0,3 do x=x+a[i*4+k+1]*b[k*4+j+1] end
        r[i*4+j+1]=x
    end end
    return r
end
local function point(a,p)
    return {a[1]*p[1]+a[2]*p[2]+a[3]*p[3]+a[4],a[5]*p[1]+a[6]*p[2]+a[7]*p[3]+a[8],a[9]*p[1]+a[10]*p[2]+a[11]*p[3]+a[12]}
end
local function it3(a)
    local c={a[5]*a[9]-a[6]*a[8],a[6]*a[7]-a[4]*a[9],a[4]*a[8]-a[5]*a[7],
        a[3]*a[8]-a[2]*a[9],a[1]*a[9]-a[3]*a[7],a[2]*a[7]-a[1]*a[8],
        a[2]*a[6]-a[3]*a[5],a[3]*a[4]-a[1]*a[6],a[1]*a[5]-a[2]*a[4]}
    local det=a[1]*c[1]+a[2]*c[2]+a[3]*c[3]
    if det<1e-8 then return nil,"singular or reflected attachment reference" end
    for i=1,9 do c[i]=c[i]/det end
    return c
end
local function polar(a)
    local r={a[1],a[2],a[3],a[5],a[6],a[7],a[9],a[10],a[11]}
    for iteration=1,8 do
        local inv,err=it3(r)
        if not inv then return nil,err end
        local change=0
        for i=1,9 do local x=(r[i]+inv[i])*.5;change=math.max(change,math.abs(x-r[i]));r[i]=x end
        if change<1e-12 then break end
    end
    local e=0
    for i=0,2 do for j=0,2 do
        local x=0
        for k=0,2 do x=x+r[k*3+i+1]*r[k*3+j+1] end
        e=math.max(e,math.abs(x-(i==j and 1 or 0)))
    end end
    -- Preserve every successful eight-step output exactly. A ninth step
    -- is used only for the recorded, finite near-threshold failure; the same
    -- singularity/reflection and orthogonality gates remain mandatory.
    if e>1e-7 then
        local inv,err=it3(r)
        if not inv then return nil,err end
        for i=1,9 do r[i]=(r[i]+inv[i])*.5 end
        e=0
        for i=0,2 do for j=0,2 do
            local x=0
            for k=0,2 do x=x+r[k*3+i+1]*r[k*3+j+1] end
            e=math.max(e,math.abs(x-(i==j and 1 or 0)))
        end end
    end
    if e>1e-7 then return nil,"attachment rotation did not converge" end
    return r,e
end
local function finite_matrix(a)
    if type(a)~="table" or #a~=16 then return false end
    for i=1,16 do if type(a[i])~="number" or a[i]~=a[i] or math.abs(a[i])==math.huge then return false end end
    if math.abs(a[13])+math.abs(a[14])+math.abs(a[15])>1e-5 or math.abs(a[16]-1)>1e-5 then return false end
    return true
end
function M.compute(config, world_by_name)
    local skin={}
    for i,input in ipairs(config.inputs) do
        local world=world_by_name[input.name]
        if not finite_matrix(world) then return nil,"missing/non-finite/non-affine joint world: "..input.name end
        skin[i]=mm(world,input.inverse_bind)
    end
    local affine={};local points={}
    for side,anchor in ipairs(config.anchors) do
        local a={}
        for k=1,16 do a[k]=0 end
        for i,w in ipairs(anchor.weight_bytes) do
            for k=1,16 do a[k]=a[k]+skin[i][k]*(w/255) end
        end
        affine[side]=a;points[side]=point(a,anchor.reference_point_native)
    end
    local mean={}
    for i=1,16 do mean[i]=(affine[1][i]+affine[2][i])*.5 end
    local r,err=polar(mean)
    if not r then return nil,err end
    local origin={(points[1][1]+points[2][1])*.5,(points[1][2]+points[2][2])*.5,(points[1][3]+points[2][3])*.5}
    local p=config.reference_origin_native
    local rigid={r[1],r[2],r[3],origin[1]-(r[1]*p[1]+r[2]*p[2]+r[3]*p[3]),
        r[4],r[5],r[6],origin[2]-(r[4]*p[1]+r[5]*p[2]+r[6]*p[3]),
        r[7],r[8],r[9],origin[3]-(r[7]*p[1]+r[8]*p[2]+r[9]*p[3]),0,0,0,1}
    return {mount_world=mm(rigid,config.mount_bind_world),rigid_skin_reference=rigid,
        anchor_world=points,rotation_error=err,source_joint_count=#config.inputs}
end
return M

end)()
local AssemblySDK=(function()
-- Owned Body integration only. No autorun hook and no new skeleton nodes.
local M={}
local function identity(o)return o and tostring(o:get_address())or nil end
local function finite(x)return type(x)=='number'and x==x and math.abs(x)<math.huge end
local function quat(a)
    local r={a[1],a[2],a[3],a[5],a[6],a[7],a[9],a[10],a[11]}
    for c=1,3 do local s=math.sqrt(r[c]^2+r[c+3]^2+r[c+6]^2);if s<1e-8 then return nil end;for row=0,2 do r[row*3+c]=r[row*3+c]/s end end
    local x,y,z,w;local tr=r[1]+r[5]+r[9]
    if tr>0 then local s=math.sqrt(tr+1)*2;w=s/4;x=(r[8]-r[6])/s;y=(r[3]-r[7])/s;z=(r[4]-r[2])/s
    elseif r[1]>r[5]and r[1]>r[9]then local s=math.sqrt(1+r[1]-r[5]-r[9])*2;w=(r[8]-r[6])/s;x=s/4;y=(r[2]+r[4])/s;z=(r[3]+r[7])/s
    elseif r[5]>r[9]then local s=math.sqrt(1+r[5]-r[1]-r[9])*2;w=(r[3]-r[7])/s;x=(r[2]+r[4])/s;y=s/4;z=(r[6]+r[8])/s
    else local s=math.sqrt(1+r[9]-r[1]-r[5])*2;w=(r[4]-r[2])/s;x=(r[3]+r[7])/s;y=(r[6]+r[8])/s;z=s/4 end
    local n=math.sqrt(x*x+y*y+z*z+w*w);if not finite(n)or n<1e-8 then return nil end
    return{x/n,y/n,z/n,w/n}
end
M.quaternion_from_row_major=quat
function M.decorate(C,sdk,A,Math,config)
    local methods={};local base;local latest={};local init_ok,init_error=pcall(function()
        local specs={
            {'joints','via.Transform','get_Joints',{},'via.Joint[]',125571280},
            {'length','System.Array','GetLength',{'System.Int32'},'System.Int32',114447776},
            {'value','System.Array','GetValue',{'System.Int32'},'System.Object',114447856},
            {'valid','via.Joint','get_Valid',{},'System.Boolean',94763376},
            {'name','via.Joint','get_Name',{},'System.String',109358608},
            {'owner','via.Joint','get_Owner',{},'via.Transform',109360928},
            {'parent','via.Joint','get_Parent',{},'via.Joint',109360368},
            {'basep','via.Joint','get_BaseLocalPosition',{},'via.vec3',109360528},
            {'baseq','via.Joint','get_BaseLocalRotation',{},'via.Quaternion',109360624},
            {'bases','via.Joint','get_BaseLocalScale',{},'via.vec3',109360704},
            {'world','via.Joint','get_WorldMatrix',{},'via.mat4',109360048},
            {'p','via.Joint','get_Position',{},'via.vec3',109358800},
            {'q','via.Joint','get_Rotation',{},'via.Quaternion',109359552},
            {'scale','via.Joint','get_LocalScale',{},'via.vec3',109359872},
            {'setp','via.Joint','set_Position',{'via.vec3'},'System.Void',109358864},
            {'setq','via.Joint','set_Rotation',{'via.Quaternion'},'System.Void',109359616},
        }
        for _,s in ipairs(specs)do
            local d=sdk.find_type_definition(s[2]);assert(d and d:get_crc_hash()==C.crcs[s[2]],'Assembly SDK type changed '..s[2])
            local f=d:get_method(s[3]..'('..table.concat(s[4],', ')..')');assert(f and f:get_num_params()==#s[4]and f:get_return_type():get_full_name()==s[5]and not f:is_static(),'Assembly SDK signature changed '..s[1])
            local address=sdk.to_int64(f:get_function());base=base or(address-s[6]);assert(address-s[6]==base,'Assembly SDK RVA changed '..s[1]);methods[s[1]]=f
        end
    end)
    local function call(k,o,...)return methods[k]:call(o,...)end
    local function valid(j)return j and sdk.is_managed_object(j)and call('valid',j)==true end
    local function matrix(value)
        -- REFramework mat4 indexes columns; the fixed math module uses rows.
        local out={};local keys={'x','y','z','w'}
        for row=1,4 do for col=0,3 do out[(row-1)*4+col+1]=value[col][keys[row]]end end
        return out
    end
    local old_bind,old_post,old_invalidate=A.bind,A.after_stage,A.invalidate
    function A.bind(ctx)
        old_bind(ctx);ctx.scarlet_assembly=nil
        if not init_ok then ctx.scarlet_assembly_error=tostring(init_error);return end
        local ok,err=pcall(function()
            assert(A.current(ctx)==true,'Assembly bind lease expired');assert(config.bind_contract and #config.bind_contract==3,'Assembly bind contract absent');local wanted={SCN_BottleMount=true};for _,input in ipairs(config.inputs)do wanted[input.name]=true end
            for _,record in ipairs(config.bind_contract)do wanted[record.name]=true end
            local array=call('joints',ctx.body_transform);local count=call('length',array,0);assert(count==#C.body_names,'Assembly Body skeleton count changed');local joints={}
            for i=0,count-1 do local j=call('value',array,i);local name=call('name',j);if wanted[name]then assert(valid(j)and identity(call('owner',j))==identity(ctx.body_transform),'Assembly joint owner mismatch');joints[name]=j end end
            for name in pairs(wanted)do assert(joints[name],'Missing assembly joint '..name)end
            for _,record in ipairs(config.bind_contract)do
                local j=joints[record.name];local parent=call('parent',j);assert(valid(parent)and call('name',parent)==record.parent,'Assembly base parent differs: '..record.name)
                local p,q,s=call('basep',j),call('baseq',j),call('bases',j);local plus,minus=0,0
                for i,k in ipairs({'x','y','z'})do
                    assert(math.abs(p[k]-record.local_position[i])<=2e-6,'Assembly base position differs: '..record.name)
                    assert(math.abs(s[k]-record.local_scale[i])<=1e-5,'Assembly base scale differs: '..record.name)
                end
                for i,k in ipairs({'x','y','z','w'})do plus=math.max(plus,math.abs(q[k]-record.local_rotation_xyzw[i]));minus=math.max(minus,math.abs(q[k]+record.local_rotation_xyzw[i]))end
                assert(math.min(plus,minus)<=5e-6,'Assembly base rotation differs: '..record.name)
            end
            ctx.scarlet_assembly={joints=joints,body=identity(ctx.body_transform),frame=nil}
        end)
        ctx.scarlet_assembly_error=not ok and tostring(err)or nil
    end
    function A.assembly_after_constraints(ctx)
        local started=A.clock();local state=ctx.scarlet_assembly;local frame=A.frame()
        local function finish(s)
            s.start_tick=started;s.end_tick=A.clock();s.total_ticks=s.end_tick-s.start_tick
            ctx.scarlet_assembly_stats=s;latest[ctx.actor_id]=s;return s
        end
        if not state then
            local s={frame=frame,key=ctx.key,actor=ctx.actor_id,body=identity(ctx.body_transform),reads=0,writes=0,rollback_writes=0,completed=false,error=ctx.scarlet_assembly_error or(not init_ok and tostring(init_error))or'Assembly state not bound'}
            return finish(s)
        end
        if ctx.skip_native then
            local s={frame=frame,key=ctx.key,actor=ctx.actor_id,body=state.body,reads=0,writes=0,rollback_writes=0,completed=true,skipped=true,reason='owned Body hidden'};return finish(s)
        end
        if state.frame==frame then return ctx.scarlet_assembly_stats end
        state.frame=frame;local stats={frame=frame,key=ctx.key,actor=ctx.actor_id,body=state.body,reads=0,writes=0,rollback_writes=0,completed=false};local saved_p,saved_q,target
        local ok,err=pcall(function()
            assert(A.current(ctx)==true and identity(ctx.body_transform)==state.body,'Assembly lease expired')
            local worlds={};for _,input in ipairs(config.inputs)do local j=state.joints[input.name];assert(valid(j),'Assembly input invalid');worlds[input.name]=matrix(call('world',j));stats.reads=stats.reads+1 end
            local result,why=Math.compute(config,worlds);assert(result,why);target=state.joints.SCN_BottleMount;assert(valid(target)and identity(call('owner',target))==state.body and A.current(ctx)==true,'Assembly output lease changed')
            saved_p=call('p',target):clone();saved_q=call('q',target):clone();local scale=call('scale',target):clone();local p=saved_p:clone();local q=saved_q:clone();local value=quat(result.mount_world);assert(value,'Invalid assembly quaternion')
            p.x=result.mount_world[4];p.y=result.mount_world[8];p.z=result.mount_world[12];q.x=value[1];q.y=value[2];q.z=value[3];q.w=value[4]
            call('setp',target,p);stats.writes=1;call('setq',target,q);stats.writes=2
            local after=call('scale',target);assert(math.abs(after.x-scale.x)<1e-6 and math.abs(after.y-scale.y)<1e-6 and math.abs(after.z-scale.z)<1e-6,'Assembly scale changed')
            stats.completed=true;stats.anchor_world=result.anchor_world;stats.mount_world=result.mount_world;stats.rotation_error=result.rotation_error;stats.input_world=worlds
        end)
        if not ok then
            stats.error=tostring(err)
            if stats.writes>0 and saved_p and saved_q then
                local restored=pcall(function()assert(A.current(ctx)==true and valid(target)and identity(call('owner',target))==state.body);call('setp',target,saved_p);stats.rollback_writes=stats.rollback_writes+1;call('setq',target,saved_q);stats.rollback_writes=stats.rollback_writes+1 end)
                stats.restored=restored
            end
        end
        -- Never throw an accessory fault into the character adapter.
        return finish(stats)
    end
    function A.after_stage(ctx,role)
        if old_post then old_post(ctx,role)end
        if role==(C.assembly_after_role or C.roles[#C.roles])then A.assembly_after_constraints(ctx)end
    end
    function A.assembly_frame(frame,actor)
        if actor then local r=latest[actor];return r and r.frame==frame and r or nil end
        for _,r in pairs(latest)do if r.frame==frame then return r end end
    end
    function A.assembly_boot_error()return not init_ok and tostring(init_error)or nil end
    function A.invalidate(reason)latest={};if old_invalidate then old_invalidate(reason)end end
    return A
end
return M

end)()
local AC=json.load_string([=[{"matrix_layout":"row-major flat16; column vectors; native game axes and MESH units","inputs":[{"name":"Bip001-Pelvis","index_at_v9":95,"inverse_bind":[1.0,1.8636372942637536e-06,-1.5479806734219892e-06,-1.827594587666681e-06,-1.8189286947745131e-06,1.0,1.3877959190722322e-06,-0.9886744022369385,1.581509309289686e-06,-1.3877930769012892e-06,1.0,-0.010523894801735878,-0.0,0.0,0.0,1.0]},{"name":"Ab-R-Venter2","index_at_v9":439,"inverse_bind":[0.0007409491227008402,0.0004068990529049188,0.9999994039535522,-0.011138069443404675,-0.9938502311706543,0.11068332940340042,0.0006885832990519702,-0.20348834991455078,-0.11068259924650192,-0.9938557147979736,0.00048609820078127086,0.972244381904602,0.0,0.0,-0.0,1.0]},{"name":"Ab-R-Hip-Reg","index_at_v9":442,"inverse_bind":[-0.9988269209861755,0.04829951003193855,0.0011170539073646069,-0.13968892395496368,-0.0009287807624787092,0.0039740814827382565,-0.9999914169311523,0.006578041706234217,-0.04830348119139671,-0.9988250136375427,-0.0039247265085577965,0.9831758141517639,0.0,0.0,0.0,1.0]}],"anchors":[{"label":"front","source_section":0,"source_vertex_ids":[28434,53936,53934,28435,53933,28437,53927,28439,53925,28441,53921,53918],"source_center_m":[0.01768067930242978,-0.09956393701334794,0.9936724007129669],"reference_point_native":[0.01768067930242978,0.9936724007129669,0.09956389230986436],"weight_bytes":[255,0,0],"source_connection":"Original sling end ring, all12 vertices source Pelvis255; preserves source front/back waist relationship."},{"label":"back","source_section":36,"source_vertex_ids":[28291,53785,53774,28264,53783,28261,53772,28259,53768,28258,53765,53763],"source_center_m":[0.03669525356963277,0.12848518788814545,1.0026804010073345],"reference_point_native":[0.03669525356963277,1.0026804010073345,-0.12848523197074732],"weight_bytes":[255,0,0],"source_connection":"Original sling end ring, all12 vertices source Pelvis255; preserves source front/back waist relationship."}],"reference_origin_native":[0.027187966436031274,0.9981764008601507,-0.014460669830441482],"mount_bind_world":[1.0405757393527892e-06,-0.10956785827875137,-0.9939845204353333,-0.19371041655540466,0.24028129875659943,-0.9648587107658386,0.10635776072740555,0.8016452193260193,-0.9707036018371582,-0.23883457481861115,0.026328567415475845,-0.02470516227185726,0.0,0.0,0.0,1.0],"mount_parent":"Bip001-Pelvis","integration":"Cache only these three Body joint handles per actual body generation. After existing nonphysical native constraint stages, before native Chain2 Last, call compute and write only SCN_BottleMount world/parent-local pose. Preserve original bind scale. A nil result must not disable the character adapter; skip this accessory update and record one bounded diagnostic.","bind_contract":[{"name":"SCN_BottleMount","index":546,"parent":"Bip001-Pelvis","local_position":[-0.19371071457862854,-0.1870288848876953,-0.035230476409196854],"local_rotation_xyzw":[-0.6961564734410323,-0.04694019604490915,0.7055464096500487,0.1239638911592267],"local_scale":[1.0000003174896086,0.9999996948833321,1.000005170305906]},{"name":"SCN_BottleRigid","index":547,"parent":"SCN_BottleMount","local_position":[-0.008357482962310314,0.05373494699597359,0.0018820237601175904],"local_rotation_xyzw":[-1.4737754941009154e-08,1.0868028538622893e-06,-8.505881414508747e-08,0.9999999999994057],"local_scale":[1.0000000000023754,1.0000000000000153,1.0000000000023634]},{"name":"SCN_BottleRigid_Tip","index":548,"parent":"SCN_BottleRigid","local_position":[0.008572726510465145,0.0959077924489975,-0.0027420136611908674],"local_rotation_xyzw":[0.0,0.0,0.0,1.0],"local_scale":[1.0,1.0,1.0]}],"expected_runtime_mesh_sha256":"73a8e65beffb0ce5cde5ca1de1f0f87a0b21d6c88559218e03dcd003a6598207","calibration_input_mesh_sha256":"1056e1849dd78bddd611d9861ba7ddcd589d3a40eb46c9cbf4cb7ff5343f5084","source_layout":"Original CH_M_NA_961 body-source.npz, no D translation/taper/reroute","required_orientation_policy":"Pelvis rigid skin rotation times restored source bind; Venter/Hip input weights at both source ends are zero.","runtime_mesh_variants":[{"name":"hat","resource":"mods/scarlet_hat_static/6516e70211991f0b/body_mesh_2de4180b65dbe6b20a.mesh","sha256":"73a8e65beffb0ce5cde5ca1de1f0f87a0b21d6c88559218e03dcd003a6598207","native_body_id":7482},{"name":"no_hat","resource":"mods/scarlet_no_hat_static/67cc2ab84782dc5b/body_mesh_ae4e361f60ab521537.mesh","sha256":"ae4e361f60ab5215379d5cd65e9c1606564b09efc0f4e913f8ee3e779faa4270","native_body_id":28284}],"expected_runtime_mesh_identity_scope":"Primary calibration mesh. Admitted runtime variants are checked by the SDK backend and have identical bind/skin/anchor data."}]=])
local C=json.load_string([=[{"schema":"scarlet-native-adapter-contract-v1","entry":"UpdateConstraintsEnd","roles":["primary","actor_corrections","hand_gate_input","hand_gate","cloth_drivers","cloth_solve","cloth_actor_local","cloth_body_local_and_component_inputs","cloth_component_deltas","hip_response","cloth_actor_component"],"specs":[{"key":"pm_instance","type":"ace.GAElement`1<app.PlayerManager>","name":"get_Instance","params":[],"returns":"app.PlayerManager","is_static":true,"rva":109939872,"hook_only":false},{"key":"pm_info","type":"app.PlayerManager","name":"getControllingPlayer","params":[],"returns":"app.cPlayerManageInfo","is_static":false,"rva":77873440,"hook_only":false},{"key":"pm_ui","type":"app.PlayerManager","name":"getControllingPlayerUI","params":[],"returns":"via.GameObject","is_static":false,"rva":111300480,"hook_only":false},{"key":"pm_ui_ready","type":"app.PlayerManager","name":"isPlayerUICreateComplete","params":[],"returns":"System.Boolean","is_static":false,"rva":86942128,"hook_only":false},{"key":"pm_current","type":"app.PlayerManager","name":"isControllingPlayer","params":["via.GameObject"],"returns":"System.Boolean","is_static":false,"rva":111298048,"hook_only":false},{"key":"info_go","type":"app.cPlayerManageInfo","name":"get_Object","params":[],"returns":"via.GameObject","is_static":false,"rva":86045520,"hook_only":false},{"key":"info_entity","type":"app.cPlayerManageInfo","name":"get_CharacterEntity","params":[],"returns":"app.cPlayerCharacterEntity","is_static":false,"rva":94387552,"hook_only":false},{"key":"info_valid","type":"app.cPlayerManageInfo","name":"get_Valid","params":[],"returns":"System.Boolean","is_static":false,"rva":125839200,"hook_only":false},{"key":"component_go","type":"via.Component","name":"get_GameObject","params":[],"returns":"via.GameObject","is_static":false,"rva":94821856,"hook_only":false},{"key":"component_valid","type":"via.Component","name":"get_Valid","params":[],"returns":"System.Boolean","is_static":false,"rva":94763376,"hook_only":false},{"key":"go_valid","type":"via.GameObject","name":"get_Valid","params":[],"returns":"System.Boolean","is_static":false,"rva":94806192,"hook_only":false},{"key":"go_name","type":"via.GameObject","name":"get_Name","params":[],"returns":"System.String","is_static":false,"rva":97956448,"hook_only":false},{"key":"go_transform","type":"via.GameObject","name":"get_Transform","params":[],"returns":"via.Transform","is_static":false,"rva":97957552,"hook_only":false},{"key":"go_components","type":"via.GameObject","name":"get_Components","params":[],"returns":"via.Component[]","is_static":false,"rva":97957600,"hook_only":false},{"key":"go_draw","type":"via.GameObject","name":"get_Draw","params":[],"returns":"System.Boolean","is_static":false,"rva":97957216,"hook_only":false},{"key":"go_draw_self","type":"via.GameObject","name":"get_DrawSelf","params":[],"returns":"System.Boolean","is_static":false,"rva":97957376,"hook_only":false},{"key":"tr_child","type":"via.Transform","name":"get_Child","params":[],"returns":"via.Transform","is_static":false,"rva":94762288,"hook_only":false},{"key":"tr_next","type":"via.Transform","name":"get_Next","params":[],"returns":"via.Transform","is_static":false,"rva":94384720,"hook_only":false},{"key":"tr_parent","type":"via.Transform","name":"get_Parent","params":[],"returns":"via.Transform","is_static":false,"rva":125570976,"hook_only":false},{"key":"tr_joints","type":"via.Transform","name":"get_Joints","params":[],"returns":"via.Joint[]","is_static":false,"rva":125571280,"hook_only":false},{"key":"array_length","type":"System.Array","name":"GetLength","params":["System.Int32"],"returns":"System.Int32","is_static":false,"rva":114447776,"hook_only":false},{"key":"array_value","type":"System.Array","name":"GetValue","params":["System.Int32"],"returns":"System.Object","is_static":false,"rva":114447856,"hook_only":false},{"key":"mesh_holder","type":"via.render.Mesh","name":"getMesh","params":[],"returns":"via.render.MeshResourceHolder","is_static":false,"rva":122190144,"hook_only":false},{"key":"mesh_ready","type":"via.render.Mesh","name":"get_MeshReady","params":[],"returns":"System.Boolean","is_static":false,"rva":122191152,"hook_only":false},{"key":"mesh_enabled","type":"via.render.Mesh","name":"get_Enabled","params":[],"returns":"System.Boolean","is_static":false,"rva":101519712,"hook_only":false},{"key":"mesh_part","type":"via.render.Mesh","name":"getPartsEnable","params":["System.UInt64"],"returns":"System.Boolean","is_static":false,"rva":122190240,"hook_only":false},{"key":"resource_path","type":"via.ResourceHolder","name":"get_ResourcePath","params":[],"returns":"System.String","is_static":false,"rva":116635664,"hook_only":false},{"key":"jc_count","type":"via.motion.JointConstraints","name":"getLayerCount","params":[],"returns":"System.Int32","is_static":false,"rva":94883808,"hook_only":false},{"key":"jc_layer","type":"via.motion.JointConstraints","name":"getLayer","params":["System.Int32"],"returns":"via.motion.JointConstraintsLayer","is_static":false,"rva":104877744,"hook_only":false},{"key":"constraint_enabled","type":"via.motion.Constraint","name":"get_Enabled","params":[],"returns":"System.Boolean","is_static":false,"rva":94307760,"hook_only":false},{"key":"constraint_mode","type":"via.motion.Constraint","name":"get_UpdateMode","params":[],"returns":"via.motion.ConstraintsUpdateMode","is_static":false,"rva":94314832,"hook_only":false},{"key":"constraint_timing","type":"via.motion.Constraint","name":"get_UpdateTiming","params":[],"returns":"via.motion.ConstraintsUpdate","is_static":false,"rva":94314848,"hook_only":false},{"key":"jc_layer_enabled","type":"via.motion.JointConstraintsLayerBase","name":"get_Enable","params":[],"returns":"System.Boolean","is_static":false,"rva":100274000,"hook_only":false},{"key":"jc_layer_pause","type":"via.motion.JointConstraintsLayerBase","name":"get_Pause","params":[],"returns":"System.Boolean","is_static":false,"rva":100273968,"hook_only":false},{"key":"jc_layer_blend","type":"via.motion.JointConstraintsLayerBase","name":"get_BlendRate","params":[],"returns":"System.Single","is_static":false,"rva":96890048,"hook_only":false},{"key":"jc_layer_asset","type":"via.motion.JointConstraintsLayerBase","name":"get_JointConstraintsAsset","params":[],"returns":"via.motion.JointConstraintsResourceHolder","is_static":false,"rva":100274064,"hook_only":false},{"key":"jc_layer_override","type":"via.motion.JointConstraintsLayerBase","name":"get_EnabledOverrideUpdateTiming","params":[],"returns":"System.Boolean","is_static":false,"rva":100273936,"hook_only":false},{"key":"jc_layer_timing","type":"via.motion.JointConstraintsLayer","name":"get_OverrideUpdateTiming","params":[],"returns":"via.motion.ConstraintsUpdate","is_static":false,"rva":96902528,"hook_only":false},{"key":"joint_valid","type":"via.Joint","name":"get_Valid","params":[],"returns":"System.Boolean","is_static":false,"rva":94763376,"hook_only":false},{"key":"joint_name","type":"via.Joint","name":"get_Name","params":[],"returns":"System.String","is_static":false,"rva":109358608,"hook_only":false},{"key":"frame","type":"via.Application","name":"get_FrameCount","params":[],"returns":"System.UInt32","is_static":true,"rva":127698480,"mutates_native":false},{"key":"clock","type":"System.Diagnostics.Stopwatch","name":"GetTimestamp","params":[],"returns":"System.Int64","is_static":true,"rva":102410384,"mutates_native":false},{"key":"frequency","type":"System.Diagnostics.Stopwatch","name":"QueryPerformanceFrequency","params":[],"returns":"System.Int64","is_static":true,"rva":102410400,"mutates_native":false},{"key":"native_update","type":"via.motion.Constraint","name":"update","params":[],"returns":"System.Void","is_static":false,"rva":106024768,"mutates_native":true},{"key":"copy_scale","type":"via.motion.ConstraintJoints","name":"get_EnableScale","params":[],"returns":"System.Boolean","is_static":false,"rva":94766832,"mutates_native":false},{"key":"copy_source_go","type":"via.motion.ConstraintJoints","name":"get_ConstraintTargetGameObject","params":[],"returns":"via.GameObject","is_static":false,"rva":94762560,"mutates_native":false},{"key":"copy_set_source_go","type":"via.motion.ConstraintJoints","name":"set_ConstraintTargetGameObject","params":["via.GameObject"],"returns":"System.Void","is_static":false,"rva":122209568,"mutates_native":true},{"key":"row_source","type":"via.motion.ConstraintTargetJoint","name":"get_JointName","params":[],"returns":"System.String","is_static":false,"rva":120057920,"mutates_native":false},{"key":"row_target","type":"via.motion.ConstraintTargetJoint","name":"get_MyJointName","params":[],"returns":"System.String","is_static":false,"rva":120058176,"mutates_native":false},{"key":"row_position","type":"via.motion.ConstraintTargetJoint","name":"get_LocalPositionOffset","params":[],"returns":"via.vec3","is_static":false,"rva":94305392,"mutates_native":false},{"key":"row_rotation","type":"via.motion.ConstraintTargetJoint","name":"get_LocalRotationOffset","params":[],"returns":"via.Quaternion","is_static":false,"rva":94926448,"mutates_native":false},{"key":"chain_timing","type":"via.motion.SecondaryAnimation","name":"get_UpdateTiming","params":[],"returns":"via.motion.ExpressionUpdate","is_static":false,"rva":94348704,"mutates_native":false},{"key":"child_merged","type":"via.motion.ChildSecondary","name":"get_MergedSkeleton","params":[],"returns":"System.Boolean","is_static":false,"rva":99399376,"mutates_native":false},{"key":"same_joints","type":"via.Transform","name":"get_SameJointsConstraint","params":[],"returns":"System.Boolean","is_static":false,"rva":100273456,"mutates_native":false},{"key":"joint_parent","type":"via.Joint","name":"get_Parent","params":[],"returns":"via.Joint","is_static":false,"rva":109360368,"mutates_native":false},{"key":"joint_base_p","type":"via.Joint","name":"get_BaseLocalPosition","params":[],"returns":"via.vec3","is_static":false,"rva":109360528,"mutates_native":false},{"key":"joint_base_q","type":"via.Joint","name":"get_BaseLocalRotation","params":[],"returns":"via.Quaternion","is_static":false,"rva":109360624,"mutates_native":false},{"key":"joint_base_s","type":"via.Joint","name":"get_BaseLocalScale","params":[],"returns":"via.vec3","is_static":false,"rva":109360704,"mutates_native":false}],"crcs":{"ace.GAElement`1<app.PlayerManager>":437989116,"app.PlayerManager":346041440,"app.cPlayerManageInfo":3185740719,"via.Component":1881844667,"via.GameObject":4065074914,"via.Transform":1340992935,"System.Array":58605515,"via.render.Mesh":1829138609,"via.ResourceHolder":1072471267,"via.motion.JointConstraints":3198816904,"via.motion.Constraint":3990833109,"via.motion.JointConstraintsLayerBase":628620890,"via.motion.JointConstraintsLayer":1799083026,"via.Joint":1272281384,"via.Application":1896701499,"System.Diagnostics.Stopwatch":223667291,"via.motion.ConstraintJoints":2560794515,"via.motion.ConstraintTargetJoint":80507510,"via.motion.SecondaryAnimation":983439782,"via.motion.ChildSecondary":3993056455,"app.cEntityBase":2325337446,"via.motion.Chain2":2132214968,"System.UInt64":3170887894},"uint64_field":"m_value","body_path":"mods/scarlet_hat_static/6516e70211991f0b/body_mesh_2de4180b65dbe6b20a.mesh","preview_name":"Player_UI","actor_names":["root","Ground_Angle","COG","Hip","Spine_0","Spine_1","Spine_2","Chest_Mark","Neck_0","Neck_1","Head","R_Eye","L_Eye","L_Shoulder","L_UpperArm","L_Forearm","L_Hand","L_Wep","L_Weapon_ID","L_Wep_Mark","L_Wep_Mark_02","L_SubWep","L_Thumb1","L_Thumb2","L_Thumb3","L_IndexF1","L_IndexF2","L_IndexF3","L_MiddleF1","L_MiddleF2","L_MiddleF3","L_Palm","L_RingF1","L_RingF2","L_RingF3","L_PinkyF1","L_PinkyF2","L_PinkyF3","L_Attach_01","R_Shoulder","R_UpperArm","R_Forearm","R_Hand","R_Wep","R_Weapon_ID","R_Wep_Mark","R_Wep_Mark_02","R_SubWep","R_Thumb1","R_Thumb2","R_Thumb3","R_IndexF1","R_IndexF2","R_IndexF3","R_MiddleF1","R_MiddleF2","R_MiddleF3","R_Palm","R_RingF1","R_RingF2","R_RingF3","R_PinkyF1","R_PinkyF2","R_PinkyF3","R_Attach_01","R_eyeOffset_HJ_00_SCH","kote_eye_00_SCH","kote_eye_01_SCH","Control","Lookat","L_Thigh","L_Knee","L_Shin","L_Foot","L_Instep","L_Toe","R_Thigh","R_Knee","R_Shin","R_Foot","R_Instep","R_Toe","Katana_Yure_root","Katana_root","Saya_root","Wakizashi_Yure_root","Wakizashi_root","Wakizashi_Saya_root","Obi_Control_01","Obi_Control_02","SageoWakizashi_const","Attach","Attach_02","Root","Bip001","Bip001-Pelvis","Bip001-Spine","Bip001-Spine1","Bip001-Spine2","Bip001-Neck","Bip001-L-Clavicle","Bip001-L-UpperArm","Bip001-L-Forearm","Bip001-L-Hand","Bip001-L-Finger0","Bip001-L-Finger01","Bip001-L-Finger02","Bip001-L-Finger1","Bip001-L-Finger11","Bip001-L-Finger12","Bip001-L-Finger2","Bip001-L-Finger21","Bip001-L-Finger22","Bip001-L-Finger3","Bip001-L-Finger31","Bip001-L-Finger32","Bip001-L-Finger4","Bip001-L-Finger41","Bip001-L-Finger42","SC_BurstStanceConstraint","Ab-L-Forearm-Tw0","Ab-L-Forearm-Tw1","Dm-L-BrochiDn","Ab-L-BrochiDn","Ab_Drone_Ctl","Dm-L-UpperArm-Tw","Dm-L-Becep","Ab-L-Becep","Ab-L-UpperArm-Tw1","Ab-L-UpperArm-Tw0","Dm-L-Deltoid-A","Dm-L-Deltoid-Point","Ab-L-Deltoid","Dm-L-Elbow-Point","Dm-L-Elbow","Ab-L-Elbow","Dm-L-BrochiUp","Ab-L-BrochiUp","Ab-L-Tricep","Dm-L-Side-Point","Ab-L-Side","Ab-L-Shoulder1","Bip001-R-Clavicle","Bip001-R-UpperArm","Bip001-R-Forearm","Bip001-R-Hand","Bip001-R-Finger0","Bip001-R-Finger01","Bip001-R-Finger02","Bip001-R-Finger1","Bip001-R-Finger11","Bip001-R-Finger12","Bip001-R-Finger2","Bip001-R-Finger21","Bip001-R-Finger22","Bip001-R-Finger3","Bip001-R-Finger31","Bip001-R-Finger32","Bip001-R-Finger4","Bip001-R-Finger41","Bip001-R-Finger42","SC_WeaponConstraint","Ab-R-Forearm-Tw0","Ab-R-Forearm-Tw1","Dm-R-BrochiDn","Ab-R-BrochiDn","Dm-R-Elbow-Point","Dm-R-Elbow","Ab-R-Elbow","Dm-R-BrochiUp","Ab-R-BrochiUp","Dm-R-UpperArm-Tw","Dm-R-Becep","Ab-R-Becep","Ab-R-UpperArm-Tw0","Ab-R-UpperArm-Tw1","Ab-R-Tricep","Dm-R-Deltoid-A","Dm-R-Deltoid-Point","Ab-R-Deltoid","Dm-R-Side-Point","Ab-R-Side","Ab-R-Shoulder1","Bip001-Head","Ab-TL-HairB01","Ab-TL-HairB02","Ab-TL-HairB03","Ab-TL-HairB04","Ab-TL-HairB05","Ab-TL-HairB06","Ab-TL-HairB07","Ab-TL-HairB08","Ab-TL-HairB09","Ab_Hat_A_01","Ab-NeckSub","Ab-L-Shoulder0","Ab-L-Trape0","Ab-L-Trape1","Ab-L-Pectro0","Ab-L-Pectro1","Ab-R-Pectro0","Ab-R-Pectro1","Ab-R-Shoulder0","Ab-R-Trape0","Ab-R-Trape1","Dm-L-Breast-Point","Dm-L-Breast","Ab-L-Breast-Link","Ab-L-Breast","Dm-R-Breast-Point","Dm-R-Breast","Ab-R-Breast-Link","Ab-R-Breast","Bip001-L-Thigh","Bip001-L-Calf","Bip001-L-Foot","Bip001-L-Toe0","Ab-L-Calf-Tw1","Ab-L-Calf-Tw0","Ab-L-Ankle","Ab-L-Knee","Ab-L-Thigh-Tw0","Ab-L-Hip","Ab-L-Hip-Reg","Dm-L-Knee","Dm-L-Knee-Sub","Ab-L-Knee-SubA","Ab-L-Knee-SubB","Dm-L-Venter-A","Ab-L-Venter2","Ab_SkirtL_S01","Ab_SkirtL_S02","Ab_SkirtL_S03","Ab_SkirtL_S04","Ab-L-Thigh-Tw1","Bip001-R-Thigh","Bip001-R-Calf","Bip001-R-Foot","Bip001-R-Toe0","Ab-R-Calf-Tw1","Ab-R-Calf-Tw0","Ab-R-Ankle","Ab-R-Thigh-Tw1","Ab-R-Thigh-Tw0","Ab-R-Knee","Dm-R-Knee","Dm-R-Knee-Sub","Ab-R-Knee-SubA","Ab-R-Knee-SubB","Dm-R-Venter-A","Ab-R-Venter2","Ab-R-Hip","Ab-R-Hip-Reg","Dm-L-Thigh-point","Ab-L-Venter","Dm-R-Thigh-point","Ab-R-Venter","Ab-Fr-SuiteA-01","Ab-R-SkirtA-01","Ab-L-SkirtA-01","Bip001-Prop1","Bip001-Prop2","SC_LinkTarget","SCN_BottleMount"],"body_names":["root","Ground_Angle","COG","Hip","Spine_0","Spine_1","Spine_2","Chest_Mark","Neck_0","Neck_1","Head","R_Eye","L_Eye","L_Shoulder","L_UpperArm","L_Forearm","L_Hand","L_Wep","L_Weapon_ID","L_Wep_Mark","L_Wep_Mark_02","L_SubWep","L_Thumb1","L_Thumb2","L_Thumb3","L_IndexF1","L_IndexF2","L_IndexF3","L_MiddleF1","L_MiddleF2","L_MiddleF3","L_Palm","L_RingF1","L_RingF2","L_RingF3","L_PinkyF1","L_PinkyF2","L_PinkyF3","L_Attach_01","R_Shoulder","R_UpperArm","R_Forearm","R_Hand","R_Wep","R_Weapon_ID","R_Wep_Mark","R_Wep_Mark_02","R_SubWep","R_Thumb1","R_Thumb2","R_Thumb3","R_IndexF1","R_IndexF2","R_IndexF3","R_MiddleF1","R_MiddleF2","R_MiddleF3","R_Palm","R_RingF1","R_RingF2","R_RingF3","R_PinkyF1","R_PinkyF2","R_PinkyF3","R_Attach_01","R_eyeOffset_HJ_00_SCH","kote_eye_00_SCH","kote_eye_01_SCH","Control","Lookat","L_Thigh","L_Knee","L_Shin","L_Foot","L_Instep","L_Toe","R_Thigh","R_Knee","R_Shin","R_Foot","R_Instep","R_Toe","Katana_Yure_root","Katana_root","Saya_root","Wakizashi_Yure_root","Wakizashi_root","Wakizashi_Saya_root","Obi_Control_01","Obi_Control_02","SageoWakizashi_const","Attach","Attach_02","Root","Bip001","Bip001-Pelvis","Bip001-Spine","Bip001-Spine1","Bip001-Spine2","Bip001-Neck","Bip001-L-Clavicle","Bip001-L-UpperArm","Bip001-L-Forearm","Bip001-L-Hand","Bip001-L-Finger0","Bip001-L-Finger01","Bip001-L-Finger02","Bip001-L-Finger1","Bip001-L-Finger11","Bip001-L-Finger12","Bip001-L-Finger2","Bip001-L-Finger21","Bip001-L-Finger22","Bip001-L-Finger3","Bip001-L-Finger31","Bip001-L-Finger32","Bip001-L-Finger4","Bip001-L-Finger41","Bip001-L-Finger42","SC_BurstStanceConstraint","Ab-L-Forearm-Tw0","Ab-L-Forearm-Tw1","Dm-L-BrochiDn","Ab-L-BrochiDn","Ab_Drone_Ctl","Dm-L-UpperArm-Tw","Dm-L-Becep","Ab-L-Becep","Ab-L-UpperArm-Tw1","Ab-L-UpperArm-Ribbon-Root","Ab-L-UpperArm-Tw0","Dm-L-Deltoid-A","Dm-L-Deltoid-Point","Ab-L-Deltoid","Dm-L-Elbow-Point","Dm-L-Elbow","Ab-L-Elbow","Dm-L-BrochiUp","Ab-L-BrochiUp","Ab-L-Tricep","Dm-L-Side-Point","Ab-L-Side","Ab-L-Shoulder1","Bip001-R-Clavicle","Bip001-R-UpperArm","Bip001-R-Forearm","Bip001-R-Hand","Bip001-R-Finger0","Bip001-R-Finger01","Bip001-R-Finger02","Bip001-R-Finger1","Bip001-R-Finger11","Bip001-R-Finger12","Bip001-R-Finger2","Bip001-R-Finger21","Bip001-R-Finger22","Bip001-R-Finger3","Bip001-R-Finger31","Bip001-R-Finger32","Bip001-R-Finger4","Bip001-R-Finger41","Bip001-R-Finger42","SC_WeaponConstraint","Ab-R-Forearm-Tw0","Ab-R-Forearm-Tw1","Dm-R-BrochiDn","Ab-R-BrochiDn","Dm-R-Elbow-Point","Dm-R-Elbow","Ab-R-Elbow","Dm-R-BrochiUp","Ab-R-BrochiUp","Dm-R-UpperArm-Tw","Dm-R-Becep","Ab-R-Becep","Ab-R-UpperArm-Tw0","Ab-R-UpperArm-Tw1","Ab-R-Tricep","Dm-R-Deltoid-A","Dm-R-Deltoid-Point","Ab-R-Deltoid","Dm-R-Side-Point","Ab-R-Side","Ab-R-Shoulder1","Bip001-Head","Ab-TL-HairB01","Ab-TL-HairB02","Ab-TL-HairB03","Ab-TL-HairB04","Ab-TL-HairB05","Ab-TL-HairB06","Ab-TL-HairB07","Ab-TL-HairB08","Ab-TL-HairB09","Ab_Hat_A_01","Ab_Hat_L_String_01","Ab_Hat_L_String_02","Ab_Hat_L_String_03","Ab_Hat_R_String_01","Ab_Hat_R_String_02","Ab_Hat_R_String_03","Ab_Hat_StrapA_01","Ab_Hat_StrapA_02","Ab_Hat_StrapA_03","Ab_Hat_StrapA_06","Ab_Hat_StrapA_04","Ab_Hat_StrapB_01","Ab_Hat_StrapB_02","Ab_Hat_StrapB_03","Ab_Hat_StrapB_04","Ab_HatAcc_A_01","Ab_HatAcc_A_02","Ab_HatAcc_D_01","Ab_HatAcc_E_01","Ab_HatAcc_F_01","Ab_HatAcc_G_01","Ab_HatAcc_G_02","Ab_HatAcc_G_03","Ab_HatFur_L_Root","Ab_HatFur_L_E_01","Ab_HatFur_L_D_01","Ab_HatFur_L_C_01","Ab_HatFur_L_B_01","Ab_HatFur_L_A_01","Ab_HatFur_R_Root","Ab_HatFur_R_B_Root","Ab_HatFur_R_B_03","Ab_HatFur_R_B_03_End","Ab_HatFur_R_B_02","Ab_HatFur_R_B_02_End","Ab_HatFur_R_B_01","Ab_HatFur_R_B_01_End","Ab_HatFur_R_A_Root","Ab_HatFur_R_A_02","Ab_HatFur_R_A_03","Ab_Hair_Bc","Ab_Hair_Bc_L_01","Ab_Hair_Bc_L_02","Ab_Hair_Bc_L_03","Ab_Hair_Bc_L_04","Ab_Hair_Bc_L_05","Ab_Hair_Bc_L_06","Ab_Hair_Bc_L_07","Ab_Hair_Bc_L_08","Ab_Hair_Bc_L_09","Ab_Hair_Bc_LL_01","Ab_Hair_Bc_LL_02","Ab_Hair_Bc_LL_03","Ab_Hair_Bc_LL_04","Ab_Hair_Bc_LL_05","Ab_Hair_Bc_LL_06","Ab_Hair_Bc_LL_07","Ab_Hair_Bc_LL_08","Ab_Hair_Bc_LL_09","Ab_Hair_Bc_R_01","Ab_Hair_Bc_R_02","Ab_Hair_Bc_R_03","Ab_Hair_Bc_R_04","Ab_Hair_Bc_R_05","Ab_Hair_Bc_R_06","Ab_Hair_Bc_R_07","Ab_Hair_Bc_R_08","Ab_Hair_Bc_R_09","Ab_Hair_Bc_RR_01","Ab_Hair_Bc_RR_02","Ab_Hair_Bc_RR_03","Ab_Hair_Bc_RR_04","Ab_Hair_Bc_RR_05","Ab_Hair_Bc_RR_06","Ab_Hair_Bc_RR_07","Ab_Hair_Bc_RR_08","Ab_Hair_Bc_RR_09","Ab_LongHair_A_01","Ab_LongHair_A_02","Ab_LongHair_A_03","Ab_LongHair_A_04","Ab_LongHair_A_05","Ab_LongHair_A_06","Ab_LongHair_A_07","Ab_LongHair_A_08","Ab_LongHair_A_09","Ab_LongHair_A_10","Ab_LongHair_A_11","Ab_LongHair_B_01","Ab_LongHair_B_02","Ab_LongHair_B_03","Ab_LongHair_B_04","Ab_LongHair_B_05","Ab_LongHair_B_06","Ab_LongHair_B_07","Ab_LongHair_B_08","Ab_LongHair_B_09","Ab_LongHair_B_10","Ab_LongHair_B_11","Ab_LongHair_C_01","Ab_LongHair_C_02","Ab_LongHair_C_03","Ab_LongHair_C_04","Ab_LongHair_C_05","Ab_LongHair_C_06","Ab_LongHair_C_07","Ab_LongHair_C_08","Ab_LongHair_C_09","Ab_LongHair_C_10","Ab_LongHair_C_11","Ab_LongHair_D_01","Ab_LongHair_D_02","Ab_LongHair_D_03","Ab_LongHair_D_04","Ab_LongHair_D_05","Ab_LongHair_D_06","Ab_LongHair_D_07","Ab_LongHair_D_08","Ab_LongHair_D_09","Ab_LongHair_D_10","Ab_LongHair_D_11","Ab_Hair_exLl_01","Ab_Hair_exLl_02","Ab_Hair_exLl_03","Ab_Hair_exR_01","Ab_Hair_exR_02","Ab_Hair_exR_03","Ab_Hair_exR_04","Ab_Hair_exR_05","Ab_Hair_Fr_01","Ab_Hair_Fr_02","Ab_Hair_Fr_03","Ab_Hair_Fr_04","Ab_Hair_Fr_L_01","Ab_Hair_Fr_L_02","Ab_Hair_Fr_L_03","Ab_Hair_Fr_L_04","Ab_Hair_Fr_R_01","Ab_Hair_Fr_R_02","Ab_Hair_Fr_R_03","Ab_Hair_Fr_R_04","Ab_Hair_Side_l_01","Ab_Hair_Side_l_02","Ab_Hair_Side_l_03","Ab_Hair_Side_l_04","Ab_Hair_Side_l_05","Ab_Hair_Side_l_06","Ab_Hair_Side_LL_01","Ab_Hair_Side_LL_02","Ab_Hair_Side_LL_03","Ab_Hair_Side_LL_04","Ab_Hair_Side_LL_05","Ab_Hair_Side_LL_06","Ab_Hair_Side_R_01","Ab_Hair_Side_R_02","Ab_Hair_Side_R_03","Ab_Hair_Side_R_04","Ab_Hair_Side_R_05","Ab_Hair_Side_R_06","Ab_Hair_Side_RR_01","Ab_Hair_Side_RR_02","Ab_Hair_Side_RR_03","Ab_Hair_Side_RR_04","Ab_Hair_Side_RR_05","Ab_Hair_Side_RR_06","Ab_ShortHair_L_01","Ab_ShortHair_L_02","Ab_ShortHair_L_03","Ab_ShortHair_L_04","Ab_ShortHair_L_05","Ab_ShortHair_L_06","Ab_ShortHair_M_01","Ab_ShortHair_M_02","Ab_ShortHair_M_03","Ab_ShortHair_M_04","Ab_ShortHair_M_05","Ab_ShortHair_M_06","Ab_ShortHair_R_01","Ab_ShortHair_R_02","Ab_ShortHair_R_03","Ab_ShortHair_R_04","Ab_ShortHair_R_05","Ab_ShortHair_R_06","Ab-NeckSub","Ab-L-Shoulder0","Ab-L-Trape0","Ab-L-Trape1","Ab-L-Pectro0","Ab-L-Pectro1","Ab-R-Pectro0","Ab-R-Pectro1","Ab-R-Shoulder0","Ab-R-Trape0","Ab-R-Trape1","Dm-L-Breast-Point","Dm-L-Breast","Ab-L-Breast-Link","Ab-L-Breast","Ab-L-Breast-String1","Ab-L-Breast-String2","Dm-R-Breast-Point","Dm-R-Breast","Ab-R-Breast-Link","Ab-R-Breast","Ab-R-Breast-String1","Bip001-L-Thigh","Bip001-L-Calf","Bip001-L-Foot","Bip001-L-Toe0","Ab-L-Calf-Tw1","Ab-L-Calf-Tw0","Ab-L-Ankle","Ab-L-Knee","Ab-L-Thigh-Tw0","Ab-L-Hip","Ab-L-Hip-Reg","Dm-L-Knee","Dm-L-Knee-Sub","Ab-L-Knee-SubA","Ab-L-Knee-SubB","Dm-L-Venter-A","Ab-L-Venter2","Ab_SkirtL_S01","Ab_SkirtL_S02","Ab_SkirtL_S03","Ab_SkirtL_S04","Ab-L-Thigh-Tw1","Bip001-R-Thigh","Bip001-R-Calf","Bip001-R-Foot","Bip001-R-Toe0","Ab-R-Calf-Tw1","Ab-R-Calf-Tw0","Ab-R-Ankle","Ab-R-Thigh-Tw1","Ab_RV_ACC_R01","Ab_RV_ACC_R02","Ab-R-Thigh-Tw0","Ab-R-Knee","Dm-R-Knee","Dm-R-Knee-Sub","Ab-R-Knee-SubA","Ab-R-Knee-SubB","Dm-R-Venter-A","Ab-R-Venter2","Ab-R-SkirtE-01","Ab-R-Hip","Ab-R-Hip-Reg","Dm-L-Thigh-point","Ab-L-Venter","Dm-R-Thigh-point","Ab-R-Venter","Ab-R-SkirtQ-01","Ab-R-SkirtQ-02","Ab-R-SkirtQ-03","Ab-R-SkirtQ-04","Ab-R-SkirtQ-05","Ab-R-SkirtQ-AccA_01","Ab-R-SkirtQ-AccA_02","Ab-R-SkirtQ-AccB_01","Ab-R-SkirtQ-AccB_02","Ab-Fr-SuiteA-01","Ab-R-SkirtA-01","Ab_Tail00","Ab_Tail01","Ab_Tail02","Ab_Tail03","Ab_Tail04","Ab_Tail05","Ab_Tail06","Ab_Tail07","Ab_Tail08","Ab_Tail09","Ab_Tail03_Acc01","Ab_Tail03_Acc02","Ab_Tail03_Acc03","Ab_Tail03_Acc04","Ab-L-SkirtA-01","Ab-L-SkirtA-02","Ab-L-SkirtA-03","Ab-L-SkirtA-04","Ab-L-SkirtA-05","Ab-L-SkirtA-06","Ab-L-SkirtA-07","Ab-L-SkirtA-08","Ab-L-SkirtA-09","Ab-L-SkirtA-10","Ab-L-SkirtA-11","Ab-L-SkirtA-AccA_01","Ab-L-SkirtA-AccA_02","Ab-L-SkirtA-AccB_01","Ab-L-SkirtA-AccB_02","Ab-L-SkirtA-AccB_03","Ab-L-SkirtA-AccB_04","Ab-L-SkirtAA-01","Ab-L-SkirtAA-02","Bip001-Prop1","Bip001-Prop2","SC_LinkTarget","SCN_Ab-L-UpperArm-Ribbon-Root_Tip","SCN_Ab_Hat_L_String_03_Tip","SCN_Ab_Hat_R_String_03_Tip","SCN_Ab_Hat_StrapA_06_Tip","SCN_Ab_Hat_StrapA_04_Tip","SCN_Ab_Hat_StrapB_04_Tip","SCN_Ab_HatAcc_A_02_Tip","SCN_Ab_HatAcc_D_01_Tip","SCN_Ab_HatAcc_E_01_Tip","SCN_Ab_HatAcc_F_01_Tip","SCN_Ab_HatAcc_G_03_Tip","SCN_Ab_HatFur_L_E_01_Tip","SCN_Ab_HatFur_L_D_01_Tip","SCN_Ab_HatFur_L_C_01_Tip","SCN_Ab_HatFur_L_B_01_Tip","SCN_Ab_HatFur_L_A_01_Tip","SCN_Ab_HatFur_R_B_03_End_Tip","SCN_Ab_HatFur_R_B_02_End_Tip","SCN_Ab_HatFur_R_B_01_End_Tip","SCN_Ab_HatFur_R_A_03_Tip","SCN_Ab_LongHair_A_11_Tip","SCN_Ab_Hair_Bc_L_09_Tip","SCN_Ab_Hair_Bc_LL_09_Tip","SCN_Ab_Hair_Bc_R_09_Tip","SCN_Ab_Hair_Bc_RR_09_Tip","SCN_Ab_LongHair_B_11_Tip","SCN_Ab_LongHair_C_11_Tip","SCN_Ab_LongHair_D_11_Tip","SCN_Ab_Hair_exLl_03_Tip","SCN_Ab_Hair_exR_05_Tip","SCN_Ab_Hair_Fr_04_Tip","SCN_Ab_Hair_Fr_L_04_Tip","SCN_Ab_Hair_Fr_R_04_Tip","SCN_Ab_Hair_Side_l_06_Tip","SCN_Ab_Hair_Side_LL_06_Tip","SCN_Ab_Hair_Side_R_06_Tip","SCN_Ab_Hair_Side_RR_06_Tip","SCN_Ab_ShortHair_L_06_Tip","SCN_Ab_ShortHair_M_06_Tip","SCN_Ab_ShortHair_R_06_Tip","SCN_Ab-L-Breast-String2_Tip","SCN_Ab-R-Breast-String1_Tip","SCN_Ab-R-SkirtE-01_Tip","SCN_Ab-R-SkirtQ-05_Tip","SCN_Ab-R-SkirtQ-AccA_02_Tip","SCN_Ab-R-SkirtQ-AccB_02_Tip","SCN_Ab_Tail09_Tip","SCN_Ab_Tail03_Acc04_Tip","SCN_Ab-L-SkirtA-11_Tip","SCN_Ab-L-SkirtA-AccA_02_Tip","SCN_Ab-L-SkirtA-AccB_04_Tip","SCN_Ab-L-SkirtAA-02_Tip","SCN_BottleMount","SCN_BottleRigid","SCN_BottleRigid_Tip","SC_ClothInput","SC_ClothReg_00","SC_ClothReg_01","SC_ClothReg_02","SC_ClothReg_03","SC_ClothReg_04","SC_ClothReg_05","SC_ClothReg_06","SC_ClothReg_07","SC_ClothReg_08","SC_ClothReg_09","SC_ClothReg_10","SC_ClothReg_11","SC_ClothReg_12","SC_ClothReg_13","SC_ClothReg_14","SC_ClothReg_15","SC_ClothReg_16","SC_ClothReg_17","SC_ClothReg_18","SC_ClothReg_19","SC_ClothReg_20","SC_ClothReg_21","SC_ClothReg_22","SC_ClothReg_23","SC_ClothReg_24","SC_ClothReg_25","SC_ClothEulerProbe"],"carriers":[{"index":549,"name":"SC_ClothInput","parent":"Ab-L-Thigh-Tw0","position":[0.0,0.0,0.0],"rotation":[-1.4294258221525238e-08,0.99999999999998,-8.570495424464582e-08,1.8041455973616034e-07]},{"index":550,"name":"SC_ClothReg_00","parent":"root","position":[0.0,0.0,0.0],"rotation":[0.0,0.0,0.0,1.0]},{"index":551,"name":"SC_ClothReg_01","parent":"root","position":[0.0,0.0,0.0],"rotation":[0.0,0.0,0.0,1.0]},{"index":552,"name":"SC_ClothReg_02","parent":"Bip001-Pelvis","position":[0.09009460359811783,0.07193106412887573,0.07368378341197968],"rotation":[1.6199783203773613e-07,0.999999999999968,1.439264138980388e-07,1.3059418790816872e-07]},{"index":553,"name":"SC_ClothReg_03","parent":"Bip001-Pelvis","position":[-0.08263015747070312,0.07433365285396576,0.07515805959701538],"rotation":[1.6199783203773613e-07,0.999999999999968,1.439264138980388e-07,1.3059418790816872e-07]},{"index":554,"name":"SC_ClothReg_04","parent":"Bip001-Pelvis","position":[-1.861837404248945e-07,0.06965579837560654,0.0860859602689743],"rotation":[1.6199783203773613e-07,0.999999999999968,1.439264138980388e-07,1.3059418790816872e-07]},{"index":555,"name":"SC_ClothReg_05","parent":"root","position":[0.0,0.0,0.0],"rotation":[0.0,0.0,0.0,1.0]},{"index":556,"name":"SC_ClothReg_06","parent":"root","position":[0.0,0.0,0.0],"rotation":[0.0,0.0,0.0,1.0]},{"index":557,"name":"SC_ClothReg_07","parent":"root","position":[0.0,0.0,0.0],"rotation":[0.0,0.0,0.0,1.0]},{"index":558,"name":"SC_ClothReg_08","parent":"root","position":[0.0,0.0,0.0],"rotation":[0.0,0.0,0.0,1.0]},{"index":559,"name":"SC_ClothReg_09","parent":"Bip001-Pelvis","position":[-0.10279758274555206,0.010505284182727337,-0.13788877427577972],"rotation":[1.6199783203773613e-07,0.999999999999968,1.439264138980388e-07,1.3059418790816872e-07]},{"index":560,"name":"SC_ClothReg_10","parent":"root","position":[0.0,0.0,0.0],"rotation":[0.0,0.0,0.0,1.0]},{"index":561,"name":"SC_ClothReg_11","parent":"Ab-R-SkirtQ-01","position":[4.051786390846246e-07,0.0900006964802742,7.302706421796756e-07],"rotation":[3.7815470932060416e-07,0.9999999999700164,7.706828455182745e-07,-7.696120518838448e-06]},{"index":562,"name":"SC_ClothReg_12","parent":"Ab-L-SkirtA-01","position":[-0.03717386722564697,0.1398916244506836,0.012675289995968342],"rotation":[1.3327404246864835e-07,0.9999999999999407,-2.997516332925265e-07,-1.0533494787522898e-07]},{"index":563,"name":"SC_ClothReg_13","parent":"root","position":[0.0,0.0,0.0],"rotation":[0.0,0.0,0.0,1.0]},{"index":564,"name":"SC_ClothReg_14","parent":"Ab-L-Venter2","position":[0.017003115266561508,0.06657295674085617,-0.073796845972538],"rotation":[-8.615091360292936e-07,0.9999999999994342,5.407413254940035e-07,-3.111685771271427e-07]},{"index":565,"name":"SC_ClothReg_15","parent":"root","position":[0.0,0.0,0.0],"rotation":[0.0,0.0,0.0,1.0]},{"index":566,"name":"SC_ClothReg_16","parent":"root","position":[0.0,0.0,0.0],"rotation":[0.0,0.0,0.0,1.0]},{"index":567,"name":"SC_ClothReg_17","parent":"root","position":[0.0,0.0,0.0],"rotation":[0.0,0.0,0.0,1.0]},{"index":568,"name":"SC_ClothReg_18","parent":"root","position":[0.0,0.0,0.0],"rotation":[0.0,0.0,0.0,1.0]},{"index":569,"name":"SC_ClothReg_19","parent":"root","position":[0.0,0.0,0.0],"rotation":[0.0,0.0,0.0,1.0]},{"index":570,"name":"SC_ClothReg_20","parent":"root","position":[0.0,0.0,0.0],"rotation":[0.0,0.0,0.0,1.0]},{"index":571,"name":"SC_ClothReg_21","parent":"root","position":[0.0,0.0,0.0],"rotation":[0.0,0.0,0.0,1.0]},{"index":572,"name":"SC_ClothReg_22","parent":"root","position":[0.0,0.0,0.0],"rotation":[0.0,0.0,0.0,1.0]},{"index":573,"name":"SC_ClothReg_23","parent":"root","position":[0.0,0.0,0.0],"rotation":[0.0,0.0,0.0,1.0]},{"index":574,"name":"SC_ClothReg_24","parent":"root","position":[0.0,0.0,0.0],"rotation":[0.0,0.0,0.0,1.0]},{"index":575,"name":"SC_ClothReg_25","parent":"Ab-R-Hip","position":[-7.450580596923828e-08,-3.725290298461914e-09,5.960464477539063e-08],"rotation":[1.9152411741190245e-08,8.889438429262235e-08,3.851567913578332e-09,0.9999999999999959]},{"index":576,"name":"SC_ClothEulerProbe","parent":"Ab-R-Thigh-Tw0","position":[0.0,0.0,0.0],"rotation":[2.944516666047308e-07,0.9999999999997642,-2.392530120686733e-07,-5.724453444598581e-07]}],"profiles":{"player":{"primary":{"type":"via.motion.ConstraintJoints","kind":"copy","source_owner":"self","rows":[{"JointName":"Hip","MyJointName":"Bip001","LocalPositionOffset":[-5.6231975e-10,0,0],"LocalRotationOffset":[0.5000003,0.5000004,0.49999982,0.49999943]},{"JointName":"Hip","MyJointName":"Bip001-Pelvis","LocalPositionOffset":[0,0,0],"LocalRotationOffset":[6.938973e-07,7.823725e-07,9.2064147e-07,1]},{"JointName":"Spine_0","MyJointName":"Bip001-Spine","LocalPositionOffset":[0,0,0],"LocalRotationOffset":[0.037175715,-1.3210986e-06,1.662345e-07,0.99930876]},{"JointName":"Spine_1","MyJointName":"Bip001-Spine1","LocalPositionOffset":[0,-2.220446e-16,0],"LocalRotationOffset":[0.03504491,-1.4394763e-06,2.40052e-07,0.9993857]},{"JointName":"Spine_2","MyJointName":"Bip001-Spine2","LocalPositionOffset":[0,-2.220446e-16,-1.3877788e-17],"LocalRotationOffset":[-0.020661052,-1.5219715e-06,3.372787e-07,0.99978656]},{"JointName":"Neck_1","MyJointName":"Bip001-Neck","LocalPositionOffset":[0,-2.220446e-16,0],"LocalRotationOffset":[0.0027740933,-6.48652e-05,1.4450286e-05,0.9999961]},{"JointName":"L_Shoulder","MyJointName":"Bip001-L-Clavicle","LocalPositionOffset":[5.035316e-17,2.1709979e-16,-2.015976e-17],"LocalRotationOffset":[0.6883895,0.704713,-0.16161868,-0.058128905]},{"JointName":"L_UpperArm","MyJointName":"Bip001-L-UpperArm","LocalPositionOffset":[2.0884855e-16,7.181397e-17,2.2996536e-17],"LocalRotationOffset":[0.7065995,0.70659935,-0.02678197,0.026782004]},{"JointName":"L_Forearm","MyJointName":"Bip001-L-Forearm","LocalPositionOffset":[2.7222593e-16,-1.4899995e-16,5.5407982e-17],"LocalRotationOffset":[0.7042214,0.7042213,-0.06381417,0.06381413]},{"JointName":"L_Hand","MyJointName":"Bip001-L-Hand","LocalPositionOffset":[1.8699692e-17,1.2532665e-18,-8.113014e-17],"LocalRotationOffset":[-0.5289637,-0.5145987,0.5063656,-0.44607115]},{"JointName":"L_Thumb1","MyJointName":"Bip001-L-Finger0","LocalPositionOffset":[-1.9554121e-17,-1.5630995e-16,5.40206e-17],"LocalRotationOffset":[0.69670606,0.7057887,0.120832875,-0.04315547]},{"JointName":"L_Thumb2","MyJointName":"Bip001-L-Finger01","LocalPositionOffset":[5.588321e-17,-9.5666614e-17,7.1356115e-18],"LocalRotationOffset":[0.7029808,0.7029812,0.0762738,-0.07627372]},{"JointName":"L_Thumb3","MyJointName":"Bip001-L-Finger02","LocalPositionOffset":[9.6586684e-17,-6.9836933e-17,3.4659106e-17],"LocalRotationOffset":[0.6899735,0.7152633,-0.030870873,-0.10668665]},{"JointName":"L_IndexF1","MyJointName":"Bip001-L-Finger1","LocalPositionOffset":[1.01854514e-16,4.8142716e-17,2.0106223e-17],"LocalRotationOffset":[-0.52520734,-0.5252066,0.4734532,-0.47345257]},{"JointName":"L_IndexF2","MyJointName":"Bip001-L-Finger11","LocalPositionOffset":[8.2267056e-17,3.625238e-17,7.0811154e-17],"LocalRotationOffset":[-0.52461296,-0.52461267,0.4741114,-0.47411093]},{"JointName":"L_IndexF3","MyJointName":"Bip001-L-Finger12","LocalPositionOffset":[3.4480547e-17,1.3404772e-16,7.9149075e-17],"LocalRotationOffset":[-0.52156836,-0.52747077,0.47557396,-0.4728324]},{"JointName":"L_MiddleF1","MyJointName":"Bip001-L-Finger2","LocalPositionOffset":[-3.298688e-17,1.0582947e-16,-2.843083e-17],"LocalRotationOffset":[-0.5082929,-0.50829333,0.49156672,-0.49156725]},{"JointName":"L_MiddleF2","MyJointName":"Bip001-L-Finger21","LocalPositionOffset":[-8.226735e-17,-6.811669e-17,-3.0301016e-17],"LocalRotationOffset":[-0.4950198,-0.49501947,0.5049314,-0.5049311]},{"JointName":"L_MiddleF3","MyJointName":"Bip001-L-Finger22","LocalPositionOffset":[8.0144563e-17,6.4979815e-17,4.327836e-17],"LocalRotationOffset":[-0.53766775,-0.44870976,0.5457066,-0.46019262]},{"JointName":"L_RingF1","MyJointName":"Bip001-L-Finger3","LocalPositionOffset":[-1.0052419e-16,-4.5977726e-17,-1.730551e-17],"LocalRotationOffset":[-0.557717,-0.55771697,0.4346858,-0.4346858]},{"JointName":"L_RingF2","MyJointName":"Bip001-L-Finger31","LocalPositionOffset":[-1.5152743e-16,-8.874186e-18,-4.8815584e-17],"LocalRotationOffset":[-0.5545672,-0.5545669,0.43869737,-0.4386973]},{"JointName":"L_RingF3","MyJointName":"Bip001-L-Finger32","LocalPositionOffset":[-6.463202e-17,-8.203937e-17,-3.7658933e-17],"LocalRotationOffset":[-0.58604217,-0.5172642,0.4924107,-0.38278455]},{"JointName":"L_PinkyF1","MyJointName":"Bip001-L-Finger4","LocalPositionOffset":[-2.5967735e-18,-5.1768317e-18,1.9994785e-17],"LocalRotationOffset":[-0.52517027,-0.52517027,0.47349387,-0.47349334]},{"JointName":"L_PinkyF2","MyJointName":"Bip001-L-Finger41","LocalPositionOffset":[-1.5644794e-16,-5.620235e-18,-1.38746586e-17],"LocalRotationOffset":[-0.5240061,-0.52400804,0.47477886,-0.47478223]},{"JointName":"L_PinkyF3","MyJointName":"Bip001-L-Finger42","LocalPositionOffset":[0,0,0],"LocalRotationOffset":[-0.5769056,-0.46212032,0.5391933,-0.40360293]},{"JointName":"R_Shoulder","MyJointName":"Bip001-R-Clavicle","LocalPositionOffset":[0,0,0],"LocalRotationOffset":[-0.6883865,0.70471436,-0.1616293,0.058118027]},{"JointName":"R_UpperArm","MyJointName":"Bip001-R-UpperArm","LocalPositionOffset":[-2.8066355e-16,-1.3826117e-16,2.6822326e-17],"LocalRotationOffset":[0.70659906,-0.70659924,0.026789254,0.026789235]},{"JointName":"R_Forearm","MyJointName":"Bip001-R-Forearm","LocalPositionOffset":[-6.705804e-17,-2.1213478e-16,-2.4004836e-17],"LocalRotationOffset":[0.7042208,-0.7042207,0.06382109,0.063821055]},{"JointName":"R_Hand","MyJointName":"Bip001-R-Hand","LocalPositionOffset":[8.683322e-17,-4.287567e-17,-7.7647325e-17],"LocalRotationOffset":[0.5490887,-0.4788054,0.54584455,0.41388494]},{"JointName":"R_Thumb1","MyJointName":"Bip001-R-Finger0","LocalPositionOffset":[6.684994e-17,7.414399e-17,1.3329345e-16],"LocalRotationOffset":[0.6231967,-0.5394098,-0.56227934,0.06711751]},{"JointName":"R_Thumb2","MyJointName":"Bip001-R-Finger01","LocalPositionOffset":[0,0,0],"LocalRotationOffset":[0.76568913,-0.5610903,-0.30094874,-0.091256075]},{"JointName":"R_Thumb3","MyJointName":"Bip001-R-Finger02","LocalPositionOffset":[-4.0704466e-17,2.5829507e-17,2.7522187e-17],"LocalRotationOffset":[0.70880663,-0.61954707,-0.21396007,-0.26072133]},{"JointName":"R_IndexF1","MyJointName":"Bip001-R-Finger1","LocalPositionOffset":[5.753917e-17,9.6317016e-17,2.2552145e-17],"LocalRotationOffset":[0.4343856,-0.5316792,0.39479402,0.610544]},{"JointName":"R_IndexF2","MyJointName":"Bip001-R-Finger11","LocalPositionOffset":[-2.4211674e-17,1.301063e-16,1.0109172e-16],"LocalRotationOffset":[0.2711524,-0.64505446,0.2723824,0.660446]},{"JointName":"R_IndexF3","MyJointName":"Bip001-R-Finger12","LocalPositionOffset":[-1.2709731e-16,1.756551e-16,1.2406325e-16],"LocalRotationOffset":[0.18198802,-0.6831504,0.18194494,0.6834339]},{"JointName":"R_MiddleF1","MyJointName":"Bip001-R-Finger2","LocalPositionOffset":[8.559926e-17,-3.442857e-17,-8.3035414e-17],"LocalRotationOffset":[-0.43092668,0.5938677,-0.36696726,-0.57180274]},{"JointName":"R_MiddleF2","MyJointName":"Bip001-R-Finger21","LocalPositionOffset":[1.3530602e-17,-1.5577872e-16,-1.9859784e-17],"LocalRotationOffset":[0.25685894,-0.64821583,0.28836402,0.6562666]},{"JointName":"R_MiddleF3","MyJointName":"Bip001-R-Finger22","LocalPositionOffset":[1.09538086e-17,-1.5255828e-16,-3.546671e-17],"LocalRotationOffset":[0.089062676,-0.7002238,0.085569315,0.70315886]},{"JointName":"R_RingF1","MyJointName":"Bip001-R-Finger3","LocalPositionOffset":[-9.5964704e-17,3.7743633e-17,4.3413575e-17],"LocalRotationOffset":[-0.40844205,0.60574585,-0.36394206,-0.5777484]},{"JointName":"R_RingF2","MyJointName":"Bip001-R-Finger31","LocalPositionOffset":[-6.446902e-19,2.5679028e-18,-6.41393e-18],"LocalRotationOffset":[0.21047439,-0.65301573,0.20888563,0.6968772]},{"JointName":"R_RingF3","MyJointName":"Bip001-R-Finger32","LocalPositionOffset":[-4.1842947e-19,2.6143196e-18,-6.41393e-18],"LocalRotationOffset":[-0.058043294,0.7056837,-0.053658314,-0.7041038]},{"JointName":"R_PinkyF1","MyJointName":"Bip001-R-Finger4","LocalPositionOffset":[8.653782e-19,-1.7256586e-18,6.6649437e-18],"LocalRotationOffset":[0.2759162,-0.6071014,0.4278544,0.61011374]},{"JointName":"R_PinkyF2","MyJointName":"Bip001-R-Finger41","LocalPositionOffset":[-8.3009355e-17,-7.130283e-17,-1.8743125e-17],"LocalRotationOffset":[0.15342228,-0.68074363,0.15412791,0.69949573]},{"JointName":"R_PinkyF3","MyJointName":"Bip001-R-Finger42","LocalPositionOffset":[7.398649e-17,-7.914871e-17,-2.4237009e-17],"LocalRotationOffset":[0.03418917,-0.7056867,0.037570912,0.7067007]},{"JointName":"Head","MyJointName":"Bip001-Head","LocalPositionOffset":[0,2.220446e-16,-6.938894e-18],"LocalRotationOffset":[0.021815134,-1.5187037e-06,2.0172365e-07,0.999762]},{"JointName":"Neck_0","MyJointName":"Ab-NeckSub","LocalPositionOffset":[0,0,0],"LocalRotationOffset":[-0.023403782,-1.1626527e-06,1.46090915e-05,0.9997261]},{"JointName":"L_Thigh","MyJointName":"Bip001-L-Thigh","LocalPositionOffset":[0,0,0],"LocalRotationOffset":[-0.03983113,-8.887582e-09,0.9992064,1.5894683e-07]},{"JointName":"L_Shin","MyJointName":"Bip001-L-Calf","LocalPositionOffset":[2.7680898e-17,2.0338564e-18,-5.745309e-20],"LocalRotationOffset":[-0.03926666,2.2081212e-08,0.9992288,9.633472e-08]},{"JointName":"L_Foot","MyJointName":"Bip001-L-Foot","LocalPositionOffset":[0,2.7755576e-17,0],"LocalRotationOffset":[0.08211999,-0.0057430877,0.9941782,0.06952003]},{"JointName":"L_Toe","MyJointName":"Bip001-L-Toe0","LocalPositionOffset":[2.7755576e-17,0,0],"LocalRotationOffset":[0.082366124,-0.0022076631,0.99419236,0.069227666]},{"JointName":"R_Thigh","MyJointName":"Bip001-R-Thigh","LocalPositionOffset":[1.981306e-17,-1.1230529e-16,9.554463e-18],"LocalRotationOffset":[0.03983135,-1.3759346e-08,0.9992064,-4.9753524e-08]},{"JointName":"R_Shin","MyJointName":"Bip001-R-Calf","LocalPositionOffset":[0,0,0],"LocalRotationOffset":[0.03926708,-3.4471178e-08,0.9992288,-9.2033645e-08]},{"JointName":"R_Foot","MyJointName":"Bip001-R-Foot","LocalPositionOffset":[0,0,0],"LocalRotationOffset":[-0.082119554,-0.0057430035,0.9941783,-0.069519445]},{"JointName":"R_Toe","MyJointName":"Bip001-R-Toe0","LocalPositionOffset":[0,0,0],"LocalRotationOffset":[-0.08236571,-0.002207556,0.9941924,-0.06922709]}]},"actor_corrections":{"type":"via.motion.JointConstraints","kind":"jcns","layers":["art/mods/scarlet/p/source_limb_bind_translation.jcns","art/mods/scarlet/p/source_right_finger_hinges.jcns","art/mods/scarlet/p/source_right_finger_root_limits.jcns","art/mods/scarlet/p/source_right_forearm_helpers.jcns","art/mods/scarlet/p/source_left_forearm_helpers.jcns","art/mods/scarlet/p/source_calf_helpers.jcns"]},"cloth_actor_local":{"type":"via.motion.ConstraintJoints","kind":"copy","source_owner":"owned_body_runtime_binding","rows":[{"JointName":"SC_ClothReg_14","MyJointName":"Ab_SkirtL_S01","LocalPositionOffset":[3.3833152e-07,-1.384157e-07,-6.305764e-07],"LocalRotationOffset":[-8.6092535e-07,1,3.9712637e-07,2.9413425e-07]},{"JointName":"SC_ClothReg_04","MyJointName":"Ab-Fr-SuiteA-01","LocalPositionOffset":[-4.98577e-09,-3.3177985e-06,-1.545941e-06],"LocalRotationOffset":[2.0414593e-07,1,6.9901205e-07,2.5436597e-07]},{"JointName":"SC_ClothReg_03","MyJointName":"Ab-R-SkirtA-01","LocalPositionOffset":[1.9850513e-07,-4.553392e-06,-2.0086784e-06],"LocalRotationOffset":[2.3612708e-07,1,-2.585478e-07,2.3308898e-07]},{"JointName":"SC_ClothReg_02","MyJointName":"Ab-L-SkirtA-01","LocalPositionOffset":[-9.776525e-10,3.521907e-06,1.4758975e-06],"LocalRotationOffset":[1.3327407e-07,1,-2.9975163e-07,1.05335005e-07]}]},"cloth_actor_component":{"type":"via.motion.ConstraintJoints","kind":"copy","source_owner":"owned_body_runtime_binding","rows":[{"JointName":"SC_ClothReg_23","MyJointName":"Ab-L-SkirtA-01","LocalPositionOffset":[0,0,0],"LocalRotationOffset":[0,0,0,1]},{"JointName":"SC_ClothReg_24","MyJointName":"Ab-R-SkirtA-01","LocalPositionOffset":[0,0,0],"LocalRotationOffset":[0,0,0,1]},{"JointName":"SC_ClothReg_21","MyJointName":"Ab-Fr-SuiteA-01","LocalPositionOffset":[0,0,0],"LocalRotationOffset":[0,0,0,1]},{"JointName":"SC_ClothReg_25","MyJointName":"Ab-R-Hip-Reg","LocalPositionOffset":[0,0,0],"LocalRotationOffset":[0,0,0,1]}]}},"preview":{"primary":{"type":"via.motion.ConstraintJoints","kind":"copy","source_owner":"self","rows":[{"JointName":"Hip","MyJointName":"Bip001","LocalPositionOffset":[-5.6231975e-10,0,0],"LocalRotationOffset":[0.5000003,0.5000004,0.49999982,0.49999943]},{"JointName":"Hip","MyJointName":"Bip001-Pelvis","LocalPositionOffset":[0,0,0],"LocalRotationOffset":[6.938973e-07,7.823725e-07,9.2064147e-07,1]},{"JointName":"Spine_0","MyJointName":"Bip001-Spine","LocalPositionOffset":[0,0,0],"LocalRotationOffset":[0.037175715,-1.3210986e-06,1.662345e-07,0.99930876]},{"JointName":"Spine_1","MyJointName":"Bip001-Spine1","LocalPositionOffset":[0,-2.220446e-16,0],"LocalRotationOffset":[0.03504491,-1.4394763e-06,2.40052e-07,0.9993857]},{"JointName":"Spine_2","MyJointName":"Bip001-Spine2","LocalPositionOffset":[0,-2.220446e-16,-1.3877788e-17],"LocalRotationOffset":[-0.020661052,-1.5219715e-06,3.372787e-07,0.99978656]},{"JointName":"Neck_1","MyJointName":"Bip001-Neck","LocalPositionOffset":[0,-2.220446e-16,0],"LocalRotationOffset":[0.0027740933,-6.48652e-05,1.4450286e-05,0.9999961]},{"JointName":"L_Shoulder","MyJointName":"Bip001-L-Clavicle","LocalPositionOffset":[5.035316e-17,2.1709979e-16,-2.015976e-17],"LocalRotationOffset":[0.6883895,0.704713,-0.16161868,-0.058128905]},{"JointName":"L_UpperArm","MyJointName":"Bip001-L-UpperArm","LocalPositionOffset":[2.0884855e-16,7.181397e-17,2.2996536e-17],"LocalRotationOffset":[0.7065995,0.70659935,-0.02678197,0.026782004]},{"JointName":"L_Forearm","MyJointName":"Bip001-L-Forearm","LocalPositionOffset":[2.7222593e-16,-1.4899995e-16,5.5407982e-17],"LocalRotationOffset":[0.7042214,0.7042213,-0.06381417,0.06381413]},{"JointName":"L_Hand","MyJointName":"Bip001-L-Hand","LocalPositionOffset":[1.8699692e-17,1.2532665e-18,-8.113014e-17],"LocalRotationOffset":[-0.5289637,-0.5145987,0.5063656,-0.44607115]},{"JointName":"L_Thumb1","MyJointName":"Bip001-L-Finger0","LocalPositionOffset":[-1.9554121e-17,-1.5630995e-16,5.40206e-17],"LocalRotationOffset":[0.69670606,0.7057887,0.120832875,-0.04315547]},{"JointName":"L_Thumb2","MyJointName":"Bip001-L-Finger01","LocalPositionOffset":[5.588321e-17,-9.5666614e-17,7.1356115e-18],"LocalRotationOffset":[0.7029808,0.7029812,0.0762738,-0.07627372]},{"JointName":"L_Thumb3","MyJointName":"Bip001-L-Finger02","LocalPositionOffset":[9.6586684e-17,-6.9836933e-17,3.4659106e-17],"LocalRotationOffset":[0.6899735,0.7152633,-0.030870873,-0.10668665]},{"JointName":"L_IndexF1","MyJointName":"Bip001-L-Finger1","LocalPositionOffset":[1.01854514e-16,4.8142716e-17,2.0106223e-17],"LocalRotationOffset":[-0.52520734,-0.5252066,0.4734532,-0.47345257]},{"JointName":"L_IndexF2","MyJointName":"Bip001-L-Finger11","LocalPositionOffset":[8.2267056e-17,3.625238e-17,7.0811154e-17],"LocalRotationOffset":[-0.52461296,-0.52461267,0.4741114,-0.47411093]},{"JointName":"L_IndexF3","MyJointName":"Bip001-L-Finger12","LocalPositionOffset":[3.4480547e-17,1.3404772e-16,7.9149075e-17],"LocalRotationOffset":[-0.52156836,-0.52747077,0.47557396,-0.4728324]},{"JointName":"L_MiddleF1","MyJointName":"Bip001-L-Finger2","LocalPositionOffset":[-3.298688e-17,1.0582947e-16,-2.843083e-17],"LocalRotationOffset":[-0.5082929,-0.50829333,0.49156672,-0.49156725]},{"JointName":"L_MiddleF2","MyJointName":"Bip001-L-Finger21","LocalPositionOffset":[-8.226735e-17,-6.811669e-17,-3.0301016e-17],"LocalRotationOffset":[-0.4950198,-0.49501947,0.5049314,-0.5049311]},{"JointName":"L_MiddleF3","MyJointName":"Bip001-L-Finger22","LocalPositionOffset":[8.0144563e-17,6.4979815e-17,4.327836e-17],"LocalRotationOffset":[-0.53766775,-0.44870976,0.5457066,-0.46019262]},{"JointName":"L_RingF1","MyJointName":"Bip001-L-Finger3","LocalPositionOffset":[-1.0052419e-16,-4.5977726e-17,-1.730551e-17],"LocalRotationOffset":[-0.557717,-0.55771697,0.4346858,-0.4346858]},{"JointName":"L_RingF2","MyJointName":"Bip001-L-Finger31","LocalPositionOffset":[-1.5152743e-16,-8.874186e-18,-4.8815584e-17],"LocalRotationOffset":[-0.5545672,-0.5545669,0.43869737,-0.4386973]},{"JointName":"L_RingF3","MyJointName":"Bip001-L-Finger32","LocalPositionOffset":[-6.463202e-17,-8.203937e-17,-3.7658933e-17],"LocalRotationOffset":[-0.58604217,-0.5172642,0.4924107,-0.38278455]},{"JointName":"L_PinkyF1","MyJointName":"Bip001-L-Finger4","LocalPositionOffset":[-2.5967735e-18,-5.1768317e-18,1.9994785e-17],"LocalRotationOffset":[-0.52517027,-0.52517027,0.47349387,-0.47349334]},{"JointName":"L_PinkyF2","MyJointName":"Bip001-L-Finger41","LocalPositionOffset":[-1.5644794e-16,-5.620235e-18,-1.38746586e-17],"LocalRotationOffset":[-0.5240061,-0.52400804,0.47477886,-0.47478223]},{"JointName":"L_PinkyF3","MyJointName":"Bip001-L-Finger42","LocalPositionOffset":[0,0,0],"LocalRotationOffset":[-0.5769056,-0.46212032,0.5391933,-0.40360293]},{"JointName":"R_Shoulder","MyJointName":"Bip001-R-Clavicle","LocalPositionOffset":[0,0,0],"LocalRotationOffset":[-0.6883865,0.70471436,-0.1616293,0.058118027]},{"JointName":"R_UpperArm","MyJointName":"Bip001-R-UpperArm","LocalPositionOffset":[-2.8066355e-16,-1.3826117e-16,2.6822326e-17],"LocalRotationOffset":[0.70659906,-0.70659924,0.026789254,0.026789235]},{"JointName":"R_Forearm","MyJointName":"Bip001-R-Forearm","LocalPositionOffset":[-6.705804e-17,-2.1213478e-16,-2.4004836e-17],"LocalRotationOffset":[0.7042208,-0.7042207,0.06382109,0.063821055]},{"JointName":"R_Hand","MyJointName":"Bip001-R-Hand","LocalPositionOffset":[8.683322e-17,-4.287567e-17,-7.7647325e-17],"LocalRotationOffset":[0.5490887,-0.4788054,0.54584455,0.41388494]},{"JointName":"R_Thumb1","MyJointName":"Bip001-R-Finger0","LocalPositionOffset":[6.684994e-17,7.414399e-17,1.3329345e-16],"LocalRotationOffset":[0.6231967,-0.5394098,-0.56227934,0.06711751]},{"JointName":"R_Thumb2","MyJointName":"Bip001-R-Finger01","LocalPositionOffset":[0,0,0],"LocalRotationOffset":[0.76568913,-0.5610903,-0.30094874,-0.091256075]},{"JointName":"R_Thumb3","MyJointName":"Bip001-R-Finger02","LocalPositionOffset":[-4.0704466e-17,2.5829507e-17,2.7522187e-17],"LocalRotationOffset":[0.70880663,-0.61954707,-0.21396007,-0.26072133]},{"JointName":"R_IndexF1","MyJointName":"Bip001-R-Finger1","LocalPositionOffset":[5.753917e-17,9.6317016e-17,2.2552145e-17],"LocalRotationOffset":[0.4343856,-0.5316792,0.39479402,0.610544]},{"JointName":"R_IndexF2","MyJointName":"Bip001-R-Finger11","LocalPositionOffset":[-2.4211674e-17,1.301063e-16,1.0109172e-16],"LocalRotationOffset":[0.2711524,-0.64505446,0.2723824,0.660446]},{"JointName":"R_IndexF3","MyJointName":"Bip001-R-Finger12","LocalPositionOffset":[-1.2709731e-16,1.756551e-16,1.2406325e-16],"LocalRotationOffset":[0.18198802,-0.6831504,0.18194494,0.6834339]},{"JointName":"R_MiddleF1","MyJointName":"Bip001-R-Finger2","LocalPositionOffset":[8.559926e-17,-3.442857e-17,-8.3035414e-17],"LocalRotationOffset":[-0.43092668,0.5938677,-0.36696726,-0.57180274]},{"JointName":"R_MiddleF2","MyJointName":"Bip001-R-Finger21","LocalPositionOffset":[1.3530602e-17,-1.5577872e-16,-1.9859784e-17],"LocalRotationOffset":[0.25685894,-0.64821583,0.28836402,0.6562666]},{"JointName":"R_MiddleF3","MyJointName":"Bip001-R-Finger22","LocalPositionOffset":[1.09538086e-17,-1.5255828e-16,-3.546671e-17],"LocalRotationOffset":[0.089062676,-0.7002238,0.085569315,0.70315886]},{"JointName":"R_RingF1","MyJointName":"Bip001-R-Finger3","LocalPositionOffset":[-9.5964704e-17,3.7743633e-17,4.3413575e-17],"LocalRotationOffset":[-0.40844205,0.60574585,-0.36394206,-0.5777484]},{"JointName":"R_RingF2","MyJointName":"Bip001-R-Finger31","LocalPositionOffset":[-6.446902e-19,2.5679028e-18,-6.41393e-18],"LocalRotationOffset":[0.21047439,-0.65301573,0.20888563,0.6968772]},{"JointName":"R_RingF3","MyJointName":"Bip001-R-Finger32","LocalPositionOffset":[-4.1842947e-19,2.6143196e-18,-6.41393e-18],"LocalRotationOffset":[-0.058043294,0.7056837,-0.053658314,-0.7041038]},{"JointName":"R_PinkyF1","MyJointName":"Bip001-R-Finger4","LocalPositionOffset":[8.653782e-19,-1.7256586e-18,6.6649437e-18],"LocalRotationOffset":[0.2759162,-0.6071014,0.4278544,0.61011374]},{"JointName":"R_PinkyF2","MyJointName":"Bip001-R-Finger41","LocalPositionOffset":[-8.3009355e-17,-7.130283e-17,-1.8743125e-17],"LocalRotationOffset":[0.15342228,-0.68074363,0.15412791,0.69949573]},{"JointName":"R_PinkyF3","MyJointName":"Bip001-R-Finger42","LocalPositionOffset":[7.398649e-17,-7.914871e-17,-2.4237009e-17],"LocalRotationOffset":[0.03418917,-0.7056867,0.037570912,0.7067007]},{"JointName":"Head","MyJointName":"Bip001-Head","LocalPositionOffset":[0,2.220446e-16,-6.938894e-18],"LocalRotationOffset":[0.021815134,-1.5187037e-06,2.0172365e-07,0.999762]},{"JointName":"Neck_0","MyJointName":"Ab-NeckSub","LocalPositionOffset":[0,0,0],"LocalRotationOffset":[-0.023403782,-1.1626527e-06,1.46090915e-05,0.9997261]},{"JointName":"L_Thigh","MyJointName":"Bip001-L-Thigh","LocalPositionOffset":[0,0,0],"LocalRotationOffset":[-0.03983113,-8.887582e-09,0.9992064,1.5894683e-07]},{"JointName":"L_Shin","MyJointName":"Bip001-L-Calf","LocalPositionOffset":[2.7680898e-17,2.0338564e-18,-5.745309e-20],"LocalRotationOffset":[-0.03926666,2.2081212e-08,0.9992288,9.633472e-08]},{"JointName":"L_Foot","MyJointName":"Bip001-L-Foot","LocalPositionOffset":[0,2.7755576e-17,0],"LocalRotationOffset":[0.08211999,-0.0057430877,0.9941782,0.06952003]},{"JointName":"L_Toe","MyJointName":"Bip001-L-Toe0","LocalPositionOffset":[2.7755576e-17,0,0],"LocalRotationOffset":[0.082366124,-0.0022076631,0.99419236,0.069227666]},{"JointName":"R_Thigh","MyJointName":"Bip001-R-Thigh","LocalPositionOffset":[1.981306e-17,-1.1230529e-16,9.554463e-18],"LocalRotationOffset":[0.03983135,-1.3759346e-08,0.9992064,-4.9753524e-08]},{"JointName":"R_Shin","MyJointName":"Bip001-R-Calf","LocalPositionOffset":[0,0,0],"LocalRotationOffset":[0.03926708,-3.4471178e-08,0.9992288,-9.2033645e-08]},{"JointName":"R_Foot","MyJointName":"Bip001-R-Foot","LocalPositionOffset":[0,0,0],"LocalRotationOffset":[-0.082119554,-0.0057430035,0.9941783,-0.069519445]},{"JointName":"R_Toe","MyJointName":"Bip001-R-Toe0","LocalPositionOffset":[0,0,0],"LocalRotationOffset":[-0.08236571,-0.002207556,0.9941924,-0.06922709]}]},"actor_corrections":{"type":"via.motion.JointConstraints","kind":"jcns","layers":["art/mods/scarlet/p/source_limb_bind_translation.jcns","art/mods/scarlet/p/source_right_finger_hinges.jcns","art/mods/scarlet/p/source_right_finger_root_limits.jcns","art/mods/scarlet/p/source_right_forearm_helpers.jcns","art/mods/scarlet/p/source_left_forearm_helpers.jcns","art/mods/scarlet/p/source_calf_helpers.jcns"]},"cloth_actor_local":{"type":"via.motion.ConstraintJoints","kind":"copy","source_owner":"owned_body_runtime_binding","rows":[{"JointName":"SC_ClothReg_14","MyJointName":"Ab_SkirtL_S01","LocalPositionOffset":[3.3833152e-07,-1.384157e-07,-6.305764e-07],"LocalRotationOffset":[-8.6092535e-07,1,3.9712637e-07,2.9413425e-07]},{"JointName":"SC_ClothReg_04","MyJointName":"Ab-Fr-SuiteA-01","LocalPositionOffset":[-4.98577e-09,-3.3177985e-06,-1.545941e-06],"LocalRotationOffset":[2.0414593e-07,1,6.9901205e-07,2.5436597e-07]},{"JointName":"SC_ClothReg_03","MyJointName":"Ab-R-SkirtA-01","LocalPositionOffset":[1.9850513e-07,-4.553392e-06,-2.0086784e-06],"LocalRotationOffset":[2.3612708e-07,1,-2.585478e-07,2.3308898e-07]},{"JointName":"SC_ClothReg_02","MyJointName":"Ab-L-SkirtA-01","LocalPositionOffset":[-9.776525e-10,3.521907e-06,1.4758975e-06],"LocalRotationOffset":[1.3327407e-07,1,-2.9975163e-07,1.05335005e-07]}]},"cloth_actor_component":{"type":"via.motion.ConstraintJoints","kind":"copy","source_owner":"owned_body_runtime_binding","rows":[{"JointName":"SC_ClothReg_23","MyJointName":"Ab-L-SkirtA-01","LocalPositionOffset":[0,0,0],"LocalRotationOffset":[0,0,0,1]},{"JointName":"SC_ClothReg_24","MyJointName":"Ab-R-SkirtA-01","LocalPositionOffset":[0,0,0],"LocalRotationOffset":[0,0,0,1]},{"JointName":"SC_ClothReg_21","MyJointName":"Ab-Fr-SuiteA-01","LocalPositionOffset":[0,0,0],"LocalRotationOffset":[0,0,0,1]},{"JointName":"SC_ClothReg_25","MyJointName":"Ab-R-Hip-Reg","LocalPositionOffset":[0,0,0],"LocalRotationOffset":[0,0,0,1]}]}},"body":{"hand_gate_input":{"type":"via.motion.ConstraintJoints","kind":"copy","source_owner":"self","rows":[{"JointName":"R_Hand","MyJointName":"SC_ClothReg_02","LocalPositionOffset":[0,0,0],"LocalRotationOffset":[0,0,0,1]}]},"hand_gate":{"type":"via.motion.JointConstraints","kind":"jcns","layers":["mods/{id}/97e55bfe16b5f8f7/hand_middle_position_gate_2d148dc2a278.jcns"]},"cloth_drivers":{"type":"via.motion.ConstraintJoints","kind":"copy","source_owner":"self","rows":[{"JointName":"Dm-L-Thigh-point","MyJointName":"SC_ClothInput","LocalPositionOffset":[0,0,0],"LocalRotationOffset":[2.631338e-07,1,4.5875512e-07,-2.524983e-06]},{"JointName":"Dm-R-Thigh-point","MyJointName":"SC_ClothEulerProbe","LocalPositionOffset":[0,0,0],"LocalRotationOffset":[7.7082554e-08,1,4.802107e-07,2.0415825e-06]}]},"cloth_solve":{"type":"via.motion.JointConstraints","kind":"jcns","layers":["mods/{id}/3190a9df36b142e7/cloth_bind_reset_b8254a25060c.jcns","mods/{id}/be7baca90be8ce7c/cloth_driver_inputs_09261f55a7de.jcns","mods/{id}/286d74852297ba5c/cloth_scalar_graph_e8784a233745.jcns","mods/{id}/041e639488958a8b/cloth_local_poses_c21cfa22a734.jcns"]},"cloth_body_local_and_component_inputs":{"type":"via.motion.ConstraintJoints","kind":"copy","source_owner":"self","rows":[{"JointName":"SC_ClothReg_09","MyJointName":"Ab-R-SkirtQ-01","LocalPositionOffset":[5.43421e-07,-2.6655375e-06,7.9115017e-07],"LocalRotationOffset":[3.7814624e-07,1,7.7067443e-07,7.696122e-06]},{"JointName":"SC_ClothReg_11","MyJointName":"Ab-R-SkirtQ-02","LocalPositionOffset":[4.1261728e-07,-7.8328634e-07,7.302758e-07],"LocalRotationOffset":[4.7167356e-07,1,8.420067e-07,7.756065e-06]},{"JointName":"SC_ClothReg_12","MyJointName":"Ab-L-SkirtA-02","LocalPositionOffset":[8.406862e-08,-9.866535e-07,-5.6269374e-07],"LocalRotationOffset":[1.01476004e-07,1,-2.0107557e-07,1.7222423e-08]},{"JointName":"Ab-L-SkirtA-01","MyJointName":"SC_ClothReg_23","LocalPositionOffset":[0,0,0],"LocalRotationOffset":[0,0,0,1]},{"JointName":"Ab-R-SkirtA-01","MyJointName":"SC_ClothReg_24","LocalPositionOffset":[0,0,0],"LocalRotationOffset":[0,0,0,1]},{"JointName":"Ab-Fr-SuiteA-01","MyJointName":"SC_ClothReg_21","LocalPositionOffset":[0,0,0],"LocalRotationOffset":[0,0,0,1]}]},"cloth_component_deltas":{"type":"via.motion.JointConstraints","kind":"jcns","layers":["mods/{id}/f4669cb10d462b24/cloth_component_positions_4a93305fb489.jcns"]},"hip_response":{"type":"via.motion.JointConstraints","kind":"jcns","layers":["mods/{id}/1981737c1476bd0e/right_hip_follow_4a96e952da4b.jcns"]}}},"actor_fbx_sha256":"f609544e9a16906f7d41a708e5b699bcb4451431c2d1cbcb0e19b4bd94d2f19b","body_mesh_sha256":"5c8aafcb6b20b5ebbadb1ab8960b753bf5ed27514c3b705bd42e7f061299a960","prefab_delivery_sha256":"af9d334cf9b30699c7840e396494237e3f7ff4384bab4dc842170e5e4f20f53b","static_window_proof_sha256":"62ce0106fef59615bcc38f3668f463cfdf03304b2a0b296236009bb9d3cb1394","disk_identity_verified_by_installer_not_lua":true,"runtime_verified":false,"timer":"System.Diagnostics.Stopwatch QPC Int64 / QueryPerformanceFrequency","callback_timing_scope":"wrapper QPC span around entire core.step; excludes outer clock call edges and annotation/REFramework dispatch","coherent_specs":[{"key":"transform_joints","type":"via.Transform","name":"get_Joints","params":[],"returns":"via.Joint[]","is_static":false,"rva":125571280,"hook_only":false},{"key":"array_length","type":"System.Array","name":"GetLength","params":["System.Int32"],"returns":"System.Int32","is_static":false,"rva":114447776,"hook_only":false},{"key":"array_value","type":"System.Array","name":"GetValue","params":["System.Int32"],"returns":"System.Object","is_static":false,"rva":114447856,"hook_only":false},{"key":"joint_valid","type":"via.Joint","name":"get_Valid","params":[],"returns":"System.Boolean","is_static":false,"rva":94763376,"hook_only":false},{"key":"joint_name","type":"via.Joint","name":"get_Name","params":[],"returns":"System.String","is_static":false,"rva":109358608,"hook_only":false},{"key":"joint_owner","type":"via.Joint","name":"get_Owner","params":[],"returns":"via.Transform","is_static":false,"rva":109360928,"mutates_native":false},{"key":"joint_world_p","type":"via.Joint","name":"get_Position","params":[],"returns":"via.vec3","is_static":false,"rva":109358800,"mutates_native":false},{"key":"joint_world_q","type":"via.Joint","name":"get_Rotation","params":[],"returns":"via.Quaternion","is_static":false,"rva":109359552,"mutates_native":false},{"key":"joint_local_scale","type":"via.Joint","name":"get_LocalScale","params":[],"returns":"via.vec3","is_static":false,"rva":109359872,"mutates_native":false},{"key":"joint_set_world_p","type":"via.Joint","name":"set_Position","params":["via.vec3"],"returns":"System.Void","is_static":false,"rva":109358864,"mutates_native":true},{"key":"joint_set_world_q","type":"via.Joint","name":"set_Rotation","params":["via.Quaternion"],"returns":"System.Void","is_static":false,"rva":109359616,"mutates_native":true},{"type":"via.Joint","name":"get_LocalPosition","params":[],"returns":"via.vec3","rva":109358992,"is_static":false,"key":"joint_local_p"},{"type":"via.Joint","name":"get_LocalRotation","params":[],"returns":"via.Quaternion","rva":109359728,"is_static":false,"key":"joint_local_q"},{"type":"via.Joint","name":"get_Parent","params":[],"returns":"via.Joint","rva":109360368,"is_static":false,"key":"joint_parent"},{"type":"via.Joint","name":"get_WorldMatrix","params":[],"returns":"via.mat4","rva":109360048,"is_static":false,"key":"joint_world_matrix"}],"coherent_cloth":{"schema":"scarlet-coherent-cloth-config-v1","fraction":0.05,"write_order":[{"name":"Ab_SkirtL_S01","domain":"Actor"},{"name":"Ab-Fr-SuiteA-01","domain":"Actor"},{"name":"Ab-R-SkirtA-01","domain":"Actor"},{"name":"Ab-L-SkirtA-01","domain":"Actor"},{"name":"Ab-R-SkirtQ-01","domain":"Body"},{"name":"Ab-R-SkirtQ-02","domain":"Body"},{"name":"Ab-L-SkirtA-02","domain":"Body"}],"all_roots":["Ab_SkirtL_S01","Ab-Fr-SuiteA-01","Ab-R-SkirtA-01","Ab-L-SkirtA-01","Ab-R-SkirtQ-01","Ab-R-SkirtQ-02","Ab-L-SkirtA-02"],"kin_roots":["Ab-L-SkirtA-01","Ab-R-SkirtA-01","Ab-Fr-SuiteA-01"],"desired_roots":["Ab-L-SkirtA-01","Ab-R-SkirtA-01"],"start_role":"cloth_solve","kin_role":"cloth_solve","finish_role":"cloth_actor_component","math_sha256":"a8a07cb15136ba825b4de53bcc7df76d99c36172ce6010d4919c6817ec1c2984","backend_sha256":"6a7c580af4b20c0bec2319dc06830aab78a976f8bb1907e5ab10f6304ada3d1c","reference_math_sha256":"1515631f97c2c97b166010e6cba7deb26fdf8d8d167d137169f0f833c131b78b","prototype_delivery_sha256":"681e8fd64fb7cabfd611c80ad652f916a28a0f2ba2fcda47d390cadb7c667eb9","binding_sha256":"bfb953afc1f32375a99e68aa3ef10e818c986e01b5d9640d3e26730f94179df1","core_sha256":"c2f18f6489e985c64f13baed6e335b53ccef035afbff17d96f6f102a671905e8","scope":"Seven owned cloth roots, world P/Q only; local scale untouched; native physics remains enabled","math_backend":"REFramework C++ GLM, float32","runtime_required":["Actual mapped Joint write domain and scale preservation","Before/kin/desired/final same-frame samples","Native Chain2 follows the bridge","No feedback or clipping regression at real speed","Measured bridge/QPC cost"],"baseline":{"mode":"owned-local-and-native-reset-v1","actor_self_write_comparison":"exact local P and sign-equivalent exact local Q; no epsilon suppressing genuine animation changes","reset_tolerance":2e-05,"parents":{"Ab_SkirtL_S01":"Ab-L-Venter2","Ab-Fr-SuiteA-01":"Bip001-Pelvis","Ab-R-SkirtA-01":"Bip001-Pelvis","Ab-L-SkirtA-01":"Bip001-Pelvis","Ab-R-SkirtQ-01":"Bip001-Pelvis","Ab-R-SkirtQ-02":"Ab-R-SkirtQ-01","Ab-L-SkirtA-02":"Ab-L-SkirtA-01"},"reset_body_local":{"Ab-R-SkirtQ-01":{"p":[-0.10279760509729385,0.01050788164138794,-0.137887641787529],"q":[0.9813325191425758,-0.02958928503099543,-0.18501440273147893,-0.04336625262291724]},"Ab-R-SkirtQ-02":{"p":[-7.450580596923828e-09,0.08999991416931152,0.0],"q":[-7.913264433472015e-08,-9.412525009298712e-09,6.939891265280957e-08,0.9999999999999944]},"Ab-L-SkirtA-02":{"p":[-0.03717385232448578,0.1398906111717224,0.01267581433057785],"q":[0.020360214507620922,0.029298661782380896,0.033626754562076984,0.9987974226341331]}},"failure":"Report baseline_valid=false/native_only=true; skip Lua cloth override for this frame while native source stages and primary continue."},"baseline_delivery_sha256":"44dc8f944487e34acd3e6b714b52996790ca1d88f941b8251bb564ae0c1425e0"},"hip_clearance_specs":[{"key":"transform_joints","type":"via.Transform","name":"get_Joints","params":[],"returns":"via.Joint[]","is_static":false,"rva":125571280,"hook_only":false},{"key":"array_length","type":"System.Array","name":"GetLength","params":["System.Int32"],"returns":"System.Int32","is_static":false,"rva":114447776,"hook_only":false},{"key":"array_value","type":"System.Array","name":"GetValue","params":["System.Int32"],"returns":"System.Object","is_static":false,"rva":114447856,"hook_only":false},{"key":"joint_valid","type":"via.Joint","name":"get_Valid","params":[],"returns":"System.Boolean","is_static":false,"rva":94763376,"hook_only":false},{"key":"joint_name","type":"via.Joint","name":"get_Name","params":[],"returns":"System.String","is_static":false,"rva":109358608,"hook_only":false},{"key":"joint_owner","type":"via.Joint","name":"get_Owner","params":[],"returns":"via.Transform","is_static":false,"rva":109360928,"mutates_native":false},{"key":"joint_world_p","type":"via.Joint","name":"get_Position","params":[],"returns":"via.vec3","is_static":false,"rva":109358800,"mutates_native":false},{"key":"joint_local_p","type":"via.Joint","name":"get_LocalPosition","params":[],"returns":"via.vec3","is_static":false,"rva":109358992,"mutates_native":false},{"key":"joint_set_local_p","type":"via.Joint","name":"set_LocalPosition","params":["via.vec3"],"returns":"System.Void","is_static":false,"rva":109359088,"mutates_native":true}],"hip_clearance":{"schema":"scarlet-native-hip-clearance-input-v1","role":"hip_response","hand_joint":"Bip001-R-Hand","pelvis_joint":"Bip001-Pelvis","register_joint":"SC_ClothReg_02","inner_radius_m":0.35,"outer_radius_m":0.55,"falloff":"1-C2 smootherstep","native_register_encoding":"LocalP.X=g/100; native translation source readscentimeters","math_sha256":"8450e8d6a8d757b229026c35657a815ff870e441d65e835c1d19dfb8812c6838","binding_sha256":"b6cbb902169b3394b9d2ff8e33f4b591ad3289a2aeaf680689f2310556cc2c59","scope":"One cached scalar write after all cloth consumers, then native six-channel Hip curves multiply that scalar","runtime_required":["Exact scalar readback and endpoint behavior","No Reg02 consumer after Hip input except the gated Hip layer","Measured same-frame hand/pelvis distance and Hip native output","No new contact or temporal artifact"]},"sdk_backend_sha256":"aacf2e2235835e6c78917396e35f1a851a96c61226f0db08a9e1e1084796ee25","child_secondary_mode_policy":"Observe MergedSkeleton configuration; readiness uses actual names, binds, parents, same-joint constraints and owned Chain2 Last timing","late_sheath":{"schema":"scarlet-late-native-ik-host-v2","placement":"after owner bind, before primary","delivery_sha256":"fe81aeed34c4a877b323926324820ba99bbc9f942eee405e37963f1bc7507d11","contract_file_sha256":"edcf7139b3efa34becdf33b6f221a88db5f54c5215851b8cbd3a9c6cab0b8024","core_sha256":"c14ad8db98458c5b8c489796fcf28a2a500e1b8a31143fec7cd76a0200a4e493","sdk_sha256":"d633a0523008def52af4f1df5a078f7e43b99605478f4236cd6e4b15118f820b","maximum_extra_native_calls_per_owner_frame":1,"primary_drive_continues_if_supplement_fails":true,"algorithm":"Native updateIK only; no Lua bone pose mathematics in this supplement","existing_native_model_animation_material_files_unchanged":true},"assembly_after_role":"cloth_actor_component","assembly":{"schema":"scarlet-bounded-accessory-host-v1","delivery_sha256":"07d9b7d4c974974bcfad3f4e664944497b758c821643a8b38318d5f246fb8d96","contract_sha256":"bc81d233ae987bea3ca4eb8a16696e202f1fa365133d7b6d5b6f39ac3a7b110a","sdk_sha256":"bd8e5a9108560cb0fa3ccb95ec19cd0f8163f2cacde05e83a0843d970082f97a","math_sha256":"529871e62bc973313b57ee41bf5200aebab3103d12a8975ca6b437d985692ad7","config_sha256":"cc08c2aae721514313a1138436dc8581f70b33a9d047abf935551762adc20a68","read_bones":["Bip001-Pelvis","Ab-R-Venter2","Ab-R-Hip-Reg"],"write_bones":["SCN_BottleMount"],"joint_writes_per_owner_frame":2,"scale_writes_per_owner_frame":0,"placement":"after final cloth_actor_component and coherent finish; before native Chain2 Last","failure_isolation":"Report accessory failure and preserve the existing character drive.","math":"Unchanged three-input Lua carrier and polar rotation; both source sling ends use Pelvis255, so the two retained leg inputs contribute zero. Native Chain2 owns bottle swing.","configuration":"Embedded in the immutable adapter; no external mutable JSON or extra autorun scripts.","removed":true,"removal_evidence_sha256":"16ddb77520c5264f707aae7999e9c7b1760f4f5f83d64450723bd9d6a40783bd"},"native_hip_routing":{"delivery":"D:\\AI\\Game\\Onimusha-Scarlet-Mod\\offline-adapter\\root-controller\\unified-adaptation\\source-design-study\\source-layout-restoration\\ownership-audit\\hip-native-routing\\candidate-v2\\delivery.json","delivery_sha256":"1b061f8235d9097e296ec7c5b18899e41bf359a41bc4aa4d76d30c96e36f5f9a","host_update_sha256":"9a00242ebb5e28fc92573275cad60b87c5d6d0bb3960f833c1bf2064138aeabf","private_source":575,"actor_target":252,"body_target":442,"runtime_verified":false},"body_variants":[{"name":"hat","resource":"mods/scarlet_hat_static/6516e70211991f0b/body_mesh_2de4180b65dbe6b20a.mesh","sha256":"5c8aafcb6b20b5ebbadb1ab8960b753bf5ed27514c3b705bd42e7f061299a960","native_body_id":7482},{"name":"no_hat","resource":"mods/scarlet_no_hat_static/67cc2ab84782dc5b/body_mesh_ae4e361f60ab521537.mesh","sha256":"844df0b06c3c396b3f3826bb903421ee330e1a4786a4df4b415b7e4b58d7a30c","native_body_id":28284}],"body_mesh_identity_scope":"body_mesh_sha256 is the primary pose-calibration mesh; each runtime context pins its actual admitted path and asset SHA.","native_costume_slots":{"BODY000":{"item":23169,"body":7482,"variant":"hat"},"BODY001":{"item":5932,"body":28284,"variant":"no_hat"},"source_delivery_sha256":"591ea110c080c73cb028fe2e31918312add431742cad5980fec9632dd36e63db","skeleton_and_non_hat_geometry_identical":true},"copy_source_lifecycle":{"restore_own_writes_before_forgetting":true,"foreign_changes_preserved":true,"native_methods_added":0,"verification_sha256":"2f4a9fe70fce170f744a3a6fb4b019be7252e253c9eb3b3dbbe6f060a2c3d30e","original_costume_resource_isolation_separate":true}}]=])
C.actor_setting_types={'app.CharacterTimelineEventActorPlayer.cVirtualGroundHeightOffsetSetting','app.CharacterTimelineEventActorPlayer.cOverwriteSpecificWeaponDrawSetting'}
local LC=json.load_string([=[{"schema":"scarlet-native-late-sheath-contract-v2","exe_sha256":"69ffeadc34cf3c828d5713fb9e869aa6d187231a117c385ba6d434a711c99b26","crcs":{"ace.GAElement`1<app.PlayerManager>":437989116,"ace.cActionController":1972218437,"app.CharacterBase":1997845319,"app.PlayerManager":346041440,"app.cJointPosOverwriteRate":2624485424,"app.cJointPosOverwriteRate.RequestDate":1169997700,"app.cPlayerCharacterEntity":4067958465,"app.cPlayerManageInfo":3185740719,"app.mcLeftHandSheathHold":370816328,"app.mcLeftHandSheathHold.StateValue":3537056103,"app.mcLeftHandSheathHold.cWeaponOnOff":2055982217,"via.Component":1881844667,"via.GameObject":4065074914},"specs":[{"key":"pm_instance","type":"ace.GAElement`1<app.PlayerManager>","name":"get_Instance","params":[],"returns":"app.PlayerManager","is_static":true,"rva":109939872,"hook_only":false},{"key":"pm_info","type":"app.PlayerManager","name":"getControllingPlayer","params":[],"returns":"app.cPlayerManageInfo","is_static":false,"rva":77873440,"hook_only":false},{"key":"info_character","type":"app.cPlayerManageInfo","name":"get_Character","params":[],"returns":"app.PlayerCharacter","is_static":false,"rva":94360256},{"key":"info_entity","type":"app.cPlayerManageInfo","name":"get_CharacterEntity","params":[],"returns":"app.cPlayerCharacterEntity","is_static":false,"rva":94387552,"hook_only":false},{"key":"entity_sheath","type":"app.cPlayerCharacterEntity","name":"get_SheathHold","params":[],"returns":"app.mcLeftHandSheathHold","is_static":false,"rva":108613008},{"key":"component_go","type":"via.Component","name":"get_GameObject","params":[],"returns":"via.GameObject","is_static":false,"rva":94821856,"hook_only":false},{"key":"component_valid","type":"via.Component","name":"get_Valid","params":[],"returns":"System.Boolean","is_static":false,"rva":94763376,"hook_only":false},{"key":"go_valid","type":"via.GameObject","name":"get_Valid","params":[],"returns":"System.Boolean","is_static":false,"rva":94806192,"hook_only":false},{"type":"app.CharacterBase","name":"get_BaseActionController","params":[],"returns":"ace.cActionController","is_static":false,"rva":107271456,"key":"base_action_controller"},{"type":"ace.cActionController","name":"get_CurrentAction","params":[],"returns":"ace.cActionBase","is_static":false,"rva":94387552,"key":"current_action"},{"key":"update_joint","type":"app.mcLeftHandSheathHold","name":"updateJoint","params":[],"returns":"System.Void","is_static":false,"rva":5523728},{"key":"update_ik","type":"app.mcLeftHandSheathHold","name":"updateIK","params":["System.Single"],"returns":"System.Void","is_static":false,"rva":5531168}],"fields":[{"key":"state","type":"app.mcLeftHandSheathHold","name":"_StateValue","value_type":"app.mcLeftHandSheathHold.StateValue","offset":112},{"key":"onoff","type":"app.mcLeftHandSheathHold","name":"_WeaponOnOff","value_type":"app.mcLeftHandSheathHold.cWeaponOnOff","offset":152},{"key":"overwrite","type":"app.mcLeftHandSheathHold","name":"_JointPosOverwriteRate","value_type":"app.cJointPosOverwriteRate","offset":160},{"key":"enabled","type":"app.mcLeftHandSheathHold","name":"_IsEnbleUpdate","value_type":"System.Boolean","offset":226},{"key":"sequence_blend","type":"app.mcLeftHandSheathHold","name":"_SeqBlendRate","value_type":"System.Single","offset":188},{"key":"sequence_ik","type":"app.mcLeftHandSheathHold","name":"_SeqIKRate","value_type":"System.Single","offset":204},{"key":"transfer_enabled","type":"app.mcLeftHandSheathHold.cWeaponOnOff","name":"IsKatana4Lwep2Katana","value_type":"System.Boolean","offset":56},{"key":"transfer_rate","type":"app.mcLeftHandSheathHold.cWeaponOnOff","name":"RateKatana4Lwep2Katana","value_type":"System.Single","offset":48},{"key":"hold_rate","type":"app.mcLeftHandSheathHold.StateValue","name":"HoldRate","value_type":"System.Single","offset":80},{"key":"overwrite_active","type":"app.cJointPosOverwriteRate","name":"<IsActive>k__BackingField","value_type":"System.Boolean","offset":96},{"key":"request","type":"app.cJointPosOverwriteRate","name":"_RequestDate","value_type":"app.cJointPosOverwriteRate.RequestDate","offset":80},{"key":"request_pending","type":"app.cJointPosOverwriteRate.RequestDate","name":"IsRequest","value_type":"System.Boolean","offset":44},{"key":"ik_pos_go","type":"app.mcLeftHandSheathHold.StateValue","name":"IKPosGameObject","value_type":"via.GameObject","offset":16}],"core_sha256":"c14ad8db98458c5b8c489796fcf28a2a500e1b8a31143fec7cd76a0200a4e493","sdk_sha256":"d633a0523008def52af4f1df5a078f7e43b99605478f4236cd6e4b15118f820b","native_updateIK_code_sha256":"ab0cd723a7471c9e5f32abb286a478a0f76cfffc9c6bc124079d7105442a57d7","scope":"Owned player only. Post original updateJoint records latest completion; host flush(ctx) after same owner bind and before primary replays native IK once per updater/frame. Exact full IK rate only. Late original completion after flush is an explicit timing conflict.","native_only":true,"animation_time_advanced":false,"physics_step_called":false,"overwrite_repeated":false,"deployed":false,"runtime_verified":false,"source_v1_contract_file":"D:\\AI\\Game\\Onimusha-Scarlet-Mod\\offline-adapter\\root-controller\\unified-adaptation\\source-design-study\\weapons\\sheath-fix-from-memory\\late-sheath-contract.json","source_v1_contract_sha256":"0132510a3a7299ce2ee43a5721ec16b58abc7811a457599c2660f5b4d316de12","deferred_to_host_primary":true,"original_post_hook_writes_pose":false,"contract_sha256":"36646f4fd6f9b2a106f27f3c76196bc44242d44d0939cc58683a6ea87319e792"}]=])
local CONTRACT_SHA="d05b992bdb069925c1c77468d51dcb84a3faf4602169c2ef0979690059272c72"
local adapter,controller,late,boot_error,late_error
local ok,why=pcall(function()
 adapter=Backend.new(C,sdk)
 adapter=Bridge.decorate(C,sdk,adapter,Math,MathBackend(Quaternion))
 adapter=HipBinding.decorate(C,sdk,adapter,HipGate)
 if C.assembly.removed~=true then adapter=AssemblySDK.decorate(C,sdk,adapter,AssemblyMath,AC)
 else adapter.assembly_frame=function()return nil end;adapter.assembly_boot_error=function()return nil end end
 local late_ok,value=pcall(LateSDK.new,LC,sdk,thread,adapter,LateCore)
 if late_ok then late=value else late_error=tostring(value)end
 adapter.before_primary_native=function(ctx)
  if ctx.kind~='player'then return{success=true,native_calls=0,native_ticks=0,reason='preview'}end
  if not late then return{success=false,native_calls=0,native_ticks=0,reason='late_sdk_unavailable',error=late_error}end
  return late.flush(ctx)
 end
 controller=Core.new(C,adapter)
end)
if not ok then boot_error=tostring(why)end
_G.scarlet_manual_adapter={api_schema='scarlet-native-adapter-api-v1',
 status=function()
  local s=controller and controller:status()or{state='SDK unavailable',last_error=boot_error}
  s.wrapper_error=boot_error;s.contract_sha256=CONTRACT_SHA;s.static_window_proof_sha256=C.static_window_proof_sha256
s.restart_required=scarlet_reset_required;s.restart_reason=scarlet_reset_reason
  s.runtime_verified=false;s.coherent_math_sha256=C.coherent_cloth.math_sha256
  s.source_leases=adapter and adapter.source_lease_status()or nil
  s.assembly_boot_error=adapter and adapter.assembly_boot_error()or nil
  s.assembly_contract_sha256=C.assembly.contract_sha256
  s.late_sheath=late and late.status()or{available=false,error=late_error}
  s.late_sheath_contract_file_sha256=C.late_sheath.contract_file_sha256;return s
 end,
 late_sheath_events=function(cursor)return late and late.events(cursor)or{events={},latest_sequence=0,first_available=1}end,
 assembly_frame=function(frame,actor)return adapter and adapter.assembly_frame(frame,actor)or nil end,
 coherent_frame=function(frame,actor)return adapter and adapter.coherent_frame(frame,actor)or nil end,
 samples_since=function(sequence)return controller and controller:samples_since(sequence)or{schema='scarlet-native-adapter-timing-v1',frequency=0,latest_sequence=0,first_available_sequence=1,lost=0,samples={}}end}
if controller then
 re.on_application_entry(C.entry,function()
   if not scarlet_gate.allow('UpdateConstraintsEnd') then scarlet_gate.flush_restore('UpdateConstraintsEnd');return end
  local captured,reason=pcall(function()
   if not isolation_can_run or not isolation_can_run()then return end
   local start=adapter.clock();local before=controller:sequence();controller:step(C.entry);local finish=adapter.clock()
   controller:finish_callback(before,start,finish)
  end)
  if not captured then boot_error=tostring(reason)end
 end)
end
scarlet_gate.on_disable(function(reason)local all=true;if controller then local ok,result=pcall(function()return controller:retry()end);if not ok or result==false then all=false end end;if late and late.retry then local ok,result=pcall(late.retry);if not ok or result==false then all=false end end;return all end)
re.on_script_reset(function()scarlet_reset_required=true;scarlet_reset_reason='script_reset_requires_restart';end)

-- SCARLET_NATIVE_PRIVATE_PARTS_ROUTER
do
local Factory=(function()
local C=json.load_string([=[{"schema":"scarlet-native-private-parts-router-contract-v1","specs":[{"key":"arg_ctor","type":"app.PlayerPartsDef.cChangeArgument","name":".ctor","params":["app.PlayerPartsDef.PARTS_TYPE","System.Int32"],"returns":"System.Void","is_static":false,"rva":94486240,"hook_only":false},{"key":"arg_id","type":"app.PlayerPartsDef.cChangeArgument","name":"get_ID","params":[],"returns":"System.Int32","is_static":false,"rva":94310352,"hook_only":false},{"key":"arg_part","type":"app.PlayerPartsDef.cChangeArgument","name":"get_PartsType","params":[],"returns":"app.PlayerPartsDef.PARTS_TYPE","is_static":false,"rva":94314752,"hook_only":false},{"key":"array_length","type":"System.Array","name":"GetLength","params":["System.Int32"],"returns":"System.Int32","is_static":false,"rva":114447776,"hook_only":false},{"key":"array_value","type":"System.Array","name":"GetValue","params":["System.Int32"],"returns":"System.Object","is_static":false,"rva":114447856,"hook_only":false},{"key":"catalog_hq","type":"app.cPlayerCatalogHolder","name":"getPlayerPartsListHQ","params":["app.PlayerPartsDef.PARTS_TYPE"],"returns":"System.Collections.Generic.Dictionary`2<System.Int32,via.Prefab>","is_static":false,"rva":77621648,"hook_only":false},{"key":"catalog_normal","type":"app.cPlayerCatalogHolder","name":"getPlayerPartsList","params":["app.PlayerPartsDef.PARTS_TYPE"],"returns":"System.Collections.Generic.Dictionary`2<System.Int32,via.Prefab>","is_static":false,"rva":3288560,"hook_only":false},{"key":"component_go","type":"via.Component","name":"get_GameObject","params":[],"returns":"via.GameObject","is_static":false,"rva":94821856,"hook_only":false},{"key":"component_valid","type":"via.Component","name":"get_Valid","params":[],"returns":"System.Boolean","is_static":false,"rva":94763376,"hook_only":false},{"key":"context_hair","type":"app.cPlayerContextParam","name":"get_CurrentEquipHairID","params":[],"returns":"System.Int32","is_static":false,"rva":96902496,"hook_only":false},{"key":"context_head","type":"app.cPlayerContextParam","name":"get_CurrentEquipHeadID","params":[],"returns":"System.Int32","is_static":false,"rva":96902784,"hook_only":false},{"key":"context_player","type":"app.cGameContextHolder","name":"get_Player","params":[],"returns":"app.cPlayerContextParam","is_static":false,"rva":105264544,"hook_only":false},{"key":"dict_add","type":"System.Collections.Generic.Dictionary`2<System.Int32,via.Prefab>","name":"Add","params":["System.Int32","via.Prefab"],"returns":"System.Void","is_static":false,"rva":111498912,"hook_only":false},{"key":"dict_contains","type":"System.Collections.Generic.Dictionary`2<System.Int32,via.Prefab>","name":"ContainsKey","params":["System.Int32"],"returns":"System.Boolean","is_static":false,"rva":95024480,"hook_only":false},{"key":"dict_get","type":"System.Collections.Generic.Dictionary`2<System.Int32,via.Prefab>","name":"get_Item","params":["System.Int32"],"returns":"via.Prefab","is_static":false,"rva":95024080,"hook_only":false},{"key":"dict_remove","type":"System.Collections.Generic.Dictionary`2<System.Int32,via.Prefab>","name":"Remove","params":["System.Int32"],"returns":"System.Boolean","is_static":false,"rva":593056,"hook_only":false},{"key":"entity_supporter","type":"app.cPlayerCharacterEntity","name":"get_GameObjectSupporter","params":[],"returns":"app.cPlayerGameObjectSupporter","is_static":false,"rva":108612672,"hook_only":false},{"key":"go_components","type":"via.GameObject","name":"get_Components","params":[],"returns":"via.Component[]","is_static":false,"rva":97957600,"hook_only":false},{"key":"go_transform","type":"via.GameObject","name":"get_Transform","params":[],"returns":"via.Transform","is_static":false,"rva":97957552,"hook_only":false},{"key":"go_valid","type":"via.GameObject","name":"get_Valid","params":[],"returns":"System.Boolean","is_static":false,"rva":94806192,"hook_only":false},{"key":"hq_async","type":"app.PlayerManager.<>c__DisplayClass135_0","name":"<changePlayerModelHQ>b__0","params":[],"returns":"System.Void","is_static":false,"rva":92959072,"hook_only":true},{"key":"info_context","type":"app.cPlayerManageInfo","name":"get_Context","params":[],"returns":"app.cGameContextHolder","is_static":false,"rva":94490768,"hook_only":false},{"key":"info_entity","type":"app.cPlayerManageInfo","name":"get_CharacterEntity","params":[],"returns":"app.cPlayerCharacterEntity","is_static":false,"rva":94387552,"hook_only":false},{"key":"info_go","type":"app.cPlayerManageInfo","name":"get_Object","params":[],"returns":"via.GameObject","is_static":false,"rva":86045520,"hook_only":false},{"key":"info_valid","type":"app.cPlayerManageInfo","name":"get_Valid","params":[],"returns":"System.Boolean","is_static":false,"rva":125839200,"hook_only":false},{"key":"list_add","type":"System.Collections.Generic.List`1<app.PlayerPartsDef.cChangeArgument>","name":"Add","params":["app.PlayerPartsDef.cChangeArgument"],"returns":"System.Void","is_static":false,"rva":96276864,"hook_only":false},{"key":"list_count","type":"System.Collections.Generic.List`1<app.PlayerPartsDef.cChangeArgument>","name":"get_Count","params":[],"returns":"System.Int32","is_static":false,"rva":75389856,"hook_only":false},{"key":"list_ctor","type":"System.Collections.Generic.List`1<app.PlayerPartsDef.cChangeArgument>","name":".ctor","params":["System.Int32"],"returns":"System.Void","is_static":false,"rva":96278256,"hook_only":false},{"key":"list_get","type":"System.Collections.Generic.List`1<app.PlayerPartsDef.cChangeArgument>","name":"get_Item","params":["System.Int32"],"returns":"app.PlayerPartsDef.cChangeArgument","is_static":false,"rva":992352,"hook_only":false},{"key":"mesh_holder","type":"via.render.Mesh","name":"getMesh","params":[],"returns":"via.render.MeshResourceHolder","is_static":false,"rva":122190144,"hook_only":false},{"key":"mesh_ready","type":"via.render.Mesh","name":"get_MeshReady","params":[],"returns":"System.Boolean","is_static":false,"rva":122191152,"hook_only":false},{"key":"normal_async","type":"app.PlayerManager.<>c__DisplayClass136_0","name":"<changePlayerModel>b__0","params":[],"returns":"System.Void","is_static":false,"rva":73694640,"hook_only":true},{"key":"part_object_type","type":"app.cPlayerGameObjectSupporter","name":"convertObjTypeToPartsType","params":["app.PlayerPartsDef.PARTS_TYPE"],"returns":"app.cPlayerGameObjectSupporter.PLAYER_GAME_OBJECT","is_static":true,"rva":11360992,"hook_only":false},{"key":"player_changing","type":"app.cPlayerGameObjectSupporter","name":"isChangeModelProcessing","params":[],"returns":"System.Boolean","is_static":false,"rva":86962400,"hook_only":false},{"key":"player_part_go","type":"app.cPlayerGameObjectSupporter","name":"getGameObject","params":["app.cPlayerGameObjectSupporter.PLAYER_GAME_OBJECT"],"returns":"via.GameObject","is_static":false,"rva":3268272,"hook_only":false},{"key":"player_request_list","type":"app.cPlayerGameObjectSupporter","name":"requestChangeModelCore","params":["System.Collections.Generic.List`1<app.PlayerPartsDef.cChangeArgument>"],"returns":"System.Void","is_static":false,"rva":124836400,"hook_only":false},{"key":"pm_info","type":"app.PlayerManager","name":"getControllingPlayer","params":[],"returns":"app.cPlayerManageInfo","is_static":false,"rva":77873440,"hook_only":false},{"key":"pm_instance","type":"ace.GAElement`1<app.PlayerManager>","name":"get_Instance","params":[],"returns":"app.PlayerManager","is_static":true,"rva":109939872,"hook_only":false},{"key":"pm_ui","type":"app.PlayerManager","name":"getControllingPlayerUI","params":[],"returns":"via.GameObject","is_static":false,"rva":111300480,"hook_only":false},{"key":"pm_ui_ready","type":"app.PlayerManager","name":"isPlayerUICreateComplete","params":[],"returns":"System.Boolean","is_static":false,"rva":86942128,"hook_only":false},{"key":"prefab_path","type":"via.Prefab","name":"get_Path","params":[],"returns":"System.String","is_static":false,"rva":89423824,"hook_only":false},{"key":"prefab_ready","type":"via.Prefab","name":"get_Ready","params":[],"returns":"System.Boolean","is_static":false,"rva":110617696,"hook_only":false},{"key":"prefab_standby","type":"via.Prefab","name":"get_Standby","params":[],"returns":"System.Boolean","is_static":false,"rva":94357296,"hook_only":false},{"key":"prefab_valid","type":"via.Prefab","name":"get_Valid","params":[],"returns":"System.Boolean","is_static":false,"rva":110617696,"hook_only":false},{"key":"private_catalog_get","type":"app.user_data.PlayerPartsList","name":"getPartsPrefab","params":["System.Int32"],"returns":"via.Prefab","is_static":false,"rva":99621040,"hook_only":false,"private_pool_only":false},{"key":"private_standby_set","type":"via.Prefab","name":"set_Standby","params":["System.Boolean"],"returns":"System.Void","is_static":false,"rva":111950032,"hook_only":false,"private_pool_only":true},{"key":"resource_path","type":"via.ResourceHolder","name":"get_ResourcePath","params":[],"returns":"System.String","is_static":false,"rva":116635664,"hook_only":false},{"key":"transform_parent","type":"via.Transform","name":"get_Parent","params":[],"returns":"via.Transform","is_static":false,"rva":125570976,"hook_only":false},{"key":"ui_changing","type":"app.PlayerUICharacter","name":"isChangeModelProcessing","params":[],"returns":"System.Boolean","is_static":false,"rva":108746864,"hook_only":false},{"key":"ui_part_go","type":"app.PlayerUICharacter","name":"getGameObject","params":["app.cPlayerGameObjectSupporter.PLAYER_GAME_OBJECT"],"returns":"via.GameObject","is_static":false,"rva":12137456,"hook_only":false},{"key":"ui_request_list","type":"app.PlayerUICharacter","name":"requestChangeModel","params":["System.Collections.Generic.List`1<app.PlayerPartsDef.cChangeArgument>"],"returns":"System.Void","is_static":false,"rva":86330432,"hook_only":false}],"fields":[{"key":"pm_catalog","type":"app.PlayerManager","name":"_Catalog","returns":"app.cPlayerCatalogHolder","offset":120},{"key":"catalog_data","type":"app.user_data.PlayerPartsList","name":"_DataList","returns":"app.user_data.PlayerPartsList.cData[]","offset":32},{"key":"player_entity","type":"app.cPlayerGameObjectSupporter","name":"_PlayerCharacterEntity","returns":"app.cPlayerCharacterEntity","offset_from_base":48,"is_static":false,"offset":48},{"key":"entity_owner","type":"app.cEntityBase","name":"_Owner","returns":"via.GameObject","offset_from_base":16,"is_static":false,"offset":16},{"key":"player_model_ids","type":"app.cPlayerGameObjectSupporter","name":"_ModelIDs","returns":"System.Int32[]","offset_from_base":32,"is_static":false,"offset":32},{"key":"ui_model_ids","type":"app.PlayerUICharacter","name":"_ModelIDs","returns":"System.Int32[]","offset_from_base":184,"is_static":false,"offset":184},{"key":"part_value","type":"app.PlayerPartsDef.PARTS_TYPE","name":"value__","returns":"System.Int32","offset_from_base":16,"is_static":false,"offset":16},{"key":"int_value","type":"System.Int32","name":"m_value","returns":"System.Int32","offset_from_base":16,"is_static":false,"offset":16},{"key":"normal_async_owner","type":"app.PlayerManager.<>c__DisplayClass136_0","name":"ownerObj","returns":"via.GameObject","offset":32},{"key":"normal_async_target","type":"app.PlayerManager.<>c__DisplayClass136_0","name":"targetObj","returns":"via.GameObject","offset":40},{"key":"normal_async_part","type":"app.PlayerManager.<>c__DisplayClass136_0","name":"partsType","returns":"app.PlayerPartsDef.PARTS_TYPE","offset":64},{"key":"normal_async_prefab","type":"app.PlayerManager.<>c__DisplayClass136_0","name":"prefab","returns":"via.Prefab","offset":16},{"key":"hq_async_owner","type":"app.PlayerManager.<>c__DisplayClass135_0","name":"ownerObj","returns":"via.GameObject","offset":32},{"key":"hq_async_target","type":"app.PlayerManager.<>c__DisplayClass135_0","name":"targetObj","returns":"via.GameObject","offset":40},{"key":"hq_async_part","type":"app.PlayerManager.<>c__DisplayClass135_0","name":"partsType","returns":"app.PlayerPartsDef.PARTS_TYPE","offset":64},{"key":"hq_async_prefab","type":"app.PlayerManager.<>c__DisplayClass135_0","name":"prefab","returns":"via.Prefab","offset":16},{"key":"object_type_value","type":"app.cPlayerGameObjectSupporter.PLAYER_GAME_OBJECT","name":"value__","returns":"System.Int32","offset":16}],"crcs":{"app.cPlayerCharacterEntity":4067958465,"via.Prefab":2699058713,"app.cEntityBase":2325337446,"System.Collections.Generic.List`1<app.PlayerPartsDef.cChangeArgument>":58605515,"app.cGameContextHolder":3170331478,"app.PlayerManager":346041440,"via.ResourceHolder":1072471267,"app.cPlayerGameObjectSupporter":1646483854,"via.Component":1881844667,"app.cPlayerContextParam":2288083251,"app.cPlayerManageInfo":3185740719,"app.PlayerUICharacter":2159145370,"app.PlayerPartsDef.PARTS_TYPE":1071981370,"via.render.Mesh":1829138609,"System.Array":58605515,"via.Transform":1340992935,"System.Collections.Generic.Dictionary`2<System.Int32,via.Prefab>":1843153456,"ace.GAElement`1<app.PlayerManager>":437989116,"app.PlayerManager.<>c__DisplayClass136_0":58605515,"via.GameObject":4065074914,"app.cPlayerCatalogHolder":3654990425,"app.user_data.PlayerPartsList":3931753037,"System.Int32":460376714,"app.PlayerPartsDef.cChangeArgument":1625114799,"app.PlayerManager.<>c__DisplayClass135_0":58605515,"app.cPlayerGameObjectSupporter.PLAYER_GAME_OBJECT":4280628242},"catalogs":[{"resource":"mods/{id}/dynamic/parts_normal.user","quality":"NORMAL","prefabs":[{"id":25571,"path":"mods/{id}/dynamic/head_normal.pfb"},{"id":1155,"path":"mods/{id}/dynamic/hair_normal.pfb"}]},{"resource":"mods/{id}/dynamic/parts_hq.user","quality":"HQ","prefabs":[{"id":25571,"path":"mods/{id}/dynamic/head_hq.pfb"},{"id":1155,"path":"mods/{id}/dynamic/hair_hq.pfb"}]}],"private_paths":{"mods/{id}/dynamic/head_normal.pfb":true,"mods/{id}/dynamic/hair_normal.pfb":true,"mods/{id}/dynamic/head_hq.pfb":true,"mods/{id}/dynamic/hair_hq.pfb":true},"dictionary_type":"System.Collections.Generic.Dictionary`2<System.Int32,via.Prefab>","scarlet_head_mesh":"mods/{id}/6423f1b37f91f9b9/face_mesh_9da307fec900e6d3ae.mesh","mutation_scope":"Vacant private/alias catalog keys and bounded native refresh requests; keep native high-level request IDs unchanged, route only owned original Head/Hair Prefab fields. Public keys, model caches and saved equipment are not directly written.","native_behavior_verified":false,"ids":{"head":1396899841,"hair":1396899842},"closure_hooks":[{"key":"normal_async","quality":"NORMAL"},{"key":"hq_async","quality":"HQ"}],"public_routes":{"gamedesign/action/player/_prefab/partslist/head/ch001_00_10.pfb":{"private":"mods/{id}/dynamic/head_normal.pfb","quality":"NORMAL","parts_type":2},"gamedesign/action/player/_prefab/partslist/head/ch001_00_10_hq.pfb":{"private":"mods/{id}/dynamic/head_hq.pfb","quality":"HQ","parts_type":2},"gamedesign/action/player/_prefab/partslist/hair/ch001_00_20.pfb":{"private":"mods/{id}/dynamic/hair_normal.pfb","quality":"NORMAL","parts_type":3},"gamedesign/action/player/_prefab/partslist/hair/ch001_00_20_hq.pfb":{"private":"mods/{id}/dynamic/hair_hq.pfb","quality":"HQ","parts_type":3}},"native_alias_base":1397030912,"scarlet_hair_mesh":"mods/{id}/065fbc394a33f4ea/hair_empty_7b4984196f493e487.mesh","native_head_mesh":"art/model/character/ch0/ch001_00/10/ch001_00_10.mesh","refresh_catalogs":[{"resource":"mods/{id}/dynamic/refresh_normal.user","quality":"NORMAL","prefabs":[{"id":25571,"path":"mods/{id}/dynamic/head_normal.pfb"},{"id":1155,"path":"mods/{id}/dynamic/hair_normal.pfb"}]},{"resource":"mods/{id}/dynamic/refresh_hq.user","quality":"HQ","prefabs":[{"id":25571,"path":"mods/{id}/dynamic/head_hq.pfb"},{"id":1155,"path":"mods/{id}/dynamic/hair_hq.pfb"}]}],"scarlet_bodies":{"mods/scarlet_hat_static/6516e70211991f0b/body_mesh_2de4180b65dbe6b20a.mesh":true,"mods/scarlet_no_hat_static/67cc2ab84782dc5b/body_mesh_ae4e361f60ab521537.mesh":true},"known_body_ids":{"7482":true,"28284":true,"1505":true,"20993":true,"16301":true,"31144":true,"23035":true,"25770":true,"16546":true,"32714":true,"24884":true},"list_type":"System.Collections.Generic.List`1<app.PlayerPartsDef.cChangeArgument>","arg_type":"app.PlayerPartsDef.cChangeArgument","raw_resource_type":"via.PrefabResource","native_preview_recreation_evidence":{"file":"D:\\AI\\Game\\Onimusha-Scarlet-Mod\\offline-adapter\\root-controller\\unified-adaptation\\source-design-study\\native-costume-regression\\assembly-lifecycle\\catalog-roundtrip-02.json","sha256":"9c7952271226459517fd8cebd716d3a22e2d4aa9d5bf3bac140850aef00f036a","gameplay_and_cross_family_validation_complete":false},"lease_catalogs":[{"resource":"mods/{id}/dynamic/lease_normal_0.user","prefabs":[{"id":25571,"path":"mods/{id}/dynamic/head_normal.pfb"},{"id":1155,"path":"mods/{id}/dynamic/hair_normal.pfb"}]},{"resource":"mods/{id}/dynamic/lease_normal_1.user","prefabs":[{"id":25571,"path":"mods/{id}/dynamic/head_normal.pfb"},{"id":1155,"path":"mods/{id}/dynamic/hair_normal.pfb"}]},{"resource":"mods/{id}/dynamic/lease_normal_2.user","prefabs":[{"id":25571,"path":"mods/{id}/dynamic/head_normal.pfb"},{"id":1155,"path":"mods/{id}/dynamic/hair_normal.pfb"}]},{"resource":"mods/{id}/dynamic/lease_normal_3.user","prefabs":[{"id":25571,"path":"mods/{id}/dynamic/head_normal.pfb"},{"id":1155,"path":"mods/{id}/dynamic/hair_normal.pfb"}]},{"resource":"mods/{id}/dynamic/lease_normal_4.user","prefabs":[{"id":25571,"path":"mods/{id}/dynamic/head_normal.pfb"},{"id":1155,"path":"mods/{id}/dynamic/hair_normal.pfb"}]},{"resource":"mods/{id}/dynamic/lease_normal_5.user","prefabs":[{"id":25571,"path":"mods/{id}/dynamic/head_normal.pfb"},{"id":1155,"path":"mods/{id}/dynamic/hair_normal.pfb"}]},{"resource":"mods/{id}/dynamic/lease_normal_6.user","prefabs":[{"id":25571,"path":"mods/{id}/dynamic/head_normal.pfb"},{"id":1155,"path":"mods/{id}/dynamic/hair_normal.pfb"}]},{"resource":"mods/{id}/dynamic/lease_normal_7.user","prefabs":[{"id":25571,"path":"mods/{id}/dynamic/head_normal.pfb"},{"id":1155,"path":"mods/{id}/dynamic/hair_normal.pfb"}]},{"resource":"mods/{id}/dynamic/lease_hq_0.user","prefabs":[{"id":25571,"path":"mods/{id}/dynamic/head_hq.pfb"},{"id":1155,"path":"mods/{id}/dynamic/hair_hq.pfb"}]},{"resource":"mods/{id}/dynamic/lease_hq_1.user","prefabs":[{"id":25571,"path":"mods/{id}/dynamic/head_hq.pfb"},{"id":1155,"path":"mods/{id}/dynamic/hair_hq.pfb"}]},{"resource":"mods/{id}/dynamic/lease_hq_2.user","prefabs":[{"id":25571,"path":"mods/{id}/dynamic/head_hq.pfb"},{"id":1155,"path":"mods/{id}/dynamic/hair_hq.pfb"}]},{"resource":"mods/{id}/dynamic/lease_hq_3.user","prefabs":[{"id":25571,"path":"mods/{id}/dynamic/head_hq.pfb"},{"id":1155,"path":"mods/{id}/dynamic/hair_hq.pfb"}]},{"resource":"mods/{id}/dynamic/lease_hq_4.user","prefabs":[{"id":25571,"path":"mods/{id}/dynamic/head_hq.pfb"},{"id":1155,"path":"mods/{id}/dynamic/hair_hq.pfb"}]},{"resource":"mods/{id}/dynamic/lease_hq_5.user","prefabs":[{"id":25571,"path":"mods/{id}/dynamic/head_hq.pfb"},{"id":1155,"path":"mods/{id}/dynamic/hair_hq.pfb"}]},{"resource":"mods/{id}/dynamic/lease_hq_6.user","prefabs":[{"id":25571,"path":"mods/{id}/dynamic/head_hq.pfb"},{"id":1155,"path":"mods/{id}/dynamic/hair_hq.pfb"}]},{"resource":"mods/{id}/dynamic/lease_hq_7.user","prefabs":[{"id":25571,"path":"mods/{id}/dynamic/head_hq.pfb"},{"id":1155,"path":"mods/{id}/dynamic/hair_hq.pfb"}]}]}]=])
local Pool=(function()
local M={}
function M.new(C,A)
 local catalogs,prefabs={},{ };local pins={};local prepared=false;local closing=false;local closed=false;local handed_off=false;local expected=0
 local cleanup_errors={};local leases={};local pending_catalogs=0;local rearms=0;local last_rearm={}
 for _,entry in ipairs(C.catalogs)do expected=expected+#entry.prefabs end
 local function need(v,s)if not v then error(s,0)end;return v end
 local function canonical(p)return type(p)=='string'and scarlet_gate.route(p):lower():gsub('\\','/'):gsub('^@',''):gsub('%.%d+$','')or nil end
 local self={}
 local function snapshot()
  local count,ready=0,0;local parts={}
  for path,p in pairs(prefabs)do
   count=count+1;need(A.is_prefab(p)and canonical(A.path(p))==canonical(scarlet_gate.route(path)),'Private prefab changed')
   local valid,loaded,standby=A.valid(p),A.ready(p),A.standby(p)
   parts[path]={valid=valid,ready=loaded,standby=standby,last_rearm=last_rearm[path]}
   if valid and loaded then ready=ready+1 end
  end
  return{prepared=prepared,ready=prepared and count==expected and ready==expected,ready_count=ready,expected_count=expected,
   pending_catalogs=pending_catalogs,closed=closed,closing=closing,handed_off=handed_off,cleanup_errors=cleanup_errors,parts=parts,rearms=rearms,resource_pins=(function()local n=0;for _ in pairs(pins)do n=n+1 end;return n end)()}
 end
 local function advance()
  if closing or closed then return snapshot()end
  pending_catalogs=0
  for _,entry in ipairs(C.catalogs)do
   local c=catalogs[entry.resource]
   if not c.ready then
    local count=A.catalog_count(c.object)
    if count==nil then pending_catalogs=pending_catalogs+1
    else
     need(count==#entry.prefabs,'Private catalog entry count differs')
     for _,part in ipairs(entry.prefabs)do
      local p=A.get_prefab(c.object,part.id);need(p and A.is_prefab(p),'Private native Prefab missing');A.retain(p)
      need(canonical(A.path(p))==canonical(scarlet_gate.route(part.path)),'Private native Prefab path differs');prefabs[part.path]=p;A.set_standby(p,true)
     end
     c.ready=true
    end
   end
  end
  prepared=pending_catalogs==0
  for path,p in pairs(prefabs)do
   if not A.standby(p)then
    last_rearm[path]={valid_before=A.valid(p),ready_before=A.ready(p),standby_before=false}
    A.set_standby(p,true);rearms=rearms+1
   end
  end
  return snapshot()
 end
 function self.prepare()
  need(not closing and not closed,'Private pool closed')
  if A.pin then for _,entry in ipairs(C.catalogs)do for _,part in ipairs(entry.prefabs)do
   if not pins[part.path]then pins[part.path]=need(A.pin(part.path),'Private prefab resource pin failed')end
  end end end
  for _,entry in ipairs(C.catalogs)do if not catalogs[entry.resource]then
   local o=A.create_catalog(entry.resource);need(o and A.is_catalog(o),'Private catalog creation failed');A.retain(o);catalogs[entry.resource]={object=o,ready=false}
  end end
  return advance()
 end
 function self.poll()
  if next(catalogs)==nil then return snapshot()end
  return advance()
 end
 function self.get_ready(path)
  if closing or closed or not prepared then return nil,'Private pool not ready'end
  local p=prefabs[path];if not p then return nil,'Private Prefab absent'end
  if not A.standby(p)then
   last_rearm[path]={valid_before=A.valid(p),ready_before=A.ready(p),standby_before=false};A.set_standby(p,true);rearms=rearms+1
  end
  if not A.valid(p)or not A.ready(p)then return nil,'Private Prefab not ready'end
  handed_off=true;return p
 end
 function self.acquire(path,key)local p,why=self.get_ready(path);if p then leases[key]=p end;return p,why end
 function self.complete(key)leases[key]=nil end
 function self.has_lease(key)return leases[key]~=nil end
 function self.close()
  if closed then return true end;closing=true
  if not handed_off then for path,p in pairs(prefabs)do local ok,why=pcall(A.set_standby,p,false);if not ok then cleanup_errors[#cleanup_errors+1]={path=path,error=tostring(why)}end end end
  for path,r in pairs(pins)do
   if A.unpin then local ok,why=pcall(A.unpin,r);if not ok then cleanup_errors[#cleanup_errors+1]={path=path,error=tostring(why)}end end
  end
  pins={};leases={};catalogs={};prefabs={};closed=true;return true
 end
 return self
end
return M

end)()
local Leases=(function()
-- Independent native USER entries own the wrappers; no Prefab.Clone/duplicate calls.
local M={}
function M.new(A)
 local leases,catalogs,slots={},{},{}
 local stats={created=0,reused=0,released=0,active=0,maximum_active=0,prepared=0,available=0,catalogs=0}
 local function need(v,s)if not v then error(s,0)end;return v end
 local self={}
 function self.prepare(entries)
  local complete=true
  for _,entry in ipairs(entries)do
   local c=catalogs[entry.resource]
   if not c then c={object=A.retain(A.create_catalog(entry.resource)),loaded=false};catalogs[entry.resource]=c;stats.catalogs=stats.catalogs+1 end
   if not c.loaded then
    local n=A.catalog_count(c.object)
    if n==nil then complete=false else
     need(n==#entry.prefabs,'Native lease catalog count differs')
     for _,part in ipairs(entry.prefabs)do
      local p=need(A.get_prefab(c.object,part.id),'Native lease prefab absent')
      need(A.valid_type(p)and A.path(p)==canon(scarlet_gate.route(part.path)),'Native lease prefab identity differs')
      for _,slot in ipairs(slots)do need(not A.same(slot.prefab,p),'Native lease catalogs share a mutable wrapper')end
      A.retain(p);A.standby(p,true);slots[#slots+1]={prefab=p,path=part.path};stats.prepared=stats.prepared+1
     end
     c.loaded=true
    end
   end
  end
  local available=0
  for _,slot in ipairs(slots)do
   if not slot.busy then
    if not A.get_standby(slot.prefab)then A.standby(slot.prefab,true)end
    if A.ready(slot.prefab)then available=available+1 else complete=false end
   end
  end
  stats.available=available
  return complete
 end
 function self.acquire(key,template,path,owner,closure,original,target,part)
  local old=leases[key]
  if old then need(old.path==path and A.same(old.owner,owner),'Prefab lease key was reused');stats.reused=stats.reused+1;return old.prefab end
  local selected
  for _,slot in ipairs(slots)do if slot.path==path and not slot.busy and A.ready(slot.prefab)then selected=slot;break end end
  need(selected,'Native private prefab reserve exhausted')
  selected.busy=true
  leases[key]={prefab=selected.prefab,slot=selected,path=path,owner=A.retain(owner),closure=A.retain(closure),original=A.retain(original),target=target,part=part,created=A.clock()}
  stats.created=stats.created+1;stats.available=stats.available-1;stats.active=stats.active+1;stats.maximum_active=math.max(stats.maximum_active,stats.active)
  return selected.prefab
 end
 function self.poll(completed)
  local now=A.clock()
  for key,v in pairs(leases)do
   if completed(v)then v.completed_since=v.completed_since or now else v.completed_since=nil end
   if v.completed_since and now-v.completed_since>=2 then v.slot.busy=false;leases[key]=nil;stats.active=stats.active-1;stats.released=stats.released+1 end
  end
 end
 function self.status()return stats end
 function self.close()leases={};catalogs={};slots={};stats.active=0;stats.available=0 end
 return self
end
return M

end)()
local Router=(function()
-- Own private Head/Hair IDs; let the original loader manage native part lifetimes.
local M={}
local function need(v,s)if not v then error(s,0)end;return v end
local function id(o)return o and tostring(o:get_address())or nil end
local function same(a,b)return a and b and id(a)==id(b)end
local function canon(p)return type(p)=='string'and scarlet_gate.route(p):gsub('\\','/'):lower():gsub('^@',''):gsub('%.%d+$','')or nil end
function M.new(C,Pool,env)
 local sdk=env.sdk;local defs,methods,fields={},{},{};local image
 for n,crc in pairs(C.crcs)do local t=sdk.find_type_definition(n);need(t and t:get_crc_hash()==crc,'Parts router type changed '..n);defs[n]=t end
 for _,s in ipairs(C.specs)do
  local f=defs[s.type]:get_method(s.name..'('..table.concat(s.params,', ')..')')
  need(f and f:get_num_params()==#s.params and f:get_return_type():get_full_name()==s.returns and f:is_static()==s.is_static,'Parts router method changed '..s.key)
  local base=sdk.to_int64(f:get_function())-s.rva;image=image or base;need(base==image,'Parts method image changed');methods[s.key]=f
 end
 for _,s in ipairs(C.fields)do local f=defs[s.type]:get_field(s.name);need(f and f:get_declaring_type():get_full_name()==s.type and f:get_type():get_full_name()==s.returns and f:get_offset_from_base()==s.offset,'Parts field changed '..s.key);fields[s.key]=f end
 local function call(k,o,...)local m=need(methods[k],'Unbound native method '..k);local good,value=pcall(m.call,m,o,...);if not good then error(k..': '..tostring(value),0)end;return value end
 local function managed(o,t)return o and sdk.is_managed_object(o)and o:get_type_definition():is_a(t)end
 local function retain(o)need(managed(o,'System.Object'),'Managed reference required');o:add_ref();need(o:get_reference_count()>0,'Native retain failed');return o end
 local function valid(go)return managed(go,'via.GameObject')and call('go_valid',go)==true end
 local function number(v,key)if type(v)=='number'then return v end;return fields[key]:get_data(v)end
 local function array(a,limit)local n=call('array_length',a,0);need(n>=0 and n<=limit,'Array bound');local r={};for i=0,n-1 do r[#r+1]=call('array_value',a,i)end;return r end
 local function resource(go)
  if not valid(go)then return nil end
  local out
  for _,m in ipairs(array(call('go_components',go),128))do if managed(m,'via.render.Mesh')and call('component_valid',m)and call('mesh_ready',m)then
   need(not out,'Multiple meshes on native part');out=canon(call('resource_path',call('mesh_holder',m)))
  end end
  return out
 end
 local function belongs_to(go,root)
  if not valid(go)then return false end
  local t=call('go_transform',go);local visited={}
  for _=1,32 do
   if not t or visited[id(t)]then return false end;visited[id(t)]=true
   if same(call('component_go',t),root)then return true end
   t=call('transform_parent',t)
  end
  return false
 end
 local object_types={};for _,part in ipairs({0,2,3})do object_types[part]=number(call('part_object_type',nil,part),'object_type_value')end
 local function part_go(s,part)return call(s.role=='ui'and'ui_part_go'or'player_part_go',s.processor,object_types[part])end
 local function ids(s)local a=fields[s.role..'_model_ids']:get_data(s.processor);need(a and call('array_length',a,0)==13,'Native model ID array changed');return a end
 local function current_id(s,part)return number(call('array_value',ids(s),part),'int_value')end
 local function private_id(value)return value==C.ids.head or value==C.ids.hair or(value>=C.native_alias_base and value<C.native_alias_base+65536)end
 local function busy(s)return call(s.role=='ui'and'ui_changing'or'player_changing',s.processor)end
 local owners={};local serial=0;local state={schema='scarlet-native-private-parts-router-v2',active=false,ready=false,events={},errors=0,catalog_adds=0,catalog_removes=0,requests_rewritten=0,reconcile_requests=0,cache_writes=0,save_writes=0,owners={},waiting={}}
 local function event(kind,data)
  serial=serial+1;state.events[#state.events+1]={sequence=serial,time=os.clock(),kind=kind,data=data};if #state.events>64 then table.remove(state.events,1)end
 end
 local function get_owner(processor,role)
  local pm=need(call('pm_instance',nil),'PlayerManager absent');local go
  if role=='ui'then
   need(managed(processor,'app.PlayerUICharacter')and call('component_valid',processor),'UI controller invalid');go=call('component_go',processor)
   need(same(go,call('pm_ui',pm)),'UI is not current registered preview')
  else
   need(managed(processor,'app.cPlayerGameObjectSupporter'),'Gameplay supporter type changed')
   local entity=fields.player_entity:get_data(processor);go=fields.entity_owner:get_data(entity)
   local info=call('pm_info',pm);local registered_go=info and call('info_go',info);local registered_entity=info and call('info_entity',info)
   need(info and call('info_valid',info)and same(go,registered_go)and same(entity,registered_entity),'Gameplay registration pending: supporterGO='..tostring(id(go))..', registeredGO='..tostring(id(registered_go))..', supporterEntity='..tostring(id(entity))..', registeredEntity='..tostring(id(registered_entity)))
  end
  need(valid(go),'Part owner is not valid')
  local key=id(go);local s=owners[key]
  if not s or not same(s.processor,processor)then
   s={key=key,go=retain(go),processor=retain(processor),role=role,requests=0,holds={},failures=0};owners[key]=s
   local h=current_id(s,2);local hair=current_id(s,3)
   if not private_id(h)then s.native_head=h end;if not private_id(hair)then s.native_hair=hair end
   event('owner_bound',{owner=key,role=role,head_id=h,hair_id=hair})
  end
  return s
 end
 local function try_owner(processor,role)
  local ok,value=pcall(get_owner,processor,role)
  if ok then state.waiting[role]=nil;return value end
  local reason=tostring(value)
  if state.waiting[role]~=reason then event('owner_not_ready',{role=role,reason=reason})end
  state.waiting[role]=reason
  return nil
 end
 local function family(path)if C.scarlet_bodies[path]then return'scarlet'end;if path and path:match('^art/model/character/')then return'native'end end
 local function new_list(values)
  state.last_native_operation='allocate List<ChangeArgument>'
  local list=retain(sdk.create_instance(C.list_type));state.last_native_operation='construct list capacity';call('list_ctor',list,#values);local hold={list}
  for _,row in ipairs(values)do
   -- This type has only .ctor(PARTS_TYPE, Int32), so do not invoke the default Activator path.
   state.last_native_operation='allocate ChangeArgument without default constructor'
   local a=retain(sdk.create_instance(C.arg_type,true));state.last_native_operation='construct ChangeArgument';call('arg_ctor',a,row.part,row.id)
   state.last_native_operation='append ChangeArgument';call('list_add',list,a);hold[#hold+1]=a
  end
  state.last_native_operation='native change list constructed'
  return list,hold
 end
 local function decode(list)
  need(managed(list,C.list_type),'Typed change list required');local n=call('list_count',list);need(n>=0 and n<=13,'Part request list bound')
  local values,by={},{}
  for i=0,n-1 do local a=call('list_get',list,i);local part=number(call('arg_part',a),'part_value');local value=call('arg_id',a)
   need(type(part)=='number'and part>=0 and part<=12 and not by[part],'Duplicate or invalid part request');local row={part=part,id=value};values[#values+1]=row;by[part]=row
  end
  return values,by
 end
 local function record_request(s,list)
  local values,by=decode(list);local desired
  if by[0]and C.known_body_ids[tostring(by[0].id)]then desired=(by[0].id==7482 or by[0].id==28284)and'scarlet'or'native';s.requested_family=desired;s.body_request_time=env.clock()
  else desired=s.requested_family or family(resource(part_go(s,0)))end
  for _,part in ipairs({2,3})do local row=by[part];if row and not private_id(row.id)then s[part==2 and'native_head'or'native_hair']=row.id end end
  -- Preserve native business IDs and the original list. Altering them on every check causes reload churn.
  return desired
 end
  local function private_path(path)
   local actual=canon(path);if not actual then return false end
   for expected in pairs(C.private_paths)do
    if actual==canon(expected)or actual==canon(expected:gsub('{id}','scarlet_hat_static'))or actual==canon(expected:gsub('{id}','scarlet_no_hat_static'))then return true end
   end
   return false
  end
 local pool_adapter={
  pin=function(path)need(C.private_paths[path],'Cannot pin a nonprivate prefab');local r=need(sdk.create_resource('via.PrefabResource',scarlet_gate.route(path)),'Native prefab resource creation failed');r:add_ref();return r end,
  unpin=function(r)r:release()end,
  create_catalog=function(p)return sdk.create_userdata('app.user_data.PlayerPartsList',p)end,is_catalog=function(o)return managed(o,'app.user_data.PlayerPartsList')end,retain=retain,
  catalog_count=function(o)local a=fields.catalog_data:get_data(o);return a and a:get_size()or nil end,get_prefab=function(o,i)return call('private_catalog_get',o,i)end,
  is_prefab=function(o)return managed(o,'via.Prefab')end,valid=function(o)return call('prefab_valid',o)end,path=function(o)return call('prefab_path',o)end,
  ready=function(o)return call('prefab_ready',o)end,standby=function(o)return call('prefab_standby',o)end,
  set_standby=function(o,v)need(private_path(call('prefab_path',o)),'Private prefab path required');call('private_standby_set',o,v)end}
 local pool=Pool.new(C,pool_adapter)
 local refresh_pool=Pool.new({catalogs=C.refresh_catalogs},pool_adapter)
 local private_routes={};for _,r in pairs(C.public_routes)do private_routes[r.private]=r end
 local requests=Leases.new({same=same,clock=env.clock,create_catalog=pool_adapter.create_catalog,catalog_count=pool_adapter.catalog_count,get_prefab=pool_adapter.get_prefab,get_standby=pool_adapter.standby,
  valid_type=function(p)return managed(p,'via.Prefab')end,path=function(p)return canon(call('prefab_path',p))end,
  retain=retain,standby=function(p,v)return call('private_standby_set',p,v)end,ready=function(p)return call('prefab_ready',p)end})
 local registrations={};local catalog_owner;local opened=env.clock();local prepared=false;local closed=false;local next_tick=opened+5
 local function retire_catalogs()
  for _,r in ipairs(registrations)do
   if call('dict_contains',r.dictionary,r.id)then
    need(same(call('dict_get',r.dictionary,r.id),r.prefab),'Foreign change to an owned private catalog key')
    need(call('dict_remove',r.dictionary,r.id),'Owned catalog removal failed');state.catalog_removes=state.catalog_removes+1
   end
  end
  registrations={};catalog_owner=nil
 end
 local function register_catalogs(pm)
  local catalog=fields.pm_catalog:get_data(pm);if not managed(catalog,'app.cPlayerCatalogHolder')then return false end
  if catalog_owner then
   local current=same(catalog,catalog_owner)
   for _,r in ipairs(registrations)do
    local dictionary=call(r.quality=='NORMAL'and'catalog_normal'or'catalog_hq',catalog,r.part)
    current=current and same(dictionary,r.dictionary)and call('dict_contains',r.dictionary,r.id)and same(call('dict_get',r.dictionary,r.id),r.prefab)
   end
   if current then return true end
   retire_catalogs();event('catalog_generation_changed',{})
  end
  local pending={}
  for _,entry in ipairs(C.catalogs)do for _,part in ipairs(entry.prefabs)do
   local kind=part.id==25571 and'head'or'hair';local part_type=kind=='head'and 2 or 3
   local dictionary=call(entry.quality=='NORMAL'and'catalog_normal'or'catalog_hq',catalog,part_type)
   if not managed(dictionary,C.dictionary_type)then return false end
   need(not call('dict_contains',dictionary,C.ids[kind]),'Private part ID already occupied')
   local prefab=need(refresh_pool.get_ready(part.path),'Refresh prefab not ready');pending[#pending+1]={dictionary=retain(dictionary),prefab=prefab,id=C.ids[kind],part=part_type,quality=entry.quality}
  end end
  for _,r in ipairs(pending)do call('dict_add',r.dictionary,r.id,r.prefab);registrations[#registrations+1]=r;state.catalog_adds=state.catalog_adds+1;need(same(call('dict_get',r.dictionary,r.id),r.prefab),'Private catalog readback differs')end
  catalog_owner=retain(catalog);state.active=true;event('catalogs_registered',{entries=#registrations});return true
 end
 local function native_alias(s,part)
  local original=s[part==2 and'native_head'or'native_hair'];need(type(original)=='number'and original>=0 and original<65536 and not private_id(original),'Native part ID not resolved')
  -- INVALID Head resolves to the sole original Head entry; actual initial registration established HEAD000.
  if part==2 and original==4202 then original=25571 end
  local alias=C.native_alias_base+original
  for _,quality in ipairs({'NORMAL','HQ'})do
   local dictionary=call(quality=='NORMAL'and'catalog_normal'or'catalog_hq',catalog_owner,part)
   need(call('dict_contains',dictionary,original),'Original native prefab is not in its actual catalog')
   local prefab=call('dict_get',dictionary,original)
   if call('dict_contains',dictionary,alias)then need(same(call('dict_get',dictionary,alias),prefab),'Native alias ID occupied')
   else call('dict_add',dictionary,alias,prefab);registrations[#registrations+1]={dictionary=retain(dictionary),prefab=retain(prefab),id=alias,part=part,quality=quality};state.catalog_adds=state.catalog_adds+1 end
  end
  return alias
 end
 local function visual_matches(s,part,actual)
  local path=resource(part_go(s,part));if not path then return false end
  if actual=='scarlet'then return path==canon(part==2 and scarlet_gate.route(C.scarlet_head_mesh) or scarlet_gate.route(C.scarlet_hair_mesh))end
  if part==2 then return path==C.native_head_mesh end
  return path:match('^art/model/character/')~=nil
 end
 local function reconcile(s)
  local body=part_go(s,0);local actual=family(resource(body));if not actual then return end
  if s.requested_family and s.requested_family~=actual then
   if env.clock()-(s.body_request_time or env.clock())>10 then error('Requested body family did not become the actual native Body',0)end
   return
  end
  s.requested_family=nil;s.active_family=actual
  local generation=id(body)..':'..actual
  if s.generation~=generation then s.generation=generation;s.failures=0;s.last_submit=nil end
  local values={};local view={owner=s.key,role=s.role,body=id(body),body_resource=resource(body),family=actual,head=resource(part_go(s,2)),hair=resource(part_go(s,3)),head_id=current_id(s,2),hair_id=current_id(s,3)}
  if s.role=='player'then
   local pm=call('pm_instance',nil);local info=call('pm_info',pm);local context=call('context_player',call('info_context',info))
   view.context_head_id=call('context_head',context);view.context_hair_id=call('context_hair',context)
  end
  state.owners[s.key]=view
  if busy(s)then return end
  for _,part in ipairs({2,3})do
   local native_key=part==2 and'native_head'or'native_hair';local current=current_id(s,part)
   if not private_id(current)then s[native_key]=current end
   if not visual_matches(s,part,actual)then
    local wanted=actual=='scarlet'and C.ids[part==2 and'head'or'hair']or native_alias(s,part)
    values[#values+1]={part=part,id=wanted}
   end
  end
  if #values==0 then s.holds={};s.last_submit=nil;return end
  if s.last_submit and env.clock()-s.last_submit<3 then return end
  need(s.failures<2,'Native private part IDs did not stay applied; no repeated retries')
  local list,hold=new_list(values);s.holds[#s.holds+1]=hold;s.last_submit=env.clock();s.failures=s.failures+1;s.requests=s.requests+1
  call(s.role=='ui'and'ui_request_list'or'player_request_list',s.processor,list);state.reconcile_requests=state.reconcile_requests+1
  event('initial_parts_requested',{owner=s.key,role=s.role,family=actual,parts=values})
 end
 for _,hook in ipairs({{key='ui_request_list',role='ui'},{key='player_request_list',role='player'}})do
  sdk.hook(methods[hook.key],function(args)
   if closed or not state.active or not scarlet_gate.allow('private_parts_request') then return end
   local ok,why=pcall(function()
    local s=try_owner(sdk.to_managed_object(args[2]),hook.role);if not s or s.disabled then return end
    record_request(s,sdk.to_managed_object(args[3]))
   end)
   if not ok then state.errors=state.errors+1;state.last_error=tostring(why);event('request_not_routed',{role=hook.role,error=state.last_error})end
  end,function(ret)return ret end)
 end
 local function read_route_object(field,object,label)
  local ok,value=pcall(field.get_data,field,object)
  if ok then return true,value end
  if tostring(value):match('sol_lua_push: %d+ is not a managed object')then
   state.cancelled_route_reads=(state.cancelled_route_reads or 0)+1
   event('expired_route_skipped',{field=label,error=tostring(value)})
   return false,nil
  end
  error(value,0)
 end
 for _,h in ipairs(C.closure_hooks)do
  sdk.hook(methods[h.key],function(args)
   if closed or not state.active or not scarlet_gate.allow('private_parts_closure') then return end
   local ok,why=xpcall(function()
    local object=sdk.to_managed_object(args[2]);local readable,go=read_route_object(fields[h.key..'_owner'],object,'owner');if not readable or not valid(go)then return end
    local s=owners[id(go)];if not s or s.disabled then return end
    local verified=try_owner(s.processor,s.role);if verified~=s then return end
    local desired=s.requested_family or family(resource(part_go(s,0)))
    if desired~='scarlet'then return end
    local part=number(fields[h.key..'_part']:get_data(object),'part_value');if part~=2 and part~=3 then return end
    local readable,target=read_route_object(fields[h.key..'_target'],object,'target');if not readable or(target and not valid(target))then return end
    if target and not belongs_to(target,go)then state.last_skipped_route={reason='target is outside the current owner hierarchy',owner=s.key,part=part,target=id(target)};return end
    local readable,original=read_route_object(fields[h.key..'_prefab'],object,'prefab');if not readable or not managed(original,'via.Prefab')then return end
    local path=canon(call('prefab_path',original));local route=C.public_routes[path]or private_routes[path]
    if not route or route.parts_type~=part then state.last_skipped_route={reason='actual Prefab is outside the exact Head/Hair map',owner=s.key,part=part,prefab=path};return end
    local replacement=pool.get_ready(route.private);if not replacement then state.resource_wait=route.private;event('native_prefab_wait',{owner=s.key,part=part,original=path,private=route.private,pool=pool.poll()});return end
    replacement=requests.acquire(id(object),replacement,route.private,s.go,object,original,id(target),part)
    local written,reason=pcall(function()object:set_field('prefab',replacement);need(same(fields[h.key..'_prefab']:get_data(object),replacement),'Native prefab route readback failed')end)
    if not written then
     pcall(function()if same(fields[h.key..'_prefab']:get_data(object),replacement)then object:set_field('prefab',original)end end)
     error(reason,0)
    end
    state.prefab_routes=(state.prefab_routes or 0)+1
    event('native_prefab_routed',{owner=s.key,role=s.role,part=part,quality=route.quality,loader=h.key,original=path,private=route.private})
   end,debug.traceback)
   if not ok then state.errors=state.errors+1;state.last_error=tostring(why);event('prefab_route_failed',state.last_error)end
  end,function(ret)return ret end)
 end
 local self={status=function()state.latest_sequence=serial;return state end}
 function self.step()
   if scarlet_gate.static_catalog_verified() then state.ready=true;state.active=false;state.static_catalog_mode=true;return end
  if closed or state.fatal_error then return end
  local now=env.clock();if now<next_tick then return end;next_tick=now+.25
  local ok,why=pcall(function()
   if not prepared then prepared=true;pool.prepare();refresh_pool.prepare()end
   state.pool=pool.poll()
   state.refresh_pool=refresh_pool.poll()
   if not state.pool.ready or not state.refresh_pool.ready then state.pool_wait_since=state.pool_wait_since or now;need(now-state.pool_wait_since<25,'Private resource did not recover readiness within25 seconds');return end
   state.pool_wait_since=nil;state.resource_wait=nil
   if not requests.prepare(C.lease_catalogs)then need(env.clock()-opened<30 or state.active,'Native lease catalogs did not load');return end
   local pm=call('pm_instance',nil);if not pm or not register_catalogs(pm)then return end;state.ready=true
   local present={}
   local info=call('pm_info',pm)
   if info and call('info_valid',info)then
    local entity=call('info_entity',info);local processor=entity and call('entity_supporter',entity)
    if processor then local s=try_owner(processor,'player');if s then present[s.key]=true;if not s.disabled then local good,reason=pcall(reconcile,s);if not good then s.disabled=true;state.errors=state.errors+1;event('owner_reconcile_failed',{owner=s.key,role=s.role,error=tostring(reason)})end end end end
   end
   local go=call('pm_ui',pm)
   if valid(go)and call('pm_ui_ready',pm)then
    for _,c in ipairs(array(call('go_components',go),128))do if managed(c,'app.PlayerUICharacter')and call('component_valid',c)then
     local s=try_owner(c,'ui');if s then present[s.key]=true;if not s.disabled then local good,reason=pcall(reconcile,s);if not good then s.disabled=true;state.errors=state.errors+1;event('owner_reconcile_failed',{owner=s.key,role=s.role,error=tostring(reason)})end end end
    end end
   end
   requests.poll(function(r)
    if not valid(r.owner)then return true end
    local s=owners[id(r.owner)];if not s or busy(s)then return false end
    local part=part_go(s,r.part);return valid(part)and id(part)~=r.target and visual_matches(s,r.part,'scarlet')
   end)
   state.request_leases=requests.status()
   for key in pairs(owners)do if not present[key]then owners[key]=nil;state.owners[key]=nil end end
  end)
  if not ok then state.active=false;state.fatal_error=tostring(why);event('router_stopped',state.fatal_error)end
 end
 function self.pause()
  if closed then return end;state.active=false;state.quarantined=true
  local ok,why=pcall(retire_catalogs);if not ok then state.cleanup_error=tostring(why)end;return ok
 end
 function self.resume()state.quarantined=false;return true end
 function self.close()
  if closed then return end
  closed=true;state.active=false;state.closed=true
  local ok,why=pcall(retire_catalogs);if not ok then state.cleanup_error=tostring(why)end
  local a,e=pcall(pool.close);if not a then state.pool_cleanup_error=tostring(e)end
  local b,f=pcall(refresh_pool.close);if not b then state.refresh_cleanup_error=tostring(f)end
  requests.close();owners={};state.owners={};event('closed',{catalog_entries_remaining=#registrations,cleanup_error=state.cleanup_error})
 end
 return self
end
return M

end)()
return{new=function(env)return Router.new(C,Pool,env)end}

end)()

local instance,boot_error,closed
local good,why=pcall(function()assert(adapter and controller,'Body adapter not ready');instance=Factory.new({sdk=sdk,clock=function()return adapter.clock()/adapter.frequency()end})end)
if not good then boot_error=tostring(why)end
local original_status=_G.scarlet_manual_adapter.status
_G.scarlet_manual_adapter.status=function()local s=original_status();s.private_parts=instance and instance.status()or{error=boot_error};return s end
 scarlet_gate.on_disable(function()if instance and instance.pause then local ok,result=pcall(instance.pause);return ok and result~=false end;return true end)
local last_write=-1
re.on_frame(function()
 if not scarlet_gate.allow('private_parts_frame') then return end
 if instance and instance.resume then instance.resume()end
 if closed then return end
 if instance then instance.step()end
 local now=os.clock();if now-last_write>=.25 then
  last_write=now;local s=instance and instance.status()or{error=boot_error};s.written_at=os.time();s.runtime_tag=tostring(instance)
  pcall(json.dump_file,'scarlet-native-private-parts-status.json',s)
 end
end)
re.on_script_reset(function()scarlet_reset_required=true;scarlet_reset_reason='script_reset_requires_restart';end)
end

do
local Prop=(function()
-- Hide only the equipped native prop meshes owned by Scarlet; retain public assets.
local M={}
function M.new(C,sdk)
 local defs,methods,fields={},{},{};local image;local closed=false;local paused=false;local leases={}
 local S={schema='scarlet-owned-prop-visibility-v1',ticks=0,hides=0,restores=0,expired=0,faults=0,owners={},live_leases=0}
 local function need(x,s)if not x then error(s,0)end;return x end
 local function id(o)return o and tostring(o:get_address())end
 local function managed(o,t)return o and sdk.is_managed_object(o)and o:get_type_definition():is_a(t)end
 local function same(a,b)return a and b and id(a)==id(b)end
 local function canon(p)return p and scarlet_gate.route(p):lower():gsub('\\','/'):gsub('^@',''):gsub('%.%d+$','')end
 for n,crc in pairs(C.crcs)do local t=sdk.find_type_definition(n);need(t and t:get_crc_hash()==crc,'Prop visibility type changed '..n);defs[n]=t end
 for _,s in ipairs(C.specs)do
  local f=defs[s.type]:get_method(s.name..'('..table.concat(s.params,', ')..')')
  need(f and f:get_num_params()==#s.params and f:get_return_type():get_full_name()==s.returns and f:is_static()==s.is_static,'Prop visibility method changed '..s.key)
  local base=sdk.to_int64(f:get_function())-s.rva;image=image or base;need(base==image,'Prop visibility native image changed');methods[s.key]=f
 end
 for _,s in ipairs(C.fields)do local f=defs[s.type]:get_field(s.name);need(f and f:get_type():get_full_name()==s.returns and f:get_offset_from_base()==s.offset,'Prop visibility field changed');fields[s.key]=f end
 local function call(k,o,...)return methods[k]:call(o,...)end
 local function valid(go)return managed(go,'via.GameObject')and call('go_valid',go)end
 local function components(go)
  local a=call('go_components',go);local n=call('array_length',a,0);need(n>=0 and n<=128,'Prop component array bound')
  local out={};for i=0,n-1 do out[#out+1]=call('array_value',a,i)end;return out
 end
 local function belongs(go,root)
  if not valid(go)or not valid(root)then return false end
  local tr=call('go_transform',go);local seen={}
  for _=1,32 do
   if not tr or seen[id(tr)]then return false end;seen[id(tr)]=true
   if same(call('component_go',tr),root)then return true end;tr=call('transform_parent',tr)
  end
  return false
 end
 local objects={};for _,p in ipairs({0,4,10,11})do local o=call('part_object_type',nil,p);objects[p]=type(o)=='number'and o or fields.object_type_value:get_data(o)end
 local function find_mesh(go)
  if not valid(go)then return end
  local mesh
  for _,x in ipairs(components(go))do if managed(x,'via.render.Mesh')and call('component_valid',x)then need(not mesh,'Ambiguous prop Mesh');mesh=x end end
  if mesh and call('mesh_ready',mesh)then return mesh,canon(call('resource_path',call('mesh_holder',mesh)))end
 end
 local function release(key)
  local r=leases[key];if not r then return end
  if valid(r.go)and call('component_valid',r.mesh)and same(call('component_go',r.mesh),r.go)then
   local current,path=find_mesh(r.go)
   if same(current,r.mesh)and path==r.path then
    if call('mesh_enabled',r.mesh)~=r.before then call('mesh_set_enabled',r.mesh,r.before);S.restores=S.restores+1 end
   else S.expired=S.expired+1 end
  else S.expired=S.expired+1 end
  leases[key]=nil
 end
 local function inspect(root,processor,role,seen)
  if not valid(root)then return end
  local get=role=='ui'and'ui_part_go'or'player_part_go'
  local body=call(get,processor,objects[0]);local _,body_path=find_mesh(body)
  if not body_path then
   S.owners[id(root)]={role=role,waiting_for_body=true}
   for key,r in pairs(leases)do if r.owner==id(root)then seen[key]=true end end
   return
  end
  local scarlet=C.scarlet_bodies[body_path]==true
  local view={role=role,body=body_path,family=scarlet and'scarlet'or'native',parts={}}
  S.owners[id(root)]=view
  for _,part in ipairs({4,10,11})do
   local go=call(get,processor,objects[part]);local mesh,path=find_mesh(go)
   if mesh and belongs(go,root)then
    local key=id(mesh);local native=C.meshes[tostring(part)][path]==true
    local before=call('mesh_enabled',mesh)
    if scarlet and native then
     seen[key]=true
     local r=leases[key]
     if not r then need(S.live_leases<64,'Prop visibility lease bound');mesh:add_ref();go:add_ref();r={go=go,mesh=mesh,path=path,before=before,owner=id(root)};leases[key]=r end
     need(r.owner==id(root)and same(r.go,go)and r.path==path,'Prop ownership changed without generation change')
     if before then call('mesh_set_enabled',mesh,false);S.hides=S.hides+1 end
    elseif leases[key]then release(key)end
    view.parts[tostring(part)]={mesh=path,go=id(go),mesh_address=id(mesh),enabled=call('mesh_enabled',mesh),native_resource=native,owned_hidden=leases[key]~=nil}
   end
  end
 end
 local self={}
 function self.step()
  if closed or paused then return end
  local ok,e=pcall(function()
   S.ticks=S.ticks+1;S.owners={};local seen={};local pm=call('pm_instance',nil)
   if pm then
    local info=call('pm_info',pm)
    if info and call('info_valid',info)then
     local root=call('info_go',info);local entity=call('info_entity',info);local supporter=entity and call('entity_supporter',entity)
     if supporter then inspect(root,supporter,'player',seen)end
    end
    local root=call('pm_ui',pm)
    if valid(root)then for _,c in ipairs(components(root))do if managed(c,'app.PlayerUICharacter')and call('component_valid',c)then inspect(root,c,'ui',seen)end end end
   end
   local old={};for key in pairs(leases)do if not seen[key]then old[#old+1]=key end end;for _,key in ipairs(old)do release(key)end
   local count=0;for _ in pairs(leases)do count=count+1 end;S.live_leases=count
  end)
  if not ok then S.faults=S.faults+1;S.last_error=tostring(e);self.close()end
 end
 function self.pause()
  if closed then return true end;local all=true;local old={};for key in pairs(leases)do old[#old+1]=key end;for _,key in ipairs(old)do local ok=pcall(release,key);if not ok then all=false end end;paused=true;return all
 end
 function self.resume()if not closed then paused=false end;return true end
 function self.close()
  closed=true;local old={};for key in pairs(leases)do old[#old+1]=key end
  for _,key in ipairs(old)do local ok,e=pcall(release,key);if not ok then S.restore_error=tostring(e)end end
 end
 function self.status()S.closed=closed;return S end
 return self
end
return M

end)()
local C=json.load_string([=[{"schema":"scarlet-prop-visibility-contract-v1","specs":[{"key":"array_length","type":"System.Array","name":"GetLength","params":["System.Int32"],"returns":"System.Int32","is_static":false,"rva":114447776,"hook_only":false},{"key":"array_value","type":"System.Array","name":"GetValue","params":["System.Int32"],"returns":"System.Object","is_static":false,"rva":114447856,"hook_only":false},{"key":"component_go","type":"via.Component","name":"get_GameObject","params":[],"returns":"via.GameObject","is_static":false,"rva":94821856,"hook_only":false},{"key":"component_valid","type":"via.Component","name":"get_Valid","params":[],"returns":"System.Boolean","is_static":false,"rva":94763376,"hook_only":false},{"key":"entity_supporter","type":"app.cPlayerCharacterEntity","name":"get_GameObjectSupporter","params":[],"returns":"app.cPlayerGameObjectSupporter","is_static":false,"rva":108612672,"hook_only":false},{"key":"go_components","type":"via.GameObject","name":"get_Components","params":[],"returns":"via.Component[]","is_static":false,"rva":97957600,"hook_only":false},{"key":"go_transform","type":"via.GameObject","name":"get_Transform","params":[],"returns":"via.Transform","is_static":false,"rva":97957552,"hook_only":false},{"key":"go_valid","type":"via.GameObject","name":"get_Valid","params":[],"returns":"System.Boolean","is_static":false,"rva":94806192,"hook_only":false},{"key":"info_entity","type":"app.cPlayerManageInfo","name":"get_CharacterEntity","params":[],"returns":"app.cPlayerCharacterEntity","is_static":false,"rva":94387552,"hook_only":false},{"key":"info_go","type":"app.cPlayerManageInfo","name":"get_Object","params":[],"returns":"via.GameObject","is_static":false,"rva":86045520,"hook_only":false},{"key":"info_valid","type":"app.cPlayerManageInfo","name":"get_Valid","params":[],"returns":"System.Boolean","is_static":false,"rva":125839200,"hook_only":false},{"key":"mesh_holder","type":"via.render.Mesh","name":"getMesh","params":[],"returns":"via.render.MeshResourceHolder","is_static":false,"rva":122190144,"hook_only":false},{"key":"mesh_ready","type":"via.render.Mesh","name":"get_MeshReady","params":[],"returns":"System.Boolean","is_static":false,"rva":122191152,"hook_only":false},{"key":"part_object_type","type":"app.cPlayerGameObjectSupporter","name":"convertObjTypeToPartsType","params":["app.PlayerPartsDef.PARTS_TYPE"],"returns":"app.cPlayerGameObjectSupporter.PLAYER_GAME_OBJECT","is_static":true,"rva":11360992,"hook_only":false},{"key":"player_part_go","type":"app.cPlayerGameObjectSupporter","name":"getGameObject","params":["app.cPlayerGameObjectSupporter.PLAYER_GAME_OBJECT"],"returns":"via.GameObject","is_static":false,"rva":3268272,"hook_only":false},{"key":"pm_info","type":"app.PlayerManager","name":"getControllingPlayer","params":[],"returns":"app.cPlayerManageInfo","is_static":false,"rva":77873440,"hook_only":false},{"key":"pm_instance","type":"ace.GAElement`1<app.PlayerManager>","name":"get_Instance","params":[],"returns":"app.PlayerManager","is_static":true,"rva":109939872,"hook_only":false},{"key":"pm_ui","type":"app.PlayerManager","name":"getControllingPlayerUI","params":[],"returns":"via.GameObject","is_static":false,"rva":111300480,"hook_only":false},{"key":"resource_path","type":"via.ResourceHolder","name":"get_ResourcePath","params":[],"returns":"System.String","is_static":false,"rva":116635664,"hook_only":false},{"key":"transform_parent","type":"via.Transform","name":"get_Parent","params":[],"returns":"via.Transform","is_static":false,"rva":125570976,"hook_only":false},{"key":"ui_part_go","type":"app.PlayerUICharacter","name":"getGameObject","params":["app.cPlayerGameObjectSupporter.PLAYER_GAME_OBJECT"],"returns":"via.GameObject","is_static":false,"rva":12137456,"hook_only":false},{"key":"mesh_enabled","type":"via.render.Mesh","name":"get_Enabled","params":[],"returns":"System.Boolean","is_static":false,"rva":101519712},{"key":"mesh_set_enabled","type":"via.render.Mesh","name":"set_Enabled","params":["System.Boolean"],"returns":"System.Void","is_static":false,"rva":122191136}],"fields":[{"key":"object_type_value","type":"app.cPlayerGameObjectSupporter.PLAYER_GAME_OBJECT","name":"value__","returns":"System.Int32","offset":16}],"scarlet_bodies":{"mods/scarlet_hat_static/6516e70211991f0b/body_mesh_2de4180b65dbe6b20a.mesh":true,"mods/scarlet_no_hat_static/67cc2ab84782dc5b/body_mesh_ae4e361f60ab521537.mesh":true},"meshes":{"4":{"art/model/character/ch0/ch001_00/60/ch001_00_60.mesh":true},"10":{"art/model/character/ch0/ch001_00/71/ch001_00_71.mesh":true,"art/model/character/ch0/ch001_00/72/ch001_00_72.mesh":true,"art/model/character/ch0/ch001_00/73/ch001_00_73.mesh":true,"art/model/character/ch0/ch001_00/74/ch001_00_74.mesh":true,"art/model/character/ch0/ch001_00/75/ch001_00_75.mesh":true},"11":{"art/model/character/ch0/ch001_00/70/ch001_00_70.mesh":true}},"crcs":{"ace.GAElement`1<app.PlayerManager>":437989116,"app.PlayerManager":346041440,"app.cPlayerGameObjectSupporter.PLAYER_GAME_OBJECT":4280628242,"app.PlayerUICharacter":2159145370,"via.GameObject":4065074914,"app.cPlayerGameObjectSupporter":1646483854,"via.render.Mesh":1829138609,"via.ResourceHolder":1072471267,"via.Component":1881844667,"System.Array":58605515,"app.cPlayerManageInfo":3185740719,"via.Transform":1340992935,"app.cPlayerCharacterEntity":4067958465}}]=])
local good,instance=pcall(Prop.new,C,sdk)
scarlet_gate.on_disable(function()if good and instance and instance.pause then local ok,result=pcall(instance.pause);return ok and result~=false end;return true end)
local api=_G.scarlet_manual_adapter;local previous=api.status
api.status=function()local s=previous();s.native_prop_visibility=good and instance.status()or{faults=1,error=tostring(instance)};return s end
re.on_pre_application_entry('BeginRendering',function()if not scarlet_gate.allow('BeginRendering') then return end;if good and instance then if instance.resume then instance.resume()end;instance.step()end end)
re.on_script_reset(function()scarlet_reset_required=true;scarlet_reset_reason='script_reset_requires_restart';end)
end

do
local FitMath=(function()
local M={}
function M.add(a,b)return{a[1]+b[1],a[2]+b[2],a[3]+b[3]}end
function M.sub(a,b)return{a[1]-b[1],a[2]-b[2],a[3]-b[3]}end
function M.mul(a,s)return{a[1]*s,a[2]*s,a[3]*s}end
function M.dot(a,b)return a[1]*b[1]+a[2]*b[2]+a[3]*b[3]end
function M.cross(a,b)return{a[2]*b[3]-a[3]*b[2],a[3]*b[1]-a[1]*b[3],a[1]*b[2]-a[2]*b[1]}end
function M.length(v)return math.sqrt(M.dot(v,v))end
function M.unit(v)local n=M.length(v);assert(n>1e-10,'Degenerate arm vector');return M.mul(v,1/n)end
function M.qnorm(q)local n=math.sqrt(q[1]^2+q[2]^2+q[3]^2+q[4]^2);assert(n>1e-10,'Degenerate rotation');return{q[1]/n,q[2]/n,q[3]/n,q[4]/n}end
function M.qmul(a,b)return M.qnorm({a[4]*b[1]+a[1]*b[4]+a[2]*b[3]-a[3]*b[2],a[4]*b[2]-a[1]*b[3]+a[2]*b[4]+a[3]*b[1],a[4]*b[3]+a[1]*b[2]-a[2]*b[1]+a[3]*b[4],a[4]*b[4]-a[1]*b[1]-a[2]*b[2]-a[3]*b[3]})end
function M.qinv(q)q=M.qnorm(q);return{-q[1],-q[2],-q[3],q[4]}end
function M.rotate(q,v)q=M.qnorm(q);local xyz={q[1],q[2],q[3]};local t=M.mul(M.cross(xyz,v),2);return M.add(v,M.add(M.mul(t,q[4]),M.cross(xyz,t)))end
function M.from_to(a,b)
 a=M.unit(a);b=M.unit(b);local d=math.max(-1,math.min(1,M.dot(a,b)))
 if d>1-1e-10 then return{0,0,0,1}end
 if d< -1+1e-8 then local basis=math.abs(a[1])<.8 and{1,0,0}or{0,1,0};local axis=M.unit(M.cross(a,basis));return{axis[1],axis[2],axis[3],0}end
 local c=M.cross(a,b);return M.qnorm({c[1],c[2],c[3],1+d})
end
function M.solve(shoulder,elbow,hand,target,upper_q,forearm_q,pole_hint)
 local upper=M.sub(elbow,shoulder);local lower=M.sub(hand,elbow);local a=M.length(upper);local b=M.length(lower)
 assert(a>.05 and a<1 and b>.05 and b<1,'Unexpected arm dimensions')
 local vector=M.sub(target,shoulder);local distance=M.length(vector);local dir=distance>1e-8 and M.mul(vector,1/distance)or M.unit(M.sub(hand,shoulder))
 local d=math.max(math.abs(a-b)+1e-6,math.min(a+b-1e-6,distance))
 local pole=pole_hint or upper;pole=M.sub(pole,M.mul(dir,M.dot(pole,dir)))
 if M.length(pole)<1e-7 then local basis=math.abs(dir[2])<.8 and{0,1,0}or{0,0,1};pole=M.cross(dir,basis)end
 pole=M.unit(pole);local along=(a*a-b*b+d*d)/(2*d);local height=math.sqrt(math.max(0,a*a-along*along))
 local next_elbow=M.add(shoulder,M.add(M.mul(dir,along),M.mul(pole,height)));local next_hand=M.add(shoulder,M.mul(dir,d))
 return{upper_rotation=M.qmul(M.from_to(upper,M.sub(next_elbow,shoulder)),upper_q),forearm_rotation=M.qmul(M.from_to(lower,M.sub(next_hand,next_elbow)),forearm_q),elbow=next_elbow,hand=next_hand,clamp_distance=math.abs(distance-d),upper_length=a,lower_length=b}
end
return M

end)()
local Fit=(function()
-- Correct the owned animated left arm before native sheath joint placement.
local M={}
function M.new(C,sdk,thread,A,V)
 local defs,methods,fields={},{},{};local image;local closed=false;local cached
 local S={schema='scarlet-left-sheath-reference-fit-v1',entries=0,matched=0,writes=0,faults=0,right_arm_writes=0,position_writes=0,original_calls_skipped=0,clamped=0,max_clamp_m=0,max_native_hand_error_m=0,max_right_drift_m=0,ticks=0,max_ticks=0,frequency=A.frequency(),records={}}
 local function need(v,s)if not v then error(s,0)end;return v end
 local function id(o)return o and tostring(o:get_address())end
 local function same(a,b)return a and b and id(a)==id(b)end
 for n,crc in pairs(C.crcs)do local d=sdk.find_type_definition(n);need(d and d:get_crc_hash()==crc,'Left fit type changed '..n);defs[n]=d end
 for _,s in ipairs(C.methods)do local m=defs[s.type]:get_method(s.name..'('..table.concat(s.params,', ')..')')
  need(m and m:get_num_params()==#s.params and m:get_return_type():get_full_name()==s.returns and m:is_static()==s.is_static,'Left fit method changed '..s.key)
  local b=sdk.to_int64(m:get_function())-s.rva;image=image or b;need(image==b,'Left fit native image changed');methods[s.key]=m
 end
 for _,s in ipairs(C.fields)do local f=defs[s.type]:get_field(s.name);need(f and f:get_type():get_full_name()==s.returns and f:get_offset_from_base()==s.offset,'Left fit field changed');fields[s.key]=f end
 local function call(k,o,...)return methods[k]:call(o,...)end
 local function field(k,o)return fields[k]:get_data(o)end
 local function vec(v)return{v.x,v.y,v.z}end
 local function quat(q)return V.qnorm({q.x,q.y,q.z,q.w})end
 local function p(j)return vec(call('joint_p',j))end
 local function q(j)return quat(call('joint_q',j))end
 local function setq(j,r)local t=Quaternion.new();t.x=r[1];t.y=r[2];t.z=r[3];t.w=r[4];call('joint_set_q',j,t);S.writes=S.writes+1 end
 local function slerp(a,b,t)
  local dot=0;for i=1,4 do dot=dot+a[i]*b[i]end
  if dot<0 then b={-b[1],-b[2],-b[3],-b[4]};dot=-dot end
  if dot>.9995 then return V.qnorm({a[1]+(b[1]-a[1])*t,a[2]+(b[2]-a[2])*t,a[3]+(b[3]-a[3])*t,a[4]+(b[4]-a[4])*t})end
  local angle=math.acos(math.max(-1,math.min(1,dot)));local d=math.sin(angle);local x,y=math.sin((1-t)*angle)/d,math.sin(t*angle)/d
  return V.qnorm({a[1]*x+b[1]*y,a[2]*x+b[2]*y,a[3]*x+b[3]*y,a[4]*x+b[4]*y})
 end
 local function reference(frame)
  local rows=C.curve;local a,b=1,#rows
  if frame<=rows[a][1]then return{rows[a][2],rows[a][3],rows[a][4]},{rows[a][5],rows[a][6],rows[a][7],rows[a][8]}end
  if frame>=rows[b][1]then return{rows[b][2],rows[b][3],rows[b][4]},{rows[b][5],rows[b][6],rows[b][7],rows[b][8]}end
  while b-a>1 do local m=math.floor((a+b)/2);if rows[m][1]<=frame then a=m else b=m end end
  local x,y=rows[a],rows[b];local t=(frame-x[1])/(y[1]-x[1]);return{x[2]+(y[2]-x[2])*t,x[3]+(y[3]-x[3])*t,x[4]+(y[4]-x[4])*t},slerp({x[5],x[6],x[7],x[8]},{y[5],y[6],y[7],y[8]},t)
 end
 local function owner(address)
  local ctx=A.peek_owned_player();if not ctx or ctx.kind~='player'or ctx.skip_native or not A.current_owner_context(ctx)then cached=nil;return end
  if cached and cached.ctx==ctx and cached.key==ctx.key then if id(cached.updater)==address then return cached end;return end
  local pm=call('pm',nil);local info=pm and call('info',pm);if not info then return end
  local character,entity=call('character',info),call('entity',info);if not character or not same(call('component_go',character),ctx.actor)then return end
  local updater=call('sheath',entity);if not updater or id(updater)~=address then return end
  local tr=call('transform',ctx.actor);local mot
  local components=call('components',ctx.actor);local count=call('array_length',components,0);need(count>=0 and count<=128,'Owned component array bound')
  for i=0,count-1 do local c=call('array_value',components,i);if c and c:get_type_definition():is_a('via.motion.Motion')then need(not mot,'Multiple owned actor motions');mot=c end end
  cached={ctx=ctx,key=ctx.key,updater=updater,character=character,entity=entity,tr=tr,motion=mot,joints={}}
  for _,name in ipairs(C.joints)do local j=call('joint',tr,name);need(j and call('joint_name',j)==name,'Left fit anatomical joint differs');cached.joints[name]=j end
  return cached
 end
 local function fail(e)S.faults=S.faults+1;S.last_error=tostring(e);closed=true end
 sdk.hook(methods.update_joint,function(args)
  local store=thread.get_hook_storage();store.scarlet_left_reference=nil;S.entries=S.entries+1;if closed or not scarlet_gate.allow('left_fit_updateJoint') then return end
  local start=A.clock();local ok,e=pcall(function()
   local o=owner(tostring(sdk.to_int64(args[2])));if not o then return end
   local state=field('state',o.updater);if not state or field('hold_rate',state)>0.0001 then return end
   local ac=call('action_controller',o.character);local action=ac and call('current_action',ac);if not action or action:get_type_definition():get_full_name()~='app.PlayerBasicAction.cAutoWeaponOffIdle'then return end
   need(o.motion,'Owned actor Motion absent');local layer=call('layer',o.motion,0);if call('layer_bank',layer)~=10000 or call('layer_motion',layer)~=747 then return end
   local frame=call('layer_frame',layer);local relative,rq=reference(frame);local j=o.joints;local rightp,rightq=p(j.R_Hand),q(j.R_Hand)
   local desiredq=V.qmul(rightq,V.qinv(rq));local desiredp=V.sub(rightp,V.rotate(desiredq,relative))
   local shoulder,elbow,hand=p(j.L_UpperArm),p(j.L_Forearm),p(j.L_Hand)
   local solved=V.solve(shoulder,elbow,hand,desiredp,q(j.L_UpperArm),q(j.L_Forearm),V.sub(elbow,shoulder))
   setq(j.L_UpperArm,solved.upper_rotation);setq(j.L_Forearm,solved.forearm_rotation);setq(j.L_Hand,desiredq)
   S.matched=S.matched+1;S.max_clamp_m=math.max(S.max_clamp_m,solved.clamp_distance);if solved.clamp_distance>.001 then S.clamped=S.clamped+1 end
   store.scarlet_left_reference={owner=o,frame=frame,target=desiredp,right=rightp,clamp=solved.clamp_distance}
  end)
  local ticks=math.max(0,A.clock()-start);S.ticks=S.ticks+ticks;S.max_ticks=math.max(S.max_ticks,ticks)
  if not ok then fail(e)end
 end,function(ret)
  local store=thread.get_hook_storage();local r=store.scarlet_left_reference;store.scarlet_left_reference=nil
  if closed or not r then return ret end
  local ok,e=pcall(function()
   local o=r.owner;need(A.current_owner_context(o.ctx)and o.key==o.ctx.key,'Left fit owner changed inside native update')
   local error=V.length(V.sub(p(o.joints.L_Hand),r.target));local drift=V.length(V.sub(p(o.joints.R_Hand),r.right))
   S.max_native_hand_error_m=math.max(S.max_native_hand_error_m,error);S.max_right_drift_m=math.max(S.max_right_drift_m,drift)
   if #S.records<512 then S.records[#S.records+1]={frame=r.frame,left_target_error_m=error,right_drift_m=drift,clamp_m=r.clamp}end
  end)
  if not ok then fail(e)end;return ret
 end)
 return{status=function()S.closed=closed;return S end,close=function()closed=true;cached=nil end}
end
return M

end)()
local FC=json.load_string([=[{"crcs":{"ace.GAElement`1<app.PlayerManager>":437989116,"app.PlayerManager":346041440,"app.cPlayerManageInfo":3185740719,"app.cPlayerCharacterEntity":4067958465,"via.Component":1881844667,"app.CharacterBase":1997845319,"ace.cActionController":1972218437,"app.mcLeftHandSheathHold":370816328,"app.mcLeftHandSheathHold.StateValue":3537056103,"via.GameObject":4065074914,"via.Transform":1340992935,"via.Joint":1272281384,"via.motion.Motion":1638522585,"via.motion.TreeLayer":827969571,"System.Array":58605515},"methods":[{"key":"pm","type":"ace.GAElement`1<app.PlayerManager>","name":"get_Instance","params":[],"returns":"app.PlayerManager","is_static":true,"rva":109939872,"hook_only":false},{"key":"info","type":"app.PlayerManager","name":"getControllingPlayer","params":[],"returns":"app.cPlayerManageInfo","is_static":false,"rva":77873440,"hook_only":false},{"key":"character","type":"app.cPlayerManageInfo","name":"get_Character","params":[],"returns":"app.PlayerCharacter","is_static":false,"rva":94360256},{"key":"entity","type":"app.cPlayerManageInfo","name":"get_CharacterEntity","params":[],"returns":"app.cPlayerCharacterEntity","is_static":false,"rva":94387552,"hook_only":false},{"key":"sheath","type":"app.cPlayerCharacterEntity","name":"get_SheathHold","params":[],"returns":"app.mcLeftHandSheathHold","is_static":false,"rva":108613008},{"key":"component_go","type":"via.Component","name":"get_GameObject","params":[],"returns":"via.GameObject","is_static":false,"rva":94821856,"hook_only":false},{"type":"app.CharacterBase","name":"get_BaseActionController","params":[],"returns":"ace.cActionController","is_static":false,"rva":107271456,"key":"action_controller"},{"type":"ace.cActionController","name":"get_CurrentAction","params":[],"returns":"ace.cActionBase","is_static":false,"rva":94387552,"key":"current_action"},{"key":"update_joint","type":"app.mcLeftHandSheathHold","name":"updateJoint","params":[],"returns":"System.Void","is_static":false,"rva":5523728},{"key":"transform","type":"via.GameObject","name":"get_Transform","params":[],"returns":"via.Transform","is_static":false,"rva":97957552},{"key":"components","type":"via.GameObject","name":"get_Components","params":[],"returns":"via.Component[]","is_static":false,"rva":97957600},{"key":"joint","type":"via.Transform","name":"getJointByName","params":["System.String"],"returns":"via.Joint","is_static":false,"rva":125569776},{"key":"joint_name","type":"via.Joint","name":"get_Name","params":[],"returns":"System.String","is_static":false,"rva":109358608},{"key":"joint_p","type":"via.Joint","name":"get_Position","params":[],"returns":"via.vec3","is_static":false,"rva":109358800},{"key":"joint_q","type":"via.Joint","name":"get_Rotation","params":[],"returns":"via.Quaternion","is_static":false,"rva":109359552},{"key":"joint_set_q","type":"via.Joint","name":"set_Rotation","params":["via.Quaternion"],"returns":"System.Void","is_static":false,"rva":109359616},{"key":"layer","type":"via.motion.Motion","name":"getLayer","params":["System.UInt32"],"returns":"via.motion.TreeLayer","is_static":false,"rva":99052976},{"key":"layer_bank","type":"via.motion.TreeLayer","name":"get_MotionBankID","params":[],"returns":"System.UInt32","is_static":false,"rva":117848112},{"key":"layer_motion","type":"via.motion.TreeLayer","name":"get_MotionID","params":[],"returns":"System.UInt32","is_static":false,"rva":117848160},{"key":"layer_frame","type":"via.motion.TreeLayer","name":"get_Frame","params":[],"returns":"System.Single","is_static":false,"rva":117848464},{"key":"array_length","type":"System.Array","name":"GetLength","params":["System.Int32"],"returns":"System.Int32","is_static":false,"rva":114447776,"hook_only":false},{"key":"array_value","type":"System.Array","name":"GetValue","params":["System.Int32"],"returns":"System.Object","is_static":false,"rva":114447856,"hook_only":false}],"fields":[{"key":"state","type":"app.mcLeftHandSheathHold","name":"_StateValue","returns":"app.mcLeftHandSheathHold.StateValue","offset":112},{"key":"hold_rate","type":"app.mcLeftHandSheathHold.StateValue","name":"HoldRate","returns":"System.Single","offset":80}],"curve_sha256":"6218d1121392d37c1ee88e0cf27d821883d23eb5071f42e305b864e889305a3f","joints":["L_UpperArm","L_Forearm","L_Hand","R_Hand"],"curve":[[0.5833619832992554,-0.16812685559594487,-0.5918304369382429,-0.10688245569939944,0.13979782363146392,-0.297041957456995,0.8957481756299598,0.2997629894994069],[1.2177300453186035,-0.1681629749417744,-0.5925099419511224,-0.10640673836739986,0.1397868153048714,-0.29629458677272147,0.8964693880078313,0.29834845479902933],[1.8598320484161377,-0.16805289041243693,-0.593185429230553,-0.10586378331207653,0.13986626959975804,-0.29527038700839925,0.8972484246215628,0.2969816319206994],[2.5223400592803955,-0.16761043668027184,-0.5939703786647776,-0.10494492682475332,0.14036707832210832,-0.29356575427898035,0.8981880640308321,0.2955916657662639],[3.1448280811309814,-0.16688832485277727,-0.5947932699033054,-0.10373225843307111,0.1413038061758707,-0.29132100284782,0.8991896998567643,0.294318180429709],[3.75406813621521,-0.16583010580463156,-0.5957251858009331,-0.10208192941763325,0.14301558756528693,-0.28826644482067043,0.9002926419632571,0.2931248152760626],[4.338348388671875,-0.1646315439696659,-0.596654496424909,-0.10020334591980065,0.14541278495159887,-0.2846315260293479,0.9013852838019409,0.2921379580063486],[4.974390506744385,-0.16312046421476123,-0.597700428404081,-0.09783353686928702,0.14889365107028782,-0.27987131674885973,0.9025959716548984,0.29124429382319045],[5.570220470428467,-0.1613164478043196,-0.5987269821672708,-0.09544263490792697,0.15318466110817688,-0.27452803005999804,0.9037625303346117,0.2904859877442111],[6.169302463531494,-0.1589549120700131,-0.59985984433675,-0.09278996760966515,0.15824302991876743,-0.26832534195303526,0.9050248673753806,0.2896388160797679],[6.78004264831543,-0.15547084171181866,-0.6012270033385765,-0.08983424598269266,0.16422713794029778,-0.2609132701104727,0.9065304098992681,0.2883683903829664],[7.377138614654541,-0.151164914605977,-0.6026565086992739,-0.08664213820410929,0.17060116722973728,-0.2525644696800734,0.9082272678529713,0.2867571452002576],[7.9563188552856445,-0.14616686743841892,-0.6040921290480287,-0.08328153537492992,0.1772876858785662,-0.2434576089913772,0.9100254911342398,0.28487027669785125],[8.595222473144531,-0.1392287443078412,-0.6057748487124124,-0.07885708132267745,0.18540851536520583,-0.23169157151542732,0.9122763179060559,0.2823023519323756],[9.30894660949707,-0.13024593079131425,-0.6075490850101303,-0.07344260493077842,0.19535948155465707,-0.2168758062606184,0.9148181354985213,0.27911885745773507],[9.928056716918945,-0.12135631050343329,-0.6089038922536422,-0.06837929948197757,0.20474053477467138,-0.20252310524122924,0.9169701697847803,0.27610036759936213],[10.555356979370117,-0.11482386057122268,-0.6094060458068249,-0.0655710720195572,0.2109498536086273,-0.19283299449197888,0.9183063335886932,0.2739143537470189],[11.185338973999023,-0.1081693197386046,-0.6096754254257137,-0.06343444562448101,0.21651356861671064,-0.1840120155390978,0.9195595483058934,0.27142529333420123],[11.790828704833984,-0.10079860034806298,-0.6097349122318384,-0.06213212505397714,0.2214664945963006,-0.1760103003640781,0.9209074699413305,0.2681462245552432],[12.393126487731934,-0.09206305205285821,-0.6095816890686223,-0.061725714936233966,0.22211131731760111,-0.16916121641739398,0.9233183654600755,0.26369346139743766],[13.013226509094238,-0.08219139740458155,-0.6091992509120632,-0.061604811252082364,0.22047421856661037,-0.16262813499482204,0.9263512320642604,0.2584890781224138],[13.59854507446289,-0.0725085990081179,-0.6084423670245557,-0.0612851146872045,0.2240164805653371,-0.15552834823969763,0.9279907621394791,0.25389110798281234],[14.216233253479004,-0.061423485601360614,-0.6073578280165575,-0.061490968943046474,0.22924864257707517,-0.14801159379073997,0.9293836009533551,0.2485633727222663],[14.897125244140625,-0.047586644532870634,-0.6056862534703423,-0.06296065570279835,0.23813847584510944,-0.13972425078936995,0.930236875189,0.24171585819329736],[15.622572898864746,-0.03059495095861623,-0.6033621166297525,-0.06537922782270397,0.24890811214449177,-0.13056788720817103,0.930982518371818,0.23295563746071218],[16.23703384399414,-0.015331475859800374,-0.6008870937495476,-0.0677609831766478,0.25802766969059643,-0.12261453904420587,0.9315545530366852,0.22493001401689156],[16.836463928222656,0.00024497780870183505,-0.5979812847534204,-0.0702981372994374,0.2667225931323161,-0.11463498723764257,0.9320884661372364,0.21663095186914694],[17.439590454101562,0.01535580796797685,-0.5946896746993506,-0.07331615509240158,0.27547364419175924,-0.1068212355057862,0.9322596539077203,0.2087951931836245],[18.035648345947266,0.03021348131423854,-0.5910079251642735,-0.07665084752535414,0.28404363143781397,-0.09918740630401546,0.9322234908744054,0.2010980778929501],[18.638858795166016,0.04353427028882439,-0.5870429064253065,-0.08022867995780568,0.29334865487991724,-0.09143165077278548,0.9315325185543452,0.19450960591422],[19.25787925720215,0.05882781501836838,-0.5824713816707289,-0.084348968049893,0.30104815872793117,-0.08395262222497658,0.9314456090499758,0.18636265916109007],[19.87960433959961,0.07627163057139343,-0.577259791821101,-0.08873045295254779,0.30620820271535,-0.07700585927664202,0.9322883555490712,0.17647962016762692],[20.526386260986328,0.09341091455192631,-0.5702982879342839,-0.09674128370646691,0.31290157885341047,-0.07024225758598711,0.9324062481591984,0.16666498010666256],[21.13104820251465,0.10854799864562913,-0.5632245817966066,-0.10485439856274698,0.32061283857081097,-0.0636293936419576,0.9317615934779264,0.15804759070545601],[21.73206901550293,0.12025932797261475,-0.5564702221132147,-0.1128933783693023,0.3330693452561531,-0.055910776132656825,0.9289398358167213,0.15168908265160086],[22.365615844726562,0.12864702415897583,-0.5504484153877193,-0.11948876309489709,0.34943837461518196,-0.04547715508770775,0.9240327019087985,0.14828424230023285],[22.961824417114258,0.13372697606248202,-0.545631037474701,-0.12491602412078029,0.36713085587686267,-0.03435733149471721,0.9178055247239152,0.14719893757070115],[23.541873931884766,0.13474750983639772,-0.5424359424129725,-0.1292046067159361,0.3852706495649615,-0.023425806615015393,0.9103765919454564,0.14910472496203644],[24.18645477294922,0.13553500620489006,-0.5393676477352998,-0.13334440187540936,0.40373401631426087,-0.011655684476893913,0.9021732194375808,0.15148092691742512],[24.83826446533203,0.1364179410060487,-0.5372906675733494,-0.13468522903764502,0.41812901560441046,0.0001754461695417098,0.8951093174276435,0.154749492349883],[25.494718551635742,0.13866143149232996,-0.5366312379022536,-0.13028813305023612,0.42394817498275833,0.012183107255393899,0.8914430004342999,0.15952709426014408],[26.087032318115234,0.1404681589420666,-0.5366851357902155,-0.12433203927288682,0.4258802694222358,0.022812998079072364,0.8893137695989276,0.1650047951946662],[26.712369918823242,0.1383403397502802,-0.5383405351613749,-0.11570148955483683,0.42288229306372,0.03305899851333649,0.888496828954307,0.17507442351356264],[27.374176025390625,0.1342633829534457,-0.540822904174849,-0.10535598265581513,0.4200473637614238,0.04444337625917785,0.88691079271415,0.18701402158908145],[27.978267669677734,0.12915746028776637,-0.5434843862504253,-0.09508816227617624,0.41772211457339936,0.05513535495479684,0.8848308688816418,0.19885336583647628],[28.585899353027344,0.12451933887372128,-0.5460897163991435,-0.08323991273560333,0.4200642214598481,0.06914324785239633,0.8804921915405718,0.20856356767622397],[29.17841148376465,0.12075124011623604,-0.5481759730737158,-0.07202759643137031,0.42366312043473076,0.08352494263083578,0.8755029752811981,0.21685867429225045],[29.82986068725586,0.11865745167018957,-0.5497430542483309,-0.060629459948598294,0.43039547137300904,0.10116860034300307,0.8687658041558145,0.2230933214055141],[30.442520141601562,0.11880063948084005,-0.5507339901345313,-0.0487709089510667,0.4364297725356504,0.11957009293175411,0.8622921814580955,0.2273416818733665],[31.051969528198242,0.11996174088060563,-0.5513364013948016,-0.036063625293113896,0.44213827110416026,0.1388992467214333,0.8554905574226475,0.23099059428022325],[31.683732986450195,0.12284374154759,-0.5514615655898288,-0.017371737246152777,0.44674976494656427,0.1632239418521583,0.847594180709563,0.23528003985403706],[32.29190444946289,0.12662408662137165,-0.5507854476837396,-0.005474584937967528,0.4513486109175064,0.18228453444015522,0.8409493589179812,0.23634922395093624],[32.843910217285156,0.13087262351686563,-0.5498268619733815,-0.0006559960255803632,0.455732100438291,0.19537691259333254,0.8361940212941293,0.23434093412708346],[33.47877502441406,0.13283332671433384,-0.549975441002142,-0.0005287227149991802,0.4596300247349935,0.2040400306718736,0.8326113517957993,0.23209102332124376],[34.07028579711914,0.132745085926587,-0.5507455444501284,-0.0030854132885930474,0.4629821831667088,0.2088013185610993,0.8300452185639545,0.23037891087608642],[34.621212005615234,0.12543827841403413,-0.5530628205308217,-0.012581204902570017,0.46675787119537904,0.2036970109418213,0.8288645629114358,0.23157753293478134],[35.26277542114258,0.11621418854279517,-0.5553423013738045,-0.02310240134347298,0.4718929265193198,0.19868294186875807,0.8265169947245559,0.2339055620178714],[35.867515563964844,0.10659320393549417,-0.5570493421525663,-0.03225949264102952,0.4777588536658847,0.1951950430780218,0.8230018398762248,0.23730432878895807],[36.420135498046875,0.09960255702770712,-0.5593058552739428,-0.04012970571068457,0.48204531948251084,0.19477520833625692,0.820114548451467,0.23897082583616414],[37.07903289794922,0.09276735823025573,-0.5615374573917521,-0.04882854448811816,0.48659689861668665,0.19618905184035082,0.8167679744825229,0.24004872433388003],[37.65719223022461,0.09245445180857748,-0.5594124326776613,-0.052752913790197156,0.4892503954195269,0.20289901867849167,0.8136940682859783,0.23951618324730248],[38.198673248291016,0.09455671226523188,-0.5552408488569222,-0.054744899668459884,0.49122050842272663,0.21119356477625484,0.8106214895883932,0.23873100116974827],[38.825252532958984,0.10139227605474638,-0.545809207168793,-0.05348241952556519,0.49229868989625686,0.22437017234695592,0.806796092157543,0.23744492280683524],[39.46708297729492,0.11831976291459247,-0.53445819571352,-0.04809161844515776,0.4902204720146069,0.24877599018216998,0.803028431133649,0.23008636273731553],[40.10189437866211,0.1391049660462419,-0.5215108526858746,-0.04160153908705083,0.4857096676619861,0.2773221187735644,0.7992973751140905,0.2197777680165783],[40.770179748535156,0.16520696514561828,-0.505707621922148,-0.03424207228129701,0.4779622694184805,0.31329434735056855,0.7945276474988684,0.20524263273119292],[41.35884475708008,0.17998274495096064,-0.4928393373265574,-0.03123461890312952,0.4722181886650762,0.33997262079301127,0.7891316720189321,0.19672265660469962],[41.92976760864258,0.18919868218955016,-0.4814049365387569,-0.0303710510165439,0.4673752045798179,0.362627856573999,0.783259245053362,0.19122345781560893],[42.565738677978516,0.20050206743860946,-0.4684695963549757,-0.030450417924471437,0.4606048789189541,0.39049156347257513,0.7762000199115147,0.18130916541135975],[43.17681884765625,0.21117564655097953,-0.45582663350261354,-0.031226997559726216,0.4523175513415885,0.41733142869791523,0.7696368318664577,0.17000723044585014],[43.744422912597656,0.22129234356968464,-0.4440727394370849,-0.03251205544851285,0.4420814271571431,0.4431391008456557,0.7639799653906197,0.1566089446556451],[44.35481643676758,0.23185227621022725,-0.4315151790380108,-0.03408415703855293,0.42787271002335997,0.46987585888500377,0.7591324701647859,0.14092378789919116],[44.98685836791992,0.24228017471044416,-0.41843407591039655,-0.035911094445911694,0.4104151445866292,0.49632198589938065,0.7549263527167791,0.12373397827829082],[45.68815612792969,0.2521560733159334,-0.4049774726162284,-0.034497416421925275,0.38223797059958775,0.5219380329207596,0.7550964678807361,0.1063209660262418],[46.34386444091797,0.26098663834141717,-0.39269704791513765,-0.033506147306818654,0.35447819102659583,0.5429602285659184,0.7560796948829386,0.0887856816602797],[46.92811965942383,0.2686127622218379,-0.3819989235842067,-0.03291326815801922,0.32881559136423105,0.5593822236794979,0.7574796692194309,0.07208595859384083],[47.49800109863281,0.2752986594006672,-0.3726156758777124,-0.03103157428657254,0.3012345273360789,0.5720582057825602,0.76089640763232,0.05517087628158232],[48.09117889404297,0.2816605682245544,-0.3630437671233107,-0.028387603630488357,0.2714334175972179,0.5833481294952556,0.7645880768931652,0.03786729853966611],[48.678565979003906,0.286987667107018,-0.3545756147722752,-0.02339752199895687,0.24003442752030082,0.590452284497642,0.7702252947005903,0.022418044961726037],[49.349822998046875,0.2928470886744318,-0.3453091852043987,-0.01767743618070053,0.2052865407950885,0.5961306487373507,0.7761917406570414,0.003473836519495125],[50.0184440612793,0.2984937032576503,-0.33645658777738824,-0.011953995499364434,0.1719855956988248,0.5994420521004955,0.781541515020124,-0.016823832670248888],[50.67629623413086,0.3048167262922865,-0.32829759027245914,-0.005958726820515334,0.14563398986598813,0.5978666306980478,0.7871379401043634,-0.04195349975552983],[51.32587432861328,0.3108471646188719,-0.32040210091377325,0.0005466394742863652,0.12207108442406389,0.5936729259694318,0.7924502968427403,-0.06836398432127692],[52.02643966674805,0.3171278661667195,-0.3121045629560955,0.008177054810417821,0.09945719578872562,0.5863456941554631,0.7978356983854825,-0.09881898366680522],[52.665584564208984,0.3224059297375781,-0.3055133237216106,0.015288842321760265,0.08088427613406943,0.5773426050470977,0.8019945231739503,-0.13014620651669778],[53.263423919677734,0.3262818770675066,-0.2993135178834966,0.021679680517378133,0.0630050869537403,0.5699378876313147,0.8037958477336202,-0.1584720745951707],[53.91633605957031,0.3291331927615912,-0.29256940307229407,0.028214670166420777,0.04279596374619565,0.563318754008385,0.803432405900457,-0.18798099908894614],[54.51792526245117,0.3292250472045382,-0.28646454608938077,0.0332001900777211,0.021672484335176323,0.5588548474011737,0.8014875086588802,-0.21172939432854837],[55.134437561035156,0.32820500816467946,-0.2802191849384764,0.037997233139425976,-0.000119118788049391,0.5546929032999255,0.7982214706488598,-0.23485794139135488],[55.78195571899414,0.32504144693520265,-0.27367445339914925,0.04268995545918886,-0.022612578824389676,0.5517278202555079,0.7933713651664919,-0.25621662820526253],[56.38460159301758,0.320575116097017,-0.2681447872909674,0.046676279556651726,-0.04256935372962947,0.5495820122103122,0.7884043075553792,-0.273067958219248],[57.18231201171875,0.31290071851287254,-0.26172442776079097,0.05141036496597276,-0.06774173578017066,0.546894068553577,0.7816201851232661,-0.29221194572138237],[57.81351089477539,0.30549811365601065,-0.2576925108498129,0.054505933172267984,-0.08657344582033169,0.5445087149112842,0.7766726364568473,-0.30462257572876345],[58.384925842285156,0.29794592225848815,-0.2545620460465313,0.057448884552831925,-0.10423794403341348,0.5437417556955156,0.77113943326109,-0.31436177981206653],[58.95088195800781,0.2899484270518571,-0.2517976891057597,0.0604093111942926,-0.1218652347188097,0.5432793788515061,0.7651013407511708,-0.3234444611713301],[59.5968132019043,0.2804309377500664,-0.24873004309117663,0.06352196634632712,-0.14285660040414233,0.5437639932431318,0.7577463075680115,-0.3312600862468931],[60.18281555175781,0.27171914088233867,-0.2459833304298409,0.06630181877917507,-0.1616064478094105,0.5441476919041847,0.7506738811768598,-0.33804640146086834],[60.76893615722656,0.2631428744246105,-0.24307322191327066,0.0690642957910909,-0.17997560530768889,0.5451846395544524,0.742882601105708,-0.34424980938619343],[61.36881637573242,0.2543925345926379,-0.24045750156040452,0.07178519432525468,-0.1973948012114764,0.5470077850688437,0.7347717381430752,-0.34918228528229184],[61.94912338256836,0.24592051457314865,-0.23817702869169233,0.07429812783165222,-0.21333764510408443,0.5490810810193973,0.726842060372004,-0.35312552289829435],[62.578025817871094,0.23722665004444513,-0.23674550073555645,0.07684847489239022,-0.23018235241067128,0.5527461911901719,0.717486887062927,-0.35594985553613934],[63.21207046508789,0.22866569844880086,-0.23570673517602386,0.07924627793313724,-0.24629659381402236,0.5566994454812967,0.7082602444862769,-0.35747886840576554],[63.85063934326172,0.2204481474378667,-0.2351922768151221,0.08148360701385005,-0.26115991813793765,0.5614799607310297,0.6996060187727806,-0.3564928741960586],[64.45633697509766,0.2135648800206903,-0.23554773970708465,0.08381874962962357,-0.2744983039726563,0.5665699122657172,0.6914766071017165,-0.35427294204109233],[65.06269073486328,0.2070217560166836,-0.23626530138072752,0.0862097188049994,-0.2873543788358991,0.5718120864266465,0.6833534268736666,-0.35140644951431466],[65.66291809082031,0.20114928919457584,-0.23787059476671477,0.08887261771188029,-0.2986606136315556,0.5778832158949343,0.675997781338022,-0.34623666223874],[66.21746826171875,0.19582310228472374,-0.23954376250626191,0.09138323896126335,-0.30865022966530914,0.5836640884828547,0.6691160320489246,-0.3411084918294077],[66.83464050292969,0.19007734303256854,-0.2417467726787114,0.09430906960824553,-0.3190463404115066,0.5905363862524448,0.6613843459947082,-0.33473415728766137],[67.43611145019531,0.18482785037429994,-0.2440757310689262,0.09713622361054222,-0.32839450966350425,0.5973833348955948,0.65377124936671,-0.32844078722560555],[68.03219604492188,0.17976588318640618,-0.2464620927741933,0.09988328057078652,-0.33732831150378356,0.6041373987078885,0.6460312158328229,-0.3222906792168166],[68.6413803100586,0.17551547349702437,-0.24929422329245568,0.10256569665408138,-0.3470060503987774,0.61056431132839,0.6366524538435782,-0.3185461908949481],[69.26112365722656,0.17121721330987566,-0.2520837636117655,0.1050557091827947,-0.35503562395147154,0.6170441197824108,0.6283969949302904,-0.313565745466433],[69.8520278930664,0.16719214941321275,-0.254635665779687,0.10713804899177015,-0.36043015134506196,0.6232005788176694,0.622332080631502,-0.30726849168042475],[70.48632049560547,0.1632873975141896,-0.2572675291438183,0.10919590035219877,-0.3649215446434577,0.6292001002411415,0.6168691311911232,-0.30068584119489133],[71.11077880859375,0.15953259927258964,-0.25971055913294555,0.11112064233489574,-0.3685277141111575,0.6347589016857832,0.6122722173103392,-0.2939237870138175],[71.68792724609375,0.15602429861869105,-0.26144640895124077,0.11284053403881361,-0.3701435321666793,0.639338511711472,0.610107190557623,-0.28637257038274283],[72.28409576416016,0.15295627840130782,-0.26356565595981185,0.11470595536799813,-0.37147756709115914,0.6437364135192702,0.6080118319310963,-0.2791584841790997],[72.92047119140625,0.15032701208798438,-0.26621137890825614,0.11681793286453054,-0.37251350193686733,0.6480586487466092,0.6059527819081653,-0.2721670530339889],[73.51881408691406,0.14808643163405844,-0.2680774291626112,0.11843659039631589,-0.37297397428790063,0.6515534742581233,0.604440353756045,-0.2664964229353273],[74.0643310546875,0.14611794013446663,-0.2696352952625107,0.11981913686846521,-0.37334446386375797,0.6545361114407648,0.6031578519012324,-0.26152819314975767],[74.72229766845703,0.14418990819029892,-0.270988458309006,0.12138171515064325,-0.3740252905581384,0.6573585193971312,0.6018928504402605,-0.2563393367936532],[75.32322692871094,0.14291179043188001,-0.2727980886482162,0.12274138147777683,-0.3745396535071042,0.6592654079884357,0.6012450741986514,-0.25217757737847735],[76.09259033203125,0.14195396385224926,-0.2759836822611623,0.12443513732393192,-0.3750806612973305,0.6608081859630058,0.601100258160334,-0.24763989687572288],[76.74549865722656,0.1420523822318853,-0.2801209683773158,0.12609056921859532,-0.37550333678636333,0.6611304011296528,0.6016983644436651,-0.24466899065935974],[77.32112121582031,0.14273237423955226,-0.2848669046895039,0.12782807644149205,-0.3762672488222276,0.6609501392105197,0.6023895487380193,-0.24226989600970236],[77.9026870727539,0.14385851628310584,-0.2905539928515685,0.12980993152126594,-0.37735636972104897,0.660400573447244,0.603214116181929,-0.24001246396876327],[78.55615997314453,0.14631598214219022,-0.2989310911218717,0.13244607787562004,-0.3779373554296327,0.6591748768430369,0.6046792525413159,-0.23877780184912106],[79.1793212890625,0.149250670018313,-0.307920847023468,0.13502675035576744,-0.3787881314295747,0.6576264608454452,0.6061851518869878,-0.2378792784496688],[79.75933837890625,0.1530294712365561,-0.3177817436940017,0.13744947677765967,-0.38049224224677325,0.6555875831833753,0.6075844953764348,-0.2372164735931441],[80.41180419921875,0.15874189579786807,-0.329301567568277,0.13990761754294195,-0.3838587365148799,0.6525935505636133,0.6088261730611585,-0.23686455868213172],[81.01657104492188,0.16481972705109654,-0.3403140826173549,0.14200155301152156,-0.3877566402856764,0.6493924691770809,0.6098312018968248,-0.2367279326220984],[81.59319305419922,0.17267497015249558,-0.3510260810034766,0.1435663157830938,-0.39315029893571907,0.6457444587629398,0.6100733907294124,-0.2371864126539091],[82.22376251220703,0.1818847298757763,-0.3630388663169917,0.1450474977128861,-0.3995360374999505,0.6416011999013653,0.6100753487191014,-0.2377539146033843],[82.8331069946289,0.19202350355030282,-0.37499484933652466,0.14613086346791795,-0.4066511939173623,0.6373730418511023,0.6095231293586695,-0.23847844092049844],[83.39983367919922,0.2023182745995837,-0.3862510654559598,0.14691695924168835,-0.41315603230845666,0.6339282478174365,0.6090899654750864,-0.2375846870987405],[84.04558563232422,0.21446179256207196,-0.3992023172942554,0.1476510702021845,-0.42035671911706735,0.6302850204940793,0.6087886285556775,-0.23540906391897998],[84.63524627685547,0.22622169875906636,-0.41033896528276237,0.14846767819870654,-0.42610484480348076,0.6283857422550074,0.6089937977531216,-0.2295486320234891],[85.2463150024414,0.238738782297308,-0.42159774920771287,0.14944063472815342,-0.43189347264256656,0.6268445765364005,0.6093600198516316,-0.22184289793018974],[86.01185607910156,0.25510929216902895,-0.43501664704108134,0.15096987914456028,-0.4388974250236148,0.6257244536940074,0.6100011203388385,-0.2091329518328912],[86.71749114990234,0.2712066548880357,-0.44577998723305723,0.1532860642342217,-0.4449658471595452,0.625991402109611,0.6103087151523127,-0.1940706870075053],[87.39222717285156,0.28666280022285356,-0.4547188042756996,0.15579821466021013,-0.45208944912234994,0.6262999564451359,0.6099064521725855,-0.17713727486703817],[88.05450439453125,0.301888201752608,-0.46234375875772504,0.1585250216404433,-0.46004314711123695,0.6264731776978152,0.6089125606808059,-0.15848392305320572],[88.6646728515625,0.31607392364751824,-0.4682319077678715,0.1616280373800495,-0.46831320854861147,0.6263192239933313,0.6074311800194551,-0.13940706544314252],[89.36376190185547,0.3329429362796597,-0.4744246540406512,0.16570687094120634,-0.478147151486919,0.625253686266538,0.6055768470058187,-0.11708890513427078],[89.99663543701172,0.34863199624568547,-0.4795845643936284,0.1698606142010595,-0.4872427063058879,0.6234304522325862,0.6038455628057431,-0.09643418823530853],[90.61079406738281,0.3642965106876094,-0.48395221962429874,0.17475919651146687,-0.496150436177256,0.6207744943941202,0.6020896511146098,-0.07721284745125341],[91.22399139404297,0.38016896598485345,-0.48789075846405766,0.1800908196392585,-0.5045245996967159,0.6175917034563789,0.6004673049705677,-0.058944310871364015],[91.83057403564453,0.3964023440297521,-0.4910883100196227,0.18616211633762242,-0.5122187722430906,0.6139562667268678,0.5990533417528447,-0.042716807504042525],[92.4100570678711,0.4112014742619142,-0.4934734620280674,0.19219362510049282,-0.5188262225650236,0.610177471299617,0.5980087273935719,-0.029805473632110772],[93.04783630371094,0.426807405593912,-0.49565598241057224,0.19893338039492653,-0.5255297294045829,0.6056254366123375,0.5972860922375366,-0.016901421824056392],[93.63697814941406,0.43949635931229086,-0.4961912499555208,0.20523877799486742,-0.5308438833675726,0.6015147530184318,0.5969308542146087,-0.007637321456345585],[94.20467376708984,0.4510419190401183,-0.49643631345984446,0.21137751847542546,-0.5352032913652761,0.5977165417108147,0.5969017630672739,0.000811125279735682],[94.82402038574219,0.4625617248102839,-0.496220292365256,0.21823717981288,-0.5386904516810841,0.5942273833845979,0.5971817970355008,0.00896188557022165],[95.43144226074219,0.47320008844481176,-0.4963207900480019,0.22522512595389263,-0.5407745611497801,0.591552593462573,0.5977957538361915,0.016390237227876418],[96.00651550292969,0.48284074609394945,-0.49655485031910923,0.2319517541574915,-0.5421659963798179,0.5891351359891129,0.5986952302456247,0.0232345689374098],[96.55719757080078,0.4909644187237692,-0.49683457214825527,0.23859564050729098,-0.5424517328029915,0.5877528211022174,0.5995412327342441,0.029035308107885047],[97.21524047851562,0.4998317900702228,-0.4971193533073715,0.24672875073340478,-0.5425481372508769,0.586119622489848,0.6006720430419362,0.03603336794955485],[97.80661010742188,0.5065657840386802,-0.4972255735090522,0.2543671879464068,-0.5422887803961771,0.5850235482849456,0.6015632280036441,0.042332131086849856],[98.38777923583984,0.5111686971899392,-0.4980350496961097,0.26464087177966916,-0.5435589644825002,0.5836062587126883,0.6011572035148094,0.050570777968555164],[99.06758880615234,0.5150603583819284,-0.4993580690808945,0.2783259612371402,-0.5459065795250294,0.5816320706482836,0.59993711259594,0.06136449914013149],[99.6349105834961,0.5174991314423696,-0.4998701339613285,0.2902269974130636,-0.5477016907181634,0.5804330097371591,0.5985304593469949,0.0698689374887273],[100.26968383789062,0.5197971654992225,-0.5001503236365061,0.30374962565804053,-0.5497721307570469,0.5789920435878839,0.5968767850103491,0.07910070303412098],[100.85469055175781,0.521490994364791,-0.5000074378125603,0.3164650412529679,-0.5517711480793801,0.5776408737838102,0.5952081410664993,0.08721748614584951],[101.50814819335938,0.5228579394969158,-0.4993393597002418,0.33074089660049133,-0.5539227512099709,0.5761250539533672,0.5933574398808965,0.0957938225419304],[102.10392761230469,0.5236312053974381,-0.49838616858517554,0.34374433133848925,-0.5560314598259989,0.5744702167696348,0.5916857240218318,0.1035422122478474],[102.81868743896484,0.5237726780336613,-0.4962855961278354,0.35905919365634553,-0.5592838697322041,0.5717044536739329,0.5895938438203967,0.11284799526730993],[103.42522430419922,0.5231472110838772,-0.4931082142043712,0.37147273111929024,-0.5624672294332222,0.5690281517258367,0.5877112085242477,0.12013789465510731],[104.04261779785156,0.5219736759485837,-0.4890523813713319,0.38391069614046625,-0.5660583230333031,0.5660405255356565,0.5856557822194207,0.1272140052392067],[104.68902587890625,0.5191686179890618,-0.4834842739119174,0.398675680236984,-0.5714541906737225,0.5625250280507855,0.5822011907449398,0.1343408883143111],[105.27791595458984,0.5155880014591687,-0.4777528588906857,0.41291819212484693,-0.5769220531916165,0.5591704759730028,0.5785724333897392,0.1405107208108023],[105.91741180419922,0.5104163529532839,-0.4707612400281979,0.4292764394495554,-0.5835041085605319,0.5553724848822948,0.5740524070463036,0.14679302535539407],[106.75255584716797,0.5027342153319977,-0.4601332925939991,0.45173749869981106,-0.5929780132013696,0.5500882343076597,0.5674628270655862,0.15416209078359772],[107.36333465576172,0.49746334289798955,-0.4526182292747722,0.46841786573637567,-0.6014376445544748,0.5457679301171722,0.5616697137337002,0.15791535341025625],[108.03340911865234,0.4919791271539945,-0.4445588762819087,0.4866364153443006,-0.6118810574510846,0.5404502158434882,0.5546358695727531,0.16091671109784053],[108.74369812011719,0.48834620905779513,-0.43586216155994495,0.5030274260311406,-0.6247873496078413,0.53141395920805,0.5474174351441045,0.16605457966910928],[109.35858154296875,0.4860075297967859,-0.4281058194568851,0.5154583957130897,-0.6371418639823672,0.5205702219417238,0.5418036349832828,0.17177226291669165],[110.04319763183594,0.484248711004919,-0.4192626537103606,0.5277188831117977,-0.6517380880172806,0.5056833354274353,0.5361414076365414,0.17909276902229074],[110.66912841796875,0.4851326263670035,-0.4110569899775022,0.5366885168923059,-0.6654318063575174,0.48880780093654297,0.5323315717274985,0.18679010298590218],[111.3434829711914,0.4868047340558583,-0.40162175295999036,0.5456485978010857,-0.6798958175324219,0.4695723708302818,0.5284552384577264,0.19488080152066226],[112.1030502319336,0.4896429832027369,-0.3903091305947488,0.5547755222898724,-0.6955849620009427,0.4468161193943759,0.5244366665177219,0.20367400153008713],[112.83020782470703,0.4933277178164379,-0.37916987569784233,0.5622498065498794,-0.7091318914484316,0.4252047449218487,0.5212520875771111,0.211256116179436],[113.50753021240234,0.4972954590740983,-0.3687767071765178,0.568161249486771,-0.7196049758065601,0.406653540011119,0.5192822353203238,0.21713483661447172],[114.25203704833984,0.501981973462336,-0.3574738251727645,0.5737198170930651,-0.7289381978775501,0.38846588053404657,0.5179752894767052,0.22236223336587746],[114.88997650146484,0.5062480333779328,-0.34806273700785145,0.5776227198854196,-0.7347986414937148,0.3757386808459882,0.5176917159758925,0.22558077796001139],[115.54438781738281,0.511479678727289,-0.33871130169765284,0.580228959006815,-0.739584044213541,0.3634398218730628,0.5187151998051441,0.22773115490140775],[116.16966247558594,0.5169460749967302,-0.32985100168743414,0.5818961319835125,-0.7436365258297559,0.3516818499142936,0.520380352465549,0.2291918032141249],[116.8538818359375,0.5238567719230002,-0.32030040570116225,0.5822673992283974,-0.747450164010507,0.3384359671621478,0.523444750499019,0.22974973694589415],[117.58472442626953,0.5299409572578695,-0.31154088001039576,0.5818524208384157,-0.7483202919597255,0.3320833526221147,0.526650915710713,0.2288584727154206],[118.28009796142578,0.535204054791482,-0.3039521584394813,0.5813400973730319,-0.7477157457436717,0.33080627335127644,0.5292217155940652,0.22674379555370405],[118.90493774414062,0.5396427906108477,-0.2976696047371171,0.5810092152184272,-0.7462776531831046,0.33351824641140143,0.5308845120476477,0.22359981784007027],[119.57305145263672,0.5447589199635904,-0.29127933441390147,0.5803735244335867,-0.7455737441859831,0.33562328725436846,0.5324055171724058,0.2191373229676982],[120.17584228515625,0.5487748984594459,-0.28615639762194217,0.5799781133536532,-0.7454517296776242,0.33661787015369443,0.5335384674258096,0.21523668830091952],[120.79481506347656,0.5512910703595485,-0.2823326411384091,0.5803061144864078,-0.7463509824622355,0.33566703839154516,0.5341893008965827,0.21196613201812417],[121.4976806640625,0.5541183499479652,-0.27909657527125453,0.5799856747615006,-0.746642062387896,0.33526294740762885,0.5352026745677593,0.2090035499799366],[122.1279296875,0.5566604237965512,-0.27653062989251204,0.5793519297087258,-0.746488659053881,0.3353481098848306,0.5362731149671072,0.20665786523644875],[122.816650390625,0.5595313238138377,-0.2734308517442162,0.5782955429315899,-0.7457083331383993,0.33628200565811645,0.537686565795399,0.20427102467470698],[123.52129364013672,0.5623807718502315,-0.2698793649731752,0.5769166146027783,-0.7445491894225841,0.33782258709316987,0.5392535668802475,0.20181178059464497],[124.18698120117188,0.5649901575078021,-0.2662708653383393,0.5753737595569806,-0.7432239057466097,0.3396386771396784,0.5408227106213088,0.19943568034277093],[124.91209411621094,0.5677013347512779,-0.26197859766204873,0.5733127919398521,-0.7414753547055966,0.34207139320746877,0.542676126979615,0.19673352922091356],[125.61370849609375,0.5700438646225698,-0.25729517703343785,0.5709286802605817,-0.7396441376034558,0.3446761581270096,0.5445687598689578,0.19382920704174172],[126.32997131347656,0.5721627938673718,-0.25216030534376516,0.5682125478739809,-0.73776492971706,0.34734892191134936,0.5465583949778956,0.19059264362978895],[127.01314544677734,0.5739064789079799,-0.24693771767042716,0.5653631420979818,-0.7359905720183147,0.34986119991552805,0.5485011842653581,0.18724708156155764],[127.64469146728516,0.5750929623085986,-0.24126875355464802,0.5623017073606222,-0.734505515502348,0.35181198687485116,0.5504236084248932,0.18374935340381304],[128.29124450683594,0.5760021743792315,-0.23523787042630986,0.5588091621808485,-0.7331326482255409,0.353589473055019,0.5523402716868077,0.18003118875190202],[128.9876251220703,0.5765773259219041,-0.22845947220210067,0.5545707179860239,-0.7318431938429302,0.35520198706737355,0.5543558975638773,0.17585967941889633],[129.6089324951172,0.576906383256832,-0.2228147553538476,0.5493091479260875,-0.7311010109362914,0.3553665642315912,0.5563597447144653,0.17224909664617213],[130.2838897705078,0.5771387529644947,-0.21713243106014876,0.5428488888871632,-0.7305733323175108,0.3546373406716187,0.5586520169042524,0.1685315600018624],[130.99745178222656,0.5772070664468755,-0.2117719110052272,0.534977910160074,-0.7303764104890347,0.35256190972409135,0.5613079191753504,0.16487516090634585],[131.6407012939453,0.5766741761207691,-0.20807397101381608,0.5276350061747496,-0.729929477858994,0.35541384363316625,0.5621590798385812,0.1576741134791491],[132.35255432128906,0.5752739519015839,-0.20426041768199366,0.5200493474856124,-0.7290461482947143,0.36343043241354556,0.5613815242963148,0.1458109002478584],[133.09542846679688,0.5728003234583087,-0.20052088345321956,0.5128549079547736,-0.7276013692206917,0.3777476957884481,0.5579775968073309,0.12870092189183618],[133.78744506835938,0.5693624182510929,-0.19670702559879724,0.5070036576428738,-0.725655144953191,0.39631473913851006,0.551882136872739,0.10856032951920175],[134.4540557861328,0.5654380696252715,-0.19214922309819105,0.5014346618056814,-0.7264767632054412,0.40785729879909177,0.5455720454314475,0.09074733925906676],[135.07708740234375,0.5611843697388149,-0.1874686232099229,0.4963777009323577,-0.7287638713796892,0.41522423891193944,0.5392976983524554,0.07516677286828663],[135.70655822753906,0.5549481361836195,-0.18207684428585916,0.49227283925306164,-0.7338358273861179,0.4185657998924902,0.5314354816731558,0.062160907520022686],[136.4202423095703,0.5467823970568582,-0.17673998129108287,0.4871498779642749,-0.737800406743992,0.4269343524377408,0.5206751702878034,0.04769680872693488],[137.2822723388672,0.5341598078801387,-0.16936266205190148,0.4795164706900724,-0.743802881091535,0.44120724074510825,0.5012874010317219,0.028361705888077196],[137.89996337890625,0.522417083823904,-0.16187550744071427,0.4723065767363923,-0.7519111395287296,0.4514405451658374,0.4803148822455092,0.011343999579588789],[138.69174194335938,0.5004040974363387,-0.147802959895157,0.46177717982338495,-0.7629062711358662,0.4773057546944994,0.43571507508955704,-0.017481742956136335],[139.31617736816406,0.4808990657593961,-0.13644545561237809,0.4521339279445536,-0.7676939601653827,0.49954268621879827,0.3991228981885936,-0.04247352484120834],[139.98968505859375,0.4582771006662381,-0.12493625506688033,0.4405132308399947,-0.7688129373055305,0.5239861755510711,0.35975464523548156,-0.07029758526790006],[140.64549255371094,0.42423841913223526,-0.1144800355603576,0.41190185779008365,-0.7649818904440424,0.5497486488708231,0.3181489126621768,-0.10658517593567277],[141.31700134277344,0.38141537995739533,-0.10375261733860888,0.3746103232296869,-0.7513657776107301,0.5781913958199257,0.2766353048789335,-0.15689833055124763],[141.97938537597656,0.3308922499824016,-0.0988812518992227,0.33166704184236984,-0.7260662619087408,0.6090736116099945,0.23222362798279833,-0.21892762631685506],[142.60012817382812,0.30397637050047976,-0.09389671798483626,0.30783980877346895,-0.6998202180831676,0.6297622635487384,0.21182148932435194,-0.2622647716190848],[143.34608459472656,0.27053605328371993,-0.0891617632871456,0.2829259251846048,-0.6792770451058757,0.6368446045886198,0.1922238648516864,-0.3099381089509248],[144.09808349609375,0.23358749215740954,-0.08573356953610578,0.2584205906859186,-0.6682799700882525,0.6204668247329593,0.18316657658522947,-0.36725033179929306],[144.7473907470703,0.19554960677143352,-0.0891483237740954,0.22396396644418554,-0.6317462208879773,0.5804702531152808,0.1863040335993442,-0.47879202656963243],[145.36117553710938,0.14706451633995082,-0.07573260487320681,0.2053716226882498,-0.6438673856861971,0.5575041461042978,0.1473310562378387,-0.5029090142301911],[146.01541137695312,0.07700705815578154,-0.055568353542501184,0.193962286738945,-0.7018871288689081,0.533946726533017,0.08586803655910019,-0.46355369899324644],[146.64073181152344,0.00904982230717992,-0.03792499460132155,0.20419104686961925,-0.7635586408940249,0.5146541552955448,0.029756035208247267,-0.3888751479868368],[147.3708038330078,-0.05864775322290597,-0.024789651894702516,0.21706222432928315,-0.8117607347907078,0.48997999838537903,-0.01745650395818732,-0.3172686260944695],[148.09620666503906,-0.10817855289683881,-0.012640365263943866,0.22995359220294875,-0.8399053635893625,0.46740527615583677,-0.051049885598214384,-0.2710815324139884],[148.74282836914062,-0.13285302069499366,-0.0036023049268569113,0.2432411234061029,-0.8518665635028287,0.4526157052385501,-0.06143832583497627,-0.2562961440909448],[149.48123168945312,-0.15067713343769643,0.004010930446795317,0.26018600156328425,-0.8653283220388401,0.4147356432949673,-0.04494631066738825,-0.27781481316795464],[150.09603881835938,-0.15987012819399785,0.008857571005713907,0.27514563226982586,-0.8747195373686314,0.3682455623840374,-0.015815899263793124,-0.3146598068717215],[150.76463317871094,-0.16539499985659759,0.012683273717949958,0.29053491534587084,-0.8797706936308151,0.29532752493730796,0.03733965040146892,-0.37066282542312584],[151.4485626220703,-0.16899182026009596,0.017021546249244825,0.3050183548802624,-0.8860224981669381,0.22244783036075375,0.08003585264884105,-0.3988425225581953],[152.10768127441406,-0.17083339798340075,0.021513783210503627,0.31812329868433364,-0.8907969733912979,0.15711540239115696,0.11070944661825484,-0.4117510424490119],[152.75083923339844,-0.17057193154177241,0.026015406480177986,0.3297489141204914,-0.8885081338337666,0.10958659436289445,0.11631645710441818,-0.4301331843206894],[153.4347381591797,-0.16837844362697274,0.030802194935583258,0.34058724889968767,-0.8795272518812163,0.07892727559811431,0.11774984289323828,-0.45424362721292266],[154.08787536621094,-0.16501948616638312,0.035343650733656216,0.34988880608917133,-0.8675626368035776,0.06108210565267805,0.11634479242821488,-0.4796539761810533],[154.7084503173828,-0.160421132023639,0.03920858306083478,0.35780855393360156,-0.8563963412473885,0.047171937325056895,0.11296877525579774,-0.5015956248257081],[155.3543243408203,-0.15419057134351485,0.04292483101190068,0.36584409095375453,-0.8449542132840429,0.03415315221596754,0.11026970332859592,-0.5222322588418689],[155.9622039794922,-0.1472014061516335,0.04615438655237692,0.37319403590751454,-0.8343838095049402,0.023015678339111365,0.10833748302934144,-0.539941595691128],[156.58316040039062,-0.13825568449763062,0.04841388122082656,0.38025853254768266,-0.8244853114152702,0.01305717555964342,0.10828041554636758,-0.5552736559895273],[157.2451934814453,-0.12823099552007877,0.05025299220916813,0.3873181917399048,-0.8139713517092482,0.0031233432566937225,0.10890416991420881,-0.5705968498851159],[157.85598754882812,-0.1184807749417776,0.05118477893209644,0.3932587916169397,-0.8044060604581309,-0.00507836873301426,0.11053656919423133,-0.5836837901980921],[158.5139923095703,-0.1067044265869811,0.051481773146734494,0.39920976964528226,-0.7932288180356761,-0.01325910973929942,0.11470581640920831,-0.5978752494697724],[159.17396545410156,-0.0941927884248143,0.05135167454954345,0.40480742581620566,-0.7817372866094222,-0.021597718376199115,0.12042343464916444,-0.6114887976674462],[159.84471130371094,-0.08055320787337353,0.050746684040178104,0.41010686394632595,-0.7702672790875246,-0.030865637499362386,0.12893135632644181,-0.6237886954287354],[160.54409790039062,-0.06650332441642305,0.04978888070948256,0.4151480506664075,-0.7597818284513908,-0.04161422194830152,0.14035096531566008,-0.6334835721797852],[161.20907592773438,-0.05329586107974919,0.04854131209214593,0.41952514690425724,-0.7503854236106503,-0.05206876672643041,0.15247789133202874,-0.6410624401875309],[161.80075073242188,-0.041779539990038486,0.047033119736695356,0.423070215699882,-0.7424668506044183,-0.061140772124444714,0.164524443052388,-0.6464800765498382],[162.50575256347656,-0.028325971101307593,0.045230911062446616,0.4269009106536851,-0.7333306500656249,-0.07067890615504979,0.17955631380117426,-0.6519127089367011],[163.1471710205078,-0.016032339718254476,0.04350234309681751,0.43006037603872177,-0.725686137963345,-0.07870969755466428,0.19313910690972497,-0.6556536418421025],[163.6927947998047,-0.0051737615645875284,0.04195956033128477,0.4324482256462273,-0.720922883183336,-0.08463865987501444,0.20390238085185303,-0.656909668706538],[164.28439331054688,0.006678690240842111,0.04006296982429171,0.43468979238306005,-0.716143114984472,-0.09053160863560313,0.21538985616173142,-0.6576855453488515],[164.88160705566406,0.018720381058524124,0.03791845464045919,0.43657429230208145,-0.711736515308303,-0.09586651219792999,0.22680636028937215,-0.6578750789839098],[165.43983459472656,0.030483488230250697,0.0357443647812274,0.4380398471857874,-0.707186151210239,-0.10053140816811088,0.23903310539069003,-0.6577570661235567],[166.0276641845703,0.043016890835080535,0.03328224151113784,0.43930423580020483,-0.7021992309858739,-0.10542941236057131,0.25237722347949115,-0.6573481696033959],[166.64434814453125,0.05632534744828095,0.030467943064681934,0.4401794327198218,-0.6967273070403095,-0.11020433829211802,0.2684314998016519,-0.6560263663605226],[167.33717346191406,0.07129721750077032,0.027105813873895872,0.4406951889679386,-0.6905593231008201,-0.11502264076795626,0.2866651923582696,-0.6540035786442604],[167.93887329101562,0.0843056075832445,0.02400883119064258,0.44073425197623556,-0.6851739977424802,-0.11867902665648031,0.3026918546288075,-0.6517894772016737],[168.537841796875,0.09711445133771454,0.020798917428017486,0.4403125358095339,-0.6796986477232002,-0.12133253942639352,0.31989919154611046,-0.6488086546954661],[169.1025848388672,0.10911187120994309,0.01760680911329991,0.4396287903804585,-0.6745007887553791,-0.12342601555614474,0.33602857708841316,-0.6456775511292322],[169.76141357421875,0.12297588053515465,0.013636110083648064,0.4384150031992434,-0.6690019286014882,-0.12402195681108738,0.3540826034873144,-0.6416233191397296],[170.3633575439453,0.13566044519776227,0.009687893492029101,0.4370158789388009,-0.6643257821312244,-0.12351696246526322,0.3701912662624092,-0.6374741105034194],[170.9594268798828,0.14818164802423145,0.005491318626247802,0.4353664718709197,-0.6598504007174858,-0.1223360646823839,0.38586308769237776,-0.633041083585817],[171.6380615234375,0.162665360447811,8.56647328938906e-05,0.4331984182624969,-0.6553261329288803,-0.11948766301892068,0.4038205796674625,-0.6270560559661242],[172.3005828857422,0.174657439961133,-0.005815713214877505,0.43146760828769026,-0.6520554740598342,-0.1138817467757589,0.42045194878264547,-0.6205439269421484],[172.88706970214844,0.18297880808446684,-0.011668292809560742,0.43056541294463085,-0.6504513448912946,-0.10604726069338169,0.4342432565119449,-0.6140845386446702],[173.46490478515625,0.19047706091803693,-0.017788132873505075,0.4296938534890173,-0.6487297585299104,-0.09626811078028957,0.44878509738159744,-0.6070206648975865],[174.14556884765625,0.19874489233490722,-0.02542335515711966,0.42865785995992667,-0.6467068603702613,-0.08363215395144745,0.4656399409530653,-0.5982936945720779],[174.71876525878906,0.20505500349126848,-0.03213914983574187,0.42776488557369124,-0.6455287082286467,-0.07112097202795353,0.4784225655579214,-0.5910552791029196],[175.36663818359375,0.21161572789925698,-0.03997305415444835,0.42668816405120347,-0.6434461532555101,-0.055650878055111375,0.4936206679025734,-0.5824248139045926],[175.97470092773438,0.21726732426562329,-0.04760075695768246,0.42563392766140773,-0.6408117698789536,-0.04024585367673245,0.5083582207653942,-0.5738575312973394],[176.52334594726562,0.2219672162048862,-0.05453048414036248,0.42423078571439327,-0.6366990151492394,-0.024321031412728292,0.5237024838131387,-0.5654719798424668],[177.0771484375,0.2264078280449615,-0.06177922293782821,0.42269518860367566,-0.6320358341570246,-0.008044010751247886,0.5390502737318814,-0.5566783637092891],[177.75392150878906,0.23132744346670797,-0.07062203923871099,0.4200753394883994,-0.6253281065491675,0.013831121612153609,0.5571981304676803,-0.5461718618144887],[178.3611602783203,0.23545471924100747,-0.07865051448942531,0.4172844526917652,-0.6184135205720879,0.03437428150853656,0.572868146902093,-0.5368474761134395],[178.9330596923828,0.23905390096708223,-0.08636802487404333,0.414377910286029,-0.6111473660183284,0.05422000801030351,0.5871477627960097,-0.5280308630978522],[179.55604553222656,0.24283726450834142,-0.09451136800901903,0.410686332220556,-0.6016130128186115,0.07716228341904108,0.602405677260253,-0.5188594846675626],[180.1586151123047,0.24627735947471296,-0.10261743084862088,0.40675369971433806,-0.5913125684075309,0.09950919528223756,0.6168904698066715,-0.5097975232965286],[180.7703399658203,0.2498001587357646,-0.11101322193536847,0.4018824812289161,-0.5793175257962501,0.12275360323085932,0.6314228934718431,-0.500627493051268],[181.41802978515625,0.25367941213970135,-0.12035253114855886,0.3958217786480864,-0.5656882120375104,0.14728562888787147,0.645707110990802,-0.4912902574861638],[182.00376892089844,0.2570174190083899,-0.1291909180194617,0.3898704266928256,-0.5525472397793841,0.16919377803317767,0.6578710980798774,-0.48298098471701767],[182.54815673828125,0.26898607936319263,-0.13202148595463475,0.38264157479512795,0.5585151823694322,-0.15255187839753526,-0.6456980269154899,0.4978581861310174],[183.14967346191406,0.27306120365821557,-0.14254230689272343,0.3750171250486421,0.5455754724275963,-0.1720306547224288,-0.6565081690027872,0.491680670510633],[183.69522094726562,0.2752041247474415,-0.15366969337039202,0.3671491952953291,0.5341842284999692,-0.1899216211120099,-0.6656396822744075,0.4852842478771642],[184.26846313476562,0.27720048989430934,-0.16558196621592225,0.3585003810747991,0.5220699366712626,-0.20819487349973187,-0.6743886049776657,0.47885058770849653],[184.87416076660156,0.2789867603805939,-0.1784186478815159,0.3489025252257602,0.5091843612652506,-0.22691619802402907,-0.6826581650511476,0.47245968611747036],[185.4585418701172,0.2805398490594666,-0.19092781313628512,0.3390778918323475,0.4955707877681195,-0.24458546340961562,-0.6914467542790048,0.4652837106504145],[186.00157165527344,0.28154134841397593,-0.20269547162300994,0.32968455030529864,-0.4821552480205481,0.26049797393298363,0.6995976509783994,-0.4585087230670317],[186.59458923339844,0.2827021578443919,-0.21596407205148857,0.3183750453094081,-0.4637473961654952,0.27656091133369254,0.7133405654281112,-0.4467635309497669],[187.22117614746094,0.2834058232347187,-0.23012006614361027,0.3058533450249851,-0.44274999057953934,0.2913476891996272,0.7286268875444594,-0.4338108211964395],[187.83157348632812,0.2837382155718865,-0.24402618403888254,0.29278655044246055,-0.4202749853721356,0.30243353301747367,0.7453381710057121,-0.4199689341116554],[188.38551330566406,0.2836614113255642,-0.2563113770644575,0.2805282540085398,0.3992761763067786,-0.30903312061552957,-0.761111864582311,0.40716801813072695],[188.98497009277344,0.28290034250289453,-0.26956072558329236,0.2669341703012398,0.3760609153896994,-0.3142772316610161,-0.7780542180588439,0.3929880956677826],[189.60809326171875,0.2812676179835633,-0.28330411260586313,0.2528231967771595,0.35186586879957693,-0.31659798743985257,-0.7977412718792347,0.37358397698971885],[190.21961975097656,0.2787757825769016,-0.29708003208682104,0.23846120890303188,0.3261550562407641,-0.31629126200988544,-0.8179726056343984,0.35285058211153775],[190.8330535888672,0.27535271444448084,-0.3113116919884359,0.22329569765871066,0.2972238405149585,-0.31172541021328876,-0.8402852473482243,0.32925060416926966],[191.41563415527344,0.27139592453094463,-0.32528332299816665,0.2086824219772776,0.26654382717207215,-0.3070961708581199,-0.8615812406903489,0.3038488040641661],[191.98330688476562,0.26651339583038625,-0.33904333636567807,0.19423685486037015,0.2351482935592365,-0.3021185201139581,-0.8811843485161708,0.2773874975020735],[192.62615966796875,0.2606206368806878,-0.3552885698392685,0.1778539520369452,0.20374678335265148,-0.29954216156526964,-0.8990285219062112,0.24598670394431227],[193.26881408691406,0.25366194657153274,-0.37174045593370425,0.16147325841033566,0.17265379867050137,-0.2981928528189574,-0.9142758589510452,0.21300549774986088],[193.86427307128906,0.24639763497159956,-0.38727210624145,0.1463416628227741,0.14414966289578793,-0.29856534268630824,-0.9259313453754592,0.18091642956025386],[194.4781494140625,0.23863876036448842,-0.4037721708571968,0.1312009653651193,0.11407454388701899,-0.3006854643293009,-0.9354469954379558,0.1466770899088965],[195.04638671875,0.23038791771620173,-0.4190328119288616,0.1171153610847856,0.08529083240565459,-0.3025878538737066,-0.9423139579005314,0.11493680586083194],[195.63372802734375,0.2222368901363078,-0.4353254371772641,0.10327404872561619,0.05172189886367387,-0.3038549965112615,-0.9477560672257124,0.08219138221205526],[196.2700958251953,0.21253834371387278,-0.4529903890511599,0.08841397275870685,0.014126812586096212,-0.304229821140564,-0.9513781030119817,0.04609071711593208],[196.8258056640625,0.20368695561363004,-0.46854396027084955,0.07572450765235852,-0.019953062107326416,-0.30359030667191594,-0.952493935431894,0.013787819728155525],[197.5110321044922,0.19278042047125196,-0.48798869234609826,0.06077598644352181,-0.059746954143747616,-0.30525868763343783,-0.9499939663917522,-0.02754811997437795],[198.12432861328125,0.1821478574805269,-0.5051566973793498,0.04755840145602215,0.09482731782235587,0.30762271520998036,0.9445707121473059,0.06451522793099872],[198.7060089111328,0.17229297765230578,-0.521659085257464,0.035922754749728475,0.1268379017439323,0.314197038425082,0.9354380650498942,0.10073725319768265],[199.24667358398438,0.162633591744924,-0.5367604052200362,0.02546592459652945,0.1558825760469607,0.31873034178234816,0.9251732597324294,0.1347814200412725],[199.90235900878906,0.15048469555285443,-0.554875134331843,0.013481941645968873,0.1896912707286016,0.322414171294572,0.9103477209227094,0.1770122904451316],[200.47621154785156,0.14019444028793954,-0.5707689279718727,0.0039759409622103364,0.2182621683676948,0.32113587673556954,0.8957374027208931,0.21653609375699454],[201.0207977294922,0.12944431751440855,-0.5850857255084825,-0.004927041463295104,0.24512338650534807,0.3178984982158969,0.8802130340820405,0.25314044491608945],[201.6123809814453,0.11686016972469218,-0.5955034667453477,-0.014782689759888543,0.27029184337393314,0.3124745886388189,0.8652258868868925,0.2840530153357157],[202.25242614746094,0.1029228064013046,-0.6059642308725335,-0.02512951032531935,0.2939368210219511,0.3058851525125866,0.8489970234516643,0.3150229720037501],[202.8017578125,0.09109675173803747,-0.6143869226749017,-0.03353150140286261,0.3095495440680421,0.29990332833189726,0.8361523865713472,0.3392436585313839],[203.3690185546875,0.07879035394503509,-0.6213663980451013,-0.04194347426928857,0.32544971036561,0.2944834040205414,0.8229301883143142,0.36076019173459617],[203.9763946533203,0.0654028112897983,-0.6274974320341039,-0.05080758828825817,0.3423764214636856,0.2889560805600392,0.8085983988998036,0.38138091041605],[204.56619262695312,0.05299632785449912,-0.6321115533723586,-0.05882825452309204,0.363506513064087,0.2883648516138834,0.7941960585180977,0.39237908704212326],[205.14630126953125,0.04070737981994348,-0.6356009513043905,-0.06655890920771394,0.3856111203880626,0.2889562104080917,0.7789115075149275,0.4013791670733307],[205.76693725585938,0.02787624686555247,-0.63760244781861,-0.0744451503190074,0.41269088449781915,0.29402452525075684,0.7593416863751318,0.40821074916817907],[206.34092712402344,0.016388753378773227,-0.6382542817179687,-0.08137537182137251,0.4342075045250229,0.29880795673602134,0.7447943728561388,0.40921753404176997],[206.9172821044922,0.005132483238231719,-0.6380504989236028,-0.08806554846671275,0.4533626619097207,0.30362077026458273,0.7327685955934555,0.4066041194602787],[207.51339721679688,-0.005619580105505451,-0.637302122075899,-0.09432855813702554,0.47038309083128543,0.3063322451882232,0.7266178025300987,0.39613996574983434],[208.07920837402344,-0.015590401779938007,-0.6362700086892136,-0.10006032139393381,0.4859856436617221,0.30792885256337066,0.7218673990182672,0.3845844954601128],[208.71905517578125,-0.026044970434702386,-0.6347080570448571,-0.10601175693612844,0.503702863136327,0.308027007431227,0.7170876348458141,0.3703891363315963],[209.3871612548828,-0.03640757951763186,-0.6327852768219862,-0.11182744649228121,0.5238941421948261,0.3070337633943361,0.7091831678671269,0.3582239946232031],[209.9449920654297,-0.04470019264309277,-0.6309934442819032,-0.11644177140081796,0.5417066915427702,0.30554885160764994,0.7007095277867883,0.349571047553782],[210.5077667236328,-0.0524028060149877,-0.6290356619562856,-0.12072872114945968,0.5596236442410831,0.30652861149448296,0.6901781844875089,0.34134390400169795],[211.19525146484375,-0.061458457560879684,-0.6264838587598186,-0.12586474488372773,0.5776714804872992,0.3094825521955052,0.6794299001077398,0.32998669875883646],[211.739501953125,-0.06816251584441242,-0.6243631508503422,-0.12982481196426962,0.5847861826033307,0.3151161360495906,0.6760046335246044,0.318974414163057],[212.35415649414062,-0.07526752602762303,-0.6219414290115121,-0.13430297227989996,0.5910527531199766,0.32027178217378177,0.6742083979036253,0.30581966053338105],[212.91867065429688,-0.08147768768169893,-0.6196836141491007,-0.1384029018140799,0.5955720252245367,0.32414246250139606,0.67396294596203,0.2932568400628651],[213.50653076171875,-0.08699274327691166,-0.6175007460058037,-0.14246337383353824,0.6007255024082557,0.32292539403200604,0.6756357912506876,0.2799363110185597],[214.14186096191406,-0.09248476767577744,-0.6151759031100859,-0.1466662109069898,0.6057663168767107,0.319519041901583,0.6784931162484346,0.2657100720774567],[214.7346649169922,-0.09663948887170884,-0.6131550386604994,-0.1502105730385346,0.6088439909379737,0.3129293115970483,0.6835674529767648,0.25321883396180583],[215.34202575683594,-0.1003098358979982,-0.6111310026279876,-0.15352134317304292,0.6107298557101893,0.3043207229420102,0.6894884668022503,0.24290655626999025],[215.97630310058594,-0.10366874529542308,-0.6090665241302237,-0.15671585911217553,0.6117027603237026,0.2938284262134925,0.6961650564888553,0.2341768628304984],[216.513427734375,-0.10576572127223847,-0.6072829232009029,-0.15917721765689422,0.6113820005165157,0.2838049703167226,0.7018178687671639,0.23047443968271972],[217.14852905273438,-0.10807699914837543,-0.6051193705453453,-0.16204794205807976,0.6104453604913558,0.272242197363297,0.7083657328473749,0.22684496105707044],[217.69667053222656,-0.10970464130891473,-0.603097793453389,-0.16449545827826467,0.608248168566827,0.26341103536147825,0.7140991104987319,0.225191590140074],[218.28358459472656,-0.11113939848236934,-0.6011104620702433,-0.1669852381671922,0.6053995020154507,0.2549068635226691,0.7202103189407162,0.22318384883273176],[218.90745544433594,-0.11230113725248686,-0.5992023838404148,-0.16947736793063592,0.6017961755497742,0.24696463392509113,0.7267094964562779,0.2207784872766692],[219.45040893554688,-0.11244107239623918,-0.5975959168386646,-0.17135005741230663,0.5975267252065896,0.24114245706207002,0.7330718651483408,0.2177562136745805],[219.9940948486328,-0.11238516314273052,-0.5959933849069803,-0.17314765835121446,0.5929872124299039,0.2355105672401368,0.7395186350945793,0.21450670609724945],[220.59188842773438,-0.11113576874877637,-0.5943159551064041,-0.17469459735665355,0.5873358996722877,0.2286740768115236,0.7474819645958186,0.20979852276533592],[221.1410675048828,-0.10973655857597295,-0.592748642176642,-0.1759901692951823,0.5821949037034699,0.22240276077346133,0.7546281576610514,0.2052375447308245],[221.67550659179688,-0.10773360421012101,-0.5911599004529652,-0.17696085585672167,0.5774596329236139,0.21641511223558257,0.7613120972240734,0.2002717208196611],[222.26185607910156,-0.10526971240267832,-0.5893729899132947,-0.1778389899069013,0.5720678932855393,0.2106903416726114,0.7683350849334222,0.19495923332346765],[222.8867950439453,-0.10230099680723938,-0.5873946063788815,-0.17853240520252123,-0.5660836374465549,-0.20570694708951365,-0.7754546995068444,-0.1894834461031866],[223.4531707763672,-0.09923250701510293,-0.585626550948626,-0.17886406793104037,-0.5594387281463085,-0.2033674307089809,-0.7818330095636322,-0.18549162442962733],[224.09494018554688,-0.09559500897340713,-0.5835836222199671,-0.1790567449530578,-0.5513620414781265,-0.20155574613398433,-0.7890022204124539,-0.18124755612604287],[224.82081604003906,-0.09113781923102135,-0.5812661659696728,-0.1788025313879325,-0.5410265773540737,-0.20124096218416682,-0.7971671605882633,-0.17696563456042402],[225.40005493164062,-0.08734857217637641,-0.5792506226723306,-0.17834972334679394,-0.5335566391961254,-0.2016411441203176,-0.8026223727188921,-0.17451500960857452],[226.02273559570312,-0.08316680851882491,-0.5769256399250975,-0.1777111325512891,-0.5259009567466421,-0.20230076300484126,-0.8079589201538903,-0.1723512933644112],[226.65992736816406,-0.07859510766644089,-0.5743493616062924,-0.17682888456823215,-0.5185038936516978,-0.20274165802608365,-0.8126687992958671,-0.17210158343221854],[227.22354125976562,-0.07451287268285635,-0.5720099838628462,-0.17595454287602028,-0.5121037579458746,-0.20265073089729266,-0.8167743368983321,-0.17193633981446793],[227.9527587890625,-0.06914560323070956,-0.5689436333770781,-0.17466792054914226,-0.5041369947027883,-0.20168603053226358,-0.8219580497754568,-0.17191160539506178],[228.57875061035156,-0.06455951698534972,-0.5664079872025666,-0.17342349592583656,-0.4966103951553093,-0.20044993110459708,-0.8271164277383409,-0.17051790377909204],[229.13436889648438,-0.060510406752453935,-0.564121351900083,-0.17227160071485,-0.4897047321890823,-0.1992331401208569,-0.8318479103892997,-0.16889193328918206],[229.68093872070312,-0.056505073715216056,-0.5619899141604425,-0.17108074470658627,-0.4823781155797957,-0.1980141842121894,-0.836843930079646,-0.16671524570152227],[230.29603576660156,-0.05187338588991651,-0.5595391537981409,-0.16976958472671064,-0.4740224012287157,-0.19634121676019264,-0.8424624541211041,-0.16434689875606492],[230.83285522460938,-0.04770506876423404,-0.5573678783172069,-0.1686556129157049,-0.46662991504884754,-0.19460087446425037,-0.8473626792919742,-0.16236844454013055],[231.41842651367188,-0.04306352679666978,-0.5550235590372441,-0.16739674862853837,-0.4587067813147841,-0.19236531389683245,-0.8524907185253525,-0.16075835783352602],[232.04832458496094,-0.03804412633824121,-0.5524401794050419,-0.16601313396301512,-0.45030610032236196,-0.18966354169288524,-0.8578452880526121,-0.15922819703466196],[232.62298583984375,-0.03343333702406667,-0.5501551291785545,-0.16471199735006287,-0.44325109871065965,-0.18660855601801682,-0.8622689723683709,-0.1587385573937775],[233.25372314453125,-0.028399037446157155,-0.5476710173108063,-0.1632463649098762,-0.43609099690251907,-0.18322317016695855,-0.8667105320876068,-0.1583248745553089],[233.88589477539062,-0.023376770910921343,-0.5452708798204887,-0.1617264627770749,-0.4297766934382519,-0.17987877862715806,-0.8705787036579632,-0.15820347503801951],[234.51268005371094,-0.01844202097212881,-0.5431936820344329,-0.160113979115176,-0.4250933583649503,-0.17802912490089642,-0.8734028080800589,-0.15738107319146422],[235.13490295410156,-0.013564926941908237,-0.5412174583295003,-0.15847321037959358,-0.42116484876071136,-0.17694242589192014,-0.8757456820400799,-0.15614431938435971],[235.80621337890625,-0.008313178902140672,-0.5394420817709932,-0.15665014235452185,-0.4183393882865511,-0.1776040370216585,-0.8773410100059231,-0.15401855214041676],[236.35531616210938,-0.0039846920975775135,-0.538206824919836,-0.155100916978324,-0.4166473609982376,-0.17888164429180237,-0.8781926141466921,-0.15226314842030717],[236.94580078125,0.00069290141344934,-0.5369735293295883,-0.15338548993420367,-0.41517888919256113,-0.18069465878815913,-0.8788410553249294,-0.15038061620310758],[237.59677124023438,0.005756327436566691,-0.5359505780205437,-0.1515352930520031,-0.41339668671380103,-0.18275357762134772,-0.8794962448697722,-0.14896531321290551],[238.1436767578125,0.00997404040918523,-0.5351194058444043,-0.149985548962496,-0.4117063565097627,-0.1842268574150865,-0.8801273525663942,-0.1481019388154243],[238.7057647705078,0.014217238942984087,-0.5344053923837117,-0.14845220772295725,-0.40947996841768664,-0.18499093483424636,-0.8810223316308347,-0.14800054277457708],[239.3656463623047,0.019111449905256442,-0.5336649790789182,-0.14668717532479403,-0.40673917331400017,-0.18544468551437018,-0.8822194082282803,-0.14785949158462272],[239.95481872558594,0.023425385243281846,-0.5330675692303388,-0.145120652009275,-0.4041993518115619,-0.18553048882383028,-0.8833918041970663,-0.1477167627229756],[240.50489807128906,0.027255333188735492,-0.5327001985750903,-0.14346747778789415,-0.4017260979968367,-0.18564758307687607,-0.8845864089052029,-0.14716657999066096],[241.1324920654297,0.03154116475773641,-0.5323130587326429,-0.14147634375063634,-0.39884159700669386,-0.18579721139005073,-0.8859895075698857,-0.14638090453642638],[241.7407989501953,0.0354666834964522,-0.5321153269225637,-0.13938243205569717,-0.3958879032240131,-0.185995124468746,-0.8874681746914059,-0.1451854698813027],[242.29421997070312,0.038923425856530386,-0.5319881921886425,-0.13746344467279126,-0.3932272600741578,-0.18609103725068712,-0.8888879182743966,-0.1435991522793349],[242.8426513671875,0.04225046818141688,-0.5319076685340753,-0.13555061342236552,-0.3906175840277142,-0.18611385776302627,-0.8903551316681261,-0.14158839821521235],[243.4378662109375,0.04574482570212063,-0.5319372910105976,-0.1337245353816784,-0.38781146764424906,-0.1858619098515452,-0.8920579097188627,-0.13888953069962923],[243.99420166015625,0.048967288870768955,-0.5319747804856567,-0.1320859687907174,-0.3851969288853624,-0.18553140125196213,-0.8936746860975249,-0.13618729953728825],[244.53988647460938,0.051862250617191005,-0.5321263835583375,-0.13071410639948733,-0.38268720433083564,-0.18490372903817656,-0.8951446207331981,-0.13445156228785451],[245.15115356445312,0.05507436387485738,-0.5322840005994983,-0.12923282183859225,-0.3801655630895407,-0.18408646471781068,-0.8966702844966365,-0.1325470446642688],[245.70327758789062,0.05790944262150213,-0.5324658144611316,-0.12808224201204504,-0.3786906382810798,-0.18306222779863546,-0.8977410111893641,-0.1309301266338923],[246.26060485839844,0.060713034398135954,-0.5326708081818141,-0.12694319351791797,-0.3774325286118539,-0.18212808483728812,-0.8986769670254269,-0.12943630092498676],[246.8596649169922,0.06365695020721533,-0.532920068069122,-0.12574536969692787,-0.37636138325229485,-0.181248845519421,-0.89950902550005,-0.12800186810452008],[247.40126037597656,0.06620775961117178,-0.5331999110651561,-0.1248317906753218,-0.3757680659546429,-0.1806625392313455,-0.900004029533416,-0.12709112616860377],[247.98196411132812,0.0689044142852269,-0.5334950474419448,-0.1239105575647948,-0.3752632623069743,-0.18011003854213906,-0.9004425268725151,-0.12625812361395283],[248.56800842285156,0.07144513686796321,-0.5338341099986377,-0.12327172607118048,-0.3747413349944661,-0.18004219469357355,-0.9007131639388404,-0.12597434772115496],[249.2662811279297,0.07439024926486255,-0.5341902581086174,-0.12259246153904305,-0.3738647357799484,-0.1802166617997163,-0.90109396290517,-0.1256056693219396],[249.91810607910156,0.07701870975498931,-0.5344679426448175,-0.12207047870018187,-0.3726742027092752,-0.18074092799451968,-0.9015406134650997,-0.12518457515068487],[250.59579467773438,0.07970511168214788,-0.5345848617032612,-0.12159185896504887,-0.37081727632784434,-0.1808398763098744,-0.9024414126836725,-0.12406040216977442],[251.20147705078125,0.08207366154398718,-0.534616161834536,-0.12119338838982949,-0.3689136768065241,-0.18058482454874197,-0.9034473507100426,-0.12277908902902424],[251.83016967773438,0.08447172868238446,-0.5345591080000632,-0.12082777541759454,-0.3666019346712555,-0.17972589584757362,-0.904791471682757,-0.12105377576610539],[252.46627807617188,0.08679970358714338,-0.5344053680104133,-0.12058609803220649,-0.36454509483222475,-0.1775760881493001,-0.9064688609080266,-0.11784655682480098],[253.02149963378906,0.08880028857918747,-0.5342354897418206,-0.12041772711938539,-0.36285834738927125,-0.17524543401872691,-0.9080234989580892,-0.11452590504084173],[253.58045959472656,0.09076148306760091,-0.5339472292353038,-0.12040784852605319,-0.36163788031634114,-0.1717703662946817,-0.9097311468393169,-0.11001011432461996],[254.16668701171875,0.09278548549243754,-0.5336045807899538,-0.1204809019770981,-0.36041806545231103,-0.16799956983243433,-0.9115048152199293,-0.10504253644411447],[254.80996704101562,0.09492562119376666,-0.5331556065458849,-0.12079342439527432,-0.3592478898666664,-0.16351585303836091,-0.9134587092639747,-0.09897831025673326],[255.4174346923828,0.09683558020207512,-0.5326351952905243,-0.12141106132119167,-0.3580268771589298,-0.160182194621366,-0.9150256438386096,-0.0942681859157443],[256.00177001953125,0.0986212915766161,-0.5320868513859328,-0.12214287370704874,-0.3567947772943542,-0.15736868449288272,-0.9164052067735856,-0.09018914033692585],[256.62109375,0.10031560063235932,-0.5314423495606111,-0.12318778782616013,0.35556391328520226,0.15540190537354118,0.9175093783653354,0.08718424162222134],[257.24005126953125,0.10190792111010372,-0.5308033220442875,-0.1243258352645806,0.35432392767827786,0.15360041353073461,0.9185317600609787,0.08462194158199501],[258.002197265625,0.10367455033891494,-0.5300318563750244,-0.12590964184895664,0.352788838467361,0.15170438292037194,0.9196453710857728,0.08232986758224875],[258.6122741699219,0.10481395166697041,-0.5294196964320043,-0.1274591167027298,0.35141084351959434,0.1500168958099032,0.9205515320817541,0.08118021193827361],[259.23211669921875,0.10592545358829737,-0.5287394482900452,-0.12914048323690208,0.34992109596434096,0.14824320206387534,0.9215127779743069,0.07995861223807862],[259.882568359375,0.1070027002185063,-0.5279151261629506,-0.1311034512338201,0.34819922246489593,0.14628121496961233,0.9225969316741692,0.07857486422046404],[260.5113220214844,0.10783923735217685,-0.5272068564663552,-0.1330427476843081,0.34662033102696654,0.14428305798812038,0.9236262959503654,0.07714409067038744],[261.08636474609375,0.1085115230924154,-0.5266089316872168,-0.13481891905713564,0.34524890017515875,0.14237752010272958,0.9245484311834533,0.07577623039882336],[261.7479553222656,0.10895492019325002,-0.5261553441120757,-0.13684994286575533,0.34402026811134595,0.13983223442754666,0.9255448965372198,0.07391647879535615],[262.3244934082031,0.10918720003481024,-0.5258355896321895,-0.13869000396677167,0.3431871052445076,0.13730299745536273,0.9263890759548566,0.07192897632508785],[262.86981201171875,0.10929636312604481,-0.5255956339425603,-0.14048410591445504,0.34256809232897945,0.13468348696797863,0.9271667488117983,0.06978022896200546],[263.41949462890625,0.10927392610714311,-0.5253959988311003,-0.14240133150247267,0.3426710583973626,0.13172432982467525,0.9277309786773837,0.06738306813566262],[264.0191345214844,0.10919820308953364,-0.5251874577946894,-0.14453263278806822,0.3430460376499209,0.12837554707114143,0.9282537267804652,0.06468503447515288],[264.5904541015625,0.10895440480879236,-0.5250531986803064,-0.1466411437405684,0.34414761048849435,0.12480106019294102,0.9285143409581702,0.06203415353490748],[265.1680908203125,0.10864581614213936,-0.5249337053422775,-0.14879490361098338,0.3455252278123175,0.12109737230080193,0.9286626972183957,0.059441888951660006],[265.7958984375,0.10814893045789938,-0.5248613195519818,-0.15119097745913085,0.3477428552239384,0.1168365730312191,0.9285420637358549,0.05686613857281984],[266.3466796875,0.10760858275394491,-0.5247997692653489,-0.15336490948176154,0.3500382141561988,0.11302649648040972,0.9282625833025363,0.0550166898695736],[266.9192199707031,0.10698065284173272,-0.5247262561274515,-0.15566556806579857,0.35263508918107034,0.10901777238403043,0.9278571617763023,0.05333579026420378],[267.51861572265625,0.10612277520542317,-0.5246668901458676,-0.158279236765514,0.3554437303910929,0.10535237539544129,0.927208234952072,0.05334342097452485],[268.0823669433594,0.10522416033929353,-0.5246134088691814,-0.16079847350040838,0.35821373007393537,0.10208545231569296,0.9264852727036117,0.053726375974306656],[268.664794921875,0.10392363956741814,-0.5246601691453895,-0.16360343748375406,0.36174156779201866,0.09933726943951483,0.9253424267012711,0.05492302229736197],[269.2475891113281,0.10255769651738691,-0.5247162232262614,-0.1663852032901219,0.3657903117956677,0.09673697983381435,0.9239650423770607,0.055928570464627805],[269.8948669433594,0.10094700033242175,-0.5248092718396994,-0.1694351591668306,0.37105629486394265,0.09406635279583697,0.9220886073257528,0.05675691635021861],[270.55902099609375,0.09924947480926505,-0.5249354485008456,-0.17247767846414233,0.376917205094025,0.09100585710831267,0.9200146231780206,0.056784219768301565],[271.159912109375,0.09766477539329099,-0.525065138382735,-0.17520041326775,0.3817716251692556,0.08819247304222,0.9182705146660135,0.05702434400619866],[271.752197265625,0.09600375118950105,-0.5252649332715484,-0.17785112402821057,0.385155725314309,0.08548228175640156,0.9170328895013078,0.05829688101614056],[272.3622131347656,0.09460935831136402,-0.5254190804461885,-0.1802402853250159,0.3885901611403738,0.08438426694258756,0.9156039815178756,0.059551080477807175],[272.98272705078125,0.09341364640821084,-0.5255487173870016,-0.18242805544619164,0.3920476866401598,0.08445590283552297,0.9140407478419449,0.06078916976628202],[273.5408020019531,0.0924073106879968,-0.5256660758809807,-0.18425571316844275,0.3951588015204755,0.08477131912783975,0.9126043176910092,0.061779481755313365],[274.1316223144531,0.09132250838990923,-0.5258082336544372,-0.1861546992941365,0.3981660217534188,0.08473118466321172,0.9112372905575483,0.06269805231395258],[274.6808166503906,0.09025226548501274,-0.5259991480825069,-0.18783152031455314,0.4000338954111835,0.08343469517749315,0.9105046766306285,0.06318835332992745],[275.3547058105469,0.08889144332609267,-0.5262670516457211,-0.18982271379725946,-0.4016820575862538,-0.08098200955318552,-0.9099416945315267,-0.06402773848181068],[275.9294128417969,0.08769467263553204,-0.526519873564771,-0.1914690472895589,-0.40259243135879197,-0.0782322875156128,-0.9097156486922773,-0.06493444330307332],[276.4953918457031,0.08647050328157814,-0.526833095623277,-0.1929515204907125,-0.40381887656226045,-0.07567162170530971,-0.9092799899326651,-0.06643809531085969],[277.11041259765625,0.08517805159172905,-0.5271805285968386,-0.19446237241012868,-0.4052609225673786,-0.07295637830083641,-0.9087295612023527,-0.06820217080153682],[277.66790771484375,0.0842139690097788,-0.5274987110605023,-0.1955107888440212,-0.40681731300314844,-0.07065519397713958,-0.9080845392698207,-0.06992844159616696],[278.2077941894531,0.08332820654380642,-0.5278166326982331,-0.19642692340980494,-0.40838540575673565,-0.06851235417252206,-0.9074090966563484,-0.07166693097904471],[278.8053283691406,0.0824382405356279,-0.5281896372789516,-0.1972644660518017,-0.4102312984940286,-0.06628898191506083,-0.906577962459109,-0.0737051599011783],[279.3866271972656,0.08156636080973466,-0.5285837676896076,-0.19803951983421256,-0.4119758309431159,-0.06478098888261472,-0.9057173053302806,-0.07586501844311994],[279.97686767578125,0.08067979929174669,-0.5290001732267622,-0.19880606378461355,-0.41372105636660905,-0.06358496033578813,-0.9048121555873488,-0.0781460391790169],[280.5926208496094,0.07978822167321652,-0.5294475340478156,-0.19951016914633196,-0.4159594479835741,-0.06559121310526222,-0.9036099386602818,-0.07851502500121908],[281.2466125488281,0.07881566183541285,-0.5299319405977247,-0.20026563394996325,-0.4183950993754966,-0.06799095287500655,-0.9022792983554759,-0.07883424956747663],[281.8344421386719,0.07790045417202293,-0.5303801583898073,-0.20096605276021723,-0.4206440685794437,-0.07035099861556993,-0.9010246485470669,-0.07914472359771818],[282.4504089355469,0.07686526452571485,-0.5309079561923821,-0.20168310330388267,-0.4230597107372169,-0.07240187473997606,-0.8996593158814765,-0.07994726407296814],[283.011474609375,0.07589140255880829,-0.531398622705748,-0.20232887103765246,-0.4252769735214854,-0.07411192015716256,-0.8983941437384746,-0.0808386144081989],[283.5727233886719,0.07487426401071454,-0.531907973193833,-0.20300021555954503,-0.4274393659399443,-0.0750146317281104,-0.8972017327481625,-0.08183791435055916],[284.1522521972656,0.07384123846355523,-0.5324286402857593,-0.203659091281126,-0.42952094431036386,-0.07582821822582854,-0.8960427209283703,-0.08288113169299909],[284.7510986328125,0.07282770999895459,-0.5329599579454598,-0.2042479039489352,-0.4312378109242659,-0.07632504074446904,-0.895071461740748,-0.08399712472390297],[285.3613586425781,0.07181400437794,-0.5334961812020748,-0.2048248907518959,-0.4326519929409768,-0.07656181335071406,-0.894260902891708,-0.0851350650434863],[286.0013427734375,0.07076145247666274,-0.5340507045500773,-0.20541313680403428,-0.4338916273071296,-0.0766161946543516,-0.893540832313405,-0.08632957464348483],[286.6598205566406,0.06979775273260973,-0.5346349500108861,-0.20586923050553327,-0.43464565615140494,-0.07640446545268015,-0.8930637856354348,-0.0876503624300055],[287.21258544921875,0.06900625828929205,-0.5351016808646321,-0.20623972845036118,-0.43511550629441453,-0.07611771152443189,-0.8927530387667495,-0.08872768422072848],[287.8440856933594,0.06813544902929856,-0.5355827106515585,-0.20663873735485228,-0.4353549345460199,-0.07558984339721637,-0.8925638137447709,-0.0899004723847701],[288.58819580078125,0.0674794101906116,-0.5360544982224149,-0.20682204204931248,-0.43504318021060245,-0.07492280613820161,-0.8926487586318702,-0.0911163991035856],[289.24517822265625,0.06696794166395567,-0.5364542689118053,-0.20691604492280813,-0.43451611513744887,-0.07429768766238683,-0.892851787549767,-0.09214816744280654],[289.9267883300781,0.06640054895789488,-0.5368725408450552,-0.2070108486254242,-0.43377206532374624,-0.07360281632372516,-0.8931604846998012,-0.09321356845869552],[290.51214599609375,0.06582747836140622,-0.53727586159842,-0.20711681233470436,-0.4329149279233707,-0.07301779140977638,-0.8935288158211546,-0.0941239747141311],[291.0709228515625,0.06526852069690642,-0.5376799548755284,-0.20720876516421205,-0.43202420470731534,-0.07248862943906716,-0.8939121419815894,-0.09498193284485261],[291.6835021972656,0.06464647200446628,-0.5381868780559526,-0.2072495428592435,-0.4307341150628666,-0.07211047712061726,-0.8944714805729354,-0.09585912398987935],[292.3565673828125,0.06393694482695789,-0.5387404337839334,-0.207353206914724,-0.42929267441822244,-0.07180157097318432,-0.8950992397791052,-0.09669376941406703],[292.9378356933594,0.06330580926517533,-0.5392134023853334,-0.20748571386371406,-0.428029269405094,-0.07161608051207369,-0.8956516144736564,-0.09731529702653317],[293.5326232910156,0.06266165597923196,-0.5397396799172244,-0.20762007227685172,-0.4275421579133185,-0.07243272681163154,-0.8958344774937858,-0.09716888507588493],[294.1809387207031,0.06195218655000001,-0.5403428728037544,-0.2077710748497037,-0.4274527883269057,-0.07376781235750389,-0.8958058439283122,-0.0968210390123234],[294.7513427734375,0.06131400119018819,-0.5409284681918278,-0.20792011827760726,-0.428142349985316,-0.0756628928770945,-0.8953723057363134,-0.09632076053976321],[295.3338928222656,0.060664571380344395,-0.5415591253058609,-0.20807788443541442,-0.4293513653855821,-0.07719444121695235,-0.8946728753926467,-0.09622301867740705],[295.987060546875,0.059940755685595065,-0.5422976277709584,-0.20825637607224234,-0.43112630199642576,-0.07857521289139788,-0.8936729277584963,-0.09646111049286132],[296.5676574707031,0.05933001577822804,-0.5429780365833219,-0.20846962578625866,-0.4319290750371869,-0.07966944965391304,-0.893077649323724,-0.09748007595285478],[297.1764221191406,0.058690509094970894,-0.5437252028570331,-0.20869691336287483,-0.43284821067358303,-0.08072419886067264,-0.892416084750745,-0.0985878385660801],[297.88336181640625,0.05794242825819064,-0.5446719754245584,-0.20897926279986762,-0.4341936713106025,-0.08169108497531365,-0.8915241728321901,-0.09993533752009862],[298.49420166015625,0.05733533730600343,-0.5454847712469303,-0.20925965451886636,-0.43512156361903964,-0.08244548403178018,-0.8908537355157108,-0.10125013063789934],[299.1217346191406,0.056718159522647346,-0.5463303622384124,-0.2095546701054491,-0.4360322315540318,-0.08318172578520891,-0.8901778552046873,-0.10266489002861974],[299.74554443359375,0.056092333854999024,-0.5472100536155672,-0.20984437151659407,-0.43700415691365657,-0.08382738084466868,-0.8894643033837618,-0.10418056472752793],[300.34918212890625,0.05550056435391294,-0.5480541219644124,-0.2101371404012909,-0.4379583501822811,-0.08438002138174153,-0.8887703707108472,-0.10563959316342897],[300.91705322265625,0.05495256428624688,-0.5488472658171905,-0.2104175365840394,-0.43886483763710005,-0.08484960714277352,-0.8881146362547582,-0.10700743583301742],[301.5957336425781,0.05430253360502574,-0.549779553376222,-0.21074209357948628,-0.4399266800515988,-0.08524443809188588,-0.8873529169604024,-0.1086402444540786],[302.14208984375,0.05378870099974806,-0.550518623762605,-0.21099038462225567,-0.440776553934244,-0.08551303080553592,-0.8867455575347664,-0.10993574148865574],[302.71197509765625,0.05326950531173258,-0.5512615808756394,-0.21122401292344992,-0.44166005015937276,-0.08570195249306062,-0.886125936137858,-0.11123129386958831],[303.37896728515625,0.05263794542240012,-0.5520861605728722,-0.21151200468826936,-0.442475261848101,-0.08572390581086568,-0.8855390255414683,-0.11263964163672952],[303.9695129394531,0.052063143901291936,-0.5527884920066861,-0.21177688305382603,-0.4430495341445945,-0.08560971312602807,-0.8851126666927135,-0.11381412290594868],[304.5807189941406,0.05149466965464486,-0.5534226162690663,-0.2120341445001541,-0.4432845315901681,-0.08520340591147586,-0.8849006098553399,-0.11484822311040348],[305.2320251464844,0.05090305976477397,-0.5540410662282634,-0.2123155575612464,-0.4434346049359933,-0.08464815119179014,-0.8847395025967685,-0.11591572020176633],[305.7947692871094,0.05041393552544951,-0.5544996165519516,-0.2125673650563832,-0.44344144820383125,-0.08400170346102268,-0.8846814476241184,-0.1167995379281509]]}]=])
local good,instance=pcall(Fit.new,FC,sdk,thread,adapter,FitMath)
local old_status=_G.scarlet_manual_adapter.status
_G.scarlet_manual_adapter.status=function()local s=old_status();s.left_sheath_reference_fit=good and instance.status()or{faults=1,error=tostring(instance)};return s end
re.on_script_reset(function()scarlet_reset_required=true;scarlet_reset_reason='script_reset_requires_restart';end)
end

do
local Maths=(function()
local M={}
function M.add(a,b)return{a[1]+b[1],a[2]+b[2],a[3]+b[3]}end
function M.sub(a,b)return{a[1]-b[1],a[2]-b[2],a[3]-b[3]}end
function M.mul(a,s)return{a[1]*s,a[2]*s,a[3]*s}end
function M.dot(a,b)return a[1]*b[1]+a[2]*b[2]+a[3]*b[3]end
function M.cross(a,b)return{a[2]*b[3]-a[3]*b[2],a[3]*b[1]-a[1]*b[3],a[1]*b[2]-a[2]*b[1]}end
function M.length(v)return math.sqrt(M.dot(v,v))end
function M.unit(v)local n=M.length(v);assert(n>1e-10,'Degenerate arm vector');return M.mul(v,1/n)end
function M.qnorm(q)local n=math.sqrt(q[1]^2+q[2]^2+q[3]^2+q[4]^2);assert(n>1e-10,'Degenerate rotation');return{q[1]/n,q[2]/n,q[3]/n,q[4]/n}end
function M.qmul(a,b)return M.qnorm({a[4]*b[1]+a[1]*b[4]+a[2]*b[3]-a[3]*b[2],a[4]*b[2]-a[1]*b[3]+a[2]*b[4]+a[3]*b[1],a[4]*b[3]+a[1]*b[2]-a[2]*b[1]+a[3]*b[4],a[4]*b[4]-a[1]*b[1]-a[2]*b[2]-a[3]*b[3]})end
function M.qinv(q)q=M.qnorm(q);return{-q[1],-q[2],-q[3],q[4]}end
function M.rotate(q,v)q=M.qnorm(q);local xyz={q[1],q[2],q[3]};local t=M.mul(M.cross(xyz,v),2);return M.add(v,M.add(M.mul(t,q[4]),M.cross(xyz,t)))end
function M.from_to(a,b)
 a=M.unit(a);b=M.unit(b);local d=math.max(-1,math.min(1,M.dot(a,b)))
 if d>1-1e-10 then return{0,0,0,1}end
 if d< -1+1e-8 then local basis=math.abs(a[1])<.8 and{1,0,0}or{0,1,0};local axis=M.unit(M.cross(a,basis));return{axis[1],axis[2],axis[3],0}end
 local c=M.cross(a,b);return M.qnorm({c[1],c[2],c[3],1+d})
end
function M.solve(shoulder,elbow,hand,target,upper_q,forearm_q,pole_hint)
 local upper=M.sub(elbow,shoulder);local lower=M.sub(hand,elbow);local a=M.length(upper);local b=M.length(lower)
 assert(a>.05 and a<1 and b>.05 and b<1,'Unexpected arm dimensions')
 local vector=M.sub(target,shoulder);local distance=M.length(vector);local dir=distance>1e-8 and M.mul(vector,1/distance)or M.unit(M.sub(hand,shoulder))
 local d=math.max(math.abs(a-b)+1e-6,math.min(a+b-1e-6,distance))
 local pole=pole_hint or upper;pole=M.sub(pole,M.mul(dir,M.dot(pole,dir)))
 if M.length(pole)<1e-7 then local basis=math.abs(dir[2])<.8 and{0,1,0}or{0,0,1};pole=M.cross(dir,basis)end
 pole=M.unit(pole);local along=(a*a-b*b+d*d)/(2*d);local height=math.sqrt(math.max(0,a*a-along*along))
 local next_elbow=M.add(shoulder,M.add(M.mul(dir,along),M.mul(pole,height)));local next_hand=M.add(shoulder,M.mul(dir,d))
 return{upper_rotation=M.qmul(M.from_to(upper,M.sub(next_elbow,shoulder)),upper_q),forearm_rotation=M.qmul(M.from_to(lower,M.sub(next_hand,next_elbow)),forearm_q),elbow=next_elbow,hand=next_hand,clamp_distance=math.abs(distance-d),upper_length=a,lower_length=b}
end
return M

end)()
local Release=(function()
-- Cancel the existing drawn-blade grip offset only at the end of sheathing.
-- Character joints, animation clocks, normal grip and sheath placement are untouched.
local M={}
function M.new(C,sdk,A,V)
 local methods,defs={},{ };local image;local lease;local closed=false
 local S={schema='scarlet-sheath-grip-release-v1',frames=0,writes=0,restores=0,faults=0,matched=0,max_compensation_m=0,bone_writes=0,parameter_writes=0,records={}}
 local function need(x,msg)if not x then error(msg,0)end;return x end
 local function id(x)return x and tostring(x:get_address())end
 local function same(a,b)return a and b and id(a)==id(b)end
 local function managed(x,t)return x and sdk.is_managed_object(x)and x:get_type_definition():is_a(t)end
 for name,crc in pairs(C.crcs)do local t=sdk.find_type_definition(name);need(t and t:get_crc_hash()==crc,'Grip release type changed '..name);defs[name]=t end
 for _,s in ipairs(C.methods)do local f=defs[s.type]:get_method(s.name..'('..table.concat(s.params,', ')..')');need(f and f:get_num_params()==#s.params and f:get_return_type():get_full_name()==s.returns and f:is_static()==s.is_static,'Grip release method changed '..s.key);local b=sdk.to_int64(f:get_function())-s.rva;image=image or b;need(image==b,'Grip release image changed');methods[s.key]=f end
 local function call(k,o,...)return methods[k]:call(o,...)end
 local function vec(x)return{x.x,x.y,x.z}end
 local function quat(x)return V.qnorm({x.x,x.y,x.z,x.w})end
 local function valid(x)return managed(x,'via.GameObject')and call('go_valid',x)end
 local function canon(x)return type(x)=='string'and x:lower():gsub('\\','/'):gsub('^@',''):gsub('%.%d+$','')end
 local function arr(x,n)local k=call('array_length',x,0);need(k>=0 and k<=n,'Grip release array bound');local r={};for i=0,k-1 do r[#r+1]=call('array_value',x,i)end;return r end
 local function localp(l)return vec(call('local_p',l.transform))end
 local function restore()
  if not lease then return end;local l=lease
  if l.written and valid(l.go)then
   local p=localp(l);need(V.length(V.sub(p,l.last))<.0001,'Another writer changed the blade mesh offset; preserve it')
   call('set_local_p',l.transform,Vector3f.new(l.base[1],l.base[2],l.base[3]));S.restores=S.restores+1;l.written=false
  end
 end
 local function find(ctx)
  local queue={ctx.actor_transform};local seen={};local nodes=0;local found
  while#queue>0 do
   local tr=table.remove(queue);nodes=nodes+1;need(nodes<=512 and not seen[id(tr)],'Grip release subtree bound');seen[id(tr)]=true
   local go=call('component_go',tr);need(valid(go),'Grip release invalid subtree owner')
   for _,c in ipairs(arr(call('components',go),128))do if managed(c,'via.render.Mesh')and call('mesh_ready',c)and canon(call('resource_path',call('mesh_holder',c)))==C.blade_resource then
    need(not found,'Multiple matching blades on owned character');local parent=call('parent',tr);need(parent,'Blade parent missing')
    local p=vec(call('local_p',tr));need(V.length(p)<.0001,'Blade mesh has an unexpected local offset')
    found={ctx=ctx,key=ctx.key,go=go,mesh=c,transform=tr,parent=parent,base=p,socket=call('joint',ctx.actor_transform,'R_Wep')}
   end end
   local child=call('child',tr);local siblings={}
   while child do need(not siblings[id(child)],'Grip release sibling cycle');siblings[id(child)]=true;need(same(call('parent',child),tr),'Grip release ancestry differs');queue[#queue+1]=child;child=call('next',child)end
  end
  return found
 end
 local function frame(ctx)
  local pm=call('pm',nil);local info=pm and call('info',pm);local ch=info and call('character',info)
  if not ch or not same(call('component_go',ch),ctx.actor)then return end
  local ac=call('action_controller',ch);local act=ac and call('current_action',ac)
  if not act or act:get_type_definition():get_full_name()~='app.PlayerBasicAction.cAutoWeaponOffIdle'then return end
  local motion
  for _,c in ipairs(arr(call('components',ctx.actor),128))do if managed(c,'via.motion.Motion')then motion=c;break end end
  if not motion then return end;local l=call('layer',motion,0)
  if call('layer_bank',l)~=10000 or call('layer_motion',l)~=747 then return end
  return call('layer_frame',l)
 end
 local function work()
  local ctx=A.peek_owned_player()
  if not ctx or not A.current_owner_context(ctx)or ctx.skip_native then restore();lease=nil;return end
  if lease and(lease.key~=ctx.key or not valid(lease.go))then restore();lease=nil end
  local f=frame(ctx)
  if not f or f<C.start_frame or f>C.end_frame then restore();return end
  if not lease then lease=find(ctx);if not lease then S.waiting='Owned katana not ready';return end end
  local l=lease;need(l.socket and same(call('parent',l.transform),l.parent),'Owned blade topology changed')
  local sm=call('joint_matrix',l.socket);local pm=call('world_matrix',l.parent)
  local delta=V.sub(vec(pm[3]),vec(sm[3]));local relative={};local rotation_error=0
  for i=0,2 do relative[i+1]=V.dot(delta,vec(sm[i]));local a,b=vec(pm[i]),vec(sm[i]);for j=1,3 do rotation_error=math.max(rotation_error,math.abs(a[j]-b[j]))end end
  local offset_error=V.length(V.sub(relative,C.grip_offset))
  -- Once the native game changes to the sheathed attachment, release our mesh
  -- correction. This follows actual attachment state rather than a guessed cut frame.
  if offset_error>.001 or rotation_error>.002 then restore();S.last_release_frame=f;return end
  local current=localp(l);need(V.length(V.sub(current,l.written and l.last or l.base))<.0001,'Foreign blade mesh transform writer')
  local t=math.max(0,math.min(1,(f-C.start_frame)/(C.full_frame-C.start_frame)));local w=t*t*t*(t*(t*6-15)+10)
  local p=V.sub(l.base,V.mul(C.grip_offset,w))
  call('set_local_p',l.transform,Vector3f.new(p[1],p[2],p[3]));l.last=p;l.written=true
  S.writes=S.writes+1;S.matched=S.matched+1;S.max_compensation_m=math.max(S.max_compensation_m,V.length(V.sub(p,l.base)))
  if#S.records<256 then S.records[#S.records+1]={frame=f,weight=w,offset_error_m=offset_error,mesh=id(l.go),local_position=p}end
 end
 return{step=function()
  if closed then return end;S.frames=S.frames+1;local ok,e=pcall(work)
  if not ok then S.faults=S.faults+1;S.error=tostring(e);pcall(restore);closed=true end
 end,status=function()S.closed=closed;return S end,pause=function()local ok,why=pcall(restore);if not ok then S.restore_error=tostring(why);return false end;lease=nil;return true end,close=function()pcall(restore);closed=true;lease=nil end}
end
return M

end)()
local GC=json.load_string([=[{"crcs":{"ace.GAElement`1<app.PlayerManager>":437989116,"app.PlayerManager":346041440,"app.cPlayerManageInfo":3185740719,"via.Component":1881844667,"app.CharacterBase":1997845319,"ace.cActionController":1972218437,"via.GameObject":4065074914,"via.Transform":1340992935,"via.Joint":1272281384,"via.motion.Motion":1638522585,"via.motion.TreeLayer":827969571,"System.Array":58605515,"via.render.Mesh":1829138609,"via.ResourceHolder":1072471267},"methods":[{"key":"pm","type":"ace.GAElement`1<app.PlayerManager>","name":"get_Instance","params":[],"returns":"app.PlayerManager","is_static":true,"rva":109939872,"hook_only":false},{"key":"info","type":"app.PlayerManager","name":"getControllingPlayer","params":[],"returns":"app.cPlayerManageInfo","is_static":false,"rva":77873440,"hook_only":false},{"key":"character","type":"app.cPlayerManageInfo","name":"get_Character","params":[],"returns":"app.PlayerCharacter","is_static":false,"rva":94360256},{"key":"component_go","type":"via.Component","name":"get_GameObject","params":[],"returns":"via.GameObject","is_static":false,"rva":94821856,"hook_only":false},{"type":"app.CharacterBase","name":"get_BaseActionController","params":[],"returns":"ace.cActionController","is_static":false,"rva":107271456,"key":"action_controller"},{"type":"ace.cActionController","name":"get_CurrentAction","params":[],"returns":"ace.cActionBase","is_static":false,"rva":94387552,"key":"current_action"},{"key":"transform","type":"via.GameObject","name":"get_Transform","params":[],"returns":"via.Transform","is_static":false,"rva":97957552},{"key":"components","type":"via.GameObject","name":"get_Components","params":[],"returns":"via.Component[]","is_static":false,"rva":97957600},{"key":"joint","type":"via.Transform","name":"getJointByName","params":["System.String"],"returns":"via.Joint","is_static":false,"rva":125569776},{"key":"joint_p","type":"via.Joint","name":"get_Position","params":[],"returns":"via.vec3","is_static":false,"rva":109358800},{"key":"joint_q","type":"via.Joint","name":"get_Rotation","params":[],"returns":"via.Quaternion","is_static":false,"rva":109359552},{"key":"layer","type":"via.motion.Motion","name":"getLayer","params":["System.UInt32"],"returns":"via.motion.TreeLayer","is_static":false,"rva":99052976},{"key":"layer_bank","type":"via.motion.TreeLayer","name":"get_MotionBankID","params":[],"returns":"System.UInt32","is_static":false,"rva":117848112},{"key":"layer_motion","type":"via.motion.TreeLayer","name":"get_MotionID","params":[],"returns":"System.UInt32","is_static":false,"rva":117848160},{"key":"layer_frame","type":"via.motion.TreeLayer","name":"get_Frame","params":[],"returns":"System.Single","is_static":false,"rva":117848464},{"key":"array_length","type":"System.Array","name":"GetLength","params":["System.Int32"],"returns":"System.Int32","is_static":false,"rva":114447776,"hook_only":false},{"key":"array_value","type":"System.Array","name":"GetValue","params":["System.Int32"],"returns":"System.Object","is_static":false,"rva":114447856,"hook_only":false},{"key":"go_valid","type":"via.GameObject","name":"get_Valid","params":[],"returns":"System.Boolean","is_static":false,"rva":94806192,"hook_only":false},{"key":"child","type":"via.Transform","name":"get_Child","params":[],"returns":"via.Transform","is_static":false,"rva":94762288,"hook_only":false},{"key":"next","type":"via.Transform","name":"get_Next","params":[],"returns":"via.Transform","is_static":false,"rva":94384720,"hook_only":false},{"key":"parent","type":"via.Transform","name":"get_Parent","params":[],"returns":"via.Transform","is_static":false,"rva":125570976,"hook_only":false},{"key":"mesh_ready","type":"via.render.Mesh","name":"get_MeshReady","params":[],"returns":"System.Boolean","is_static":false,"rva":122191152,"hook_only":false},{"key":"mesh_holder","type":"via.render.Mesh","name":"getMesh","params":[],"returns":"via.render.MeshResourceHolder","is_static":false,"rva":122190144,"hook_only":false},{"key":"resource_path","type":"via.ResourceHolder","name":"get_ResourcePath","params":[],"returns":"System.String","is_static":false,"rva":116635664,"hook_only":false},{"key":"local_p","type":"via.Transform","name":"get_LocalPosition","params":[],"returns":"via.vec3","is_static":false,"rva":94490784},{"key":"set_local_p","type":"via.Transform","name":"set_LocalPosition","params":["via.vec3"],"returns":"System.Void","is_static":false,"rva":125570544},{"key":"world_p","type":"via.Transform","name":"get_Position","params":[],"returns":"via.vec3","is_static":false,"rva":125570192},{"key":"world_q","type":"via.Transform","name":"get_Rotation","params":[],"returns":"via.Quaternion","is_static":false,"rva":125570304},{"key":"joint_matrix","type":"via.Joint","name":"get_WorldMatrix","params":[],"returns":"via.mat4","is_static":false,"rva":109360048},{"key":"world_matrix","type":"via.Transform","name":"get_WorldMatrix","params":[],"returns":"via.mat4","is_static":false,"rva":125570800}],"blade_resource":"art/model/item/it0/it000_0000/it000_0000_00.mesh","grip_offset":[0.011774236055444889,-0.024549714072299427,0.008481776828853371],"start_frame":140,"full_frame":156,"end_frame":200}]=])
local good,release=pcall(Release.new,GC,sdk,adapter,Maths)
scarlet_gate.on_disable(function()if good and release and release.pause then local ok,result=pcall(release.pause);return ok and result~=false end;return true end)
local previous=_G.scarlet_manual_adapter.status
_G.scarlet_manual_adapter.status=function()local s=previous();s.sheath_grip_release=good and release.status()or{faults=1,error=tostring(release)};return s end
re.on_application_entry('UpdateBehavior',function()if not scarlet_gate.allow('UpdateBehavior') then return end;if good then release.step()end end)
re.on_script_reset(function()scarlet_reset_required=true;scarlet_reset_reason='script_reset_requires_restart';end)
end

_G.scarlet_manual_adapter.manual_migration=true
_G.scarlet_manual_adapter.original_author='Little1113'
_G.scarlet_manual_adapter.gate=scarlet_gate.status
_G.scarlet_manual_adapter.voice_api_version=1
_G.scarlet_manual_adapter.voice_host={clock=adapter.clock,frequency=adapter.frequency,peek_owned_player=adapter.peek_owned_player,current_owner_context=adapter.current_owner_context}

do
local Isolation=(function()
-- Instance-owned driver selection. Scarlet assets remain the accepted bytes.
local M={}
 function M.new(C,sdk,invalidate,actor_preflight)
 local defs,methods,fields={},{ },{};local image;local closed=false;local owners={};local refs={};local load_at=0
 local S={schema='scarlet-costume-driver-isolation-v2',phase='waiting',errors=0,transitions=0,owners={},events={},blocked_reason=nil,actor_contract_required=true}
 local function need(v,s)if not v then error(s,0)end;return v end
 local function id(o)return o and tostring(o:get_address())end
 local function same(a,b)return a and b and id(a)==id(b)end
 local function canon(p)return type(p)=='string'and scarlet_gate.route(p):lower():gsub('\\','/'):gsub('^@',''):gsub('%.%d+$','')end
 for n,crc in pairs(C.crcs)do local t=sdk.find_type_definition(n);need(t and t:get_crc_hash()==crc,'Isolation type mismatch '..n);defs[n]=t end
 for _,s in ipairs(C.methods)do
  local m=defs[s.type]:get_method(s.name..'('..table.concat(s.params,', ')..')')
  need(m and m:get_num_params()==#s.params and m:get_return_type():get_full_name()==s.returns and m:is_static()==s.is_static,'Isolation method mismatch '..s.key)
  local b=sdk.to_int64(m:get_function())-s.rva;image=image or b;need(b==image,'Isolation method image mismatch');methods[s.key]=m
 end
 for _,s in ipairs(C.fields or{})do local f=defs[s.type]:get_field(s.name);need(f and f:get_type():get_full_name()==s.returns and f:get_offset_from_base()==s.offset,'Isolation field mismatch '..s.key);fields[s.key]=f end
 local function call(k,o,...)local ok,r=pcall(methods[k].call,methods[k],o,...);if not ok then error(k..': '..tostring(r),0)end;return r end
 local function managed(o,t)return o and sdk.is_managed_object(o)and o:get_type_definition():is_a(t)end
 local function keep(o)need(managed(o,'System.Object'),'Missing managed isolation object');o:add_ref();return o end
 local function valid(o)return managed(o,'via.GameObject')and call('go_valid',o)end
 local function path(h)return h and canon(call('resource_path',h))end
 local function array(a,nmax)local n=call('array_length',a,0);need(n>=0 and n<=nmax,'Isolation array bound');local r={};for i=0,n-1 do r[#r+1]=call('array_value',a,i)end;return r end
 local function components(go)return array(call('components',go),128)end
 local function event(kind,v)S.events[#S.events+1]={kind=kind,time=os.clock(),data=v};if#S.events>40 then table.remove(S.events,1)end end
 local function load()
  if refs.ready then return true end
  if os.clock()<load_at then return false end
  local x=C.resources[#refs+1]
  if not x then refs.ready=true;return true end
  if x.user then
   local o=refs.loading_user
   if not o then o=keep(sdk.create_userdata(x.type,scarlet_gate.route(x.path)));refs.loading_user=o;refs.loading_started=os.clock()end
   need(managed(o,x.type),'USER root mismatch')
   if x.key:match('_sheath$')or x.key:match('_visual$')then
    local states=o:get_field(x.key:match('_sheath$')and'_StateParam'or'_DataList')
    if not states then need(os.clock()-refs.loading_started<8,'Original USER load timed out');return false end
    need(#array(states,128)==(x.key:match('_sheath$')and 7 or 24),'Parameter count differs')
   end
   refs[#refs+1]={object=o};refs[x.key]=o
   refs.loading_user=nil
  else
   local resource=need(sdk.create_resource(x.type,scarlet_gate.route(x.path)),'Cannot load '..x.path):add_ref()
   local h=need(resource:create_holder(x.holder),'Cannot construct '..x.path);h:add_ref();need(path(h)==canon(x.path),'Resource path mismatch')
   refs[#refs+1]={raw=resource,holder=h};refs[x.key]=h
  end
  load_at=os.clock()+.1;S.phase='load_'..x.key;return false
 end
 local body_type=call('part_object_type',nil,0)
 if type(body_type)~='number'then body_type=body_type:get_field('value__')end
 local function family(s)
  local b=call(s.role=='ui'and'ui_part_go'or'player_part_go',s.processor,body_type)
  if not valid(b)then return end
  for _,m in ipairs(components(b))do
   if managed(m,'via.render.Mesh')and call('mesh_ready',m)then
    local p=path(call('mesh_holder',m))
    if C.scarlet_bodies[p]then return 'scarlet',b,p end
    if p and p:match('^art/model/character/')then return 'native',b,p end
   end
  end
 end
  local function route_map(map,key)
   if not map then return nil end;local direct=map[key];if direct then return direct end
   for source,value in pairs(map)do if canon(source)==key then return value end end
  end
 local function bind(root,role,processor,entity)
  if not valid(root)or not processor then return end
  local key=id(root);local s=owners[key]
  if s then need(same(s.processor,processor),'Owner processor changed');return s end
  s={root=keep(root),processor=keep(processor),entity=entity and keep(entity),role=role,key=key,phase='initial',chains={},constraints={},layers={},jc_components={}}
  for _,c in ipairs(components(root))do
   if managed(c,'via.motion.DummySkeleton')then need(not s.skeleton,'Multiple root skeletons');s.skeleton=keep(c)end
   if managed(c,'via.motion.Motion')then need(not s.motion,'Multiple root motions');s.motion=keep(c)end
   if managed(c,'via.motion.ConstraintJoints')or managed(c,'via.motion.ConstraintParent')then s.constraints[#s.constraints+1]={component=keep(c),enabled=C.public_native and managed(c,'via.motion.ConstraintJoints')or call('constraint_get',c)}end
   if managed(c,'via.motion.JointConstraints')then
    local count=call('jc_count',c);need(count>=0 and count<=32,'Constraint layer bound')
    local custom=false
    for i=0,count-1 do local layer=call('jc_layer',c,i);local p=path(call('layer_asset',layer));if p and p:match('^mods/scarlet_[^/]+/')then custom=true;s.layers[#s.layers+1]={layer=keep(layer),enabled=call('layer_get',layer)}end end
    if custom then s.jc_components[#s.jc_components+1]={component=keep(c),enabled=C.public_native or call('constraint_get',c)}end
   end
  end
  if not(s.skeleton and s.motion)then return end
  need(same(call('component_go',s.skeleton),root)and same(call('component_go',s.motion),root),'Component owner mismatch')
  local rig=call('skeleton_get',s.skeleton);need(path(rig)==(C.public_native and C.native_rig or C.scarlet_rig),'Unexpected initial rig')
  s.scarlet_rig=keep(C.public_native and refs.scarlet_rig or rig)
  s.scarlet_bank=keep(C.public_native and refs[role=='ui'and'scarlet_designchange'or'scarlet_common']or call('motion_bank',s.motion))
  need(path(s.scarlet_bank)==scarlet_gate.route(C.scarlet_banks[role]),'Unexpected Scarlet root bank')
  local todo={call('transform',root)};local visited={};local count=0
  while #todo>0 do
   local t=table.remove(todo);need(not visited[id(t)],'Chain owner hierarchy cycle');visited[id(t)]=true;count=count+1;need(count<=512,'Chain owner hierarchy bound')
   for _,c in ipairs(components(call('component_go',t)))do
    if managed(c,'via.motion.Chain2')then
     local h=call('chain_get',c);local hp=path(h);local key=route_map(C.chain_map,hp);local pair=route_map(C.chain_pairs,hp)
     if pair then s.chains[#s.chains+1]={component=keep(c),scarlet=refs[pair.scarlet],native=refs[pair.native]}
     elseif key then s.chains[#s.chains+1]={component=keep(c),scarlet=keep(h),native=refs[key]}end
    end
   end
   local child=call('child',t);while child do todo[#todo+1]=child;child=call('next',child)end
  end
  if role=='player'then
   local sheath=call('entity_sheath',entity)
   if not sheath then return end
   s.sheath=keep(sheath);s.scarlet_sheath=keep(C.public_native and refs.scarlet_sheath or call('sheath_cached',sheath));need(managed(s.scarlet_sheath,'app.user_data.SheathHoldParam'),'Cached sheath type')
   local pack=call('entity_pack',entity);local visual=pack:get_field('_WeaponVisualParam')
   local scarlet=array((C.public_native and refs.scarlet_visual or visual):get_field('_DataList'),128);local native=array((C.public_native and visual or refs.original_visual):get_field('_DataList'),128)
   need(#scarlet==#native,'Visual parameter inventory differs');s.visual_map={}
   for i,x in ipairs(scarlet)do local row={scarlet=keep(x),native=keep(native[i])};s.visual_map[id(x)]=row;s.visual_map[id(native[i])]=row end
  else s.scarlet_visual=keep(C.public_native and refs.scarlet_visual or fields.ui_visual:get_data(processor))end
  owners[key]=s;event('bound',{owner=key,role=role});return s
 end
 local function dynamic(s)
  local count=call('dynamic_count',s.motion);need(count>=0 and count<=16,'Dynamic bank bound');local r={}
  for i=0,count-1 do local b=call('dynamic',s.motion,i);r[#r+1]={object=b,index=i,path=path(call('dynamic_bank',b)),list=path(call('dynamic_list',b))}end
  return r
 end
 local function snapshot(s)
  local tr=call('transform',s.root);local joints=call('joints',tr);local n=call('array_length',joints,0);local positions={}
  for name in pairs(C.bind_checks.native)do local j=call('joint',tr,name);if j then local p=call('joint_base_p',j);positions[name]={p.x,p.y,p.z}end end
  local banks={};for _,r in ipairs(dynamic(s))do banks[#banks+1]={index=r.index,path=r.path,list=r.list}end
  local active={};local count=call('active_bank_count',s.motion);need(count<128,'Active motion bank bound')
  for i=0,count-1 do local b=call('active_bank',s.motion,i);active[#active+1]={id=call('bank_id',b),kind=call('bank_kind',b),valid=call('bank_valid',b),dynamic=call('bank_dynamic',b)}end
  return {rig=path(call('skeleton_get',s.skeleton)),joint_count=n,constructed=call('joints_constructed',s.motion),base_positions=positions,bank=path(call('motion_bank',s.motion)),dynamic=banks,active_banks=active}
 end
 local function restore_loaded_banks(s)
  local ready=true;local count=call('active_bank_count',s.motion);need(count<128,'Active motion bank bound')
  s.bank_load_requests=s.bank_load_requests or{}
  for i=0,count-1 do
   local b=call('active_bank',s.motion,i);local key=tostring(call('bank_id',b))..':'..tostring(call('bank_kind',b))
   if s.previously_loaded and s.previously_loaded[key]and not call('bank_valid',b)then
    ready=false
    if call('bank_dynamic',b)and not s.bank_load_requests[id(b)]then
     local result=call('bank_load',b);s.bank_load_requests[id(b)]=true
     event('restore_loaded_bank',{owner=s.key,bank=key,requested=result})
    end
   end
  end
  return ready
 end
 local function apply_banks(s,want)
  local changed=false;local target=want=='native'and refs[s.role=='ui'and'original_designchange'or'original_common']or s.scarlet_bank
  if path(call('motion_bank',s.motion))~=path(target)then call('motion_bank_set',s.motion,target);changed=true end
  for _,r in ipairs(dynamic(s))do
   if r.path==scarlet_gate.route(C.scarlet_weapon) or r.path==C.original_weapon then
    if not s.scarlet_weapon then s.scarlet_weapon=keep(refs.scarlet_weapon)end
    local h=want=='native'and refs.original_weapon or s.scarlet_weapon
    if r.path~=path(h)then call('dynamic_bank_set',r.object,h);changed=true end
   end
  end
  if changed then call('motion_setup',s.motion)end
  return changed
 end
 local function custom_enabled(s,on)
  for _,x in ipairs(s.constraints)do call('constraint_set',x.component,on and x.enabled or false)end
  for _,x in ipairs(s.layers)do call('layer_set',x.layer,on and x.enabled or false)end
  for _,x in ipairs(s.jc_components)do call('constraint_set',x.component,on and x.enabled or false)end
 end
 local function apply_parameters(s,want)
  for _,x in ipairs(s.chains)do
   local h=want=='native'and x.native or x.scarlet
   if path(call('chain_get',x.component))~=path(h)then call('chain_set',x.component,h);need(path(call('chain_get',x.component))==path(h),'Chain resource selection failed')end
  end
  if s.sheath then
   local target=want=='native'and refs.original_sheath or s.scarlet_sheath
   local before=call('sheath_cached',s.sheath)
   if not same(before,target)then
    call('sheath_set',s.sheath,sdk.to_ptr(target:get_address()))
    need(same(call('sheath_cached',s.sheath),target),'Sheath parameter readback differs')
    call('sheath_init',s.sheath)
   end
   s.sheath_parameter=id(target)
  else
   local target=want=='native'and refs.original_visual or s.scarlet_visual
   if not same(fields.ui_visual:get_data(s.processor),target)then s.processor:set_field(C.ui_visual_field,target);need(same(fields.ui_visual:get_data(s.processor),target),'Preview visual parameter readback differs');call('ui_update_weapon',s.processor)end
   s.visual_parameter=id(target)
  end
 end
 local function process(s)
  if not s or s.failed then return end
  local ok,why=pcall(function()
   local want,b,p=family(s);if not want then return end;s.body_path=p;s.body=id(b)
   if(s.phase=='settling'and s.target~=want)or(s.phase~='settling'and s.family~=want)then
    s.target=want;s.started=os.clock();s.phase='settling';s.before=snapshot(s);s.previously_loaded=s.previously_loaded or{};s.bank_load_requests={}
    for _,b in ipairs(s.before.active_banks)do if b.valid then s.previously_loaded[tostring(b.id)..':'..tostring(b.kind)]=true end end
    invalidate();custom_enabled(s,false)
    local target=want=='native'and refs.original_rig or s.scarlet_rig
    if path(call('skeleton_get',s.skeleton))~=path(target)then call('skeleton_set',s.skeleton,target)end
    apply_banks(s,want);restore_loaded_banks(s);event('requested',{owner=s.key,role=s.role,target=want,before=s.before})
   elseif s.phase=='settling'then
    local loaded=restore_loaded_banks(s);local v=snapshot(s);s.after=v;local ready=loaded and v.joint_count==C.joint_counts[want] and v.constructed and v.rig==(want=='native'and C.native_rig or scarlet_gate.route(C.scarlet_rig))
    for name,p in pairs(C.bind_checks[want])do local q=v.base_positions[name];if not q then ready=false else for i=1,3 do if math.abs(p[i]-q[i])>2e-6 then ready=false end end end end
    if ready and os.clock()-s.started>.3 then
     apply_parameters(s,want);custom_enabled(s,want=='scarlet')
     s.family=want;s.phase='ready';S.transitions=S.transitions+1;invalidate();event('ready',{owner=s.key,role=s.role,family=want,after=v,sheath_parameter=s.sheath_parameter,visual_parameter=s.visual_parameter,chains=#s.chains,custom_constraints=#s.constraints,custom_layers=#s.layers})
    else need(os.clock()-s.started<5,'Driver did not settle')end
   else
    if apply_banks(s,want)then event('dynamic_reselected',{owner=s.key,family=want})end
   end
  end)
  if not ok then s.failed=true;s.error=tostring(why);S.errors=S.errors+1;event('error',{owner=s.key,error=s.error})end
  S.owners[s.key]={role=s.role,family=s.family,target=s.target,phase=s.phase,body=s.body,body_path=s.body_path,error=s.error,after=s.after,sheath_parameter=s.sheath_parameter,visual_parameter=s.visual_parameter}
 end
 local function owning(go)
  local t=valid(go)and call('transform',go);local seen={}
  for _=1,16 do if not t or seen[id(t)]then return end;seen[id(t)]=true;local s=owners[id(call('component_go',t))];if s then return s end;t=call('parent',t)end
 end
 local weapons={};local updating=false
 local function weapon_owner(gm)
  local c=call('weapon_owner',gm);return c and owning(call('component_go',c))or owning(call('component_go',gm))
 end
 sdk.hook(methods.gm_setup_visual,function(args)
  if closed or S.weapon_error or not scarlet_gate.allow('weapon_setup_visual') then return end
  local ok,e=pcall(function()
   local gm=sdk.to_managed_object(args[2]);local s=weapon_owner(gm);if not s or not s.visual_map then return end
   local want=family(s);local value=sdk.to_managed_object(args[3]);local row=value and s.visual_map[id(value)]
   if row and want then args[3]=sdk.to_ptr(row[want]:get_address());S.visual_setup_routes=(S.visual_setup_routes or 0)+1 end
  end);if not ok then S.weapon_error=tostring(e);S.errors=S.errors+1 end
  return sdk.PreHookResult.CALL_ORIGINAL
 end,function(ret)return ret end)
 sdk.hook(methods.gm_update_visual,function(args)
  if closed or updating or S.weapon_error or not scarlet_gate.allow('weapon_update_visual') then return end
  local ok,e=pcall(function()
   local gm=sdk.to_managed_object(args[2]);local s=weapon_owner(gm);if not s or not s.visual_map then return end
   local want=family(s);if not want then return end
   local key=id(gm);local w=weapons[key]
   if not w then
    w={gm=keep(gm)}
    local original=gm:get_field('_VisualParamList')
    if not original then return end
    local n=call('visual_list_count',original);need(n>0 and n<=24,'Weapon visual subset bound')
    w.native_list=keep(original);w.scarlet_list=keep(sdk.create_instance(C.visual_list_type))
    call('visual_list_ctor',w.scarlet_list)
    for i=0,n-1 do
     local x=call('visual_list_item',original,i);local row=s.visual_map[id(x)]
     need(row,'Weapon visual subset contains an unmapped record')
     call('visual_list_add',w.scarlet_list,sdk.to_ptr(row.scarlet:get_address()))
     need(same(call('visual_list_item',w.scarlet_list,i),row.scarlet),'Weapon visual subset copy differs')
    end
    if managed(gm,'app.Gm800_000')then
     local base=gm:get_field('_BaseComponents');local holder=base and base:get_field('_AssetHolder')
     need(holder and same(call('component_go',holder),call('component_go',gm)),'Weapon parameter owner mismatch')
     w.holder=keep(holder);w.scarlet_aaa=keep(C.public_native and refs.scarlet_aaa or holder:get_field('_AaaUniqueParam'));need(managed(w.scarlet_aaa,C.aaa_type),'Katana parameter subtype differs')
    end
    weapons[key]=w
   end
   if w.family==want then return end
   local list=want=='native'and w.native_list or w.scarlet_list
   gm:set_field('_VisualParamList',list)
   need(same(gm:get_field('_VisualParamList'),list),'Weapon visual list cache readback differs')
   local value=gm:get_field('_VisualParam');local row=value and s.visual_map[id(value)]
   if not row then S.visual_record_unmapped=(S.visual_record_unmapped or 0)+1;return end
   local aaa
   if w.holder then
    aaa=want=='native'and refs.original_aaa or w.scarlet_aaa
    if not same(w.holder:get_field('_AaaUniqueParam'),aaa)then w.holder:set_field('_AaaUniqueParam',aaa);need(same(w.holder:get_field('_AaaUniqueParam'),aaa),'Weapon AAA cache readback differs')end
   end
   gm:set_field('_VisualParam',row[want])
   updating=true;local applied,why=pcall(call,'gm_setup_visual',gm,sdk.to_ptr(row[want]:get_address()));updating=false;need(applied,why)
   need(same(gm:get_field('_VisualParam'),row[want]),'Weapon visual cache readback differs')
   w.family=want;S.weapon_cache_routes=(S.weapon_cache_routes or 0)+1;event('weapon_cache',{owner=s.key,weapon=key,family=want,visual=id(row[want]),visual_list=id(list),visual_list_count=call('visual_list_count',list),aaa=id(aaa)})
  end)
  updating=false;if not ok then S.weapon_error=tostring(e);S.errors=S.errors+1 end
  return sdk.PreHookResult.CALL_ORIGINAL
 end,function(ret)return ret end)
  local function actor_ready()
   if type(actor_preflight)~='function' then return false,'actor_contract_preflight_missing' end
   local probe_ok,ready,reason=pcall(actor_preflight)
   if not probe_ok then return false,'actor_contract_missing:'..tostring(ready) end
   if ready~=true then return false,tostring(reason or 'actor_contract_missing') end
   return true
  end
 local self={};local last_output=0
 function self.step()
  if closed then return end
   local actor_ok,actor_reason=actor_ready()
   if not actor_ok then S.phase='blocked_actor_contract';S.blocked_reason=actor_reason;S.actor_contract_blocked_frames=(S.actor_contract_blocked_frames or 0)+1;if os.clock()-last_output>.25 then last_output=os.clock();json.dump_file('scarlet-driver-isolation-status.json',S,-1)end;return end
   S.blocked_reason=nil;if S.phase=='blocked_actor_contract' then S.phase='waiting' end
  local ok,why=pcall(function()
   local pm=call('pm',nil);if not pm then return end
   local info=call('info',pm);if not(info and call('info_valid',info))then return end
   if not load()then return end
   local root=call('info_go',info);local e=call('info_entity',info)
   if valid(root)and e then process(bind(root,'player',call('entity_supporter',e),e))end
   root=call('ui',pm)
   if valid(root)then
    local proc;for _,c in ipairs(components(root))do if managed(c,'app.PlayerUICharacter')then proc=c end end
    if proc then process(bind(root,'ui',proc,nil))end
   end
   for k,s in pairs(owners)do if not valid(s.root)then owners[k]=nil;S.owners[k]=nil end end
   S.phase=S.errors==0 and'active'or'failed'
  end)
  if not ok and S.error~=tostring(why)then S.error=tostring(why);S.errors=S.errors+1 end
  if os.clock()-last_output>.25 then last_output=os.clock();json.dump_file('scarlet-driver-isolation-status.json',S,-1)end
 end
 function self.pause()
  if closed then return end
  local all=true;for _,s in pairs(owners)do if s and not s.failed then local ok,why=pcall(function()custom_enabled(s,false);apply_banks(s,'native');apply_parameters(s,'native');s.family='native';s.target=nil;s.phase='ready'end);if not ok then all=false;S.restore_unresolved=true;S.last_restore_error=tostring(why)end end end
  if all then invalidate('manual gate disabled');S.restore_unresolved=false;S.phase='paused' else S.phase='restore_pending' end;return all
 end
 function self.status()return S end
 function self.can_run()
  if closed or not refs.ready or S.errors>0 then return false end
   local actor_ok,actor_reason=actor_ready();if not actor_ok then S.phase='blocked_actor_contract';S.blocked_reason=actor_reason;return false end;S.blocked_reason=nil;if S.phase=='blocked_actor_contract' then S.phase='waiting' end
  local found=false
  for _,s in pairs(owners)do if valid(s.root)then found=true;if s.phase~='ready'then return false end end end
  return found
 end
 function self.close()closed=true;S.closed=true end
 return self
end
return M

end)()
local IC=json.load_string([=[{"methods":[{"key":"pm","type":"ace.GAElement`1<app.PlayerManager>","name":"get_Instance","params":[],"returns":"app.PlayerManager","is_static":true,"rva":109939872},{"key":"info","type":"app.PlayerManager","name":"getControllingPlayer","params":[],"returns":"app.cPlayerManageInfo","is_static":false,"rva":77873440},{"key":"ui","type":"app.PlayerManager","name":"getControllingPlayerUI","params":[],"returns":"via.GameObject","is_static":false,"rva":111300480},{"key":"info_valid","type":"app.cPlayerManageInfo","name":"get_Valid","params":[],"returns":"System.Boolean","is_static":false,"rva":125839200},{"key":"info_go","type":"app.cPlayerManageInfo","name":"get_Object","params":[],"returns":"via.GameObject","is_static":false,"rva":86045520},{"key":"info_entity","type":"app.cPlayerManageInfo","name":"get_CharacterEntity","params":[],"returns":"app.cPlayerCharacterEntity","is_static":false,"rva":94387552},{"key":"go_valid","type":"via.GameObject","name":"get_Valid","params":[],"returns":"System.Boolean","is_static":false,"rva":94806192},{"key":"components","type":"via.GameObject","name":"get_Components","params":[],"returns":"via.Component[]","is_static":false,"rva":97957600},{"key":"transform","type":"via.GameObject","name":"get_Transform","params":[],"returns":"via.Transform","is_static":false,"rva":97957552},{"key":"component_go","type":"via.Component","name":"get_GameObject","params":[],"returns":"via.GameObject","is_static":false,"rva":94821856},{"key":"joints","type":"via.Transform","name":"get_Joints","params":[],"returns":"via.Joint[]","is_static":false,"rva":125571280},{"key":"resource_path","type":"via.ResourceHolder","name":"get_ResourcePath","params":[],"returns":"System.String","is_static":false,"rva":116635664},{"key":"skeleton_get","type":"via.motion.DummySkeleton","name":"get_SkeletonResourceHandle","params":[],"returns":"via.motion.SkeletonResourceHolder","is_static":false,"rva":113281056},{"key":"motion_bank","type":"via.motion.Motion","name":"get_MotionBankAsset","params":[],"returns":"via.motion.MotionBankResourceHolder","is_static":false,"rva":99055168},{"key":"dynamic_count","type":"via.motion.Motion","name":"getDynamicMotionBankCount","params":[],"returns":"System.Int32","is_static":false,"rva":99052928},{"key":"dynamic","type":"via.motion.Motion","name":"getDynamicMotionBank","params":["System.Int32"],"returns":"via.motion.DynamicMotionBank","is_static":false,"rva":99052896},{"key":"dynamic_bank","type":"via.motion.DynamicMotionBank","name":"get_MotionBank","params":[],"returns":"via.motion.MotionBankResourceHolder","is_static":false,"rva":106024848},{"key":"dynamic_list","type":"via.motion.DynamicMotionBank","name":"get_MotionList","params":[],"returns":"via.motion.MotionListResourceHolder","is_static":false,"rva":106025120},{"key":"array_length","type":"System.Array","name":"GetLength","params":["System.Int32"],"returns":"System.Int32","is_static":false,"rva":114447776,"hook_only":false},{"key":"array_value","type":"System.Array","name":"GetValue","params":["System.Int32"],"returns":"System.Object","is_static":false,"rva":114447856,"hook_only":false},{"key":"entity_supporter","type":"app.cPlayerCharacterEntity","name":"get_GameObjectSupporter","params":[],"returns":"app.cPlayerGameObjectSupporter","is_static":false,"rva":108612672,"hook_only":false},{"key":"player_part_go","type":"app.cPlayerGameObjectSupporter","name":"getGameObject","params":["app.cPlayerGameObjectSupporter.PLAYER_GAME_OBJECT"],"returns":"via.GameObject","is_static":false,"rva":3268272,"hook_only":false},{"key":"ui_part_go","type":"app.PlayerUICharacter","name":"getGameObject","params":["app.cPlayerGameObjectSupporter.PLAYER_GAME_OBJECT"],"returns":"via.GameObject","is_static":false,"rva":12137456,"hook_only":false},{"key":"part_object_type","type":"app.cPlayerGameObjectSupporter","name":"convertObjTypeToPartsType","params":["app.PlayerPartsDef.PARTS_TYPE"],"returns":"app.cPlayerGameObjectSupporter.PLAYER_GAME_OBJECT","is_static":true,"rva":11360992,"hook_only":false},{"key":"mesh_ready","type":"via.render.Mesh","name":"get_MeshReady","params":[],"returns":"System.Boolean","is_static":false,"rva":122191152,"hook_only":false},{"key":"mesh_holder","type":"via.render.Mesh","name":"getMesh","params":[],"returns":"via.render.MeshResourceHolder","is_static":false,"rva":122190144,"hook_only":false},{"key":"joint_base_p","type":"via.Joint","name":"get_BaseLocalPosition","params":[],"returns":"via.vec3","is_static":false,"rva":109360528,"mutates_native":false},{"key":"joints_constructed","type":"via.motion.Motion","name":"get_JointsConstructed","params":[],"returns":"System.Boolean","is_static":false,"rva":99057168},{"key":"skeleton_set","type":"via.motion.DummySkeleton","name":"set_SkeletonResourceHandle","params":["via.motion.SkeletonResourceHolder"],"returns":"System.Void","is_static":false,"rva":113281152},{"key":"motion_bank_set","type":"via.motion.Motion","name":"set_MotionBankAsset","params":["via.motion.MotionBankResourceHolder"],"returns":"System.Void","is_static":false,"rva":99055312},{"key":"motion_setup","type":"via.motion.Motion","name":"setupMotionBank","params":[],"returns":"System.Void","is_static":false,"rva":99054176},{"key":"dynamic_bank_set","type":"via.motion.DynamicMotionBank","name":"set_MotionBank","params":["via.motion.MotionBankResourceHolder"],"returns":"System.Void","is_static":false,"rva":106024992},{"key":"joint","type":"via.Transform","name":"getJointByName","params":["System.String"],"returns":"via.Joint","is_static":false,"rva":125569776},{"key":"chain_get","type":"via.motion.Chain2","name":"get_ChainAsset","params":[],"returns":"via.motion.Chain2ResourceHolder","is_static":false,"rva":123493856},{"key":"chain_set","type":"via.motion.Chain2","name":"set_ChainAsset","params":["via.motion.Chain2ResourceHolder"],"returns":"System.Void","is_static":false,"rva":123493952},{"key":"constraint_get","type":"via.motion.Constraint","name":"get_Enabled","params":[],"returns":"System.Boolean","is_static":false,"rva":94307760},{"key":"constraint_set","type":"via.motion.Constraint","name":"set_Enabled","params":["System.Boolean"],"returns":"System.Void","is_static":false,"rva":94307776},{"key":"layer_get","type":"via.motion.JointConstraintsLayerBase","name":"get_Enable","params":[],"returns":"System.Boolean","is_static":false,"rva":100274000},{"key":"layer_set","type":"via.motion.JointConstraintsLayerBase","name":"set_Enable","params":["System.Boolean"],"returns":"System.Void","is_static":false,"rva":100274016},{"key":"layer_asset","type":"via.motion.JointConstraintsLayerBase","name":"get_JointConstraintsAsset","params":[],"returns":"via.motion.JointConstraintsResourceHolder","is_static":false,"rva":100274064},{"key":"jc_count","type":"via.motion.JointConstraints","name":"getLayerCount","params":[],"returns":"System.Int32","is_static":false,"rva":94883808},{"key":"jc_layer","type":"via.motion.JointConstraints","name":"getLayer","params":["System.Int32"],"returns":"via.motion.JointConstraintsLayer","is_static":false,"rva":104877744},{"key":"parent","type":"via.Transform","name":"get_Parent","params":[],"returns":"via.Transform","is_static":false,"rva":125570976},{"key":"ui_update_weapon","type":"app.PlayerUICharacter","name":"updateWeapon","params":[],"returns":"System.Void","is_static":false,"rva":8311808},{"key":"entity_pack","type":"app.cPlayerCharacterEntity","name":"get_PlayerParamPack","params":[],"returns":"app.user_data.PlayerParamPack","is_static":false,"rva":108610928},{"key":"entity_sheath","type":"app.cPlayerCharacterEntity","name":"get_SheathHold","params":[],"returns":"app.mcLeftHandSheathHold","is_static":false,"rva":108613008},{"key":"sheath_cached","type":"app.mcLeftHandSheathHold","name":"get__SheathHoldParam","params":[],"returns":"app.user_data.SheathHoldParam","is_static":false,"rva":94490768},{"key":"sheath_set","type":"app.mcLeftHandSheathHold","name":"set__SheathHoldParam","params":["app.user_data.SheathHoldParam"],"returns":"System.Void","is_static":false,"rva":94761888},{"key":"sheath_init","type":"app.mcLeftHandSheathHold","name":"initParam","params":[],"returns":"System.Void","is_static":false,"rva":133662016},{"key":"weapon_owner","type":"app.Gm800","name":"get_OwnerCharacter","params":[],"returns":"app.CharacterBase","is_static":false,"rva":96043264},{"key":"child","type":"via.Transform","name":"get_Child","params":[],"returns":"via.Transform","is_static":false,"rva":94762288},{"key":"next","type":"via.Transform","name":"get_Next","params":[],"returns":"via.Transform","is_static":false,"rva":94384720},{"key":"gm_setup_visual","type":"app.Gm800","name":"setupAttachParam","params":["app.user_data.CharacterWeaponVisualParam.cVisualParam"],"returns":"System.Void","is_static":false,"rva":5638128},{"key":"gm_update_visual","type":"app.Gm800","name":"updateAttachParam","params":[],"returns":"System.Void","is_static":false,"rva":77549120},{"key":"visual_list_ctor","type":"System.Collections.Generic.List`1<app.user_data.CharacterWeaponVisualParam.cVisualParam>","name":".ctor","params":[],"returns":"System.Void","is_static":false,"rva":124111808},{"key":"visual_list_count","type":"System.Collections.Generic.List`1<app.user_data.CharacterWeaponVisualParam.cVisualParam>","name":"get_Count","params":[],"returns":"System.Int32","is_static":false,"rva":75389856},{"key":"visual_list_item","type":"System.Collections.Generic.List`1<app.user_data.CharacterWeaponVisualParam.cVisualParam>","name":"get_Item","params":["System.Int32"],"returns":"app.user_data.CharacterWeaponVisualParam.cVisualParam","is_static":false,"rva":992352},{"key":"visual_list_add","type":"System.Collections.Generic.List`1<app.user_data.CharacterWeaponVisualParam.cVisualParam>","name":"Add","params":["app.user_data.CharacterWeaponVisualParam.cVisualParam"],"returns":"System.Void","is_static":false,"rva":124110528},{"key":"active_bank_count","type":"via.motion.Motion","name":"getActiveMotionBankCount","params":[],"returns":"System.UInt32","is_static":false,"rva":99052720},{"key":"active_bank","type":"via.motion.Motion","name":"getActiveMotionBank","params":["System.UInt32"],"returns":"via.motion.MotionBank","is_static":false,"rva":99052704},{"key":"bank_id","type":"via.motion.MotionBank","name":"get_BankID","params":[],"returns":"System.UInt32","is_static":false,"rva":94310176},{"key":"bank_kind","type":"via.motion.MotionBank","name":"get_BankType","params":[],"returns":"System.UInt32","is_static":false,"rva":94348528},{"key":"bank_dynamic","type":"via.motion.MotionBank","name":"get_EnabledDynamicMotionListLoad","params":[],"returns":"System.Boolean","is_static":false,"rva":103682784},{"key":"bank_valid","type":"via.motion.MotionBank","name":"get_MotionListValid","params":[],"returns":"System.Boolean","is_static":false,"rva":103682800},{"key":"bank_load","type":"via.motion.MotionBank","name":"loadDynamicMotionList","params":[],"returns":"System.Boolean","is_static":false,"rva":103682384}],"crcs":{"ace.GAElement`1<app.PlayerManager>":437989116,"app.PlayerManager":346041440,"app.cPlayerManageInfo":3185740719,"via.GameObject":4065074914,"via.Component":1881844667,"via.Transform":1340992935,"via.ResourceHolder":1072471267,"via.motion.DummySkeleton":2062619527,"via.motion.Motion":1638522585,"via.motion.DynamicMotionBank":186405504,"System.Array":58605515,"app.cPlayerCharacterEntity":4067958465,"app.cPlayerGameObjectSupporter":1646483854,"app.PlayerUICharacter":2159145370,"via.render.Mesh":1829138609,"via.Joint":1272281384,"via.motion.Chain2":2132214968,"via.motion.Constraint":3990833109,"via.motion.JointConstraintsLayerBase":628620890,"via.motion.JointConstraints":3198816904,"app.mcLeftHandSheathHold":370816328,"app.Gm800":837792757,"System.Collections.Generic.List`1<app.user_data.CharacterWeaponVisualParam.cVisualParam>":3696520543,"via.motion.MotionBank":4114983487},"resources":[{"key":"original_rig","path":"art/model/character/ch0/ch001_00/90/ch001_00_90.fbxskel","type":"via.motion.FbxSkeletonResource","holder":"via.motion.FbxSkeletonResourceHolder"},{"key":"original_common","path":"motion/player/common/common.motbank","type":"via.motion.MotionBankResource","holder":"via.motion.MotionBankResourceHolder"},{"key":"original_designchange","path":"motion/player/designchange/designchange.motbank","type":"via.motion.MotionBankResource","holder":"via.motion.MotionBankResourceHolder"},{"key":"original_weapon","path":"motion/player/weapon/weapon.motbank","type":"via.motion.MotionBankResource","holder":"via.motion.MotionBankResourceHolder"},{"key":"original_visual","type":"app.user_data.CharacterWeaponVisualParam","path":"gamedesign/action/player/data/parampack/playerweaponvisualparam.user","user":true},{"key":"original_sheath","type":"app.user_data.SheathHoldParam","path":"gamedesign/action/player/data/parampack/motionparam/playersheathholdparam.user","user":true},{"key":"original_aaa","type":"app.user_data.Gm800AaaUniqueParam","path":"gamedesign/gimmick/gm800/gm800_000/gm800_000_aaauniqueparam.user","user":true},{"key":"original_chain_0","path":"Art/Model/Character/ch0/ch001_00/01/ch001_00_01.chain2","type":"via.motion.Chain2Resource","holder":"via.motion.Chain2ResourceHolder"},{"key":"original_chain_1","path":"Art/Model/Character/ch0/ch001_00/01/ch001_00_01_MantChange.chain2","type":"via.motion.Chain2Resource","holder":"via.motion.Chain2ResourceHolder"},{"key":"scarlet_rig","path":"mods/{id}/dynamic/rig.fbxskel","type":"via.motion.FbxSkeletonResource","holder":"via.motion.FbxSkeletonResourceHolder"},{"key":"scarlet_common","path":"mods/{id}/dynamic/scarlet_common.motbank","type":"via.motion.MotionBankResource","holder":"via.motion.MotionBankResourceHolder"},{"key":"scarlet_designchange","path":"mods/{id}/dynamic/scarlet_designchange.motbank","type":"via.motion.MotionBankResource","holder":"via.motion.MotionBankResourceHolder"},{"key":"scarlet_weapon","path":"mods/{id}/dynamic/scarlet_weapon.motbank","type":"via.motion.MotionBankResource","holder":"via.motion.MotionBankResourceHolder"},{"key":"scarlet_visual","type":"app.user_data.CharacterWeaponVisualParam","path":"mods/{id}/dynamic/scarlet_visual.user","user":true},{"key":"scarlet_sheath","type":"app.user_data.SheathHoldParam","path":"mods/{id}/dynamic/scarlet_sheath.user","user":true},{"key":"scarlet_aaa","type":"app.user_data.Gm800AaaUniqueParam","path":"mods/{id}/dynamic/scarlet_aaa.user","user":true},{"key":"scarlet_chain_0","path":"mods/{id}/dynamic/chain_0.chain2","type":"via.motion.Chain2Resource","holder":"via.motion.Chain2ResourceHolder"},{"key":"scarlet_chain_2","path":"mods/{id}/dynamic/chain_2.chain2","type":"via.motion.Chain2Resource","holder":"via.motion.Chain2ResourceHolder"}],"bind_checks":{"native":{"Hip":[0.0,0.0,0.0],"L_Forearm":[0.25999999046325684,0.0,0.0],"L_Hand":[0.2549999952316284,0.0,0.0],"L_Shin":[0.0,-0.029999999329447746,0.0],"R_Shin":[0.0,-0.029999999329447746,0.0]},"scarlet":{"Hip":[1.3569585455286415e-09,-0.03132559731602669,0.010525266639888287],"L_Forearm":[0.24381449818611145,-1.826248596792368e-09,-1.0006726003375377e-10],"L_Hand":[0.24387291073799133,4.032076617033198e-10,-1.0884120271725806e-09],"L_Shin":[2.1931592111418214e-20,-0.006000000052154064,4.0858376330729396e-21],"R_Shin":[-1.814959310385506e-20,-0.006000000052154064,5.979604637614875e-20]}},"fields":[{"key":"ui_visual","type":"app.PlayerUICharacter","name":"_WeaponVisualParam","returns":"app.user_data.CharacterWeaponVisualParam","offset":152}],"aaa_type":"app.user_data.Gm800AaaUniqueParam","ui_visual_field":"_WeaponVisualParam","visual_list_type":"System.Collections.Generic.List`1<app.user_data.CharacterWeaponVisualParam.cVisualParam>","joint_counts":{"native":93,"scarlet":264},"chain_map":{"mods/{id}/dynamic/chain_0.chain2":"original_chain_0","mods/{id}/dynamic/chain_2.chain2":"original_chain_1"},"scarlet_rig":"mods/{id}/dynamic/rig.fbxskel","native_rig":"art/model/character/ch0/ch001_00/90/ch001_00_90.fbxskel","scarlet_banks":{"player":"mods/{id}/dynamic/scarlet_common.motbank","ui":"mods/{id}/dynamic/scarlet_designchange.motbank"},"scarlet_weapon":"mods/{id}/dynamic/scarlet_weapon.motbank","original_weapon":"motion/player/weapon/weapon.motbank","scarlet_bodies":{"mods/scarlet_hat_static/6516e70211991f0b/body_mesh_2de4180b65dbe6b20a.mesh":true,"mods/scarlet_no_hat_static/67cc2ab84782dc5b/body_mesh_ae4e361f60ab521537.mesh":true},"public_native":true,"chain_pairs":{"mods/{id}/dynamic/chain_0.chain2":{"scarlet":"scarlet_chain_0","native":"original_chain_0"},"art/model/character/ch0/ch001_00/01/ch001_00_01.chain2":{"scarlet":"scarlet_chain_0","native":"original_chain_0"},"mods/{id}/dynamic/chain_2.chain2":{"scarlet":"scarlet_chain_2","native":"original_chain_1"},"art/model/character/ch0/ch001_00/01/ch001_00_01_mantchange.chain2":{"scarlet":"scarlet_chain_2","native":"original_chain_1"}},"scarlet_root_constraints_enabled":true}]=])
local actor_preflight_last=-1;local actor_preflight_next=0;local actor_preflight_ready=false;local actor_preflight_reason='actor_contract_preflight_missing'
local function actor_preflight()local frame=adapter.frame();if type(frame)~='number'or frame<0 then actor_preflight_ready=false;actor_preflight_reason='actor_contract_missing:invalid frame';return false,actor_preflight_reason end;if actor_preflight_last>=0 and frame<actor_preflight_last then actor_preflight_next=0;actor_preflight_ready=false end;actor_preflight_last=frame;if frame<actor_preflight_next then return actor_preflight_ready,actor_preflight_reason end;actor_preflight_next=frame+15;local probe_ok,ready,detail=pcall(function()local contexts=adapter.resolve_all(frame,true);if type(contexts)~='table'then return false,'actor_contract_missing:resolve_all returned invalid contexts'end;for _,ctx in ipairs(contexts)do if ctx and ctx.kind=='player'and adapter.current_owner_context(ctx)==true then return true,nil end end;return false,'actor_contract_missing:player actor context absent'end);if probe_ok and ready==true then actor_preflight_ready=true;actor_preflight_reason=nil;return true end;actor_preflight_ready=false;if probe_ok then actor_preflight_reason=tostring(detail or 'actor_contract_missing:player actor context absent')else actor_preflight_reason='actor_contract_missing:'..tostring(ready)end;return false,actor_preflight_reason end
scarlet_gate.set_actor_preflight(actor_preflight)
local ok,isolation=pcall(Isolation.new,IC,sdk,function()if adapter then adapter.invalidate('manual gate disabled')end;if controller then controller:retry()end end,actor_preflight)
scarlet_gate.on_disable(function()if ok and isolation and isolation.pause then local ok2,result=pcall(isolation.pause);return ok2 and result~=false end;return true end)
isolation_can_run=function()return scarlet_gate.allow('isolation_can_run') and ok and isolation.can_run()end
re.on_pre_application_entry('UpdateMotion',function()if not scarlet_gate.allow('UpdateMotion') then return end;if ok then isolation.step()else json.dump_file('scarlet-driver-isolation-status.json',{error=tostring(isolation)},-1)end end)
re.on_script_reset(function()scarlet_reset_required=true;scarlet_reset_reason='script_reset_requires_restart';end)
end
