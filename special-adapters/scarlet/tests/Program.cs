using System.Numerics;
using System.Text.Json;
using OWOTS.SpecialAdapters.Scarlet;

var report = new Dictionary<string, object?>
{
    ["schema"] = "scarlet-manual-adapter-offline-tests-v1",
    ["tests"] = new List<Dictionary<string, object?>>()
};
var tests = (List<Dictionary<string, object?>>)report["tests"]!;

void Test(string name, Action action)
{
    try
    {
        action();
        tests.Add(new() { ["name"] = name, ["passed"] = true });
    }
    catch (Exception error)
    {
        tests.Add(new() { ["name"] = name, ["passed"] = false, ["error"] = error.Message });
        throw;
    }
}

static void Check(bool value, string message)
{
    if (!value) throw new InvalidOperationException(message);
}

static ScarletWardrobeSelection Selection(string id = "scarlet_hat_static", long revision = 1,
    bool rowsVerified = true)
{
    var d = ScarletResourceManifest.GetDefinition(id);
    return new(id, d.Variant, d.NativeBodyId, d.BodyPrefab, d.BodyCatalog,
        d.HeadPrefab, d.HeadCatalog, d.HairPrefab, d.HairCatalog, rowsVerified, revision,
        "offline-test");
}

Test("known variants have isolated exact routes", () =>
{
    var hat = Selection();
    var noHat = Selection("scarlet_no_hat_static");
    Check(ScarletResourceManifest.ValidateStaticSelection(hat).Count == 0, "hat route rejected");
    Check(ScarletResourceManifest.ValidateStaticSelection(noHat).Count == 0, "no-hat route rejected");
    Check(hat.ModId != noHat.ModId, "variants share an ID");
    Check(hat.BodyPrefab != noHat.BodyPrefab, "body routes are not isolated");
    Check(ScarletResourceManifest.ResolveRequiredPrivateRoutes(hat.ModId).All(p => p.StartsWith("mods/" + hat.ModId + "/", StringComparison.Ordinal)), "private route escaped");
});

Test("selection gate rejects unverified rows, wrong body ID and public routes", () =>
{
    var d = ScarletResourceManifest.GetDefinition("scarlet_hat_static");
    var bad = Selection(rowsVerified: false);
    Check(ScarletResourceManifest.ValidateStaticSelection(bad).Contains("catalog_rows_not_verified"), "unverified rows accepted");
    bad = bad with { BodyNativeId = 28284 };
    Check(ScarletResourceManifest.ValidateStaticSelection(bad).Any(e => e.StartsWith("native_body_id_mismatch", StringComparison.Ordinal)), "wrong body ID accepted");
    bad = bad with { BodyNativeId = d.NativeBodyId, BodyPrefab = "art/mods/scarlet/p/public.pfb" };
    Check(ScarletResourceManifest.ValidateStaticSelection(bad).Any(e => e.Contains("not_private", StringComparison.Ordinal)), "public route accepted");
});

Test("path policy rejects traversal and game routes in private namespace", () =>
{
    Check(!ScarletPathPolicy.IsSafeLogicalPath("mods/x/../escape.pfb"), "traversal accepted");
    Check(!ScarletPathPolicy.IsPrivateRoute("game:art/model/a.mesh", "scarlet_hat_static"), "game route accepted as private");
    Check(!ScarletPathPolicy.IsPrivateRoute("mods/scarlet_hat_static/../other.pfb", "scarlet_hat_static"), "private traversal accepted");
    Check(ScarletPathPolicy.IsGameSharedRoute("art/model/character/ch0/body.mesh"), "game shared route rejected");
});

Test("cloth bridge preserves seven roots and never writes scale", () =>
{
    var cloth = new ScarletCoherentCloth();
    var before = ScarletCoherentCloth.RootNames.ToDictionary(name => name,
        name => new ScarletPose(new Vector3(name.Length * .01f, 0, 0), Quaternion.Identity));
    cloth.Start(1, "owner", before);
    var kin = ScarletCoherentCloth.KinNames.ToDictionary(name => name,
        name => before[name] with { Position = before[name].Position + new Vector3(.2f, .01f, -.03f) });
    cloth.SetKin(1, "owner", kin);
    var desired = new Dictionary<string, ScarletPose>
    {
        [ScarletCoherentCloth.DesiredNames[0]] = kin[ScarletCoherentCloth.DesiredNames[0]] with { Position = new Vector3(.4f, .2f, .1f) },
        [ScarletCoherentCloth.DesiredNames[1]] = kin[ScarletCoherentCloth.DesiredNames[1]] with { Position = new Vector3(-.4f, .2f, .1f) },
    };
    var goals = cloth.Finish(1, "owner", desired);
    Check(goals.Count == 7 && goals.All(goal => goal.IsValid), "cloth root batch incomplete");
    Check(goals.Select(goal => goal.Name).Distinct(StringComparer.Ordinal).Count() == 7, "cloth roots duplicated");
});

Test("hip clearance uses audited plateau and smootherstep", () =>
{
    Check(ScarletHipClearance.Weight(.2f) == 1f, "inner plateau wrong");
    Check(ScarletHipClearance.Weight(.7f) == 0f, "outer cutoff wrong");
    var middle = ScarletHipClearance.Weight(.45f);
    Check(middle > 0f && middle < 1f, "middle taper wrong");
    Check(Math.Abs(ScarletHipClearance.EncodeNativeRegister(1f) - .01f) < .000001f, "register encoding wrong");
});

Test("managed lifecycle binds, stages once, restores on selection change", () =>
{
    var source = new FakeSelectionSource(Selection());
    var host = new FakeHost();
    using var adapter = new ScarletWardrobeAdapter(source, host);
    var first = adapter.Tick();
    Check(first.State == ScarletAdapterState.Active, "adapter did not activate");
    Check(first.NativeStageCalls == 11, "stage count is not the audited 11");
    Check(first.LateSheathCalls == 1 && first.WeaponSheathCalls == 1, "supplement bound missing");
    Check(first.ClothJointWrites == 7 && first.HipScalarWrites == 2, "owned writes missing");
    var duplicate = adapter.Tick();
    Check(duplicate.NativeStageCalls == first.NativeStageCalls, "duplicate frame ran native stages");
    host.Frame++;
    var second = adapter.Tick();
    Check(second.NativeStageCalls == 22, "next frame did not run stages");
    source.Selection = Selection("scarlet_no_hat_static", 2);
    host.Frame++;
    var changed = adapter.Tick();
    Check(changed.State == ScarletAdapterState.Active && host.RestoreCalls == 1 && host.ReleaseCalls == 1, "variant transition did not restore/release");
    Check(changed.ActiveModId == "scarlet_no_hat_static", "new variant was not selected");
});

Test("missing dynamic dependency never reaches native stage", () =>
{
    var source = new FakeSelectionSource(Selection());
    var host = new FakeHost { DependenciesReady = false };
    using var adapter = new ScarletWardrobeAdapter(source, host);
    var snapshot = adapter.Tick();
    Check(snapshot.State == ScarletAdapterState.Degraded, "missing dependency was treated as success");
    Check(host.NativeStageCalls == 0 && host.AcquireCalls == 0, "native work started without dependencies");
});

Test("unresolved restore keeps the lease quarantined", () =>
{
    var source = new FakeSelectionSource(Selection());
    var host = new FakeHost { RestoreCanRelease = false };
    using var adapter = new ScarletWardrobeAdapter(source, host);
    Check(adapter.Tick().State == ScarletAdapterState.Active, "adapter did not activate");
    source.Selection = null;
    host.Frame++;
    var snapshot = adapter.Tick();
    Check(snapshot.RestoreUnresolved && host.ReleaseCalls == 0, "unresolved owner was released");
});

Test("actor generation change is restored before rebinding", () =>
{
    var source = new FakeSelectionSource(Selection());
    var host = new FakeHost();
    using var adapter = new ScarletWardrobeAdapter(source, host);
    Check(adapter.Tick().State == ScarletAdapterState.Active, "adapter did not activate");
    host.ActorGeneration++;
    host.Frame++;
    var snapshot = adapter.Tick();
    Check(snapshot.State == ScarletAdapterState.Active && host.RestoreCalls == 1 && host.BindCalls == 2, "actor generation was not rebound safely");
});

report["passed"] = tests.Count(item => (bool)item["passed"]!);
report["total"] = tests.Count;
report["generatedUtc"] = DateTimeOffset.UtcNow;
var output = Environment.GetEnvironmentVariable("SCARLET_TEST_REPORT") ?? "offline-test-report.json";
Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(output))!);
File.WriteAllText(output, JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true }));
Console.WriteLine(JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true }));

sealed class FakeSelectionSource(ScarletWardrobeSelection? selection) : IScarletWardrobeSelectionSource
{
    public ScarletWardrobeSelection? Selection { get; set; } = selection;
    public bool TryReadSelection(out ScarletWardrobeSelection? selection, out string reason)
    {
        selection = Selection;
        reason = selection is null ? "disabled" : string.Empty;
        return true;
    }
}

sealed class FakeHost : IScarletRuntimeHost
{
    public long Frame { get; set; }
    public bool SceneReady { get; set; } = true;
    public bool DependenciesReady { get; set; } = true;
    public bool RestoreCanRelease { get; set; } = true;
    public int ActorGeneration { get; set; }
    public int NativeStageCalls { get; private set; }
    public int BindCalls { get; private set; }
    public int AcquireCalls { get; private set; }
    public int RestoreCalls { get; private set; }
    public int ReleaseCalls { get; private set; }
    private readonly ScarletActorContext _baseActor = new(0x1000, 0x2000, 0, "player:0", "scene:0");

    public bool TryGetCurrentActor(out ScarletActorContext actor)
    {
        actor = _baseActor with { Generation = ActorGeneration };
        return SceneReady;
    }

    public bool IsCurrent(ScarletActorContext actor) => actor.IsValid && actor.Generation == ActorGeneration;

    public bool ValidateSelection(ScarletWardrobeSelection selection, out string reason)
    {
        reason = string.Empty;
        return ScarletResourceManifest.ValidateStaticSelection(selection).Count == 0;
    }

    public ScarletDynamicDependencyReport CheckDynamicDependencies(ScarletWardrobeSelection selection)
    {
        var dependencies = ScarletResourceManifest.RequiredDependencies;
        return DependenciesReady
            ? new(dependencies.Select(d => d.Key).ToArray(), Array.Empty<string>(), Array.Empty<string>(), true)
            : new(Array.Empty<string>(), dependencies.Select(d => d.Key).ToArray(), Array.Empty<string>(), true);
    }

    public bool TryAcquireResources(ScarletWardrobeSelection selection, ScarletDynamicDependencyReport report,
        out ScarletResourceLease lease, out string reason)
    {
        AcquireCalls++;
        lease = new("lease-" + AcquireCalls, selection.ModId, selection.Revision,
            ScarletResourceManifest.ResolveRequiredPrivateRoutes(selection.ModId), report.Verified);
        reason = string.Empty;
        return DependenciesReady;
    }

    public bool TryBind(ScarletWardrobeSelection selection, ScarletResourceLease lease, ScarletActorContext actor,
        out ScarletBinding binding, out string reason)
    {
        BindCalls++;
        binding = new(lease, actor, $"{lease.LeaseId}/{actor.OwnerKey}");
        reason = string.Empty;
        return true;
    }

    public bool ValidateStage(ScarletBinding binding, ScarletStage stage, out string reason)
    {
        reason = string.Empty;
        return IsCurrent(binding.Actor);
    }

    public bool InvokeNativeStage(ScarletBinding binding, ScarletStage stage, out string reason)
    {
        NativeStageCalls++;
        reason = string.Empty;
        return IsCurrent(binding.Actor);
    }

    public ScarletSupplementResult TryLateSheath(ScarletBinding binding) =>
        new(ScarletOperationStatus.Applied, 1);

    public ScarletSupplementResult TryUpdateWeaponAndSheath(ScarletBinding binding) =>
        new(ScarletOperationStatus.Applied, 1);

    public ScarletClothResult ApplyCoherentCloth(ScarletBinding binding, ScarletClothPhase phase) =>
        phase == ScarletClothPhase.AfterClothActorComponent
            ? new(ScarletOperationStatus.Applied, 7, 0)
            : new(ScarletOperationStatus.Applied, 0, 0);

    public ScarletHipResult ApplyHipClearance(ScarletBinding binding, ScarletHipPhase phase) =>
        new(ScarletOperationStatus.Applied, .5f, 1);

    public ScarletRestoreResult TryRestore(ScarletBinding binding, string reason)
    {
        RestoreCalls++;
        return new(RestoreCanRelease, RestoreCanRelease, RestoreCanRelease ? 7 : 0, 1,
            RestoreCanRelease ? string.Empty : "foreign owner still active");
    }

    public void ReleaseResources(ScarletResourceLease lease) => ReleaseCalls++;
    public void Diagnostic(string code, string message) { }
}
