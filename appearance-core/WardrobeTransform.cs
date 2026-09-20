using System;
using System.Collections.Generic;
using System.Linq;

namespace OWOTS.Appearance;

/// <summary>
/// Owns the per-transformation snapshot. The adapter calls Lock once when a
/// transformation starts; later expectation edits only affect the next Lock.
/// Resource ownership, readiness and native entry/exit timing stay adapter-side.
/// </summary>
public sealed class WardrobeTransformSnapshotStore
{
    private readonly object gate = new();
    private WardrobeTransformPlan? current;

    public WardrobeTransformPlan? Current { get { lock (gate) return current; } }

    public WardrobeTransformPlan Lock(WardrobeSelectionState expectation, WardrobeRegistrySnapshot registry)
    {
        ArgumentNullException.ThrowIfNull(expectation);
        ArgumentNullException.ThrowIfNull(registry);
        var resolved = WardrobeSelections.Resolve(expectation, registry);
        var plan = resolved.Transform?.Plan ?? throw new ArgumentException("Transform resolution is unavailable");
        lock (gate) current = plan;
        return plan;
    }

    /// <summary>True when the current expectation would solve differently than the snapshot.</summary>
    public bool IsPending(WardrobeSelectionState expectation, WardrobeRegistrySnapshot registry)
    {
        var locked = Current;
        if (locked == null) return false;
        var resolved = WardrobeSelections.Resolve(expectation, registry);
        return !Same(locked, resolved.Transform?.Plan);
    }

    public void Clear() { lock (gate) current = null; }

    private static bool Same(WardrobeTransformPlan? left, WardrobeTransformPlan? right) =>
        left != null && right != null && left.Policy == right.Policy && left.EntryId == right.EntryId &&
        left.HiddenParts.SequenceEqual(right.HiddenParts, StringComparer.Ordinal);
}
