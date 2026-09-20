# Core regressions

## Key Files
| File | Purpose |
| --- | --- |
| `Appearance.Core.Tests.csproj` | Console regression executable referencing the real core library |
| `Program.cs` | Registry/choice semantics plus real temporary-file sidecar round-trip, key isolation and corruption rejection |
| `WardrobeCompositionTests.cs` | Normal four-category suppression/fallback/restoration plus transform domain isolation, the selection/native rule and invalid root/target rejection |
| `WardrobeRegistryTests.cs` | Schema 4 parsing, transform roots, older-version re-conversion reporting, INI overlay and whole-package conflict isolation |
| `WardrobeTransformTests.cs` | Expectation/snapshot isolation, next-lock adoption and pending reporting |
| `WardrobeSkeletonTests.cs` | Optional 93-joint metadata, private paths, immutable snapshots, malformed rejection and schema 4 compatibility |
| `WardrobeEquipTests.cs` | Separate accessory registration, declared wear, manual overrides, body cancellation/rewear, missing dependencies and saved restoration |

## Dependencies
- Parent Appearance.Core project and .NET 10; no test framework packages.

## For AI Agents
- Keep regression coverage tied to user behavior, and distinguish fixture parsing from native game acceptance.
- Sidecar regressions cover schema 4 round-trip (including `TransformEnabled` and the transform request), legacy-version rebuild reporting with a preserved backup, wrong embedded identity, corruption and incomplete-state rejection. Older sidecars are never read as the new format.
- Transform regressions cover domain isolation (transform hiding never enters the normal hidden set and vice versa), the selection/native rule, missing/wrong-category fallback to native and expectation/snapshot isolation. They do not claim live Oni resident behavior.
- Restoration-plan tests cover per-group missing/wrong-kind fallback and reinstall from unchanged saved intent; they do not claim actual scene restoration.
- Save transaction regressions cover no commit during preparation, successful prepared-snapshot reuse after choice changes, failure/cancel rejection, duplicate completion, cross-slot isolation and late preparation order.
- Missing-intent regressions cover saving native fallback without erasing the missing ID, independent category changes, active-choice precedence and explicit native cancellation. These are managed semantics tests, not live save/load acceptance.
- Load coordinator regressions cover invalidation on new load, same-key reload distinction, late and duplicate completion rejection, missing successful identity and explicit restore retry. Native transition cancellation is not exercised by these tests.
- Presentation metadata checks preserve description/author/icon, legacy manifests, and usable appearances with invalid optional icon paths. No image decoding or rendering is covered.
- Native-menu ledger tests cover no-op close, NPC exclusion, per-group and combined confirmation, duplicate apply consumption and reused menu identity. Actual callbacks are not simulated by this managed test.
- Preference tests use a separate temporary settings directory, covering restart round-trip, invalid-write preservation and corruption reporting. Keep their files out of sidecar key-isolation test enumeration.
- Restore-clock tests cover long pause, resumption and backward time readings. They do not simulate native model loading or prove why an earlier in-game restore timed out.
