namespace VibeLightHelper.Core;

/// <summary>
/// Restart PC, done the way MoonDeckBuddy does it (its <c>PcStateHandler</c>,
/// which the owner found really effective — VibeLight Helper replaces it):
/// <list type="bullet">
/// <item>one change at a time: a second request while one is under way is refused;</item>
/// <item>the native side must be able to do it (the shutdown privilege, taken
/// at startup) or the request is refused up front;</item>
/// <item>the request is answered at once and the restart fires after a grace
/// period of 1–30 s, which can still be cancelled;</item>
/// <item>once it fires the state is transient until Windows goes down; a native
/// call that fails puts it back to normal.</item>
/// </list>
/// The native call itself is MoonDeckBuddy's too (see Win32Platform).
/// </summary>
public sealed class PcStateHandler : IDisposable
{
    public enum PcState { Normal, Restarting, Transient }

    public const int MinGraceSeconds = 1;
    public const int MaxGraceSeconds = 30;

    readonly Func<bool> canRestart;
    readonly Func<bool> restartNow;
    readonly object gate = new();
    Timer? graceTimer;
    PcState state = PcState.Normal;

    /// <summary>A restart was scheduled, in this many seconds (the tray says so).</summary>
    public event Action<int>? RestartScheduled;
    /// <summary>A scheduled restart was called off.</summary>
    public event Action? RestartCancelled;

    public PcStateHandler(Func<bool> canRestart, Func<bool> restartNow)
    {
        this.canRestart = canRestart;
        this.restartNow = restartNow;
    }

    public PcState State
    {
        get { lock (gate) { return state; } }
    }

    public RestartResponse Restart(int graceSeconds)
    {
        lock (gate)
        {
            if (state != PcState.Normal)
            {
                return new RestartResponse(false, "The PC is already restarting.");
            }
            if (!canRestart())
            {
                return new RestartResponse(false, "Windows won't let VibeLight Helper restart this PC.");
            }
            state = PcState.Restarting;
            graceTimer = new Timer(_ => Fire(), null, TimeSpan.FromSeconds(graceSeconds), Timeout.InfiniteTimeSpan);
        }
        RestartScheduled?.Invoke(graceSeconds);
        return new RestartResponse(true, $"Restarting in {graceSeconds} second(s).");
    }

    /// <summary>Calls off a scheduled restart. Too late once it has fired.</summary>
    public bool Cancel()
    {
        lock (gate)
        {
            if (state != PcState.Restarting) return false;
            graceTimer?.Dispose();
            graceTimer = null;
            state = PcState.Normal;
        }
        RestartCancelled?.Invoke();
        return true;
    }

    void Fire()
    {
        lock (gate)
        {
            if (state != PcState.Restarting) return;   // cancelled meanwhile
            graceTimer?.Dispose();
            graceTimer = null;
            state = PcState.Transient;
        }
        if (!restartNow())
        {
            lock (gate) { state = PcState.Normal; }
        }
    }

    public void Dispose()
    {
        lock (gate)
        {
            graceTimer?.Dispose();
            graceTimer = null;
        }
    }
}
