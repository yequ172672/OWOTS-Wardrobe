using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace OWOTS.Appearance;

public sealed record WardrobeSaveRecord(int SchemaVersion, AppearanceSaveKey Key, WardrobeSelectionState Choices);
public sealed record WardrobeSaveRead(WardrobeSaveRecord? Record, string? Error, bool MigratedLegacy = false);

/// <summary>V2 sidecars with read-only v1 migration. Native game saves remain untouched.</summary>
public sealed class WardrobeSaveStore
{
    private readonly AppearanceSaveStore paths;
    private static readonly JsonSerializerOptions Options = new() { UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow };
    public WardrobeSaveStore(string directory) => paths = new(directory);

    public static WardrobeSelectionState Freeze(WardrobeSelectionState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        if (state.Requested == null || state.Visibility?.Disabled == null || state.Visibility.ConfirmedOverrides == null ||
            state.Requested.Count != 4 || Enum.GetValues<WardrobeCategory>().Any(category => !state.Requested.ContainsKey(category)))
            throw new FormatException("Incomplete four-category appearance state");
        static void Id(string? value) {
            if (value == null || !Regex.IsMatch(value, "^[a-z0-9][a-z0-9._-]{0,127}$")) throw new FormatException("Invalid saved MOD ID");
        }
        foreach (var selection in state.Requested.Values) {
            if (selection == null) continue;
            if ((selection.EntryId == null) == (selection.LegacyBundleId == null)) throw new FormatException("Ambiguous saved selection");
            Id(selection.EntryId ?? selection.LegacyBundleId);
        }
        static bool Accessory(WardrobeCategory category) => category is WardrobeCategory.Cloak or WardrobeCategory.Gauntlet;
        if (state.Visibility.Disabled.Any(category => !Accessory(category)) ||
            state.Visibility.Disabled.Distinct().Count() != state.Visibility.Disabled.Count ||
            state.Visibility.ConfirmedOverrides.Distinct().Count() != state.Visibility.ConfirmedOverrides.Count)
            throw new FormatException("Invalid saved visibility controls");
        foreach (var grant in state.Visibility.ConfirmedOverrides) {
            if (grant == null || !Accessory(grant.Category)) throw new FormatException("Invalid force grant");
            Id(grant.DeclaringId);
        }
        WardrobeEquipState? equipment = null;
        if (state.Equipment is { } source) {
            Id(source.DeclaringBodyId);
            if (source.PreviousSelections == null || source.Overridden == null || source.PreviousSelections.Count is < 1 or > 2 ||
                state.Requested[WardrobeCategory.Body]?.EntryId != source.DeclaringBodyId ||
                source.PreviousSelections.Keys.Any(category => !Accessory(category)) ||
                source.Overridden.Distinct().Count() != source.Overridden.Count ||
                source.Overridden.Any(category => !source.PreviousSelections.ContainsKey(category)))
                throw new FormatException("Invalid saved accessory declaration source");
            foreach (var previous in source.PreviousSelections.Values) {
                if (previous == null) continue;
                if ((previous.EntryId == null) == (previous.LegacyBundleId == null)) throw new FormatException("Invalid saved base accessory");
                Id(previous.EntryId ?? previous.LegacyBundleId);
            }
            equipment = new(source.DeclaringBodyId,
                new ReadOnlyDictionary<WardrobeCategory, WardrobeSelection?>(source.PreviousSelections.ToDictionary(pair => pair.Key, pair => pair.Value)),
                Array.AsReadOnly(source.Overridden.ToArray()));
        }
        return new(new ReadOnlyDictionary<WardrobeCategory, WardrobeSelection?>(state.Requested.ToDictionary(pair => pair.Key, pair => pair.Value)),
            new(Array.AsReadOnly(state.Visibility.Disabled.ToArray()), Array.AsReadOnly(state.Visibility.ConfirmedOverrides.ToArray())), equipment);
    }

    public WardrobeSaveRead Read(AppearanceSaveKey key)
    {
        var path = paths.RecordPath(key);
        try {
            if (new FileInfo(path).Length > 1024 * 1024) throw new FormatException("Appearance sidecar too large");
            var bytes = File.ReadAllBytes(path);
            using var json = JsonDocument.Parse(bytes);
            int version = json.RootElement.GetProperty("SchemaVersion").GetInt32();
            if (version == 1) {
                var old = JsonSerializer.Deserialize<AppearanceSaveRecord>(bytes, Options);
                if (old?.Key != key || old.Choices == null) throw new FormatException("Legacy save identity mismatch");
                return new(new(2, key, Freeze(WardrobeSelections.FromLegacy(old.Choices))), null, true);
            }
            if (version is not (2 or 3)) throw new FormatException("Unsupported wardrobe save version");
            var record = JsonSerializer.Deserialize<WardrobeSaveRecord>(bytes, Options);
            if (record?.Key != key || record.Choices == null) throw new FormatException("Wardrobe save identity mismatch");
            if (version == 2 && record.Choices.Equipment != null) throw new FormatException("Declared equip state requires save version 3");
            return new(record with { Choices = Freeze(record.Choices) }, null);
        } catch (FileNotFoundException) { return new(null, null); }
        catch (DirectoryNotFoundException) { return new(null, null); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or FormatException or
            KeyNotFoundException or InvalidOperationException or ArgumentException) { return new(null, e.Message); }
    }

    public void Write(AppearanceSaveKey key, WardrobeSelectionState choices)
    {
        var path = paths.RecordPath(key);
        var snapshot = Freeze(choices);
        var existing = Read(key);
        if (existing.Error != null) throw new InvalidDataException("Existing sidecar requires repair: " + existing.Error);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        if (existing.MigratedLegacy) {
            var original = File.ReadAllBytes(path);
            var backup = path + ".v1." + Convert.ToHexString(SHA256.HashData(original)).ToLowerInvariant() + ".bak";
            if (!File.Exists(backup)) File.Copy(path, backup);
        }
        int version = snapshot.Equipment == null ? 2 : 3;
        if (version == 3 && existing.Record?.SchemaVersion == 2 && !existing.MigratedLegacy) {
            var original = File.ReadAllBytes(path);
            var backup = path + ".v2." + Convert.ToHexString(SHA256.HashData(original)).ToLowerInvariant() + ".bak";
            if (!File.Exists(backup)) File.Copy(path, backup);
        }
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None)) {
                stream.Write(JsonSerializer.SerializeToUtf8Bytes(new WardrobeSaveRecord(version, key, snapshot), Options));
                stream.Flush(true);
            }
            File.Move(temporary, path, true);
        } finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
