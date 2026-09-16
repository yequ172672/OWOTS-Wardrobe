using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;

namespace OWOTS.Appearance;

// A legacy reference resolves per category. This preserves a missing package without
// guessing which optional parts it contained, or clearing other categories on a manual change.
public sealed record WardrobeSelection(string? EntryId, string? LegacyBundleId);
public sealed record WardrobeSelectionState(IReadOnlyDictionary<WardrobeCategory, WardrobeSelection?> Requested,
    WardrobeVisibilityOptions Visibility);
public sealed record WardrobeSelectionResolution(WardrobeCompositionResult Composition, IReadOnlyList<string> Issues);

public static class WardrobeSelections
{
    public static WardrobeSelectionState FromLegacy(SavedAppearance saved)
    {
        var requested = new Dictionary<WardrobeCategory, WardrobeSelection?>();
        foreach (var category in Enum.GetValues<WardrobeCategory>()) {
            var id = category == WardrobeCategory.Weapon ? saved.Weapon : saved.Outfit;
            requested[category] = id == null ? null : new(null, id);
        }
        return new(new ReadOnlyDictionary<WardrobeCategory, WardrobeSelection?>(requested),
            new(Array.Empty<WardrobeCategory>(), Array.Empty<WardrobeVisibilityOverride>()));
    }

    public static WardrobeSelectionState Choose(WardrobeSelectionState state, WardrobeCategory category,
        string? entryId, WardrobeRegistrySnapshot registry)
    {
        if (!Enum.IsDefined(category)) throw new ArgumentException("Unknown category");
        if (entryId != null && (!registry.Entries.TryGetValue(entryId, out var entry) || entry.Rules.Category != category))
            throw new InvalidOperationException("Missing or wrong-category entry");
        var requested = state.Requested.ToDictionary(pair => pair.Key, pair => pair.Value);
        requested[category] = entryId == null ? null : new(entryId, null);
        var before = Resolve(state, registry).Composition;
        before.Effective.TryGetValue(category, out var previousDeclaringId);
        // Changing a category is a new choice and cannot silently carry its old force approval.
        return new(new ReadOnlyDictionary<WardrobeCategory, WardrobeSelection?>(requested), state.Visibility with {
            ConfirmedOverrides = Array.AsReadOnly(state.Visibility.ConfirmedOverrides.Where(grant =>
                grant.Category != category && grant.DeclaringId != previousDeclaringId).ToArray()) });
    }

    public static WardrobeSelectionState SetVisible(WardrobeSelectionState state, WardrobeCategory category, bool visible)
    {
        Accessory(category);
        var disabled = state.Visibility.Disabled.ToHashSet();
        if (visible) disabled.Remove(category); else disabled.Add(category);
        return state with { Visibility = new(Array.AsReadOnly(disabled.Order().ToArray()),
            Array.AsReadOnly(state.Visibility.ConfirmedOverrides.Where(grant => visible || grant.Category != category).ToArray())) };
    }

    public static IReadOnlyList<string> RequiredForceDeclarations(WardrobeSelectionState state,
        WardrobeCategory category, WardrobeRegistrySnapshot registry)
    {
        Accessory(category);
        if (state.Visibility.Disabled.Contains(category)) return Array.Empty<string>();
        var result = new List<string>();
        var simulated = state;
        // Several active declarations can independently block one accessory. A single approval
        // must name all of them, not remove whichever blocker happens to be encountered first.
        while (Resolve(simulated, registry).Composition.Suppressed.TryGetValue(category, out var blocker)) {
            if (result.Contains(blocker) || !registry.Entries.ContainsKey(blocker))
                throw new InvalidOperationException("Cannot resolve accessory override");
            result.Add(blocker);
            simulated = simulated with { Visibility = simulated.Visibility with {
                ConfirmedOverrides = Array.AsReadOnly(simulated.Visibility.ConfirmedOverrides.Append(new(category, blocker)).ToArray()) } };
        }
        return result.AsReadOnly();
    }

    public static WardrobeSelectionState ConfirmForce(WardrobeSelectionState state, WardrobeCategory category,
        IReadOnlyList<string> confirmedDeclarations, WardrobeRegistrySnapshot registry)
    {
        var required = RequiredForceDeclarations(state, category, registry);
        if (required.Count == 0 || confirmedDeclarations.Count != required.Count ||
            !required.Order(StringComparer.Ordinal).SequenceEqual(confirmedDeclarations.Order(StringComparer.Ordinal)))
            throw new InvalidOperationException("Declaration changed or confirmation does not match current blockers");
        return state with { Visibility = state.Visibility with {
            ConfirmedOverrides = Array.AsReadOnly(state.Visibility.ConfirmedOverrides.Concat(
                required.Select(id => new WardrobeVisibilityOverride(category, id))).ToArray()) } };
    }

    private static void Accessory(WardrobeCategory category)
    {
        if (category is not (WardrobeCategory.Cloak or WardrobeCategory.Gauntlet))
            throw new ArgumentException("Only cloak and gauntlet have a visibility/force control");
    }

    public static WardrobeSelectionResolution Resolve(WardrobeSelectionState state, WardrobeRegistrySnapshot registry)
    {
        var resolved = new Dictionary<WardrobeCategory, string?>();
        var issues = new List<string>();
        foreach (var pair in state.Requested) {
            if (!Enum.IsDefined(pair.Key)) throw new ArgumentException("Unknown saved category");
            var selection = pair.Value;
            if (selection == null) { resolved[pair.Key] = null; continue; }
            if ((selection.EntryId == null) == (selection.LegacyBundleId == null))
                throw new ArgumentException("Choice must reference exactly one entry or legacy bundle");
            if (selection.EntryId != null) { resolved[pair.Key] = selection.EntryId; continue; }
            if (!registry.LegacyBundles.TryGetValue(selection.LegacyBundleId!, out var bundle)) {
                issues.Add("Missing legacy bundle for " + pair.Key + ": " + selection.LegacyBundleId);
                resolved[pair.Key] = null;
                continue;
            }
            bool weapon = pair.Key == WardrobeCategory.Weapon;
            if (weapon != (bundle.Kind == AppearanceKind.Weapon)) {
                issues.Add("Wrong-kind legacy bundle: " + selection.LegacyBundleId);
                resolved[pair.Key] = null;
                continue;
            }
            // An installed body-only legacy package intentionally has no cloak/gauntlet entry.
            resolved[pair.Key] = bundle.Selections.TryGetValue(pair.Key, out var id) ? id : null;
        }
        var composition = WardrobeComposition.Resolve(resolved,
            registry.Entries.ToDictionary(pair => pair.Key, pair => pair.Value.Rules), state.Visibility);
        issues.AddRange(composition.Issues);
        return new(composition, issues.AsReadOnly());
    }
}
