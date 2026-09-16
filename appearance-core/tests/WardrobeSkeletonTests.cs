using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;
using OWOTS.Appearance;

static class WardrobeSkeletonTests
{
    public static void Run()
    {
        var validSkeleton = Skeleton("test.body");
        var parsed = WardrobeManifest.Parse(Manifest("test.body", "body", "BODY", validSkeleton), "skeleton");
        var skeleton = parsed.Skeleton ?? throw new Exception("Valid skeleton was not retained");
        Check(skeleton.SchemaVersion == 1 && skeleton.Kind == "actor-fbxskel-v1", "Skeleton identity changed");
        Check(skeleton.Resource == "mods/test.body/dynamic/actor.fbxskel" &&
            skeleton.BodyMesh == "mods/test.body/dynamic/body.mesh", "Private skeleton paths changed");
        Check(skeleton.BaselineResource == WardrobeSkeleton.FixedBaselineResource &&
            skeleton.JointNames.Count == 93 && skeleton.BindPositions.Count == 93,
            "Complete 93-joint skeleton metadata was not retained");
        Check(skeleton.JointNames.SequenceEqual(Enumerable.Range(0, 93).Select(i => "Joint" + i)),
            "Joint order changed");
        Check(skeleton.BindPositions["Joint17"].SequenceEqual(new[] { 17f, 18f, 19f }),
            "Bind positions changed");

        using (var snapshot = JsonDocument.Parse(skeleton.ToSnapshot().GetRawText()))
        {
            var root = snapshot.RootElement;
            Check(root.GetProperty("schemaVersion").GetInt32() == 1 &&
                root.GetProperty("kind").GetString() == "actor-fbxskel-v1" &&
                root.GetProperty("resource").GetString() == skeleton.Resource &&
                root.GetProperty("bodyMesh").GetString() == skeleton.BodyMesh &&
                root.GetProperty("jointNames").GetArrayLength() == 93 &&
                root.GetProperty("bindPositions").GetProperty("Joint17").GetArrayLength() == 3 &&
                root.GetProperty("baselineResource").GetString() == WardrobeSkeleton.FixedBaselineResource,
                "Skeleton snapshot did not use the stable lower-camel schema");
            Check(!root.TryGetProperty("SchemaVersion", out _), "Snapshot exposed PascalCase fields");
        }

        // Runtime discovery applies an optional modinfo.ini overlay to the
        // manifest.  The overlay is allowed to change presentation and rules,
        // but must not discard the independently validated skeleton contract.
        var overlaidJson = WardrobeRegistry.ApplyModInfo(
            Manifest("test.body", "body", "BODY", validSkeleton),
            "name=覆盖后的名称\ndescription=覆盖说明\nauthor=覆盖作者\n" +
            "[wardrobe.body]\nid=test.body\nhide_head=true\nhide_hair=true\n" +
            "incompatible_cloak=true\nincompatible_gauntlet=true\n");
        var overlaid = WardrobeManifest.Parse(overlaidJson, "skeleton-with-modinfo");
        Check(overlaid.Name == "覆盖后的名称" && overlaid.Description == "覆盖说明" &&
            overlaid.Author == "覆盖作者", "modinfo overlay did not update presentation fields");
        Check(overlaid.Rules.HiddenParts.SequenceEqual(new[] { "HEAD", "HAIR" }) &&
            overlaid.Rules.IncompatibleCategories.Count == 2,
            "modinfo overlay did not retain wardrobe rules");
        Check(overlaid.Skeleton != null &&
            overlaid.Skeleton.ToSnapshot().GetRawText() == validSkeleton.ToJsonString(),
            "modinfo overlay discarded or changed skeleton metadata");

        bool listReadOnly = false;
        try { ((IList<string>)skeleton.JointNames).Add("unexpected"); }
        catch (NotSupportedException) { listReadOnly = true; }
        bool mapReadOnly = false;
        try { ((IDictionary<string, IReadOnlyList<float>>)skeleton.BindPositions)["unexpected"] = new[] { 0f, 0f, 0f }; }
        catch (NotSupportedException) { mapReadOnly = true; }
        Check(listReadOnly && mapReadOnly, "Skeleton metadata was not immutable");

        // Compatibility contract: the runtime derives the shape from the manifest
        // bind positions when the converter declared them, otherwise from the
        // equipped body mesh skeleton.  Both `resource` and `bindPositions` are
        // therefore optional so a mesh-authored mod needs no separate rig file.
        var minimal = Skeleton("test.body");
        minimal.Remove("resource");
        minimal.Remove("bindPositions");
        var minimalParsed = WardrobeManifest.Parse(Manifest("test.body", "body", "BODY", minimal), "minimal").Skeleton
            ?? throw new Exception("Skeleton without resource/bindPositions was not retained");
        Check(minimalParsed.Resource == null && minimalParsed.BindPositions.Count == 0 &&
            minimalParsed.JointNames.Count == 93, "Optional resource/bindPositions were not accepted");
        using (var minimalSnapshot = JsonDocument.Parse(minimalParsed.ToSnapshot().GetRawText()))
            Check(!minimalSnapshot.RootElement.GetProperty("bindPositions").EnumerateObject().Any(),
                "A skeleton with no declared bind positions must expose none in the snapshot");

        // A schema-2 manifest without the optional field remains source-compatible.
        Check(WardrobeManifest.Parse(Manifest("legacy.body", "body", "BODY", null), "legacy").Skeleton == null,
            "Legacy schema-2 manifest unexpectedly required skeleton metadata");
        var legacyV1 = JsonSerializer.Serialize(new {
            schemaVersion = 1, id = "legacy.outfit", name = "旧套装", kind = "outfit",
            parts = new[] { new { part = "BODY", catalog = "mods/legacy/catalog.user", prefab = "mods/legacy/body.pfb" } }
        });
        Check(AppearanceRegistry.Parse(legacyV1, "legacy-v1").Parts.Count == 1,
            "Legacy schema-1 manifest stopped working");

        Reject(() => Manifest("wrong.category", "cloak", "CLOAK", Skeleton("wrong.category")),
            "non-BODY skeleton accepted");
        Reject(() => Mutate(validSkeleton, root => root["resource"] = "mods/other/dynamic/actor.fbxskel"),
            "cross-manifest skeleton resource accepted");
        Reject(() => Mutate(validSkeleton, root => root["resource"] = "mods/test.body/dynamic/actor.fbxskel.7"),
            "versioned FBXSKEL path accepted");
        Reject(() => Mutate(validSkeleton, root => root["bodyMesh"] = "mods/test.body/dynamic/body.mesh.260209350"),
            "versioned mesh path accepted");
        Reject(() => Mutate(validSkeleton, root => root["baselineResource"] = "art/model/character/ch0/ch001_00/91/other.fbxskel"),
            "non-/90 baseline accepted");
        Reject(() => Mutate(validSkeleton, root => root["jointNames"]!.AsArray().RemoveAt(92)),
            "incomplete joint list accepted");
        Reject(() => Mutate(validSkeleton, root => root["jointNames"]!.AsArray()[1] = "Joint0"),
            "duplicate joint name accepted");
        Reject(() => Mutate(validSkeleton, root => root["bindPositions"]!.AsObject().Remove("Joint92")),
            "missing bind position accepted");
        Reject(() => Mutate(validSkeleton, root => root["bindPositions"]!.AsObject()["Unknown"] = new JsonArray(0, 0, 0)),
            "unknown bind position accepted");
        Reject(() => Mutate(validSkeleton, root => root["bindPositions"]!.AsObject()["Joint0"] = new JsonArray(0, 0)),
            "short bind position accepted");
        Reject(() => Mutate(validSkeleton, root => root["bindPositions"]!.AsObject()["Joint0"] = new JsonArray("nan", 0, 0)),
            "non-numeric bind position accepted");
        Reject(() => Mutate(validSkeleton, root => root["unexpected"] = true),
            "unknown skeleton field accepted");
        Reject(() => DuplicateKind(validSkeleton), "duplicate skeleton property accepted");
        Console.WriteLine("PASS: optional 93-joint skeleton schema, private paths, immutable snapshot, malformed rejection and legacy compatibility");
    }

    private static JsonObject Skeleton(string id)
    {
        var names = Enumerable.Range(0, 93).Select(i => "Joint" + i).ToArray();
        var positions = names.ToDictionary(name => name,
            name => new[] { (float)int.Parse(name[5..]), (float)int.Parse(name[5..]) + 1, (float)int.Parse(name[5..]) + 2 });
        return JsonNode.Parse(JsonSerializer.Serialize(new {
            schemaVersion = 1,
            kind = "actor-fbxskel-v1",
            resource = "mods/" + id + "/dynamic/actor.fbxskel",
            bodyMesh = "mods/" + id + "/dynamic/body.mesh",
            jointNames = names,
            bindPositions = positions,
            baselineResource = WardrobeSkeleton.FixedBaselineResource
        }))!.AsObject();
    }

    private static string Manifest(string id, string category, string part, JsonObject? skeleton)
    {
        var parts = new JsonArray();
        parts.Add(new JsonObject {
            ["part"] = part,
            ["catalog"] = "mods/" + id + "/catalog.user",
            ["prefab"] = "mods/" + id + "/body.pfb"
        });
        var root = new JsonObject {
            ["schemaVersion"] = 2,
            ["id"] = id,
            ["name"] = id,
            ["category"] = category,
            ["parts"] = parts
        };
        if (skeleton != null)
            // A JsonNode can have only one parent.  Clone the fixture so the
            // helper can safely be used for both the baseline and overlay
            // parse in this test.
            root["skeleton"] = JsonNode.Parse(skeleton.ToJsonString())!.AsObject();
        return root.ToJsonString();
    }

    private static string Mutate(JsonObject source, Action<JsonObject> mutation)
    {
        var copy = JsonNode.Parse(source.ToJsonString())!.AsObject();
        mutation(copy);
        return Manifest("test.body", "body", "BODY", copy);
    }

    private static string DuplicateKind(JsonObject source)
    {
        var skeleton = source.ToJsonString();
        skeleton = skeleton.Replace("\"kind\":\"actor-fbxskel-v1\"",
            "\"kind\":\"actor-fbxskel-v1\",\"kind\":\"actor-fbxskel-v1\"", StringComparison.Ordinal);
        var root = JsonNode.Parse(Manifest("test.body", "body", "BODY", null))!.AsObject();
        root["skeleton"] = JsonNode.Parse(skeleton);
        return root.ToJsonString();
    }

    private static void Reject(Func<string> json, string message)
    {
        try
        {
            WardrobeManifest.Parse(json(), "invalid-skeleton");
            throw new Exception(message);
        }
        catch (FormatException) { }
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
    }
}
