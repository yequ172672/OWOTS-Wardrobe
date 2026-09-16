using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace OWOTS.Appearance;

public enum AppearanceKind { Outfit, Weapon }
public sealed record AppearancePart(int Part, string Catalog, string Prefab);
public sealed record AppearanceEntry(string Id, string Name, AppearanceKind Kind, IReadOnlyList<AppearancePart> Parts, string Source,
    string Description = "", string Author = "", string? Icon = null);
public sealed record RegistryIssue(string Source, string Message);
public sealed record RegistrySnapshot(IReadOnlyDictionary<string, AppearanceEntry> Entries, IReadOnlyList<RegistryIssue> Issues);

/// <summary>Manifest identities and resource references only; no game, skeleton or stat inspection.</summary>
public static class AppearanceRegistry
{
    private static readonly Dictionary<string, int> Parts = new(StringComparer.OrdinalIgnoreCase)
    {
        ["BODY"] = 0, ["BODY_SUB"] = 1, ["HEAD"] = 2, ["HAIR"] = 3,
        ["GAUNTLET"] = 4, ["CLOAK"] = 5, ["WEAPON"] = 6, ["SHEATH"] = 7,
        ["WEAPON_SUB"] = 8, ["SHEATH_SUB"] = 9, ["BOW"] = 12
    };

    public static AppearanceEntry Parse(string json, string source)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        if (root.GetProperty("schemaVersion").GetInt32() != 1)
            throw new FormatException("Unsupported appearance manifest schemaVersion");
        var id = RequiredText(root, "id").ToLowerInvariant();
        if (!Regex.IsMatch(id, "^[a-z0-9][a-z0-9._-]{0,127}$"))
            throw new FormatException("id must use ASCII letters, digits, dots, underscores or hyphens");
        var name = RequiredText(root, "name");
        var kind = RequiredText(root, "kind").ToLowerInvariant() switch
        {
            "outfit" => AppearanceKind.Outfit,
            "weapon" => AppearanceKind.Weapon,
            _ => throw new FormatException("kind must be outfit or weapon")
        };
        // Do not silently claim that a future attribute payload has been registered.
        if (root.TryGetProperty("weaponAttributes", out var attributes) && attributes.ValueKind != JsonValueKind.Null)
            throw new FormatException("Weapon attribute registration is not implemented; omit weaponAttributes for a cosmetic entry");
        var parts = new List<AppearancePart>();
        var seen = new HashSet<int>();
        foreach (var value in root.GetProperty("parts").EnumerateArray())
        {
            if (!Parts.TryGetValue(RequiredText(value, "part"), out int part))
                throw new FormatException("Unknown appearance part");
            if ((kind == AppearanceKind.Outfit) != (part <= 5))
                throw new FormatException("Part belongs to a different appearance kind");
            if (!seen.Add(part)) throw new FormatException("Duplicate part in appearance manifest");
            parts.Add(new(part, ResourcePath(RequiredText(value, "catalog"), ".user"),
                ResourcePath(RequiredText(value, "prefab"), ".pfb")));
        }
        if (parts.Count == 0) throw new FormatException("At least one part is required");
        return new(id, name, kind, parts.AsReadOnly(), source,
            OptionalText(root, "description", 4096), OptionalText(root, "author", 256), OptionalIcon(root));
    }

    private static string OptionalText(JsonElement root, string name, int limit)
    {
        if (!root.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.String) return "";
        var text = value.GetString()?.Trim() ?? "";
        return text.Length <= limit ? text : text[..limit];
    }

    private static string? OptionalIcon(JsonElement root)
    {
        var icon = OptionalText(root, "icon", 1024).Replace('\\', '/');
        if (icon.Length == 0 || icon.StartsWith('/') || icon.Contains(':') ||
            icon.Split('/').Any(segment => segment is "" or "." or "..")) return null;
        var extension = Path.GetExtension(icon);
        return extension.Equals(".png", StringComparison.OrdinalIgnoreCase) ||
            extension.Equals(".jpg", StringComparison.OrdinalIgnoreCase) ||
            extension.Equals(".jpeg", StringComparison.OrdinalIgnoreCase) ? icon : null;
    }

    public static RegistrySnapshot ReadDirectory(string directory)
    {
        if (!Directory.Exists(directory))
            return new(new Dictionary<string, AppearanceEntry>(StringComparer.OrdinalIgnoreCase), Array.Empty<RegistryIssue>());
        return Build(Directory.EnumerateFiles(directory, "manifest.json", SearchOption.AllDirectories)
            .Order(StringComparer.OrdinalIgnoreCase)
            .Select(path => (Source: path, Read: (Func<string>)(() => File.ReadAllText(path)))));
    }

    public static RegistrySnapshot Build(IEnumerable<(string Source, Func<string> Read)> files)
    {
        var parsed = new List<AppearanceEntry>();
        var issues = new List<RegistryIssue>();
        foreach (var file in files)
        {
            try { parsed.Add(Parse(file.Read(), file.Source)); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or
                FormatException or KeyNotFoundException or InvalidOperationException or OverflowException)
            { issues.Add(new(file.Source, e.Message)); }
        }
        var entries = new Dictionary<string, AppearanceEntry>(StringComparer.OrdinalIgnoreCase);
        foreach (var group in parsed.GroupBy(entry => entry.Id, StringComparer.OrdinalIgnoreCase))
        {
            // Reject every conflicting definition rather than picking a filesystem-order winner.
            if (group.Count() != 1)
            {
                foreach (var entry in group) issues.Add(new(entry.Source, "Duplicate MOD id: " + entry.Id));
                continue;
            }
            var single = group.Single();
            entries.Add(single.Id, single);
        }
        return new(new System.Collections.ObjectModel.ReadOnlyDictionary<string, AppearanceEntry>(entries), issues.AsReadOnly());
    }

    private static string RequiredText(JsonElement value, string property)
    {
        string? text = value.GetProperty(property).GetString()?.Trim();
        if (string.IsNullOrEmpty(text)) throw new FormatException(property + " is required");
        return text;
    }

    private static string ResourcePath(string path, string suffix)
    {
        path = path.Replace('\\', '/');
        if (path.StartsWith('/') || path.Contains(':') || path.Contains('@') ||
            path.Split('/').Any(segment => segment is "" or "." or "..") ||
            path.Any(char.IsControl) || !path.EndsWith(suffix, StringComparison.OrdinalIgnoreCase))
            throw new FormatException("Expected a relative logical " + suffix + " resource path without a numeric version suffix");
        return path;
    }
}

/// <summary>Two independent cosmetic choices. Actual weapon identity and attributes remain owned by the game.</summary>
public sealed class AppearanceChoices
{
    public string? Outfit { get; private set; }
    public string? Weapon { get; private set; }

    public void Choose(AppearanceKind kind, string? id, RegistrySnapshot registry)
    {
        if (id != null)
        {
            if (!registry.Entries.TryGetValue(id, out var entry) || entry.Kind != kind)
                throw new InvalidOperationException("Appearance entry is missing or has a different kind");
            id = entry.Id;
        }
        if (kind == AppearanceKind.Outfit) Outfit = id;
        else if (kind == AppearanceKind.Weapon) Weapon = id;
        else throw new ArgumentOutOfRangeException(nameof(kind));
    }
}
