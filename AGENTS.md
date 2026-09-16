# OWOTS Wardrobe system repository

Standalone repository for the Onimusha WotS (OWOTS) wardrobe/appearance system and
the loose/PAK mod converter. Split out of the sibling `re-engine-mcp-CN` MCP
repository on 2026-09-16 so the MCP checkout stays upstream-focused.

## Subdirectories
| Directory | Purpose |
| --- | --- |
| `appearance-core` | Manifest registry, four-category composition, save/sidecar logic, preferences and the lab bundler (`build_lab.py`) |
| `reframework` | In-game wardrobe plugin source (`plugins/source/OWOTSAppearanceLab.cs`) and the inert 2B retirement marker (`autorun/`) |
| `mod-converter` | Standalone loose/PAK appearance converter and diagnostic reports |
| `release-tools` | Reproducible OWOTS test-release packaging, install, verify and rollback helpers |
| `special-adapters` | Dedicated scripted-MOD migrations (Scarlet, YoRHa 2B) kept separate from the converter |

## Key Files
| File | Purpose |
| --- | --- |
| `OWOTS_INDEPENDENT_SKELETON.md` | Manifest-driven independent actor skeleton contract, conversion scope and manual acceptance |
| `OWOTS_APPEARANCE_*` / `OWOTS_WARDROBE_*` | Appearance system requirements, runtime research, UI/save research, user guide and export plan |
| `appearance-core/build_lab.py` | Bundles the tested core into the single-source plugin (`reframework/plugins/source/OWOTSAppearanceLab.cs`) |

## Dependencies
- .NET 10 SDK/runtime (appearance core, plugin compile at game runtime); Python 3 for the converter and the lab bundler; CMake/Visual Studio only for the sibling native REFramework branch.
- Blender 5.2 is the adaptation and acceptance baseline for Mesh/asset work.
- Game data at `D:\gametest\steamapps\common\OnimushaWotS` stays read-only; never bundle game assets or saves in source releases.

## For AI Agents
- Independent skeleton is a single implementation in the plugin: `OWOTSAppearanceLab.MotionRebase` on `[Callback(typeof(LateUpdateBehavior), CallbackType.Post)]`. Keep the root `/90` stock and set `rootRest + (rest - rootRest)` on the changed root joints, where `rest` is the manifest `bindPositions` when declared, otherwise the equipped BODY mesh's `get_BaseLocalPosition`. The write must run on this late phase; `UpdateMotion`/`UpdateBehavior` writes were overwritten during normal gameplay. Never create a resource, hold a holder, or call the retired `DummySkeleton` swap.
- The enable switch is `WardrobePreferences.IndependentSkeleton` in the wardrobe settings; the runtime Lua controller was retired (no second writer, no second config).
- A mod's private `/90` fbxskel must never be installed at the game root skeleton path; keep it in the private mod directory (unused) or drop it.
- Deploy `build_lab.py` output, never the unbundled lab source. Release outputs belong under workspace `_validation`, not this repository.
- Converter/skeleton evidence lives in workspace `_validation/` (e.g. `owots-joint-rebase-probe-20260916`, `wardrobe-hotreload-20260916`), outside this repo.
- Sync this file and subdirectory AGENTS.md files on structural changes.
