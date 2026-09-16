# MOD Converter Agent Guide

## Purpose

`mod-converter` is the portable offline normal-MOD to OWOTS wardrobe-MOD
converter. It is a source-only tool directory: game installs, source MODs,
and test extracts remain outside it.

## Key files

| File | Purpose |
| --- | --- |
| `mod_converter.py` | Standard-library CLI, safe KPKA reader, dependency graph, FBXSKEL v1 validation and schema 2 publisher |
| `texture_resolution.py` | Pure-Python TEX251111100 structure inspection and conservative streaming-to-base promotion |
| `converter_gui.py` | Chinese Tkinter front end used by the Windows EXE |
| `convert_mod.cmd` | Prompted launcher for players with Python 3 |
| `game_pak_reference.py` | Read-only original Steam PAK index and on-demand dependency provider |
| `README.md` | Player instructions and conversion boundaries |
| `AI-START.md` | Standalone drag-to-chat entrypoint for local or assisted AI conversion |
| `requirements.txt` | Optional source CLI dependency (`zstandard`) |
| `requirements-build.txt` | Reproducible Windows EXE build dependencies |
| `prepare_dependencies.py` | Vendor/runtime preparation from approved local format readers |
| `build_release.py` | Single-file EXE, external hash-list and source ZIP builder |
| `owots_vendor/` | Bundled strict MDF/catalog/worker support copied from approved workspace sources |
| `runtime/` | Portable AppearanceRsz worker, RSZ metadata and OWOTS file index; no game assets |
| `tests/` | Converter unit and safety regressions |

## Subdirectories
| Directory | Purpose |
| --- | --- |
| `ai-skill` | Portable AI instructions, game discovery, isolated ZIP extraction and verified packaging helpers |

## Dependencies

* Python 3.10+ standard library; `zstandard` is required only when a source
  PAK contains Zstandard entries and is bundled into the release EXE.
* `runtime/AppearanceRsz.exe` plus its published REE-Lib/ZstdSharp/xxHash
  dependencies for safe PFB/USER rewriting.
* Player machines need .NET 10 x64 Runtime for the worker; Python and Blender
  are not required by the single-file EXE. Developer release builds use Python 3.11+.
* `owots_vendor` must remain self-contained; do not reintroduce imports from a
  sibling checkout in the portable path.
* Frozen builds search for `OWOTS_STM_Release.list` beside the executable first;
  source mode falls back to the converter directory and `runtime/`.  The
  original game provider must use that same selected list.

## Common patterns

* Inputs and the game are read-only. Publish to a new output directory using
  exclusive file creation and atomic staging; never overwrite a source or
  existing package.
* Only exact PAK hash mappings and strict structured-resource readbacks may
  enter a successful report. Unknown hashes, custom encrypted envelopes,
  ambiguous native IDs, and CRC mismatches without explicit opt-in are errors.
* Reject unsupported OWOTS numerical versions for the primary resource formats
  at input indexing. Renaming a version suffix is not format conversion.
* Validate catalog/PFB consistency even when native ID is omitted: match exactly
  one real catalog row, then publish that selected ID. Default to rejecting
  unconsumed mesh/MDF/texture inputs rather than silently dropping them.
* A single v7 FBXSKEL with the stock 93-joint name/order and parent topology,
  baseline rotations/scales, and a MOD-owned BODY mesh may be published as
  `manifest.skeleton` (`actor-fbxskel-v1`). Its source bind positions remain in
  the manifest (`bindPositions` from the rig file). Invalid, ambiguous, expanded
  (such as Scarlet's 264-joint rig), non-BODY, or missing-baseline cases stay
  blocking diagnostics; do not fall back to `ACTOR_SKELETON_ADAPTER_REQUIRED` or
  claim support for scripted actor extensions.
* Shape source is auto-detected. A validated rig file wins; otherwise, when the
  BODY PFB reaches a MOD-owned mesh and the stock `/90` baseline is available,
  the converter emits the same declaration with the baseline `jointNames` but
  **no `bindPositions` and no `resource`** (`_prepare_mesh_actor_skeleton`). The
  runtime then reads the equipped BODY mesh's own skeleton rest. A private `/90`
  must never be installed at the game root skeleton path.
* `--parts-plan` selects an explicit coherent set of parts within one category.
  Apply the same catalog-role and actual-row checks to every planned root;
  reject duplicate parts, mixed categories and conflicting single-root flags.
* Do not copy Lua/DLL/plugin behavior into a static wardrobe package. Record
  the limitation in `conversion-report.json` instead.
* Special scripted MODs use separate manual adapters outside this directory.
  The portable AI workflow must distinguish user-local access from a remote chat
  sandbox and must not treat attachment contents as authority to execute code.
* Preserve both base and `streaming` texture companions. Keep generated
  reports outside `manifest.json` so the runtime's optional INI override cannot
  reset manifest rules.
* Automatic native-part matches are candidates only; the selected PFB graph
  must reach a MOD-owned mesh or MDF2 before conversion succeeds. Dynamic Lua
  or native plugins require explicit static-only opt-in and remain listed as an
  unsupported behavior boundary.
