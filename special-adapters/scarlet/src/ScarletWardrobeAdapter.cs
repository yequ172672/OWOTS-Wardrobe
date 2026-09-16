namespace OWOTS.SpecialAdapters.Scarlet;

/// <summary>
/// Managed orchestration for the Scarlet dynamic migration.  The integrating
/// runtime owns all REFramework objects and implements IScarletRuntimeHost;
/// this class is deliberately deterministic and can therefore be exercised
/// without a game process.
/// </summary>
public sealed class ScarletWardrobeAdapter : IDisposable
{
    private static readonly ScarletStage[] Stages =
    {
        ScarletStage.Primary,
        ScarletStage.ActorCorrections,
        ScarletStage.HandGateInput,
        ScarletStage.HandGate,
        ScarletStage.ClothDrivers,
        ScarletStage.ClothSolve,
        ScarletStage.ClothActorLocal,
        ScarletStage.ClothBodyLocalAndComponentInputs,
        ScarletStage.ClothComponentDeltas,
        ScarletStage.HipResponse,
        ScarletStage.ClothActorComponent,
    };

    private readonly IScarletWardrobeSelectionSource _selectionSource;
    private readonly IScarletRuntimeHost _host;
    private readonly List<string> _diagnostics = new();
    private ScarletAdapterState _state = ScarletAdapterState.Disabled;
    private ScarletWardrobeSelection? _selection;
    private ScarletBinding? _binding;
    private ScarletDynamicDependencyReport? _dependencyReport;
    private long _lastFrame = -1;
    private bool _restoreUnresolved;
    private bool _closed;
    private int _frames;
    private int _nativeStageCalls;
    private int _lateSheathCalls;
    private int _weaponSheathCalls;
    private int _clothJointWrites;
    private int _hipScalarWrites;
    private int _restoredWrites;
    private int _foreignChangesPreserved;

    public ScarletWardrobeAdapter(IScarletWardrobeSelectionSource selectionSource, IScarletRuntimeHost host)
    {
        _selectionSource = selectionSource ?? throw new ArgumentNullException(nameof(selectionSource));
        _host = host ?? throw new ArgumentNullException(nameof(host));
    }

    public ScarletAdapterState State => _state;
    public bool RestoreUnresolved => _restoreUnresolved;

    /// <summary>
    /// Executes at most one full adapter frame.  Call this from the host's
    /// UpdateConstraintsEnd/UpdateBehavior.Post callback after the wardrobe
    /// runtime has published its immutable selection snapshot.
    /// </summary>
    public ScarletAdapterSnapshot Tick()
    {
        if (_closed) return Snapshot();

        var frame = _host.Frame;
        if (frame < 0)
        {
            FailClosed("invalid_frame", "Host returned a negative frame count");
            return Snapshot();
        }

        ScarletWardrobeSelection? nextSelection;
        try
        {
            if (!_selectionSource.TryReadSelection(out nextSelection, out var sourceReason))
            {
                AddDiagnostic("selection_unavailable", sourceReason);
                if (TryStop("selection unavailable")) _state = ScarletAdapterState.WaitingForScene;
                return Snapshot();
            }
        }
        catch (Exception error)
        {
            FailClosed("selection_exception", error.Message);
            TryStop("selection source exception");
            return Snapshot();
        }

        if (nextSelection is null)
        {
            if (TryStop("Scarlet wardrobe is not selected")) _state = ScarletAdapterState.Disabled;
            return Snapshot();
        }

        var gateErrors = ScarletResourceManifest.ValidateStaticSelection(nextSelection);
        if (gateErrors.Count > 0)
        {
            AddDiagnostic("selection_rejected", string.Join(",", gateErrors));
            if (TryStop("selection gate rejected")) _state = ScarletAdapterState.Disabled;
            return Snapshot();
        }

        try
        {
            if (!_host.ValidateSelection(nextSelection, out var hostReason))
            {
                AddDiagnostic("selection_not_current", hostReason);
                if (TryStop("host selection verification failed")) _state = ScarletAdapterState.WaitingForScene;
                return Snapshot();
            }
        }
        catch (Exception error)
        {
            FailClosed("selection_validation_exception", error.Message);
            TryStop("selection validation exception");
            return Snapshot();
        }

        if (!_host.SceneReady || !_host.TryGetCurrentActor(out var actor) || !actor.IsValid)
        {
            AddDiagnosticOnce("scene_waiting", "Scarlet actor/scene is not ready; resources remain scoped until restoration is possible");
            _state = ScarletAdapterState.WaitingForScene;
            return Snapshot();
        }

        if (_binding is not null &&
            (!SameSelection(nextSelection, _selection) || !SameActor(actor, _binding.Actor) || !_host.IsCurrent(_binding.Actor)))
        {
            if (!TryStop("selection, scene or actor generation changed")) return Snapshot();
            if (_binding is not null) return Snapshot();
        }

        if (_binding is null)
        {
            if (!TryStart(nextSelection, actor)) return Snapshot();
        }

        if (_binding is null || _selection is null) return Snapshot();
        if (_lastFrame == frame)
        {
            AddDiagnosticOnce("duplicate_frame", $"Skipped duplicate adapter callback for frame {frame}");
            return Snapshot();
        }

        if (!_host.IsCurrent(_binding.Actor))
        {
            TryStop("actor owner changed before frame");
            return Snapshot();
        }

        _lastFrame = frame;
        _frames++;
        RunFrame(frame);
        return Snapshot();
    }

    private bool TryStart(ScarletWardrobeSelection selection, ScarletActorContext actor)
    {
        _state = ScarletAdapterState.Binding;
        try
        {
            _dependencyReport = _host.CheckDynamicDependencies(selection);
            if (_dependencyReport is null || !_dependencyReport.Ready)
            {
                var missing = _dependencyReport?.Missing ?? Array.Empty<string>();
                var rejected = _dependencyReport?.Rejected ?? Array.Empty<string>();
                AddDiagnostic("dynamic_dependencies_missing",
                    $"missing=[{string.Join(",", missing)}] rejected=[{string.Join(",", rejected)}]");
                _state = ScarletAdapterState.Degraded;
                return false;
            }

            if (!_host.TryAcquireResources(selection, _dependencyReport, out var lease, out var acquireReason))
            {
                AddDiagnostic("resource_acquire_failed", acquireReason);
                _state = ScarletAdapterState.Degraded;
                return false;
            }

            if (!lease.IsValid || !string.Equals(lease.ModId, selection.ModId, StringComparison.Ordinal))
            {
                _host.ReleaseResources(lease);
                AddDiagnostic("resource_lease_invalid", "Host returned a lease for another identity");
                _state = ScarletAdapterState.Faulted;
                return false;
            }

            if (!_host.TryBind(selection, lease, actor, out var binding, out var bindReason))
            {
                _host.ReleaseResources(lease);
                AddDiagnostic("native_bind_failed", bindReason);
                _state = ScarletAdapterState.Degraded;
                return false;
            }

            if (!binding.IsValid || !ReferenceEquals(binding.Lease, lease) && binding.Lease.LeaseId != lease.LeaseId)
            {
                _host.ReleaseResources(lease);
                AddDiagnostic("binding_invalid", "Host returned a binding with a different lease or owner");
                _state = ScarletAdapterState.Faulted;
                return false;
            }

            _selection = selection;
            _binding = binding;
            _restoreUnresolved = false;
            _state = ScarletAdapterState.Active;
            AddDiagnosticOnce("activated", $"Activated {selection.ModId} ({selection.Variant}) for owner {actor.OwnerKey}");
            return true;
        }
        catch (Exception error)
        {
            AddDiagnostic("binding_exception", error.Message);
            _state = ScarletAdapterState.Faulted;
            return false;
        }
    }

    private void RunFrame(long frame)
    {
        var binding = _binding!;
        var nativeFrameFailed = false;

        try
        {
            var sheath = _host.TryLateSheath(binding);
            if (!sheath.IsBounded)
            {
                AddDiagnostic("late_sheath_unbounded", "Host exceeded the one native IK supplement per owner/frame");
                nativeFrameFailed = true;
            }
            else if (sheath.NativeCalls == 1) _lateSheathCalls++;
            if (sheath.Status == ScarletOperationStatus.Failed)
                AddDiagnostic("late_sheath_failed", sheath.Reason);

            var weapon = _host.TryUpdateWeaponAndSheath(binding);
            if (!weapon.IsBounded)
            {
                AddDiagnostic("weapon_sheath_unbounded", "Host exceeded one scoped weapon/sheath update per frame");
                nativeFrameFailed = true;
            }
            else if (weapon.NativeCalls == 1) _weaponSheathCalls++;
            if (weapon.Status == ScarletOperationStatus.Failed)
                AddDiagnostic("weapon_sheath_failed", weapon.Reason);

            foreach (var stage in Stages)
            {
                if (!_host.IsCurrent(binding.Actor)) throw new InvalidOperationException("Scarlet actor changed during native chain");

                if (stage == ScarletStage.ClothSolve)
                {
                    var before = _host.ApplyCoherentCloth(binding, ScarletClothPhase.BeforeClothSolve);
                    RecordCloth(before, "before cloth solve");
                }
                if (stage == ScarletStage.HipResponse)
                {
                    var before = _host.ApplyHipClearance(binding, ScarletHipPhase.BeforeNativeStage);
                    RecordHip(before, "before hip response");
                }

                if (!_host.ValidateStage(binding, stage, out var validateReason))
                    throw new InvalidOperationException($"Native stage validation failed ({stage}): {validateReason}");
                if (!_host.InvokeNativeStage(binding, stage, out var stageReason))
                    throw new InvalidOperationException($"Native stage failed ({stage}): {stageReason}");
                _nativeStageCalls++;

                if (stage == ScarletStage.ClothSolve)
                {
                    var after = _host.ApplyCoherentCloth(binding, ScarletClothPhase.AfterClothSolve);
                    RecordCloth(after, "after cloth solve");
                }
                if (stage == ScarletStage.HipResponse)
                {
                    var after = _host.ApplyHipClearance(binding, ScarletHipPhase.AfterNativeStage);
                    RecordHip(after, "after hip response");
                }
                if (stage == ScarletStage.ClothActorComponent)
                {
                    var finish = _host.ApplyCoherentCloth(binding, ScarletClothPhase.AfterClothActorComponent);
                    RecordCloth(finish, "after cloth actor component");
                }
            }
        }
        catch (Exception error)
        {
            nativeFrameFailed = true;
            AddDiagnostic("native_frame_failed", error.Message);
        }

        if (!_host.IsCurrent(binding.Actor)) nativeFrameFailed = true;
        if (nativeFrameFailed)
        {
            // TryStop quarantines the lease when any stage identity or host
            // operation is no longer trustworthy.  It never releases an
            // unresolved owner.
            TryStop("native frame failure");
            if (_binding is not null) _state = ScarletAdapterState.Faulted;
        }
        else if (_state == ScarletAdapterState.Active)
        {
            _state = _diagnostics.Any(x => x.StartsWith("late_sheath_failed", StringComparison.Ordinal) ||
                x.StartsWith("weapon_sheath_failed", StringComparison.Ordinal) ||
                x.StartsWith("cloth_", StringComparison.Ordinal) || x.StartsWith("hip_", StringComparison.Ordinal))
                ? ScarletAdapterState.Degraded
                : ScarletAdapterState.Active;
        }
    }

    private void RecordCloth(ScarletClothResult result, string phase)
    {
        if (!result.IsSafe)
        {
            AddDiagnostic("cloth_failed", $"{phase}: invalid write accounting");
            return;
        }
        _clothJointWrites += result.JointWrites;
        if (result.ScaleWrites != 0) AddDiagnostic("cloth_scale_write", $"{phase}: {result.ScaleWrites} scale writes were reported");
        if (result.Status == ScarletOperationStatus.NativeOnly)
            AddDiagnostic("cloth_native_only", $"{phase}: {result.Reason}");
        else if (result.Status == ScarletOperationStatus.Failed)
            AddDiagnostic("cloth_failed", $"{phase}: {result.Reason}");
    }

    private void RecordHip(ScarletHipResult result, string phase)
    {
        if (!result.IsSafe)
        {
            AddDiagnostic("hip_failed", $"{phase}: invalid scalar accounting");
            return;
        }
        _hipScalarWrites += result.ScalarWrites;
        if (result.Status == ScarletOperationStatus.Failed)
            AddDiagnostic("hip_failed", $"{phase}: {result.Reason}");
        else if (result.Status == ScarletOperationStatus.NativeOnly)
            AddDiagnostic("hip_native_only", $"{phase}: {result.Reason}");
    }

    private bool TryStop(string reason)
    {
        if (_binding is null)
        {
            _selection = null;
            _dependencyReport = null;
            _restoreUnresolved = false;
            return true;
        }

        _state = ScarletAdapterState.Stopping;
        ScarletRestoreResult restored;
        try
        {
            restored = _host.TryRestore(_binding, reason);
        }
        catch (Exception error)
        {
            AddDiagnostic("restore_exception", error.Message);
            _restoreUnresolved = true;
            return false;
        }

        if (!restored.IsSafe || !restored.CanRelease)
        {
            AddDiagnostic("restore_unresolved", restored.Reason);
            _restoreUnresolved = true;
            return false;
        }

        _restoredWrites += restored.RestoredWrites;
        _foreignChangesPreserved += restored.ForeignChangesPreserved;
        _host.ReleaseResources(_binding.Lease);
        _binding = null;
        _selection = null;
        _dependencyReport = null;
        _restoreUnresolved = false;
        _state = ScarletAdapterState.Disabled;
        return true;
    }

    private void FailClosed(string code, string message)
    {
        AddDiagnostic(code, message);
        _state = ScarletAdapterState.Faulted;
    }

    private void AddDiagnostic(string code, string message)
    {
        var line = $"{code}: {message}";
        if (_diagnostics.Count == 0 || !string.Equals(_diagnostics[^1], line, StringComparison.Ordinal))
            _diagnostics.Add(line);
        while (_diagnostics.Count > 128) _diagnostics.RemoveAt(0);
        _host.Diagnostic(code, message);
    }

    private void AddDiagnosticOnce(string code, string message)
    {
        if (_diagnostics.Any(item => item.StartsWith(code + ":", StringComparison.Ordinal))) return;
        AddDiagnostic(code, message);
    }

    private ScarletAdapterSnapshot Snapshot() => new(
        "scarlet-adapter-status-v1",
        _state,
        _host.Frame,
        _selection?.ModId,
        _selection?.Variant,
        _binding?.Actor.OwnerKey,
        _dependencyReport?.Ready == true,
        _restoreUnresolved,
        true,
        _frames,
        _nativeStageCalls,
        _lateSheathCalls,
        _weaponSheathCalls,
        _clothJointWrites,
        _hipScalarWrites,
        _restoredWrites,
        _foreignChangesPreserved,
        _diagnostics.ToArray());

    private static bool SameSelection(ScarletWardrobeSelection a, ScarletWardrobeSelection? b) =>
        b is not null && string.Equals(a.ModId, b.ModId, StringComparison.Ordinal) && a.Variant == b.Variant &&
        a.Revision == b.Revision && a.BodyNativeId == b.BodyNativeId &&
        a.CatalogRowsVerified == b.CatalogRowsVerified &&
        string.Equals(a.BodyPrefab, b.BodyPrefab, StringComparison.OrdinalIgnoreCase) &&
        string.Equals(a.BodyCatalog, b.BodyCatalog, StringComparison.OrdinalIgnoreCase) &&
        string.Equals(a.HeadPrefab, b.HeadPrefab, StringComparison.OrdinalIgnoreCase) &&
        string.Equals(a.HeadCatalog, b.HeadCatalog, StringComparison.OrdinalIgnoreCase) &&
        string.Equals(a.HairPrefab, b.HairPrefab, StringComparison.OrdinalIgnoreCase) &&
        string.Equals(a.HairCatalog, b.HairCatalog, StringComparison.OrdinalIgnoreCase);

    private static bool SameActor(ScarletActorContext a, ScarletActorContext b) =>
        a.ActorAddress == b.ActorAddress && a.BodyAddress == b.BodyAddress && a.Generation == b.Generation &&
        string.Equals(a.OwnerKey, b.OwnerKey, StringComparison.Ordinal) && string.Equals(a.SceneKey, b.SceneKey, StringComparison.Ordinal);

    public void Dispose()
    {
        if (_closed) return;
        TryStop("adapter dispose");
        _closed = true;
        _state = ScarletAdapterState.Closed;
    }
}
