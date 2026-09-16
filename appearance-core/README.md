# Appearance manifest core

This library reads MOD identities and logical resource references without loading game assets. The in-game lab uses the same parser for `registry_list`, `registry_select` and its REFramework menu. Building this project alone does not install the in-game plugin.

Current milestone prioritizes core appearance switching and UI, followed by scene lifecycle and save-associated restoration. Dedicated weapon attribute research and registration are deferred optional work. Cosmetic selection still must not write native equipment or attribute values; numeric damage/guard behavior has not been independently verified.


## Current four-category contract (2026-09-15)

New Mesh authoring exports schema 2. BODY, CLOAK, GAUNTLET and WEAPON categories have independent stable IDs; weapon cosmetics do not own native weapon attributes. Example:

```json
{"schemaVersion":2,"id":"author.body","name":"Body","category":"body",
 "parts":[{"part":"BODY","catalog":"mods/author.body/body.user","prefab":"mods/author.body/body.pfb"}],
 "rules":{"hideParts":["HEAD","HAIR"],"incompatibleCategories":["cloak","gauntlet"]}}
```

BODY entries may also declare an optional `skeleton` object with
`schemaVersion: 1` and `kind: "actor-fbxskel-v1"`. Its `resource` and
`bodyMesh` must remain under `mods/<manifest-id>/` and use unversioned
`.fbxskel`/`.mesh` paths. `jointNames` and `bindPositions` must describe the
same ordered 93-joint set with finite three-component positions. The
`baselineResource` is fixed to
`art/model/character/ch0/ch001_00/90/ch001_00_90.fbxskel`. The core parser
validates this declaration and returns it in read-only snapshots; it does not
open binary skeletons, retarget bones or prove native compatibility.

Use `wardrobe_registry` and `wardrobe_select` (`category`, `modId`) for schema 2. Accessory visibility uses `wardrobe_visibility` (`category`, `visible`). If force is required, the response identifies declaring MOD IDs; only the exact confirmed declarations can authorize that choice. The UI provides this confirmation. Titles can hide cloak/gauntlet while retaining requested selections. Resolve effective state separately from requested intent; persist the latter.

`registry_list/select/clear` are legacy two-group tools. In four-category mode their active IDs may be synthetic `runtime.wardrobe.*` groups and cannot reconstruct original selections. The new `wardrobe_status` read-only endpoint has compiled but is not installed yet. Do not invoke it against the current bundle expecting it to exist.

The installed bundle SHA256 is `7450e0cf2c462ad8e130ec5bdcca3c4d3e1269d9b3195604f6ac1ae2f079c936` (checked on disk 2026-09-15). It contains the four-category apply/UI and v2 sidecar writer/reader. Historical slot 4 user acceptance covered the earlier two-group restore; it is not proof of every v2 visibility/force/missing-MOD combination. The intermittent CG hidden-part reappearance remains unresolved and was deferred by the user. Native menu registration/four-category synchronization remains incomplete; do not enable the legacy sync alongside four-category selection.

Mesh authoring has real Blender evidence for independent resource export, unchanged repeat, preserved source baselines, category-state save/reopen, cross-category related-part import and cross-scene reference isolation. The generated gauntlet PFB has live `ready/valid` preload evidence, not equipped visual/animation acceptance. Optional default part imports are verified separately from a complete outfit assembly. Refer to the Mesh authoring guide for remaining custom-resource and full-assembly limitations.

## Legacy API and historical verification

Legacy schema 1 MOD folders contain `manifest.json` (new authoring exports schema 2 below):

```json
{
  "schemaVersion": 1,
  "id": "author.outfit_a",
  "name": "服装 A",
  "kind": "outfit",
  "description": "服装说明，可省略。",
  "author": "作者名",
  "icon": "preview.png",
  "parts": [
    {
      "part": "BODY",
      "catalog": "mods/author/outfit_a/body_catalog.user",
      "prefab": "mods/author/outfit_a/body.pfb"
    }
  ]
}
```

`kind` is `outfit` or `weapon`. Outfit parts are BODY, BODY_SUB, HEAD, HAIR, GAUNTLET and CLOAK. Weapon parts are WEAPON, SHEATH, WEAPON_SUB, SHEATH_SUB and BOW. A manifest lists the parts it supplies; icons, scripts and attributes are not required. Catalog and prefab paths are logical engine paths without numeric file-version suffixes. A catalog can contain multiple entries; the adapter must select the exact declared prefab path rather than the first item.

IDs are normalized to lowercase and used for selection, independently of display names. All definitions sharing an ID are rejected, with a diagnostic for each file. A malformed manifest does not hide unrelated valid entries. Resource and optional skeleton metadata checks do not open binary assets; the runtime adapter remains responsible for resource loading, missing-resource errors, native catalog collisions and any runtime actor compatibility.

Optional `description`, `author` and `icon` are supported by the installed wardrobe. Icons are relative PNG/JPEG paths within the manifest folder, e.g. `preview.png` or `images/preview.jpg`; do not use game logical paths, absolute paths or `..`. The native decoder accepts files up to 4 MiB and dimensions up to 2048 × 2048, then downsizes to a longest edge of 256 pixels for its atlas. Missing, corrupt or rejected images use a text placeholder without preventing appearance selection. The same image supplies the card and detail preview; no 3D preview is required. Existing manifests need no changes. A default manager image has not been chosen.

`AppearanceChoices` holds independent outfit and weapon choices. It deliberately contains no actual weapon identity or attribute values: those remain owned by the game. `weaponAttributes` is reserved; a non-null payload currently reports unsupported functionality instead of falsely claiming to register attributes. Future attribute support must follow the precedence in the requirements document.

`NativeCostumeSelections` tracks explicit native confirmations separately from closing the native menu, which always applies its current settings. The opt-in runtime candidate queues category cancellation only after an explicit confirmation is applied. This is one synchronization direction; native MOD rows, names and previews remain unfinished.

Run core regressions:

```powershell
dotnet run --project appearance-core/tests/Appearance.Core.Tests.csproj
```

An optional path argument also parses a real manifest fixture. These tests cover manifest/selection semantics and sidecar file behavior, not native switching, visuals, weapon damage or actual game-save isolation. Actual game evidence is recorded separately in the handoff and UI/save research documents.

`AppearanceSaveStore` provides a private sidecar format containing only separate outfit/weapon MOD IDs. Its explicit key combines user index, slot and nonzero native UniqueID. Current-build slots are 1–20 and 101. Writes flush a temporary file then publish it by same-directory rename. Reads reject mismatched embedded keys, unsupported schemas and malformed records; missing records are distinct from corrupt records. MOD IDs are kept even when their manifest is unavailable, allowing a future adapter to display a missing-MOD warning without erasing the choice.

The lab has an experimental `appearance_persistence` command with `enabled: true/false` (omitting enabled reads status) and `automaticRestore: true/false`. It captures request-time identities and choices, commits successful writes on the game update callback, and stores private records under its data directory's `saves` folder. Automatic restoration is connected to verified successful loads. Startup settings come from `preferences.json`, with persistence and automatic restore off when unset. Native save files are not modified by this component; neither core tests nor one live success prove power-loss durability or all scene/load sequences.

`AppearanceSaveTransactions` separates preparation from disk-write completion. Prepared writes use the earlier snapshot even if the selected appearance changes meanwhile; preparation, failed/cancelled attempts and duplicate completions do not commit. The adapter recognizes the observed manual and automatic branches, skips unverified flag combinations, and skips fresh snapshots during appearance transitions or unresolved restoration. Prepared saves without a captured preparation report an error rather than guessing. Actual writes were verified for manual slot 4 and automatic slot 101. On 2026-09-15 the user also confirmed automatic restoration of both groups from slot 4; an earlier timeout remains documented rather than erased by that successful retest.

`AppearanceRestorePlan.Create` resolves the stored outfit and weapon independently against the installed registry. Missing/rejected or wrong-kind entries fall back to native for that group with a structured warning; the other valid group remains available. The original stored IDs remain intact so reinstall can recover the selection. Tests cover missing outfit plus valid weapon, wrong-kind weapon plus valid outfit, explicit native choices and reinstall. Native application and resource-load failures still belong to the runtime adapter.

`UnavailableAppearanceIntent` retains missing IDs in subsequent saves of the same user/playthrough, including a different slot. Explicit selection or cancellation forgets retained intent for that category; an active valid choice wins. A new successful load resets the context. This prevents an automatic native fallback from silently erasing a temporarily uninstalled MOD. The installed adapter includes this logic; managed regressions pass, while missing-MOD/reinstall live acceptance remains outstanding.

`AppearanceLoadCoordinator` tickets distinguish separate reads of the same slot. Starting a new load invalidates earlier queued restoration and observed identity; late or duplicate completions cannot replace the newest load. The installed runtime checks the ticket before advancing restoration, after allowing an in-flight native step to settle. Managed regressions cover supersession; repeated live-load acceptance remains separate. `AppearanceOperationClock` excludes observed menu pause intervals from automatic restoration's active-time budget.

Generate the deployable lab source from the repository root:

```powershell
python appearance-core/build_lab.py --output ../_validation/owots-appearance-lab/OWOTSAppearanceLab.cs
```

REFramework compiles each source plugin separately. Install this generated file as `reframework/plugins/source/OWOTSAppearanceLab.cs`; the unbundled source cannot resolve the shared registry by itself. Before replacing an active lab, clear its selection and wait for native restoration, then clear again to unregister resources. Keep a backup of the installed plugin.

The generic `deploy_plugin.py` installer excludes the unbundled lab. For a new symlink installation, explicitly pass `--appearance-bundle <generated-file>`; existing real files are preserved by the installer's refusal to overwrite them. Current labs support `registry_clear` to completion before deployment; older builds need the two-step clear described above. Do not deploy during a live CG acceptance test.

Place manifests at `reframework/data/owots_appearance_lab/mods/<folder>/manifest.json`. `registry_list` reports valid entries and per-file errors. `registry_select` accepts `modId` and matches each declared prefab exactly. Runtime IDs are temporary session allocations; they must not be used as persistent MOD identity.

Selection restores the previous appearance in the requested category, waits for its resources to become unused, then loads the requested entry in one asynchronous request. Outfit and weapon choices coexist. `registry_list` exposes separate `outfit` and `weapon` IDs. `registry_clear` accepts `kind: "outfit"` or `kind: "weapon"` to restore only that category; omitting kind clears both. Loading resources are tracked separately from active resources so a preload failure does not free another group's assets.

Invalid or unknown manifests are rejected before clearing the current choice. This transition can briefly display the category's native appearance; if new resources fail to load after restoration, that category remains native, without automatic rollback to its previous MOD. Restoration times out after 8 seconds while retaining old resources for a later clear retry. Paused gameplay may prevent restoration from progressing. Coexistence, cancellation in both directions, weapon switching and failed weapon preload isolation have been runtime-tested with private controls. Weapon attributes are outside the current objective. Save integration exists; full scene lifecycle acceptance remains unfinished.

The independent ImGui wardrobe opens with Slash (`/ ?`) by default, with optional F6–F12 bindings in settings. It supports card/list modes, search, image/details, separate applied-state labels and per-category restoration. Single click changes the preview focus; double click or the apply button queues selection. Settings contain refresh, persistence and restore retry. Rendering reads immutable CLR snapshots; it never invokes native switching on the render thread. The user confirmed V2 functionality and reported a card highlight alignment bug; its geometry fix was subsequently confirmed by the user. Native costume-menu integration remains separate and is currently blocked by the game's locked menu.
