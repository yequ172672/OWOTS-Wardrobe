using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Text.RegularExpressions;

namespace OWOTS.Appearance;

// Logical categories only. Native enum/asset mapping belongs to the game adapter.
public enum WardrobeCategory { Body, Cloak, Gauntlet, Weapon }
public sealed record WardrobeRuleEntry(string Id, WardrobeCategory Category,
    IReadOnlyList<string> ProvidedParts, IReadOnlyList<string> HiddenParts,
    IReadOnlyList<WardrobeCategory> IncompatibleCategories,
    IReadOnlyDictionary<WardrobeCategory, string>? Equip = null);
public sealed record WardrobeCompositionResult(
    IReadOnlyDictionary<WardrobeCategory, string?> Requested,
    IReadOnlyDictionary<WardrobeCategory, string> Effective,
    IReadOnlyDictionary<WardrobeCategory, string> Suppressed,
    IReadOnlyList<string> HiddenParts,
    IReadOnlyList<string> Issues);
// Grants are scoped to the declaring MOD ID, never a permanent global bypass.
public sealed record WardrobeVisibilityOverride(WardrobeCategory Category, string DeclaringId);
public sealed record WardrobeVisibilityOptions(IReadOnlyList<WardrobeCategory> Disabled,
    IReadOnlyList<WardrobeVisibilityOverride> ConfirmedOverrides);

/// <summary>Pure planning only: does not hide meshes, free resources or rewrite saved choices.</summary>
public static class WardrobeComposition
{
    private static readonly WardrobeCategory[] Priority = { WardrobeCategory.Body, WardrobeCategory.Cloak,
        WardrobeCategory.Gauntlet, WardrobeCategory.Weapon };
    private static readonly IReadOnlyDictionary<WardrobeCategory, string[]> CategoryParts =
        new Dictionary<WardrobeCategory, string[]> {
            [WardrobeCategory.Body] = new[] { "BODY", "BODY_SUB", "HEAD", "HAIR" },
            [WardrobeCategory.Cloak] = new[] { "CLOAK" },
            [WardrobeCategory.Gauntlet] = new[] { "GAUNTLET" },
            [WardrobeCategory.Weapon] = new[] { "WEAPON", "SHEATH", "WEAPON_SUB", "SHEATH_SUB", "BOW" }
        };

    public static WardrobeCompositionResult Resolve(IReadOnlyDictionary<WardrobeCategory, string?> requested,
        IReadOnlyDictionary<string, WardrobeRuleEntry> registry, WardrobeVisibilityOptions? visibility = null)
    {
        bool Accessory(WardrobeCategory category) => category is WardrobeCategory.Cloak or WardrobeCategory.Gauntlet;
        if (visibility != null && (visibility.Disabled.Any(category => !Accessory(category)) ||
            visibility.ConfirmedOverrides.Any(grant => !Accessory(grant.Category) || string.IsNullOrWhiteSpace(grant.DeclaringId))))
            throw new ArgumentException("Visibility controls only support cloak/gauntlet with explicit declaring IDs");
        bool Forced(WardrobeCategory category, string declaringId) =>
            visibility?.ConfirmedOverrides.Any(grant => grant.Category == category && grant.DeclaringId == declaringId) ?? false;
        foreach (var category in requested.Keys)
            if (!CategoryParts.ContainsKey(category)) throw new ArgumentException("Unknown category");
        var intent = new Dictionary<WardrobeCategory, string?>();
        var effective = new Dictionary<WardrobeCategory, string>();
        var suppressed = new Dictionary<WardrobeCategory, string>();
        var hidden = new HashSet<string>(StringComparer.Ordinal);
        var issues = new List<string>();
        var active = new List<WardrobeRuleEntry>();
        foreach (var category in Priority)
        {
            requested.TryGetValue(category, out var id);
            intent[category] = id;
            if (visibility?.Disabled.Contains(category) ?? false)
            {
                suppressed[category] = "@user";
                hidden.UnionWith(CategoryParts[category]);
                continue;
            }
            WardrobeRuleEntry? entry = null;
            if (id != null)
            {
                if (!registry.TryGetValue(id, out entry) || entry.Id != id || entry.Category != category)
                { issues.Add("Missing or wrong-category appearance: " + id); entry = null; }
                else Validate(entry);
            }
            var blocker = active.FirstOrDefault(other => !Forced(category, other.Id) &&
                (other.IncompatibleCategories.Contains(category) ||
                (Accessory(category) && other.HiddenParts.Any(CategoryParts[category].Contains)) ||
                (entry?.IncompatibleCategories.Contains(other.Category) ?? false)));
            if (blocker != null)
            {
                suppressed[category] = blocker.Id;
                // Suppression includes native fallback, even if the user selected no MOD here.
                hidden.UnionWith(CategoryParts[category]);
                continue;
            }
            if (entry == null) continue;
            effective[category] = entry.Id;
            active.Add(entry);
            hidden.UnionWith(entry.HiddenParts.Where(part =>
                !(part == "CLOAK" && Forced(WardrobeCategory.Cloak, entry.Id)) &&
                !(part == "GAUNTLET" && Forced(WardrobeCategory.Gauntlet, entry.Id))));
        }
        // A hidden part must never silently win over a separately selected provider.
        foreach (var entry in active)
            if (entry.ProvidedParts.Any(hidden.Contains))
                issues.Add("Provided part is hidden by another active entry: " + entry.Id);
        return new(new ReadOnlyDictionary<WardrobeCategory, string?>(intent),
            new ReadOnlyDictionary<WardrobeCategory, string>(effective),
            new ReadOnlyDictionary<WardrobeCategory, string>(suppressed),
            Array.AsReadOnly(hidden.Order(StringComparer.Ordinal).ToArray()), issues.AsReadOnly());
    }

    public static void Validate(WardrobeRuleEntry entry)
    {
        if (string.IsNullOrWhiteSpace(entry.Id) || !CategoryParts.ContainsKey(entry.Category))
            throw new ArgumentException("Invalid entry identity/category");
        if (entry.ProvidedParts.Count == 0 || entry.ProvidedParts.Distinct().Count() != entry.ProvidedParts.Count ||
            entry.ProvidedParts.Any(part => !CategoryParts[entry.Category].Contains(part)))
            throw new ArgumentException("Invalid provided parts");
        var known = CategoryParts.Values.SelectMany(parts => parts).ToHashSet(StringComparer.Ordinal);
        if (entry.HiddenParts.Any(part => !known.Contains(part) || entry.ProvidedParts.Contains(part)))
            throw new ArgumentException("Unknown hidden part or entry hides its own resource");
        if (entry.IncompatibleCategories.Any(category => !CategoryParts.ContainsKey(category) || category == entry.Category))
            throw new ArgumentException("Invalid incompatible category");
        if (entry.Equip != null) {
            if (entry.Category != WardrobeCategory.Body) throw new ArgumentException("Only body can declare accessory equip");
            foreach (var pair in entry.Equip) {
                if (pair.Key is not (WardrobeCategory.Cloak or WardrobeCategory.Gauntlet) ||
                    pair.Value == null || !Regex.IsMatch(pair.Value, "^[a-z0-9][a-z0-9._-]{0,127}$") ||
                    pair.Value == entry.Id || pair.Value.StartsWith("runtime.wardrobe.", StringComparison.Ordinal))
                    throw new ArgumentException("Invalid declared accessory reference");
                if (entry.IncompatibleCategories.Contains(pair.Key) || entry.HiddenParts.Any(CategoryParts[pair.Key].Contains))
                    throw new ArgumentException("Cannot equip and hide the same accessory category");
            }
        }
    }
}
