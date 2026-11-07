namespace StreamSetu.Core;

/// <summary>Stops playback after a chosen time. The clock is given in, so the rule is tested without waiting.</summary>
public sealed class SleepTimer(Func<DateTimeOffset> now)
{
    private DateTimeOffset? _at;
    private bool _fired;

    public bool Running => _at is not null && !_fired;

    public void Start(TimeSpan after)
    {
        if (after <= TimeSpan.Zero) { Cancel(); return; }
        _at = now() + after; _fired = false;
    }

    public void Cancel() { _at = null; _fired = false; }

    public TimeSpan? Remaining => Running ? Max(_at!.Value - now(), TimeSpan.Zero) : null;

    /// <summary>True exactly once, when the time has come. The screen calls this on its clock tick and stops playback when it returns true.</summary>
    public bool Due()
    {
        if (!Running || now() < _at!.Value) return false;
        _fired = true;
        return true;
    }

    private static TimeSpan Max(TimeSpan a, TimeSpan b) => a > b ? a : b;
}
