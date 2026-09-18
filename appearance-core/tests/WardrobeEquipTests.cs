using OWOTS.Appearance;

static class WardrobeEquipTests
{
    public static void Run()
    {
        static void Check(bool value, string message) { if (!value) throw new Exception(message); }
        static string Manifest(string id, string category, string part, string rules = "{}", int version = 2) =>
            $$"""{"schemaVersion":{{version}},"id":"{{id}}","name":"{{id}}","category":"{{category}}","parts":[{"part":"{{part}}","catalog":"mods/test/a.user","prefab":"mods/test/a.pfb"}],"rules":{{rules}}} """;
        var json = Manifest("set.body", "body", "BODY",
            """{"equip":{"cloak":"set.cloak","gauntlet":"set.glove"}}""", 3);
        var files = new[] { json, Manifest("set.cloak", "cloak", "CLOAK"), Manifest("set.glove", "gauntlet", "GAUNTLET"),
            Manifest("user.glove", "gauntlet", "GAUNTLET"), Manifest("user.cloak", "cloak", "CLOAK"),
            Manifest("other.body", "body", "BODY") };
        var registry = WardrobeRegistry.Build(files.Select((text, i) => ("fixture" + i, (Func<string>)(() => text))));
        Check(registry.Issues.Count == 0 && registry.Entries.ContainsKey("set.body"),
            "Body manifest with declared accessory equip was rejected");
        var empty = WardrobeSelections.FromLegacy(new SavedAppearance(null, null));
        var initial = WardrobeSelections.Choose(empty, WardrobeCategory.Cloak, "user.cloak", registry);
        initial = WardrobeSelections.Choose(initial, WardrobeCategory.Gauntlet, "user.glove", registry);
        var wearing = WardrobeSelections.Choose(initial, WardrobeCategory.Body, "set.body", registry);
        var applied = WardrobeSelections.Resolve(wearing, registry).Composition;
        Check(applied.Effective[WardrobeCategory.Cloak] == "set.cloak" && applied.Effective[WardrobeCategory.Gauntlet] == "set.glove",
            "Wearing body did not select its declared cloak and gauntlet");
        Check(initial.Requested[WardrobeCategory.Gauntlet]!.EntryId == "user.glove", "Choose mutated its input");
        var manual = WardrobeSelections.Choose(wearing, WardrobeCategory.Gauntlet, "user.glove", registry);
        for (int i = 0; i < 3; i++) Check(WardrobeSelections.Resolve(manual, registry).Composition.Effective[WardrobeCategory.Gauntlet] == "user.glove",
            "Polling re-applied the body default over a manual gauntlet choice");
        var cancelled = WardrobeSelections.Choose(manual, WardrobeCategory.Body, null, registry);
        Check(cancelled.Requested[WardrobeCategory.Gauntlet]!.EntryId == "user.glove" && cancelled.Requested[WardrobeCategory.Cloak]!.EntryId == "user.cloak",
            "Cancelling body erased manual choice or retained its default cloak");
        var rewear = WardrobeSelections.Choose(manual, WardrobeCategory.Body, "set.body", registry);
        Check(rewear.Requested[WardrobeCategory.Gauntlet]!.EntryId == "set.glove", "Explicit rewear did not reapply the declared default");
        var switchBody = WardrobeSelections.Choose(rewear, WardrobeCategory.Body, "other.body", registry);
        Check(switchBody.Requested[WardrobeCategory.Gauntlet]!.EntryId == "user.glove", "Switching body lost the underlying manual choice");
        var manualNative = WardrobeSelections.Choose(wearing, WardrobeCategory.Gauntlet, null, registry);
        Check(WardrobeSelections.Choose(manualNative, WardrobeCategory.Body, null, registry).Requested[WardrobeCategory.Gauntlet] == null,
            "Explicit native accessory choice was overwritten on body cancellation");
        var missing = WardrobeRegistry.Build(files.Where(x => !x.Contains("\"id\":\"set.glove\"")).Select((text, i) => ("missing" + i, (Func<string>)(() => text))));
        try { WardrobeSelections.Choose(initial, WardrobeCategory.Body, "set.body", missing); throw new Exception("Missing declared accessory accepted"); }
        catch (InvalidOperationException) { }
        Check(WardrobeSelections.Resolve(wearing, missing).IncompleteDeclaredEquipment, "Missing saved declared accessory would apply a half outfit");
        var missingBody = WardrobeRegistry.Build(files.Where(x => !x.Contains("\"id\":\"set.body\"")).Select((text, i) => ("missingbody" + i, (Func<string>)(() => text))));
        Check(WardrobeSelections.Resolve(wearing, missingBody).Composition.Effective[WardrobeCategory.Cloak] == "user.cloak",
            "Missing body continued imposing its default cloak");
        Check(wearing.Requested[WardrobeCategory.Cloak]!.EntryId == "set.cloak", "Missing body fallback erased saved intent");
        foreach (var invalid in new[] { json.Replace("\"schemaVersion\":3", "\"schemaVersion\":2"),
            json.Replace("set.glove\"", "set.body\""),
            json.Replace("\"equip\":", "\"hideParts\":[\"CLOAK\"],\"equip\":"),
            json.Replace("\"cloak\":\"set.cloak\"", "\"weapon\":\"set.cloak\"") }) {
            try { WardrobeManifest.Parse(invalid, "invalid"); throw new Exception("Invalid equip declaration accepted"); }
            catch (Exception e) when (e is ArgumentException or FormatException) { }
        }
        var folder = Path.Combine(Path.GetTempPath(), "owots-equip-tests-" + Guid.NewGuid().ToString("N"));
        try {
            var store = new WardrobeSaveStore(folder);
            var key = new AppearanceSaveKey(0, 1, 100);
            store.Write(key, manual);
            var read = store.Read(key);
            Check(read.Error == null && read.Record != null, "Declared equip save failed to round-trip");
            var loaded = read.Record!.Choices;
            Check(WardrobeSelections.Resolve(loaded, registry).Composition.Effective[WardrobeCategory.Gauntlet] == "user.glove", "Load reset manual override");
            var afterLoadCancel = WardrobeSelections.Choose(loaded, WardrobeCategory.Body, null, registry);
            Check(afterLoadCancel.Requested[WardrobeCategory.Cloak]!.EntryId == "user.cloak", "Load lost reversible cloak declaration");
            store.Write(key, afterLoadCancel);
            Check(store.Read(key).Error == null, "Cancelled declaration state did not save");
        } finally {
            var full = Path.GetFullPath(folder);
            Check(Path.GetDirectoryName(full) == Path.TrimEndingDirectorySeparator(Path.GetFullPath(Path.GetTempPath())) && Path.GetFileName(full).StartsWith("owots-equip-tests-"), "Unexpected test cleanup path");
            if (Directory.Exists(full)) Directory.Delete(full, true);
        }
        Console.WriteLine("PASS: declared equip, manual override, cancellation, rewear, missing dependency and saved restoration");
    }
}
