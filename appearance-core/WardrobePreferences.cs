using System;
using System.IO;
using System.Text.Json;

namespace OWOTS.Appearance;

public sealed record WardrobePreferences(int SchemaVersion = 1, string Hotkey = "Slash", bool Cards = false,
    bool Persistence = false, bool AutomaticRestore = false, bool NativeMenuSync = false, bool IndependentSkeleton = true)
{
    public static readonly string[] SupportedHotkeys = { "Slash", "F6", "F7", "F8", "F9", "F10", "F11", "F12" };
    public WardrobePreferences Validate()
    {
        if (SchemaVersion != 1 || Array.IndexOf(SupportedHotkeys, Hotkey) < 0)
            throw new FormatException("Unsupported wardrobe preferences version or hotkey");
        if (AutomaticRestore && !Persistence)
            throw new FormatException("Automatic restoration requires appearance persistence");
        return this;
    }
    public static WardrobePreferences Read(string path)
    {
        if (!File.Exists(path)) return new();
        return (JsonSerializer.Deserialize<WardrobePreferences>(File.ReadAllText(path)) ??
            throw new FormatException("Empty wardrobe preferences")).Validate();
    }
    public void Write(string path)
    {
        Validate();
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(JsonSerializer.SerializeToUtf8Bytes(this));
                stream.Flush(true);
            }
            File.Move(temporary, path, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
