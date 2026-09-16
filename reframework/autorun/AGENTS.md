# Wardrobe runtime Lua

## Status

The runtime Lua controller (`owots_wardrobe_skeleton.lua`) and the offline rebase
prototype (`owots_skeleton_rebase.lua`) were **retired on 2026-09-16**. The
independent skeleton is now a single implementation inside the wardrobe plugin
(`reframework/plugins/source/OWOTSAppearanceLab.cs`, `MotionRebase()` on the
`UpdateMotion` callback). Do not reintroduce a second Lua writer.

## Key Files
| File | Purpose |
| --- | --- |
| `yorha_2b_skeleton_adapter.lua` | Inert retirement marker installed over the earlier per-MOD companion with backup |
| `AGENTS.md` | Directory boundary |

## For AI Agents
- The adopted mechanism: keep the root `/90` skeleton stock; on `UpdateMotion`, set each changed root joint to `rootRest + (bodyRest - rootRest)`, where the delta comes from the equipped BODY part's `get_BaseLocalPosition`. Restore writes `rootRest`. See `_validation/owots-joint-rebase-probe-20260916/mechanism-findings.md`.
- The write **must** run on `UpdateMotion`; identical writes on `UpdateBehavior` stored and read back but had no visual effect.
- The enable switch lives in the wardrobe settings (`preferences.json`, `WardrobePreferences.IndependentSkeleton`). Never add a second config or a REF overlay toggle.
- `get_LocalPosition` returns the stored rest/offset, not the animated local; use it for readback, not to judge the rendered pose.
- No resource creation, no holder, no native skeleton rebuild. The retired `DummySkeleton` swap crashed at `setupJointGroup` (PID 66060) and stays unreachable.
- The wardrobe plugin's hot-reload preparation restores the rebase synchronously on the game thread; it no longer reads a Lua status file.
