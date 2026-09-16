using System;

namespace OWOTS.Appearance;

/// <summary>Counts active update time; paused intervals do not exhaust model-change waits.</summary>
public sealed class AppearanceOperationClock(long startedAt)
{
    private long previous = startedAt;
    private bool previouslyPaused;
    public long ActiveMilliseconds { get; private set; }
    public long Advance(long now, bool paused)
    {
        long elapsed = Math.Max(0, now - previous);
        previous = Math.Max(previous, now);
        // Exclude transition intervals too: the pause can have ended anywhere between samples.
        bool excluded = paused || previouslyPaused;
        previouslyPaused = paused;
        if (!excluded) ActiveMilliseconds += elapsed;
        return excluded ? elapsed : 0;
    }
}
