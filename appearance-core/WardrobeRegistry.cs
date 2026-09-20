using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace OWOTS.Appearance;

public sealed record WardrobeRegistrySnapshot(IReadOnlyDictionary<string, WardrobeManifestEntry> Entries,
    IReadOnlyList<RegistryIssue> Issues);

/// <summary>Schema 4 registry. Older manifests are reported for re-conversion, never read.</summary>
public static class WardrobeRegistry
{
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
        if (root["schemaVersion"]?.GetValue<int>() != WardrobeManifest.SchemaVersion) return json;
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
        if (!values.TryGetValue("wardrobe." + root["category"]!.GetValue<string>(), out var fields)) return root.ToJsonString();
        if (fields.TryGetValue("id", out var id) && id != root["id"]!.GetValue<string>())
            throw new FormatException("modinfo wardrobe ID differs from generated asset configuration; export again");
        bool Flag(string key) => fields.TryGetValue(key, out var value) && bool.Parse(value);
        var rules = root["rules"] as JsonObject ?? new JsonObject();
        // An explicit INI declaration replaces the generated declaration of that field only;
        // undeclared fields keep the manifest value (never a wholesale rules replacement).
        if (fields.Keys.Any(key => key is "hide_head" or "hide_hair")) {
            var hidden = new JsonArray();
            if (Flag("hide_head")) hidden.Add("HEAD");
            if (Flag("hide_hair")) hidden.Add("HAIR");
            rules["hideParts"] = hidden;
        }
        if (fields.Keys.Any(key => key is "incompatible_cloak" or "incompatible_gauntlet")) {
            var incompatible = new JsonArray();
            if (Flag("incompatible_cloak")) incompatible.Add("cloak");
            if (Flag("incompatible_gauntlet")) incompatible.Add("gauntlet");
            rules["incompatibleCategories"] = incompatible;
        }
        if (rules.Count > 0) root["rules"] = rules;
        return root.ToJsonString();
    }

    public static WardrobeRegistrySnapshot Build(IEnumerable<(string Source, Func<string> Read)> files)
    {
        var parsed = new List<(string Source, WardrobeManifestEntry Entry)>();
        var issues = new List<RegistryIssue>();
        foreach (var file in files) {
            try {
                var json = file.Read();
                using var document = JsonDocument.Parse(json);
                int version = document.RootElement.GetProperty("schemaVersion").GetInt32();
                if (version != WardrobeManifest.SchemaVersion) {
                    issues.Add(new(file.Source, "Appearance manifest schemaVersion " + version +
                        " is no longer read; re-convert this appearance"));
                    continue;
                }
                parsed.Add((file.Source, WardrobeManifest.Parse(json, file.Source)));
            } catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or
                FormatException or KeyNotFoundException or InvalidOperationException or OverflowException or ArgumentException) {
                issues.Add(new(file.Source, e.Message));
            }
        }
        var owners = new Dictionary<string, List<int>>(StringComparer.OrdinalIgnoreCase);
        for (int index = 0; index < parsed.Count; index++) {
            var id = parsed[index].Entry.Rules.Id;
            if (!owners.TryGetValue(id, out var list)) owners.Add(id, list = new List<int>());
            list.Add(index);
        }
        var rejected = new HashSet<int>();
        foreach (var pair in owners.Where(pair => pair.Value.Count > 1))
            foreach (int index in pair.Value) {
                rejected.Add(index);
                issues.Add(new(parsed[index].Source, "Duplicate MOD or entry id: " + pair.Key));
            }
        var entries = new Dictionary<string, WardrobeManifestEntry>(StringComparer.OrdinalIgnoreCase);
        for (int index = 0; index < parsed.Count; index++) {
            if (rejected.Contains(index)) continue;
            entries.Add(parsed[index].Entry.Rules.Id, parsed[index].Entry);
        }
        return new(new ReadOnlyDictionary<string, WardrobeManifestEntry>(entries), issues.AsReadOnly());
    }
}
