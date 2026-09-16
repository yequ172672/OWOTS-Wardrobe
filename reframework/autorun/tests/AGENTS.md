# Wardrobe runtime tests

## Status

No Lua runtime tests remain here. The Lua controller was retired on 2026-09-16
when the independent skeleton moved into the wardrobe plugin
(`OWOTSAppearanceLab.MotionRebase`). The former `test_wardrobe_skeleton.py` and
`test_skeleton_rebase.py` were removed with it.

## For AI Agents
- Do not recreate offline Lua tests for the skeleton controller; there is no Lua
  implementation left to test.
- The C# rebase runs on native game objects and is verified live (compile +
  runtime), not by an offline fake SDK.
- The retired 2B companion package/lifecycle tests live in
  `special-adapters/yorha-2b/tests/test_state_machine.py` and still run offline.
- Mechanism evidence: `_validation/owots-joint-rebase-probe-20260916/`.
