using System.Text.Json;
using OWOTS.Appearance;

static string Manifest(string id, string kind = "outfit", string part = "BODY", string name = "同名外观") =>
    JsonSerializer.Serialize(new { schemaVersion = 1, id, name, kind,
        parts = new[] { new { part, catalog = "mods/author/item/catalog.user", prefab = "mods/author/item/model.pfb" } } });
static RegistrySnapshot Build(params (string Source, string Json)[] files) =>
    AppearanceRegistry.Build(files.Select(file => (file.Source, (Func<string>)(() => file.Json))));
static void Require(bool condition, string message) { if (!condition) throw new Exception(message); }

var valid = Build(("a", Manifest("author.a")), ("b", Manifest("author.b")),
    ("sword", Manifest("author.sword", "weapon", "WEAPON")));
Require(valid.Entries.Count == 3 && valid.Issues.Count == 0, "Distinct IDs with identical display names must coexist");
var metadata = AppearanceRegistry.Parse(Manifest("author.metadata").Replace("\"parts\":", "\"description\":\"说明 100%\",\"author\":\"作者\",\"icon\":\"images/icon.png\",\"parts\":"), "metadata");
Require(metadata.Description == "说明 100%" && metadata.Author == "作者" && metadata.Icon == "images/icon.png",
    "Optional presentation metadata did not survive parsing");
var invalidIcon = AppearanceRegistry.Parse(Manifest("author.noicon").Replace("\"parts\":", "\"icon\":\"../outside.png\",\"parts\":"), "noicon");
Require(invalidIcon.Icon == null && invalidIcon.Parts.Count == 1, "Invalid optional icon blocked the usable appearance");
Require(valid.Entries["author.a"].Description == "" && valid.Entries["author.a"].Icon == null,
    "Legacy manifests must remain usable without presentation metadata");
var choices = new AppearanceChoices();
var operationClock = new AppearanceOperationClock(1000);
Require(operationClock.Advance(1250, false) == 0 && operationClock.ActiveMilliseconds == 250, "Active waiting time not counted");
Require(operationClock.Advance(125000, true) == 123750 && operationClock.ActiveMilliseconds == 250,
    "A long pause consumed the restoration deadline");
operationClock.Advance(125250, false);
Require(operationClock.ActiveMilliseconds == 250, "Resume boundary charged unknown paused time");
operationClock.Advance(125500, false);
Require(operationClock.ActiveMilliseconds == 500, "Restoration clock failed to resume");
operationClock.Advance(100, false);
Require(operationClock.ActiveMilliseconds == 500, "Backward clock reading changed elapsed work");
Console.WriteLine("PASS: restoration clock survives long pause, resumes and rejects backward elapsed time");
var nativeMenu = new NativeCostumeSelections();
nativeMenu.Open(1);
Require(nativeMenu.ConsumeApplied(1) == 0, "Closing a merely opened menu cleared MOD appearances");
Require(!nativeMenu.Confirm(1, 4) && nativeMenu.ConsumeApplied(1) == 0, "NPC choice cleared player appearances");
Require(nativeMenu.Confirm(1, 0) && nativeMenu.ConsumeApplied(1) == NativeCostumeSelections.Weapon,
    "Native sword confirmation did not isolate weapon appearance");
Require(nativeMenu.ConsumeApplied(1) == 0, "Repeated application replayed consumed confirmation");
nativeMenu.Confirm(1, 3);
nativeMenu.Confirm(1, 2);
Require(nativeMenu.ConsumeApplied(1) == NativeCostumeSelections.Outfit, "Native outfit categories affected weapon group");
nativeMenu.Confirm(1, 0);
nativeMenu.Confirm(1, 1);
Require(nativeMenu.ConsumeApplied(1) == 3, "Two explicitly confirmed groups were not retained");
nativeMenu.Close(1);
Require(!nativeMenu.Confirm(1, 0), "Stale callback outside an opened menu was accepted");
nativeMenu.Open(1);
Require(nativeMenu.ConsumeApplied(1) == 0, "Reused native menu identity retained prior choices");
Console.WriteLine("PASS: native menu confirmation isolation, no-op close, NPC exclusion and duplicate consumption");
choices.Choose(AppearanceKind.Weapon, "author.sword", valid);
choices.Choose(AppearanceKind.Outfit, "author.a", valid);
choices.Choose(AppearanceKind.Outfit, "author.b", valid);
Require(choices.Outfit == "author.b" && choices.Weapon == "author.sword", "Outfit switch cleared weapon choice");
choices.Choose(AppearanceKind.Outfit, null, valid);
Require(choices.Outfit == null && choices.Weapon == "author.sword", "Outfit cancellation cleared weapon choice");
var duplicate = Build(("a", Manifest("AUTHOR.A")), ("b", Manifest("author.a")), ("c", Manifest("author.c")));
Require(duplicate.Entries.Count == 1 && duplicate.Entries.ContainsKey("author.c") && duplicate.Issues.Count == 2,
    "Conflicting IDs must both be rejected while unrelated entries survive");
var malformed = Build(("bad", "{"), ("wrong-kind", Manifest("author.wrong", "weapon", "BODY")),
    ("bad-path", Manifest("author.path").Replace("mods/author/item/catalog.user", "../catalog.user")),
    ("valid", Manifest("author.valid")));
Require(malformed.Entries.Count == 1 && malformed.Issues.Count == 3, "One invalid manifest must not hide valid entries");
try { choices.Choose(AppearanceKind.Weapon, "author.a", valid); throw new Exception("Expected kind mismatch"); }
catch (InvalidOperationException) { }
Require(choices.Weapon == "author.sword", "Failed selection changed active choice");
var unavailable = new SavedAppearance("author.missing", "author.sword");
var restore = AppearanceRestorePlan.Create(unavailable, valid);
Require(restore.Available == new SavedAppearance(null, "author.sword") && restore.Issues.Count == 1 &&
    restore.Issues[0].Kind == AppearanceKind.Outfit, "Missing outfit blocked a valid weapon restoration");
Require(unavailable.Outfit == "author.missing", "Resolution erased the saved missing MOD identity");
var retained = new UnavailableAppearanceIntent(restore);
Require(retained.ForSave(restore.Available) == unavailable, "Saving native fallback erased an unavailable MOD");
retained.Forget(AppearanceKind.Weapon);
Require(retained.ForSave(new SavedAppearance(null, null)) == new SavedAppearance("author.missing", null),
    "Changing the other category erased retained outfit intent");
Require(retained.ForSave(new SavedAppearance("author.a", null)).Outfit == "author.a", "Retained missing ID overrode a new active choice");
retained.Forget(AppearanceKind.Outfit);
Require(retained.ForSave(new SavedAppearance(null, null)) == new SavedAppearance(null, null),
    "Explicit native choice failed to clear retained missing ID");
var reinstalled = Build(("outfit", Manifest("author.missing")), ("weapon", Manifest("author.sword", "weapon", "WEAPON")));
Require(AppearanceRestorePlan.Create(unavailable, reinstalled).Available == unavailable,
    "Reinstalled MOD could not recover from the unchanged saved choice");
var wrongKind = AppearanceRestorePlan.Create(new SavedAppearance("author.a", "author.b"), valid);
Require(wrongKind.Available == new SavedAppearance("author.a", null) && wrongKind.Issues.Count == 1,
    "Wrong-kind weapon prevented outfit restoration or was accepted as a weapon");
Require(AppearanceRestorePlan.Create(new SavedAppearance(null, null), valid).Issues.Count == 0,
    "Explicit native appearances should not produce missing-MOD warnings");
Console.WriteLine("PASS: restore plans isolate unavailable/wrong-kind groups and preserve intent for reinstall");
var temporary = Path.Combine(Path.GetTempPath(), "owots-appearance-tests-" + Guid.NewGuid().ToString("N"));
var transactions = new AppearanceSaveTransactions();
var saveKey = new AppearanceSaveKey(0, 101, 7);
var loads = new AppearanceLoadCoordinator();
loads.Begin(1);
Require(loads.Complete(1, saveKey, true), "Successful load was not published");
var oldLoad = loads.TakePending()!;
Require(loads.IsCurrent(oldLoad), "New restore ticket is already stale");
loads.Begin(2);
Require(!loads.IsCurrent(oldLoad) && loads.Observed == null && !loads.HasPending,
    "Starting another load retained the previous restoration");
Require(!loads.Complete(1, saveKey, true), "Late old completion replaced the newest load");
Require(loads.Complete(2, saveKey, true), "Repeated load of the same slot was rejected");
var newLoad = loads.TakePending()!;
Require(newLoad != oldLoad && loads.IsCurrent(newLoad) && !loads.IsCurrent(oldLoad),
    "Same-slot reload reused the old restoration ticket");
Require(!loads.Complete(2, saveKey, true), "Duplicate load completion queued another restore");
loads.Begin(3);
Require(!loads.HasPending && loads.Observed == null, "Failed/cancelled load can fall back to an earlier ticket");
loads.Complete(3, saveKey, false);
Require(!loads.HasPending && loads.QueueObserved().Key == saveKey, "Manual restore retry lost observed identity");
loads.ClearPending();
Require(!loads.HasPending && loads.Observed != null, "Clearing queued work erased verified identity");
Console.WriteLine("PASS: load supersession, same-slot reload, late/duplicate completion and explicit retry");
var appearanceA = new SavedAppearance("author.a", "author.sword");
var appearanceB = new SavedAppearance("author.b", null);
Require(transactions.Begin(1, saveKey, appearanceA, AppearanceSavePhase.Prepare), "Preparation rejected");
Require(transactions.Complete(1, true) == null, "Preparation must not commit a sidecar");
Require(transactions.Begin(2, saveKey, appearanceB, AppearanceSavePhase.WritePrepared), "Prepared write rejected");
Require(transactions.Complete(2, true)?.Choices == appearanceA, "Auto-save sampled choices after native preparation");
Require(transactions.Begin(3, saveKey, appearanceB, AppearanceSavePhase.WriteCurrent), "Manual write rejected");
Require(transactions.Complete(3, false) == null, "Failed/cancelled save committed choices");
Require(transactions.Complete(3, true) == null, "Duplicate completion resurrected a failed save");
Require(!transactions.Begin(4, saveKey with { Slot = 4 }, appearanceA, AppearanceSavePhase.WritePrepared),
    "Preparation leaked between slots");
transactions.Begin(5, saveKey, appearanceA, AppearanceSavePhase.Prepare);
transactions.Begin(6, saveKey, appearanceB, AppearanceSavePhase.Prepare);
transactions.Complete(6, true);
transactions.Complete(5, true);
transactions.Begin(7, saveKey, appearanceA, AppearanceSavePhase.WritePrepared);
Require(transactions.Complete(7, true)?.Choices == appearanceB, "Late old preparation replaced newer snapshot");
transactions.Begin(8, saveKey, appearanceA, AppearanceSavePhase.Prepare);
transactions.Complete(8, false);
Require(!transactions.Begin(9, saveKey, appearanceA, AppearanceSavePhase.WritePrepared), "Failed preparation reused stale choices");
Console.WriteLine("PASS: save completion gating, preparation snapshots, duplicate/late-event handling");
try
{
    var store = new AppearanceSaveStore(temporary);
    var preferencePath = Path.Combine(temporary, "settings", "preferences.json");
    Require(WardrobePreferences.Read(preferencePath) == new WardrobePreferences(), "Missing preferences did not use safe defaults");
    var preferences = new WardrobePreferences(Hotkey: "F8", Cards: true, Persistence: true, AutomaticRestore: true);
    preferences.Write(preferencePath);
    Require(WardrobePreferences.Read(preferencePath) == preferences, "Wardrobe preferences did not survive restart round trip");
    try { new WardrobePreferences(Hotkey: "MouseLeft").Write(preferencePath); throw new Exception("Invalid binding accepted"); }
    catch (FormatException) { }
    Require(WardrobePreferences.Read(preferencePath) == preferences, "Invalid preferences destroyed the last valid file");
    try { new WardrobePreferences(AutomaticRestore: true).Validate(); throw new Exception("Restore enabled without persistence"); }
    catch (FormatException) { }
    Require(new WardrobePreferences().UiCharacterSync, "Menu-character sync must default to enabled");
    Require(new WardrobePreferences(UiCharacterSync: false).Validate().UiCharacterSync == false, "Menu-character sync opt-out was not preserved");
    Require(new WardrobePreferences().AtomicSwitch, "Flicker-free switch must default to enabled");
    Require(new WardrobePreferences().UiLanguage == "auto", "Interface language must default to auto");
    Require(new WardrobePreferences(UiLanguage: "en").Validate().UiLanguage == "en", "Forced interface language was not preserved");
    try { new WardrobePreferences(UiLanguage: "fr").Validate(); throw new Exception("Unsupported interface language accepted"); }
    catch (FormatException) { }
    // Older preference files have no UiCharacterSync member; they must adopt the enabled default.
    File.WriteAllText(preferencePath,
        "{\"SchemaVersion\":1,\"Hotkey\":\"Slash\",\"Cards\":true,\"Persistence\":true,\"AutomaticRestore\":true}");
    Require(WardrobePreferences.Read(preferencePath).UiCharacterSync, "Legacy preferences did not adopt the menu-character default");
    preferences.Write(preferencePath);
    File.WriteAllText(preferencePath, "{");
    try { WardrobePreferences.Read(preferencePath); throw new Exception("Corrupt preferences silently accepted"); }
    catch (JsonException) { }
    Console.WriteLine("PASS: wardrobe preferences restart round-trip, invalid write preservation and corruption reporting");
    var key = new AppearanceSaveKey(0, 101, 196596286);
    Require(store.Read(key) == new AppearanceSaveRead(null, null), "Missing sidecar must not invent a selection");
    var saved = new SavedAppearance("author.a", "author.sword");
    store.Write(key, saved);
    Require(store.Read(key).Record?.Choices == saved, "Save choices did not round-trip");
    foreach (var other in new[] { key with { UserIndex = 1 }, key with { Slot = 1 }, key with { UniqueId = 2 } })
        Require(store.Read(other).Record == null, "Choices leaked across save identities");
    store.Write(key, new SavedAppearance(null, "author.sword"));
    Require(store.Read(key).Record?.Choices == new SavedAppearance(null, "author.sword"), "Cancellation did not persist independently");
    string file = Directory.GetFiles(temporary, "*.json").Single();
    File.WriteAllText(file, "{");
    Require(store.Read(key) is { Record: null, Error: not null }, "Corruption was silently treated as no selection");
    File.WriteAllText(file, JsonSerializer.Serialize(new AppearanceSaveRecord(1, key with { Slot = 1 }, saved)));
    Require(store.Read(key) is { Record: null, Error: not null }, "Wrong embedded save identity was accepted");
    File.WriteAllText(file, JsonSerializer.Serialize(new AppearanceSaveRecord(2, key, saved)));
    Require(store.Read(key) is { Record: null, Error: not null }, "Unknown schema was accepted");
    try { store.Write(key, new SavedAppearance("../bad", null)); throw new Exception("Expected invalid MOD ID rejection"); }
    catch (FormatException) { }
    try { store.Read(key with { Slot = 0 }); throw new Exception("Expected invalid save key rejection"); }
    catch (ArgumentException) { }
    Require(Directory.GetFiles(temporary, "*.tmp").Length == 0, "Temporary writes were left behind");
    var v4Directory = Path.Combine(temporary, "v4");
    var wardrobeStore = new WardrobeSaveStore(v4Directory);
    Require(wardrobeStore.Read(key) == new WardrobeSaveRead(null, null), "Missing wardrobe sidecar must not invent a selection");
    var wardrobeState = new WardrobeSelectionState(new Dictionary<WardrobeCategory, string?> {
            [WardrobeCategory.Body] = "new.body", [WardrobeCategory.Cloak] = null,
            [WardrobeCategory.Gauntlet] = "new.glove", [WardrobeCategory.Weapon] = null,
            [WardrobeCategory.Transform] = "oni.custom" },
        new(new[] { WardrobeCategory.Cloak },
            new[] { new WardrobeVisibilityOverride(WardrobeCategory.Gauntlet, "new.body") }));
    wardrobeStore.Write(key, wardrobeState);
    var wardrobeRead = wardrobeStore.Read(key);
    Require(wardrobeRead.Error == null && wardrobeRead.Record != null &&
        wardrobeRead.Record.Choices.Requested[WardrobeCategory.Transform] == "oni.custom" &&
        wardrobeRead.Record.Choices.Visibility.ConfirmedOverrides.Single().DeclaringId == "new.body",
        "Schema 4 sidecar round trip lost the transform intent or visibility grants");
    foreach (var other in new[] { key with { UserIndex = 1 }, key with { Slot = 1 }, key with { UniqueId = 2 } })
        Require(wardrobeStore.Read(other).Record == null, "Wardrobe choices leaked across save identities");
    string wardrobeFile = Directory.GetFiles(v4Directory, "*.json").Single();
    var v4Bytes = File.ReadAllBytes(wardrobeFile);
    File.WriteAllText(wardrobeFile, JsonSerializer.Serialize(new WardrobeSaveRecord(3, key, wardrobeState)));
    var legacyRead = wardrobeStore.Read(key);
    Require(legacyRead.Record == null && legacyRead.LegacyVersion == 3 && legacyRead.Error != null,
        "An older wardrobe record must be reported for a rebuild, never read as the new format");
    Require(File.ReadAllText(wardrobeFile).Contains("\"SchemaVersion\":3"), "Reading a legacy record rewrote it");
    wardrobeStore.Write(key, wardrobeState);
    var backups = Directory.GetFiles(v4Directory, "*.legacy-v3.*.bak");
    Require(backups.Length == 1 && new FileInfo(backups[0]).Length > 0 && File.ReadAllText(backups[0]).Contains("\"SchemaVersion\":3"),
        "Legacy record was not preserved before the schema 4 write");
    Require(wardrobeStore.Read(key).Error == null, "Schema 4 write after the legacy backup failed");
    File.WriteAllText(wardrobeFile, "{");
    Require(wardrobeStore.Read(key) is { Record: null, Error: not null, LegacyVersion: null },
        "Corruption was silently treated as no selection");
    try { wardrobeStore.Write(key, wardrobeState); throw new Exception("Write over a corrupt sidecar was accepted"); }
    catch (InvalidDataException) { }
    File.WriteAllBytes(wardrobeFile, v4Bytes);
    try { wardrobeStore.Write(key, wardrobeState with { Requested = new Dictionary<WardrobeCategory, string?>() });
        throw new Exception("Incomplete wardrobe state accepted"); } catch (FormatException) { }
    Require(File.ReadAllBytes(wardrobeFile).SequenceEqual(v4Bytes), "Invalid write damaged the existing schema 4 record");
    File.WriteAllText(wardrobeFile, "{\"SchemaVersion\":4,\"Key\":{\"UserIndex\":0,\"Slot\":9,\"UniqueId\":1},\"Choices\":null}");
    Require(wardrobeStore.Read(key).Error != null, "Wrong embedded save identity accepted");
    File.WriteAllBytes(wardrobeFile, v4Bytes);
    var wardrobeTransactions = new AppearanceSaveTransactions<WardrobeSelectionState>();
    wardrobeTransactions.Begin(1, key, WardrobeSaveStore.Freeze(wardrobeState), AppearanceSavePhase.Prepare);
    var changedState = wardrobeState with { Requested = new Dictionary<WardrobeCategory, string?>(wardrobeState.Requested) {
        [WardrobeCategory.Body] = "changed.body" } };
    Require(wardrobeTransactions.Complete(1, true) == null, "Preparation published a wardrobe record");
    wardrobeTransactions.Begin(2, key, WardrobeSaveStore.Freeze(changedState), AppearanceSavePhase.WritePrepared);
    var committed = wardrobeTransactions.Complete(2, true)!;
    Require(committed.Choices.Requested[WardrobeCategory.Body] == "new.body", "Prepared snapshot followed later UI edits");
    wardrobeStore.Write(key, committed.Choices);
    Require(wardrobeStore.Read(key).Record!.Choices.Requested[WardrobeCategory.Body] == "new.body", "Committed snapshot did not save");
    Require(Directory.GetFiles(v4Directory, "*.tmp").Length == 0, "Schema 4 publication left temporary files");
    Console.WriteLine("PASS: schema 4 sidecar round trip, legacy rebuild reporting/backup, immutable prepared snapshot and invalid-write preservation");
}
finally
{
    string resolved = Path.GetFullPath(temporary);
    Require(Path.GetDirectoryName(resolved) == Path.TrimEndingDirectorySeparator(Path.GetFullPath(Path.GetTempPath())) &&
        Path.GetFileName(resolved).StartsWith("owots-appearance-tests-", StringComparison.Ordinal), "Unexpected test cleanup path");
    if (Directory.Exists(resolved)) Directory.Delete(resolved, true);
}
Console.WriteLine("PASS: sidecar round-trip, independent cancellation, key isolation, corrupt/schema/identity rejection");
WardrobeCompositionTests.Run();
WardrobeRegistryTests.Run();
WardrobeTransformTests.Run();
WardrobeSkeletonTests.Run();
WardrobeEquipTests.Run();
var v4 = """{"schemaVersion":4,"id":"test.body","name":"合并模型","category":"body","parts":[{"part":"BODY","catalog":"mods/test/catalog.user","prefab":"mods/test/body.pfb"}],"rules":{"hideParts":["HEAD","HAIR"],"incompatibleCategories":["cloak","gauntlet"]}}""";
var parsedV4 = WardrobeManifest.Parse(v4, "test");
Require(parsedV4.Rules.HiddenParts.Count == 2 && parsedV4.Rules.IncompatibleCategories.Count == 2,
    "Schema 4 lost declarations");
foreach (var invalid in new[] { v4.Replace("hideParts", "hidePart"), v4.Replace("\"HEAD\",\"HAIR\"", "\"BODY\""),
    v4.Replace("body.pfb", "../body.pfb"), v4.Replace("\"category\":\"body\"", "\"category\":\"cloak\""),
    v4.Replace("\"schemaVersion\":4", "\"schemaVersion\":4,\"schemaVersion\":4"),
    v4.Replace("\"rules\":{", "\"rules\":{\"transform\":\"keep\",") })
{
    bool rejected = false;
    try { WardrobeManifest.Parse(invalid, "invalid"); }
    catch (Exception e) when (e is FormatException or ArgumentException) { rejected = true; }
    Require(rejected, "Unsafe schema 4 manifest accepted");
}
Console.WriteLine("PASS: schema 4 declarations, rule typos, self-hide, path escape, category, removed keep-rule field and duplicate field rejection");
foreach (string path in args)
{
    using var fixture = JsonDocument.Parse(File.ReadAllText(path));
    if (fixture.RootElement.GetProperty("schemaVersion").GetInt32() == WardrobeManifest.SchemaVersion)
    {
        var actualV4 = WardrobeManifest.Parse(File.ReadAllText(path), path);
        Require(actualV4.Parts.Count > 0, "Schema 4 fixture contains no roots or parts");
        Console.WriteLine($"Parsed schema 4 fixture: {actualV4.Rules.Id}, {actualV4.Rules.Category}, {actualV4.Parts.Count} parts/roots");
        continue;
    }
    var actual = AppearanceRegistry.Parse(File.ReadAllText(path), path);
    Require(actual.Parts.Count > 0, "Actual fixture contains no parts");
    Console.WriteLine($"Parsed fixture: {actual.Id}, {actual.Kind}, {actual.Parts.Count} parts");
}
Console.WriteLine("PASS: coexistence, duplicate conflicts, invalid-file isolation, kind boundaries, independent choices; no runtime or visual claims");
