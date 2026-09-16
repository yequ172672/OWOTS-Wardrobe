using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace OWOTS.Appearance;

// The adapter supplies an identity only after a verified native save/load event.
// These fields are not inferred from the latest file, a pointer, or current equipment.
public sealed record AppearanceSaveKey(int UserIndex, int Slot, uint UniqueId);
public sealed record SavedAppearance(string? Outfit, string? Weapon);
public sealed record AppearanceSaveRecord(int SchemaVersion, AppearanceSaveKey Key, SavedAppearance Choices);
public sealed record AppearanceSaveRead(AppearanceSaveRecord? Record, string? Error);
public enum AppearanceSavePhase { Prepare, WritePrepared, WriteCurrent }

public sealed record AppearanceLoadTicket(long Sequence, AppearanceSaveKey Key);

/// <summary>Only the most recently started load may publish a restoration request.</summary>
public sealed class AppearanceLoadCoordinator
{
    private readonly object gate = new();
    private long latest;
    private AppearanceLoadTicket? observed, pending;
    public AppearanceLoadTicket? Observed { get { lock (gate) return observed; } }
    public bool HasPending { get { lock (gate) return pending != null; } }
    public void Begin(long sequence)
    {
        lock (gate)
        {
            if (sequence <= latest) throw new ArgumentException("Load sequence must increase");
            latest = sequence;
            observed = pending = null;
        }
    }
    public bool Complete(long sequence, AppearanceSaveKey key, bool automatic)
    {
        lock (gate)
        {
            if (sequence != latest || observed != null) return false;
            observed = new(sequence, key);
            if (automatic) pending = observed;
            return true;
        }
    }
    public AppearanceLoadTicket QueueObserved()
    {
        lock (gate)
        {
            if (observed == null) throw new InvalidOperationException("No successful load observed in this plugin session");
            return pending = observed;
        }
    }
    public AppearanceLoadTicket? TakePending()
    {
        lock (gate) { var result = pending; pending = null; return result; }
    }
    public void ClearPending() { lock (gate) pending = null; }
    public bool IsCurrent(AppearanceLoadTicket ticket)
    {
        lock (gate) return ticket == observed && ticket.Sequence == latest;
    }
}

/// <summary>Correlates native attempts without reading current choices at completion time.</summary>
public sealed record AppearanceSnapshot<T>(AppearanceSaveKey Key, T Choices);
public sealed class AppearanceSaveTransactions<T>
{
    private sealed record Attempt(AppearanceSaveKey Key, T Choices, AppearanceSavePhase Phase);
    private readonly Dictionary<long, Attempt> pending = new();
    private readonly Dictionary<AppearanceSaveKey, T> prepared = new();
    private readonly Dictionary<AppearanceSaveKey, long> latestPreparation = new();
    private readonly object gate = new();

    public bool Begin(long sequence, AppearanceSaveKey key, T choices, AppearanceSavePhase phase)
    {
        lock (gate)
        {
            if (pending.ContainsKey(sequence)) throw new InvalidOperationException("Duplicate save attempt");
            if (pending.Count >= 128 || latestPreparation.Count >= 128 && !latestPreparation.ContainsKey(key))
                throw new InvalidOperationException("Too many unresolved save attempts");
            if (phase == AppearanceSavePhase.WritePrepared)
            {
                if (!prepared.TryGetValue(key, out var snapshot)) return false;
                choices = snapshot;
            }
            else if (phase == AppearanceSavePhase.Prepare)
            {
                prepared.Remove(key);
                latestPreparation[key] = sequence;
            }
            else if (phase != AppearanceSavePhase.WriteCurrent) throw new ArgumentOutOfRangeException(nameof(phase));
            pending.Add(sequence, new(key, choices, phase));
            return true;
        }
    }

    public AppearanceSnapshot<T>? Complete(long sequence, bool success)
    {
        lock (gate)
        {
            if (!pending.Remove(sequence, out var attempt)) return null;
            if (!success) return null;
            if (attempt.Phase == AppearanceSavePhase.Prepare)
            {
                if (latestPreparation.TryGetValue(attempt.Key, out var latest) && latest == sequence)
                    prepared[attempt.Key] = attempt.Choices;
                return null;
            }
            return new(attempt.Key, attempt.Choices);
        }
    }
}
public sealed class AppearanceSaveTransactions
{
    private readonly AppearanceSaveTransactions<SavedAppearance> inner = new();
    public bool Begin(long sequence, AppearanceSaveKey key, SavedAppearance choices, AppearanceSavePhase phase) =>
        inner.Begin(sequence, key, choices, phase);
    public AppearanceSaveRecord? Complete(long sequence, bool success)
    {
        var result = inner.Complete(sequence, success);
        return result == null ? null : new(1, result.Key, result.Choices);
    }
}
public sealed record AppearanceRestoreIssue(AppearanceKind Kind, string ModId, string Reason);
public sealed record AppearanceRestorePlan(SavedAppearance Available, IReadOnlyList<AppearanceRestoreIssue> Issues)
{
    // Plan the two groups independently. Do not overwrite the saved intent when a MOD is unavailable.
    public static AppearanceRestorePlan Create(SavedAppearance saved, RegistrySnapshot registry)
    {
        ArgumentNullException.ThrowIfNull(saved);
        ArgumentNullException.ThrowIfNull(registry);
        var issues = new List<AppearanceRestoreIssue>();
        string? Resolve(AppearanceKind kind, string? id)
        {
            if (id == null) return null;
            if (!registry.Entries.TryGetValue(id, out var entry))
            {
                issues.Add(new(kind, id, "外观未安装或描述文件被拒绝，使用原版外观"));
                return null;
            }
            if (entry.Kind != kind)
            {
                issues.Add(new(kind, id, "外观类型与存档记录不一致，使用原版外观"));
                return null;
            }
            return entry.Id;
        }
        string? outfit = Resolve(AppearanceKind.Outfit, saved.Outfit);
        string? weapon = Resolve(AppearanceKind.Weapon, saved.Weapon);
        return new(new(outfit, weapon), issues.AsReadOnly());
    }
}

/// <summary>Keeps unavailable selections until the user explicitly changes that group.</summary>
public sealed class UnavailableAppearanceIntent
{
    private string? outfit, weapon;
    private readonly object gate = new();
    public UnavailableAppearanceIntent(AppearanceRestorePlan plan)
    {
        foreach (var issue in plan.Issues)
            if (issue.Kind == AppearanceKind.Outfit) outfit = issue.ModId;
            else if (issue.Kind == AppearanceKind.Weapon) weapon = issue.ModId;
    }
    public SavedAppearance ForSave(SavedAppearance current)
    {
        lock (gate) return new(current.Outfit ?? outfit, current.Weapon ?? weapon);
    }
    public void Forget(AppearanceKind? kind)
    {
        lock (gate)
        {
            if (kind == null || kind == AppearanceKind.Outfit) outfit = null;
            if (kind == null || kind == AppearanceKind.Weapon) weapon = null;
        }
    }
}

/// <summary>Private sidecar storage; never reads or writes native save files.</summary>
public sealed class AppearanceSaveStore
{
    private readonly string directory;
    public AppearanceSaveStore(string directory) => this.directory = Path.GetFullPath(directory);

    internal string RecordPath(AppearanceSaveKey key)
    {
        ArgumentNullException.ThrowIfNull(key);
        if (key.UserIndex < 0 || key.UserIndex > 127 || key.UniqueId == 0 ||
            !(key.Slot is >= 1 and <= 20 or 101))
            throw new ArgumentException("Unverified or invalid OWOTS save identity", nameof(key));
        return Path.Combine(directory, $"u{key.UserIndex}-s{key.Slot}-id{key.UniqueId:x8}.json");
    }

    private static void ValidateChoices(SavedAppearance choices)
    {
        ArgumentNullException.ThrowIfNull(choices);
        foreach (var id in new[] { choices.Outfit, choices.Weapon })
            if (id != null && !Regex.IsMatch(id, "^[a-z0-9][a-z0-9._-]{0,127}$"))
                throw new FormatException("Invalid saved MOD identity");
    }

    public AppearanceSaveRead Read(AppearanceSaveKey key)
    {
        string path = RecordPath(key);
        try
        {
            // Missing records mean no known selection; corrupted records remain distinguishable.
            string text = File.ReadAllText(path);
            var record = JsonSerializer.Deserialize<AppearanceSaveRecord>(text);
            if (record == null || record.SchemaVersion != 1 || record.Key != key || record.Choices == null)
                return new(null, "Appearance save identity or schema mismatch");
            ValidateChoices(record.Choices);
            return new(record, null);
        }
        catch (FileNotFoundException) { return new(null, null); }
        catch (DirectoryNotFoundException) { return new(null, null); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or FormatException)
        { return new(null, e.Message); }
    }

    public void Write(AppearanceSaveKey key, SavedAppearance choices)
    {
        string path = RecordPath(key);
        ValidateChoices(choices);
        Directory.CreateDirectory(directory);
        string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            byte[] data = JsonSerializer.SerializeToUtf8Bytes(new AppearanceSaveRecord(1, key, choices));
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(data);
                stream.Flush(true);
            }
            // Same-directory rename publishes a complete record rather than truncating the previous one.
            File.Move(temporary, path, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
