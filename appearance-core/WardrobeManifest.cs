using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace OWOTS.Appearance;

public sealed record WardrobePart(string Part, string Catalog, string Prefab);
public sealed record WardrobeManifestEntry(WardrobeRuleEntry Rules, string Name,
    IReadOnlyList<WardrobePart> Parts, string Description, string Author, string? Icon, string Source,
    WardrobeSkeleton? Skeleton = null);

/// <summary>Version 2 resources and version 3 declared accessory equip rules.</summary>
public static class WardrobeManifest
{
    public static WardrobeManifestEntry Parse(string json, string source)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        Fields(root, "schemaVersion", "id", "name", "category", "parts", "rules", "description", "author", "icon", "skeleton");
        int version = root.GetProperty("schemaVersion").GetInt32();
        if (version is not (2 or 3)) throw new FormatException("Expected schemaVersion 2 or 3");
        var id = Text(root.GetProperty("id"));
        if (!Regex.IsMatch(id, "^[a-z0-9][a-z0-9._-]{0,127}$")) throw new FormatException("Invalid stable id");
        var category = Category(Text(root.GetProperty("category")));
        var parts = new List<WardrobePart>();
        foreach (var part in root.GetProperty("parts").EnumerateArray())
        {
            Fields(part, "part", "catalog", "prefab");
            parts.Add(new(Text(part.GetProperty("part")), Path(Text(part.GetProperty("catalog")), ".user"),
                Path(Text(part.GetProperty("prefab")), ".pfb")));
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
                if (version != 3) throw new FormatException("Declared equip requires schemaVersion 3");
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

    private static WardrobeCategory Category(string value) => value switch {
        "body" => WardrobeCategory.Body, "cloak" => WardrobeCategory.Cloak,
        "gauntlet" => WardrobeCategory.Gauntlet, "weapon" => WardrobeCategory.Weapon,
        _ => throw new FormatException("Unknown category") };

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
