using System.Text.Json;
using OWOTS.Appearance;

static class WardrobeRegistryTests
{
    public static void Run()
    {
        static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
        var old = JsonSerializer.Serialize(new { schemaVersion = 1, id = "old.outfit", name = "套装",
            kind = "outfit", parts = new[] { "BODY", "HEAD", "HAIR", "CLOAK", "GAUNTLET" }.Select(part =>
                new { part, catalog = "mods/old/catalog.user", prefab = "mods/old/" + part.ToLowerInvariant() + ".pfb" }) });
        WardrobeRegistrySnapshot Build(params (string Source, string Json)[] files) =>
            WardrobeRegistry.Build(files.Select(file => (file.Source, (Func<string>)(() => file.Json))));
        var registry = Build(("old/manifest.json", old));
        var bundle = registry.LegacyBundles["old.outfit"];
        Check(registry.Issues.Count == 0 && bundle.Selections.Count == 3, "Legacy outfit lost a category");
        Check(registry.Entries.Values.Sum(entry => entry.Parts.Count) == 5, "Legacy projection lost resources");
        Check(bundle.Selections[WardrobeCategory.Body] == "old.outfit", "Original primary identity changed");
        var relocated = Build(("renamed/manifest.json", old));
        Check(registry.Entries.Keys.Order().SequenceEqual(relocated.Entries.Keys.Order()), "Moving MOD changed projected identity");
        var rules = registry.Entries.ToDictionary(pair => pair.Key, pair => pair.Value.Rules);
        var requested = bundle.Selections.ToDictionary(pair => pair.Key, pair => (string?)pair.Value);
        Check(WardrobeComposition.Resolve(requested, rules).Effective.Count == 3, "Legacy bundle cannot be composed");
        var cloakId = bundle.Selections[WardrobeCategory.Cloak];
        var v2 = JsonSerializer.Serialize(new { schemaVersion = 2, id = cloakId, name = "冲突条目", category = "cloak",
            parts = new[] { new { part = "CLOAK", catalog = "mods/new/catalog.user", prefab = "mods/new/cloak.pfb" } } });
        var conflict = Build(("old", old), ("new", v2));
        Check(conflict.Entries.Count == 0 && conflict.LegacyBundles.Count == 0 && conflict.Issues.Count == 2,
            "Collision silently published a partial legacy bundle");
        var isolated = Build(("old", old), ("bad", "{"));
        Check(isolated.Entries.Count == 3 && isolated.Issues.Count == 1, "Bad file blocked independent valid entries");
        var saved = WardrobeSelections.FromLegacy(new("old.outfit", null));
        var absent = WardrobeSelections.Resolve(saved, Build());
        Check(absent.Issues.Count == 3 && saved.Requested[WardrobeCategory.Cloak]?.LegacyBundleId == "old.outfit",
            "Missing legacy package was erased or guessed");
        saved = WardrobeSelections.Choose(saved, WardrobeCategory.Cloak, null, Build());
        var reinstalled = WardrobeSelections.Resolve(saved, registry);
        Check(reinstalled.Composition.Effective.Count == 2 && !reinstalled.Composition.Effective.ContainsKey(WardrobeCategory.Cloak),
            "Reinstall ignored manual cloak cancellation or lost other legacy categories");
        Check(reinstalled.Issues.Count == 0, "Valid reinstalled bundle still warned");
        string Declared(string id, string category, string part, string[] hidden, string[] incompatible) =>
            JsonSerializer.Serialize(new { schemaVersion = 2, id, name = id, category,
                parts = new[] { new { part, catalog = "mods/test/catalog.user", prefab = "mods/test/model.pfb" } },
                rules = new { hideParts = hidden, incompatibleCategories = incompatible } });
        var iniRoot = Path.Combine(Path.GetTempPath(), "wardrobe-ini-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(iniRoot);
        try {
            File.WriteAllText(Path.Combine(iniRoot, "manifest.json"), Declared("ini.body", "body", "BODY", Array.Empty<string>(), Array.Empty<string>()));
            string common = "; keep\nname = INI name\nauthor = INI author\ndescription = 100% test\n[wardrobe.body]\nid = ini.body\nhide_head = true\nhide_hair = true\nincompatible_cloak = true\nincompatible_gauntlet = false\n";
            File.WriteAllText(Path.Combine(iniRoot, "modinfo.ini"), common);
            var fromIni = WardrobeRegistry.ReadDirectory(iniRoot);
            Check(fromIni.Issues.Count == 0 && fromIni.Entries["ini.body"].Name == "INI name", "Shared INI metadata was not read");
            var resolvedIni = WardrobeSelections.Resolve(WardrobeSelections.Choose(WardrobeSelections.FromLegacy(new(null,null)),
                WardrobeCategory.Body, "ini.body", fromIni), fromIni).Composition;
            Check(resolvedIni.HiddenParts.Contains("HEAD") && resolvedIni.HiddenParts.Contains("HAIR") && resolvedIni.HiddenParts.Contains("CLOAK"), "INI hide declarations were not applied");
            Check(File.ReadAllText(Path.Combine(iniRoot,"modinfo.ini")) == common, "Runtime changed author INI");
            File.WriteAllText(Path.Combine(iniRoot,"modinfo.ini"),common.Replace("ini.body","wrong.id"));
            Check(WardrobeRegistry.ReadDirectory(iniRoot).Entries.Count == 0, "Mismatched INI identity was accepted");
        } finally { Directory.Delete(iniRoot,true); }
        var declared = Build(("body", Declared("new.body", "body", "BODY", Array.Empty<string>(), new[] { "cloak", "gauntlet" })),
            ("cloak", Declared("new.cloak", "cloak", "CLOAK", new[] { "GAUNTLET" }, Array.Empty<string>())));
        var state = WardrobeSelections.FromLegacy(new(null, null));
        state = WardrobeSelections.Choose(state, WardrobeCategory.Body, "new.body", declared);
        state = WardrobeSelections.Choose(state, WardrobeCategory.Cloak, "new.cloak", declared);
        var required = WardrobeSelections.RequiredForceDeclarations(state, WardrobeCategory.Cloak, declared);
        Check(required.SequenceEqual(new[] { "new.body" }), "Confirmation does not identify declaring MOD");
        var forced = WardrobeSelections.ConfirmForce(state, WardrobeCategory.Cloak, required, declared);
        Check(WardrobeSelections.Resolve(forced, declared).Composition.Effective.ContainsKey(WardrobeCategory.Cloak), "Force did not apply");
        Check(WardrobeSelections.RequiredForceDeclarations(forced, WardrobeCategory.Gauntlet, declared).Count == 2,
            "Multiple declaring MODs were not included in confirmation");
        var off = WardrobeSelections.SetVisible(forced, WardrobeCategory.Cloak, false);
        Check(WardrobeSelections.Resolve(off, declared).Composition.HiddenParts.Contains("CLOAK") &&
            off.Requested[WardrobeCategory.Cloak]?.EntryId == "new.cloak", "Display off erased choice or retained force");
        Check(WardrobeSelections.RequiredForceDeclarations(WardrobeSelections.SetVisible(off, WardrobeCategory.Cloak, true),
            WardrobeCategory.Cloak, declared).Count == 1, "Reopening skipped author's declaration");
        var changed = WardrobeSelections.Choose(forced, WardrobeCategory.Body, null, declared);
        changed = WardrobeSelections.Choose(changed, WardrobeCategory.Body, "new.body", declared);
        Check(WardrobeSelections.RequiredForceDeclarations(changed, WardrobeCategory.Cloak, declared).Count == 1,
            "Force silently returned after changing declaring body");
        bool staleRejected = false;
        try { WardrobeSelections.ConfirmForce(state, WardrobeCategory.Cloak, new[] { "stale.body" }, declared); }
        catch (InvalidOperationException) { staleRejected = true; }
        Check(staleRejected, "Stale confirmation accepted");
        Console.WriteLine("PASS: scoped confirmation, multiple blockers, display off/on, retained choice and expired approval");
        Console.WriteLine("PASS: complete legacy projection, stable relocated identities, composition and atomic collision rejection");
    }
}
