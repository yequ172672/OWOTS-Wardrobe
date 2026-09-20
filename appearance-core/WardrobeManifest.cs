using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace OWOTS.Appearance;

// Mesh/Material are optional transform-root renderer references: the runtime swaps the
// live Oni renderer to them instead of replacing the resident prefab.
public sealed record WardrobePart(string Part, string Catalog, string Prefab, string Mesh = "", string Material = "");
public sealed record WardrobeManifestEntry(WardrobeRuleEntry Rules, string Name,
    IReadOnlyList<WardrobePart> Parts, string Description, string Author, string? Icon, string Source,
    WardrobeSkeleton? Skeleton = null);

/// <summary>
/// Version 4 manifest. Normal-state categories declare native parts; the transform
/// category declares ONI_BODY/ONI_HEAD resident roots and in-domain visibility targets.
/// Earlier schema versions are rejected with a re-conversion message.
/// </summary>
public static class WardrobeManifest
{
    public const int SchemaVersion = 4;

    public static WardrobeManifestEntry Parse(string json, string source)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        Fields(root, "schemaVersion", "id", "name", "category", "parts", "roots", "rules", "description", "author", "icon", "skeleton");
        int version = root.GetProperty("schemaVersion").GetInt32();
        if (version != SchemaVersion)
            throw new FormatException("Expected schemaVersion " + SchemaVersion + "; version " + version + " is no longer read, re-convert this appearance");
        var id = Text(root.GetProperty("id"));
        if (!Regex.IsMatch(id, "^[a-z0-9][a-z0-9._-]{0,127}$")) throw new FormatException("Invalid stable id");
        var category = Category(Text(root.GetProperty("category")));
        var parts = new List<WardrobePart>();
        if (category == WardrobeCategory.Transform)
        {
            if (root.TryGetProperty("parts", out var unusedParts) && unusedParts.ValueKind != JsonValueKind.Undefined)
                throw new FormatException("Transform entries declare roots, not parts");
            foreach (var item in Required(root, "roots").EnumerateArray())
            {
                Fields(item, "root", "catalog", "prefab", "mesh", "material");
                var name = Text(item.GetProperty("root"));
                if (!WardrobeComposition.TransformRoots.Contains(name))
                    throw new FormatException("Unknown transform resident root: " + name);
                var catalog = item.TryGetProperty("catalog", out var catalogValue) ? Path(Text(catalogValue), ".user") : "";
                var mesh = item.TryGetProperty("mesh", out var meshValue) ? Path(Text(meshValue), ".mesh") : "";
                var material = item.TryGetProperty("material", out var materialValue) ? Path(Text(materialValue), ".mdf2") : "";
                parts.Add(new(name, catalog, Path(Text(item.GetProperty("prefab")), ".pfb"), mesh, material));
            }
            if (parts.Count == 0) throw new FormatException("At least one transform root is required");
        }
        else
        {
            if (root.TryGetProperty("roots", out var unusedRoots) && unusedRoots.ValueKind != JsonValueKind.Undefined)
                throw new FormatException("Only transform entries declare resident roots");
            foreach (var part in Required(root, "parts").EnumerateArray())
            {
                Fields(part, "part", "catalog", "prefab");
                parts.Add(new(Text(part.GetProperty("part")), Path(Text(part.GetProperty("catalog")), ".user"),
                    Path(Text(part.GetProperty("prefab")), ".pfb")));
            }
            if (parts.Count == 0) throw new FormatException("At least one part is required");
        }
        var hidden = new List<string>();
        var incompatible = new List<WardrobeCategory>();
        var equip = new Dictionary<WardrobeCategory, string>();
        if (root.TryGetProperty("rules", out var rules))
        {
            Fields(rules, "hideParts", "incompatibleCategories", "equip");
            if (rules.TryGetProperty("hideParts", out var hide)) hidden.AddRange(hide.EnumerateArray().Select(value => Text(value)));
            if (rules.TryGetProperty("incompatibleCategories", out var conflict))
                incompatible.AddRange(conflict.EnumerateArray().Select(value => Category(Text(value))));
            if (rules.TryGetProperty("equip", out var equipped)) {
                Fields(equipped, "cloak", "gauntlet");
                foreach (var property in equipped.EnumerateObject()) equip.Add(Category(property.Name), Text(property.Value));
            }
        }
        if (hidden.Distinct().Count() != hidden.Count || incompatible.Distinct().Count() != incompatible.Count)
            throw new FormatException("Duplicate rule values");
        var entry = new WardrobeRuleEntry(id, category, Array.AsReadOnly(parts.Select(p => p.Part).ToArray()),
            hidden.AsReadOnly(), incompatible.AsReadOnly(), equip.Count == 0 ? null :
                new ReadOnlyDictionary<WardrobeCategory, string>(equip));
        WardrobeComposition.Validate(entry);
        string Optional(string key) => root.TryGetProperty(key, out var value) ? Text(value, true) : "";
        var icon = Optional("icon");
        if (icon.Length > 0) Path(icon, ".png", ".jpg", ".jpeg");
        var skeleton = root.TryGetProperty("skeleton", out var skeletonValue)
            ? WardrobeSkeleton.Parse(skeletonValue, id, category, parts)
            : null;
        return new(entry, Text(root.GetProperty("name")), parts.AsReadOnly(), Optional("description"),
            Optional("author"), icon.Length == 0 ? null : icon, source, skeleton);
    }

    public static WardrobeCategory Category(string value) => value switch {
        "body" => WardrobeCategory.Body, "cloak" => WardrobeCategory.Cloak,
        "gauntlet" => WardrobeCategory.Gauntlet, "weapon" => WardrobeCategory.Weapon,
        "transform" => WardrobeCategory.Transform,
        _ => throw new FormatException("Unknown category") };

    private static JsonElement Required(JsonElement value, string property)
    {
        if (!value.TryGetProperty(property, out var result)) throw new FormatException("Missing field: " + property);
        return result;
    }

    private static string Text(JsonElement value, bool empty = false)
    {
        if (value.ValueKind != JsonValueKind.String) throw new FormatException("Expected text");
        var text = value.GetString()!;
        if (!empty && string.IsNullOrWhiteSpace(text)) throw new FormatException("Empty required text");
        return text;
    }

    private static string Path(string value, params string[] extensions)
    {
        if (value.Contains('\\') || value.Contains(':') || value.Contains('@') || value.Any(char.IsControl) ||
            value.Split('/').Any(segment => segment is "" or "." or "..") ||
            !extensions.Any(extension => value.EndsWith(extension, StringComparison.OrdinalIgnoreCase)))
            throw new FormatException("Expected relative logical resource path without version suffix");
        return value;
    }

    private static void Fields(JsonElement value, params string[] allowed)
    {
        if (value.ValueKind != JsonValueKind.Object) throw new FormatException("Expected object");
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var property in value.EnumerateObject())
            if (!seen.Add(property.Name) || !allowed.Contains(property.Name))
                throw new FormatException("Duplicate or unsupported field: " + property.Name);
    }
}
