using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;

namespace OWOTS.Appearance;

/// <summary>
/// Optional, same-topology actor skeleton metadata for a BODY manifest.
/// This is a strict declaration parser; it does not load or retarget a binary
/// skeleton and it does not establish native runtime compatibility.
/// </summary>
public sealed class WardrobeSkeleton
{
    public const int SupportedSchemaVersion = 1;
    public const string SupportedKind = "actor-fbxskel-v1";
    public const int RequiredJointCount = 93;
    public const string FixedBaselineResource =
        "art/model/character/ch0/ch001_00/90/ch001_00_90.fbxskel";

    private readonly IReadOnlyList<string> _jointNames;
    private readonly IReadOnlyDictionary<string, IReadOnlyList<float>> _bindPositions;

    private WardrobeSkeleton(string? resource, string bodyMesh, IReadOnlyList<string> jointNames,
        IReadOnlyDictionary<string, IReadOnlyList<float>> bindPositions)
    {
        SchemaVersion = SupportedSchemaVersion;
        Kind = SupportedKind;
        Resource = resource;
        BodyMesh = bodyMesh;
        _jointNames = jointNames;
        _bindPositions = bindPositions;
        BaselineResource = FixedBaselineResource;
    }

    public int SchemaVersion { get; }
    public string Kind { get; }
    /// <summary>Optional private FBXSKEL path inherited from the older contract;
    /// the runtime no longer needs it and never installs it at the game root.</summary>
    public string? Resource { get; }
    public string BodyMesh { get; }
    public IReadOnlyList<string> JointNames => _jointNames;
    /// <summary>Authored rest positions when the converter extracted them.  An
    /// empty map means "read the equipped body mesh's own skeleton rest".</summary>
    public IReadOnlyDictionary<string, IReadOnlyList<float>> BindPositions => _bindPositions;
    public string BaselineResource { get; }

    /// <summary>Parse a skeleton object in the context of its manifest.</summary>
    public static WardrobeSkeleton Parse(JsonElement value, string manifestId,
        WardrobeCategory category, IReadOnlyList<WardrobePart> parts)
    {
        if (value.ValueKind != JsonValueKind.Object) throw new FormatException("Expected skeleton object");
        if (string.IsNullOrWhiteSpace(manifestId)) throw new ArgumentException("Manifest ID is required", nameof(manifestId));
        if (category != WardrobeCategory.Body) throw new FormatException("Skeleton metadata requires a BODY manifest");
        if (parts == null || !parts.Any(part => part.Part == "BODY"))
            throw new FormatException("Skeleton metadata requires a BODY part");

        Fields(value, "schemaVersion", "kind", "resource", "bodyMesh", "jointNames",
            "bindPositions", "baselineResource");
        if (!value.TryGetProperty("schemaVersion", out var version) ||
            version.ValueKind != JsonValueKind.Number || !version.TryGetInt32(out var schema) ||
            schema != SupportedSchemaVersion)
            throw new FormatException("Expected skeleton schemaVersion 1");
        if (Text(value, "kind") != SupportedKind)
            throw new FormatException("Expected skeleton kind actor-fbxskel-v1");

        // `resource` is optional: the runtime derives the shape from the manifest
        // bind positions or the equipped mesh, never from a root skeleton file.
        string? resource = null;
        if (value.TryGetProperty("resource", out var resourceValue)) {
            if (resourceValue.ValueKind != JsonValueKind.String)
                throw new FormatException("Skeleton resource must be text");
            resource = PrivatePath(resourceValue.GetString()!, manifestId, ".fbxskel");
        }
        var bodyMesh = PrivatePath(Text(value, "bodyMesh"), manifestId, ".mesh");
        if (Text(value, "baselineResource") != FixedBaselineResource)
            throw new FormatException("Skeleton baselineResource must be the fixed /90 game resource");

        var namesValue = Required(value, "jointNames");
        if (namesValue.ValueKind != JsonValueKind.Array || namesValue.GetArrayLength() != RequiredJointCount)
            throw new FormatException("Skeleton jointNames must contain exactly 93 names");
        var names = new List<string>(RequiredJointCount);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in namesValue.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.String) throw new FormatException("Skeleton joint name must be text");
            var name = item.GetString()!;
            if (string.IsNullOrWhiteSpace(name) || name.Length > 128 || name.Any(char.IsControl))
                throw new FormatException("Skeleton joint name is empty, too long or contains control characters");
            if (!seen.Add(name)) throw new FormatException("Duplicate skeleton joint name: " + name);
            names.Add(name);
        }

        // `bindPositions` is optional.  When present it must declare the authored
        // rest for all 93 joints; when absent the runtime reads the equipped body
        // mesh's own skeleton rest instead (compatibility path).
        var orderedPositions = new Dictionary<string, IReadOnlyList<float>>(StringComparer.Ordinal);
        if (value.TryGetProperty("bindPositions", out var positionsValue)) {
            if (positionsValue.ValueKind != JsonValueKind.Object)
                throw new FormatException("Skeleton bindPositions must be an object");
            var positions = new Dictionary<string, IReadOnlyList<float>>(StringComparer.Ordinal);
            foreach (var property in positionsValue.EnumerateObject()) {
                if (!seen.Contains(property.Name))
                    throw new FormatException("bindPositions contains an unknown joint: " + property.Name);
                if (!positions.TryAdd(property.Name, Position(property.Value, property.Name)))
                    throw new FormatException("Duplicate bind position: " + property.Name);
            }
            if (positions.Count != names.Count)
                throw new FormatException("bindPositions must contain one position for every joint");
            // Rebuild in jointNames order so snapshots are deterministic even when
            // the source JSON object used a different property order.
            foreach (var name in names) orderedPositions.Add(name, positions[name]);
        }
        return new(resource, bodyMesh,
            new System.Collections.ObjectModel.ReadOnlyCollection<string>(names.ToArray()),
            new System.Collections.ObjectModel.ReadOnlyDictionary<string, IReadOnlyList<float>>(orderedPositions));
    }

    /// <summary>
    /// Return a detached JSON snapshot with the stable lower-camel schema used
    /// by the read-only runtime diagnostic endpoint.
    /// </summary>
    public JsonElement ToSnapshot()
    {
        var positions = new Dictionary<string, float[]>(StringComparer.Ordinal);
        foreach (var name in JointNames)
            if (BindPositions.TryGetValue(name, out var position)) positions.Add(name, position.ToArray());
        return JsonSerializer.SerializeToElement(new {
            schemaVersion = SchemaVersion,
            kind = Kind,
            resource = Resource,
            bodyMesh = BodyMesh,
            jointNames = JointNames.ToArray(),
            bindPositions = positions,
            baselineResource = BaselineResource
        });
    }

    private static JsonElement Required(JsonElement value, string property)
    {
        if (!value.TryGetProperty(property, out var result))
            throw new FormatException("Missing skeleton field: " + property);
        return result;
    }

    private static string Text(JsonElement value, string property)
    {
        var result = Required(value, property);
        if (result.ValueKind != JsonValueKind.String || string.IsNullOrWhiteSpace(result.GetString()))
            throw new FormatException("Skeleton field must be non-empty text: " + property);
        return result.GetString()!;
    }

    private static IReadOnlyList<float> Position(JsonElement value, string name)
    {
        if (value.ValueKind != JsonValueKind.Array || value.GetArrayLength() != 3)
            throw new FormatException("Skeleton bind position must be a 3D vector: " + name);
        var result = new float[3];
        for (var index = 0; index < result.Length; index++)
        {
            var coordinate = value[index];
            if (coordinate.ValueKind != JsonValueKind.Number || !coordinate.TryGetSingle(out var number) ||
                !float.IsFinite(number))
                throw new FormatException("Skeleton bind position must contain finite numbers: " + name);
            result[index] = number;
        }
        return new System.Collections.ObjectModel.ReadOnlyCollection<float>(result);
    }

    private static string PrivatePath(string value, string manifestId, string extension)
    {
        var prefix = "mods/" + manifestId + "/";
        if (value.Contains('\\') || value.Contains(':') || value.Contains('@') || value.Any(char.IsControl) ||
            value.Split('/').Any(segment => segment is "" or "." or "..") ||
            !value.StartsWith(prefix, StringComparison.Ordinal) ||
            !value.EndsWith(extension, StringComparison.OrdinalIgnoreCase))
            throw new FormatException("Skeleton resource must stay in the manifest private namespace");
        return value;
    }

    private static void Fields(JsonElement value, params string[] allowed)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var property in value.EnumerateObject())
            if (!seen.Add(property.Name) || !allowed.Contains(property.Name, StringComparer.Ordinal))
                throw new FormatException("Duplicate or unsupported skeleton field: " + property.Name);
    }
}
