using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Reflection.Emit;
using System.Runtime.InteropServices;
using System.Threading;
using Hexa.NET.ImGui;
using REFrameworkNET;
using REFrameworkNET.Attributes;
using REFrameworkNET.Callbacks;
using OWOTS.Appearance;

#if ONIMUSHAWOTS
// Development probe for native catalog registration. Idle until a request file is submitted.
// Commands execute on UpdateBehavior.Post; no inventory, save or weapon-stat setters are used.
public static class OWOTSAppearanceLab {
    static string s_dir;
    static string s_lastId;
    static long s_nextPoll;
    static volatile bool s_stopped;
    static int s_adapterGameThreadId;
    static long s_adapterRevision;
    static string s_adapterIdentity;
    static readonly string s_adapterSessionId = Guid.NewGuid().ToString("N");
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate int AdapterSnapshotCallback(IntPtr buffer, int capacity);
    static readonly AdapterSnapshotCallback s_adapterSnapshotCallback = WriteAdapterSnapshot;
    static bool s_adapterBridgeRegistered, s_adapterBridgeUnavailable;
    [DllImport("dinput8.dll", CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    static extern bool owots_adapter_register_snapshot(AdapterSnapshotCallback callback);
    [DllImport("dinput8.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern void owots_adapter_unregister_snapshot(AdapterSnapshotCallback callback);

    // Reload is deliberately a two-phase protocol.  The request is accepted on
    // UpdateBehavior.Post, Lua restores its independent skeleton there, and only
    // after the matching status file is observed do we release native appearance
    // resources and publish the unload permit.  The permit is an atomic scalar so
    // the native PluginManager can query it from its rendering-side unload guard.
    sealed class ReloadHandoff {
        public int SchemaVersion { get; set; }
        public int Pid { get; set; }
        public long ProcessStartTimeUtcTicks { get; set; }
        public string Token { get; set; }
        public string SessionId { get; set; }
        public WardrobeSelectionState State { get; set; }
        public WardrobePreferences Preferences { get; set; }
        public bool PersistenceEnabled { get; set; }
        public bool AutomaticRestoreEnabled { get; set; }
        public bool NativeMenuSyncEnabled { get; set; }
        public long CreatedAtUtcTicks { get; set; }
    }
    sealed class ReloadLuaStatus {
        public string Token;
        public string SessionId;
        public int Pid;
        public bool HasPid;
        public bool Owned;
        public bool RestorePending;
        public bool RestoreUnresolved;
        public bool Blocked;
        public bool ScriptResetRequiresRestart;
        public object PartFailure;
        public string RawReason;
    }
    sealed class ReloadResumeJob {
        public string Id;
        public ReloadHandoff Handoff;
        public int Stage;
        public bool Waiting;
        public bool SettingsApplied;
        public bool CleanupNeeded;
        public string Error;
    }
    static readonly JsonSerializerOptions s_reloadJsonOptions = new JsonSerializerOptions {
        PropertyNameCaseInsensitive = true
    };
    static readonly string s_reloadStatusFileName = "owots-wardrobe-skeleton-status.json";
    static string s_reloadPhase = "idle";
    static string s_reloadToken;
    static string s_reloadReason;
    static string s_reloadHandoffError;
    static long s_reloadDeadline;
    static volatile bool s_reloadFreeze;
    static volatile bool s_reloadCleanupActive;
    static int s_reloadPermit;
    static ReloadHandoff s_reloadHandoff;
    static ReloadResumeJob s_reloadResume;
    static ReloadLuaStatus s_lastReloadLuaStatus;
    static bool s_reloadResumeNeedsClear;

    static long CurrentProcessStartTimeUtcTicks() {
        try { return Process.GetCurrentProcess().StartTime.ToUniversalTime().Ticks; }
        catch { return 0; }
    }

    static string ReloadHandoffPath() => Path.Combine(s_dir, "reload-handoff.json");
    static string ReloadStatusPath() => Path.Combine(
        Path.GetDirectoryName(Process.GetCurrentProcess().MainModule.FileName),
        "reframework", "data", s_reloadStatusFileName);

    static int WriteAdapterSnapshot(IntPtr buffer, int capacity) {
        try {
            if (buffer == IntPtr.Zero || capacity <= 0 || capacity > 65536) return 0;
            var bytes = System.Text.Encoding.UTF8.GetBytes(GetAdapterSnapshotJson());
            if (bytes.Length >= capacity) return 0;
            Marshal.Copy(bytes, 0, buffer, bytes.Length);
            return bytes.Length;
        } catch { return 0; } // Never unwind a managed exception through Lua/native code.
    }

    static void RegisterAdapterBridge() {
        if (s_adapterBridgeRegistered || s_adapterBridgeUnavailable || s_stopped) return;
        try { s_adapterBridgeRegistered = owots_adapter_register_snapshot(s_adapterSnapshotCallback); }
        catch (DllNotFoundException) { s_adapterBridgeUnavailable = true; }
        catch (EntryPointNotFoundException) { s_adapterBridgeUnavailable = true; }
    }
    sealed class VisibilityProbeTarget {
        public ManagedObject Owner;
        public bool Original;
        public string Part;
    }
    static readonly List<VisibilityProbeTarget> s_visibilityProbe = new List<VisibilityProbeTarget>();
    static long s_visibilityProbeDeadline;
    static string s_visibilityProbeRequest;
    sealed class HiddenObject {
        public ManagedObject Owner;
        public int RequestedDraw;
    }
    static Dictionary<ulong, HiddenObject> s_hiddenObjects = new Dictionary<ulong, HiddenObject>();
    static HashSet<string> s_hiddenParts = new HashSet<string>();
    static bool s_visibilityHookInstalled;
    [ThreadStatic] static bool s_ownVisibilityWrite;
    static string s_visibilityStatus = "disabled";
    static long s_visibilityFrames;
    static long s_visibilityAuditUntil;
    static readonly Dictionary<string, long[]> s_visibilityAudit = new Dictionary<string, long[]>();
    // Opt-in, read-only observations of the SAME pinned targets at later phases.
    // Never resolve hierarchy or modify objects on rendering callbacks.
    static void AuditVisibility(string phase) {
        if (s_stopped || Environment.TickCount64 >= s_visibilityAuditUntil) return;
        long checkedCount = 0, visible = 0, errors = 0;
        foreach (var target in Volatile.Read(ref s_hiddenObjects).Values) {
            try {
                var obj = target.Owner.As<via.GameObject>();
                if (!Alive(obj) || !obj.Valid) continue;
                checkedCount++;
                if (obj.DrawSelf || obj.Draw) visible++;
            } catch { errors++; }
        }
        lock (s_visibilityAudit) {
            if (!s_visibilityAudit.TryGetValue(phase, out var row))
                s_visibilityAudit[phase] = row = new long[4];
            row[0]++; row[1] += checkedCount; row[2] += visible; row[3] += errors;
        }
    }
    [Callback(typeof(LateUpdateBehavior), CallbackType.Post)]
    public static void AuditLateVisibility() {
        AuditVisibility("LateUpdateBehavior.Post.BeforeHide");
        ReapplyHiddenVisibility();
        AuditVisibility("LateUpdateBehavior.Post.AfterHide");
    }
    [Callback(typeof(PrepareRendering), CallbackType.Pre)]
    public static void AuditPrepareVisibility() => AuditVisibility("PrepareRendering.Pre");
    static object VisibilityAudit(JsonElement request) {
        lock (s_visibilityAudit) {
            if (request.TryGetProperty("start", out var start) && start.GetBoolean()) {
                s_visibilityAudit.Clear();
                s_visibilityAuditUntil = Environment.TickCount64 + 30000;
            }
            return new { active = Environment.TickCount64 < s_visibilityAuditUntil,
                columns = new[] { "callbacks", "objectsChecked", "visibleObservations", "errors" },
                phases = s_visibilityAudit.ToDictionary(pair => pair.Key, pair => pair.Value.ToArray()) };
        }
    }
    sealed class WardrobeApplyJob {
        public string Id, StepId, Error;
        public WardrobeSelectionState State;
        public WardrobeCompositionResult Plan;
        public List<AppearanceEntry> Entries;
        public int Stage;
        public bool Waiting;
        public AppearanceOperationClock Clock = new AppearanceOperationClock(Environment.TickCount64);
    }
    static WardrobeSelectionState s_wardrobeState;
    static WardrobeApplyJob s_wardrobeJob;
    static ManagedObject s_loadOwner;
    static via.Prefab s_loadPrefab;
    static string s_loadId;
    static long s_loadDeadline;
    static bool s_loadSelectBody;
    static ManagedObject s_visualOwner;
    static via.Prefab s_visualPrefab;
    static bool s_tracing;
    static bool s_traceHookInstalled;
    static bool s_visualHooksInstalled;
    static ulong s_visualSupporter;
    static ManagedObject s_registeredSupporterOwner;
    static ulong s_visualManager;
    static int s_visualBodyId = -1;
    static bool s_aliasRegistered;
    [ThreadStatic] static Stack<bool> s_visualScopes;
    [ThreadStatic] static Stack<int> s_visualLookups;
    static Dictionary<int, int> s_selectedParts = new Dictionary<int, int>();
    sealed class OutfitPart {
        public int Part, Id;
        public ManagedObject Owner;
        public via.Prefab Prefab;
        public bool Registered;
        public bool RegisteredHQ;
        public string ExpectedPrefab;
        public string ExpectedCatalog;
        public ManagedObject NormalCatalogOwner, HQCatalogOwner;
        public Action RemoveNormal, RemoveHQ;
    }
    static readonly List<OutfitPart> s_outfitParts = new List<OutfitPart>();
    static readonly List<OutfitPart> s_preloadParts = new List<OutfitPart>();
    static readonly Dictionary<AppearanceKind, string> s_activeMods = new Dictionary<AppearanceKind, string>();
    static AppearanceKind s_pendingKind;
    static AppearanceKind? s_transitionKind;
    static string s_outfitRequest;
    static long s_outfitDeadline;
    static RegistrySnapshot s_registry;
    static readonly Dictionary<string, int> s_registrySlots = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
    static string s_pendingModId, s_activeModId;
    static string s_transitionRequest;
    sealed record MenuState(AppearanceEntry[] Entries, string Outfit, string Weapon, bool Busy, string Message, string[] Issues,
        WardrobeSelectionState State = null, WardrobeCompositionResult Composition = null,
        Dictionary<string, WardrobeCategory> Categories = null);
    static MenuState s_menu = new MenuState(Array.Empty<AppearanceEntry>(), null, null, false, "就绪", Array.Empty<string>());
    static WardrobeRegistrySnapshot s_wardrobeRegistry;
    sealed record WardrobeMenuConfirmation(string Category, string ModId, bool? Visible, string[] Declarations, string[] Names);
    static WardrobeMenuConfirmation s_confirmation;
    static string s_menuRequest;
    static string s_menuMessage = "就绪";
    static bool s_windowOpen, s_cardMode;
    static WardrobePreferences s_preferences = new WardrobePreferences();
    static bool s_applyStartupPreferences;
    static string s_search = "", s_focusedEntry;
    static WardrobeCategory s_browseCategory;
    static readonly object s_iconLock = new object();
    static readonly Dictionary<string, ulong> s_icons = new Dictionary<string, ulong>();
    static bool s_iconApiUnavailable;
    static int s_refreshIcons;
    static readonly NativeCostumeSelections s_nativeSelections = new NativeCostumeSelections();
    static bool s_nativeMenuHooks;
    static volatile bool s_nativeMenuSync;
    static int s_nativeMenuPending;
    static string s_nativeMenuRequest;
    [ThreadStatic] static Stack<ulong> s_nativeApplyScopes, s_nativeCloseScopes;
    [ThreadStatic] static Stack<(ulong Owner, int Category)> s_nativeDecideScopes;
    [DllImport("dinput8.dll", CharSet = CharSet.Unicode, CallingConvention = CallingConvention.Cdecl)]
    static extern ulong owots_ui_icon_load(string path);
    [DllImport("dinput8.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern void owots_ui_icon_release(ulong id);
    [DllImport("dinput8.dll", CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    static extern bool owots_ui_icon_draw(ulong id, float width, float height);
    static AppearanceEntry s_transitionEntry;
    static int s_transitionSlot;
    static long s_transitionDeadline;
    static readonly object s_traceLock = new object();
    static readonly List<object> s_modelTrace = new List<object>();
    static bool s_saveTraceInstalled;
    static volatile bool s_saveTracing;
    static long s_saveSequence;
    [ThreadStatic] static Stack<long> s_saveLoadScopes;
    static readonly object s_saveTraceLock = new object();
    static readonly List<object> s_saveTrace = new List<object>();
    [ThreadStatic] static Stack<long> s_saveWriteScopes;
    static readonly Dictionary<ulong, long> s_saveWriteClosures = new Dictionary<ulong, long>();
    static ulong s_saveCompletionFunction;
    static volatile bool s_persistenceEnabled;
    static AppearanceSaveTransactions<WardrobeSelectionState> s_saveTransactions = new AppearanceSaveTransactions<WardrobeSelectionState>();
    static readonly Queue<AppearanceSnapshot<WardrobeSelectionState>> s_saveCommits = new Queue<AppearanceSnapshot<WardrobeSelectionState>>();
    static WardrobeSelectionState s_saveSnapshot;
    static string s_persistenceStatus = "未启用外观记录写入";
    sealed class LoadTrace { public int Slot, Results; public bool Success; }
    static readonly Dictionary<long, LoadTrace> s_loadIdentities = new Dictionary<long, LoadTrace>();
    static readonly AppearanceLoadCoordinator s_loadCoordinator = new AppearanceLoadCoordinator();
    static volatile bool s_autoRestoreEnabled;
    sealed class RestoreJob {
        public AppearanceSaveKey Key;
        public AppearanceLoadTicket Ticket;
        public WardrobeSelectionState Choices;
        public int Stage;
        public bool Waiting;
        public string OperationId;
        public AppearanceOperationClock Clock;
        public List<string> Issues = new List<string>();
    }
    static RestoreJob s_restoreJob;
    static volatile bool s_restoreUnresolved;
    sealed record MissingIntentContext(AppearanceSaveKey Key, UnavailableAppearanceIntent Intent);
    static MissingIntentContext s_missingIntent;
    sealed class MeshSwap {
        public via.render.Mesh Component;
        public via.render.MeshResourceHolder OriginalMesh, ModMesh;
        public via.render.MeshMaterialResourceHolder OriginalMaterial, ModMaterial;
        public ManagedObject MeshOwner, MaterialOwner;
        public string OriginalPath;
    }
    static readonly List<MeshSwap> s_meshSwaps = new List<MeshSwap>();
    static app.AfterImageController s_swapAfterImage;

    [PluginEntryPoint]
    public static void Main() {
        s_dir = Path.Combine(Path.GetDirectoryName(Process.GetCurrentProcess().MainModule.FileName),
            "reframework", "data", "owots_appearance_lab");
        Directory.CreateDirectory(s_dir);
        try {
            s_preferences = WardrobePreferences.Read(Path.Combine(s_dir, "preferences.json"));
            s_cardMode = s_preferences.Cards;
            s_applyStartupPreferences = true;
        } catch (Exception e) { s_menuMessage = "设置读取失败，使用默认设置：" + e.Message; }
        LoadReloadHandoff();
        // Do not replay an old file command after UI actions or plugin reload.
        var response = Path.Combine(s_dir, "request.json");
        if (File.Exists(response)) {
            try { using var doc = JsonDocument.Parse(File.ReadAllText(response));
                s_lastId = doc.RootElement.GetProperty("id").GetString(); } catch { }
        }
        API.LogInfo("[OWOTS Appearance Lab] Ready; native catalog probes are opt-in.");
        try { ReadRegistry(); PublishMenu(); }
        catch (Exception e) { s_menuMessage = "读取外观目录失败：" + e.Message; PublishMenu(); }
    }

    static bool TryGetProperty(JsonElement root, string name, out JsonElement value) {
        if (root.TryGetProperty(name, out value)) return true;
        foreach (var property in root.EnumerateObject())
            if (string.Equals(property.Name, name, StringComparison.OrdinalIgnoreCase)) {
                value = property.Value;
                return true;
            }
        value = default;
        return false;
    }

    static bool TryGetRequiredString(JsonElement root, string name, out string value) {
        value = null;
        return TryGetProperty(root, name, out var property) && property.ValueKind == JsonValueKind.String &&
            (value = property.GetString()) != null;
    }

    static bool TryGetRequiredBool(JsonElement root, string name, out bool value) {
        value = false;
        if (!TryGetProperty(root, name, out var property) ||
            (property.ValueKind != JsonValueKind.True && property.ValueKind != JsonValueKind.False)) return false;
        value = property.GetBoolean();
        return true;
    }

    static bool TryGetRequiredPid(JsonElement root, string name, out int value) {
        value = 0;
        return TryGetProperty(root, name, out var property) && property.ValueKind == JsonValueKind.Number &&
            property.TryGetInt32(out value);
    }

    // Pure, fail-closed handshake validator.  It intentionally requires every
    // ownership/restore flag instead of interpreting a missing field as false.
    // Keep this helper side-effect free so an offline harness can exercise stale,
    // mismatched and partially-written Lua status files.
    internal static bool ValidateReloadLuaStatus(string json, string token, string sessionId, int pid) {
        try {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (!TryGetRequiredString(root, "schema", out var schema) ||
                schema != "owots-wardrobe-skeleton-status-v1" ||
                !TryGetRequiredString(root, "bridge_reload_token", out var actualToken) ||
                !string.Equals(actualToken, token, StringComparison.Ordinal) ||
                !TryGetRequiredString(root, "bridge_session_id", out var actualSession) ||
                !string.Equals(actualSession, sessionId, StringComparison.Ordinal) ||
                !TryGetRequiredPid(root, "bridge_pid", out var actualPid) || actualPid != pid)
                return false;
            var required = new[] { "owned", "restore_pending", "restore_unresolved", "blocked",
                "script_reset_requires_restart", "close_requested", "restore_request_queued" };
            bool ignored;
            foreach (var name in required)
                if (!TryGetRequiredBool(root, name, out ignored)) return false;
            if (!TryGetRequiredBool(root, "owned", out var owned) || owned ||
                !TryGetRequiredBool(root, "restore_pending", out var pending) || pending ||
                !TryGetRequiredBool(root, "restore_unresolved", out var unresolved) || unresolved ||
                !TryGetRequiredBool(root, "blocked", out var blocked) || blocked ||
                !TryGetRequiredBool(root, "script_reset_requires_restart", out var reset) || reset ||
                !TryGetRequiredBool(root, "close_requested", out var close) || close ||
                !TryGetRequiredBool(root, "restore_request_queued", out var queued) || queued)
                return false;
            return true;
        } catch { return false; }
    }

    static bool TryParseReloadLuaStatus(string json, string token, string sessionId, int pid,
        out ReloadLuaStatus status, out string reason) {
        status = null;
        reason = null;
        try {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (!TryGetRequiredString(root, "schema", out var schema) ||
                schema != "owots-wardrobe-skeleton-status-v1") { reason = "lua_schema_mismatch"; return false; }
            if (!TryGetRequiredString(root, "bridge_reload_token", out var actualToken) ||
                !string.Equals(actualToken, token, StringComparison.Ordinal)) { reason = "lua_token_mismatch"; return false; }
            if (!TryGetRequiredString(root, "bridge_session_id", out var actualSession) ||
                !string.Equals(actualSession, sessionId, StringComparison.Ordinal)) { reason = "lua_session_mismatch"; return false; }
            if (!TryGetRequiredPid(root, "bridge_pid", out var actualPid) || actualPid != pid) { reason = "lua_pid_mismatch"; return false; }
            bool owned, pending, unresolved, blocked, reset, close, queued;
            if (!TryGetRequiredBool(root, "owned", out owned)) { reason = "lua_flag_missing_or_invalid:owned"; return false; }
            if (!TryGetRequiredBool(root, "restore_pending", out pending)) { reason = "lua_flag_missing_or_invalid:restore_pending"; return false; }
            if (!TryGetRequiredBool(root, "restore_unresolved", out unresolved)) { reason = "lua_flag_missing_or_invalid:restore_unresolved"; return false; }
            if (!TryGetRequiredBool(root, "blocked", out blocked)) { reason = "lua_flag_missing_or_invalid:blocked"; return false; }
            if (!TryGetRequiredBool(root, "script_reset_requires_restart", out reset)) { reason = "lua_flag_missing_or_invalid:script_reset_requires_restart"; return false; }
            if (!TryGetRequiredBool(root, "close_requested", out close)) { reason = "lua_flag_missing_or_invalid:close_requested"; return false; }
            if (!TryGetRequiredBool(root, "restore_request_queued", out queued)) { reason = "lua_flag_missing_or_invalid:restore_request_queued"; return false; }
            status = new ReloadLuaStatus { Token = actualToken, SessionId = actualSession, Pid = actualPid,
                HasPid = true, Owned = owned, RestorePending = pending, RestoreUnresolved = unresolved,
                Blocked = blocked, ScriptResetRequiresRestart = reset, RawReason = null };
            if (TryGetProperty(root, "bridge_part_failure", out var partFailure) && partFailure.ValueKind != JsonValueKind.Null)
                status.PartFailure = JsonSerializer.Deserialize<object>(partFailure.GetRawText());
            if (TryGetProperty(root, "phase_reason", out var phaseReason) && phaseReason.ValueKind == JsonValueKind.String)
                status.RawReason = phaseReason.GetString();
            if (owned || pending || unresolved || blocked || reset || close || queued) {
                reason = owned ? "lua_still_owned" : pending ? "lua_restore_pending" : unresolved ? "lua_restore_unresolved" :
                    blocked ? "lua_restore_blocked" : reset ? "lua_script_reset_requires_restart" :
                    close ? "lua_close_requested" : "lua_restore_request_queued";
                return false;
            }
            return ValidateReloadLuaStatus(json, token, sessionId, pid);
        } catch (JsonException) { reason = "lua_status_invalid_json"; return false; }
        catch { reason = "lua_status_unavailable"; return false; }
    }

    static void LoadReloadHandoff() {
        var path = ReloadHandoffPath();
        if (!File.Exists(path)) return;
        try {
            var info = new FileInfo(path);
            if (info.Length <= 0 || info.Length > 1024 * 1024) throw new FormatException("Reload handoff size is invalid");
            var handoff = JsonSerializer.Deserialize<ReloadHandoff>(File.ReadAllText(path), s_reloadJsonOptions);
            if (handoff == null || handoff.SchemaVersion != 1 || handoff.Pid != Environment.ProcessId ||
                handoff.ProcessStartTimeUtcTicks == 0 || handoff.ProcessStartTimeUtcTicks != CurrentProcessStartTimeUtcTicks() ||
                string.IsNullOrWhiteSpace(handoff.Token) || string.IsNullOrWhiteSpace(handoff.SessionId) || handoff.State == null)
                throw new InvalidOperationException("Reload handoff identity is stale or incomplete");
            handoff.State = WardrobeSaveStore.Freeze(handoff.State);
            handoff.Preferences = (handoff.Preferences ?? new WardrobePreferences()).Validate();
            if (handoff.AutomaticRestoreEnabled && !handoff.PersistenceEnabled)
                throw new InvalidOperationException("Reload handoff has invalid runtime persistence flags");
            s_reloadHandoff = handoff;
            s_reloadToken = handoff.Token;
            s_reloadFreeze = true;
            SetReloadPhase("handoff_pending", "explicit_resume_required");
            s_reloadReason = "explicit_resume_required";
        } catch (Exception e) {
            s_reloadHandoffError = e.Message;
            s_reloadReason = "handoff_ignored:" + e.Message;
        }
    }

    static WardrobeSelectionState CurrentWardrobeState() {
        s_activeMods.TryGetValue(AppearanceKind.Outfit, out var outfit);
        s_activeMods.TryGetValue(AppearanceKind.Weapon, out var weapon);
        return WardrobeSaveStore.Freeze(s_wardrobeState ??
            WardrobeSelections.FromLegacy(new SavedAppearance(outfit, weapon)));
    }

    static bool ReloadOperationBusy() {
        return s_wardrobeJob != null || s_transitionRequest != null || s_outfitRequest != null || s_loadId != null ||
            s_restoreJob != null || s_loadCoordinator.HasPending || s_visibilityProbeRequest != null ||
            s_nativeMenuRequest != null || Volatile.Read(ref s_nativeMenuPending) != 0 ||
            Volatile.Read(ref s_menuRequest) != null || s_meshSwaps.Count > 0;
    }

    static void SetReloadPhase(string phase, string reason) {
        Interlocked.Exchange(ref s_reloadPhase, phase);
        s_reloadReason = reason;
    }

    static void WriteReloadHandoff(ReloadHandoff handoff) {
        var path = ReloadHandoffPath();
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None)) {
                var bytes = JsonSerializer.SerializeToUtf8Bytes(handoff);
                stream.Write(bytes, 0, bytes.Length);
                stream.Flush(true);
            }
            File.Move(temporary, path, true);
        } finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    static object BeginReloadPreparation(string id) {
        var phase = Volatile.Read(ref s_reloadPhase);
        if (phase != "idle" && phase != "failed")
            throw new InvalidOperationException("Reload is already prepared or in progress; use reload_status or resume_reload");
        if (ReloadOperationBusy()) throw new InvalidOperationException("Reload preparation requires an idle appearance runtime");
        lock (s_saveTraceLock) {
            if (s_saveCommits.Count != 0 || s_saveWriteClosures.Count != 0)
                throw new InvalidOperationException("A save transaction is still pending; retry after it is committed");
        }
        // A failed attempt may already have withdrawn part of the live native
        // selection.  Retry from the original immutable handoff, never from the
        // partially-cleared runtime fields.
        var previous = phase == "failed" ? s_reloadHandoff : null;
        var state = previous?.State ?? CurrentWardrobeState();
        var token = Guid.NewGuid().ToString("N");
        var handoff = new ReloadHandoff { SchemaVersion = 1, Pid = Environment.ProcessId,
            ProcessStartTimeUtcTicks = CurrentProcessStartTimeUtcTicks(), Token = token,
            SessionId = s_adapterSessionId, State = state,
            Preferences = previous?.Preferences ?? Volatile.Read(ref s_preferences),
            PersistenceEnabled = previous?.PersistenceEnabled ?? s_persistenceEnabled,
            AutomaticRestoreEnabled = previous?.AutomaticRestoreEnabled ?? s_autoRestoreEnabled,
            NativeMenuSyncEnabled = previous?.NativeMenuSyncEnabled ?? s_nativeMenuSync,
            CreatedAtUtcTicks = DateTime.UtcNow.Ticks };
        try { WriteReloadHandoff(handoff); }
        catch (Exception e) { throw new InvalidOperationException("Cannot write reload handoff: " + e.Message, e); }
        s_reloadHandoff = handoff;
        s_reloadHandoffError = null;
        s_reloadToken = token;
        s_reloadDeadline = Environment.TickCount64 + 30000;
        s_reloadResumeNeedsClear = false;
        Interlocked.Exchange(ref s_reloadPermit, 0);
        s_reloadFreeze = true;
        s_reloadCleanupActive = false;
        s_reloadRequestId = id;
        Interlocked.Exchange(ref s_nativeMenuPending, 0);
        s_nativeSelections.Clear();
        SetReloadPhase("preparing", "waiting_lua_restore");
        s_reloadResume = null;
        PublishMenu();
        return new { phase = "waiting_lua_restore", reloadToken = token, sessionId = s_adapterSessionId,
            pid = Environment.ProcessId, timeoutMs = 30000 };
    }

    static object ReloadStatus() {
        var lua = Volatile.Read(ref s_lastReloadLuaStatus);
        return new { schemaVersion = 1, phase = Volatile.Read(ref s_reloadPhase), reason = s_reloadReason,
            ready = CanUnload(), permit = Volatile.Read(ref s_reloadPermit) == 1, frozen = s_reloadFreeze,
            reloadToken = s_reloadToken, sessionId = s_adapterSessionId, pid = Environment.ProcessId,
            handoffAvailable = s_reloadHandoff != null, handoffError = s_reloadHandoffError,
            deadline = s_reloadDeadline, lua = lua == null ? null : new { token = lua.Token, sessionId = lua.SessionId,
                pid = lua.Pid, owned = lua.Owned, restorePending = lua.RestorePending,
                restoreUnresolved = lua.RestoreUnresolved, blocked = lua.Blocked,
                scriptResetRequiresRestart = lua.ScriptResetRequiresRestart, reason = lua.RawReason,
                partFailure = lua.PartFailure },
            resources = new { selectedParts = s_selectedParts.Count, outfitParts = s_outfitParts.Count,
                preloadParts = s_preloadParts.Count, aliasRegistered = s_aliasRegistered,
                loadOwner = s_loadOwner != null, visualOwner = s_visualOwner != null,
                registeredSupporterOwner = s_registeredSupporterOwner != null,
                visibilityProbe = s_visibilityProbe.Count, hiddenObjects = s_hiddenObjects.Count,
                meshSwaps = s_meshSwaps.Count } };
    }

    static void FailReload(string reason, Exception error = null, string phase = "failed") {
        Interlocked.Exchange(ref s_reloadPermit, 0);
        s_reloadCleanupActive = false;
        s_reloadReason = error == null ? reason : reason + ":" + error.Message;
        SetReloadPhase(phase, s_reloadReason);
        s_reloadResumeNeedsClear |= HasRegistered(null) || s_hiddenObjects.Count > 0 || s_hiddenParts.Count > 0;
        var id = s_reloadRequestId;
        s_reloadRequestId = null;
        if (id != null) Respond(id, false, new { phase, reason = s_reloadReason,
            reloadToken = s_reloadToken, resources = ReloadStatus() });
    }

    static string s_reloadRequestId;

    static bool CleanupReloadNative() {
        s_reloadCleanupActive = true;
        try {
            if (s_visibilityProbe.Count > 0 || s_meshSwaps.Count > 0)
                throw new InvalidOperationException("Diagnostic probe resources are active; clear them before reload");
            // Native DrawSelf restoration and catalog/model restoration both run
            // here on UpdateBehavior.Post, never from PluginExitPoint.
            if (s_visibilityProbeRequest != null) throw new InvalidOperationException("Visibility probe is still active");
            RestoreVisibilityProbe();
            s_hiddenParts.Clear();
            PollVisibility();
            if (s_hiddenObjects.Count != 0) return false;
            if (s_loadId != null || s_loadOwner != null || s_loadPrefab != null) return false;
            ClearBodyAlias();
            if (HasRegistered(null) || s_selectedParts.Count != 0 || s_preloadParts.Count != 0 ||
                s_outfitParts.Count != 0 || s_registeredSupporterOwner != null || s_visualOwner != null ||
                s_loadOwner != null || s_loadPrefab != null)
                return false;
            s_visualBodyId = -1;
            s_nativeSelections.Clear();
            Interlocked.Exchange(ref s_nativeMenuPending, 0);
            s_nativeMenuSync = false;
            s_reloadResumeNeedsClear = false;
            return true;
        } finally { s_reloadCleanupActive = false; }
    }

    static bool PollReloadPreparation() {
        var phase = Volatile.Read(ref s_reloadPhase);
        if (phase != "preparing" && phase != "cleaning") return false;
        if (phase == "preparing") {
            if (Environment.TickCount64 >= s_reloadDeadline) {
                FailReload("rebase_restore_timeout");
                return true;
            }
            // The independent skeleton is now owned entirely by this plugin, so
            // the former Lua restore handshake is replaced by a synchronous
            // rebase restore on this game-thread callback.
            RebaseRestore();
            SetReloadPhase("cleaning", "skeleton_rebase_restored");
        }
        try {
            if (!CleanupReloadNative()) {
                if (Environment.TickCount64 >= s_reloadDeadline) FailReload("native_cleanup_timeout");
                else s_reloadReason = "waiting_native_restore";
                return true;
            }
            SetReloadPhase("ready", "native_resources_clean");
            Interlocked.Exchange(ref s_reloadPermit, 1);
            var id = s_reloadRequestId;
            s_reloadRequestId = null;
            if (id != null) Respond(id, true, new { phase = "ready", reloadToken = s_reloadToken,
                sessionId = s_adapterSessionId, pid = Environment.ProcessId, permit = true });
        } catch (Exception e) {
            if (Environment.TickCount64 >= s_reloadDeadline) FailReload("native_cleanup_failed", e);
            else s_reloadReason = "native_cleanup_waiting:" + e.Message;
        }
        return true;
    }

    static void ApplyReloadRuntimeSettings(ReloadHandoff handoff) {
        // Runtime toggles are restored without writing preferences.json.  The
        // original preference record is written back after the toggles so the
        // handoff preserves both persisted UI settings and live flags.
        bool persistence = handoff.PersistenceEnabled;
        bool automatic = handoff.AutomaticRestoreEnabled;
        if (persistence != s_persistenceEnabled || automatic != s_autoRestoreEnabled) {
            using var persistenceRequest = JsonDocument.Parse(JsonSerializer.Serialize(new {
                enabled = persistence, automaticRestore = automatic }));
            ConfigurePersistence(persistenceRequest.RootElement);
        }
        if (handoff.NativeMenuSyncEnabled != s_nativeMenuSync) {
            using var nativeRequest = JsonDocument.Parse(JsonSerializer.Serialize(new {
                enabled = handoff.NativeMenuSyncEnabled }));
            ConfigureNativeMenuSync(nativeRequest.RootElement);
        }
        Volatile.Write(ref s_preferences, handoff.Preferences.Validate());
    }

    static object BeginReloadResume(JsonElement request, string id) {
        var phase = Volatile.Read(ref s_reloadPhase);
        if (phase != "ready" && phase != "handoff_pending" && phase != "resume_failed")
            throw new InvalidOperationException("Reload is not waiting for explicit resume");
        if (s_reloadResume != null) throw new InvalidOperationException("Reload resume is already in progress");
        if (s_reloadHandoff == null) throw new InvalidOperationException("Reload handoff is unavailable");
        if (TryGetProperty(request, "reloadToken", out var token) && token.ValueKind == JsonValueKind.String &&
            !string.Equals(token.GetString(), s_reloadHandoff.Token, StringComparison.Ordinal))
            throw new InvalidOperationException("Reload handoff token mismatch");
        // Revoke first.  No subsequent state/settings operation can run while
        // the native manager still sees a positive unload permit.
        Interlocked.Exchange(ref s_reloadPermit, 0);
        s_reloadFreeze = true;
        s_reloadRequestId = id;
        s_reloadResume = new ReloadResumeJob { Id = id, Handoff = s_reloadHandoff,
            CleanupNeeded = s_reloadResumeNeedsClear };
        SetReloadPhase("resuming", "restoring_selection_and_settings");
        PublishMenu();
        return new { phase = "resuming", reloadToken = s_reloadHandoff.Token,
            sessionId = s_reloadHandoff.SessionId, pid = Environment.ProcessId };
    }

    static void PollReloadResume() {
        var job = s_reloadResume;
        if (job == null) return;
        try {
            if (job.Stage == 0) {
                if (job.CleanupNeeded) {
                    if (!CleanupReloadNative()) return;
                    job.CleanupNeeded = false;
                }
                ApplyReloadRuntimeSettings(job.Handoff);
                s_applyStartupPreferences = false;
                s_wardrobeRegistry = WardrobeRegistry.ReadDirectory(Path.Combine(s_dir, "mods"));
                var applyId = job.Id + ":resume";
                StartWardrobeState(job.Handoff.State, s_wardrobeRegistry, applyId, true);
                job.Stage = 1;
                return;
            }
            // PollWardrobeApply is the existing game-thread state machine; keep
            // it as the single native model/catalog transition implementation.
            if (s_wardrobeJob != null) return;
            if (s_transitionRequest != null || s_outfitRequest != null || s_loadId != null)
                return;
            if (s_restoreUnresolved) throw new InvalidOperationException("Wardrobe resume finished unresolved");
            var handoffPath = ReloadHandoffPath();
            try { if (File.Exists(handoffPath)) File.Delete(handoffPath); }
            catch (Exception e) { throw new IOException("Cannot consume reload handoff: " + e.Message, e); }
            s_reloadHandoff = null;
            s_reloadToken = null;
            s_reloadResume = null;
            s_reloadResumeNeedsClear = false;
            s_reloadRequestId = null;
            s_reloadFreeze = false;
            s_reloadReason = "resumed";
            SetReloadPhase("idle", "resumed");
            Interlocked.Exchange(ref s_reloadPermit, 0);
            PublishMenu();
            Respond(job.Id, true, new { phase = "resumed", restored = true,
                state = CurrentWardrobeState(), preferences = Volatile.Read(ref s_preferences) });
        } catch (Exception e) {
            s_reloadResume = null;
            s_reloadResumeNeedsClear = true;
            FailReload("resume_failed", e, "resume_failed");
        }
    }

    static void PublishMenu() {
        var entries = new List<AppearanceEntry>();
        var issues = new List<string>();
        var categories = new Dictionary<string, WardrobeCategory>();
        if (s_wardrobeRegistry != null) {
            foreach (var entry in s_wardrobeRegistry.Entries.Values) {
                categories.Add(entry.Rules.Id, entry.Rules.Category);
                // Presentation-only snapshot: native resources never cross into ImGui.
                entries.Add(new AppearanceEntry(entry.Rules.Id, entry.Name,
                    entry.Rules.Category == WardrobeCategory.Weapon ? AppearanceKind.Weapon : AppearanceKind.Outfit,
                    Array.Empty<AppearancePart>(), entry.Source, entry.Description, entry.Author, entry.Icon));
            }
            foreach (var issue in s_wardrobeRegistry.Issues) issues.Add(Path.GetFileName(Path.GetDirectoryName(issue.Source)) + ": " + issue.Message);
        }
        s_activeMods.TryGetValue(AppearanceKind.Outfit, out var outfit);
        s_activeMods.TryGetValue(AppearanceKind.Weapon, out var weapon);
        var state = WardrobeSaveStore.Freeze(s_wardrobeState ?? WardrobeSelections.FromLegacy(new SavedAppearance(outfit, weapon)));
        WardrobeCompositionResult composition = null;
        if (s_wardrobeRegistry != null) {
            var resolution = WardrobeSelections.Resolve(state, s_wardrobeRegistry);
            composition = resolution.Composition;
            foreach (var issue in resolution.Issues) issues.Add(issue);
        }
        Volatile.Write(ref s_saveSnapshot, state);
        Volatile.Write(ref s_menu, new MenuState(entries.ToArray(), outfit, weapon,
            s_loadId != null || s_outfitRequest != null || s_transitionRequest != null || s_restoreJob != null || s_wardrobeJob != null ||
                s_loadCoordinator.HasPending || Volatile.Read(ref s_menuRequest) != null || s_reloadFreeze,
            s_menuMessage, issues.ToArray(), state, composition, categories));
    }

    static void QueueMenu(string action, string modId = null, string kind = null) {
        var phase = Volatile.Read(ref s_reloadPhase);
        if (s_reloadFreeze && action != "reload_status" && action != "resume_reload" &&
            !(action == "prepare_reload" && phase == "failed")) return;
        var request = JsonSerializer.Serialize(new { id = "ui-" + Guid.NewGuid().ToString("N"),
            pid = Environment.ProcessId, action, modId, kind });
        Interlocked.CompareExchange(ref s_menuRequest, request, null);
    }

    static string CategoryLabel(WardrobeCategory category) => category switch {
        WardrobeCategory.Body => "身体", WardrobeCategory.Cloak => "披风", WardrobeCategory.Gauntlet => "护手", _ => "武器" };
    static void QueueWardrobe(string modId, bool? visible = null, string[] declarations = null, string category = null) {
        if (s_reloadFreeze) return;
        var values = new Dictionary<string, object> { ["id"] = "ui-" + Guid.NewGuid().ToString("N"),
            ["pid"] = Environment.ProcessId, ["action"] = visible.HasValue ? "wardrobe_visibility" : "wardrobe_select",
            ["category"] = category ?? s_browseCategory.ToString().ToLowerInvariant(), ["modId"] = modId };
        if (visible.HasValue) values["visible"] = visible.Value;
        if (declarations != null) values["confirmedDeclarations"] = declarations;
        Interlocked.CompareExchange(ref s_menuRequest, JsonSerializer.Serialize(values), null);
    }

    [Callback(typeof(ImGuiRender), CallbackType.Pre)]
    public static void DrawMenu() {
        if (s_stopped) return;
        var hotkey = Enum.Parse<ImGuiKey>(Volatile.Read(ref s_preferences).Hotkey);
        if (!ImGui.GetIO().WantTextInput && ImGui.IsKeyPressed(hotkey, false)) s_windowOpen = !s_windowOpen;
        if (!s_windowOpen) return;
        if (!ImGui.GetIO().WantTextInput && ImGui.IsKeyPressed(ImGuiKey.Escape, false)) {
            if (Volatile.Read(ref s_confirmation) != null) Volatile.Write(ref s_confirmation, null);
            else s_windowOpen = false;
            return;
        }
        ImGui.SetNextFrameWantCaptureKeyboard(true);
        ImGui.SetNextFrameWantCaptureMouse(true);
        ImGui.SetNextWindowSize(new System.Numerics.Vector2(1080, 760), ImGuiCond.FirstUseEver);
        ImGui.SetNextWindowSizeConstraints(new System.Numerics.Vector2(740, 540), new System.Numerics.Vector2(float.MaxValue, float.MaxValue));
        ImGui.PushStyleColor(ImGuiCol.WindowBg, new System.Numerics.Vector4(0.095f, 0.105f, 0.115f, 1));
        ImGui.PushStyleColor(ImGuiCol.ChildBg, new System.Numerics.Vector4(0.11f, 0.12f, 0.13f, 1));
        ImGui.PushStyleColor(ImGuiCol.FrameBg, new System.Numerics.Vector4(0.16f, 0.17f, 0.18f, 1));
        ImGui.PushStyleColor(ImGuiCol.Button, new System.Numerics.Vector4(0.19f, 0.20f, 0.21f, 1));
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, new System.Numerics.Vector4(0.29f, 0.28f, 0.24f, 1));
        ImGui.PushStyleColor(ImGuiCol.Header, new System.Numerics.Vector4(0.34f, 0.29f, 0.19f, 1));
        ImGui.PushStyleColor(ImGuiCol.HeaderHovered, new System.Numerics.Vector4(0.40f, 0.34f, 0.23f, 1));
        ImGui.PushStyleColor(ImGuiCol.Border, new System.Numerics.Vector4(0.27f, 0.28f, 0.29f, 1));
        ImGui.PushStyleColor(ImGuiCol.Text, new System.Numerics.Vector4(0.91f, 0.91f, 0.88f, 1));
        ImGui.PushStyleColor(ImGuiCol.TextDisabled, new System.Numerics.Vector4(0.65f, 0.67f, 0.68f, 1));
        ImGui.PushStyleColor(ImGuiCol.TitleBg, new System.Numerics.Vector4(0.10f, 0.11f, 0.12f, 1));
        ImGui.PushStyleColor(ImGuiCol.TitleBgActive, new System.Numerics.Vector4(0.16f, 0.16f, 0.15f, 1));
        ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding, new System.Numerics.Vector2(18, 14));
        ImGui.PushStyleVar(ImGuiStyleVar.FramePadding, new System.Numerics.Vector2(10, 7));
        ImGui.PushStyleVar(ImGuiStyleVar.ItemSpacing, new System.Numerics.Vector2(12, 10));
        ImGui.PushStyleVar(ImGuiStyleVar.WindowRounding, 4f);
        ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding, 4f);
        try {
            bool visible = ImGui.Begin("鬼武者 · 外观衣橱", ref s_windowOpen);
            try { if (visible) DrawWardrobe(); }
            finally { ImGui.End(); }
        } finally { ImGui.PopStyleVar(5); ImGui.PopStyleColor(12); }
    }

    static bool s_settingsOpen;
    static readonly System.Numerics.Vector4 WardrobeGold = new(0.78f, 0.67f, 0.45f, 1);
    static readonly System.Numerics.Vector4 WardrobeGreen = new(0.46f, 0.82f, 0.65f, 1);

    static string AppliedName(MenuState menu, string id) {
        if (id == null) return "原版";
        foreach (var entry in menu.Entries) if (entry.Id == id) return entry.Name;
        return id;
    }

    static bool WardrobeButton(string label, bool emphasized, System.Numerics.Vector2 size = default) {
        if (emphasized) {
            ImGui.PushStyleColor(ImGuiCol.Button, WardrobeGold);
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, new System.Numerics.Vector4(0.86f, 0.76f, 0.54f, 1));
            ImGui.PushStyleColor(ImGuiCol.Text, new System.Numerics.Vector4(0.09f, 0.10f, 0.11f, 1));
        }
        try { return ImGui.Button(label, size); }
        finally { if (emphasized) ImGui.PopStyleColor(3); }
    }

    static void DrawWardrobe() {
        // Only immutable managed snapshots cross into the render callback.
        s_cardMode = Volatile.Read(ref s_preferences).Cards;
        if (Interlocked.Exchange(ref s_refreshIcons, 0) != 0) ReleaseIcons();
        var menu = Volatile.Read(ref s_menu);
        ImGui.TextColored(WardrobeGold, "外观衣橱");
        ImGui.SameLine();
        ImGui.TextDisabled("服装与武器外观");
        ImGui.SameLine();
        if (ImGui.Button(s_settingsOpen ? "收起设置" : "设置")) s_settingsOpen = !s_settingsOpen;
        ImGui.PushTextWrapPos();
        try {
            var labels = new List<string>();
            foreach (var category in Enum.GetValues<WardrobeCategory>()) {
                string selected = null;
                menu.Composition?.Effective.TryGetValue(category, out selected);
                bool hidden = menu.Composition?.Suppressed.ContainsKey(category) ?? false;
                labels.Add(CategoryLabel(category) + "：" + (hidden ? "已隐藏" : AppliedName(menu, selected)));
            }
            ImGui.TextUnformatted(string.Join("   |   ", labels));
        }
        finally { ImGui.PopTextWrapPos(); }
        ImGui.Separator();
        DrawReloadControls(menu.Busy);
        ImGui.Separator();
        var confirmation = Volatile.Read(ref s_confirmation);
        if (confirmation != null) {
            ImGui.TextColored(WardrobeGold, "强制穿戴确认");
            ImGui.PushTextWrapPos();
            try {
                ImGui.TextUnformatted("以下外观的作者声明隐藏此部位：" + string.Join("、", confirmation.Names));
                ImGui.TextUnformatted("强制穿戴可能出现穿模。是否仍然穿戴？取消将保留当前外观。");
            } finally { ImGui.PopTextWrapPos(); }
            ImGui.BeginDisabled(menu.Busy || Volatile.Read(ref s_menuRequest) != null);
            try {
                if (WardrobeButton("强制穿戴", true, new(140, 38))) {
                    QueueWardrobe(confirmation.ModId, confirmation.Visible, confirmation.Declarations, confirmation.Category);
                    Volatile.Write(ref s_confirmation, null);
                }
                ImGui.SameLine();
                if (ImGui.Button("取消", new System.Numerics.Vector2(110, 38))) Volatile.Write(ref s_confirmation, null);
            } finally { ImGui.EndDisabled(); }
            return;
        }
        if (s_settingsOpen) {
            DrawPreferences(menu.Busy, true);
            ImGui.BeginDisabled(menu.Busy || Volatile.Read(ref s_menuRequest) != null);
            try {
                if (ImGui.Button("刷新已安装外观")) QueueMenu("registry_list");
                ImGui.SameLine();
                if (ImGui.Button("重试存档外观恢复")) QueueMenu("appearance_restore");
            } finally { ImGui.EndDisabled(); }
            ImGui.Separator();
        }
        foreach (var category in Enum.GetValues<WardrobeCategory>()) {
            if (category != WardrobeCategory.Body) ImGui.SameLine();
            if (WardrobeButton(CategoryLabel(category), s_browseCategory == category, new(64, 34))) s_browseCategory = category;
            if (category == WardrobeCategory.Cloak || category == WardrobeCategory.Gauntlet) {
                ImGui.SameLine();
                bool shown = !(menu.State?.Visibility.Disabled.Contains(category) ?? false);
                ImGui.BeginDisabled(menu.Busy || Volatile.Read(ref s_menuRequest) != null);
                try {
                    if (ImGui.Checkbox("显示##" + category, ref shown))
                        QueueWardrobe(null, shown, category: category.ToString().ToLowerInvariant());
                } finally { ImGui.EndDisabled(); }
            }
        }
        ImGui.SameLine();
        ImGui.BeginDisabled(menu.Busy || Volatile.Read(ref s_menuRequest) != null);
        try {
            if (WardrobeButton("卡片", s_cardMode, new(70, 34)) && !s_cardMode)
                QueuePreferences(Volatile.Read(ref s_preferences) with { Cards = true });
            ImGui.SameLine();
            if (WardrobeButton("列表", !s_cardMode, new(70, 34)) && s_cardMode)
                QueuePreferences(Volatile.Read(ref s_preferences) with { Cards = false });
        } finally { ImGui.EndDisabled(); }
        ImGui.SetNextItemWidth(Math.Max(220, ImGui.GetContentRegionAvail().X * 0.55f));
        ImGui.InputText("搜索名称或描述", ref s_search, 256);
        string active = null, requestedId = null, blocker = null;
        menu.Composition?.Effective.TryGetValue(s_browseCategory, out active);
        menu.Composition?.Requested.TryGetValue(s_browseCategory, out requestedId);
        menu.Composition?.Suppressed.TryGetValue(s_browseCategory, out blocker);
        if (blocker != null) {
            ImGui.TextColored(WardrobeGold, blocker == "@user" ? "显示开关已关闭，外观选择仍保留。" : "作者声明隐藏此部位：" + AppliedName(menu, blocker));
            if (blocker != "@user" && (s_browseCategory == WardrobeCategory.Cloak || s_browseCategory == WardrobeCategory.Gauntlet)) {
                ImGui.SameLine();
                ImGui.BeginDisabled(menu.Busy || Volatile.Read(ref s_menuRequest) != null);
                try { if (ImGui.Button("仍要穿戴")) QueueWardrobe(null, true); }
                finally { ImGui.EndDisabled(); }
            }
        }
        var entries = new List<AppearanceEntry>();
        AppearanceEntry focused = null;
        foreach (var entry in menu.Entries) {
            if (menu.Categories == null || !menu.Categories.TryGetValue(entry.Id, out var category) || category != s_browseCategory) continue;
            if (s_search.Length != 0 && entry.Name.IndexOf(s_search, StringComparison.OrdinalIgnoreCase) < 0 &&
                entry.Description.IndexOf(s_search, StringComparison.OrdinalIgnoreCase) < 0) continue;
            entries.Add(entry);
            if (entry.Id == s_focusedEntry) focused = entry;
        }
        if (focused == null && entries.Count > 0) { focused = entries[0]; s_focusedEntry = focused.Id; }
        bool wide = ImGui.GetContentRegionAvail().X >= 850;
        if (ImGui.BeginTable("wardrobe-columns-v2", wide ? 2 : 1, ImGuiTableFlags.Resizable)) {
            try {
                ImGui.TableSetupColumn("浏览", ImGuiTableColumnFlags.WidthStretch, 0.58f);
                if (wide) ImGui.TableSetupColumn("预览", ImGuiTableColumnFlags.WidthStretch, 0.42f);
                ImGui.TableNextColumn();
                bool visible = ImGui.BeginChild("entries-v2", new System.Numerics.Vector2(0, wide ? 460 : 300));
                try { if (visible) {
                    if (entries.Count == 0) ImGui.TextUnformatted("没有匹配的外观。可清空搜索或在设置中刷新。");
                    int columns = s_cardMode ? Math.Max(1, (int)(ImGui.GetContentRegionAvail().X / 205)) : 1;
                    if (ImGui.BeginTable("appearance-items-v2", columns)) {
                        try { foreach (var entry in entries) {
                            ImGui.TableNextColumn();
                            ImGui.PushID(entry.Id);
                            try {
                                ImGui.BeginGroup();
                                try {
                                    float size = s_cardMode ? Math.Min(220, Math.Max(100, ImGui.GetContentRegionAvail().X - 12)) : 52;
                                    DrawIcon(entry, size);
                                    if (!s_cardMode) ImGui.SameLine();
                                    // Card names share the image width; Selectable's half-spacing padding otherwise bleeds into the gutter.
                                    if (s_cardMode) ImGui.PushStyleVar(ImGuiStyleVar.ItemSpacing, new System.Numerics.Vector2(0, 10));
                                    try {
                                        if (ImGui.Selectable(entry.Name.Replace("##", "# #"), s_focusedEntry == entry.Id,
                                            ImGuiSelectableFlags.AllowDoubleClick, new System.Numerics.Vector2(s_cardMode ? size : 0, 32))) {
                                            s_focusedEntry = entry.Id; focused = entry;
                                        }
                                    } finally { if (s_cardMode) ImGui.PopStyleVar(); }
                                    if (entry.Id == active) ImGui.TextColored(WardrobeGreen, "已应用");
                                    else if (entry.Id == requestedId && blocker != null) ImGui.TextColored(WardrobeGold, "已选择 · 已隐藏");
                                    else if (entry.Id == s_focusedEntry) ImGui.TextColored(WardrobeGold, "预览中");
                                    else ImGui.TextDisabled("单击预览");
                                } finally { ImGui.EndGroup(); }
                                if (s_cardMode && entry.Id == s_focusedEntry)
                                    ImGui.GetWindowDrawList().AddRect(ImGui.GetItemRectMin(), ImGui.GetItemRectMax(),
                                        ImGui.GetColorU32(WardrobeGold), 4);
                                if (ImGui.IsItemHovered() && ImGui.IsMouseClicked(ImGuiMouseButton.Left)) {
                                    s_focusedEntry = entry.Id; focused = entry;
                                    if (ImGui.IsMouseDoubleClicked(ImGuiMouseButton.Left) && !menu.Busy &&
                                        active != entry.Id && Volatile.Read(ref s_menuRequest) == null)
                                        QueueWardrobe(entry.Id);
                                }
                                ImGui.Spacing();
                            } finally { ImGui.PopID(); }
                        } } finally { ImGui.EndTable(); }
                    }
                } } finally { ImGui.EndChild(); }
                ImGui.TableNextColumn();
                if (focused != null) {
                    ImGui.TextDisabled("图片预览");
                    DrawIcon(focused, Math.Min(280, Math.Max(120, ImGui.GetContentRegionAvail().X - 12)));
                    ImGui.PushTextWrapPos();
                    try {
                        ImGui.TextColored(WardrobeGold, focused.Name);
                        if (focused.Author.Length > 0) ImGui.TextUnformatted("作者：" + focused.Author);
                        ImGui.Separator();
                        ImGui.TextUnformatted(focused.Description.Length > 0 ? focused.Description : "作者暂未提供描述。");
                    } finally { ImGui.PopTextWrapPos(); }
                    ImGui.Spacing();
                    bool applied = active == focused.Id;
                    ImGui.BeginDisabled(applied || menu.Busy || Volatile.Read(ref s_menuRequest) != null);
                    try {
                        if (WardrobeButton(applied ? "已应用此外观" : menu.Busy ? "正在切换…" : "应用此外观", true,
                            new System.Numerics.Vector2(-1, 40))) QueueWardrobe(focused.Id);
                    } finally { ImGui.EndDisabled(); }
                    ImGui.TextDisabled("也可双击左侧条目应用");
                }
                ImGui.BeginDisabled(requestedId == null || menu.Busy || Volatile.Read(ref s_menuRequest) != null);
                try {
                    if (ImGui.Button("恢复原版" + CategoryLabel(s_browseCategory), new System.Numerics.Vector2(-1, 36)))
                        QueueWardrobe(null);
                } finally { ImGui.EndDisabled(); }
            } finally { ImGui.EndTable(); }
        }
        ImGui.Separator();
        ImGui.PushTextWrapPos();
        try {
            ImGui.TextUnformatted(menu.Message);
            ImGui.TextDisabled("单击预览 · 双击应用 · " + Volatile.Read(ref s_preferences).Hotkey + " 键开关 · Esc 关闭");
            foreach (var issue in menu.Issues) ImGui.TextUnformatted(issue);
        } finally { ImGui.PopTextWrapPos(); }
    }

    static void DrawReloadControls(bool busy) {
        var phase = Volatile.Read(ref s_reloadPhase);
        ImGui.TextColored(WardrobeGold, "安全热重载");
        ImGui.SameLine();
        ImGui.TextDisabled("阶段：" + phase);
        if (s_reloadReason != null) {
            ImGui.SameLine();
            ImGui.TextDisabled(s_reloadReason);
        }
        bool prepare = phase == "idle" || phase == "failed";
        ImGui.BeginDisabled(!prepare || (busy && phase != "failed") || Volatile.Read(ref s_menuRequest) != null);
        try { if (ImGui.Button(phase == "failed" ? "重试准备热重载" : "准备安全热重载")) QueueMenu("prepare_reload"); }
        finally { ImGui.EndDisabled(); }
        if (phase == "ready" || phase == "handoff_pending" || phase == "resume_failed") {
            ImGui.SameLine();
            ImGui.BeginDisabled(Volatile.Read(ref s_menuRequest) != null);
            try { if (ImGui.Button("恢复热重载状态")) QueueMenu("resume_reload"); }
            finally { ImGui.EndDisabled(); }
        }
        if (phase == "preparing" || phase == "cleaning" || phase == "ready" || phase == "handoff_pending" || phase == "resume_failed") {
            ImGui.SameLine();
            ImGui.TextDisabled("可在 request.json 中查询 reload_status");
        }
    }

    static void DrawIcon(AppearanceEntry entry, float size) {
        bool drawn = false;
        lock (s_iconLock) {
            try {
                if (!s_iconApiUnavailable && entry.Icon != null) {
                    if (!s_icons.TryGetValue(entry.Id, out var handle)) {
                        string directory = Path.GetFullPath(Path.GetDirectoryName(entry.Source));
                        string path = Path.GetFullPath(Path.Combine(directory, entry.Icon));
                        handle = path.StartsWith(directory + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)
                            ? owots_ui_icon_load(path) : 0;
                        s_icons[entry.Id] = handle;
                    }
                    if (handle != 0) drawn = owots_ui_icon_draw(handle, size, size);
                }
            } catch (Exception e) when (e is DllNotFoundException || e is EntryPointNotFoundException || e is BadImageFormatException) {
                s_iconApiUnavailable = true;
            } catch { /* Optional icon failures never disable appearance selection. */ }
        }
        if (!drawn) {
            var origin = ImGui.GetCursorScreenPos();
            ImGui.Dummy(new System.Numerics.Vector2(size, size));
            var draw = ImGui.GetWindowDrawList();
            draw.AddRectFilled(origin, origin + new System.Numerics.Vector2(size, size), 0xff292725, 4);
            string placeholder = size < 80 ? "无图" : "暂无预览图";
            var textSize = ImGui.CalcTextSize(placeholder);
            draw.AddText(origin + new System.Numerics.Vector2((size - textSize.X) / 2, (size - textSize.Y) / 2),
                0xffbfc5cd, placeholder);
        }
    }

    static void ReleaseIcons() {
        lock (s_iconLock) {
            if (!s_iconApiUnavailable) foreach (var handle in s_icons.Values) if (handle != 0)
                try { owots_ui_icon_release(handle); } catch { }
            s_icons.Clear();
        }
    }

    static void QueuePreferences(WardrobePreferences preferences) {
        if (s_reloadFreeze) return;
        var request = JsonSerializer.Serialize(new { id = "ui-" + Guid.NewGuid().ToString("N"), pid = Environment.ProcessId,
            action = "wardrobe_preferences", preferences });
        Interlocked.CompareExchange(ref s_menuRequest, request, null);
    }

    // --- Independent skeleton: per-joint root rest rebase ---------------------
    // Adopted mechanism (live-confirmed): keep the root /90 skeleton stock and,
    // on the motion phase, set each changed root joint to rootRest + (bodyRest -
    // rootRest).  The body part's own skeleton world-syncs to the root, so this
    // yields the authored body shape without any resource/holder swap.  Keeping
    // this in the wardrobe system (not a separate Lua) is the intended design.
    sealed class JointRebaseEntry { public via.Joint Joint; public via.vec3 Rest; public via.vec3 Delta; }
    static List<JointRebaseEntry> s_rebaseEntries;
    static string s_rebaseModId;

    static via.vec3 Vec3(float x, float y, float z) {
        var value = REFrameworkNET.ValueType.New<via.vec3>();
        value.x = x; value.y = y; value.z = z;
        return value;
    }

    static WardrobeSkeleton EffectiveBodySkeleton() {
        var state = s_wardrobeState;
        var registry = s_wardrobeRegistry;
        if (state == null || registry == null) return null;
        var resolved = WardrobeSelections.Resolve(state, registry);
        if (resolved.Composition.Issues.Count != 0 ||
            !resolved.Composition.Effective.TryGetValue(WardrobeCategory.Body, out var modId) ||
            !registry.Entries.TryGetValue(modId, out var entry)) return null;
        return entry.Skeleton;
    }

    static void RebaseRestore() {
        if (s_rebaseEntries == null) return;
        try { foreach (var entry in s_rebaseEntries) entry.Joint.LocalPosition = entry.Rest; } catch { }
        s_rebaseEntries = null;
        s_rebaseModId = null;
    }

    static void RebaseTryStart() {
        var manager = Manager();
        var info = Alive(manager) ? manager.getControllingPlayerInfo() : null;
        var entity = Alive(info) ? info.CharacterEntity : null;
        var supporter = Alive(entity) ? entity.GameObjectSupporter : null;
        if (!UsableSupporter(supporter)) return;
        var skeleton = EffectiveBodySkeleton();
        if (skeleton == null) return;
        var actor = Alive(info) ? info.Object : null;
        if (!Alive(actor)) return;
        var bodyType = app.cPlayerGameObjectSupporter.convertObjTypeToPartsType(app.PlayerPartsDef.PARTS_TYPE.BODY);
        var body = supporter.getGameObject(bodyType);
        if (!Alive(body)) return;
        var actorTransform = actor.Transform;
        var bodyTransform = body.Transform;
        if (actorTransform == null || bodyTransform == null) return;
        var entries = new List<JointRebaseEntry>();
        foreach (var name in skeleton.JointNames) {
            var rootJoint = actorTransform.getJointByName(name);
            if (rootJoint == null) continue;
            var rootRest = rootJoint.BaseLocalPosition;
            // Manifest bind positions win when the converter declared them; a
            // manifest without them falls back to the equipped mesh's own rest.
            float bx, by, bz;
            if (skeleton.BindPositions.TryGetValue(name, out var declared) && declared.Count >= 3) {
                bx = declared[0]; by = declared[1]; bz = declared[2];
            } else {
                var bodyJoint = bodyTransform.getJointByName(name);
                if (bodyJoint == null) continue;
                var bodyRest = bodyJoint.BaseLocalPosition;
                bx = bodyRest.x; by = bodyRest.y; bz = bodyRest.z;
            }
            float dx = bx - rootRest.x, dy = by - rootRest.y, dz = bz - rootRest.z;
            if (Math.Abs(dx) + Math.Abs(dy) + Math.Abs(dz) <= 0.0002f) continue;
            entries.Add(new JointRebaseEntry { Joint = rootJoint, Rest = rootRest, Delta = Vec3(dx, dy, dz) });
        }
        s_rebaseEntries = entries;
        s_rebaseModId = null;
    }

    // Late phase (same point the plugin already uses for final visibility
    // reassertion): the engine's pose composition has run, so the root joint
    // rest override is reflected in the frame.  Writing this on UpdateMotion
    // was overwritten during normal gameplay and only survived while paused.
    [Callback(typeof(LateUpdateBehavior), CallbackType.Post)]
    static void MotionRebase() {
        if (s_stopped || s_reloadFreeze) return;
        try {
            if (!Volatile.Read(ref s_preferences).IndependentSkeleton) { RebaseRestore(); return; }
            if (s_rebaseEntries == null) { RebaseTryStart(); return; }
            foreach (var entry in s_rebaseEntries)
                entry.Joint.LocalPosition =
                    Vec3(entry.Rest.x + entry.Delta.x, entry.Rest.y + entry.Delta.y, entry.Rest.z + entry.Delta.z);
        } catch { RebaseRestore(); }
    }

    static void DrawPreferences(bool busy, bool expanded = false) {
        if (!expanded && !ImGui.CollapsingHeader("设置")) return;
        ImGui.BeginDisabled(busy || Volatile.Read(ref s_menuRequest) != null);
        try {
            var current = Volatile.Read(ref s_preferences);
            if (ImGui.BeginCombo("开关快捷键", current.Hotkey == "Slash" ? "/ ?" : current.Hotkey)) {
                try { foreach (var key in WardrobePreferences.SupportedHotkeys)
                    if (ImGui.Selectable(key == "Slash" ? "/ ?" : key, key == current.Hotkey)) QueuePreferences(current with { Hotkey = key });
                } finally { ImGui.EndCombo(); }
            }
            bool persistence = current.Persistence, automatic = current.AutomaticRestore, native = current.NativeMenuSync;
            if (ImGui.Checkbox("跟随存档记录外观", ref persistence))
                QueuePreferences(current with { Persistence = persistence, AutomaticRestore = persistence && automatic });
            ImGui.BeginDisabled(!persistence);
            try { if (ImGui.Checkbox("读档后自动恢复外观（实验）", ref automatic)) QueuePreferences(current with { AutomaticRestore = automatic }); }
            finally { ImGui.EndDisabled(); }
            if (ImGui.Checkbox("跟随原生菜单的明确选择（实验）", ref native)) QueuePreferences(current with { NativeMenuSync = native });
            bool skeleton = current.IndependentSkeleton;
            if (ImGui.Checkbox("独立骨架：按服装自动切换体型", ref skeleton)) QueuePreferences(current with { IndependentSkeleton = skeleton });
        } finally { ImGui.EndDisabled(); }
    }

    static object ApplyPreferences(WardrobePreferences preferences, bool persist) {
        preferences.Validate();
        if (preferences.Persistence != s_persistenceEnabled || preferences.AutomaticRestore != s_autoRestoreEnabled) {
            using var persistence = JsonDocument.Parse(JsonSerializer.Serialize(new { enabled = preferences.Persistence, automaticRestore = preferences.AutomaticRestore }));
            ConfigurePersistence(persistence.RootElement);
        }
        if (preferences.NativeMenuSync != s_nativeMenuSync) {
            using var native = JsonDocument.Parse(JsonSerializer.Serialize(new { enabled = preferences.NativeMenuSync }));
            ConfigureNativeMenuSync(native.RootElement);
        }
        Volatile.Write(ref s_preferences, preferences);
        if (persist) preferences.Write(Path.Combine(s_dir, "preferences.json"));
        return new { preferences, saved = persist };
    }

    // Native PluginManager treats this optional public method as a global
    // unload gate.  It is intentionally the only cross-thread permission bit;
    // all native cleanup that sets it happens on UpdateBehavior.Post.
    public static bool CanUnload() => Volatile.Read(ref s_reloadPermit) == 1;

    [PluginExitPoint]
    public static void Unload() {
        if (!CanUnload()) {
            throw new InvalidOperationException("Refusing unload before safe reload preparation");
        }
        Interlocked.Exchange(ref s_reloadPermit, 0);
        s_stopped = true;
        if (s_adapterBridgeRegistered) {
            // Native unregister waits for an in-flight callback before the
            // collectible managed plugin may release its rooted delegate.
            owots_adapter_unregister_snapshot(s_adapterSnapshotCallback);
            s_adapterBridgeRegistered = false;
        }
        s_hiddenParts.Clear();
        ReleaseHiddenObjects(new HashSet<ulong>());
        RestoreVisibilityProbe();
        ReleaseIcons();
        s_tracing = false;
        s_saveTracing = false;
        s_visualBodyId = -1;
        s_selectedParts = new Dictionary<int, int>();
        if (s_transitionRequest != null) {
            Respond(s_transitionRequest, false, new { error = "Appearance transition interrupted by plugin unload" });
            s_transitionRequest = null;
            s_transitionEntry = null;
        }
        if (s_outfitRequest != null) {
            var outfitRequest = s_outfitRequest;
            s_outfitRequest = null;
            ReleasePreload();
            Respond(outfitRequest, false, new { error = "Outfit preload interrupted by plugin unload" });
        }
        var pending = s_loadId;
        try { ClearLoad(); }
        finally {
            if (pending != null) Respond(pending, false, new { error = "Prefab probe interrupted by plugin unload" });
        }
    }

    static void ClearLoad() {
        if (Alive(s_loadPrefab)) s_loadPrefab.Standby = false;
        s_loadPrefab = null;
        s_loadOwner?.Release();
        s_loadOwner = null;
        s_loadId = null;
        s_loadSelectBody = false;
    }

    static bool Alive(object value) {
        var address = (value as IProxyable)?.GetAddress() ?? 0;
        return address != 0 && ManagedObject.IsManagedObject(address);
    }

    [Callback(typeof(UpdateBehavior), CallbackType.Post)]
    public static void Update() {
        Volatile.Write(ref s_adapterGameThreadId, Environment.CurrentManagedThreadId);
        AuditVisibility("UpdateBehavior.Post.BeforeHide");
        if (!s_stopped && !s_reloadFreeze && (s_hiddenParts.Count > 0 || s_hiddenObjects.Count > 0)) PollVisibility();
        if (!s_stopped && !s_reloadFreeze && s_visibilityProbeRequest != null) PollVisibilityProbe();
        if (s_stopped || s_dir == null || Environment.TickCount64 < s_nextPoll) return;
        s_nextPoll = Environment.TickCount64 + 250;
        RegisterAdapterBridge();
        if (s_reloadResume != null) PollReloadResume();
        if (s_wardrobeJob != null) {
            var pause = API.GetManagedSingletonT<app.PauseManager>();
            bool paused = Alive(pause) && pause.IsMenuPause;
            long excluded = s_wardrobeJob.Clock.Advance(Environment.TickCount64, paused);
            if (s_transitionRequest == s_wardrobeJob.StepId) s_transitionDeadline += excluded;
            if (s_outfitRequest == s_wardrobeJob.StepId) s_outfitDeadline += excluded;
            if (paused) return;
            PollWardrobeApply();
        }
        if (s_reloadResume != null && s_reloadResume.Stage > 0 && s_wardrobeJob == null)
            PollReloadResume();
        if (s_reloadResume == null && s_reloadFreeze) PollReloadPreparation();
        if (s_applyStartupPreferences && !s_reloadFreeze) {
            s_applyStartupPreferences = false;
            try { ApplyPreferences(s_preferences, false); }
            catch (Exception e) { s_menuMessage = "设置应用失败：" + e.Message; PublishMenu(); }
        }
        if (!s_reloadFreeze) FlushAppearanceSaves();
        if (!s_reloadFreeze && s_restoreJob != null) {
            var pause = API.GetManagedSingletonT<app.PauseManager>();
            bool paused = Alive(pause) && pause.IsMenuPause;
            long excluded = s_restoreJob.Clock.Advance(Environment.TickCount64, paused);
            if (s_transitionRequest == s_restoreJob.OperationId && s_transitionRequest != null) s_transitionDeadline += excluded;
            if (s_outfitRequest == s_restoreJob.OperationId && s_outfitRequest != null) s_outfitDeadline += excluded;
            if (paused) {
                s_menuMessage = "等待继续游戏后恢复存档外观";
                PublishMenu();
                return;
            }
        }
        PublishMenu();
        if (!s_reloadFreeze || s_reloadResume != null) {
        if (s_transitionRequest != null) { PollTransition(); return; }
        if (s_outfitRequest != null) { PollOutfit(); return; }
        if (s_loadId != null) {
            string loadId = s_loadId;
            try {
                if (!Alive(s_loadPrefab) && Alive(s_loadOwner)) {
                    var list = s_loadOwner.As<app.user_data.PlayerPartsList>();
                    for (int i = 0; i < Math.Min(list.DataNum, 128); i++) {
                        var candidate = list._DataList[i].PartsPrefab;
                        if (Alive(candidate) && candidate.Path.StartsWith("mods/owots_appearance_lab/", StringComparison.Ordinal)) {
                            s_loadPrefab = candidate;
                            s_loadPrefab.Standby = true;
                            break;
                        }
                    }
                }
                bool ready = Alive(s_loadPrefab) && s_loadPrefab.Ready;
                if (!ready && Environment.TickCount64 < s_loadDeadline) return;
                bool selected = false;
                if (ready && s_loadSelectBody) {
                    SelectBodyPrefab(s_loadPrefab);
                    s_visualOwner = s_loadOwner;
                    s_visualPrefab = s_loadPrefab;
                    s_loadOwner = null;
                    s_loadPrefab = null;
                    selected = true;
                }
                var result = new { phase = "finished", ready,
                    selected, valid = selected ? s_visualPrefab.Valid : Alive(s_loadPrefab) && s_loadPrefab.Valid,
                    path = selected ? s_visualPrefab.Path : Alive(s_loadPrefab) ? s_loadPrefab.Path : null };
                ClearLoad();
                Respond(loadId, ready, result);
            } catch (Exception e) { ClearLoad(); Respond(loadId, false, new { error = e.Message }); }
            return;
        }
        }
        if (!s_reloadFreeze) {
        if (PollRestore()) return;
        if (PollNativeMenuSync()) return;
        }
        var path = Path.Combine(s_dir, "request.json");
        var menuRequest = Interlocked.Exchange(ref s_menuRequest, null);
        if (menuRequest == null && !File.Exists(path)) return;
        string id = null;
        try {
            using var doc = JsonDocument.Parse(menuRequest ?? File.ReadAllText(path));
            var request = doc.RootElement;
            id = request.GetProperty("id").GetString();
            if (string.IsNullOrWhiteSpace(id) || (menuRequest == null && id == s_lastId)) return;
            if (request.GetProperty("pid").GetInt32() != Environment.ProcessId) return;
            if (menuRequest == null) s_lastId = id;
            var action = request.GetProperty("action").GetString();
            var reloadPhase = Volatile.Read(ref s_reloadPhase);
            if (s_reloadFreeze && action != "reload_status" && action != "resume_reload" &&
                !(action == "prepare_reload" && reloadPhase == "failed"))
                throw new InvalidOperationException("Reload is frozen; only reload_status or resume_reload is allowed");
            object result = action switch {
                "prepare_reload" => BeginReloadPreparation(id),
                "reload_status" => ReloadStatus(),
                "resume_reload" => BeginReloadResume(request, id),
                "inspect" => Inspect(),
                "inspect_part_visibility" => InspectPartVisibility(),
                "probe_part_visibility" => BeginVisibilityProbe(request, id),
                "appearance_visibility" => SetVisibility(request),
                "visibility_status" => new { parts = s_hiddenParts, tracked = s_hiddenObjects.Count,
                    frames = s_visibilityFrames, status = s_visibilityStatus },
                "visibility_audit" => VisibilityAudit(request),
                "wardrobe_registry" => WardrobeRegistry.ReadDirectory(Path.Combine(s_dir, "mods")),
                "wardrobe_status" => WardrobeStatus(),
                "wardrobe_select" => BeginWardrobeApply(request, id),
                "wardrobe_visibility" => BeginWardrobeApply(request, id),
                "inspect_body_materials" => InspectBodyMaterials(),
                "probe_registration" => ProbeRegistration(request),
                "inspect_userdata" => InspectUserData(request),
                "probe_prefab_load" => BeginPrefabLoad(request, id),
                "probe_independent_body_select" => BeginPrefabLoad(request, id, true),
                "inspect_model_methods" => InspectModelMethods(),
                "inspect_costume_methods" => InspectCostumeMethods(),
                "native_menu_sync" => ConfigureNativeMenuSync(request),
                "wardrobe_preferences" => ApplyPreferences(request.GetProperty("preferences").Deserialize<WardrobePreferences>(), true),
                "probe_native_body_refresh" => ProbeNativeBodyRefresh(true),
                "probe_native_request_allocation" => ProbeNativeBodyRefresh(false),
                "probe_body_alias_select" => SelectBodyAlias(),
                "probe_body_alias_clear" => ClearBodyAlias(),
                "probe_full_outfit_select" => BeginOutfit(id),
                "registry_list" => ReadRegistry(),
                "registry_select" => BeginRegistered(request, id),
                "registry_clear" => BeginTransition(id, null, 0, ReadKind(request)),
                "trace_model_changes" => TraceModelChanges(request),
                "trace_save_loads" => TraceSaveLoads(request),
                "appearance_persistence" => ConfigurePersistence(request),
                "appearance_restore_preview" => PreviewSavedAppearance(),
                "appearance_restore" => QueueSavedRestore(),
                "apply_manba_meshes" => throw new InvalidOperationException("Direct binding disabled: afterimage material cache must be refreshed through the native model-change lifecycle first"),
                "apply_manba_lifecycle" => throw new InvalidOperationException("Disabled: direct mesh binding produces invisible geometry and does not complete montage; use native prefab replacement research"),
                "restore_meshes" => RestoreMeshes(),
                _ => throw new InvalidOperationException("Unknown action")
            };
            Respond(id, true, result);
        } catch (Exception e) {
            if (id != null) { if (menuRequest == null) s_lastId = id; Respond(id, false, new { error = e.Message }); }
        }
    }

    static void Respond(string id, bool ok, object result) {
        if (s_wardrobeJob != null && id == s_wardrobeJob.StepId) {
            var details = JsonSerializer.SerializeToElement(result);
            bool loading = details.TryGetProperty("phase", out var phase) && phase.GetString().StartsWith("loading", StringComparison.Ordinal);
            if (!ok || !loading) {
                s_wardrobeJob.Waiting = false;
                if (!ok) s_wardrobeJob.Error = details.TryGetProperty("error", out var error) ? error.GetString() : "Native wardrobe step failed";
                else s_wardrobeJob.Stage++;
            }
            return;
        }
        if (id == s_nativeMenuRequest) {
            var details = JsonSerializer.SerializeToElement(result);
            bool loading = details.TryGetProperty("phase", out var phase) && phase.GetString().StartsWith("loading", StringComparison.Ordinal);
            if (!loading || !ok) {
                s_nativeMenuRequest = null;
                s_menuMessage = ok ? "已跟随原生菜单的服装选择" : "原生选择同步未完成，请恢复游戏运行后重试取消外观";
                AppendSaveTrace(new { phase = "native_menu_sync_finished", ok, result });
            }
            PublishMenu();
            return;
        }
        if (s_restoreJob != null && id == s_restoreJob.OperationId) {
            var details = JsonSerializer.SerializeToElement(result);
            bool loading = details.TryGetProperty("phase", out var state) && state.GetString().StartsWith("loading", StringComparison.Ordinal);
            if (!ok || !loading) {
                s_restoreJob.Waiting = false;
                if (!ok) {
                    s_restoreJob.Issues.Add(details.TryGetProperty("error", out var error) ? error.GetString() : "恢复失败");
                    if (s_restoreJob.Stage == 0) s_restoreJob.Stage = 3;
                    else s_restoreJob.Stage++;
                } else s_restoreJob.Stage++;
            }
            PublishMenu();
            return;
        }
        if (id.StartsWith("ui-", StringComparison.Ordinal)) {
            var details = JsonSerializer.SerializeToElement(result);
            s_menuMessage = !ok ? "操作失败：" + (details.TryGetProperty("error", out var error) ? error.GetString() : "未知错误") :
                details.TryGetProperty("phase", out var phase) && phase.GetString().StartsWith("loading", StringComparison.Ordinal)
                    ? "正在切换，请稍候…" : "操作完成";
        }
        PublishMenu();
        var json = JsonSerializer.Serialize(new { id, pid = Environment.ProcessId, ok,
            capturedAt = DateTimeOffset.UtcNow, result }, new JsonSerializerOptions { WriteIndented = true });
        var temp = Path.Combine(s_dir, "response.tmp");
        File.WriteAllText(temp, json);
        File.Move(temp, Path.Combine(s_dir, "response.json"), true);
    }

    static app.PlayerManager Manager() {
        var manager = API.GetManagedSingletonT<app.PlayerManager>();
        if (!Alive(manager) || !Alive(manager.Catalog)) throw new InvalidOperationException("Player catalog unavailable");
        return manager;
    }

    static object Equipped(app.PlayerManager manager) {
        var info = manager.getControllingPlayerInfo();
        var context = Alive(info) ? info.Context : null;
        var player = Alive(context) ? context.Player : null;
        if (!Alive(player)) return null;
        return new { body = player.CurrentEquipBodyID, weapon = player.CurrentEquipWeaponsID,
            head = player.CurrentEquipHeadID, hair = player.CurrentEquipHairID,
            gauntlet = player.CurrentEquipGauntletID, cloak = player.CurrentEquipCloakID };
    }

    static object Catalog(app.PlayerManager manager, app.PlayerPartsDef.PARTS_TYPE part) {
        var entries = manager.Catalog.getPlayerPartsList(part);
        if (!Alive(entries)) return new { part = (int)part, available = false };
        var values = new List<object>();
        var keys = entries.Keys;
        var iterator = keys.GetEnumerator();
        while (iterator.MoveNext() && values.Count < 128) {
            var id = iterator.Current;
            var prefab = entries[id];
            values.Add(new { id, path = Alive(prefab) ? prefab.Path : null,
                resourcePath = Alive(prefab) ? prefab.ResourcePath : null,
                valid = Alive(prefab) && prefab.Valid, standby = Alive(prefab) && prefab.Standby });
        }
        return new { part = (int)part, count = entries.Count, entries = values };
    }

    static object Inspect() {
        var manager = Manager();
        var catalog = new List<object>();
        for (int part = 0; part < 13; part++) catalog.Add(Catalog(manager, (app.PlayerPartsDef.PARTS_TYPE)part));
        var info = manager.getControllingPlayerInfo();
        var context = Alive(info) ? info.Context : null;
        var objects = new List<object>();
        if (Alive(info)) objects.Add(new { role = "info.Object", value = DescribeObject(info.Object) });
        if (Alive(context)) {
            objects.Add(new { role = "context.Body", value = DescribeObject(context.Body) });
            var parts = context.Parts;
            if (Alive(parts)) for (int i = 0; i < Math.Min(parts.Length, 32); i++)
                objects.Add(new { role = "context.Parts[" + i + "]", value = DescribeObject(parts[i]) });
        }
        var descendants = new List<object>();
        if (Alive(info) && Alive(info.Object)) {
            foreach (var obj in Descendants(info.Object)) descendants.Add(DescribeObject(obj));
        }
        var afterImage = Alive(info) && Alive(info.Object) ? AfterImage(info.Object) : null;
        object lifecycle = Alive(afterImage) ? new { state = afterImage._State.ToString(), reloadCount = afterImage._ReloadRequestCount,
            reloadRequested = afterImage._ReloadRequested, recordTargets = afterImage._RecordTargetList.Count } : null;
        var entity = Alive(info) ? info.CharacterEntity : null;
        var supporter = Alive(entity) ? entity.GameObjectSupporter : null;
        object modelChange = Alive(supporter) ? new {
            state = supporter._ChangeStateMain.ToString(),
            complete = supporter._IsModelChangeComplete,
            changing = supporter.isChangeModelProcessing(),
            adding = supporter.isAddModelProcessing(),
            bodyModelId = supporter._ModelIDs[0], headModelId = supporter._ModelIDs[2],
            hairModelId = supporter._ModelIDs[3], selectedBodyId = s_visualBodyId,
            selectedParts = s_selectedParts
            , supporter = $"0x{((IProxyable)supporter).GetAddress():X}", registeredSupporter = $"0x{s_visualSupporter:X}",
            destroyed = supporter._IsDestroy, restoreStage = s_restoreJob?.Stage,
            restoreUnresolved = s_restoreUnresolved
        } : null;
        return new { equipped = Equipped(manager), catalogs = catalog, objects, descendants, lifecycle, modelChange };
    }

    static object WardrobeStatus() {
        s_activeMods.TryGetValue(AppearanceKind.Outfit, out var outfit);
        s_activeMods.TryGetValue(AppearanceKind.Weapon, out var weapon);
        var state = WardrobeSaveStore.Freeze(s_wardrobeState ??
            WardrobeSelections.FromLegacy(new SavedAppearance(outfit, weapon)));
        // Snapshot only: do not refresh registry/icons, commit saves or start native work.
        var resolution = s_wardrobeRegistry == null ? null : WardrobeSelections.Resolve(state, s_wardrobeRegistry);
        return new {
            schemaVersion = 1, selections = state,
            resolution, registryAvailable = s_wardrobeRegistry != null,
            hiddenParts = new List<string>(s_hiddenParts),
            persistence = new { enabled = s_persistenceEnabled, automaticRestore = s_autoRestoreEnabled },
            nativeMenuSync = s_nativeMenuSync,
            busy = s_wardrobeJob != null || s_transitionRequest != null || s_outfitRequest != null ||
                s_loadId != null || s_restoreJob != null || s_loadCoordinator.HasPending ||
                Volatile.Read(ref s_menuRequest) != null || s_reloadFreeze,
            restoreUnresolved = s_restoreUnresolved,
            reload = ReloadStatus()
        };
    }

    /// <summary>
    /// Read-only, scalar-only contract for dedicated appearance adapters.
    /// Call on the game callback thread. No save, model, catalog or selection
    /// mutations occur here; revision only identifies this diagnostic lease.
    /// Adapters must still validate actual component/mesh ownership before writes.
    /// </summary>
    public static string GetAdapterSnapshotJson() {
        bool onGameThread = Environment.CurrentManagedThreadId == Volatile.Read(ref s_adapterGameThreadId);
        string Snapshot(bool ready, string reason, string modId = null, string supporter = null,
            string entity = null, object[] parts = null, bool busy = false, object skeleton = null,
            object partFailure = null) {
            parts ??= Array.Empty<object>();
            var identity = JsonSerializer.Serialize(new { ready, reason, modId, supporter, entity, parts, busy, skeleton,
                reloadToken = s_reloadToken, partFailure });
            long revision = Volatile.Read(ref s_adapterRevision);
            if (onGameThread && identity != s_adapterIdentity) {
                s_adapterIdentity = identity;
                revision = Interlocked.Increment(ref s_adapterRevision);
            }
            return JsonSerializer.Serialize(new {
                schemaVersion = 1, sessionId = s_adapterSessionId,
                pid = Environment.ProcessId, monotonicMs = Environment.TickCount64,
                selectionRevision = revision, ready, reason, busy,
                restoreUnresolved = onGameThread && s_restoreUnresolved,
                reloadToken = s_reloadToken,
                effectiveBodyModId = modId, supporterAddress = supporter,
                playerEntityAddress = entity, bodyNativeId = (int?)null,
                independentSkeleton = Volatile.Read(ref s_preferences).IndependentSkeleton,
                catalogRowsVerified = ready, parts, skeleton, partFailure
            });
        }
        if (!onGameThread) return Snapshot(false, "wrong_thread");
        if (s_stopped || s_dir == null) return Snapshot(false, "runtime_unavailable");
        if (s_reloadFreeze) return Snapshot(false, "reload_preparing", busy: true);
        bool busy = s_wardrobeJob != null || s_transitionRequest != null || s_outfitRequest != null ||
            s_loadId != null || s_restoreJob != null || s_loadCoordinator.HasPending ||
            Volatile.Read(ref s_menuRequest) != null;
        if (busy || s_restoreUnresolved) return Snapshot(false, "transition_or_restore", busy: busy);
        try {
            if (s_wardrobeState == null || s_wardrobeRegistry == null)
                return Snapshot(false, "no_wardrobe_state");
            var resolved = WardrobeSelections.Resolve(s_wardrobeState, s_wardrobeRegistry);
            if (resolved.Composition.Issues.Count != 0 ||
                !resolved.Composition.Effective.TryGetValue(WardrobeCategory.Body, out var modId) ||
                !s_wardrobeRegistry.Entries.TryGetValue(modId, out var entry))
                return Snapshot(false, "no_effective_body");
            var pause = API.GetManagedSingletonT<app.PauseManager>();
            if (Alive(pause) && pause.IsMenuPause) return Snapshot(false, "menu_paused", modId);
            var manager = Manager();
            var info = Alive(manager) ? manager.getControllingPlayerInfo() : null;
            var entity = Alive(info) ? info.CharacterEntity : null;
            var supporter = Alive(entity) ? entity.GameObjectSupporter : null;
            if (!UsableSupporter(supporter) || supporter.isChangeModelProcessing() ||
                ((IProxyable)supporter).GetAddress() != s_visualSupporter || !Alive(manager.Catalog))
                return Snapshot(false, "player_or_model_changed", modId);
            var rows = new List<object>();
            foreach (var declared in entry.Parts) {
                int partType = (int)Enum.Parse<app.PlayerPartsDef.PARTS_TYPE>(declared.Part);
                var registered = s_outfitParts.SingleOrDefault(part => part.Part == partType);
                string failure = null;
                if (registered == null) failure = "missing_registered_part";
                else if (!registered.Registered) failure = "normal_catalog_registration_missing";
                else if (!registered.RegisteredHQ) failure = "hq_catalog_registration_missing";
                else if (!Alive(registered.Owner)) failure = "resource_owner_unavailable";
                else if (!Alive(registered.Prefab)) failure = "prefab_unavailable";
                // Ready/Valid gate PollOutfit's standby preload. The engine clears
                // standby after instantiation; live ownership is checked below
                // using selected/native IDs and exact catalog prefab addresses.
                else if (!string.Equals(registered.ExpectedPrefab, declared.Prefab, StringComparison.OrdinalIgnoreCase)) failure = "expected_prefab_mismatch";
                else if (!string.Equals(registered.ExpectedCatalog, declared.Catalog, StringComparison.OrdinalIgnoreCase)) failure = "expected_catalog_mismatch";
                else if (!string.Equals(registered.Prefab.Path, declared.Prefab, StringComparison.OrdinalIgnoreCase)) failure = "loaded_prefab_path_mismatch";
                else if (!s_selectedParts.TryGetValue(partType, out int selected) || selected != registered.Id) failure = "selection_id_mismatch";
                else if (supporter._ModelIDs[partType] != registered.Id) failure = "native_model_id_mismatch";
                if (failure != null)
                    return Snapshot(false, "part_not_applied", modId, partFailure: DescribePartFailure(failure, declared, partType, registered, supporter));
                var normal = manager.Catalog.getPlayerPartsList((app.PlayerPartsDef.PARTS_TYPE)partType);
                var hq = manager.Catalog.getPlayerPartsListHQ((app.PlayerPartsDef.PARTS_TYPE)partType);
                ulong expected = ((IProxyable)registered.Prefab).GetAddress();
                bool normalPresent = normal.ContainsKey(registered.Id), hqPresent = hq.ContainsKey(registered.Id);
                ulong normalAddress = normalPresent ? ((IProxyable)normal[registered.Id]).GetAddress() : 0;
                ulong hqAddress = hqPresent ? ((IProxyable)hq[registered.Id]).GetAddress() : 0;
                if (!normalPresent || !hqPresent || normalAddress != expected || hqAddress != expected)
                    return Snapshot(false, "catalog_ownership_changed", modId,
                        partFailure: DescribePartFailure("catalog_ownership_changed", declared, partType, registered,
                            supporter, normalPresent, hqPresent, expected, normalAddress, hqAddress));
                rows.Add(new { part = declared.Part, prefab = declared.Prefab,
                    catalog = declared.Catalog, syntheticModelId = registered.Id });
            }
            return Snapshot(true, "applied", modId, $"0x{s_visualSupporter:X}",
                $"0x{((IProxyable)entity).GetAddress():X}", rows.ToArray(),
                skeleton: entry.Skeleton?.ToSnapshot());
        } catch {
            return Snapshot(false, "snapshot_unavailable");
        }
    }

    static object DescribePartFailure(string failure, WardrobePart declared, int partType,
        OutfitPart registered, app.cPlayerGameObjectSupporter supporter,
        bool? normalPresent = null, bool? hqPresent = null, ulong expectedAddress = 0,
        ulong normalAddress = 0, ulong hqAddress = 0) {
        int? selected = s_selectedParts.TryGetValue(partType, out var selectedId) ? selectedId : (int?)null;
        int? native = null;
        try { if (supporter != null) native = supporter._ModelIDs[partType]; } catch { }
        return new {
            reason = failure, part = declared.Part, partType, expectedPrefab = declared.Prefab,
            expectedCatalog = declared.Catalog, syntheticModelId = registered?.Id,
            selectedModelId = selected, nativeModelId = native,
            registered = registered?.Registered ?? false, registeredHQ = registered?.RegisteredHQ ?? false,
            ownerAlive = registered != null && Alive(registered.Owner),
            prefabAlive = registered != null && Alive(registered.Prefab),
            prefabReady = registered != null && Alive(registered.Prefab) && registered.Prefab.Ready,
            prefabValid = registered != null && Alive(registered.Prefab) && registered.Prefab.Valid,
            loadedPrefabPath = registered != null && Alive(registered.Prefab) ? registered.Prefab.Path : null,
            loadedCatalogPath = registered?.ExpectedCatalog, loadedExpectedPrefab = registered?.ExpectedPrefab,
            normalPresent, hqPresent, expectedAddress = expectedAddress == 0 ? null : $"0x{expectedAddress:X}",
            normalAddress = normalAddress == 0 ? null : $"0x{normalAddress:X}",
            hqAddress = hqAddress == 0 ? null : $"0x{hqAddress:X}"
        };
    }

    static object BeginWardrobeApply(JsonElement request, string id) {
        if (s_wardrobeJob != null || s_transitionRequest != null || s_outfitRequest != null || s_loadId != null || s_restoreJob != null)
            throw new InvalidOperationException("Appearance operation already in progress");
        if (s_nativeMenuSync) throw new InvalidOperationException("Disable legacy native-menu synchronization before four-category selection");
        var registry = WardrobeRegistry.ReadDirectory(Path.Combine(s_dir, "mods"));
        s_activeMods.TryGetValue(AppearanceKind.Outfit, out var outfit);
        s_wardrobeRegistry = registry;
        s_activeMods.TryGetValue(AppearanceKind.Weapon, out var weapon);
        var state = s_wardrobeState ?? WardrobeSelections.FromLegacy(new SavedAppearance(outfit, weapon));
        var category = request.GetProperty("category").GetString() switch {
            "body" => WardrobeCategory.Body, "cloak" => WardrobeCategory.Cloak,
            "gauntlet" => WardrobeCategory.Gauntlet, "weapon" => WardrobeCategory.Weapon,
            _ => throw new InvalidOperationException("Unknown wardrobe category") };
        bool showRequest = request.TryGetProperty("visible", out var visible);
        bool requestForce = false;
        if (showRequest) {
            state = WardrobeSelections.SetVisible(state, category, visible.GetBoolean());
            requestForce = visible.GetBoolean();
        } else {
            var choice = request.GetProperty("modId");
            state = WardrobeSelections.Choose(state, category, choice.ValueKind == JsonValueKind.Null ? null : choice.GetString(), registry);
            requestForce = choice.ValueKind != JsonValueKind.Null;
        }
        if (category == WardrobeCategory.Cloak || category == WardrobeCategory.Gauntlet) {
            var required = WardrobeSelections.RequiredForceDeclarations(state, category, registry);
            if (request.TryGetProperty("confirmedDeclarations", out var confirmations)) {
                var approved = new List<string>();
                foreach (var confirmation in confirmations.EnumerateArray()) approved.Add(confirmation.GetString());
                state = WardrobeSelections.ConfirmForce(state, category, approved.AsReadOnly(), registry);
            } else if (requestForce && required.Count > 0) {
                var names = new List<string>();
                foreach (var declaringId in required) names.Add(registry.Entries[declaringId].Name);
                if (id.StartsWith("ui-", StringComparison.Ordinal)) {
                    string modId = null;
                    if (request.TryGetProperty("modId", out var pendingChoice) && pendingChoice.ValueKind == JsonValueKind.String)
                        modId = pendingChoice.GetString();
                    Volatile.Write(ref s_confirmation, new WardrobeMenuConfirmation(category.ToString().ToLowerInvariant(),
                        modId, showRequest ? visible.GetBoolean() : null, new List<string>(required).ToArray(), names.ToArray()));
                }
                return new { phase = "confirmation_required", category = category.ToString(), declarations = required,
                    names, message = "作者声明隐藏此部位，强制穿戴可能出现穿模。是否强制穿戴？" };
            }
        } else if (request.TryGetProperty("confirmedDeclarations", out var unsupportedConfirmation))
            throw new InvalidOperationException("Only cloak and gauntlet support force confirmation");
        return StartWardrobeState(state, registry, id, false);
    }

    static object StartWardrobeState(WardrobeSelectionState state, WardrobeRegistrySnapshot registry, string id, bool allowMissing) {
        var resolved = WardrobeSelections.Resolve(state, registry);
        if (!allowMissing && resolved.Issues.Count > 0) throw new InvalidOperationException(string.Join("; ", resolved.Issues));
        foreach (var part in resolved.Composition.HiddenParts)
            if (part != "HEAD" && part != "HAIR" && part != "CLOAK" && part != "GAUNTLET")
                throw new InvalidOperationException("Native visibility not implemented for " + part);
        VisibilitySupporter();
        if (resolved.Composition.HiddenParts.Count > 0 && via.GameObject.REFType.GetMethod("set_DrawSelf") == null)
            throw new InvalidOperationException("Visibility setter unavailable");
        var physical = new Dictionary<AppearanceKind, List<AppearancePart>>();
        foreach (var selected in resolved.Composition.Effective) {
            var kind = selected.Key == WardrobeCategory.Weapon ? AppearanceKind.Weapon : AppearanceKind.Outfit;
            if (!physical.TryGetValue(kind, out var parts)) physical.Add(kind, parts = new List<AppearancePart>());
            foreach (var part in registry.Entries[selected.Value].Parts) {
                foreach (var hidden in resolved.Composition.HiddenParts)
                    if (part.Part == hidden) throw new InvalidOperationException("Active provided part is also hidden: " + hidden);
                parts.Add(new AppearancePart((int)Enum.Parse<app.PlayerPartsDef.PARTS_TYPE>(part.Part), part.Catalog, part.Prefab));
            }
        }
        var entries = new List<AppearanceEntry>();
        foreach (var pair in physical)
            entries.Add(new AppearanceEntry("runtime.wardrobe." + pair.Key.ToString().ToLowerInvariant(),
                "四分类组合", pair.Key, pair.Value.AsReadOnly(), "runtime composition"));
        s_wardrobeJob = new WardrobeApplyJob { Id = id, State = state, Plan = resolved.Composition, Entries = entries };
        return new { phase = "loading_wardrobe", requested = state.Requested, effective = resolved.Composition.Effective };
    }

    static void PollWardrobeApply() {
        var job = s_wardrobeJob;
        try {
            if (job.Clock.ActiveMilliseconds > 60000) throw new TimeoutException("Four-category native transition timed out");
            if (job.Waiting) return;
            if (job.Error != null) throw new InvalidOperationException(job.Error);
            if (job.Stage > job.Entries.Count) {
                // Selection publication follows native completion, never only manifest validation.
                var info = Manager().getControllingPlayerInfo();
                var entity = Alive(info) ? info.CharacterEntity : null;
                var supporter = Alive(entity) ? entity.GameObjectSupporter : null;
                if (!UsableSupporter(supporter) || supporter.isChangeModelProcessing()) return;
                if (s_restoreJob != null && job.Id == s_restoreJob.OperationId && !s_loadCoordinator.IsCurrent(s_restoreJob.Ticket))
                    throw new InvalidOperationException("Appearance load superseded");
                if (s_selectedParts.Count > 0 && ((IProxyable)supporter).GetAddress() != s_visualSupporter) {
                    job.Stage = 0;
                    return;
                }
                foreach (var part in s_selectedParts)
                    if (supporter._ModelIDs[part.Key] != part.Value) return;
                using var visibility = JsonDocument.Parse(JsonSerializer.Serialize(new { parts = job.Plan.HiddenParts }));
                var status = SetVisibility(visibility.RootElement);
                s_wardrobeState = job.State;
                Volatile.Write(ref s_saveSnapshot, WardrobeSaveStore.Freeze(job.State));
                if (s_restoreJob == null) s_restoreUnresolved = false;
                s_wardrobeJob = null;
                Respond(job.Id, true, new { phase = "finished", requested = job.State.Requested,
                    effective = job.Plan.Effective, suppressed = job.Plan.Suppressed, visibility = status, equipped = Equipped(Manager()) });
                return;
            }
            job.StepId = job.Id + ":step:" + job.Stage;
            job.Waiting = true;
            if (job.Stage == 0) {
                using var off = JsonDocument.Parse("{\"parts\":[]}");
                SetVisibility(off.RootElement);
                Respond(job.StepId, true, BeginTransition(job.StepId, null, 0));
            } else {
                var entry = job.Entries[job.Stage - 1];
                if (!s_registrySlots.TryGetValue(entry.Id, out int slot)) {
                    if (s_registrySlots.Count >= 3000) throw new InvalidOperationException("Runtime MOD ID reserve exhausted");
                    slot = s_registrySlots.Count + 1;
                    s_registrySlots.Add(entry.Id, slot);
                }
                Respond(job.StepId, true, BeginOutfit(job.StepId, entry, slot));
            }
        } catch (Exception e) {
            s_wardrobeState = job.State;
            s_wardrobeJob = null;
            s_restoreUnresolved = true;
            Respond(job.Id, false, new { error = e.Message, partial = true,
                detail = "Native apply incomplete; resources retained for normal clear and no v1 save permitted" });
        }
    }

    static app.cPlayerGameObjectSupporter VisibilitySupporter() {
        var info = Manager().getControllingPlayerInfo();
        var entity = Alive(info) ? info.CharacterEntity : null;
        var supporter = Alive(entity) ? entity.GameObjectSupporter : null;
        if (!UsableSupporter(supporter) || supporter.isChangeModelProcessing())
            throw new InvalidOperationException("Player unavailable or changing model");
        return supporter;
    }

    static readonly string[] s_visibilityParts = { "HEAD", "HAIR", "CLOAK", "CLOAK_CLOSE", "CLOAK_OPEN", "GAUNTLET" };
    static object InspectPartVisibility() {
        var supporter = VisibilitySupporter();
        var result = new List<object>();
        foreach (var part in s_visibilityParts) {
            var type = Enum.Parse<app.cPlayerGameObjectSupporter.PLAYER_GAME_OBJECT>(part);
            var obj = supporter.getGameObject(type);
            result.Add(new { part, available = Alive(obj), value = DescribeObject(obj),
                drawSelf = Alive(obj) ? (bool?)obj.DrawSelf : null, draw = Alive(obj) ? (bool?)obj.Draw : null });
        }
        return result;
    }

    // Finite diagnostic lease: no asset, update, physics or equipment mutation.
    static object BeginVisibilityProbe(JsonElement request, string id) {
        if (s_hiddenParts.Count > 0 || s_hiddenObjects.Count > 0)
            throw new InvalidOperationException("Disable persistent visibility before the finite probe");
        if (s_visibilityProbeRequest != null || s_transitionRequest != null || s_outfitRequest != null || s_restoreJob != null)
            throw new InvalidOperationException("Another appearance operation is active");
        var supporter = VisibilitySupporter();
        var requested = new HashSet<string>();
        foreach (var item in request.GetProperty("parts").EnumerateArray()) {
            var part = item.GetString();
            if (Array.IndexOf(s_visibilityParts, part) < 0 || !requested.Add(part))
                throw new InvalidOperationException("Unsupported or duplicate visibility part");
        }
        if (requested.Count == 0) throw new InvalidOperationException("No visibility parts requested");
        var seen = new HashSet<ulong>();
        try {
            foreach (var part in requested) {
                var obj = supporter.getGameObject(Enum.Parse<app.cPlayerGameObjectSupporter.PLAYER_GAME_OBJECT>(part));
                if (!Alive(obj) || !obj.Valid) throw new InvalidOperationException("Part unavailable: " + part);
                ulong address = ((IProxyable)obj).GetAddress();
                if (!seen.Add(address)) continue;
                s_visibilityProbe.Add(new VisibilityProbeTarget {
                    Owner = ManagedObject.FromAddress(address).Globalize(), Original = obj.DrawSelf, Part = part });
            }
            s_visibilityProbeRequest = id;
            s_visibilityProbeDeadline = Environment.TickCount64 + 3000;
            return new { phase = "loading_visibility_probe", seconds = 3 };
        } catch { RestoreVisibilityProbe(); throw; }
    }

    static void RestoreVisibilityProbe() {
        foreach (var target in s_visibilityProbe) {
            try {
                var obj = target.Owner.As<via.GameObject>();
                if (Alive(obj) && obj.Valid) obj.DrawSelf = target.Original;
            } finally { target.Owner.Release(); }
        }
        s_visibilityProbe.Clear();
        s_visibilityProbeRequest = null;
    }

    static void PollVisibilityProbe() {
        var id = s_visibilityProbeRequest;
        try {
            if (Environment.TickCount64 >= s_visibilityProbeDeadline) {
                RestoreVisibilityProbe();
                Respond(id, true, new { phase = "finished", restored = true, parts = InspectPartVisibility() });
                return;
            }
            foreach (var target in s_visibilityProbe) {
                var obj = target.Owner.As<via.GameObject>();
                if (!Alive(obj) || !obj.Valid) throw new InvalidOperationException("Visibility target destroyed");
                obj.DrawSelf = false;
                if (obj.DrawSelf) throw new InvalidOperationException("Visibility setter did not hold");
            }
        } catch (Exception e) {
            RestoreVisibilityProbe();
            Respond(id, false, new { error = e.Message });
        }
    }

    static object SetVisibility(JsonElement request) {
        if (s_visibilityProbeRequest != null) throw new InvalidOperationException("Finite probe is active");
        var desired = new HashSet<string>();
        foreach (var value in request.GetProperty("parts").EnumerateArray()) {
            var part = value.GetString();
            if (part != "HEAD" && part != "HAIR" && part != "CLOAK" && part != "GAUNTLET")
                throw new InvalidOperationException("Unsupported logical hidden part");
            if (!desired.Add(part)) throw new InvalidOperationException("Duplicate hidden part");
        }
        if (desired.Contains("CLOAK")) { desired.Add("CLOAK_CLOSE"); desired.Add("CLOAK_OPEN"); }
        if (desired.Count > 0) {
            VisibilitySupporter(); // Do not replace a working plan while the player is unavailable.
            if (!s_visibilityHookInstalled) {
                var method = via.GameObject.REFType.GetMethod("set_DrawSelf");
                if (method == null) throw new InvalidOperationException("Native DrawSelf setter unavailable");
                MethodHook.Create(method, false).AddPre(args => {
                    // Native callbacks only touch managed scalar state, never resolve game objects here.
                    if (!s_stopped && !s_reloadFreeze && !s_ownVisibilityWrite && args.Length > 2 &&
                        Volatile.Read(ref s_hiddenObjects).TryGetValue(args[1], out var target)) {
                        Volatile.Write(ref target.RequestedDraw, args[2] != 0 ? 1 : 0);
                        args[2] = 0;
                    }
                    return PreHookResult.Continue;
                });
                s_visibilityHookInstalled = true;
            }
        }
        s_hiddenParts = desired;
        PollVisibility();
        return new { parts = s_hiddenParts, tracked = s_hiddenObjects.Count, status = s_visibilityStatus };
    }

    static void ReleaseHiddenObjects(HashSet<ulong> keep) {
        var previous = Volatile.Read(ref s_hiddenObjects);
        var remaining = new Dictionary<ulong, HiddenObject>();
        foreach (var pair in previous) if (keep.Contains(pair.Key)) remaining.Add(pair.Key, pair.Value);
        // Withdraw hooks before restoring. Pinned objects cannot be recycled into unrelated addresses.
        Volatile.Write(ref s_hiddenObjects, remaining);
        foreach (var pair in previous) if (!keep.Contains(pair.Key)) {
            try {
                var obj = pair.Value.Owner.As<via.GameObject>();
                if (Alive(obj) && obj.Valid) obj.DrawSelf = Volatile.Read(ref pair.Value.RequestedDraw) != 0;
            } finally { pair.Value.Owner.Release(); }
        }
    }

    static void PollVisibility() {
        try {
            if (s_hiddenParts.Count == 0) {
                ReleaseHiddenObjects(new HashSet<ulong>());
                s_visibilityStatus = "disabled";
                return;
            }
            var supporter = VisibilitySupporter();
            var targets = new Dictionary<ulong, via.GameObject>();
            foreach (var part in s_hiddenParts) {
                var root = supporter.getGameObject(Enum.Parse<app.cPlayerGameObjectSupporter.PLAYER_GAME_OBJECT>(part));
                if (!Alive(root) || !root.Valid) continue; // Some optional cloak variants are not instantiated.
                foreach (var obj in Descendants(root)) {
                    if (!obj.Valid) continue;
                    var mesh = obj.getComponent(via.render.Mesh.REFType.RuntimeType.As<_System.Type>());
                    if (Alive(mesh)) targets[((IProxyable)obj).GetAddress()] = obj;
                }
            }
            ReleaseHiddenObjects(new HashSet<ulong>(targets.Keys));
            var next = new Dictionary<ulong, HiddenObject>(s_hiddenObjects);
            foreach (var pair in targets) if (!next.ContainsKey(pair.Key))
                next.Add(pair.Key, new HiddenObject { Owner = ManagedObject.FromAddress(pair.Key).Globalize(),
                    RequestedDraw = pair.Value.DrawSelf ? 1 : 0 });
            Volatile.Write(ref s_hiddenObjects, next);
            s_ownVisibilityWrite = true;
            try {
                foreach (var obj in targets.Values) {
                    obj.DrawSelf = false;
                    if (obj.DrawSelf) throw new InvalidOperationException("Hidden object rejected DrawSelf=false");
                }
            } finally { s_ownVisibilityWrite = false; }
            s_visibilityFrames++;
            s_visibilityStatus = "active";
        } catch (Exception e) {
            // A changing/temporarily absent player does not erase the requested declaration.
            s_visibilityStatus = "waiting: " + e.Message;
        }
    }

    // CG updates can overwrite visibility after UpdateBehavior. Reapply only to
    // already pinned targets here; hierarchy discovery and ownership remain in Update.
    // Own writes must not replace the native state restored when a declaration ends.
    static void ReapplyHiddenVisibility() {
        if (s_stopped || s_reloadFreeze || s_hiddenParts.Count == 0) return;
        s_ownVisibilityWrite = true;
        try {
            foreach (var target in Volatile.Read(ref s_hiddenObjects).Values) {
                var obj = target.Owner.As<via.GameObject>();
                if (Alive(obj) && obj.Valid) obj.DrawSelf = false;
            }
        } catch (Exception e) {
            s_visibilityStatus = "late visibility waiting: " + e.Message;
        } finally { s_ownVisibilityWrite = false; }
    }

    static List<via.GameObject> Descendants(via.GameObject root) {
        var result = new List<via.GameObject>();
        var pending = new Queue<via.GameObject>();
        var seen = new HashSet<ulong>();
        pending.Enqueue(root);
        while (pending.Count > 0 && result.Count < 128) {
            var obj = pending.Dequeue();
            if (!Alive(obj) || !seen.Add(((IProxyable)obj).GetAddress())) continue;
            result.Add(obj);
            var transform = obj.Transform;
            if (!Alive(transform)) continue;
            var child = transform.Child;
            int count = 0;
            while (Alive(child) && count++ < 128) {
                pending.Enqueue(child.GameObject);
                child = child.Next;
            }
        }
        return result;
    }

    static object DescribeObject(via.GameObject obj) {
        if (!Alive(obj)) return null;
        var component = obj.getComponent(via.render.Mesh.REFType.RuntimeType.As<_System.Type>());
        var mesh = Alive(component) ? ManagedObject.FromAddress(((IProxyable)component).GetAddress()).As<via.render.Mesh>() : null;
        var chainComponent = obj.getComponent(via.motion.Chain2.REFType.RuntimeType.As<_System.Type>());
        var chain = Alive(chainComponent) ? ManagedObject.FromAddress(((IProxyable)chainComponent).GetAddress()).As<via.motion.Chain2>() : null;
        var components = new List<string>();
        var array = obj.Components;
        if (Alive(array)) for (int i = 0; i < Math.Min(array.Length, 256); i++) {
            var item = array[i];
            if (Alive(item)) components.Add(ManagedObject.FromAddress(((IProxyable)item).GetAddress()).GetTypeDefinition().FullName);
        }
        return new { address = "0x" + ((IProxyable)obj).GetAddress().ToString("X"), name = obj.Name,
            runtimeType = ManagedObject.FromAddress(((IProxyable)obj).GetAddress()).GetTypeDefinition().FullName,
            mesh = Alive(mesh) && Alive(mesh.getMesh()) ? mesh.getMesh().ResourcePath : null,
            material = Alive(mesh) && Alive(mesh.Material) ? mesh.Material.ResourcePath : null,
            chainAsset = Alive(chain) && Alive(chain.ChainAsset) ? chain.ChainAsset.ResourcePath : null,
            chainSetup = Alive(chain) ? (bool?)chain.Setuped : null, components };
    }

    static object InspectBodyMaterials() {
        var info = Manager().getControllingPlayerInfo();
        if (!Alive(info) || !Alive(info.Object)) throw new InvalidOperationException("Player unavailable");
        foreach (var obj in Descendants(info.Object)) {
            if (obj.Name != "Body") continue;
            var component = obj.getComponent(via.render.Mesh.REFType.RuntimeType.As<_System.Type>());
            if (!Alive(component)) continue;
            var mesh = ManagedObject.FromAddress(((IProxyable)component).GetAddress()).As<via.render.Mesh>();
            if (!mesh.MaterialReady) throw new InvalidOperationException("Body materials are still loading");
            var materials = new List<object>();
            for (uint i = 0; i < Math.Min(mesh.MaterialNum, 128u); i++) {
                var textures = new List<object>();
                for (uint j = 0; j < Math.Min(mesh.getMaterialTextureNum(i), 128u); j++) {
                    var texture = mesh.getMaterialTexture(i, j);
                    textures.Add(new { index = j, name = mesh.getMaterialTextureName(i, j),
                        path = Alive(texture) ? texture.ResourcePath : null });
                }
                materials.Add(new { index = i, name = mesh.getMaterialName(i), textures });
            }
            return new { material = mesh.Material.ResourcePath, ready = mesh.MaterialReady,
                linked = mesh.MaterialLinked, materials };
        }
        throw new InvalidOperationException("Body mesh unavailable");
    }

    static ManagedObject LoadHolder(string resourceType, string holderType, string path) {
        var resource = API.GetResourceManager().CreateResource(resourceType, path);
        if (resource == null) throw new InvalidOperationException("Resource unavailable: " + path);
        resource.AddRef();
        try {
            var holder = resource.CreateHolder(holderType);
            if (!Alive(holder)) throw new InvalidOperationException("Holder unavailable: " + path);
            return holder.Globalize();
        } finally { resource.Release(); }
    }

    static app.AfterImageController AfterImage(via.GameObject owner) {
        var component = owner.getComponent(app.AfterImageController.REFType.RuntimeType.As<_System.Type>());
        return Alive(component) ? ManagedObject.FromAddress(((IProxyable)component).GetAddress()).As<app.AfterImageController>() : null;
    }

    static object ApplyManbaMeshes() {
        if (s_meshSwaps.Count != 0) throw new InvalidOperationException("Restore the active mesh probe first");
        var manager = Manager();
        var info = manager.getControllingPlayerInfo();
        if (!Alive(info) || !Alive(info.Object)) throw new InvalidOperationException("Player object unavailable");
        var before = Equipped(manager);
        var afterImage = AfterImage(info.Object);
        if (!Alive(afterImage)) throw new InvalidOperationException("Native model-change lifecycle unavailable");
        var prepared = new List<MeshSwap>();
        foreach (var obj in Descendants(info.Object)) {
            var component = obj.getComponent(via.render.Mesh.REFType.RuntimeType.As<_System.Type>());
            if (!Alive(component)) continue;
            var mesh = ManagedObject.FromAddress(((IProxyable)component).GetAddress()).As<via.render.Mesh>();
            var original = mesh.getMesh();
            if (!Alive(original)) continue;
            string path = original.ResourcePath;
            string suffix = null;
            foreach (var number in new[] { "00", "10", "20" }) {
                if (string.Equals(path, "Art/Model/Character/ch0/ch001_00/" + number + "/ch001_00_" + number + ".mesh", StringComparison.OrdinalIgnoreCase))
                    suffix = number;
            }
            if (suffix == null) continue;
            string prefix = "mods/owots/manba_2______________/" + suffix + "/ch001_00_" + suffix;
            var meshHolder = LoadHolder("via.render.MeshResource", "via.render.MeshResourceHolder", prefix + ".mesh");
            var materialHolder = LoadHolder("via.render.MeshMaterialResource", "via.render.MeshMaterialResourceHolder", prefix + ".mdf2");
            prepared.Add(new MeshSwap { Component = mesh, OriginalMesh = original, OriginalMaterial = mesh.Material,
                ModMesh = meshHolder.As<via.render.MeshResourceHolder>(), ModMaterial = materialHolder.As<via.render.MeshMaterialResourceHolder>(),
                MeshOwner = meshHolder, MaterialOwner = materialHolder, OriginalPath = path });
        }
        if (prepared.Count != 3) throw new InvalidOperationException("Expected exactly body/head/hair renderers; found " + prepared.Count);
        s_swapAfterImage = afterImage;
        afterImage.onChangeModelStart();
        try {
            foreach (var swap in prepared) {
                s_meshSwaps.Add(swap);
                swap.Component.setMesh(swap.ModMesh);
                swap.Component.Material = swap.ModMaterial;
            }
            var objects = new List<object>();
            foreach (var swap in s_meshSwaps) objects.Add(DescribeObject(swap.Component.GameObject));
            return new { applied = true, before, after = Equipped(manager), objects,
                lifecycle = "AfterImageController.onChangeModelStart/Finish",
                scope = "Mesh/material binding only; native equipment and physics untouched" };
        } catch { RestoreMeshes(); throw; }
        finally { if (Alive(afterImage)) afterImage.onChangeModelFinish(); }
    }

    static object RestoreMeshes() {
        int restored = 0;
        var afterImage = s_swapAfterImage;
        if (s_meshSwaps.Count == 0) return new { restored };
        if (Alive(afterImage)) afterImage.onChangeModelStart();
        try {
        foreach (var swap in s_meshSwaps) {
            if (!Alive(swap.Component) || !Alive(swap.Component.GameObject)) continue;
            // Do not overwrite a subsequent change made by the game or another mod.
            var current = swap.Component.getMesh();
            if (!Alive(current) || !string.Equals(current.ResourcePath, swap.ModMesh.ResourcePath, StringComparison.OrdinalIgnoreCase)) continue;
            swap.Component.setMesh(swap.OriginalMesh);
            swap.Component.Material = swap.OriginalMaterial;
            restored++;
        }
        s_meshSwaps.Clear(); // CLR wrappers retain native references until finalization; no double Release.
        s_swapAfterImage = null;
        return new { restored };
        } finally { if (Alive(afterImage)) afterImage.onChangeModelFinish(); }
    }

    static string LabUserDataPath(string path) {
        if (path == null || !path.StartsWith("mods/owots_appearance_lab/", StringComparison.Ordinal)
            || path.Contains("..") || path.Contains('\\') || !path.EndsWith(".user", StringComparison.Ordinal))
            throw new InvalidOperationException("Expected isolated lab UserData path");
        return path;
    }

    static object InspectUserData(JsonElement request) {
        string path = LabUserDataPath(request.GetProperty("path").GetString());
        var resource = API.GetResourceManager().CreateUserData("app.user_data.PlayerPartsList", path);
        if (!Alive(resource)) return new { available = false, path };
        var list = resource.As<app.user_data.PlayerPartsList>();
        var entries = new List<object>();
        for (int i = 0; i < Math.Min(list.DataNum, 128); i++) {
            var entry = list._DataList[i];
            var prefab = entry.PartsPrefab;
            entries.Add(new { id = entry.ID, path = Alive(prefab) ? prefab.Path : null,
                valid = Alive(prefab) && prefab.Valid, ready = Alive(prefab) && prefab.Ready,
                exists = Alive(prefab) && prefab.Exist });
        }
        return new { available = true, path, count = list.DataNum, entries };
    }

    static object BeginPrefabLoad(JsonElement request, string id, bool selectBody = false) {
        // Only isolated fixtures: never enable standby on an original catalog prefab.
        if (s_loadOwner != null) throw new InvalidOperationException("Load already active");
        string catalogPath = LabUserDataPath(request.TryGetProperty("path", out var pathValue)
            ? pathValue.GetString() : "mods/owots_appearance_lab/body_catalog.user");
        if (selectBody && (s_aliasRegistered || s_visualOwner != null)) throw new InvalidOperationException("Clear current probe before selecting another");
        if (selectBody && catalogPath != "mods/owots_appearance_lab/body_catalog.user" &&
            catalogPath != "mods/owots_appearance_lab/manba_2/body_catalog.user" &&
            catalogPath != "mods/owots_appearance_lab/manba_3/body_catalog.user")
            throw new InvalidOperationException("Body selection accepts only the private body fixtures");
        var owner = API.GetResourceManager().CreateUserData("app.user_data.PlayerPartsList",
            catalogPath);
        if (!Alive(owner)) throw new InvalidOperationException("Probe catalog unavailable");
        s_loadOwner = owner.Globalize();
        try {
            // CreateUserData may return before its data array is populated on a cold load.
            // Resolve the prefab in later callbacks instead of treating this as invalid data.
            s_loadId = id;
            s_loadSelectBody = selectBody;
            s_loadDeadline = Environment.TickCount64 + 15000;
            return new { phase = "loading_catalog", path = catalogPath };
        } catch { ClearLoad(); throw; }
    }

    static object ConfigureNativeMenuSync(JsonElement request) {
        if (request.TryGetProperty("enabled", out var value)) {
            bool enabled = value.GetBoolean();
            if (enabled && !s_nativeMenuHooks) {
                MethodHook.Create(NamedMethod(app.GUI030106.REFType, "onOpen"), false).AddPre(args => {
                    if (!s_stopped && !s_reloadFreeze && s_nativeMenuSync && args.Length > 1) s_nativeSelections.Open(args[1]);
                    return PreHookResult.Continue;
                });
                MethodHook.Create(NamedMethod(app.GUI030106.cCostumeList.REFType, "callback_Decide"), false)
                    .AddPre(args => {
                        (ulong Owner, int Category) decision = (0, -1);
                        try {
                            if (!s_stopped && !s_reloadFreeze && s_nativeMenuSync && args.Length >= 5) {
                                var list = ManagedObject.FromAddress(args[1]).As<app.GUI030106.cCostumeList>();
                                uint index = unchecked((uint)args[4]);
                                if (Alive(list._Owner) && list._DisplayItemList != null && index < list._DisplayItemList.Count)
                                    decision = (((IProxyable)list._Owner).GetAddress(), (int)list._SelectedCategory);
                            }
                        } catch (Exception e) { AppendSaveTrace(new { phase = "native_menu_decide_observation_failed", error = e.Message }); }
                        (s_nativeDecideScopes ??= new Stack<(ulong, int)>()).Push(decision);
                        return PreHookResult.Continue;
                    }).AddPost((ref ulong result) => {
                        if (s_nativeDecideScopes?.Count > 0) {
                            var decision = s_nativeDecideScopes.Pop();
                            if (!s_stopped && !s_reloadFreeze && s_nativeMenuSync && decision.Owner != 0)
                                s_nativeSelections.Confirm(decision.Owner, decision.Category);
                        }
                    });
                MethodHook.Create(NamedMethod(app.GUI030106.REFType, "applyCostume"), false)
                    .AddPre(args => { (s_nativeApplyScopes ??= new Stack<ulong>()).Push(args.Length > 1 ? args[1] : 0); return PreHookResult.Continue; })
                    .AddPost((ref ulong result) => {
                        if (s_nativeApplyScopes?.Count > 0) {
                            ulong owner = s_nativeApplyScopes.Pop();
                            int groups = s_nativeSelections.ConsumeApplied(owner);
                            if (!s_stopped && !s_reloadFreeze && s_nativeMenuSync && groups != 0) {
                                Interlocked.Or(ref s_nativeMenuPending, groups);
                                AppendSaveTrace(new { phase = "native_menu_confirmed", groups });
                            }
                        }
                    });
                MethodHook.Create(NamedMethod(app.GUI030106.REFType, "onClose"), false)
                    .AddPre(args => { (s_nativeCloseScopes ??= new Stack<ulong>()).Push(args.Length > 1 ? args[1] : 0); return PreHookResult.Continue; })
                    .AddPost((ref ulong result) => { if (s_nativeCloseScopes?.Count > 0) s_nativeSelections.Close(s_nativeCloseScopes.Pop()); });
                s_nativeMenuHooks = true;
            }
            s_nativeMenuSync = enabled;
            if (!enabled) {
                Interlocked.Exchange(ref s_nativeMenuPending, 0);
                s_nativeSelections.Clear();
            }
        }
        Volatile.Write(ref s_preferences, Volatile.Read(ref s_preferences) with { NativeMenuSync = s_nativeMenuSync });
        return new { enabled = s_nativeMenuSync, pendingGroups = Volatile.Read(ref s_nativeMenuPending),
            scope = "Native confirmation to MOD cancellation only; native MOD rows are not implemented" };
    }

    static bool PollNativeMenuSync() {
        if (s_reloadFreeze) return false;
        int groups = Interlocked.Exchange(ref s_nativeMenuPending, 0);
        if (groups == 0) return false;
        var kind = groups == NativeCostumeSelections.Outfit ? (AppearanceKind?)AppearanceKind.Outfit :
            groups == NativeCostumeSelections.Weapon ? AppearanceKind.Weapon : null;
        s_nativeMenuRequest = "native-menu-" + Guid.NewGuid().ToString("N");
        try { Respond(s_nativeMenuRequest, true, BeginTransition(s_nativeMenuRequest, null, 0, kind)); }
        catch (Exception e) { Respond(s_nativeMenuRequest, false, new { error = e.Message }); }
        return true;
    }

    static object InspectCostumeMethods() {
        var getter = new DynamicMethod("CostumeMethodAddress", typeof(IntPtr), new[] { typeof(Method) });
        var il = getter.GetILGenerator();
        il.Emit(OpCodes.Ldarg_0);
        il.Emit(OpCodes.Call, typeof(Method).GetMethod("GetFunctionPtr"));
        il.Emit(OpCodes.Conv_I);
        il.Emit(OpCodes.Ret);
        var addressOf = (Func<Method, IntPtr>)getter.CreateDelegate(typeof(Func<Method, IntPtr>));
        var targets = new Dictionary<TypeDefinition, string[]> {
            [app.GUI030106.REFType] = new[] { "onOpen", "onClose", "applyCostume", "changePreviewModelFromCurrentSettings" },
            [app.GUI030106.cCostumeList.REFType] = new[] { "setup", "onUpdateItem", "callback_Select", "callback_Decide", "applyToPreview" },
            [app.GUI030106.cPlayerCostumeSettings.REFType] = new[] { "updateFromCurrentSettings" }
        };
        var result = new List<object>();
        foreach (var pair in targets) foreach (var method in pair.Key.Methods) {
            if (Array.IndexOf(pair.Value, method.Name) < 0) continue;
            var address = addressOf(method);
            if (address == IntPtr.Zero) continue;
            var bytes = new byte[4096];
            Marshal.Copy(address, bytes, 0, bytes.Length);
            var parameters = new List<object>();
            foreach (var param in method.GetParameters()) parameters.Add(new { name = param.Name, type = param.Type.FullName });
            result.Add(new { type = pair.Key.FullName, name = method.Name, parameters,
                address = "0x" + address.ToInt64().ToString("X"), code = Convert.ToHexString(bytes) });
        }
        return result;
    }

    static object InspectModelMethods() {
        // Convert the managed API's pointer result to IntPtr without enabling unsafe source compilation.
        var getter = new DynamicMethod("NativeMethodAddress", typeof(IntPtr), new[] { typeof(Method) });
        var il = getter.GetILGenerator();
        il.Emit(OpCodes.Ldarg_0);
        il.Emit(OpCodes.Call, typeof(Method).GetMethod("GetFunctionPtr"));
        il.Emit(OpCodes.Conv_I);
        il.Emit(OpCodes.Ret);
        var addressOf = (Func<Method, IntPtr>)getter.CreateDelegate(typeof(Func<Method, IntPtr>));
        var result = new List<object>();
        // Exact-build read-only TDB candidates cross-checked against native callsites.
        foreach (ulong pointer in new ulong[] { 0x14A76E670, 0x14A76E544, 0x14A769D98,
            0x14A769DD4, 0x14A7E2404, 0x14A7E2410, 0x14AC58B04 }) {
            var candidate = Method.createFromPointer(pointer);
            var native = addressOf(candidate);
            var parameters = new List<object>();
            foreach (var p in candidate.GetParameters()) parameters.Add(new { name = p.Name, type = p.Type.FullName });
            result.Add(new { type = candidate.DeclaringType.FullName, name = candidate.Name,
                parameters, address = "0x" + native.ToInt64().ToString("X"), code = "" });
        }
        var targets = new Dictionary<TypeDefinition, string[]> {
            [app.cPlayerGameObjectSupporter.REFType] = new[] { "requestChangeModelCore", "onChangeModel", "checkModelChange", "checkModelUpdate", "resetChangeState", "initSetting", "collectModelMaterialManager" },
            [app.PlayerManager.REFType] = new[] { "changePlayerModel", "getCurrentEquipID", "getPrefabWithStandby" },
            [app.AfterImageController.REFType] = new[] { "onChangeModelStart", "onChangeModelFinish", "reloadAfterImages", "initMaterialInfoSetUp", "refreshMeshTree", "updateMain", "updateCore" },
            [app.AfterImageMaterialParamRecorder.REFType] = new[] { "init", "record" },
            [app.MeshSetting.REFType] = new[] { "doSetupMaterialParam", "doAwakeAfter", "doStartAfter" }
        };
        foreach (var pair in targets) foreach (var method in pair.Key.Methods) {
            if (Array.IndexOf(pair.Value, method.Name) < 0) continue;
            var address = addressOf(method);
            if (address == IntPtr.Zero) continue;
            var bytes = new byte[4096];
            Marshal.Copy(address, bytes, 0, bytes.Length);
            var parameters = new List<object>();
            foreach (var param in method.GetParameters()) parameters.Add(new { name = param.Name, type = param.Type.FullName });
            result.Add(new { type = pair.Key.FullName, name = method.Name, parameters,
                address = "0x" + address.ToInt64().ToString("X"), code = Convert.ToHexString(bytes) });
        }
        // Read-only callback lookup for the exact local OWOTS executable researched in this lab.
        // This is not a portable runtime integration address.
        var callback = Method.createFromPointer((ulong)Marshal.ReadIntPtr(new IntPtr(0x14CB8C2C8)).ToInt64());
        var callbackAddress = addressOf(callback);
        var callbackBytes = new byte[4096];
        Marshal.Copy(callbackAddress, callbackBytes, 0, callbackBytes.Length);
        result.Add(new { type = callback.DeclaringType.FullName, name = callback.Name,
            parameters = new List<object>(), address = "0x" + callbackAddress.ToInt64().ToString("X"),
            code = Convert.ToHexString(callbackBytes) });
        foreach (var method in callback.DeclaringType.Methods) {
            if (method.Name == callback.Name) continue;
            var addr = addressOf(method);
            if (addr == IntPtr.Zero) continue;
            var bytes = new byte[4096];
            Marshal.Copy(addr, bytes, 0, bytes.Length);
            result.Add(new { type = method.DeclaringType.FullName, name = method.Name,
                parameters = new List<object>(), address = "0x" + addr.ToInt64().ToString("X"), code = Convert.ToHexString(bytes) });
        }
        return result;
    }

    static object ProbeNativeBodyRefresh(bool apply) {
        var manager = Manager();
        var info = manager.getControllingPlayerInfo();
        var entity = Alive(info) ? info.CharacterEntity : null;
        var supporter = Alive(entity) ? entity.GameObjectSupporter : null;
        if (apply && (!UsableSupporter(supporter) || supporter.isChangeModelProcessing() || supporter.isAddModelProcessing()))
            throw new InvalidOperationException("Native player model supporter is unavailable or busy");
        var part = app.PlayerPartsDef.PARTS_TYPE.BODY;
        int modelId = apply ? app.PlayerManager.getCurrentEquipID(part, info.Context.Player) : 7482;
        if (!manager.isExistsPrefab(part, modelId)) throw new InvalidOperationException("Current native body prefab missing");
        Method change = null;
        foreach (var method in app.cPlayerGameObjectSupporter.REFType.Methods)
            if (method.Name == "requestChangeModelCore") { change = method; break; }
        if (change == null) throw new InvalidOperationException("Native model request method missing");
        var listType = change.GetParameters()[0].Type;
        var owner = listType.CreateInstance(0)?.Globalize();
        // cChangeArgument has no Activator-compatible default constructor in this build.
        // REF's documented simplify allocation creates it without invoking that constructor;
        // both fields consumed by the native request are explicitly assigned below.
        var argumentOwner = app.PlayerPartsDef.cChangeArgument.REFType.CreateInstance(1)?.Globalize();
        if (!Alive(owner) || !Alive(argumentOwner)) {
            var diagnostic = "Cannot allocate native change request: list=" + Alive(owner) +
                ", argument=" + Alive(argumentOwner) + ", type=" + listType.FullName;
            argumentOwner?.Release(); owner?.Release();
            throw new InvalidOperationException(diagnostic);
        }
        try {
            var argument = argumentOwner.As<app.PlayerPartsDef.cChangeArgument>();
            argument.PartsType = part;
            argument.ID = modelId;
            var list = owner.As<REFrameworkNET.Collections.IList<app.PlayerPartsDef.cChangeArgument>>();
            list.Add(argument);
            var before = Equipped(manager);
            if (!apply) return new { allocated = true, count = list.Count, part = (int)list[0].PartsType, modelId = list[0].ID };
            supporter.requestChangeModelCore(list);
            return new { requested = true, modelId, before, after = Equipped(manager),
                changing = supporter.isChangeModelProcessing(), state = supporter._ChangeStateMain.ToString() };
        } finally { argumentOwner.Release(); owner.Release(); }
    }

    static Method NamedMethod(TypeDefinition type, string name) {
        foreach (var method in type.Methods) if (method.Name == name) return method;
        throw new InvalidOperationException(type.FullName + "." + name + " missing");
    }

    static bool UsableSupporter(app.cPlayerGameObjectSupporter supporter) =>
        Alive(supporter) && !supporter._IsDestroy;

    static object TraceSaveLoads(JsonElement request) {
        bool enabled = !request.TryGetProperty("enabled", out var value) || value.GetBoolean();
        if (enabled && !s_saveTraceInstalled) {
            Method resultConstructor = null;
            foreach (var method in ace.SaveDataManagerBase.cSaveDataRequestCallbackData.REFType.Methods)
                if (method.Name == ".ctor" && method.GetNumParams() == 4) {
                    if (resultConstructor != null) throw new InvalidOperationException("Ambiguous save result constructor");
                    resultConstructor = method;
                }
            if (resultConstructor == null) throw new InvalidOperationException("Save result constructor missing");
            var completionType = TDB.Get().FindType("app.SaveDataManager.<>c__DisplayClass100_0");
            if (completionType == null) throw new InvalidOperationException("Save completion closure missing");
            var completion = NamedMethod(completionType, "<requestUserSaveCore>b__0");
            if (completion.GetNumParams() != 1) throw new InvalidOperationException("Unexpected save completion signature");
            var getter = new DynamicMethod("SaveCompletionAddress", typeof(IntPtr), new[] { typeof(Method) });
            var il = getter.GetILGenerator();
            il.Emit(OpCodes.Ldarg_0);
            il.Emit(OpCodes.Call, typeof(Method).GetMethod("GetFunctionPtr"));
            il.Emit(OpCodes.Conv_I);
            il.Emit(OpCodes.Ret);
            s_saveCompletionFunction = (ulong)((Func<Method, IntPtr>)getter.CreateDelegate(typeof(Func<Method, IntPtr>)))(completion);
            MethodHook.Create(NamedMethod(app.SaveDataManager.REFType, "requestSaveBase"), false).AddPre(ObserveSaveBase);
            MethodHook.Create(completion, false).AddPre(ObserveSaveCompletion);
            MethodHook.Create(NamedMethod(app.SaveDataManager.REFType, "requestUserSaveCore"), false)
                .AddPre(BeginSaveWriteTrace).AddPost(EndSaveWriteTrace);
            MethodHook.Create(resultConstructor, false).AddPre(ObserveSaveResult);
            MethodHook.Create(NamedMethod(app.SaveDataManager.REFType, "requestUserLoadCore"), false)
                .AddPre(BeginSaveLoadTrace).AddPost(EndSaveLoadTrace);
            s_saveTraceInstalled = true;
        }
        s_saveTracing = enabled;
        lock (s_saveTraceLock) {
            if (!enabled) s_saveWriteClosures.Clear();
            var events = s_saveTrace.ToArray();
            if (request.TryGetProperty("clear", out var clear) && clear.GetBoolean()) s_saveTrace.Clear();
            return new { enabled, events, note = "Request return is not proof of successful load; no save writes or appearance restoration are performed." };
        }
    }

    static void AppendSaveTrace(object entry) {
        lock (s_saveTraceLock) {
            if (s_saveTrace.Count >= 256) s_saveTrace.RemoveAt(0);
            s_saveTrace.Add(entry);
        }
    }

    static PreHookResult BeginSaveLoadTrace(Span<ulong> args) {
        // Instance ABI: VM, manager, slot, callback. Copy scalars only; never retain native objects.
        long sequence = !s_stopped && !s_reloadFreeze && s_saveTracing && args.Length >= 4
            ? Interlocked.Increment(ref s_saveSequence) : 0;
        (s_saveLoadScopes ??= new Stack<long>()).Push(sequence);
        if (sequence != 0) lock (s_saveTraceLock) {
            s_loadCoordinator.Begin(sequence);
            if (s_autoRestoreEnabled) s_restoreUnresolved = true;
            s_nativeSelections.Clear();
            Interlocked.Exchange(ref s_nativeMenuPending, 0);
            if (s_loadIdentities.Count >= 128) s_loadIdentities.Clear();
            s_loadIdentities[sequence] = new LoadTrace { Slot = unchecked((int)args[2]) };
        }
        if (sequence != 0) AppendSaveTrace(new { sequence, phase = "request", thread = Environment.CurrentManagedThreadId,
            time = DateTimeOffset.UtcNow, manager = $"0x{args[1]:X}", slot = unchecked((int)args[2]), callback = $"0x{args[3]:X}" });
        return PreHookResult.Continue;
    }

    static void EndSaveLoadTrace(ref ulong result) {
        long sequence = s_saveLoadScopes?.Count > 0 ? s_saveLoadScopes.Pop() : 0;
        // The native return type is void. Do not interpret the return register as EXECUTE_RESULT.
        if (!s_stopped && !s_reloadFreeze && sequence != 0) AppendSaveTrace(new { sequence, phase = "returned",
            thread = Environment.CurrentManagedThreadId, time = DateTimeOffset.UtcNow });
        LoadTrace load = null;
        lock (s_saveTraceLock) s_loadIdentities.Remove(sequence, out load);
        if (!s_stopped && !s_reloadFreeze && load != null && load.Results == 1 && load.Success) {
            try {
                // Post hook runs after the native user-data copy; retain only immutable scalar identity.
                var key = CurrentSaveKey(API.GetManagedSingletonT<app.SaveDataManager>(), load.Slot);
                if (!s_loadCoordinator.Complete(sequence, key, s_autoRestoreEnabled)) {
                    AppendSaveTrace(new { sequence, phase = "loaded_identity_superseded" });
                    return;
                }
                Volatile.Write(ref s_missingIntent, null);
                AppendSaveTrace(new { sequence, phase = "loaded_identity", key });
            } catch (Exception e) { AppendSaveTrace(new { sequence, phase = "loaded_identity_failed", error = e.Message }); }
        }
    }

    static PreHookResult ObserveSaveResult(Span<ulong> args) {
        long sequence = s_saveLoadScopes?.Count > 0 ? s_saveLoadScopes.Peek() : 0;
        if (!s_stopped && !s_reloadFreeze && sequence != 0 && args.Length >= 6) lock (s_saveTraceLock) {
            if (s_loadIdentities.TryGetValue(sequence, out var load)) {
                load.Results++;
                load.Success = unchecked((int)args[2]) == 1 && unchecked((int)args[3]) == 0;
            }
        }
        if (!s_stopped && !s_reloadFreeze && sequence != 0 && args.Length >= 6)
            AppendSaveTrace(new { sequence, phase = "result_prepared", thread = Environment.CurrentManagedThreadId,
                time = DateTimeOffset.UtcNow, result = unchecked((int)args[2]), error = unchecked((int)args[3]),
                detail = unchecked((int)args[4]), target = $"0x{args[5]:X}" });
        // This is the constructed callback payload, before callback execution and user-data copy.
        return PreHookResult.Continue;
    }

    static PreHookResult BeginSaveWriteTrace(Span<ulong> args) {
        long sequence = !s_stopped && !s_reloadFreeze && s_saveTracing && args.Length >= 12
            ? Interlocked.Increment(ref s_saveSequence) : 0;
        (s_saveWriteScopes ??= new Stack<long>()).Push(sequence);
        if (sequence != 0) AppendSaveTrace(new { sequence, phase = "save_request", time = DateTimeOffset.UtcNow,
            slot = unchecked((int)args[3]), flags = new[] { args[6] & 0xff, args[7] & 0xff, args[8] & 0xff, args[9] & 0xff } });
        if (sequence != 0 && s_persistenceEnabled) CaptureAppearanceSave(sequence, args);
        return PreHookResult.Continue;
    }

    static void EndSaveWriteTrace(ref ulong result) {
        long sequence = s_saveWriteScopes?.Count > 0 ? s_saveWriteScopes.Pop() : 0;
        if (!s_stopped && !s_reloadFreeze && sequence != 0) AppendSaveTrace(new { sequence, phase = "save_returned", time = DateTimeOffset.UtcNow });
    }

    static PreHookResult ObserveSaveBase(Span<ulong> args) {
        long sequence = s_saveWriteScopes?.Count > 0 ? s_saveWriteScopes.Peek() : 0;
        if (s_stopped || s_reloadFreeze || sequence == 0 || args.Length < 6 || args[5] == 0) return PreHookResult.Continue;
        try {
            // Current-build delegate layout verified at the native invocation loops:
            // +0x10 count, +0x18 target, +0x20 function, 24-byte entries.
            if (!ManagedObject.IsManagedObject(args[5])) throw new InvalidOperationException("Invalid save callback delegate");
            var address = (IntPtr)args[5];
            int count = Marshal.ReadInt32(address, 0x10);
            if (count < 1 || count > 32) throw new InvalidOperationException("Unexpected save callback count");
            int matched = 0;
            for (int i = 0; i < count; i++) {
                ulong function = unchecked((ulong)Marshal.ReadInt64(address, 0x20 + i * 24));
                ulong target = unchecked((ulong)Marshal.ReadInt64(address, 0x18 + i * 24));
                if (target == 0 || !ManagedObject.IsManagedObject(target)) continue;
                // A hook may replace the function pointer with a trampoline. The exact closure
                // type plus the specific completion hook identifies the invocation without assuming pointer stability.
                if (ManagedObject.FromAddress(target).GetTypeDefinition().FullName != "app.SaveDataManager.<>c__DisplayClass100_0") continue;
                lock (s_saveTraceLock) {
                    if (s_saveWriteClosures.Count >= 256) {
                        s_saveWriteClosures.Clear();
                        AppendSaveTrace(new { phase = "save_correlation_overflow", time = DateTimeOffset.UtcNow });
                    }
                    s_saveWriteClosures[target] = sequence;
                }
                AppendSaveTrace(new { sequence, phase = "save_callback_target", target = $"0x{target:X}",
                    function = $"0x{function:X}", originalFunction = function == s_saveCompletionFunction });
                matched++;
            }
            AppendSaveTrace(new { sequence, phase = "save_callback_bound", matched, time = DateTimeOffset.UtcNow });
        } catch (Exception e) {
            AppendSaveTrace(new { sequence, phase = "save_callback_bind_failed", error = e.Message });
        }
        return PreHookResult.Continue;
    }

    static PreHookResult ObserveSaveCompletion(Span<ulong> args) {
        if (s_stopped || s_reloadFreeze || !s_saveTracing || args.Length < 3) return PreHookResult.Continue;
        long sequence;
        lock (s_saveTraceLock) {
            if (!s_saveWriteClosures.Remove(args[1], out sequence)) return PreHookResult.Continue;
        }
        try {
            var data = ManagedObject.FromAddress(args[2]).As<ace.SaveDataManagerBase.cSaveDataRequestCallbackData>();
            AppendSaveTrace(new { sequence, phase = "save_callback", time = DateTimeOffset.UtcNow,
                result = (int)data.Result, error = (int)data.Error, detail = data.DetailResult });
            if (s_persistenceEnabled) {
                var record = s_saveTransactions.Complete(sequence, (int)data.Result == 1 && (int)data.Error == 0);
                if (record != null) lock (s_saveTraceLock) s_saveCommits.Enqueue(record);
            }
        } catch (Exception e) {
            AppendSaveTrace(new { sequence, phase = "save_callback_unreadable", error = e.Message });
        }
        return PreHookResult.Continue;
    }

    static object ConfigurePersistence(JsonElement request) {
        // Validate the resulting configuration before changing hooks, transactions or flags.
        bool nextEnabled = request.TryGetProperty("enabled", out var requestedEnabled)
            ? requestedEnabled.GetBoolean() : s_persistenceEnabled;
        bool nextAutomatic = request.TryGetProperty("automaticRestore", out var requestedAutomatic)
            ? requestedAutomatic.GetBoolean() : nextEnabled && s_autoRestoreEnabled;
        if (nextAutomatic && !nextEnabled)
            throw new InvalidOperationException("Enable persistence before automatic restoration");
        if (request.TryGetProperty("enabled", out var enabled)) {
            if (enabled.GetBoolean()) {
                using var traceRequest = JsonDocument.Parse("{\"enabled\":true}");
                TraceSaveLoads(traceRequest.RootElement);
                s_persistenceEnabled = true;
                s_persistenceStatus = "已启用保存记录，等待游戏保存成功";
            } else {
                s_persistenceEnabled = false;
                s_autoRestoreEnabled = false;
                s_loadCoordinator.ClearPending();
                s_saveTransactions = new AppearanceSaveTransactions<WardrobeSelectionState>();
                lock (s_saveTraceLock) s_saveCommits.Clear();
                s_persistenceStatus = "外观记录写入已关闭";
            }
        }
        s_autoRestoreEnabled = nextAutomatic;
        Volatile.Write(ref s_preferences, Volatile.Read(ref s_preferences) with {
            Persistence = s_persistenceEnabled, AutomaticRestore = s_autoRestoreEnabled });
        return new { enabled = s_persistenceEnabled, status = s_persistenceStatus, automaticRestore = s_autoRestoreEnabled };
    }

    static AppearanceSaveKey CurrentSaveKey(app.SaveDataManager manager, int slot) {
        var key = new AppearanceSaveKey(manager._SystemSaveData._Data._System.LastUserIndex,
            slot, manager._UserSaveData._Data._UserSystemParam.UniqueID);
        if (key.UniqueId == 0 || key.UserIndex < 0 || !(key.Slot >= 1 && key.Slot <= 20 || key.Slot == 101))
            throw new InvalidOperationException("Save identity unavailable");
        return key;
    }

    static object PreviewSavedAppearance() {
        var key = s_loadCoordinator.Observed?.Key;
        if (key == null) return new { available = false, reason = "No successful load observed in this plugin session" };
        var current = CurrentSaveKey(API.GetManagedSingletonT<app.SaveDataManager>(), key.Slot);
        if (current != key) return new { available = false, reason = "Player save identity changed since the observed load" };
        var saved = new WardrobeSaveStore(Path.Combine(s_dir, "saves")).Read(key);
        var registry = WardrobeRegistry.ReadDirectory(Path.Combine(s_dir, "mods"));
        return new { available = saved.Record != null, key, error = saved.Error,
            plan = saved.Record == null ? null : WardrobeSelections.Resolve(saved.Record.Choices, registry) };
    }

    static object QueueSavedRestore() {
        if (s_reloadFreeze) throw new InvalidOperationException("Reload is frozen; automatic restore is suspended");
        var ticket = s_loadCoordinator.QueueObserved();
        return new { queued = true, key = ticket.Key };
    }

    static bool PollRestore() {
        if (s_reloadFreeze) return false;
        try {
            if (s_restoreJob == null) {
                var ticket = s_loadCoordinator.TakePending();
                if (ticket == null) return false;
                var key = ticket.Key;
                var saved = new WardrobeSaveStore(Path.Combine(s_dir, "saves")).Read(key);
                if (saved.Error != null) throw new InvalidOperationException(saved.Error);
                var choices = saved.Record?.Choices ?? WardrobeSelections.FromLegacy(new SavedAppearance(null, null));
                var plan = WardrobeSelections.Resolve(choices, WardrobeRegistry.ReadDirectory(Path.Combine(s_dir, "mods")));
                s_restoreJob = new RestoreJob { Key = key, Ticket = ticket, Choices = choices, Clock = new AppearanceOperationClock(Environment.TickCount64) };
                s_restoreUnresolved = true;
                if (saved.Error != null) s_restoreJob.Issues.Add(saved.Error);
                foreach (var issue in plan.Issues) s_restoreJob.Issues.Add(issue);
                s_menuMessage = "正在恢复存档外观…";
                PublishMenu();
            }
            var job = s_restoreJob;
            var pause = API.GetManagedSingletonT<app.PauseManager>();
            if (Alive(pause) && pause.IsMenuPause) return true;
            if (job.Waiting) return true;
            // Let an in-flight native operation settle before abandoning its managed job.
            // A repeated load of the same slot/UniqueID still invalidates the earlier ticket.
            if (!s_loadCoordinator.IsCurrent(job.Ticket)) {
                AppendSaveTrace(new { phase = "appearance_restore_superseded", key = job.Key });
                s_restoreJob = null;
                s_menuMessage = "新读档已开始，停止上一份存档的后续外观恢复";
                PublishMenu();
                return true;
            }
            if (job.Clock.ActiveMilliseconds >= 60000) throw new TimeoutException("等待角色模型更新超时（不计菜单暂停时间），可稍后重试恢复");
            var manager = API.GetManagedSingletonT<app.SaveDataManager>();
            if (!Alive(manager)) return true;
            if (CurrentSaveKey(manager, job.Key.Slot) != job.Key)
                throw new InvalidOperationException("存档身份已变化，停止旧外观恢复");
            var playerManager = API.GetManagedSingletonT<app.PlayerManager>();
            if (!Alive(playerManager) || !Alive(playerManager.Catalog)) return true;
            var info = playerManager.getControllingPlayerInfo();
            var supporter = Alive(info) && Alive(info.CharacterEntity) ? info.CharacterEntity.GameObjectSupporter : null;
            if (!UsableSupporter(supporter) || supporter.isChangeModelProcessing() || supporter.isAddModelProcessing()) return true;
            if (job.Stage > 0 && s_selectedParts.Count > 0 && ((IProxyable)supporter).GetAddress() != s_visualSupporter) {
                // Loading a save can expose the old player before constructing its replacement.
                // Re-enter normal cleanup; it retains old resources until their supporter is destroyed.
                AppendSaveTrace(new { phase = "appearance_restore_player_changed", key = job.Key, stage = job.Stage });
                job.Stage = 0;
            }
            if (job.Stage > 0)
                foreach (var selected in s_selectedParts)
                    if (supporter._ModelIDs[selected.Key] != selected.Value) return true;
            if (job.Stage >= 1) {
                s_menuMessage = job.Issues.Count == 0 ? "存档外观恢复完成" : "外观恢复提示：" + string.Join("；", job.Issues);
                AppendSaveTrace(new { phase = "appearance_restore_finished", key = job.Key, issues = job.Issues.ToArray() });
                s_restoreUnresolved = job.Stage >= 3;
                s_restoreJob = null;
                PublishMenu();
                return true;
            }
            job.OperationId = "restore-" + Guid.NewGuid().ToString("N");
            job.Waiting = true;
            try {
                Respond(job.OperationId, true, StartWardrobeState(job.Choices,
                    WardrobeRegistry.ReadDirectory(Path.Combine(s_dir, "mods")), job.OperationId, true));
            } catch (Exception e) { Respond(job.OperationId, false, new { error = e.Message }); }
            return true;
        } catch (Exception e) {
            s_menuMessage = "外观恢复失败：" + e.Message;
            s_restoreUnresolved = true;
            AppendSaveTrace(new { phase = "appearance_restore_failed", error = e.Message });
            s_restoreJob = null;
            PublishMenu();
            return true;
        }
    }

    static void CaptureAppearanceSave(long sequence, Span<ulong> args) {
        try {
            if (s_reloadFreeze) return;
            // Only the observed current-data and prepared-data branches are supported.
            if ((args[6] & 0xff) != 0 || (args[9] & 0xff) != 0 ||
                (args[7] & 0xff) != 0 && (args[8] & 0xff) != 0)
                throw new InvalidOperationException("Unverified save branch; appearance record skipped");
            var phase = (args[8] & 0xff) != 0 ? AppearanceSavePhase.Prepare :
                (args[7] & 0xff) != 0 ? AppearanceSavePhase.WritePrepared : AppearanceSavePhase.WriteCurrent;
            var manager = ManagedObject.FromAddress(args[1]).As<app.SaveDataManager>();
            var key = CurrentSaveKey(manager, unchecked((int)args[3]));
            var menu = Volatile.Read(ref s_menu);
            var choices = Volatile.Read(ref s_saveSnapshot);
            if (choices == null) throw new InvalidOperationException("No stable wardrobe snapshot");
            bool captured = s_saveTransactions.Begin(sequence, key, choices, phase);
            bool restoring = s_saveLoadScopes?.Count > 0 || s_loadCoordinator.HasPending || s_restoreJob != null ||
                s_restoreUnresolved || s_wardrobeJob != null || s_transitionRequest != null || s_outfitRequest != null;
            if ((menu.Busy || restoring) && phase != AppearanceSavePhase.WritePrepared) {
                s_saveTransactions.Complete(sequence, false);
                throw new InvalidOperationException("Appearance transition in progress; save appearance snapshot skipped");
            }
            if (!captured) throw new InvalidOperationException("No matching prepared appearance snapshot");
            AppendSaveTrace(new { sequence, phase = "appearance_snapshot", key, choices, nativePhase = phase.ToString() });
        } catch (Exception e) {
            s_persistenceStatus = e.Message;
            AppendSaveTrace(new { sequence, phase = "appearance_snapshot_skipped", error = e.Message });
        }
    }

    static void FlushAppearanceSaves() {
        AppearanceSnapshot<WardrobeSelectionState> record;
        lock (s_saveTraceLock) {
            if (s_reloadFreeze || !s_persistenceEnabled || s_saveCommits.Count == 0) return;
            record = s_saveCommits.Dequeue();
        }
        try {
            new WardrobeSaveStore(Path.Combine(s_dir, "saves")).Write(record.Key, record.Choices);
            s_persistenceStatus = "外观记录已保存：槽 " + record.Key.Slot;
            AppendSaveTrace(new { phase = "appearance_committed", key = record.Key, choices = record.Choices });
        } catch (Exception e) {
            s_persistenceStatus = "外观记录写入失败：" + e.Message;
            AppendSaveTrace(new { phase = "appearance_commit_failed", key = record.Key, error = e.Message });
        }
    }

    static void InstallVisualHooks() {
        if (s_visualHooksInstalled) return;
        MethodHook.Create(NamedMethod(app.cPlayerGameObjectSupporter.REFType, "checkModelChange"), false)
            .AddPre(BeginVisualScope).AddPost(EndVisualScope);
        MethodHook.Create(NamedMethod(app.cPlayerGameObjectSupporter.REFType, "requestChangeAllModelHQ"), false)
            .AddPre(BeginVisualScope).AddPost(EndVisualScope);
        MethodHook.Create(NamedMethod(app.PlayerManager.REFType, "updateLoadModelHQ"), false)
            .AddPre(BeginHQLoadScope).AddPost(EndVisualScope);
        MethodHook.Create(NamedMethod(app.PlayerManager.REFType, "getCurrentEquipID"), false)
            .AddPre(BeginVisualLookup).AddPost(EndVisualLookup);
        s_visualHooksInstalled = true;
    }

    static PreHookResult BeginVisualScope(Span<ulong> args) {
        (s_visualScopes ??= new Stack<bool>()).Push(!s_stopped && s_selectedParts.Count > 0 &&
            args.Length > 1 && args[1] == s_visualSupporter);
        return PreHookResult.Continue;
    }
    static PreHookResult BeginHQLoadScope(Span<ulong> args) {
        // HQ preload/retention must use the same cosmetic identity as HQ instantiation.
        (s_visualScopes ??= new Stack<bool>()).Push(!s_stopped && s_selectedParts.Count > 0 &&
            args.Length > 1 && args[1] == s_visualManager);
        return PreHookResult.Continue;
    }
    static void EndVisualScope(ref ulong result) {
        if (s_visualScopes?.Count > 0) s_visualScopes.Pop();
    }
    static PreHookResult BeginVisualLookup(Span<ulong> args) {
        // Static native method: args[0] = VM context, args[1] = PARTS_TYPE.
        (s_visualLookups ??= new Stack<int>()).Push(s_visualScopes?.Count > 0 &&
            s_visualScopes.Peek() && args.Length > 1 ? (int)args[1] : -1);
        return PreHookResult.Continue;
    }
    static void EndVisualLookup(ref ulong result) {
        int part = s_visualLookups?.Count > 0 ? s_visualLookups.Pop() : -1;
        if (!s_stopped && s_selectedParts.TryGetValue(part, out int selected)) result = (uint)selected;
    }

    static object SelectBodyAlias() {
        return SelectBodyPrefab(null);
    }

    static object SelectBodyPrefab(via.Prefab independent) {
        var manager = Manager();
        var info = manager.getControllingPlayerInfo();
        var entity = Alive(info) ? info.CharacterEntity : null;
        var supporter = Alive(entity) ? entity.GameObjectSupporter : null;
        if (!UsableSupporter(supporter) || supporter.isChangeModelProcessing()) throw new InvalidOperationException("Player model unavailable or busy");
        var entries = manager.Catalog.getPlayerPartsList(app.PlayerPartsDef.PARTS_TYPE.BODY);
        int sourceId = app.PlayerManager.getCurrentEquipID(app.PlayerPartsDef.PARTS_TYPE.BODY, info.Context.Player);
        if (s_aliasRegistered || entries.ContainsKey(900001)) throw new InvalidOperationException("Probe alias already exists");
        InstallVisualHooks();
        entries.Add(900001, Alive(independent) ? independent : entries[sourceId]);
        s_aliasRegistered = true;
        s_visualSupporter = ((IProxyable)supporter).GetAddress();
        s_visualBodyId = 900001;
        s_selectedParts = new Dictionary<int, int> { [0] = 900001 };
        return new { selected = true, sourceId, appearanceModelId = 900001, equipped = Equipped(manager) };
    }

    static bool MatchesKind(int part, AppearanceKind? kind) => kind == null ||
        (part <= 5 ? AppearanceKind.Outfit : AppearanceKind.Weapon) == kind;

    static AppearanceKind? ReadKind(JsonElement request) {
        if (!request.TryGetProperty("kind", out var value)) return null;
        return value.GetString()?.ToLowerInvariant() switch {
            "outfit" => AppearanceKind.Outfit, "weapon" => AppearanceKind.Weapon,
            _ => throw new InvalidOperationException("kind must be outfit or weapon") };
    }

    static void WithdrawSelection(AppearanceKind? kind) {
        var remaining = new Dictionary<int, int>();
        foreach (var pair in s_selectedParts)
            if (!MatchesKind(pair.Key, kind)) remaining.Add(pair.Key, pair.Value);
        s_selectedParts = remaining;
        s_visualBodyId = remaining.TryGetValue(0, out int body) ? body : -1;
    }

    static bool HasRegistered(AppearanceKind? kind) {
        if (MatchesKind(0, kind) && s_aliasRegistered) return true;
        return s_outfitParts.Exists(part => MatchesKind(part.Part, kind));
    }

    static object ClearBodyAlias(AppearanceKind? kind = null) {
        WithdrawSelection(kind);
        // Let the native check restore the current actual equipment, then call again to unregister.
        var manager = Manager();
        var info = manager.getControllingPlayerInfo();
        var entity = Alive(info) ? info.CharacterEntity : null;
        var supporter = Alive(entity) ? entity.GameObjectSupporter : null;
        bool restored = UsableSupporter(supporter) && !supporter.isChangeModelProcessing() &&
            (!MatchesKind(0, kind) || !s_aliasRegistered || supporter._ModelIDs[0] != 900001);
        if (s_registeredSupporterOwner != null &&
            s_registeredSupporterOwner.GetAddress() != ((IProxyable)supporter)?.GetAddress()) {
            // A fresh character cannot prove the previous character has released its MOD models.
            // Retain its module until its native destroy path has run.
            restored = restored && s_registeredSupporterOwner.As<app.cPlayerGameObjectSupporter>()._IsDestroy;
        }
        foreach (var part in s_outfitParts)
            if (MatchesKind(part.Part, kind)) restored = restored && supporter._ModelIDs[part.Part] != part.Id;
        if (restored && s_aliasRegistered && MatchesKind(0, kind)) {
            manager.Catalog.getPlayerPartsList(app.PlayerPartsDef.PARTS_TYPE.BODY).Remove(900001);
            s_aliasRegistered = false;
            if (Alive(s_visualPrefab)) s_visualPrefab.Standby = false;
            s_visualPrefab = null;
            s_visualOwner?.Release();
            s_visualOwner = null;
        }
        if (restored) ReleaseOutfit(kind);
        bool registered = HasRegistered(kind);
        return new { selected = false, restored, registered, equipped = Equipped(manager) };
    }

    static object ReadRegistry() {
        s_wardrobeRegistry = WardrobeRegistry.ReadDirectory(Path.Combine(s_dir, "mods"));
        s_registry = AppearanceRegistry.ReadDirectory(Path.Combine(s_dir, "mods"));
        Interlocked.Exchange(ref s_refreshIcons, 1);
        return new { entries = s_registry.Entries, issues = s_registry.Issues, activeModId = s_activeModId,
            outfit = s_activeMods.TryGetValue(AppearanceKind.Outfit, out var outfit) ? outfit : null,
            weapon = s_activeMods.TryGetValue(AppearanceKind.Weapon, out var weapon) ? weapon : null };
    }

    static object BeginRegistered(JsonElement request, string id) {
        ReadRegistry();
        var modId = request.GetProperty("modId").GetString();
        if (modId == null || !s_registry.Entries.TryGetValue(modId, out var entry))
            throw new InvalidOperationException("MOD is missing or its manifest was rejected; inspect registry_list");
        if (!s_registrySlots.TryGetValue(entry.Id, out int slot)) {
            if (s_registrySlots.Count >= 3000) throw new InvalidOperationException("Runtime MOD ID reserve exhausted");
            slot = s_registrySlots.Count + 1;
            s_registrySlots.Add(entry.Id, slot);
        }
        return BeginTransition(id, entry, slot);
    }

    static object BeginTransition(string id, AppearanceEntry entry, int slot, AppearanceKind? kind = null) {
        if (s_loadId != null || s_outfitRequest != null || s_transitionRequest != null)
            throw new InvalidOperationException("Appearance operation already in progress");
        if (s_wardrobeJob == null && s_wardrobeState != null) {
            using var visibility = JsonDocument.Parse("{\"parts\":[]}");
            SetVisibility(visibility.RootElement);
            s_wardrobeState = null;
        }
        if (s_restoreJob == null || id != s_restoreJob.OperationId)
            Volatile.Read(ref s_missingIntent)?.Intent.Forget(entry?.Kind ?? kind);
        // Resolve/validate the requested manifest before removing the current selection.
        // Keep old resources alive until the native model check has restored every part.
        s_transitionRequest = id;
        s_transitionEntry = entry;
        s_transitionKind = entry?.Kind ?? kind;
        s_transitionSlot = slot;
        s_transitionDeadline = Environment.TickCount64 + 8000;
        WithdrawSelection(s_transitionKind);
        return new { phase = "loading_restore", modId = entry?.Id };
    }

    static void PollTransition() {
        var id = s_transitionRequest;
        try {
            ClearBodyAlias(s_transitionKind);
            if (HasRegistered(s_transitionKind)) {
                if (Environment.TickCount64 < s_transitionDeadline) return;
                throw new TimeoutException("Native restoration is still pending; old resources retained. Retry clear when the player is available.");
            }
            var entry = s_transitionEntry;
            s_transitionRequest = null;
            s_transitionEntry = null;
            if (entry == null) Respond(id, true, new { phase = "finished", selected = false });
            else Respond(id, true, BeginOutfit(id, entry, s_transitionSlot));
        } catch (Exception e) {
            s_transitionRequest = null;
            s_transitionEntry = null;
            Respond(id, false, new { error = e.Message });
        }
    }

    static object BeginOutfit(string id, AppearanceEntry entry = null, int slot = 0) {
        var kind = entry?.Kind ?? AppearanceKind.Outfit;
        if (HasRegistered(kind) || s_preloadParts.Count > 0 || s_loadId != null)
            throw new InvalidOperationException("Clear previous probe before loading an outfit");
        try {
            var requested = entry?.Parts ?? new List<AppearancePart> {
                new AppearancePart(0, "mods/owots_appearance_lab/manba_4/body_catalog.user", "mods/owots_appearance_lab/manba_4/body_____________________.pfb"),
                new AppearancePart(2, "mods/owots_appearance_lab/manba_4/head_catalog.user", "mods/owots_appearance_lab/manba_4/head_____________________.pfb"),
                new AppearancePart(3, "mods/owots_appearance_lab/manba_4/hair_catalog.user", "mods/owots_appearance_lab/manba_4/hair_____________________.pfb") };
            foreach (var part in requested) {
                var owner = API.GetResourceManager().CreateUserData("app.user_data.PlayerPartsList", part.Catalog);
                if (!Alive(owner)) throw new InvalidOperationException("Cannot load " + part.Catalog);
                s_preloadParts.Add(new OutfitPart { Part = part.Part, Id = 900001 + slot * 32 + part.Part,
                    ExpectedPrefab = part.Prefab, ExpectedCatalog = part.Catalog, Owner = owner.Globalize() });
            }
            s_pendingModId = entry?.Id;
            s_pendingKind = kind;
            s_outfitRequest = id;
            s_outfitDeadline = Environment.TickCount64 + 15000;
            return new { phase = "loading_outfit" };
        } catch { ReleasePreload(); throw; }
    }

    static void PollOutfit() {
        string id = s_outfitRequest;
        try {
            bool ready = true;
            foreach (var part in s_preloadParts) {
                if (!Alive(part.Prefab)) {
                    var data = part.Owner.As<app.user_data.PlayerPartsList>();
                    for (int i = 0; i < Math.Min(data.DataNum, 128); i++) {
                        var prefab = data._DataList[i].PartsPrefab;
                        if (Alive(prefab) && string.Equals(prefab.Path, part.ExpectedPrefab, StringComparison.OrdinalIgnoreCase)) {
                            part.Prefab = prefab;
                            prefab.Standby = true;
                            break;
                        }
                    }
                }
                ready &= Alive(part.Prefab) && part.Prefab.Ready && part.Prefab.Valid;
            }
            if (!ready) {
                if (Environment.TickCount64 < s_outfitDeadline) return;
                throw new TimeoutException("Appearance prefab preload did not complete; no new selection applied");
            }
            var manager = Manager();
            var info = manager.getControllingPlayerInfo();
            var entity = Alive(info) ? info.CharacterEntity : null;
            var supporter = Alive(entity) ? entity.GameObjectSupporter : null;
            if (!UsableSupporter(supporter) || supporter.isChangeModelProcessing())
                throw new InvalidOperationException("Player model unavailable or busy");
            if (s_selectedParts.Count > 0 && ((IProxyable)supporter).GetAddress() != s_visualSupporter)
                throw new InvalidOperationException("Player changed; clear existing appearance before selecting another group");
            foreach (var part in s_preloadParts)
                if (manager.Catalog.getPlayerPartsList((app.PlayerPartsDef.PARTS_TYPE)part.Part).ContainsKey(part.Id) ||
                    manager.Catalog.getPlayerPartsListHQ((app.PlayerPartsDef.PARTS_TYPE)part.Part).ContainsKey(part.Id))
                    throw new InvalidOperationException("Outfit test ID collision: " + part.Id);
            InstallVisualHooks();
            var selection = new Dictionary<int, int>(s_selectedParts);
            foreach (var part in s_preloadParts) {
                // Keep the exact containers alive; a later player/manager may expose different catalogs.
                var normal = manager.Catalog.getPlayerPartsList((app.PlayerPartsDef.PARTS_TYPE)part.Part);
                var hq = manager.Catalog.getPlayerPartsListHQ((app.PlayerPartsDef.PARTS_TYPE)part.Part);
                part.NormalCatalogOwner = ManagedObject.FromAddress(((IProxyable)normal).GetAddress()).Globalize();
                part.HQCatalogOwner = ManagedObject.FromAddress(((IProxyable)hq).GetAddress()).Globalize();
                ulong prefabAddress = ((IProxyable)part.Prefab).GetAddress();
                part.RemoveNormal = () => {
                    if (!normal.ContainsKey(part.Id)) return;
                    if (((IProxyable)normal[part.Id]).GetAddress() != prefabAddress)
                        throw new InvalidOperationException("Normal catalog entry ownership changed; resources retained");
                    normal.Remove(part.Id);
                };
                part.RemoveHQ = () => {
                    if (!hq.ContainsKey(part.Id)) return;
                    if (((IProxyable)hq[part.Id]).GetAddress() != prefabAddress)
                        throw new InvalidOperationException("HQ catalog entry ownership changed; resources retained");
                    hq.Remove(part.Id);
                };
                normal.Add(part.Id, part.Prefab);
                part.Registered = true;
                // Reuse the MOD's own prefab for HQ; preserve all native catalog entries.
                hq.Add(part.Id, part.Prefab);
                part.RegisteredHQ = true;
                selection.Add(part.Part, part.Id);
            }
            s_visualSupporter = ((IProxyable)supporter).GetAddress();
            if (s_registeredSupporterOwner == null)
                s_registeredSupporterOwner = ManagedObject.FromAddress(s_visualSupporter).Globalize();
            s_visualManager = ((IProxyable)manager).GetAddress();
            s_visualBodyId = selection.TryGetValue(0, out int bodyId) ? bodyId : -1;
            s_selectedParts = selection;
            s_activeModId = s_pendingModId;
            if (s_pendingModId != null) s_activeMods[s_pendingKind] = s_pendingModId;
            s_outfitParts.AddRange(s_preloadParts);
            s_preloadParts.Clear();
            s_outfitRequest = null;
            Respond(id, true, new { phase = "finished", modId = s_activeModId, selectedParts = selection, equipped = Equipped(manager) });
        } catch (Exception e) {
            s_outfitRequest = null;
            ReleasePreload();
            Respond(id, false, new { error = e.Message });
        }
    }

    static void ReleaseParts(List<OutfitPart> parts) {
        foreach (var part in parts) {
            if (part.Registered) { part.RemoveNormal(); part.Registered = false; }
            if (part.RegisteredHQ) { part.RemoveHQ(); part.RegisteredHQ = false; }
            if (Alive(part.Prefab)) part.Prefab.Standby = false;
            part.Owner?.Release();
            part.Owner = null;
            part.NormalCatalogOwner?.Release();
            part.NormalCatalogOwner = null;
            part.HQCatalogOwner?.Release();
            part.HQCatalogOwner = null;
            part.RemoveNormal = part.RemoveHQ = null;
        }
        parts.Clear();
    }

    static void ReleasePreload() {
        ReleaseParts(s_preloadParts);
        s_pendingModId = null;
    }

    static void ReleaseOutfit(AppearanceKind? kind = null) {
        var released = s_outfitParts.FindAll(part => MatchesKind(part.Part, kind));
        ReleaseParts(released);
        s_outfitParts.RemoveAll(part => MatchesKind(part.Part, kind));
        if (s_outfitParts.Count == 0) {
            s_registeredSupporterOwner?.Release();
            s_registeredSupporterOwner = null;
        }
        if (kind == null) s_activeMods.Clear();
        else s_activeMods.Remove(kind.Value);
        s_activeModId = s_activeMods.TryGetValue(AppearanceKind.Outfit, out var outfit) ? outfit :
            s_activeMods.TryGetValue(AppearanceKind.Weapon, out var weapon) ? weapon : null;
    }

    static object TraceModelChanges(JsonElement request) {
        bool enabled = request.GetProperty("enabled").GetBoolean();
        if (enabled && !s_traceHookInstalled) {
            foreach (var method in app.PlayerManager.REFType.Methods) {
                if (method.Name == "changePlayerModel" && method.GetNumParams() == 6) {
                    MethodHook.Create(method, false).AddPre(ObserveModelChange);
                    s_traceHookInstalled = true;
                    break;
                }
            }
            if (!s_traceHookInstalled) throw new InvalidOperationException("Model change overload missing");
        }
        s_tracing = enabled;
        lock (s_traceLock) return new { enabled, calls = s_modelTrace.ToArray() };
    }

    static PreHookResult ObserveModelChange(Span<ulong> args) {
        if (!s_tracing || s_stopped) return PreHookResult.Continue;
        // Record only scalar copies while arguments are live; no mutation or proxy retention.
        var values = new List<string>();
        for (int i = 0; i < Math.Min(args.Length, 8); i++) values.Add("0x" + args[i].ToString("X"));
        lock (s_traceLock) {
            if (s_modelTrace.Count >= 64) s_modelTrace.RemoveAt(0);
            s_modelTrace.Add(new { at = DateTimeOffset.UtcNow, args = values });
        }
        return PreHookResult.Continue;
    }

    static object ProbeRegistration(JsonElement request) {
        var manager = Manager();
        int partNumber = request.GetProperty("part").GetInt32();
        int sourceId = request.GetProperty("sourceId").GetInt32();
        int testId = request.GetProperty("testId").GetInt32();
        if (partNumber < 0 || partNumber >= 13 || testId < 900000 || testId > 999999)
            throw new InvalidOperationException("Probe requires part 0..12 and isolated test ID 900000..999999");
        var part = (app.PlayerPartsDef.PARTS_TYPE)partNumber;
        var entries = manager.Catalog.getPlayerPartsList(part);
        if (!Alive(entries) || !entries.ContainsKey(sourceId)) throw new InvalidOperationException("Source prefab not found");
        if (entries.ContainsKey(testId)) throw new InvalidOperationException("Test ID already exists");
        var prefab = entries[sourceId];
        if (!Alive(prefab)) throw new InvalidOperationException("Source prefab unavailable");
        var before = Equipped(manager);
        int beforeCount = entries.Count;
        bool added = false, engineLookup = false, removed = false;
        try {
            entries.Add(testId, prefab);
            added = entries.ContainsKey(testId);
            engineLookup = manager.isExistsPrefab(part, testId);
        } finally {
            if (entries.ContainsKey(testId)) removed = entries.Remove(testId);
        }
        return new { part = partNumber, sourceId, testId, added, engineLookup, removed,
            countBefore = beforeCount, countAfter = entries.Count,
            before, after = Equipped(manager), remaining = entries.ContainsKey(testId) };
    }
}
#endif
