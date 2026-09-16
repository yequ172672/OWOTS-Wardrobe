using System.Collections.ObjectModel;

namespace OWOTS.SpecialAdapters.Scarlet;

/// <summary>
/// Lifecycle states reported by the managed Scarlet adapter.  A host may map
/// these to its own diagnostics, but it must not treat Degraded as success.
/// </summary>
public enum ScarletAdapterState
{
    Disabled,
    WaitingForScene,
    Binding,
    Active,
    Degraded,
    Stopping,
    Faulted,
    Closed,
}

public enum ScarletVariant
{
    Hat,
    NoHat,
}

public enum ScarletStage
{
    Primary,
    ActorCorrections,
    HandGateInput,
    HandGate,
    ClothDrivers,
    ClothSolve,
    ClothActorLocal,
    ClothBodyLocalAndComponentInputs,
    ClothComponentDeltas,
    HipResponse,
    ClothActorComponent,
}

public enum ScarletClothPhase
{
    BeforeClothSolve,
    AfterClothSolve,
    AfterClothActorComponent,
    Abort,
}

public enum ScarletHipPhase
{
    BeforeNativeStage,
    AfterNativeStage,
}

public enum ScarletOperationStatus
{
    Applied,
    NativeOnly,
    Skipped,
    Failed,
}

/// <summary>
/// Immutable selection data supplied by the wardrobe runtime.  BodyNativeId
/// is an optional validation observation; ModId plus the exact PFB/catalog
/// routes remain the identity.  A native body ID must never be persisted as a
/// synthetic wardrobe ID.
/// </summary>
public sealed record ScarletWardrobeSelection(
    string ModId,
    ScarletVariant Variant,
    int? BodyNativeId,
    string BodyPrefab,
    string BodyCatalog,
    string HeadPrefab,
    string HeadCatalog,
    string HairPrefab,
    string HairCatalog,
    bool CatalogRowsVerified,
    long Revision,
    string Source = "wardrobe")
{
    public IReadOnlyDictionary<string, (string Prefab, string Catalog)> Parts =>
        new ReadOnlyDictionary<string, (string Prefab, string Catalog)>(new Dictionary<string, (string, string)>(StringComparer.Ordinal)
        {
            ["BODY"] = (BodyPrefab, BodyCatalog),
            ["HEAD"] = (HeadPrefab, HeadCatalog),
            ["HAIR"] = (HairPrefab, HairCatalog),
        });
}

/// <summary>
/// Stable identity of the actual player actor/body owner for one scene
/// generation.  Address values are observations used for lifetime checks and
/// are not saved or used as MOD IDs.
/// </summary>
public sealed record ScarletActorContext(
    ulong ActorAddress,
    ulong BodyAddress,
    long Generation,
    string OwnerKey,
    string SceneKey)
{
    public bool IsValid => ActorAddress != 0 && BodyAddress != 0 && Generation >= 0 &&
        !string.IsNullOrWhiteSpace(OwnerKey) && !string.IsNullOrWhiteSpace(SceneKey);
}

public sealed record ScarletResourceLease(
    string LeaseId,
    string ModId,
    long SelectionRevision,
    IReadOnlyList<string> PrivateRoutes,
    IReadOnlyList<string> VerifiedDynamicKeys)
{
    public bool IsValid => !string.IsNullOrWhiteSpace(LeaseId) &&
        !string.IsNullOrWhiteSpace(ModId) && SelectionRevision >= 0;
}

public sealed record ScarletBinding(
    ScarletResourceLease Lease,
    ScarletActorContext Actor,
    string BindingKey)
{
    public bool IsValid => Lease.IsValid && Actor.IsValid && !string.IsNullOrWhiteSpace(BindingKey);
}

public sealed record ScarletDynamicDependencyReport(
    IReadOnlyList<string> Verified,
    IReadOnlyList<string> Missing,
    IReadOnlyList<string> Rejected,
    bool PrivateNamespaceVerified)
{
    public bool Ready => Missing.Count == 0 && Rejected.Count == 0 && PrivateNamespaceVerified;
}

public sealed record ScarletSupplementResult(
    ScarletOperationStatus Status,
    int NativeCalls,
    string Reason = "")
{
    public bool IsBounded => NativeCalls is >= 0 and <= 1;
}

public sealed record ScarletClothResult(
    ScarletOperationStatus Status,
    int JointWrites,
    int ScaleWrites,
    string Reason = "")
{
    public bool IsSafe => JointWrites >= 0 && ScaleWrites == 0;
}

public sealed record ScarletHipResult(
    ScarletOperationStatus Status,
    float Weight,
    int ScalarWrites,
    string Reason = "")
{
    public bool IsSafe => ScalarWrites is >= 0 and <= 1 && float.IsFinite(Weight) && Weight is >= 0 and <= 1;
}

public sealed record ScarletRestoreResult(
    bool Restored,
    bool CanRelease,
    int RestoredWrites,
    int ForeignChangesPreserved,
    string Reason = "")
{
    public bool IsSafe => RestoredWrites >= 0 && ForeignChangesPreserved >= 0 &&
        (!CanRelease || Restored);
}

/// <summary>
/// Narrow read-only bridge from OWOTS.Appearance.  The runtime should build
/// this value from its immutable wardrobe selection/resolution snapshot and
/// verify all three catalog rows against the selected PFBs before returning
/// true.  No native operation is allowed in this method.
/// </summary>
public interface IScarletWardrobeSelectionSource
{
    bool TryReadSelection(out ScarletWardrobeSelection? selection, out string reason);
}

/// <summary>
/// Game-thread bridge implemented by the integrating REFramework runtime.
/// Every method is called from the host callback thread; implementations must
/// not queue work to a worker and must keep all resource holders alive through
/// restoration.  The interface intentionally has no equipment-ID or save
/// setter.
/// </summary>
public interface IScarletRuntimeHost
{
    long Frame { get; }
    bool SceneReady { get; }

    bool TryGetCurrentActor(out ScarletActorContext actor);
    bool IsCurrent(ScarletActorContext actor);

    /// <summary>Re-checks exact active PFB/catalog rows and expected variant.</summary>
    bool ValidateSelection(ScarletWardrobeSelection selection, out string reason);

    /// <summary>Reads only declared dynamic resources from the active package/provider.</summary>
    ScarletDynamicDependencyReport CheckDynamicDependencies(ScarletWardrobeSelection selection);

    /// <summary>Acquires private UserData/Prefab/resource holders; no global registration.</summary>
    bool TryAcquireResources(ScarletWardrobeSelection selection, ScarletDynamicDependencyReport report,
        out ScarletResourceLease lease, out string reason);

    /// <summary>Binds the private lease to this actual actor/body owner.</summary>
    bool TryBind(ScarletWardrobeSelection selection, ScarletResourceLease lease, ScarletActorContext actor,
        out ScarletBinding binding, out string reason);

    /// <summary>Checks native component identity and timing immediately before a stage call.</summary>
    bool ValidateStage(ScarletBinding binding, ScarletStage stage, out string reason);

    /// <summary>Invokes exactly one existing native constraint component update.</summary>
    bool InvokeNativeStage(ScarletBinding binding, ScarletStage stage, out string reason);

    /// <summary>
    /// Optional late native IK supplement.  It must call native updateIK only,
    /// at most once per owner/frame, and leave the primary drive operational
    /// when it returns Failed.
    /// </summary>
    ScarletSupplementResult TryLateSheath(ScarletBinding binding);

    /// <summary>
    /// Applies the scoped weapon visual/sheath cache bridge.  The host must
    /// snapshot owner-local values and preserve foreign writes on restore.
    /// </summary>
    ScarletSupplementResult TryUpdateWeaponAndSheath(ScarletBinding binding);

    /// <summary>
    /// Captures or writes the seven owned cloth roots.  The host may delegate
    /// to <see cref="ScarletPoseBridge"/>; ScaleWrites must always remain zero.
    /// Invalid native reset evidence should return NativeOnly and allow the
    /// native constraint stages to continue.
    /// </summary>
    ScarletClothResult ApplyCoherentCloth(ScarletBinding binding, ScarletClothPhase phase);

    /// <summary>Writes/verifies the one scalar hip register after cloth consumers.</summary>
    ScarletHipResult ApplyHipClearance(ScarletBinding binding, ScarletHipPhase phase);

    /// <summary>
    /// Restores only values owned by this lease.  CanRelease must be false
    /// until native users have stopped and all owned writes are either restored
    /// or proven absent.
    /// </summary>
    ScarletRestoreResult TryRestore(ScarletBinding binding, string reason);

    void ReleaseResources(ScarletResourceLease lease);
    void Diagnostic(string code, string message);
}

public sealed record ScarletAdapterSnapshot(
    string Schema,
    ScarletAdapterState State,
    long Frame,
    string? ActiveModId,
    ScarletVariant? ActiveVariant,
    string? ActiveOwnerKey,
    bool DynamicDependenciesReady,
    bool RestoreUnresolved,
    bool NoGlobalEquipmentOrSaveWrites,
    int Frames,
    int NativeStageCalls,
    int LateSheathCalls,
    int WeaponSheathCalls,
    int ClothJointWrites,
    int HipScalarWrites,
    int RestoredWrites,
    int ForeignChangesPreserved,
    IReadOnlyList<string> Diagnostics);
