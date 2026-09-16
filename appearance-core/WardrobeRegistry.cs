using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace OWOTS.Appearance;

public sealed record LegacyWardrobeBundle(AppearanceKind Kind,
    IReadOnlyDictionary<WardrobeCategory, string> Selections);
public sealed record WardrobeRegistrySnapshot(IReadOnlyDictionary<string, WardrobeManifestEntry> Entries,
    IReadOnlyDictionary<string, LegacyWardrobeBundle> LegacyBundles, IReadOnlyList<RegistryIssue> Issues);

/// <summary>Read-only v1 projection and v2 registry. Never rewrites a MOD manifest or save.</summary>
public static class WardrobeRegistry
{
    private sealed record Package(string Source, string Id, WardrobeManifestEntry[] Entries, LegacyWardrobeBundle? Legacy);
    private static readonly Dictionary<int, string> PartNames = new() {
        [0] = "BODY", [1] = "BODY_SUB", [2] = "HEAD", [3] = "HAIR", [4] = "GAUNTLET", [5] = "CLOAK",
        [6] = "WEAPON", [7] = "SHEATH", [8] = "WEAPON_SUB", [9] = "SHEATH_SUB", [12] = "BOW" };

    public static WardrobeRegistrySnapshot ReadDirectory(string directory) => Build(
        Directory.Exists(directory) ? Directory.EnumerateFiles(directory, "manifest.json", SearchOption.AllDirectories)
            .Order(StringComparer.OrdinalIgnoreCase).Select(path => (path, (Func<string>)(() => ReadPackage(path)))) :
            Array.Empty<(string, Func<string>)>());

    private static string ReadPackage(string path)
    {
        var json = File.ReadAllText(path);
        var ini = Path.Combine(Path.GetDirectoryName(path)!, "modinfo.ini");
        if (!File.Exists(ini)) return json;
        return ApplyModInfo(json, File.ReadAllText(ini));
    }

    public static string ApplyModInfo(string json, string text)
    {
        var root = JsonNode.Parse(json)!.AsObject();
        if (root["schemaVersion"]?.GetValue<int>() != 2) return json;
        var values = new Dictionary<string, Dictionary<string, string>>(StringComparer.OrdinalIgnoreCase);
        string section = "modinfo";
        values[section] = new(StringComparer.OrdinalIgnoreCase);
        foreach (var raw in text.TrimStart('\uFEFF').Split('\n')) {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith(';') || line.StartsWith('#')) continue;
            if (line.StartsWith('[') && line.EndsWith(']')) {
                section = line[1..^1];
                if (!values.TryAdd(section, new(StringComparer.OrdinalIgnoreCase)))
                    throw new FormatException("Duplicate modinfo section: " + section);
                continue;
            }
            var equal = line.IndexOf('=');
            if (equal < 1) throw new FormatException("Invalid modinfo line");
            if (!values[section].TryAdd(line[..equal].Trim(), line[(equal + 1)..].Trim()))
                throw new FormatException("Duplicate modinfo key");
        }
        var common = values["modinfo"];
        foreach (var key in new[] { "name", "description", "author" })
            if (common.TryGetValue(key, out var value)) root[key] = value;
        if (values.TryGetValue("wardrobe." + root["category"]!.GetValue<string>(), out var fields)) {
            if (fields.TryGetValue("id", out var id) && id != root["id"]!.GetValue<string>())
                throw new FormatException("modinfo wardrobe ID differs from generated asset configuration; export again");
            bool Flag(string key) => fields.TryGetValue(key, out var value) && bool.Parse(value);
            var hidden = new JsonArray();
            if (Flag("hide_head")) hidden.Add("HEAD");
            if (Flag("hide_hair")) hidden.Add("HAIR");
            var incompatible = new JsonArray();
            if (Flag("incompatible_cloak")) incompatible.Add("cloak");
            if (Flag("incompatible_gauntlet")) incompatible.Add("gauntlet");
            root["rules"] = new JsonObject { ["hideParts"] = hidden, ["incompatibleCategories"] = incompatible };
        }
        return root.ToJsonString();
    }

    public static WardrobeRegistrySnapshot Build(IEnumerable<(string Source, Func<string> Read)> files)
    {
        var packages = new List<Package>();
        var issues = new List<RegistryIssue>();
        foreach (var file in files) {
            try {
                var json = file.Read();
                using var document = JsonDocument.Parse(json);
                int version = document.RootElement.GetProperty("schemaVersion").GetInt32();
                if (version == 1) packages.Add(ProjectLegacy(AppearanceRegistry.Parse(json, file.Source)));
                else {
                    var entry = WardrobeManifest.Parse(json, file.Source);
                    packages.Add(new(file.Source, entry.Rules.Id, new[] { entry }, null));
                }
            } catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or
                FormatException or KeyNotFoundException or InvalidOperationException or OverflowException or ArgumentException) {
                issues.Add(new(file.Source, e.Message));
            }
        }
        var rejected = new HashSet<int>();
        var owners = new Dictionary<string, List<int>>(StringComparer.OrdinalIgnoreCase);
        for (int index = 0; index < packages.Count; index++)
            foreach (var id in packages[index].Entries.Select(entry => entry.Rules.Id).Append(packages[index].Id).Distinct()) {
                if (!owners.TryGetValue(id, out var list)) owners.Add(id, list = new List<int>());
                list.Add(index);
            }
        foreach (var pair in owners.Where(pair => pair.Value.Count > 1))
            foreach (int index in pair.Value) {
                rejected.Add(index);
                issues.Add(new(packages[index].Source, "Duplicate MOD or projected entry id: " + pair.Key));
            }
        var entries = new Dictionary<string, WardrobeManifestEntry>(StringComparer.OrdinalIgnoreCase);
        var legacy = new Dictionary<string, LegacyWardrobeBundle>(StringComparer.OrdinalIgnoreCase);
        for (int index = 0; index < packages.Count; index++) {
            if (rejected.Contains(index)) continue; // Never publish half a legacy outfit after an ID collision.
            var package = packages[index];
            foreach (var entry in package.Entries) entries.Add(entry.Rules.Id, entry);
            if (package.Legacy != null) legacy.Add(package.Id, package.Legacy);
        }
        return new(new ReadOnlyDictionary<string, WardrobeManifestEntry>(entries),
            new ReadOnlyDictionary<string, LegacyWardrobeBundle>(legacy), issues.AsReadOnly());
    }

    private static Package ProjectLegacy(AppearanceEntry old)
    {
        static WardrobeCategory Category(int part) => part switch {
            <= 3 => WardrobeCategory.Body, 4 => WardrobeCategory.Gauntlet,
            5 => WardrobeCategory.Cloak, _ => WardrobeCategory.Weapon };
        var groups = old.Parts.GroupBy(part => Category(part.Part)).OrderBy(group => group.Key).ToArray();
        var entries = new List<WardrobeManifestEntry>();
        var selections = new Dictionary<WardrobeCategory, string>();
        foreach (var group in groups) {
            // Retain the original ID on the first available category; all other IDs are path/name independent.
            var id = group.Key == groups[0].Key ? old.Id : "legacy." +
                Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(old.Id))).ToLowerInvariant() + "." + group.Key.ToString().ToLowerInvariant();
            var parts = group.Select(part => new WardrobePart(PartNames[part.Part], part.Catalog, part.Prefab)).ToArray();
            var rules = new WardrobeRuleEntry(id, group.Key, Array.AsReadOnly(parts.Select(part => part.Part).ToArray()),
                Array.Empty<string>(), Array.Empty<WardrobeCategory>());
            WardrobeComposition.Validate(rules);
            entries.Add(new(rules, old.Name, Array.AsReadOnly(parts), old.Description, old.Author, old.Icon, old.Source));
            selections.Add(group.Key, id);
        }
        return new(old.Source, old.Id, entries.ToArray(),
            new LegacyWardrobeBundle(old.Kind, new ReadOnlyDictionary<WardrobeCategory, string>(selections)));
    }
}
