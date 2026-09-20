using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Text.Json.Serialization;

namespace OWOTS.Appearance;

// A value references exactly one registry entry; null means "native". Missing packages
// are reported at resolution time without erasing the saved intent.
public sealed record WardrobeEquipState(string DeclaringBodyId,
    IReadOnlyDictionary<WardrobeCategory, string?> PreviousSelections,
    IReadOnlyList<WardrobeCategory> Overridden);
public sealed record WardrobeSelectionState(IReadOnlyDictionary<WardrobeCategory, string?> Requested,
    WardrobeVisibilityOptions Visibility,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] WardrobeEquipState? Equipment = null);
public sealed record WardrobeSelectionResolution(WardrobeCompositionResult Composition, IReadOnlyList<string> Issues,
    bool IncompleteDeclaredEquipment = false,
    WardrobeTransformResolution? Transform = null);

public static class WardrobeSelections
{
    /// <summary>Fresh state with every category on native and the transform switch on.</summary>
    public static WardrobeSelectionState Empty()
    {
        var requested = new Dictionary<WardrobeCategory, string?>();
        foreach (var category in Enum.GetValues<WardrobeCategory>()) requested[category] = null;
        return new(new ReadOnlyDictionary<WardrobeCategory, string?>(requested),
            new(Array.Empty<WardrobeCategory>(), Array.Empty<WardrobeVisibilityOverride>()));
    }

    public static WardrobeSelectionState Choose(WardrobeSelectionState state, WardrobeCategory category,
        string? entryId, WardrobeRegistrySnapshot registry)
    {
        if (!Enum.IsDefined(category)) throw new ArgumentException("Unknown category");
        if (entryId != null && (!registry.Entries.TryGetValue(entryId, out var entry) || entry.Rules.Category != category))
            throw new InvalidOperationException("Missing or wrong-category entry");
        var requested = state.Requested.ToDictionary(pair => pair.Key, pair => pair.Value);
        var equipment = state.Equipment;
        if (category == WardrobeCategory.Body) {
            // Withdraw only this body's defaults. Later explicit user choices survive.
            if (equipment != null)
                foreach (var previous in equipment.PreviousSelections)
                    if (!equipment.Overridden.Contains(previous.Key)) requested[previous.Key] = previous.Value;
            equipment = null;
            if (entryId != null && registry.Entries[entryId].Rules.Equip is { Count: > 0 } equip) {
                var previous = new Dictionary<WardrobeCategory, string?>();
                foreach (var pair in equip) {
                    if (!registry.Entries.TryGetValue(pair.Value, out var accessory) || accessory.Rules.Category != pair.Key)
                        throw new InvalidOperationException("Missing or wrong-category declared accessory: " + pair.Value);
                    requested.TryGetValue(pair.Key, out var beforeAccessory);
                    previous[pair.Key] = beforeAccessory;
                    requested[pair.Key] = pair.Value;
                }
                equipment = new(entryId, new ReadOnlyDictionary<WardrobeCategory, string?>(previous),
                    Array.Empty<WardrobeCategory>());
            }
        } else if (equipment != null && equipment.PreviousSelections.ContainsKey(category)) {
            equipment = equipment with { Overridden = Array.AsReadOnly(equipment.Overridden.Append(category).Distinct().ToArray()) };
        }
        requested[category] = entryId;
        var before = Resolve(state, registry).Composition;
        before.Effective.TryGetValue(category, out var previousDeclaringId);
        // Changing a category is a new choice and cannot silently carry its old force approval.
        return new(new ReadOnlyDictionary<WardrobeCategory, string?>(requested), state.Visibility with {
            ConfirmedOverrides = Array.AsReadOnly(state.Visibility.ConfirmedOverrides.Where(grant =>
                grant.Category != category && grant.DeclaringId != previousDeclaringId).ToArray()) }, equipment);
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
        var requests = state.Requested.ToDictionary(pair => pair.Key, pair => pair.Value);
        bool incompleteEquipment = false;
        if (state.Equipment is { } equipment) {
            if (!registry.Entries.TryGetValue(equipment.DeclaringBodyId, out var declaring) || declaring.Rules.Category != WardrobeCategory.Body) {
                // Inactive/missing bodies cannot keep imposing accessory defaults. Stored intent stays intact.
                foreach (var previous in equipment.PreviousSelections)
                    if (!equipment.Overridden.Contains(previous.Key)) requests[previous.Key] = previous.Value;
            } else foreach (var category in equipment.PreviousSelections.Keys.Where(category => !equipment.Overridden.Contains(category))) {
                requests.TryGetValue(category, out var choice);
                if (choice == null || !registry.Entries.TryGetValue(choice, out var accessory) || accessory.Rules.Category != category) {
                    incompleteEquipment = true;
                    issues.Add("Missing declared accessory for " + equipment.DeclaringBodyId + ": " + (choice ?? category.ToString()));
                }
            }
        }
        foreach (var pair in requests) {
            if (pair.Key == WardrobeCategory.Transform) continue;
            if (!Enum.IsDefined(pair.Key)) throw new ArgumentException("Unknown saved category");
            resolved[pair.Key] = pair.Value;
        }
        var composition = WardrobeComposition.Resolve(resolved,
            registry.Entries.ToDictionary(pair => pair.Key, pair => pair.Value.Rules), state.Visibility);
        issues.AddRange(composition.Issues);
        // The transform domain is solved independently: its problems delay neither the
        // normal-state apply nor the game's own transformation.
        requests.TryGetValue(WardrobeCategory.Transform, out var transformChoice);
        var transform = WardrobeComposition.ResolveTransform(transformChoice,
            registry.Entries.ToDictionary(pair => pair.Key, pair => pair.Value.Rules));
        return new(composition, issues.AsReadOnly(), incompleteEquipment, transform);
    }
}
