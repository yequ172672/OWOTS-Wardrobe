# Appearance core

## Key Files
| File | Purpose |
| --- | --- |
| `Appearance.Core.csproj` | Plain .NET library with no REFramework dependency |
| `AppearanceRegistry.cs` | Manifest parsing, deterministic conflict handling and independent cosmetic choices |
| `WardrobeComposition.cs` | Four-category requested/effective composition and hide/conflict planning used by the runtime adapter |
| `WardrobeManifest.cs` | Strict schema 2 logical category/resource/rule parser with optional skeleton metadata; does not migrate v1 or imply native hide support |
| `WardrobeSkeleton.cs` | Strict optional schema 1 actor-fbxskel declaration with 93-joint metadata and immutable snapshots |
| `WardrobeRegistry.cs` | Combined v1/v2 registry; read-only legacy category projection, stable IDs and whole-package conflict rejection |
| `WardrobeSelectionState.cs` | Four-category choice references and per-category legacy intent retention used by native apply and sidecar snapshots |
| `WardrobeSaveStore.cs` | V2 sidecar storage, immutable state snapshots, read-only v1 migration and original-content backup before first v2 write |
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
- New INI candidate: ReadDirectory merges sibling modinfo.ini common metadata and wardrobe.<category> declarations over generated schema 2 asset manifests. Preserve v1 and manifests without INI. Duplicate keys/sections or mismatched IDs reject the package; reading never writes the author file. Core tests and runtime-reference compilation pass; candidate bundle 41bd81bd86143b59fafb62d67ae4a6c48b0e8e7841bac9968fa568a6c7e701d4 was installed after verified game exit; live startup/INI override acceptance is pending.
- Latest source uses WardrobeSaveStore and generic snapshot transactions in the lab, including v1 read migration and v2 combination restoration. The installed bundle (SHA256 7450e0cf2c462ad8e130ec5bdcca3c4d3e1269d9b3195604f6ac1ae2f079c936, verified 2026-09-15) includes this integration. The newer read-only wardrobe_status candidate is uninstalled. Unit filesystem checks and compiler success do not prove native v2 save/load acceptance.
- AppearanceSaveTransactions<T> shares verified native preparation/completion semantics for immutable snapshots; its legacy wrapper preserves existing callers. V2 writes must pass WardrobeSaveStore.Freeze and use the native verified key. V1 read migration never writes; first v2 publication preserves a content-addressed v1 backup. The lab uses native callbacks and UI snapshots; actual four-category save/load acceptance remains pending.
- Force confirmation resolves all blocking declarations, verifies the exact current list, and does not start native mutation before approval. Visibility-off clears that category's grants but retains its selection. Changing a declaring entry revokes its prior grants, including when the user later selects that entry again. Core tests cover these semantics; the native UI contains confirmation handling, but exhaustive live override/revocation acceptance remains pending.
- build_lab.py now includes the v2 manifest, optional WardrobeSkeleton metadata, registry, composition and selection-state modules. Installed wardrobe_select consumes them through a native apply state machine; UI uses four-category snapshots and the writer uses WardrobeSaveStore v2. Never persist synthetic runtime.wardrobe group IDs as user selections.
- Legacy save choices become per-category bundle references, not guessed entry IDs. Missing bundles retain all intent; manually cancelling cloak clears only that category, so reinstall can restore body/gauntlet independently. Never persist the resolved/effective composition instead of requested references.
- Cloak/gauntlet visibility-off overrides author rules and confirmed force grants, preserving requested IDs. Force grants are scoped to category plus declaring MOD ID; never blanket-ignore all author rules. Runtime/UI/sidecar integration exists; pure tests do not establish every live scene transition.
- WardrobeComposition preserves requested IDs including missing/suppressed entries; only active rules affect lower-priority categories. Incompatibility hides native fallback too. Any reported provided/hidden collision must block application until resolved. Migration and four-category save/UI adapters exist. Native hide has observed successes and an unresolved intermittent CG restoration; full live acceptance is separate.
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
