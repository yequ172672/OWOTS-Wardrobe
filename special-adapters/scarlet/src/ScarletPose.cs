using System.Numerics;

namespace OWOTS.SpecialAdapters.Scarlet;

public readonly record struct ScarletPose(Vector3 Position, Quaternion Rotation)
{
    public static ScarletPose Identity => new(Vector3.Zero, Quaternion.Identity);

    public bool IsFiniteAndNormalized
    {
        get
        {
            var length = Rotation.Length();
            return IsFinite(Position) && IsFinite(Rotation) && float.IsFinite(length) && length > 0.5f && length < 1.5f;
        }
    }

    public ScarletPose Normalized()
    {
        if (!IsFiniteAndNormalized) throw new ArgumentException("Scarlet pose contains a non-finite position or quaternion");
        return this with { Rotation = Quaternion.Normalize(Rotation) };
    }

    private static bool IsFinite(Vector3 value) => float.IsFinite(value.X) && float.IsFinite(value.Y) && float.IsFinite(value.Z);
    private static bool IsFinite(Quaternion value) => float.IsFinite(value.X) && float.IsFinite(value.Y) &&
        float.IsFinite(value.Z) && float.IsFinite(value.W);
}

public readonly record struct ScarletLocalPose(Vector3 Position, Quaternion Rotation, Vector3 Scale)
{
    public bool IsFinite => float.IsFinite(Position.X) && float.IsFinite(Position.Y) && float.IsFinite(Position.Z) &&
        float.IsFinite(Rotation.X) && float.IsFinite(Rotation.Y) && float.IsFinite(Rotation.Z) && float.IsFinite(Rotation.W) &&
        float.IsFinite(Scale.X) && float.IsFinite(Scale.Y) && float.IsFinite(Scale.Z);
}

public sealed record ScarletClothGoal(string Name, string Domain, string Group, ScarletPose Pose, long Frame, string Key)
{
    public bool IsValid => !string.IsNullOrWhiteSpace(Name) && !string.IsNullOrWhiteSpace(Domain) &&
        !string.IsNullOrWhiteSpace(Group) && Frame >= 0 && !string.IsNullOrWhiteSpace(Key) && Pose.IsFiniteAndNormalized;
}

/// <summary>
/// Pure seven-root bridge ported from the audited coherent_cloth contract.
/// It computes a parent-preserving world P/Q batch and intentionally has no
/// setter or native dependency.  The host validates and writes the batch.
/// </summary>
public sealed class ScarletCoherentCloth
{
    public const float ApprovedFraction = 0.05f;

    private static readonly (string Name, string Group, string Domain)[] Roots =
    {
        ("Ab_SkirtL_S01", "L", "Actor"),
        ("Ab-Fr-SuiteA-01", "Front", "Actor"),
        ("Ab-R-SkirtA-01", "R", "Actor"),
        ("Ab-L-SkirtA-01", "L", "Actor"),
        ("Ab-R-SkirtQ-01", "R", "Body"),
        ("Ab-R-SkirtQ-02", "R", "Body"),
        ("Ab-L-SkirtA-02", "L", "Body"),
    };

    private const string Left = "Ab-L-SkirtA-01";
    private const string Right = "Ab-R-SkirtA-01";
    private const string Front = "Ab-Fr-SuiteA-01";
    private readonly float _fraction;
    private FrameState? _active;
    private long _lastFrame = -1;

    public ScarletCoherentCloth(float fraction = ApprovedFraction)
    {
        if (fraction is not (0f or ApprovedFraction))
            throw new ArgumentOutOfRangeException(nameof(fraction), "Only 0 or the audited 0.05 fraction is allowed");
        _fraction = fraction;
    }

    public bool IsBusy => _active is not null;

    public void Start(long frame, string key, IReadOnlyDictionary<string, ScarletPose> before)
    {
        if (_active is not null) throw new InvalidOperationException("Unfinished Scarlet cloth frame");
        if (frame < 0 || frame <= _lastFrame) throw new InvalidOperationException("Cloth frame must advance");
        if (string.IsNullOrWhiteSpace(key)) throw new ArgumentException("Cloth owner key is required", nameof(key));
        var copy = RequireSet(before, Roots.Select(root => root.Name));
        _lastFrame = frame;
        _active = new FrameState(frame, key, copy, null, "before");
    }

    public void SetKin(long frame, string key, IReadOnlyDictionary<string, ScarletPose> kin)
    {
        RequireStage(frame, key, "before");
        _active = _active! with { Kin = RequireSet(kin, new[] { Left, Right, Front }), Stage = "kin" };
    }

    public IReadOnlyList<ScarletClothGoal> Finish(long frame, string key, IReadOnlyDictionary<string, ScarletPose> desired)
    {
        RequireStage(frame, key, "kin");
        var state = _active!;
        var target = RequireSet(desired, new[] { Left, Right });
        var deltas = new Dictionary<string, Delta>(StringComparer.Ordinal);

        if (_fraction != 0)
        {
            deltas["L"] = MakeDelta(state.Kin![Left], target[Left]);
            deltas["R"] = MakeDelta(state.Kin[Right], target[Right]);
            var frontDeltaRotation = Normalize(Quaternion.Slerp(deltas["L"].Rotation, deltas["R"].Rotation, 0.5f));
            var pivot = state.Kin[Front].Position;
            var shift = (Displacement(deltas["L"], pivot) + Displacement(deltas["R"], pivot)) * 0.5f;
            deltas["Front"] = new Delta(frontDeltaRotation, pivot, shift);
        }

        var result = new List<ScarletClothGoal>(Roots.Length);
        foreach (var (name, group, domain) in Roots)
        {
            var old = state.Before[name];
            var pose = _fraction == 0 ? old : Apply(deltas[group], old);
            if (!pose.IsFiniteAndNormalized) throw new InvalidOperationException($"Computed invalid cloth goal: {name}");
            result.Add(new ScarletClothGoal(name, domain, group, pose.Normalized(), frame, key));
        }

        _active = null;
        return result;
    }

    public void Abort() => _active = null;

    public static IReadOnlyList<string> RootNames => Roots.Select(root => root.Name).ToArray();
    public static IReadOnlyList<string> KinNames => new[] { Left, Right, Front };
    public static IReadOnlyList<string> DesiredNames => new[] { Left, Right };

    private void RequireStage(long frame, string key, string stage)
    {
        if (_active is null || _active.Frame != frame || !string.Equals(_active.Key, key, StringComparison.Ordinal) ||
            !string.Equals(_active.Stage, stage, StringComparison.Ordinal))
            throw new InvalidOperationException("Cloth frame/owner/phase mismatch");
    }

    private static IReadOnlyDictionary<string, ScarletPose> RequireSet(IReadOnlyDictionary<string, ScarletPose> poses,
        IEnumerable<string> names)
    {
        var result = new Dictionary<string, ScarletPose>(StringComparer.Ordinal);
        foreach (var name in names)
        {
            if (!poses.TryGetValue(name, out var pose) || !pose.IsFiniteAndNormalized)
                throw new InvalidOperationException($"Missing or invalid cloth pose: {name}");
            result[name] = pose.Normalized();
        }
        return result;
    }

    private Delta MakeDelta(ScarletPose oldPose, ScarletPose goal)
    {
        var total = Normalize(Quaternion.Multiply(Normalize(goal.Rotation), Quaternion.Inverse(Normalize(oldPose.Rotation))));
        var rotation = Normalize(Quaternion.Slerp(Quaternion.Identity, total, _fraction));
        var shift = (goal.Position - oldPose.Position) * _fraction;
        return new Delta(rotation, oldPose.Position, shift);
    }

    private static Vector3 Displacement(Delta delta, Vector3 point)
    {
        var relative = point - delta.Pivot;
        return Vector3.Transform(relative, delta.Rotation) - relative + delta.Shift;
    }

    private static ScarletPose Apply(Delta delta, ScarletPose old)
    {
        var relative = old.Position - delta.Pivot;
        var change = Vector3.Transform(relative, delta.Rotation) - relative + delta.Shift;
        return new ScarletPose(old.Position + change, Normalize(Quaternion.Multiply(delta.Rotation, Normalize(old.Rotation))));
    }

    private static Quaternion Normalize(Quaternion value)
    {
        if (!float.IsFinite(value.X) || !float.IsFinite(value.Y) || !float.IsFinite(value.Z) || !float.IsFinite(value.W))
            throw new InvalidOperationException("Non-finite cloth quaternion");
        var length = value.Length();
        if (!float.IsFinite(length) || length <= 0.000001f) throw new InvalidOperationException("Zero cloth quaternion");
        return Quaternion.Normalize(value);
    }

    private sealed record FrameState(long Frame, string Key, IReadOnlyDictionary<string, ScarletPose> Before,
        IReadOnlyDictionary<string, ScarletPose>? Kin, string Stage);
    private readonly record struct Delta(Quaternion Rotation, Vector3 Pivot, Vector3 Shift);
}

public static class ScarletHipClearance
{
    public const float InnerRadiusMeters = 0.35f;
    public const float OuterRadiusMeters = 0.55f;

    /// <summary>Returns 1 inside the clearance plateau and 0 outside the taper.</summary>
    public static float Weight(float distanceMeters, float inner = InnerRadiusMeters, float outer = OuterRadiusMeters)
    {
        if (!float.IsFinite(distanceMeters) || distanceMeters < 0) throw new ArgumentOutOfRangeException(nameof(distanceMeters));
        if (!float.IsFinite(inner) || !float.IsFinite(outer) || inner < 0 || outer <= inner)
            throw new ArgumentOutOfRangeException(nameof(inner), "Hip clearance radii are invalid");
        if (distanceMeters <= inner) return 1f;
        if (distanceMeters >= outer) return 0f;
        var t = Math.Clamp((distanceMeters - inner) / (outer - inner), 0f, 1f);
        return 1f - t * t * (3f - 2f * t);
    }

    public static float Weight(Vector3 handWorld, Vector3 pelvisWorld) =>
        Weight(Vector3.Distance(handWorld, pelvisWorld));

    /// <summary>The native register consumes the scalar in centimetres.</summary>
    public static float EncodeNativeRegister(float weight) =>
        float.IsFinite(weight) && weight is >= 0 and <= 1 ? weight / 100f : throw new ArgumentOutOfRangeException(nameof(weight));
}

/// <summary>
/// A host-side guard for cache restores.  It captures a token and only allows
/// restoration while the current value still equals the value written by this
/// adapter.  A different mod/game write is preserved.
/// </summary>
public sealed class ScarletScopedMutation<T> where T : notnull
{
    public ScarletScopedMutation(string ownerKey, T original, T written)
    {
        OwnerKey = string.IsNullOrWhiteSpace(ownerKey) ? throw new ArgumentException("Owner key is required", nameof(ownerKey)) : ownerKey;
        Original = original;
        Written = written;
    }

    public string OwnerKey { get; }
    public T Original { get; }
    public T Written { get; }
    public bool CanRestore(T current) => EqualityComparer<T>.Default.Equals(current, Written);
}
