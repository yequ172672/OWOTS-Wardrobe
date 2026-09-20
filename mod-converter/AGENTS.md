# MOD Converter Agent Guide

## Purpose

`mod-converter` is the portable offline normal-MOD to OWOTS wardrobe-MOD
converter. It is a source-only tool directory: game installs, source MODs,
and test extracts remain outside it.

## Key files

| File | Purpose |
| --- | --- |
| `mod_converter.py` | Standard-library CLI, safe KPKA reader, dependency graph, FBXSKEL v1 validation and schema 4 publisher |
| `texture_resolution.py` | Pure-Python TEX251111100 structure inspection and conservative streaming-to-base promotion |
| `converter_gui.py` | Minimal Tk/TkinterDnD2 player UI: directories, drop zone, result list; worker-thread queue and off-screen self-test |
| `batch_converter.py` | Container/layer ownership, graph-proven native candidates, multi-entry registration, declared attachments, shared game reference, atomic batch publication and resource ledger |
| `appearance_duplicates.py` | Content fingerprints and registration deduplication, stock normal/HQ contexts, covered-target evidence and attachment-aware grouping |
| `rsz_paths.py` | Equal-size PFB18/USER3 path spans with full unchanged-outside-paths byte proof; no class-layout serialization |
| `mesh_probe.py` | Conservative all-LOD OWOTS geometry/placeholder check; uncertainty always preserves authored meshes |
| `input_containers.py` | Bounded asset-only ZIP/RAR/7z expansion with cancellation, traversal/link/duplicate checks |
| `prepare_archive_tools.py` | Hash-pinned official 7-Zip reader staging for common solid RAR archives |
| `convert_mod.cmd` | Prompted launcher for players with Python 3 |
| `game_pak_reference.py` | Read-only original Steam PAK index and on-demand dependency provider |
| `README.md` | Player instructions and conversion boundaries |
| `AI-START.md` | Standalone drag-to-chat entrypoint for local or assisted AI conversion |
| `requirements.txt` | Source GUI/archive dependencies plus optional PAK Zstandard reader |
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

* Python 3.10+ standard library; TkinterDnD2 0.6.3, py7zr 1.1.3, rarfile 4.5; pinned official 7-Zip 26.03 binaries in `runtime/7zip`. `zstandard` is required only when a source
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

* The player GUI uses `BatchConverter`, not the legacy one-plan CLI. Default UI
  contains only game/output directories, drop/file/folder input and results.
  Show reasons only for actual problems; do not expose PFB selectors, developer
  commentary, CRC overrides or implementation diagrams. `--cli` remains supported.
  One drop accepts multiple files/folders. Preserve queue append while busy,
  active-input deduplication and failure isolation between inputs; GUI self-test
  covers a mixed batch, a failed input and another drop during processing.
* `build_release.py --output` selects a fresh build-intermediate directory. Final
  ZIP and per-archive checksum default to the project's Git-ignored `release/`;
  only explicit `--release-dir` changes the distribution destination.
* Batch `output_root` / `--output` is optional. None means each input's own parent,
  including folders; never use cwd or the extracted archive's temporary directory.
  Publish `name-衣橱.zip` with natives/reframework/reports at archive root, preserve
  the directory's full name, and number collisions without overwriting. Pack and
  CRC-read in cancellable chunks inside private staging, then atomically publish
  the completed ZIP; Result.output is the ZIP path. The GUI opens its parent.
  Legacy single-plan CLI and Pack helper still accept/output loose directories.
* Batch mode reads source assets only. Never parse modinfo, descriptions, scripts
  or document contents. Distinct natives/stm roots and nested containers are
  independent layers. Record omitted behavior/assets and every output registration.
* Follow PFB -> USER/MDF -> TEX dependencies in the mod-over-original graph to
  recognize texture-only edits. Original unmodified leaf references stay original;
  their bytes are not unnecessarily read/copied. A texture streaming-only edit
  makes the base node private and retains the input streaming companion.
* Schema 4 `rules.equip` references separately registered visible cloak/gauntlet
  entries. Publish body and attachments in one atomic package and verify references.
  For shared accessory meshes, prefer a unique attachment from the same native
  character family, including covered targets of merged accessories; report real ambiguity.
  BODY/HEAD/HAIR can share a body registration; weapons group by exact native ID.
* Normal categories now publish schema 4 (the wardrobe no longer reads schema 2/3).
  Transform (`category: transform`, `roots` ONI_BODY/ONI_HEAD) recognition and
  publication is still pending: until it lands, a MOD that replaces Oni resources
  converts only its normal categories and the Oni assets are reported as unconsumed.
* Deduplicate within each source asset layer after part grouping and before publication.
  Compare complete mesh bytes, MDF properties/slots and effective base/streaming
  textures, auxiliary resources, opaque PFB fields, supplied parts, hides and equip
  outcomes. Paths/names/native IDs alone are not appearance identity. Accessories
  deduplicate first; body matching must retain distinct companion choices.
  Normal/HQ wrapper equivalence requires an original PFB shape match, including
  object/type/reference tables and opaque fields. Only stock skill-row paths,
  unreferenced string-pool leftovers and proven empty renderer pairs are context
  differences. Unknown wrapper changes use strict content comparison; uncertainty
  preserves entries. An unchanged native family's normal/AC/HQ contexts with the
  no additional authored resources remain one override, recorded with a separate
  evidence method. Additional authored appearances must survive.
  Record coveredTargets, duplicateEvidence and duplicate-appearance/representedBy
  ledger rows; merged inputs are not unrecognized assets. Do not rewrite gameplay
  skill data, merge across independent input layers or change runtime equip rules.
* Batch PFB/ordinary USER edits use only bounded resource-table and length-prefixed
  inline UTF-16 spans with equal-size private paths. Re-inventory output and prove
  all bytes outside edits identical. Never change CRCs, offsets, object indices or
  unknown fields. Catalog row selection still uses strict AppearanceRsz readback;
  do not automatically enable its CRC override. Short paths/layout uncertainty block.
* Placeholder hiding requires a BODY owner and a wholly hidden accessory part:
  verify every authored mesh, every main LOD, shadow references, index bounds and
  tiny geometry against the exact original. Morphs/streams/uncertainty preserve
  authored meshes. Do not use file size or bone count as hiding evidence.
* Header-only MDF hiding uses `mod_converter.is_empty_mdf`: exact 16-byte MDF header,
  version 1, zero materials, known flags 0/1. This is a leaf with no dependencies,
  not permission to relax the nonempty MDF parser. A stock PFB graph whose entire
  reachable material set is authored zero-material MDF may declare the part hidden
  with a BODY owner. Mixed/custom graphs preserve the MDF bytes and original mesh
  references. Fingerprints retain the empty MDF content. Failed authored HEAD/HAIR
  scans block publication (`HEAD_REPLACEMENT_INCOMPLETE`) instead of dropping parts.
* Common static mods are the compatibility target. A rotation-only mismatch in
  one unreferenced 93-joint rig automatically selects the documented BODY
  mesh-rest contract (user instruction 2026-09-18). Retain name/order, parent,
  symmetry, scale and segment-scaling checks. Report every excluded rig and the
  fallback; do not import unverified rig positions/rotations or override /90.
  Expanded topology and scripted behavior remain outside the static workflow.
* The following single-plan flags and native matching notes describe the retained
  legacy CLI; they are not controls in the player GUI.

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
* `inspect` reports `stats.nativePartCandidates` so a front end can offer an
  explicit picker, preferring the `normal` variant and keeping the alternate
  (HQ) count per part; `NATIVE_PART_CANDIDATE_AMBIGUOUS` warns during inspect
  when one part genuinely has several variants. `convert` still selects from
  that same index (`_native_index_records`/`_source_part_stems`/
  `_native_index_matches` are the shared, cached matchers).
* `--prune-unreachable` is the explicit "publish only what the selected parts
  reach" opt-in. Every excluded input becomes a reported
  `PRUNED_UNREACHABLE_RESOURCE` carrying a verifiable reason: byte-identical to
  a published resource (`sameContentAs`), a native part from the bundled index,
  an unreachable standalone rig with its mesh-embedded-rest fallback, or an
  explicit "no reachable owner". The default stays fail-closed, and dynamic
  Lua/DLL files are still governed by `--experimental-static-only`.
* A `body` entry derives `rules.hideParts` from the bundled
  `runtime/owots_body_rules.json` (`IsVisibleCloak`, `IsInvisibleHead`) for the
  selected BODY native id; a part the entry publishes is never hidden. The
  report records the derivation and `--no-body-rule-hides` restores the old
  behaviour. `UNCONSUMED_MOD_RESOURCE` details must stay classified
  (`sameContentAs` / `nativePart` / `no reachable owner`), never the legacy
  "add a part or choose a variant" wording.
* AppearanceRsz failures are classified by `AppearanceWorker.failure_code` into
  `RSZ_TEMPLATE_LAYOUT_MISMATCH` and `RSZ_TEMPLATE_CRC_OVERRIDE_REQUIRED` (each
  naming its documented next step) or the generic `CONVERSION_BLOCKED`;
  `ConversionError.code` is what `run()` writes into the report. Never encode an
  actionable cause only in a raw stderr tail.
* The GUI stays a thin front end over the batch service. Its worker receives
  captured Paths and plain data only, never Tk variables. `gui_self_test()` is the release
  gate and must exercise every new control, including releasing widget
  references when a `Toplevel` closes.
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
* The interface language is auto-detected through `mod_converter.T(zh, en)`.
  The player GUI has no advanced "auto" combo. Module scope
  must be side-effect free beyond defining those constants, so no name may
  appear in its own initializer. `build_release.py` runs the frozen EXE with
  `--self-test` and fails the build when the window cannot be constructed; never
  ship a windowed EXE whose startup path was not exercised.
