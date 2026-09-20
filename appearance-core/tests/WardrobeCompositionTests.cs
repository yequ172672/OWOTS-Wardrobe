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

        // Transform is a separate domain. Its entries own resident roots and in-domain
        // visibility targets; normal-state hiding and conflicts never cross the boundary.
        var oni = new WardrobeRuleEntry("oni.a", WardrobeCategory.Transform, new[] { "ONI_BODY", "ONI_HEAD" },
            new[] { "HAIR" }, Array.Empty<WardrobeCategory>());
        var oniBodyOnly = new WardrobeRuleEntry("oni.body", WardrobeCategory.Transform, new[] { "ONI_BODY" },
            Array.Empty<string>(), Array.Empty<WardrobeCategory>());
        var transformRegistry = new[] { oni, oniBodyOnly, cloak }.ToDictionary(x => x.Id);
        var native = WardrobeComposition.ResolveTransform(null, transformRegistry);
        Check(native.Plan!.Policy == TransformPolicy.Native && native.Issues.Count == 0,
            "No selection must hand the transformation to the game");
        var explicitChoice = WardrobeComposition.ResolveTransform("oni.a", transformRegistry);
        Check(explicitChoice.Plan!.Policy == TransformPolicy.WardrobeEntry && explicitChoice.Plan.EntryId == "oni.a" &&
            explicitChoice.Plan.HiddenParts.SequenceEqual(new[] { "HAIR" }), "Explicit transform selection did not win");
        var absent = WardrobeComposition.ResolveTransform("oni.missing", transformRegistry);
        Check(absent.Plan!.Policy == TransformPolicy.Native && absent.Issues.Count == 1,
            "Missing transform entry must fall back to native and report");
        var wrongCategory = WardrobeComposition.ResolveTransform("cloak.a", transformRegistry);
        Check(wrongCategory.Plan!.Policy == TransformPolicy.Native && wrongCategory.Issues.Count == 1,
            "Wrong-category transform selection was accepted");
        var normalPlan = WardrobeComposition.Resolve(new Dictionary<WardrobeCategory, string?> {
            [WardrobeCategory.Body] = "oni.a" }, transformRegistry);
        Check(normalPlan.Issues.Count == 1 && normalPlan.HiddenParts.Count == 0,
            "Transform entry leaked into the normal-state domain");
        try {
            WardrobeComposition.Resolve(new Dictionary<WardrobeCategory, string?> { [WardrobeCategory.Transform] = "oni.a" }, transformRegistry);
            throw new Exception("Normal composition accepted the transform category");
        } catch (ArgumentException) { }
        foreach (var invalid in new[] {
            new WardrobeRuleEntry("bad.root", WardrobeCategory.Transform, new[] { "ONI_TAIL" }, Array.Empty<string>(), Array.Empty<WardrobeCategory>()),
            new WardrobeRuleEntry("bad.target", WardrobeCategory.Transform, new[] { "ONI_BODY" }, new[] { "BODY" }, Array.Empty<WardrobeCategory>()),
            new WardrobeRuleEntry("bad.conflict", WardrobeCategory.Transform, new[] { "ONI_BODY" }, Array.Empty<string>(), new[] { WardrobeCategory.Cloak }),
            new WardrobeRuleEntry("bad.equip", WardrobeCategory.Transform, new[] { "ONI_BODY" }, Array.Empty<string>(), Array.Empty<WardrobeCategory>(),
                new Dictionary<WardrobeCategory, string> { [WardrobeCategory.Cloak] = "cloak.a" }) })
        {
            try { WardrobeComposition.Validate(invalid); throw new Exception("Invalid transform entry accepted: " + invalid.Id); }
            catch (ArgumentException) { }
        }
        Console.WriteLine("PASS: four-category intent, suppression/native fallback, restoration, inactive rules and missing entry");
        Console.WriteLine("PASS: transform domain isolation, selection/native rule, missing/wrong-category fallback and invalid root/target rejection");
    }
}
