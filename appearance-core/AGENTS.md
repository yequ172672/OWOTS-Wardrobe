# Appearance core

## Key Files
| File | Purpose |
| --- | --- |
| `Appearance.Core.csproj` | Plain .NET library with no REFramework dependency |
| `AppearanceRegistry.cs` | Manifest parsing, deterministic conflict handling and independent cosmetic choices |
| `WardrobeComposition.cs` | Normal four-category composition/hide/conflict planning plus the separate transform domain (resident roots, in-domain targets, R4 solver: selection or game-native) |
| `WardrobeManifest.cs` | Strict schema 4 parser: `parts` for normal categories, `roots` for `transform`, optional skeleton metadata |
| `WardrobeSkeleton.cs` | Strict optional schema 1 actor-fbxskel declaration with 93-joint metadata and immutable snapshots |
| `WardrobeRegistry.cs` | Schema 4 registry with stable IDs and whole-package conflict rejection; older schemas are reported for re-conversion, never read |
| `WardrobeSelectionState.cs` | Five-category intent, transform switch, body-declared accessory defaults, reversible sources and later manual overrides used by apply/save |
| `WardrobeTransform.cs` | Expectation/snapshot separation: locks one transform plan per transformation, reports later changes as pending for the next one |
| `WardrobeSaveStore.cs` | Schema 4 sidecar storage with immutable state snapshots; older versions are reported for a rebuild and preserved as a content-addressed backup before the first schema 4 write |
| `NativeCostumeSelections.cs` | Explicit native menu confirmation tracking, separate from unconditional close/apply |
| `WardrobePreferences.cs` | Versioned hotkey/view/feature preferences with validated atomic publication |
| `AppearanceOperationClock.cs` | Active-time clock that excludes menu pause and pause transition intervals |
| `AppearanceSaveStore.cs` | Versioned sidecar records, save transactions, restoration planning and missing-MOD intent retention |
| `README.md` | Current schema and integration boundaries |
| `build_lab.py` | Bundles the shared registry source into the single-source REFramework lab plugin |

## Subdirectories
| Directory | Purpose |
| --- | --- |
| `tests` | Executable semantic regressions; optional real fixture parsing |

## Dependencies
- .NET 10 SDK and runtime; no third-party packages.

## For AI Agents
- `rules.equip` (body only) references separately registered cloak/gauntlet IDs. `Choose` applies defaults once per explicit body wear; subsequent manual accessory choices override them. Body cancel/change restores only untouched defaults. `Resolve` never re-imposes defaults during polling/load; absent bodies stop imposing defaults without erasing saved intent, while missing required accessories set `IncompleteDeclaredEquipment` so native apply preserves the previous complete outfit.
- Schema 4 is the only read format. `WardrobeRegistry` reports older manifests for re-conversion and `WardrobeSaveStore` reports older sidecars for a rebuild; neither migrates nor deletes them, and the first schema 4 write preserves the old file as `<name>.legacy-vN.<sha256>.bak`. Runtime copies must preserve `Equipment`, `TransformEnabled` and the transform request.
- ReadDirectory merges sibling modinfo.ini common metadata and `wardrobe.<category>` declarations over generated schema 4 manifests. `hide_head`/`hide_hair` replace `rules.hideParts` for that package, `incompatible_cloak`/`incompatible_gauntlet` replace `rules.incompatibleCategories`, `transform_keep` sets the body keep rule, and undeclared fields keep their manifest value (never a wholesale rules replacement). Duplicate keys/sections or mismatched IDs reject the package; reading never writes the author file.
- AppearanceSaveTransactions<T> shares verified native preparation/completion semantics for immutable snapshots; its legacy wrapper preserves existing callers. Schema 4 writes must pass WardrobeSaveStore.Freeze and use the native verified key. The lab uses native callbacks and UI snapshots; actual save/load acceptance remains pending.
- Force confirmation resolves all blocking declarations, verifies the exact current list, and does not start native mutation before approval. Visibility-off clears that category's grants but retains its selection. Changing a declaring entry revokes its prior grants, including when the user later selects that entry again. Core tests cover these semantics; the native UI contains confirmation handling, but exhaustive live override/revocation acceptance remains pending.
- build_lab.py includes the schema 4 manifest, WardrobeSkeleton, registry, composition, selection-state, transform-snapshot and sidecar modules. The lab consumes them through the native apply state machine; the transform category only updates the saved expectation and the fifth-category UI until P0 validates the resident lifecycle. Never persist synthetic runtime.wardrobe group IDs as user selections.
- Transform is its own domain: `ResolveTransform` solves the R4 rule (explicit selection -> that entry; otherwise the game's own Oni appearance). There is no switch and no keep-normal policy (user decision v0.3); the wardrobe only changes the transformation appearance. `WardrobeTransformSnapshotStore.Lock` freezes one plan per transformation; later changes only report `IsPending`. A missing or wrong-category transform entry falls back to the native appearance with an issue and keeps the saved intent. Never merge transform hidden targets into the normal-state hidden set.
- Cloak/gauntlet visibility-off overrides author rules and confirmed force grants, preserving requested IDs. Force grants are scoped to category plus declaring MOD ID; never blanket-ignore all author rules. Runtime/UI/sidecar integration exists; pure tests do not establish every live scene transition.
- WardrobeComposition preserves requested IDs including missing/suppressed entries; only active rules affect lower-priority categories. Incompatibility hides native fallback too. Any reported provided/hidden collision must block application until resolved. Native hide has observed successes and an unresolved intermittent CG restoration; full live acceptance is separate.
- WardrobeSkeleton is an optional strict declaration for same-topology actor metadata: validate its exact 93-name order and, when present, finite bind positions and path ownership. `bindPositions` and `resource` are now **optional**: absent `bindPositions` means the runtime reads the equipped body mesh's own skeleton rest; `resource` (a private `/90`) is accepted for compatibility but never used at the game root. Do not load binary skeletons, retarget bones or infer broader native compatibility from this metadata.
- No actual weapon stats or identity snapshots belong in the cosmetic choices object.
- AppearanceEntry carries optional description/author and manifest-relative PNG/JPEG icon metadata. Missing or invalid optional icons fall back to null without rejecting otherwise usable parts. Parsing does not load images; the renderer must enforce file/resource ownership separately.
- Preserve missing optional metadata support, ID conflict diagnostics and independent outfit/weapon choices.
- The lab uses this parser through generated bundled source. Deploy build_lab.py output, never the unbundled lab source. Unit tests do not prove runtime switching or saving; consult runtime evidence separately.
- build_lab.py embeds both registry and sidecar sources. Sidecar storage accepts an explicit verified key, never infers the loaded slot or serializes native stats. The adapter must establish event/identity semantics and scene readiness before using records for restoration. Missing records and invalid records have distinct results; missing MOD IDs remain stored for reinstall.
- The bundler writes UTF-8 bytes directly so its printed SHA256 matches the on-disk artifact on Windows as well as LF platforms. Older printed hashes described LF-normalized source while Windows write_text produced CRLF bytes; use actual file hashes when comparing historical installations.
- AppearanceRestorePlan resolves each saved group separately against the registry, returns structured warnings, and never rewrites saved intent. Runtime resource failures and scene readiness remain adapter responsibilities; plan success is not native restoration success.
- AppearanceSaveTransactions separates Prepare, WritePrepared and WriteCurrent attempts. Completion yields a record only for successful disk-write phases; prepared snapshots survive UI changes, and late preparation completions cannot replace newer snapshots. The adapter must classify native flags and success correctly; this coordinator does not prove a disk write by itself.
- UnavailableAppearanceIntent preserves missing MOD IDs across automatic native fallback saves. Explicit user changes forget only the affected category; valid active choices take precedence. The adapter scopes retention to the observed user/playthrough identity and resets it after a new successful load. Installed v2 selection state retains requested intent; full missing-MOD/reinstall live acceptance remains pending.
- AppearanceLoadCoordinator invalidates queued and active tickets on every new load, including same-key reloads. Only the latest started load may publish identity; failed/new pending loads cannot reuse earlier identity. Runtime adapters must finish in-flight native operations safely before dropping a stale job; this coordinator does not own native resources.
- NativeCostumeSelections maps native category 0 to weapon, 1/2/3 to outfit and excludes NPC categories. Only explicit confirmation marks a group; native apply consumes it once, close/disable/load clear scope. Do not equate this ledger with native UI row registration or confirmed runtime behavior.
- WardrobePreferences also carries `IndependentSkeleton` (default true): the wardrobe settings checkbox is the authoritative enable switch for the independent-skeleton feature; the lab publishes it in the adapter snapshot as `independentSkeleton`. Keep it a UI preference, never per-save appearance state.
- WardrobePreferences validates supported keyboard bindings and restore/persistence dependency before publishing. Missing file uses safe defaults; corrupt/unknown files report errors. This is UI configuration, not per-save appearance state; never merge the two files.
- WardrobePreferences also carries `UiCharacterSync` (default true), the authoritative switch for mirroring the active MOD onto the menu/main-menu character. Older preference files without the member adopt the enabled default; the core regression covers that compatibility.
- AppearanceOperationClock returns excluded time so an automatic restoration's nested native deadlines can be extended consistently. It does not pause the game. Real pause state comes from the adapter; tests do not establish the original timeout's cause.
