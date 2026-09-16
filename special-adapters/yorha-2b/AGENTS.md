# YoRHa 2B skeleton adapter guide

## Purpose

This directory contains an opt in, test only actor skeleton bridge for the
two converted 2B wardrobe IDs. It is separate from the shared wardrobe core
and from the general mod converter. The bridge changes one owned
`via.motion.DummySkeleton.SkeletonResourceHandle` on the controlling player;
it does not change equipment, saves, game files, or the original MOD loader.

## Key Files

| File | Purpose |
| --- | --- |
| `src/yorha_2b_skeleton_adapter.lua` | Real REFramework game thread adapter and restore guarded state machine |
| `manifest/yorha-2b-skeleton-manifest.json` | Exact IDs, catalog/PFB routes, BODY mesh paths, private rig paths and hashes |
| `native-api-contract.json` | Checked SDK type/method signatures and the evidence source for the actor binding |
| `README-zh-CN.md` | Installation, test procedure, stop conditions and current limitations |
| `tools/build_companion.py` | Builds a small companion ZIP by copying the audited source rig twice |
| `tools/validate_companion.py` | Offline ZIP/path/FBXSKEL/package format validator |
| `tests/test_state_machine.py` | Offline lifecycle and package validation regression tests |

## Dependencies

- REFramework Lua `sdk` and `re` APIs supplied by the user's current OWOTS
  runtime.
- The new OWOTS appearance bridge, preferably
  `_G.owots_appearance_lab.get_adapter_snapshot()`; the adapter keeps a
  compatibility fallback to the older Scarlet-named alias.
- The two existing 2B static wardrobe packages. The companion ZIP contains
  only the adapter, metadata, README, and two 8.6 KiB rig copies; it does not
  duplicate the static package or game installation.
- Development tests use Python `lupa` (Lua execution) and `luaparser` (syntax
  parsing); these are test-only dependencies and are not runtime/package
  prerequisites.

## For AI Agents

- Keep the exact route and actor gates. Do not generalize this adapter to
  arbitrary body IDs or arbitrary PFBs.
- All native calls and the single skeleton setter run from the
  `UpdateMotion` game-thread callback. Never use fixed object addresses or
  invoke the original loader.
- The adapter starts in read-only `diagnostic` mode. The small ImGui checkbox
  or `set_mode("apply")` only changes a scalar flag; holder writes remain
  queued for `UpdateMotion`. `status()` returns cached scalar paths and
  positions so UI/reset callers never invoke managed getters.
- Component/joint arrays are pinned only while synchronously traversed and
  their entries are not retained across frames. Diagnostic JSON is throttled
  to state changes/about 60 frames while safety checks remain per-frame.
- Before releasing a lease, re-read the current holder. If the private holder
  is still installed, reassert the original holder and wait for a new Motion
  baseline; release pins only after the original holder and baseline are both
  verified.
- Entering restoration clears the menu-pause presentation state; a paused
  snapshot never bypasses a restore wait or its bounded timeout.
- The adapter fails closed for missing/ambiguous routes, busy transitions,
  actor/supporter changes, unexpected current holders, wrong joint topology,
  failed Motion reconstruction, and unresolved restoration. A quarantined
  lease must retain its references and cannot be restarted automatically.
- A `script_reset` callback can run after the game-thread callback has stopped;
  it marks restoration unverified and requires a full game restart. LuaState
  garbage collection may release the old holder references, so a script reload
  is not treated as recovery.
- Do not claim runtime success from the offline tests. The package remains an
  unverified candidate until a controlled in-game A/B records the holder path,
  joint count, Motion state, and visible proportions.
