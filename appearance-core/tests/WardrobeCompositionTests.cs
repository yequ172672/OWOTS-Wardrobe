using OWOTS.Appearance;

static class WardrobeCompositionTests
{
    public static void Run()
    {
        static void Check(bool value, string message) { if (!value) throw new Exception(message); }
        var body = new WardrobeRuleEntry("body.b", WardrobeCategory.Body, new[] { "BODY" }, new[] { "HEAD", "HAIR" },
            new[] { WardrobeCategory.Cloak, WardrobeCategory.Gauntlet });
        var cloak = new WardrobeRuleEntry("cloak.a", WardrobeCategory.Cloak, new[] { "CLOAK" }, Array.Empty<string>(),
            new[] { WardrobeCategory.Weapon });
        var glove = new WardrobeRuleEntry("glove.a", WardrobeCategory.Gauntlet, new[] { "GAUNTLET" }, Array.Empty<string>(), Array.Empty<WardrobeCategory>());
        var weapon = new WardrobeRuleEntry("weapon.a", WardrobeCategory.Weapon, new[] { "WEAPON" }, Array.Empty<string>(), Array.Empty<WardrobeCategory>());
        var registry = new[] { body, cloak, glove, weapon }.ToDictionary(x => x.Id);
        var wish = new Dictionary<WardrobeCategory, string?> {
            [WardrobeCategory.Body] = body.Id, [WardrobeCategory.Cloak] = cloak.Id,
            [WardrobeCategory.Gauntlet] = glove.Id, [WardrobeCategory.Weapon] = weapon.Id };
        var blocked = WardrobeComposition.Resolve(wish, registry);
        Check(blocked.Requested[WardrobeCategory.Cloak] == cloak.Id && wish[WardrobeCategory.Cloak] == cloak.Id, "Suppression erased intent");
        Check(blocked.Effective.Count == 2 && blocked.Effective.ContainsKey(WardrobeCategory.Weapon), "Suppressed rule still affected weapon");
        Check(new[] { "HEAD", "HAIR", "CLOAK", "GAUNTLET" }.All(blocked.HiddenParts.Contains), "Native fallback not suppressed");
        var force = new WardrobeVisibilityOptions(Array.Empty<WardrobeCategory>(),
            new[] { new WardrobeVisibilityOverride(WardrobeCategory.Cloak, body.Id) });
        var forced = WardrobeComposition.Resolve(wish, registry, force);
        Check(forced.Effective[WardrobeCategory.Cloak] == cloak.Id && !forced.HiddenParts.Contains("CLOAK") &&
            forced.HiddenParts.Contains("GAUNTLET"), "Confirmed cloak override affected unrelated declarations");
        var off = WardrobeComposition.Resolve(wish, registry, force with { Disabled = new[] { WardrobeCategory.Cloak } });
        Check(off.HiddenParts.Contains("CLOAK") && off.Requested[WardrobeCategory.Cloak] == cloak.Id &&
            off.Suppressed[WardrobeCategory.Cloak] == "@user", "Visibility off failed to win or erased selection");
        var stale = WardrobeComposition.Resolve(wish, registry, force with {
            ConfirmedOverrides = new[] { new WardrobeVisibilityOverride(WardrobeCategory.Cloak, "other.body") } });
        Check(stale.HiddenParts.Contains("CLOAK"), "Override leaked across authors' entries");
        registry[body.Id] = body with { HiddenParts = new[] { "HEAD", "HAIR", "CLOAK" } };
        Check(!WardrobeComposition.Resolve(wish, registry, force).HiddenParts.Contains("CLOAK"), "Explicit hide ignored confirmed override");
        registry[body.Id] = body with { HiddenParts = new[] { "CLOAK" }, IncompatibleCategories = Array.Empty<WardrobeCategory>() };
        var explicitHide = WardrobeComposition.Resolve(wish, registry);
        Check(explicitHide.Suppressed[WardrobeCategory.Cloak] == body.Id && explicitHide.Issues.Count == 0,
            "Accessory hide declaration failed to suppress selected provider");
        registry[body.Id] = body;
        wish[WardrobeCategory.Body] = null;
        var restored = WardrobeComposition.Resolve(wish, registry);
        Check(restored.Effective[WardrobeCategory.Cloak] == cloak.Id && restored.Effective[WardrobeCategory.Gauntlet] == glove.Id,
            "Compatible selection did not restore");
        Check(restored.Suppressed[WardrobeCategory.Weapon] == cloak.Id, "Fixed conflict priority not applied");
        wish[WardrobeCategory.Body] = body.Id; wish[WardrobeCategory.Cloak] = null;
        Check(WardrobeComposition.Resolve(wish, registry).HiddenParts.Contains("CLOAK"), "Native cloak survives incompatible body");
        wish[WardrobeCategory.Body] = "missing";
        var missing = WardrobeComposition.Resolve(wish, registry);
        Check(missing.Requested[WardrobeCategory.Body] == "missing" && missing.Issues.Count == 1 && !missing.HiddenParts.Contains("HEAD"),
            "Missing entry lost intent or retained rules");
        registry[body.Id] = body with { HiddenParts = new[] { "BODY" } }; wish[WardrobeCategory.Body] = body.Id;
        try { WardrobeComposition.Resolve(wish, registry); throw new Exception("Self-hidden resource accepted"); }
        catch (ArgumentException) { }
        Console.WriteLine("PASS: four-category intent, suppression/native fallback, restoration, inactive rules and missing entry");
    }
}
