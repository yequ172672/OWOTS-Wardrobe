using System.Collections.Generic;

namespace OWOTS.Appearance;

/// <summary>Native menu closing applies settings even without a user decision.</summary>
public sealed class NativeCostumeSelections
{
    // Values describe our two appearance groups, not native PARTS_TYPE or CATEGORY numbers.
    public const int Outfit = 1, Weapon = 2;
    private readonly Dictionary<ulong, int> decisions = new();
    private readonly object gate = new();
    public void Open(ulong menu)
    {
        lock (gate)
        {
            if (decisions.Count >= 128) decisions.Clear();
            decisions[menu] = 0;
        }
    }
    public bool Confirm(ulong menu, int nativeCategory)
    {
        int group = nativeCategory switch { 0 => Weapon, 1 or 2 or 3 => Outfit, _ => 0 };
        lock (gate)
        {
            if (group == 0 || !decisions.TryGetValue(menu, out var previous)) return false;
            decisions[menu] = previous | group;
            return true;
        }
    }
    public int ConsumeApplied(ulong menu)
    {
        lock (gate)
        {
            if (!decisions.TryGetValue(menu, out var result)) return 0;
            decisions[menu] = 0;
            return result;
        }
    }
    public void Close(ulong menu) { lock (gate) decisions.Remove(menu); }
    public void Clear() { lock (gate) decisions.Clear(); }
}
