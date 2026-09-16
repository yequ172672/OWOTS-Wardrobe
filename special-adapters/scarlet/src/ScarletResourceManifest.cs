using System.Collections.ObjectModel;

namespace OWOTS.SpecialAdapters.Scarlet;

public sealed record ScarletVariantDefinition(
    string ModId,
    ScarletVariant Variant,
    int NativeBodyId,
    string OriginalBodyMeshPath,
    string OriginalBodyMeshSha256,
    string BodyPrefab,
    string BodyCatalog,
    string HeadPrefab,
    string HeadCatalog,
    string HairPrefab,
    string HairCatalog)
{
    public IReadOnlyDictionary<string, (string Prefab, string Catalog)> Routes =>
        new ReadOnlyDictionary<string, (string, string)>(new Dictionary<string, (string, string)>(StringComparer.Ordinal)
        {
            ["BODY"] = (BodyPrefab, BodyCatalog),
            ["HEAD"] = (HeadPrefab, HeadCatalog),
            ["HAIR"] = (HairPrefab, HairCatalog),
        });
}

public sealed record ScarletDynamicDependency(
    string Key,
    string SourceAuditPath,
    string RuntimePathTemplate,
    string Purpose,
    bool Required,
    bool GameShared)
{
    public string ResolveRuntimePath(string modId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(modId);
        return RuntimePathTemplate.Replace("{id}", modId, StringComparison.Ordinal);
    }
}

/// <summary>
/// Audited data from C.json and the two v3 static wardrobe packages.  This is
/// metadata only: it does not ship the referenced game or Scarlet assets.
/// </summary>
public static class ScarletResourceManifest
{
    public const string Schema = "scarlet-manual-adapter-manifest-v1";
    public const string OriginalAuthor = "Little1113";
    public const string OriginalPackage = "Scarlet-Model-1.1.0";

    private static readonly IReadOnlyDictionary<string, ScarletVariantDefinition> Definitions =
        new ReadOnlyDictionary<string, ScarletVariantDefinition>(new Dictionary<string, ScarletVariantDefinition>(StringComparer.Ordinal)
        {
            ["scarlet_hat_static"] = new(
                "scarlet_hat_static", ScarletVariant.Hat, 7482,
                "art/mods/scarlet/p/body_mesh_2de4180b65dbe6b20a.mesh",
                "5c8aafcb6b20b5ebbadb1ab8960b753bf5ed27514c3b705bd42e7f061299a960",
                "mods/scarlet_hat_static/b60902b0c9f97048/ch001_00_00_HQ.pfb",
                "mods/scarlet_hat_static/c406cadd4073f518/playerbodypartslisthq_1st.user",
                "mods/scarlet_hat_static/2670bb075a9de61f/ch001_00_10_HQ.pfb",
                "mods/scarlet_hat_static/cf3fdf041f9fbd65/playerheadpartslisthq_1st.user",
                "mods/scarlet_hat_static/fa78e476fb9051c2/ch001_00_20_HQ.pfb",
                "mods/scarlet_hat_static/1f9bad298db57811/playerhairpartslisthq_1st.user"),
            ["scarlet_no_hat_static"] = new(
                "scarlet_no_hat_static", ScarletVariant.NoHat, 28284,
                "art/mods/scarlet/p/body_mesh_ae4e361f60ab521537.mesh",
                "844df0b06c3c396b3f3826bb903421ee330e1a4786a4df4b415b7e4b58d7a30c",
                "mods/scarlet_no_hat_static/8fabaa2952df9e4c/ch001_01_00_HQ.pfb",
                "mods/scarlet_no_hat_static/c406cadd4073f518/playerbodypartslisthq_1st.user",
                "mods/scarlet_no_hat_static/2670bb075a9de61f/ch001_00_10_HQ.pfb",
                "mods/scarlet_no_hat_static/cf3fdf041f9fbd65/playerheadpartslisthq_1st.user",
                "mods/scarlet_no_hat_static/fa78e476fb9051c2/ch001_00_20_HQ.pfb",
                "mods/scarlet_no_hat_static/1f9bad298db57811/playerhairpartslisthq_1st.user"),
        });

    // SourceAuditPath is retained for provenance only.  RuntimePathTemplate
    // is the private, rewritten route that a host must actually resolve.
    private static readonly IReadOnlyList<ScarletDynamicDependency> Dependencies =
        new ReadOnlyCollection<ScarletDynamicDependency>(new ScarletDynamicDependency[]
        {
            new("original_rig", "art/model/character/ch0/ch001_00/90/ch001_00_90.fbxskel", "game:art/model/character/ch0/ch001_00/90/ch001_00_90.fbxskel", "native source skeleton", true, true),
            new("original_common", "motion/player/common/common.motbank", "game:motion/player/common/common.motbank", "native common motion source", true, true),
            new("original_designchange", "motion/player/designchange/designchange.motbank", "game:motion/player/designchange/designchange.motbank", "native design-change motion source", true, true),
            new("original_weapon", "motion/player/weapon/weapon.motbank", "game:motion/player/weapon/weapon.motbank", "native weapon motion source", true, true),
            new("original_visual", "gamedesign/action/player/data/parampack/playerweaponvisualparam.user", "game:gamedesign/action/player/data/parampack/playerweaponvisualparam.user", "native weapon visual baseline", true, true),
            new("original_sheath", "gamedesign/action/player/data/parampack/motionparam/playersheathholdparam.user", "game:gamedesign/action/player/data/parampack/motionparam/playersheathholdparam.user", "native sheath baseline", true, true),
            new("original_aaa", "gamedesign/gimmick/gm800/gm800_000/gm800_000_aaauniqueparam.user", "game:gamedesign/gimmick/gm800/gm800_000/gm800_000_aaauniqueparam.user", "native weapon AAA baseline", true, true),
            new("scarlet_rig", "art/mods/scarlet/p/rig_dd9ab81db072df9531fbfe9d.fbxskel", "mods/{id}/dynamic/rig.fbxskel", "private Scarlet actor skeleton", true, false),
            new("scarlet_common", "art/mods/scarlet/isolation/scarlet_common.motbank", "mods/{id}/dynamic/scarlet_common.motbank", "private Scarlet actor motion", true, false),
            new("scarlet_designchange", "art/mods/scarlet/isolation/scarlet_designchange.motbank", "mods/{id}/dynamic/scarlet_designchange.motbank", "private Scarlet UI/design-change motion", true, false),
            new("scarlet_weapon", "art/mods/scarlet/isolation/scarlet_weapon.motbank", "mods/{id}/dynamic/scarlet_weapon.motbank", "private Scarlet weapon motion", true, false),
            new("scarlet_visual", "art/mods/scarlet/isolation/scarlet_visual.user", "mods/{id}/dynamic/scarlet_visual.user", "private weapon visual override", true, false),
            new("scarlet_sheath", "art/mods/scarlet/isolation/scarlet_sheath.user", "mods/{id}/dynamic/scarlet_sheath.user", "private sheath override", true, false),
            new("scarlet_aaa", "art/mods/scarlet/isolation/scarlet_aaa.user", "mods/{id}/dynamic/scarlet_aaa.user", "private weapon AAA override", true, false),
            new("scarlet_chain_0", "art/mods/scarlet/p/empty_chain_188ce7286fa25651.chain2", "mods/{id}/dynamic/chain_0.chain2", "private chain source mapped to native chain 0", true, false),
            new("scarlet_chain_2", "art/mods/scarlet/p/empty_chain_1378acd141f77147f46804b4fa4.chain2", "mods/{id}/dynamic/chain_2.chain2", "private chain source mapped to native chain 1", true, false),
        });

    public static IReadOnlyCollection<string> AcceptedModIds => Definitions.Keys.ToArray();
    public static IReadOnlyList<ScarletDynamicDependency> AllDependencies => Dependencies;

    public static bool TryGetDefinition(string modId, out ScarletVariantDefinition definition) =>
        Definitions.TryGetValue(modId, out definition!);

    public static ScarletVariantDefinition GetDefinition(string modId) =>
        TryGetDefinition(modId, out var value)
            ? value
            : throw new ArgumentException($"Unsupported Scarlet wardrobe ID: {modId}", nameof(modId));

    public static IReadOnlyList<ScarletDynamicDependency> RequiredDependencies =>
        Dependencies.Where(d => d.Required).ToArray();

    public static IReadOnlyList<string> ResolveRequiredPrivateRoutes(string modId) =>
        RequiredDependencies.Where(d => !d.GameShared)
            .Select(d => d.ResolveRuntimePath(modId))
            .ToArray();

    public static IReadOnlyList<string> ValidateStaticSelection(ScarletWardrobeSelection selection)
    {
        var errors = new List<string>();
        if (!TryGetDefinition(selection.ModId, out var definition))
        {
            errors.Add("unsupported_mod_id");
            return errors;
        }

        if (selection.Variant != definition.Variant)
            errors.Add($"variant_mismatch:{definition.Variant}");
        if (selection.BodyNativeId.HasValue && selection.BodyNativeId.Value != definition.NativeBodyId)
            errors.Add($"native_body_id_mismatch:{definition.NativeBodyId}");
        if (!selection.CatalogRowsVerified)
            errors.Add("catalog_rows_not_verified");

        foreach (var pair in selection.Parts)
        {
            if (!ScarletPathPolicy.IsPrivateRoute(pair.Value.Prefab, selection.ModId))
                errors.Add($"{pair.Key}_prefab_not_private");
            if (!ScarletPathPolicy.IsPrivateRoute(pair.Value.Catalog, selection.ModId))
                errors.Add($"{pair.Key}_catalog_not_private");
        }

        foreach (var part in new[] { "BODY", "HEAD", "HAIR" })
        {
            var actual = selection.Parts[part];
            var expected = definition.Routes[part];
            if (!string.Equals(actual.Prefab, expected.Prefab, StringComparison.OrdinalIgnoreCase))
                errors.Add($"{part}_prefab_does_not_match_known_static_route");
            if (!string.Equals(actual.Catalog, expected.Catalog, StringComparison.OrdinalIgnoreCase))
                errors.Add($"{part}_catalog_does_not_match_known_static_route");
        }

        return errors;
    }
}

public static class ScarletPathPolicy
{
    public static string Canonicalize(string path)
    {
        if (string.IsNullOrWhiteSpace(path)) return string.Empty;
        var value = path.Trim().Replace('\\', '/');
        while (value.StartsWith("@", StringComparison.Ordinal)) value = value[1..];
        while (value.StartsWith("./", StringComparison.Ordinal)) value = value[2..];
        if (value.StartsWith("natives/stm/", StringComparison.OrdinalIgnoreCase)) value = value[12..];
        return value;
    }

    public static bool IsSafeLogicalPath(string path)
    {
        var value = Canonicalize(path);
        if (value.Length == 0 || value.Contains('\0') || value.Contains(':') || value.StartsWith("/", StringComparison.Ordinal)) return false;
        var segments = value.Split('/', StringSplitOptions.RemoveEmptyEntries);
        return segments.Length > 0 && segments.All(segment => segment is not ("." or "..")) &&
            !value.Contains("//", StringComparison.Ordinal);
    }

    public static bool IsPrivateRoute(string path, string modId)
    {
        if (!IsSafeLogicalPath(path) || string.IsNullOrWhiteSpace(modId)) return false;
        var value = Canonicalize(path);
        var prefix = $"mods/{modId}/";
        return value.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) &&
            !value.Contains("art/mods/scarlet", StringComparison.OrdinalIgnoreCase) &&
            !value.Contains("reframework/", StringComparison.OrdinalIgnoreCase);
    }

    public static bool IsGameSharedRoute(string path)
    {
        if (!IsSafeLogicalPath(path)) return false;
        var value = Canonicalize(path);
        return value.StartsWith("game:", StringComparison.OrdinalIgnoreCase) == false &&
            !value.StartsWith("mods/", StringComparison.OrdinalIgnoreCase) &&
            (value.StartsWith("art/", StringComparison.OrdinalIgnoreCase) ||
             value.StartsWith("motion/", StringComparison.OrdinalIgnoreCase) ||
             value.StartsWith("gamedesign/", StringComparison.OrdinalIgnoreCase));
    }

    public static bool ValidateDependencyRoute(ScarletDynamicDependency dependency, string modId, out string reason)
    {
        var route = dependency.ResolveRuntimePath(modId);
        if (dependency.GameShared)
        {
            if (!route.StartsWith("game:", StringComparison.OrdinalIgnoreCase))
            {
                reason = "game dependency route must be provider-qualified";
                return false;
            }
            if (!IsSafeLogicalPath(route[5..]))
            {
                reason = "unsafe game dependency path";
                return false;
            }
        }
        else if (!IsPrivateRoute(route, modId))
        {
            reason = "private dependency escaped the mod namespace";
            return false;
        }

        reason = string.Empty;
        return true;
    }
}
