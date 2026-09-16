# Scarlet adapter guide

## Key Files

| File | Purpose |
| --- | --- |
| `src/Scarlet.Adapter.csproj` | Standalone .NET 10 managed adapter library |
| `src/ScarletContracts.cs` | Selection gate, host bridge and immutable status contracts |
| `src/ScarletResourceManifest.cs` | Private path policy and dynamic dependency inventory |
| `src/ScarletPose.cs` | Coherent cloth and hip-clearance math migrated from the audited contract |
| `src/ScarletWardrobeAdapter.cs` | Game-thread lifecycle state machine and bounded stage orchestration |
| `tests/Program.cs` | Offline fake-host regression suite and JSON report writer |
| `tests/Scarlet.Adapter.Tests.csproj` | Standalone .NET 10 offline test project |
| `README-zh-CN.md` | Integration, installation and real-game acceptance procedure |
| `MIGRATION.md` | Original behavior mapping and explicit limits |
| `tools/derive_lua.py` | Reproducibly derives the gated Lua candidate from the audited source without executing it |
| `src/scarlet_gate.lua` | Exact wardrobe bridge gate, identity lease and restore quarantine |
| `src/scarlet_manual_adapter.lua` | Generated manual migration candidate with native stage/cloth/weapon/sheath hooks |
| `manifest/runtime-path-map.json` | Full per-variant source-to-private target route and digest map |
| `manifest/actor-contract.json` | Exact actor/body joint, stage, component and whole-player evidence contract |
| `manifest/scarlet-dynamic-dependencies.json` | Audited dependency and body-variant metadata |

## Dependencies

- .NET 10 SDK for the managed library and offline tests.
- A host supplied by the existing OWOTS runtime is required for native calls, resource holders and game-thread callbacks.
- No game assets, original MOD files, Lua scripts or DLLs are dependencies of this source package.
- `manifest/runtime-path-map.json` and `manifest/actor-contract.json` are audit metadata; they must not be treated as a license to copy or replace the global player PFB.

## For AI Agents

- The adapter is enabled only by the exact IDs `scarlet_hat_static` and `scarlet_no_hat_static`. A native body ID is a validation signal, never a synthetic wardrobe identity.
- The host must verify catalog rows and the selected PFB before binding, and must keep the private resource lease until owned writes are restored.
- All native calls must run from the host's game-thread callback. The adapter does not use fixed RVAs or invoke the original Scarlet scripts.
- `re.on_script_reset` is scalar-only and reports `restart_required`; it must not call `close()`, native getters/setters, or restore handlers from a UI/render thread. Render-side gate denials queue recovery; only the known game-thread callback may call `scarlet_gate.flush_restore()`.
- The game-thread flush has restore handlers for private parts, Prop leases, sheath release, and dynamic isolation. The actor preflight `read_only` flag must propagate through every resolver decorator so render/UI probes cannot retire native source leases.
- Missing dynamic companions, invalid baseline evidence or an unresolved owner transition produce a bounded degraded/stop state; do not silently claim behavior equivalence.
- The static wardrobe package does not provide Scarlet's appended whole-player actor components. Keep the adapter disabled until a separately verified private/existing actor contract supplies the 264/577 skeleton and 11 role components; never globally replace `player.pfb.18`.
- The actor contract also remains blocked by the unresolved Scarlet v10/game v12 `via.dynamics.Ragdoll` layout and unimplemented creation of the 110 appended instances; do not treat the two named setting types as the complete migration.
