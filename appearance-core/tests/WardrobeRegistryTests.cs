using System.Text.Json;
using OWOTS.Appearance;

static class WardrobeRegistryTests
{
    public static void Run()
    {
        static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
        static string Declared(string id, string category, string part, string[] hidden, string[] incompatible) =>
            JsonSerializer.Serialize(new { schemaVersion = 4, id, name = id, category,
                parts = new[] { new { part, catalog = "mods/test/catalog.user", prefab = "mods/test/model.pfb" } },
                rules = new { hideParts = hidden, incompatibleCategories = incompatible } });
        WardrobeRegistrySnapshot Build(params (string Source, string Json)[] files) =>
            WardrobeRegistry.Build(files.Select(file => (file.Source, (Func<string>)(() => file.Json))));

        var v2 = Declared("new.body", "body", "BODY", new[] { "HEAD" }, Array.Empty<string>());
        var v3 = v2.Replace("\"schemaVersion\":4", "\"schemaVersion\":3");
        var v2Only = v2.Replace("\"schemaVersion\":4", "\"schemaVersion\":2");
        var v1 = JsonSerializer.Serialize(new { schemaVersion = 1, id = "old.outfit", name = "套装", kind = "outfit",
            parts = new[] { "BODY", "HEAD", "HAIR", "CLOAK", "GAUNTLET" }.Select(part =>
                new { part, catalog = "mods/old/catalog.user", prefab = "mods/old/" + part.ToLowerInvariant() + ".pfb" }) });
        var legacy = Build(("old/manifest.json", v1), ("v2/manifest.json", v2Only), ("v3/manifest.json", v3), ("new/manifest.json", v2));
        Check(legacy.Entries.Count == 1 && legacy.Entries.ContainsKey("new.body"), "Schema 4 entry was rejected or an older schema was read");
        Check(legacy.Issues.Count == 3 && legacy.Issues.All(issue => issue.Message.Contains("re-convert")),
            "Older manifests must be reported for re-conversion with one issue each");
        var duplicate = Build(("a", v2), ("b", v2.Replace("\"new.body\"", "\"new.body\"")));
        Check(duplicate.Entries.Count == 0 && duplicate.Issues.Count == 2, "Conflicting IDs must both be rejected");
        var isolated = Build(("bad", "{"), ("valid", v2));
        Check(isolated.Entries.Count == 1 && isolated.Issues.Count == 1, "A malformed manifest blocked an independent valid entry");
        var transform = """{"schemaVersion":4,"id":"oni.custom","name":"鬼化","category":"transform","roots":[{"root":"ONI_BODY","prefab":"mods/oni/body.pfb"},{"root":"ONI_HEAD","catalog":"mods/oni/head.user","prefab":"mods/oni/head.pfb"}],"rules":{"hideParts":["HAIR"]}}""";
        var withTransform = Build(("oni", transform));
        Check(withTransform.Issues.Count == 0 && withTransform.Entries["oni.custom"].Rules.Category == WardrobeCategory.Transform &&
            withTransform.Entries["oni.custom"].Rules.ProvidedParts.SequenceEqual(new[] { "ONI_BODY", "ONI_HEAD" }) &&
            withTransform.Entries["oni.custom"].Rules.HiddenParts.SequenceEqual(new[] { "HAIR" }),
            "Transform manifest did not parse its roots and in-domain targets");
        foreach (var invalid in new[] {
            transform.Replace("\"ONI_TAIL\"", "\"ONI_TAIL\"").Replace("\"ONI_BODY\"", "\"ONI_TAIL\""),
            transform.Replace("\"HAIR\"", "\"CLOAK\""),
            transform.Replace("\"roots\":", "\"parts\":[{\"part\":\"BODY\",\"catalog\":\"mods/oni/a.user\",\"prefab\":\"mods/oni/a.pfb\"}],\"ignored\":") })
        {
            var rejected = Build(("oni", invalid));
            Check(rejected.Entries.Count == 0 && rejected.Issues.Count == 1, "Invalid transform manifest was accepted");
        }
        var iniRoot = Path.Combine(Path.GetTempPath(), "wardrobe-ini-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(iniRoot);
        try {
            File.WriteAllText(Path.Combine(iniRoot, "manifest.json"), Declared("ini.body", "body", "BODY", Array.Empty<string>(), Array.Empty<string>()));
            string common = "; keep\nname = INI name\nauthor = INI author\ndescription = 100% test\n[wardrobe.body]\nid = ini.body\nhide_head = true\nhide_hair = true\nincompatible_cloak = true\nincompatible_gauntlet = false\n";
            File.WriteAllText(Path.Combine(iniRoot, "modinfo.ini"), common);
            var fromIni = WardrobeRegistry.ReadDirectory(iniRoot);
            Check(fromIni.Issues.Count == 0 && fromIni.Entries["ini.body"].Name == "INI name", "Shared INI metadata was not read");
            var resolvedIni = WardrobeSelections.Resolve(WardrobeSelections.Choose(WardrobeSelections.Empty(),
                WardrobeCategory.Body, "ini.body", fromIni), fromIni).Composition;
            Check(resolvedIni.HiddenParts.Contains("HEAD") && resolvedIni.HiddenParts.Contains("HAIR") && resolvedIni.HiddenParts.Contains("CLOAK"), "INI hide declarations were not applied");
            Check(File.ReadAllText(Path.Combine(iniRoot,"modinfo.ini")) == common, "Runtime changed author INI");
            File.WriteAllText(Path.Combine(iniRoot,"modinfo.ini"),common.Replace("ini.body","wrong.id"));
            Check(WardrobeRegistry.ReadDirectory(iniRoot).Entries.Count == 0, "Mismatched INI identity was accepted");
        } finally { Directory.Delete(iniRoot,true); }
        var declared = Build(("body", Declared("new.body", "body", "BODY", Array.Empty<string>(), new[] { "cloak", "gauntlet" })),
            ("cloak", Declared("new.cloak", "cloak", "CLOAK", new[] { "GAUNTLET" }, Array.Empty<string>())));
        var state = WardrobeSelections.Empty();
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
            off.Requested[WardrobeCategory.Cloak] == "new.cloak", "Display off erased choice or retained force");
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
        Console.WriteLine("PASS: schema 4 parsing, transform roots, older-version re-conversion reporting and isolated invalid files");
        Console.WriteLine("PASS: scoped confirmation, multiple blockers, display off/on, retained choice and expired approval");
    }
}
