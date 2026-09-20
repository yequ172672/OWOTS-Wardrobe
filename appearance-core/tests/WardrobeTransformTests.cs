using OWOTS.Appearance;

static class WardrobeTransformTests
{
    public static void Run()
    {
        static void Check(bool value, string message) { if (!value) throw new Exception(message); }
        static string Transform(string id, string[] hidden) =>
            "{\"schemaVersion\":4,\"id\":\"" + id + "\",\"name\":\"" + id + "\",\"category\":\"transform\"," +
            "\"roots\":[{\"root\":\"ONI_BODY\",\"prefab\":\"mods/oni/body.pfb\"}]," +
            "\"rules\":{\"hideParts\":[" + string.Join(",", hidden.Select(h => "\"" + h + "\"")) + "]}}";
        var files = new[] { Transform("oni.a", new[] { "HAIR" }), Transform("oni.b", Array.Empty<string>()) };
        var registry = WardrobeRegistry.Build(files.Select((text, i) => ("fixture" + i, (Func<string>)(() => text))));
        Check(registry.Issues.Count == 0, "Transform fixtures were rejected");
        var store = new WardrobeTransformSnapshotStore();
        var expectation = WardrobeSelections.Choose(WardrobeSelections.Empty(), WardrobeCategory.Transform, "oni.a", registry);
        var locked = store.Lock(expectation, registry);
        Check(locked.Policy == TransformPolicy.WardrobeEntry && locked.EntryId == "oni.a" &&
            locked.HiddenParts.SequenceEqual(new[] { "HAIR" }), "Lock did not freeze the selected entry");
        var changed = WardrobeSelections.Choose(expectation, WardrobeCategory.Transform, "oni.b", registry);
        Check(store.IsPending(changed, registry) && store.Current!.EntryId == "oni.a",
            "A mid-transformation change replaced the active snapshot");
        var next = store.Lock(changed, registry);
        Check(next.EntryId == "oni.b" && !store.IsPending(changed, registry), "Next lock did not adopt the newer expectation");
        store.Clear();
        Check(store.Current == null && !store.IsPending(changed, registry), "Clear left a stale snapshot or pending flag");
        Console.WriteLine("PASS: transform expectation/snapshot isolation and next-lock adoption");
    }
}
